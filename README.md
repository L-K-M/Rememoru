# Rememoru

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

Snapshot and restore your macOS window layout — displays, Spaces, fullscreen
windows, Split View pairs, and space order — **with SIP fully enabled**.

Zero dependencies: pure Python 3 + `ctypes` against the system frameworks.
No installation, no yabai, no scripting additions, no SIP changes.

```sh
./rememoru-cli doctor      # check your setup first
./rememoru-cli list        # show the current display/space/window map
./rememoru-cli snapshot    # capture → rememoru-<timestamp>.json
./rememoru-cli restore rememoru-<timestamp>.json --dry-run --verbose
./rememoru-cli restore rememoru-<timestamp>.json
```

## Requirements

- macOS (developed against macOS 26 / Tahoe; private API surface should work
  on 15+ — older versions untested)
- "Displays have separate Spaces" **enabled** (System Settings →
  Desktop & Dock)
- Grant to the app that runs the tool (Terminal, iTerm, …):
  - **Accessibility** — required for restore
  - **Screen Recording** — needed for window titles; without it matching is
    weaker and Mission Control drag fallbacks may pick the wrong window
- Stage Manager: not supported

## What gets captured

- Every display: stable UUID, frame, main flag, ordered space list, active space
- Every space: UUID/id, type (user desktop / fullscreen / split-view),
  Mission Control order
- Every window: id, pid, app, bundle id, title, frame, space assignment,
  split-view side

## What restore does

Runs a phased restore, skipping whatever is no longer available:

1. Match saved windows to live windows (app + bundle id + fuzzy title)
2. Create missing desktops via Mission Control (`+` button)
3. Move windows onto their target spaces — the private
   `SLSBridgedMoveWindowsToManagedSpaceOperation` WindowServer op
   (SIP-safe; technique from Hammerspoon PR #3889), with optional
   Mission Control drag and relaunch fallbacks
4. Restore window frames via Accessibility
5. Recreate fullscreen spaces via `AXFullScreen`
6. Recreate Split View pairs — green-button hold → "Tile Window to Left/Right
   of Screen" → clicks the companion thumbnail in the picker
7. Reorder spaces via Mission Control thumbnail drags
8. Restore the active space per display

## Restore options

```text
--dry-run           print the plan, change nothing (no AX permission needed)
--verbose           per-window progress
--launch            launch apps whose windows are all missing
--relaunch          allow quit+reopen as a window-move fallback
                    (may lose unsaved app state)
--move-fallback {none,mc,relaunch,all}
                    what to try if the bridged space-move fails
                    (default: mc = Mission Control drag)
--no-fullscreen     don't recreate fullscreen spaces
--no-split          don't recreate Split View pairs
--no-reorder        don't reorder space thumbnails
--remap-displays    map snapshot windows of missing displays onto connected ones
--focus-mode {sls,mc}
                    space switching: fast SkyLight call (default) or
                    Mission Control thumbnail click
```

## Restore automatically at login

`contrib/com.rememoru.restore.plist` is a LaunchAgent that waits 60
seconds after login (so login apps can finish opening their windows),
then runs `restore --launch --verbose`, logging to
`/tmp/rememoru-restore.log`.

```sh
cp contrib/com.rememoru.restore.plist ~/Library/LaunchAgents/
# edit the two paths inside: checkout dir + snapshot file
launchctl bootstrap gui/$(id -u) \
    ~/Library/LaunchAgents/com.rememoru.restore.plist
```

Permission note: under launchd the Accessibility grant attaches to
`python3` itself rather than your terminal. If the log says Accessibility
is missing, add `/usr/bin/python3` under System Settings → Privacy &
Security → Accessibility. That grant covers every Python script — for a
dedicated entry, wrap the restore command in an Automator app and add the
app to Login Items instead.

```sh
# test once without waiting for a login:
launchctl kickstart gui/$(id -u)/com.rememoru.restore

# stop it running at login:
launchctl bootout gui/$(id -u)/com.rememoru.restore
```

## Debugging

```sh
./rememoru-cli dump        # raw SkyLight display/space dicts, CG displays,
                           # and raw per-window space-query results
./rememoru-cli inspect-mc  # dump Dock/Mission Control AX tree
```

## Honest limitations

- **Split View is UI-automation fragile** — no programmatic API exists; the
  menu titles are localized and the picker needs timing. If the automation
  can't find the companion thumbnail it leaves the picker open so you can
  click it yourself.
- Space reordering is simulated thumbnail drags — works, but slower and less
  precise than yabai's SIP-off path.
- Windows owned by apps that are no longer running are skipped (or relaunched
  with `--launch`); fuzzy title matching can't resurrect e.g. a closed browser
  tab's window.
- Minimized windows aren't in `CGWindowList` and aren't captured.
- Uses private SkyLight APIs — fine for personal tooling, not App Store-safe.

## Development

```sh
python3 -m unittest discover -s tests   # offline tests (mock native layer)
python3 -m compileall rememoru          # syntax check
```

The code is split by framework: `cf`/`cg`/`skylight`/`ax` are thin ctypes
layers, `macho`/`objcrt` support the bridged move op, `mc` is Mission Control
automation, `model` captures snapshots, `restore` orchestrates, `cli` wires it
up. All native symbols are lazy-loaded so the CLI degrades cleanly instead of
crashing at import.
