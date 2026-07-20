defmodule SSHAudio.Session do
  @moduledoc """
  One per SSH connection. Owns rendering and input handling for a
  single terminal client, and drives a Player via the Player API.
  Playback itself lives in the Player GenServer, not here, so a
  session dying (or a client disconnecting) never stops playback.
  """

  use GenServer

  alias SSHAudio.{Library, Player, PlayerSupervisor}
  alias SSHAudio.TUI.{Buffer, Widgets}

  defstruct [
    :channel_pid,
    :user_id,
    :width,
    :height,
    :player_state,
    mode: :normal,
    query: "",
    results: [],
    selected: 0
  ]

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({channel_pid, user_id, width, height}) do
    Process.monitor(channel_pid)
    {:ok, _pid} = PlayerSupervisor.ensure_started(user_id)
    Phoenix.PubSub.subscribe(SSHAudio.PubSub, Player.topic(user_id))

    state = %__MODULE__{
      channel_pid: channel_pid,
      user_id: user_id,
      width: width,
      height: height,
      player_state: Player.get_state(user_id)
    }

    render(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:resize, width, height}, state) do
    state = %{state | width: width, height: height}
    render(state)
    {:noreply, state}
  end

  def handle_info({:input, data}, state), do: handle_input(data, state)

  def handle_info({:player_state, player_state}, state) do
    state = %{state | player_state: player_state}
    render(state)
    {:noreply, state}
  end

  def handle_info(:channel_closed, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, _ref, :process, channel_pid, _reason}, %{channel_pid: channel_pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # Ctrl-C always quits, regardless of mode.
  defp handle_input(<<3, _rest::binary>>, state), do: quit(state)

  # While searching, every other keystroke is query input/navigation,
  # not a playback shortcut — so this clause must win over "q"/" "/etc.
  defp handle_input(data, %{mode: :search} = state), do: handle_search_input(data, state)

  defp handle_input("q", state), do: quit(state)

  defp handle_input("/", state) do
    results = Library.search("")
    render_and_reply(%{state | mode: :search, query: "", results: results, selected: 0})
  end

  defp handle_input(" ", state) do
    Player.toggle(state.user_id)
    {:noreply, state}
  end

  defp handle_input("n", state) do
    Player.skip(state.user_id)
    {:noreply, state}
  end

  defp handle_input("+", state) do
    Player.set_volume(state.user_id, state.player_state.volume + 5)
    {:noreply, state}
  end

  defp handle_input("-", state) do
    Player.set_volume(state.user_id, state.player_state.volume - 5)
    {:noreply, state}
  end

  defp handle_input(_other, state), do: {:noreply, state}

  # Enter: play the selected result
  defp handle_search_input("\r", state), do: select_result(state)
  defp handle_search_input("\n", state), do: select_result(state)

  # Tab: queue the selected result without leaving search, so multiple
  # tracks can be queued back to back.
  defp handle_search_input("\t", state), do: enqueue_result(state)

  # Esc: cancel search (but not an arrow-key sequence, handled below)
  defp handle_search_input(<<27>>, state) do
    render_and_reply(%{state | mode: :normal, query: "", results: [], selected: 0})
  end

  defp handle_search_input(<<27, 91, 65, _rest::binary>>, state), do: move_selection(state, -1)
  defp handle_search_input(<<27, 91, 66, _rest::binary>>, state), do: move_selection(state, 1)

  defp handle_search_input(<<127>>, state), do: backspace(state)
  defp handle_search_input(<<8>>, state), do: backspace(state)

  defp handle_search_input(data, state) do
    if String.printable?(data) do
      query = state.query <> data
      render_and_reply(%{state | query: query, results: Library.search(query), selected: 0})
    else
      {:noreply, state}
    end
  end

  defp select_result(state) do
    case Enum.at(state.results, state.selected) do
      nil -> :ok
      track -> Player.play(state.user_id, track)
    end

    render_and_reply(%{state | mode: :normal, query: "", results: [], selected: 0})
  end

  defp enqueue_result(state) do
    case Enum.at(state.results, state.selected) do
      nil -> :ok
      track -> Player.enqueue(state.user_id, track)
    end

    {:noreply, state}
  end

  defp move_selection(%{results: []} = state, _delta), do: render_and_reply(state)

  defp move_selection(state, delta) do
    selected = Integer.mod(state.selected + delta, length(state.results))
    render_and_reply(%{state | selected: selected})
  end

  defp backspace(%{query: ""} = state), do: render_and_reply(state)

  defp backspace(state) do
    query = String.slice(state.query, 0..-2//1)
    render_and_reply(%{state | query: query, results: Library.search(query), selected: 0})
  end

  defp quit(state) do
    send(state.channel_pid, {:session_closed, self()})
    {:stop, :normal, state}
  end

  defp render_and_reply(state) do
    render(state)
    {:noreply, state}
  end

  defp render(state) do
    send(state.channel_pid, {:session_render, frame(state)})
  end

  defp frame(%{player_state: player_state} = state) do
    width = max(state.width, 40)
    height = max(state.height, 14)

    now_row = 4
    now_height = now_playing_height(height)
    lower_row = now_row + now_height + 1
    lower_height = max(height - lower_row - 1, 3)

    footer =
      case state.mode do
        :search -> "type to search   ↑/↓ select   enter: play   tab: queue   esc: cancel"
        :normal -> "space: play/pause   n: skip   +/-: volume   /: search   q: quit"
      end

    buffer =
      Buffer.new(width, height)
      |> Buffer.put_string(1, 2, "SSH Audio — #{state.user_id}", [:cyan, :bright])
      |> Buffer.hline(2, 1, width, [:cyan])
      |> render_now_playing(player_state, now_row, width, now_height)

    buffer =
      case state.mode do
        :search -> render_search(buffer, state, lower_row, width, lower_height)
        :normal -> render_queue(buffer, player_state, lower_row, width, lower_height)
      end

    buffer
    |> Buffer.put_string(height, 2, footer, [:faint])
    |> Buffer.to_iodata()
  end

  # Scales the "now playing" panel to the client's terminal size: taller
  # panels (and thus bigger album art, see `art_dimensions/2`) on bigger
  # terminals, falling back to the original compact size for small ones.
  defp now_playing_height(height) do
    cond do
      height >= 34 -> 18
      height >= 24 -> 13
      height >= 18 -> 10
      true -> 7
    end
  end

  # Album art fills the panel's interior height and keeps roughly a 2.2:1
  # width:height cell ratio (a terminal cell is about twice as tall as it
  # is wide), capped so at least ~34 columns stay free for the text column.
  defp art_dimensions(width, height) do
    art_height = height - 2
    max_art_width = max(width - 34, 10)
    art_width = (art_height * 2.2) |> round() |> min(max_art_width) |> max(10)

    {art_width, art_height}
  end

  defp render_now_playing(buffer, player_state, row, width, height) do
    {status_label, status_style} =
      case player_state.status do
        :playing -> {"▶ PLAYING", [:green, :bright]}
        :paused -> {"⏸ PAUSED", [:yellow, :bright]}
        :stopped -> {"■ STOPPED", [:red]}
      end

    info = player_state.now_info || %{}
    track = player_state.current

    title = info[:title] || (track && track.display) || "(nothing queued)"
    artist = info[:artist] || (track && track.artist)
    meta_line = Enum.join(Enum.filter([artist, info[:genre]], & &1), " · ")

    format_line =
      [format_bitrate(info[:bitrate]), format_samplerate(info[:samplerate])]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    art_col = 3
    {art_width, art_height} = art_dimensions(width, height)
    text_col = art_col + art_width + 2

    # Center the (fixed 5-line-tall) text block vertically alongside the
    # album art, so it doesn't sit pinned to the top on taller panels.
    text_row = row + 1 + div(max(art_height - 5, 0), 2)

    buffer
    |> Widgets.panel(row, 1, width, height, title: "now playing", style: [:blue])
    |> Widgets.img_preview_data(row + 1, art_col, art_width, art_height, track && track.album_img)
    |> Buffer.put_string(text_row, text_col, status_label, status_style)
    |> Buffer.put_string(text_row, text_col + String.length(status_label) + 3, "vol #{player_state.volume}%", [])
    |> Buffer.put_string(text_row + 1, text_col, title, [:bright])
    |> put_line(text_row + 2, text_col, meta_line, [:faint])
    |> put_line(text_row + 3, text_col, format_line, [:faint])
    |> render_progress(text_row + 4, text_col, width, info[:position], info[:duration])
  end

  defp put_line(buffer, _row, _col, "", _style), do: buffer
  defp put_line(buffer, row, col, text, style), do: Buffer.put_string(buffer, row, col, text, style)

  defp render_progress(buffer, row, text_col, width, position, duration)
       when is_number(position) and is_number(duration) and duration > 0 do
    time_width = 5
    bar_col = text_col + time_width + 1
    bar_width = max(width - bar_col - time_width - 1, 4)
    ratio = position / duration

    buffer
    |> Buffer.put_string(row, text_col, format_time(position), [:faint])
    |> Widgets.progress_bar(row, bar_col, bar_width, ratio, style: [:cyan])
    |> Buffer.put_string(row, bar_col + bar_width + 1, format_time(duration), [:faint])
  end

  defp render_progress(buffer, _row, _text_col, _width, _position, _duration), do: buffer

  defp format_time(seconds) when is_number(seconds) do
    total = trunc(seconds)
    minutes = div(total, 60)
    secs = rem(total, 60)
    :io_lib.format("~2..0B:~2..0B", [minutes, secs]) |> IO.iodata_to_binary()
  end

  defp format_bitrate(bps) when is_number(bps), do: "#{round(bps / 1000)} kbps"
  defp format_bitrate(_), do: nil

  defp format_samplerate(hz) when is_number(hz), do: "#{Float.round(hz / 1000, 1)} kHz"
  defp format_samplerate(_), do: nil

  defp render_queue(buffer, player_state, row, width, height) do
    queue_lines =
      case Enum.take(player_state.queue, 5) do
        [] ->
          ["(empty)"]

        tracks ->
          tracks
          |> Enum.with_index(1)
          |> Enum.map(fn {track, i} -> "#{i}. #{track.display}" end)
      end

    buffer
    |> Widgets.panel(row, 1, width, height, title: "queue", style: [:blue])
    |> Widgets.list(row + 1, 3, queue_lines)
  end

  defp render_search(buffer, state, row, width, height) do
    buffer =
      buffer
      |> Widgets.panel(row, 1, width, height, title: "search", style: [:magenta])
      |> Buffer.put_string(row + 1, 3, "/ #{state.query}▌", [:bright])

    case state.results do
      [] ->
        Buffer.put_string(buffer, row + 3, 3, "(no matches)", [:faint])

      results ->
        visible = max(height - 4, 0)
        offset = if visible > 0, do: div(state.selected, visible) * visible, else: 0
        queued_paths = MapSet.new(state.player_state.queue, & &1.path)

        results
        |> Enum.slice(offset, visible)
        |> Enum.with_index(offset)
        |> Enum.reduce(buffer, fn {track, i}, buffer ->
          selected? = i == state.selected
          queued? = MapSet.member?(queued_paths, track.path)

          style =
            cond do
              selected? and queued? -> [:yellow, :reverse]
              selected? -> [:reverse]
              queued? -> [:yellow]
              true -> []
            end

          prefix = if selected?, do: "> ", else: "  "
          Buffer.put_string(buffer, row + 3 + (i - offset), 3, prefix <> track.display, style)
        end)
    end
  end
end
