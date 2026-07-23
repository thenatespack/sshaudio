# AGENTS.md

## Project overview

This repository contains an Elixir/OTP application that serves a full-screen music player TUI over raw SSH. The app is designed to be used by connecting with SSH directly, without requiring any client software beyond ssh itself.

Key facts:
- The app runs as an Elixir/OTP service with SSH and TUI components.
- Playback state is owned by a per-user Player process, while Session is per-connection and temporary.
- State flows via Phoenix.PubSub rather than shared memory.
- The default playback backend is an mpv-based output sink, but the sink is pluggable via configuration.

## Working conventions

- Prefer small, focused changes that preserve the existing architecture.
- Keep the Session/Player split intact unless a change explicitly requires otherwise.
- Avoid introducing optimistic state updates where the app already relies on querying the sink for authoritative state.
- Preserve existing SSH/TUI behavior and avoid broad refactors without a clear reason.

## Common commands

```bash
mix deps.get
mix test
mix format
iex -S mix
```

## Important implementation notes

- The SSH channel layer is in lib/ssh_audio/ssh/ and handles raw bytes and resize events.
- Session logic lives in lib/ssh_audio/session.ex and is responsible for rendering and input handling.
- Player lifecycle and playback state live in lib/ssh_audio/player.ex and the related supervisor modules.
- Output sink behavior is defined in lib/ssh_audio/output_sink.ex and implemented in lib/ssh_audio/output_sink/server.ex.
- Library scanning and search logic live in lib/ssh_audio/library.ex.

## Testing and verification

- Run relevant tests with mix test after making changes.
- If a change affects playback or terminal rendering, verify it with the closest existing test or a manual smoke check.
- Keep changes compatible with the existing Elixir version and dependency setup from mix.exs.

## Notes for agents

- The app intentionally uses a simple architecture; follow it rather than introducing new abstractions unless necessary.
- Be careful around real audio playback and terminal interaction; changes here can affect user-facing behavior in subtle ways.
- When adding features, prefer keeping behavior deterministic and easy to reason about.
