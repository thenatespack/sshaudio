defmodule SSHAudio.SessionSupervisor do
  @moduledoc """
  Starts one Session process per SSH connection. Sessions are
  temporary: if one crashes, the SSH channel that owns it is
  responsible for noticing (via monitor) and closing the connection,
  not for being restarted in place.
  """

  use DynamicSupervisor

  def start_link(init_arg), do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  def start_session(channel_pid, user_id, width, height) do
    spec = %{
      id: SSHAudio.Session,
      start: {SSHAudio.Session, :start_link, [{channel_pid, user_id, width, height}]},
      restart: :temporary
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end
end
