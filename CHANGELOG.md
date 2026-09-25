# Changelog

## Unreleased

- Rewrite Rememoru as a native Swift menu bar app, replacing the Python
  tool and the AppleScript login helper (whose unanswered dialogs caused
  "AppleEvent timed out (-1712)" at login). Save and restore from the
  menu; restore at login through a real login item; permissions belong
  to Rememoru.app itself; every restore step is verified and logged.
- Fix window-to-space attribution: `SLSCopySpacesForWindows` is now
  queried per window (it returns the union of spaces for a batch).
- Fix display identification on macOS 26 by reading display UUIDs from
  ColorSync instead of relying on enumeration order.
- Find windows by CGWindowID (`_AXUIElementGetWindow`) instead of fuzzy
  title/frame matching, including windows on other Spaces.
- Switch Spaces with the Dock-swipe gesture; reorder fullscreen spaces
  with the bridged space-move operation; recreate Split View through the
  Window menu's Full Screen Tile items.
- Command-line mode in the app binary: `doctor`, `list`, `snapshot`,
  `restore [--dry-run]`, `dump`, `inspect-mc`.

### Python version

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
