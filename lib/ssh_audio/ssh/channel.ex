defmodule SSHAudio.SSH.Channel do
  @moduledoc """
  Raw SSH channel: the only piece of this app that speaks the SSH
  connection protocol directly. It never renders anything or knows
  about players — it just forwards bytes between the client and a
  Session process, so the Session can be tested and reasoned about
  without an SSH connection in the loop.
  """

  @behaviour :ssh_server_channel

  alias SSHAudio.SessionSupervisor

  @shared_player_id "shared"

  defstruct [:channel_id, :conn_ref, :session_pid]

  @impl true
  def init(_args), do: {:ok, %__MODULE__{}}

  @impl true
  def handle_msg({:ssh_channel_up, channel_id, conn_ref}, state) do
    {:ok, %{state | channel_id: channel_id, conn_ref: conn_ref}}
  end

  def handle_msg({:session_render, iodata}, state) do
    :ssh_connection.send(state.conn_ref, state.channel_id, IO.iodata_to_binary(iodata))
    {:ok, state}
  end

  def handle_msg({:session_closed, _session_pid}, state) do
    :ssh_connection.send(state.conn_ref, state.channel_id, "\r\n")
    {:stop, state.channel_id, state}
  end

  def handle_msg({:DOWN, _ref, :process, pid, _reason}, %{session_pid: pid} = state) do
    {:stop, state.channel_id, state}
  end

  def handle_msg(_msg, state), do: {:ok, state}

  @impl true
  def handle_ssh_msg(
        {:ssh_cm, conn_ref, {:pty, channel_id, want_reply, {_term, width, height, _pw, _ph, _modes}}},
        state
      ) do
    :ssh_connection.reply_request(conn_ref, want_reply, :success, channel_id)
    {:ok, %{state | session_pid: ensure_session(state, width, height)}}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:shell, channel_id, want_reply}}, state) do
    :ssh_connection.reply_request(conn_ref, want_reply, :success, channel_id)
    {:ok, %{state | session_pid: ensure_session(state, 80, 24)}}
  end

  def handle_ssh_msg({:ssh_cm, conn_ref, {:exec, channel_id, want_reply, _cmd}}, state) do
    :ssh_connection.reply_request(conn_ref, want_reply, :failure, channel_id)

    :ssh_connection.send(
      conn_ref,
      channel_id,
      "ssh_audio is a full-screen app; connect without a command, e.g. `ssh music@host`.\r\n"
    )

    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:window_change, _channel_id, width, height, _pw, _ph}}, state) do
    if state.session_pid, do: send(state.session_pid, {:resize, width, height})
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:data, _channel_id, _type, data}}, state) do
    if state.session_pid, do: send(state.session_pid, {:input, data})
    {:ok, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, {:eof, channel_id}}, state) do
    {:stop, channel_id, state}
  end

  def handle_ssh_msg({:ssh_cm, _conn_ref, _other}, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    if state.session_pid, do: send(state.session_pid, :channel_closed)
    :ok
  end

  defp ensure_session(%{session_pid: nil}, width, height) do
    user_id = shared_player_id()
    {:ok, pid} = SessionSupervisor.start_session(self(), user_id, width, height)
    Process.monitor(pid)
    pid
  end

  defp ensure_session(%{session_pid: pid}, _width, _height), do: pid

  def shared_player_id, do: @shared_player_id
end
