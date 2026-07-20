defmodule SSHAudio.Player do
  @moduledoc """
  Owns playback state for one user: queue, current track, volume,
  repeat, shuffle. Independent of any SSH session — a session attaches
  to a player, and a player keeps running after the session disconnects.
  """

  use GenServer

  # How often we poll the sink for time-pos/duration while playing, to
  # drive the session's progress bar. Kept out of the sink's own hands
  # since only the Player knows when playback starts/stops.
  @tick_interval 1_000

  defstruct [
    :user_id,
    :sink_mod,
    :sink_state,
    status: :stopped,
    current: nil,
    queue: [],
    volume: 100,
    repeat: :off,
    shuffle: false,
    now_info: nil,
    ticking: false
  ]

  # Client API

  def start_link(user_id) do
    GenServer.start_link(__MODULE__, user_id, name: via(user_id))
  end

  def via(user_id), do: {:via, Registry, {SSHAudio.Registry, {:player, user_id}}}

  def topic(user_id), do: "player:#{user_id}"

  def get_state(user_id), do: GenServer.call(via(user_id), :get_state)

  def play(user_id, track), do: GenServer.cast(via(user_id), {:play, track})
  def toggle(user_id), do: GenServer.cast(via(user_id), :toggle)
  def pause(user_id), do: GenServer.cast(via(user_id), :pause)
  def resume(user_id), do: GenServer.cast(via(user_id), :resume)
  def skip(user_id), do: GenServer.cast(via(user_id), :skip)
  def enqueue(user_id, track), do: GenServer.cast(via(user_id), {:enqueue, track})
  def set_volume(user_id, volume), do: GenServer.cast(via(user_id), {:set_volume, volume})
  def seek(user_id, position), do: GenServer.cast(via(user_id), {:seek, position})

  # Server callbacks

  @impl true
  def init(user_id) do
    sink_mod = Application.get_env(:sshaudio, :output_sink, SSHAudio.OutputSink.Server)
    {:ok, sink_state} = sink_mod.init([])
    {:ok, %__MODULE__{user_id: user_id, sink_mod: sink_mod, sink_state: sink_state}}
  end

  @impl true
  def handle_call(:get_state, _from, state), do: {:reply, state, state}

  @impl true
  def handle_cast({:play, track}, state) do
    {:ok, sink_state} = state.sink_mod.play(state.sink_state, track, state.volume)

    state = %{
      state
      | sink_state: sink_state,
        current: track,
        status: :playing,
        now_info: nil,
        ticking: false
    }

    {:noreply, broadcast(maybe_schedule_tick(state))}
  end

  def handle_cast(:toggle, %{status: :playing} = state) do
    {:ok, sink_state} = state.sink_mod.pause(state.sink_state)
    {:noreply, broadcast(%{state | sink_state: sink_state, status: :paused, ticking: false})}
  end

  def handle_cast(:toggle, %{status: :paused} = state) do
    {:ok, sink_state} = state.sink_mod.resume(state.sink_state)
    state = %{state | sink_state: sink_state, status: :playing, ticking: false}
    {:noreply, broadcast(maybe_schedule_tick(state))}
  end

  def handle_cast(:toggle, %{status: :stopped, queue: [next | rest]} = state) do
    {:ok, sink_state} = state.sink_mod.play(state.sink_state, next, state.volume)

    state = %{
      state
      | sink_state: sink_state,
        status: :playing,
        current: next,
        queue: rest,
        now_info: nil,
        ticking: false
    }

    {:noreply, broadcast(maybe_schedule_tick(state))}
  end

  def handle_cast(:toggle, state), do: {:noreply, state}

  def handle_cast(:pause, state) do
    {:ok, sink_state} = state.sink_mod.pause(state.sink_state)
    {:noreply, broadcast(%{state | sink_state: sink_state, status: :paused, ticking: false})}
  end

  def handle_cast(:resume, state) do
    {:ok, sink_state} = state.sink_mod.resume(state.sink_state)
    state = %{state | sink_state: sink_state, status: :playing, ticking: false}
    {:noreply, broadcast(maybe_schedule_tick(state))}
  end

  def handle_cast(:skip, state), do: {:noreply, broadcast(advance(state))}

  def handle_cast({:enqueue, track}, %{status: :stopped, current: nil} = state) do
    state = %{state | queue: state.queue ++ [track]}
    {:noreply, broadcast(advance(state))}
  end

  def handle_cast({:enqueue, track}, state) do
    {:noreply, broadcast(%{state | queue: state.queue ++ [track]})}
  end

  def handle_cast({:set_volume, volume}, state) do
    volume = clamp(volume)
    {:ok, sink_state} = state.sink_mod.set_volume(state.sink_state, volume)
    {:noreply, broadcast(%{state | sink_state: sink_state, volume: volume})}
  end

  def handle_cast({:seek, _position}, %{current: nil} = state), do: {:noreply, state}

  def handle_cast({:seek, position}, state) do
    {:ok, sink_state} = state.sink_mod.seek(state.sink_state, position)

    # Query mpv for the post-seek position. If mpv returns nil/empty fields
    # mid-seek (due to cache flush during IPC), retain previous valid `now_info`
    # instead of broadcasting `nil` to prevent UI progress bar flickering.
    {info, sink_state} = fetch_valid_info(state.sink_mod, sink_state, state.now_info)

    {:noreply, broadcast(%{state | sink_state: sink_state, now_info: info})}
  end

  @impl true
  def handle_info(:tick, %{status: :playing} = state) do
    state = %{state | ticking: false}

    {info, sink_state} = fetch_valid_info(state.sink_mod, state.sink_state, state.now_info)

    state = maybe_schedule_tick(%{state | sink_state: sink_state, now_info: info})
    {:noreply, broadcast(state)}
  end

  def handle_info(:tick, state), do: {:noreply, %{state | ticking: false}}

  def handle_info(msg, state) do
    case state.sink_mod.handle_message(state.sink_state, msg) do
      {:done, sink_state} -> {:noreply, broadcast(advance(%{state | sink_state: sink_state}))}
      _other -> {:noreply, state}
    end
  end

  @impl true
  def terminate(_reason, state) do
    {:ok, _sink_state} = state.sink_mod.stop(state.sink_state)
    :ok
  end

  # Shared by `skip` and by the sink reporting the current track ended
  # on its own — both mean "move to whatever's next in the queue".
  defp advance(%{queue: [next | rest]} = state) do
    {:ok, sink_state} = state.sink_mod.play(state.sink_state, next, state.volume)

    maybe_schedule_tick(%{
      state
      | sink_state: sink_state,
        current: next,
        queue: rest,
        status: :playing,
        now_info: nil,
        ticking: false
    })
  end

  defp advance(state) do
    {:ok, sink_state} = state.sink_mod.stop(state.sink_state)

    %{
      state
      | sink_state: sink_state,
        current: nil,
        status: :stopped,
        now_info: nil,
        ticking: false
    }
  end

  defp maybe_schedule_tick(%{status: :playing, ticking: false} = state) do
    Process.send_after(self(), :tick, @tick_interval)
    %{state | ticking: true}
  end


  # Helper to safely query sink info without overwriting current info when mpv
  # temporarily returns empty metadata during seeks/buffering.
  defp fetch_valid_info(sink_mod, sink_state, fallback_info) do
    case sink_mod.info(sink_state) do
      {:ok, %{position: nil}, sink_state} -> {fallback_info, sink_state}
      {:ok, nil, sink_state} -> {fallback_info, sink_state}
      {:ok, info, sink_state} -> {info, sink_state}
      {:error, sink_state} -> {fallback_info, sink_state}
    end
  end

  defp clamp(v), do: v |> max(0) |> min(100)

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(SSHAudio.PubSub, topic(state.user_id), {:player_state, state})
    state
  end
end
