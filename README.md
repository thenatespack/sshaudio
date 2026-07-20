# SSH Audio

A music player you `ssh` into. Connect from any terminal and get a
full-screen TUI with search, a queue, and a mouse-clickable seekbar —
no client software beyond `ssh` itself.

```
ssh music@localhost -p 2222
```

Any username/password is accepted (it's a kiosk, not a login system) —
each connection gets its own session attached to a per-user player, so
multiple people can connect and each has their own queue/volume/playback
state.

## Features

- Full-screen terminal UI rendered over the raw SSH channel (no
  external TUI client, no PTY assumptions beyond ANSI + SGR mouse mode)
- Fuzzy-ish substring search across your music library
- Play/pause, skip, volume, and a queue
- Mouse-clickable progress bar to seek
- Album art rendered inline in the terminal (from embedded cover art)
- Per-user playback state that survives SSH disconnects — reconnect
  and you're back where you left off
- Pluggable output — audio currently plays via `mpv` on the machine
  running the server (home stereo, office speakers, always-on music
  box), with the sink abstracted so other targets (AirPlay, Chromecast,
  Spotify Connect, ...) can be added later

## Requirements

- Elixir ~> 1.19
- [`mpv`](https://mpv.io/) on `PATH` — used to actually play audio
- [`ffmpeg`/`ffprobe`](https://ffmpeg.org/) on `PATH` (optional) — used
  to read tag metadata and extract embedded album art; without them,
  tracks fall back to filename-based title/artist guessing and no art

## Running it

```
export SSHAUDIO_LIBRARY_PATH=/path/to/your/music
mix deps.get
iex -S mix
```

This starts the SSH daemon on port `2222` (configurable, see below) and
scans `SSHAUDIO_LIBRARY_PATH` for music files
(`.mp3 .flac .wav .ogg .m4a .aac .opus .wma .aiff`). Connect with:

```
ssh music@localhost -p 2222
```

A host key is generated on first boot and persisted under
`priv/ssh/ssh_host_rsa_key`, so the fingerprint stays stable across
restarts.

### Configuration

| Setting | Env var | Config | Default |
| --- | --- | --- | --- |
| SSH port | — | `config :sshaudio, :ssh_port` | `2222` |
| Music library path | `SSHAUDIO_LIBRARY_PATH` | `config :sshaudio, :library_path` | none |
| SSH host key directory | — | `config :sshaudio, :ssh_host_key_dir` | `priv/ssh` |

## Controls

**Normal mode**

| Key | Action |
| --- | --- |
| `space` | Play/pause |
| `n` | Skip to next queued track |
| `+` / `-` | Volume up/down |
| `/` | Open search |
| click on progress bar | Seek |
| `q` / `Ctrl-C` | Quit |

**Search mode**

| Key | Action |
| --- | --- |
| type | Filter results |
| `↑` / `↓` | Move selection |
| `enter` | Play selected track now |
| `tab` | Add selected track to queue |
| `esc` | Cancel search |

## Architecture

```
SSH client
   │  (raw bytes over the ssh connection protocol)
   ▼
SSHAudio.SSH.Channel        — speaks :ssh_server_channel, forwards bytes only
   │  {:input, data} / {:resize, w, h}
   ▼
SSHAudio.Session            — one per connection; renders the TUI, handles input
   │  Player.play/pause/seek/... (GenServer.cast)      ▲ {:player_state, state} (PubSub)
   ▼                                                     │
SSHAudio.Player              — one per user_id; survives session disconnects
   │  sink_mod callbacks (play/pause/seek/info/...)
   ▼
SSHAudio.OutputSink.Server   — wraps `mpv` as a Port + IPC socket
```

- **`SSHAudio.Library`** scans `library_path` for music files, reads
  tags via `ffprobe` (falling back to filename parsing), and serves
  `search/1`.
- **`SSHAudio.Player`** is a per-user GenServer (via `Registry` +
  `PlayerSupervisor`) holding queue/volume/current track/playback
  status. It polls the output sink for position/duration on a tick
  while playing and broadcasts state changes over `Phoenix.PubSub`.
- **`SSHAudio.OutputSink`** is a behaviour describing wherever audio
  actually comes out. `SSHAudio.OutputSink.Server` is the only
  implementation so far — it shells out to `mpv` and controls it live
  via its `--input-ipc-server` control socket. Swapping in a different
  sink (e.g. AirPlay) means implementing the behaviour, not touching
  `Player`.
- **`SSHAudio.Session`** owns rendering and input handling for one
  connection, drawing the TUI via `SSHAudio.TUI.Buffer`/`Widgets` and
  driving its `Player` through its public API.
- **`SSHAudio.SSH.Channel`** is the only module that speaks the `:ssh`
  connection protocol directly; it just forwards bytes to/from a
  `Session`, so `Session` can be exercised without a real SSH
  connection in the loop.

## Development

```
mix test
```

`test/manual_mpv_check.exs` is a manual script (not part of the
automated suite) for sanity-checking the `mpv` IPC integration directly.

## Security note

Authentication is intentionally open (`pwdfun` accepts any
username/password) — this is meant to run on a trusted network as a
kiosk-style shared player, not as a general-purpose login shell.
Revisit `SSHAudio.SSH.Daemon` before exposing this on a public host.
