defmodule SSHAudio.PlayerSupervisor do
  @moduledoc """
  Starts and looks up Player GenServers on demand, one per user_id.
  Players are looked up by Registry key, so multiple sessions can
  attach to the same player.
  """

  use DynamicSupervisor

  def start_link(init_arg), do: DynamicSupervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg), do: DynamicSupervisor.init(strategy: :one_for_one)

  def ensure_started(user_id) do
    case DynamicSupervisor.start_child(__MODULE__, {SSHAudio.Player, user_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      other -> other
    end
  end
end
