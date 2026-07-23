defmodule SSHAudio.Application do
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    port = Application.get_env(:sshaudio, :ssh_port, 2222)

    library_path =
      Application.get_env(:sshaudio, :library_path) || System.get_env("SSHAUDIO_LIBRARY_PATH")

    children = [
      {Registry, keys: :unique, name: SSHAudio.Registry},
      {Phoenix.PubSub, name: SSHAudio.PubSub},
      {SSHAudio.Library, path: library_path},
      SSHAudio.PlayerSupervisor,
      SSHAudio.SessionSupervisor,
      {SSHAudio.SSH.Daemon, port: port}
    ]

    opts = [strategy: :one_for_one, name: SSHAudio.Supervisor]
    {:ok, _supervisor} = Supervisor.start_link(children, opts)

    if library_path do
      Task.start(fn -> SSHAudio.Library.scan_and_update(library_path) end)
    end

    {:ok, self()}
  end
end
