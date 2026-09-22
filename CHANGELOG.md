# Changelog

## Unreleased

- Snapshot macOS window layouts to JSON: displays, Spaces (including fullscreen
  and Split View), space order, and per-window frames.
- Restore snapshots in phases with `--dry-run`, per-phase opt-outs, and a
  SIP-safe bridged WindowServer space move, with Mission Control drag and app
  relaunch fallbacks.
- Match saved windows to live ones by app, bundle id, and fuzzy title;
  optionally launch apps whose windows are gone and remap missing displays.
- Diagnostics: `doctor` for permissions and settings, `list` for the current
  layout, `dump` and `inspect-mc` for debugging.
- Zero-dependency pure-stdlib implementation over ctypes; offline test suite
  with the native layer mocked.
- Add local build and release tooling, CI, draft zipapp releases, dependency
  updates, and GLM PR review.
