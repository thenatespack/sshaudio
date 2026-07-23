defmodule SSHAudio.Session do
  @moduledoc """
  One per SSH connection. Owns rendering and input handling for a
  single terminal client, and drives a Player via the Player API.
  """

  use GenServer

  alias SSHAudio.{Library, Player, PlayerSupervisor}
  alias SSHAudio.TUI.{Buffer, Widgets}

  # SGR mouse mode (1000 for click reporting, 1006 for extended encoding)
  @enable_mouse "\e[?1000h\e[?1006h"
  @disable_mouse "\e[?1000l\e[?1006l"

  defstruct [
    :channel_pid,
    :user_id,
    :width,
    :height,
    :player_state,
    mode: :normal,
    query: "",
    results: [],
    selected: 0,
    progress_rect: nil
  ]

  def start_link(args), do: GenServer.start_link(__MODULE__, args)

  @impl true
  def init({channel_pid, user_id, width, height}) do
    Process.monitor(channel_pid)
    {:ok, _pid} = PlayerSupervisor.ensure_started(user_id)
    Phoenix.PubSub.subscribe(SSHAudio.PubSub, Player.topic(user_id))

    # Enable mouse mode on the client terminal
    send(channel_pid, {:session_render, @enable_mouse})

    state = %__MODULE__{
      channel_pid: channel_pid,
      user_id: user_id,
      width: width,
      height: height,
      player_state: Player.get_state(user_id)
    }

    state = render(state)
    {:ok, state}
  end

  @impl true
  def handle_info({:resize, width, height}, state) do
    state = render(%{state | width: width, height: height})
    {:noreply, state}
  end

  def handle_info({:input, data}, state) do
    # Mouse sequences often arrive as part of a larger buffer or
    # slightly fragmented. We check for the SGR prefix specifically.
    if String.contains?(data, "\e[<") do
      handle_mouse_input(data, state)
    else
      handle_keyboard_input(data, state)
    end
  end

  def handle_info({:player_state, player_state}, state) do
    state = render(%{state | player_state: player_state})
    {:noreply, state}
  end

  def handle_info(:channel_closed, state), do: {:stop, :normal, state}

  def handle_info({:DOWN, _ref, :process, channel_pid, _reason}, %{channel_pid: channel_pid} = state) do
    {:stop, :normal, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- Input Handlers ---

  defp handle_mouse_input(data, state) do
    # Regex explains:
    # (\d+) button (0 is left)
    # (\d+) column
    # (\d+) row
    # ([Mm]) M is press, m is release
    case Regex.run(~r/\e\[<(\d+);(\d+);(\d+)([Mm])/, data) do
      [_match, "0", cx, cy, "M"] ->
        # Left button press
        state = seek_from_click(state, String.to_integer(cx), String.to_integer(cy))
        {:noreply, state}

      [_match, _btn, _cx, _cy, _event] ->
        # Ignore other mouse events (releases, right clicks) so they
        # don't fall through to keyboard shortcuts.
        {:noreply, state}

      nil ->
        # If the sequence was malformed, try treating it as keyboard input
        handle_keyboard_input(data, state)
    end
  end

  defp handle_keyboard_input(data, state) do
    case data do
      <<3, _rest::binary>> -> quit(state)
      _ -> dispatch_mode_input(data, state)
    end
  end

  # While searching, keys drive the query.
  defp dispatch_mode_input(data, %{mode: :search} = state), do: handle_search_input(data, state)

  # Normal mode playback shortcuts
  defp dispatch_mode_input("q", state), do: quit(state)
  defp dispatch_mode_input("/", state) do
    results = Library.search("")
    render_and_reply(%{state | mode: :search, query: "", results: results, selected: 0})
  end
  defp dispatch_mode_input(" ", state) do
    Player.toggle(state.user_id)
    {:noreply, state}
  end
  defp dispatch_mode_input("n", state) do
    Player.skip(state.user_id)
    {:noreply, state}
  end
  defp dispatch_mode_input("+", state) do
    Player.set_volume(state.user_id, state.player_state.volume + 5)
    {:noreply, state}
  end
  defp dispatch_mode_input("-", state) do
    Player.set_volume(state.user_id, state.player_state.volume - 5)
    {:noreply, state}
  end
  defp dispatch_mode_input(_other, state), do: {:noreply, state}

  defp seek_from_click(%{progress_rect: nil} = state, _col, _row), do: state
  defp seek_from_click(state, col, row) do
    {bar_row, bar_col, bar_width} = state.progress_rect
    duration = state.player_state.now_info && state.player_state.now_info[:duration]

    # Calculate click relative to the start of the bar
    offset = col - bar_col

    if row == bar_row and is_number(duration) and duration > 0 and offset >= 0 and offset < bar_width do
      # Calculate percentage (0.0 to 1.0) and seek
      percent = offset / (bar_width - 1)
      Player.seek(state.user_id, percent * duration)
    end

    state
  end

  # --- Search Logic ---

  defp handle_search_input("\r", state), do: select_result(state)
  defp handle_search_input("\n", state), do: select_result(state)
  defp handle_search_input("\t", state), do: enqueue_result(state)
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

  # --- Rendering ---

  defp quit(state) do
    send(state.channel_pid, {:session_render, @disable_mouse})
    send(state.channel_pid, {:session_closed, self()})
    {:stop, :normal, state}
  end

  defp render_and_reply(state) do
    state = render(state)
    {:noreply, state}
  end

  defp render(state) do
    {iodata, progress_rect} = frame(state)
    send(state.channel_pid, {:session_render, iodata})
    %{state | progress_rect: progress_rect}
  end

  defp frame(%{player_state: player_state} = state) do
    width = max(state.width, 40)
    height = max(state.height, 14)

    now_row = 4
    now_height = now_playing_height(height)
    lower_row = now_row + now_height + 1
    lower_height = max(height - lower_row - 1, 3)

    {art_width, art_height} = art_dimensions(width, now_height)
    layout = now_playing_layout(now_row, width, art_width, art_height)
    progress_rect = {layout.bar_row, layout.bar_col, layout.bar_width}

    footer = case state.mode do
      :search -> "type to search   ↑/↓ select   enter: play   tab: queue   esc: cancel"
      :normal -> "space: play/pause   n: skip   +/-: volume   /: search   q: quit"
    end

    buffer =
      Buffer.new(width, height)
      |> Buffer.put_string(1, 2, "SSH Audio — #{state.user_id}", [:cyan, :bright])
      |> Buffer.hline(2, 1, width, [:cyan])
      |> render_now_playing(player_state, now_row, width, now_height)

    buffer = case state.mode do
      :search -> render_search(buffer, state, lower_row, width, lower_height)
      :normal -> render_queue(buffer, player_state, lower_row, width, lower_height)
    end

    iodata = buffer
      |> Buffer.put_string(height, 2, footer, [:faint])
      |> Buffer.to_iodata()

    {iodata, progress_rect}
  end

  defp now_playing_height(height) do
    cond do
      height >= 34 -> 18
      height >= 24 -> 13
      height >= 18 -> 10
      true -> 7
    end
  end

  defp art_dimensions(width, height) do
    art_height = height - 2
    max_art_width = max(width - 34, 10)
    art_width = (art_height * 2.2) |> round() |> min(max_art_width) |> max(10)
    {art_width, art_height}
  end

  defp now_playing_layout(row, width, art_width, art_height) do
    art_col = 3
    text_col = art_col + art_width + 2
    text_row = row + 1 + div(max(art_height - 5, 0), 2)
    time_width = 5
    bar_row = text_row + 4
    bar_col = text_col + time_width + 1
    bar_width = max(width - bar_col - time_width - 1, 4)

    %{
      art_col: art_col,
      text_col: text_col,
      text_row: text_row,
      bar_row: bar_row,
      bar_col: bar_col,
      bar_width: bar_width
    }
  end

  defp render_now_playing(buffer, player_state, row, width, height) do
    {status_label, status_style} = case player_state.status do
      :playing -> {"▶ PLAYING", [:green, :bright]}
      :paused -> {"⏸ PAUSED", [:yellow, :bright]}
      :stopped -> {"■ STOPPED", [:red]}
    end

    info = player_state.now_info || %{}
    track = player_state.current
    title = info[:title] || (track && track.display) || "(nothing queued)"
    artist = info[:artist] || (track && track.artist)
    meta_line = Enum.join(Enum.filter([artist, info[:genre]], & &1), " · ")
    format_line = [format_bitrate(info[:bitrate]),format_bitdepth(info[:bitdepth]), format_samplerate(info[:samplerate])]
      |> Enum.filter(& &1)
      |> Enum.join(" · ")

    {art_width, art_height} = art_dimensions(width, height)
    layout = now_playing_layout(row, width, art_width, art_height)

    buffer
    |> Widgets.panel(row, 1, width, height, title: "now playing", style: [:blue])
    |> Widgets.img_preview_data(row + 1, layout.art_col, art_width, art_height, track && track.album_img)
    |> Buffer.put_string(layout.text_row, layout.text_col, status_label, status_style)
    |> Buffer.put_string(layout.text_row, layout.text_col + String.length(status_label) + 3, "vol #{player_state.volume}%", [])
    |> Buffer.put_string(layout.text_row + 1, layout.text_col, title, [:bright])
    |> put_line(layout.text_row + 2, layout.text_col, meta_line, [:faint])
    |> put_line(layout.text_row + 3, layout.text_col, format_line, [:faint])
    |> render_progress(layout, info[:position], info[:duration])
  end

  defp put_line(buffer, _row, _col, "", _style), do: buffer
  defp put_line(buffer, row, col, text, style), do: Buffer.put_string(buffer, row, col, text, style)

  defp render_progress(buffer, layout, position, duration) when is_number(position) and is_number(duration) and duration > 0 do
    ratio = position / duration
    buffer
    |> Buffer.put_string(layout.bar_row, layout.text_col, format_time(position), [:faint])
    |> Widgets.progress_bar(layout.bar_row, layout.bar_col, layout.bar_width, ratio, style: [:cyan])
    |> Buffer.put_string(layout.bar_row, layout.bar_col + layout.bar_width + 1, format_time(duration), [:faint])
  end
  defp render_progress(buffer, _layout, _position, _duration), do: buffer

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
defp format_bitdepth(bitdp) when is_number(bitdp), do: "#{bitdp} bit"
  defp format_bitdepth(_), do: nil
  defp render_queue(buffer, player_state, row, width, height) do
    queue_lines = case Enum.take(player_state.queue, 5) do
      [] -> ["(empty)"]
      tracks -> tracks |> Enum.with_index(1) |> Enum.map(fn {t, i} -> "#{i}. #{t.display}" end)
    end

    buffer
    |> Widgets.panel(row, 1, width, height, title: "queue", style: [:blue])
    |> Widgets.list(row + 1, 3, queue_lines)
  end

  defp render_search(buffer, state, row, width, height) do
    buffer = buffer
      |> Widgets.panel(row, 1, width, height, title: "search", style: [:magenta])
      |> Buffer.put_string(row + 1, 3, "/ #{state.query}▌", [:bright])

    case state.results do
      [] -> Buffer.put_string(buffer, row + 3, 3, "(no matches)", [:faint])
      results ->
        visible = max(height - 4, 0)
        offset = if visible > 0, do: div(state.selected, visible) * visible, else: 0
        queued_paths = MapSet.new(state.player_state.queue, & &1.path)

        results
        |> Enum.slice(offset, visible)
        |> Enum.with_index(offset)
        |> Enum.reduce(buffer, fn {track, i}, buffer ->
          selected? = (i == state.selected)
          queued? = MapSet.member?(queued_paths, track.path)
          style = cond do
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
