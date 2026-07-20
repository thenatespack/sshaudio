defmodule SSHAudio.OutputSink do
  @moduledoc """
  Behaviour for wherever a Player's audio actually comes out — the
  "OutputSink" from the connection-flow design (LocalStream, ServerAudio,
  SpotifyConnect, AirPlay, Chromecast, ...). A Player only ever calls
  these callbacks and holds onto whatever opaque `state` they return; it
  never knows how playback is actually happening, so new sinks can be
  added without touching `SSHAudio.Player`.

  `handle_message/2` exists because a sink may need to receive messages
  in its owning process's mailbox (e.g. a `Port`'s `{:exit_status, _}`)
  to know when a track finishes on its own. The Player forwards any
  message it doesn't otherwise recognize to the sink; `:ignore` means
  the message wasn't relevant, `{:done, state}` tells the Player the
  current track ended so it should advance to the next one.
  """

  alias SSHAudio.Library.Track

  @type state :: term()

  @type info :: %{
          title: String.t() | nil,
          artist: String.t() | nil,
          genre: String.t() | nil,
          bitrate: number() | nil,
          samplerate: number() | nil,
          position: number() | nil,
          duration: number() | nil
        }

  @callback init(opts :: keyword()) :: {:ok, state()}
  @callback play(state(), Track.t(), volume :: 0..100) :: {:ok, state()}
  @callback pause(state()) :: {:ok, state()}
  @callback resume(state()) :: {:ok, state()}
  @callback stop(state()) :: {:ok, state()}
  @callback set_volume(state(), 0..100) :: {:ok, state()}
  @callback handle_message(state(), term()) :: :ignore | {:done, state()}

  @doc """
  Reads back live info about whatever's currently loaded: tag metadata
  and audio format from the file itself, plus playback position — all
  values default to `nil` when the sink has nothing playing or can't
  be reached.
  """
  @callback info(state()) :: {:ok, info(), state()} | {:error, state()}
end
