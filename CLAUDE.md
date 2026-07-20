# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

An Elixir/OTP app that serves a full-screen music player TUI directly over
raw SSH — connect with `ssh music@host -p 2222` and get search, a queue,
and a mouse-clickable seekbar, no client software beyond `ssh` itself.
Auth is intentionally wide open (any password accepted); see README.md
for the full feature list, controls, and config.

## Commands

```
mix deps.get                          # fetch deps (only phoenix_pubsub)
export SSHAUDIO_LIBRARY_PATH=/path/to/music
iex -S mix                            # run the app; SSH daemon on :2222 (or $SSHAUDIO_LIBRARY_PATH-configured port)
mix test                              # run the test suite
mix test test/some_test.exs:42        # run a single test by file:line
mix format                            # format per .formatter.exs
```

There is no lint/typecheck task configured beyond `mix format` and
ElixirLS/Dialyzer diagnostics surfaced in-editor. `test/manual_mpv_check.exs`
is a standalone manual script (not part of `mix test`) for sanity-checking
the `mpv` IPC integration directly — run it with `mix run test/manual_mpv_check.exs`
against a real audio file path.

Runtime dependencies on `PATH`: `mpv` (required, actually plays audio),
`ffprobe`/`ffmpeg` (optional, tag reading + embedded album art — falls
back to filename-based `Artist - Title` guessing and no art if absent).

## Architecture

Byte flow for one connection:

```
SSH client
   │  raw bytes, ssh connection protocol
   ▼
SSHAudio.SSH.Channel        — :ssh_server_channel; forwards bytes only, never renders
   │  {:input, data} / {:resize, w, h}
   ▼
SSHAudio.Session            — one per connection; owns rendering + input handling
   │  Player.play/pause/seek/... (GenServer.cast)      ▲ {:player_state, state} via Phoenix.PubSub
   ▼                                                     │
SSHAudio.Player              — one per user_id; outlives session disconnects
   │  sink_mod callbacks (play/pause/seek/info/handle_message/...)
   ▼
SSHAudio.OutputSink.Server   — wraps `mpv` as a Port + IPC unix socket
```

Key structural decisions, since they explain why the code is split this way:

- **Session vs. Player is a deliberate lifecycle split.** `Session`
  (`lib/ssh_audio/session.ex`) is per-connection and temporary — dies when
  the SSH channel closes, restart: `:temporary` under `SessionSupervisor`.
  `Player` (`lib/ssh_audio/player.ex`) is per-`user_id`, looked up via
  `Registry` (`SSHAudio.PlayerSupervisor.ensure_started/1`), and keeps
  running after disconnect so playback state (queue, volume, current
  track, position) survives a dropped SSH connection. Reconnecting attaches
  a fresh `Session` to the same `Player`.
- **State propagates one-way via PubSub, not shared memory.** `Player`
  broadcasts `{:player_state, state}` on topic `"player:#{user_id}"`
  after every mutation (`broadcast/1` in player.ex); `Session` subscribes
  once at init and re-renders its whole frame on every message. `Session`
  never reads `Player`'s state directly except once at init via
  `Player.get_state/1` (a synchronous call).
- **`SSHAudio.OutputSink` is a behaviour, not a hard dependency on mpv.**
  `Player` only calls sink callbacks and holds an opaque `sink_state` —
  it has no idea `mpv` is involved. `SSHAudio.OutputSink.Server`
  (`lib/ssh_audio/output_sink/server.ex`) is the only implementation:
  spawns `mpv` as a `Port` with `--input-ipc-server`, then talks to it
  live over that unix socket via `:gen_tcp` for pause/seek/volume/info
  queries. Swapping in a different playback target (AirPlay, Chromecast,
  Spotify Connect) means implementing the behaviour, not touching `Player`.
  The sink module is configurable via `config :sshaudio, :output_sink`
  (defaults to `SSHAudio.OutputSink.Server`) — this is the seam tests
  use to fake playback without shelling out to real `mpv`.
- **Position/duration are polled, not pushed.** `Player` self-schedules
  a `:tick` every 1s while `status == :playing` and calls `sink_mod.info/1`
  to refresh `now_info` (position, duration, title/artist/genre, audio
  format) for the progress bar — mpv's IPC protocol here is simple
  request/reply, not an event stream. On an explicit seek, `Player`
  re-queries `sink_mod.info/1` immediately afterward rather than
  optimistically guessing the new position, specifically to avoid the
  progress bar visibly jumping twice (once to a guess, once to the
  real value) — don't reintroduce an optimistic position patch here.
- **Sessions don't own a real tty.** Since SSH channel bytes are just
  forwarded (`SSHAudio.SSH.Channel` never touches terminal state itself),
  each `Session` builds its own virtual screen via `SSHAudio.TUI.Buffer`
  (a grid of styled cells) and widgets in `SSHAudio.TUI.Widgets`, then
  flattens to ANSI iodata once per render — this is why a termbox-based
  library like Ratatouille isn't used; there's no single owned terminal.
  Mouse support (click-to-seek) is hand-rolled SGR mouse mode parsing in
  `Session.handle_mouse_input/2`, not a library feature.
- **`SSHAudio.Library`** is a single GenServer holding the entire scanned
  track list in memory (`scan/1` walks `library_path` for known audio
  extensions, tags via `ffprobe`, falls back to filename parsing). Search
  is a case-insensitive substring filter over that in-memory list, not a
  persisted index — rescans happen via `set_path/1`.
