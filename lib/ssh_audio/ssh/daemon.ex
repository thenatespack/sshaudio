defmodule SSHAudio.SSH.Daemon do
  @moduledoc """
  Boots the `:ssh` daemon and wraps it as a supervised child, so a
  daemon crash restarts under the app's supervisor instead of quietly
  leaving the port unbound.

  Auth is wide open by design for now (any password is accepted) —
  this is a kiosk-style app, not a shell login. Revisit before
  exposing this on a public host.
  """

  use GenServer

  require Logger

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    port = Keyword.fetch!(opts, :port)

    daemon_opts = [
      key_cb: {SSHAudio.SSH.HostKeys, []},
      pwdfun: fn _user, _password -> true end,
      ssh_cli: {SSHAudio.SSH.Channel, []},
      subsystems: []
    ]

    case :ssh.daemon(port, daemon_opts) do
      {:ok, ref} ->
        Logger.info("SSHAudio listening on port #{port} — try `ssh music@localhost -p #{port}`")
        {:ok, %{ref: ref}}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def terminate(_reason, %{ref: ref}) do
    :ssh.stop_daemon(ref)
  end
end
