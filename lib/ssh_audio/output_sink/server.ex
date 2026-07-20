defmodule SSHAudio.OutputSink.Server do
  @moduledoc """
  The "2. Server" output from the connection-flow design: audio plays
  on the machine running SSHAudio itself (home stereo, office speakers,
  an always-on music server), not on the SSH client.

  Shells out to `mpv` via a `Port` — cross-platform (macOS/Linux/Windows,
  wherever mpv is installed) unlike `afplay`. `mpv` is started with
  `--input-ipc-server`, a control socket we connect to over
  `:gen_tcp` (`{:local, path}`) to send `pause`/`volume` commands to the
  running process live, so `set_volume/2` actually takes effect
  immediately instead of only on the next `play/3` call.

  If `mpv` isn't on PATH, `play/3` logs a warning and no-ops instead of
  crashing the Player.
  """

  @behaviour SSHAudio.OutputSink

  require Logger

  defstruct port: nil, os_pid: nil, socket_path: nil, ipc: nil

  @impl true
  def init(_opts), do: {:ok, %__MODULE__{}}

  @impl true
  def play(state, track, volume) do
    state = kill(state)

    case System.find_executable("mpv") do
      nil ->
        Logger.warning("OutputSink.Server: mpv not found on PATH; no audio will play")
        {:ok, state}

      bin ->
        socket_path = ipc_socket_path()

        port =
          Port.open({:spawn_executable, bin}, [
            :binary,
            :exit_status,
            args: [
              "--no-terminal",
              "--really-quiet",
              "--vo=null",
              "--no-video",
              "--input-ipc-server=#{socket_path}",
              "--volume=#{volume}",
              track.path
            ]
          ])

        {:os_pid, os_pid} = Port.info(port, :os_pid)
        ipc = connect_ipc(socket_path, 500)

        {:ok, %{state | port: port, os_pid: os_pid, socket_path: socket_path, ipc: ipc}}
    end
  end

  @impl true
  def pause(state), do: send_command(state, ~s({"command":["set_property","pause",true]}\n))

  @impl true
  def resume(state), do: send_command(state, ~s({"command":["set_property","pause",false]}\n))

  @impl true
  def stop(state), do: {:ok, kill(state)}

  @impl true
  def set_volume(state, volume) do
    send_command(state, ~s({"command":["set_property","volume",#{volume}]}\n))
  end

  @impl true
  def seek(state, position) do
    send_command(state, ~s({"command":["set_property","time-pos",#{position}]}\n))
  end

  @impl true
  def info(%{socket_path: nil} = state), do: {:error, state}

  def info(state) do
    case ensure_ipc(state) do
      {nil, state} ->
        {:error, state}

      {sock, state} ->
        {title, sock} = query(sock, "media-title")
        {metadata, sock} = query(sock, "metadata")
        {audio_params, sock} = query(sock, "audio-params")
        {bitrate, sock} = query(sock, "audio-bitrate")
        {position, sock} = query(sock, "time-pos")
        {duration, sock} = query(sock, "duration")

        info = %{
          title: title,
          artist: meta_lookup(metadata, "artist"),
          genre: meta_lookup(metadata, "genre"),
          bitrate: bitrate,
          samplerate: if(is_map(audio_params), do: audio_params["samplerate"]),
          bitdepth: audio_bitdepth(audio_params),
          position: position,
          duration: duration
        }

        {:ok, info, %{state | ipc: sock}}
    end
  end

  defp audio_bitdepth(%{"format" => format}) do
    case format do
      "u8" -> 8
      "s16" -> 16
      "s24" -> 24
      "s32" -> 32
      "float" -> 32
      _ -> nil
    end
  end

  defp audio_bitdepth(_), do: nil

  defp meta_lookup(metadata, key) when is_map(metadata) do
    case Enum.find(metadata, fn {k, _v} -> String.downcase(k) == key end) do
      {_k, v} -> v
      nil -> nil
    end
  end

  defp meta_lookup(_metadata, _key), do: nil

  # Queries a single property on an already-connected socket. Doesn't
  # attempt to reconnect — if the socket dies mid-batch the remaining
  # properties in this `info/1` call just come back `nil`, and the
  # next tick's `ensure_ipc/1` reconnects fresh.
  defp query(nil, _name), do: {nil, nil}

  defp query(sock, name) do
    payload = JSON.encode!(%{command: ["get_property", name]}) <> "\n"

    with :ok <- :gen_tcp.send(sock, payload),
         {:ok, data} <- :gen_tcp.recv(sock, 0, 150),
         {:ok, %{"error" => "success", "data" => value}} <- JSON.decode(data) do
      {value, sock}
    else
      {:error, _reason} ->
        safe_close_ipc(sock)
        {nil, nil}

      _other ->
        {nil, sock}
    end
  end

  @impl true
  def handle_message(%{port: port} = state, {port, {:exit_status, _status}}) do
    {:done, %{state | port: nil, os_pid: nil, socket_path: nil, ipc: nil}}
  end

  def handle_message(%{port: port} = state, {port, {:data, _data}}), do: {:ignore, state}

  def handle_message(_state, _other), do: :ignore

  defp send_command(%{socket_path: nil} = state, _payload), do: {:ok, state}

  defp send_command(state, payload) do
    case ensure_ipc(state) do
      {nil, state} ->
        {:ok, state}

      {sock, state} ->
        case :gen_tcp.send(sock, payload) do
          :ok ->
            {:ok, %{state | ipc: sock}}

          {:error, _reason} ->
            safe_close_ipc(sock)
            {:ok, %{state | ipc: nil}}
        end
    end
  end

  defp ensure_ipc(%{ipc: sock} = state) when not is_nil(sock), do: {sock, state}

  defp ensure_ipc(%{socket_path: socket_path} = state) do
    case connect_ipc(socket_path, 200) do
      nil -> {nil, state}
      sock -> {sock, %{state | ipc: sock}}
    end
  end

  defp connect_ipc(socket_path, timeout_ms), do: connect_ipc(socket_path, timeout_ms, 10)

  defp connect_ipc(_socket_path, remaining_ms, _interval_ms) when remaining_ms <= 0, do: nil

  defp connect_ipc(socket_path, remaining_ms, interval_ms) do
    case :gen_tcp.connect({:local, socket_path}, 0, [:binary, active: false]) do
      {:ok, sock} ->
        sock

      {:error, _reason} ->
        Process.sleep(interval_ms)
        connect_ipc(socket_path, remaining_ms - interval_ms, interval_ms)
    end
  end

  defp kill(%{port: nil} = state), do: state

  defp kill(state) do
    state = quit_mpv(state)

    safe_close_port(state.port)

    if state.socket_path do
      File.rm(state.socket_path)
    end

    %__MODULE__{}
  end

  defp safe_close_port(port) do
    Port.close(port)
  rescue
    ArgumentError -> :ok
  end

  defp safe_close_ipc(sock), do: :gen_tcp.close(sock)

  defp ipc_socket_path do
    Path.join(System.tmp_dir!(), "sshaudio-mpv-#{:erlang.unique_integer([:positive])}.sock")
  end

  defp quit_mpv(%{ipc: nil} = state), do: state

  defp quit_mpv(%{ipc: ipc} = state) do
    IO.puts("quit mpv")
    _ = :gen_tcp.send(ipc, ~s({"command":["quit"]}\n))
    safe_close_ipc(ipc)

    %{state | ipc: nil}
  end
end
