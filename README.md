# SSHAudio

A terminal-native music platform. There's no app to install — you connect
straight into a full-screen player over SSH:

```bash
ssh music@domain.com
```

Playback lives in OTP processes, not in the connection. Disconnect and
reconnect, and your queue and player state are still there.

## Architecture

```
SSH Client
    │
SSH Server (:ssh daemon, custom channel — SSHAudio.SSH.Channel)
    │
Session Process (SSHAudio.Session — one per connection: input + rendering)
    │
Player API (SSHAudio.Player)
    │
Player GenServer (playback, queue, volume, repeat, shuffle — survives disconnects)
    │
Music backend (not yet implemented)
```

- **`SSHAudio.SSH.Channel`** — the only module that speaks the SSH connection
  protocol directly. Handles pty/shell/data/window-change requests and just
  forwards bytes between the client and a `Session`.
- **`SSHAudio.SSH.HostKeys`** — loads the daemon's host key from
  `priv/ssh/ssh_host_rsa_key`, generating one on first boot if it's missing.
  Keeps the fingerprint stable across restarts.
- **`SSHAudio.SSH.Daemon`** — supervises the `:ssh.daemon/2` listener.
- **`SSHAudio.Session`** — one GenServer per SSH connection. Subscribes to its
  player's PubSub topic, renders the full-screen ANSI frame, and turns
  keypresses into `Player` API calls.
- **`SSHAudio.Player`** — one GenServer per user (via `Registry`), owns queue,
  current track, volume, repeat, shuffle. Broadcasts every change over
  `Phoenix.PubSub` so all attached sessions stay in sync. Outlives any single
  session.
- **`SSHAudio.PlayerSupervisor` / `SSHAudio.SessionSupervisor`** —
  `DynamicSupervisor`s that start players and sessions on demand.
- **`SSHAudio.Library`** — scans a directory tree once at boot for music
  files (`.mp3`, `.flac`, `.wav`, `.ogg`, `.m4a`, `.aac`, `.opus`, `.wma`,
  `.aiff`), guessing artist/title from `Artist - Title.ext` filenames since
  no tag parsing is wired up yet. Holds the result in memory and serves
  substring search queries against it; `set_path/1` rescans a different
  directory at runtime.

## Running it

```bash
mix deps.get
mix run --no-halt
```

Then, in another terminal:

```bash
ssh music@localhost -p 2222
```

Any username/password is accepted — this is a kiosk-style app, not a shell
login. Once connected:

| Key       | Action       |
|-----------|--------------|
| `space`   | play / pause |
| `n`       | skip         |
| `+` / `-` | volume       |
| `/`       | search       |
| `q`       | quit         |

Inside search: type to filter, `↑`/`↓` to move the selection, `enter` to
play the selected track, `esc` to cancel.

The listen port defaults to `2222` and can be overridden via
`config :sshaudio, :ssh_port, <port>`.

The music library path is unset by default (no tracks to search) and can be
set via `config :sshaudio, :library_path, <path>` or the `SSHAUDIO_LIBRARY_PATH`
environment variable, e.g.:

```bash
SSHAUDIO_LIBRARY_PATH=~/Music mix run --no-halt
```

## Current status

Initial scaffold: SSH transport, session/player process model, and PubSub
sync all work end-to-end. There is no real music backend yet (`Player` holds
queue/state but doesn't decode or stream audio), and no persistence.

## Known limitations

- **`mix test` boots the real SSH daemon** on port 2222, since nothing
  disables it for the test environment yet.

## Roadmap

- Shared listening rooms (`Room` GenServer)
- Presence (who's listening)
- Chat
- Playlists
- Remote control from multiple devices
- Web/LiveView client reusing the same `Player`/`Room` backend
