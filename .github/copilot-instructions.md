# GitHub Copilot instructions

This repository is an Elixir/OTP SSH music player. Follow the architecture described in AGENTS.md and preserve the existing Session/Player separation, PubSub-driven state updates, and sink abstraction.

Prefer minimal changes, keep the UI and SSH behavior stable, and validate changes with mix test and mix format.
