# Changelog

All notable changes to this project will be documented in this file.

## [0.1.0] - 2026-03-07

Initial public release.

Highlights:

- high-level `vtol.Client` API for authentication, session restore, messaging, media transfer, peer resolution, and update handling
- generated `vtol.tl` layer for direct MTProto and Telegram API access when higher-level helpers are not enough
- session backends for in-memory, string, and SQLite persistence
- runnable examples plus reference docs covering quick start, auth, peers, messages, updates, and raw API usage
