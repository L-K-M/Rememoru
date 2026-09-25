# Rememoru

> [!IMPORTANT]
> LLM disclosure: This codebase was written with substantial help from large language models: AI coding agents working from the [`AGENTS.md`](AGENTS.md) brief in this repo.

A macOS menu bar app that saves your window layout and puts it back later:
which display and desktop (Space) every window is on, its position and
size, fullscreen windows, Split View pairs, and the order of your Spaces.
It works **with SIP enabled**.

## Install

Rememoru is built from source (it uses private macOS APIs, so it is not
notarized or in the App Store). You need the Xcode command-line tools
(`xcode-select --install`) on macOS 13 or later.

```sh
scripts/build-app.sh --install   # builds dist/Rememoru.app, copies it to ~/Applications
open ~/Applications/Rememoru.app
```

On first launch Rememoru asks for **Accessibility** permission. Turn
Rememoru on under System Settings > Privacy & Security > Accessibility.

> [!NOTE]
> macOS ties the permission to the app's code signature. The default
> build is signed ad hoc, and that signature changes with every rebuild,
> so after rebuilding you have to grant the permission again: remove the
> old Rememoru entry with the minus button and add the new one. To keep
> the grant across builds, sign with a stable identity, for example
> `CODESIGN_IDENTITY="Apple Development: you@example.com" scripts/build-app.sh --install`
> (list yours with `security find-identity -v -p codesigning`).

## Use

Click the menu bar icon:

- **Save Current Layout** (⌘S) writes a snapshot to
  `~/Library/Application Support/Rememoru/Snapshots/`.
- **Restore Latest Layout** (⌘R), or pick an older one under **Restore**.
  Rememoru reports what it could not restore, with a link to the log.
- **Restore Latest Layout at Login** registers Rememoru as a login item.
  At login it waits (**Wait After Login**, 30 s by default) so your apps
  can reopen their windows, then restores the newest snapshot.
- **Open Apps That Aren't Running** (on by default) launches apps that
  had saved windows before matching, and waits up to 20 s for their
  windows.
- **Show Log** opens `~/Library/Logs/Rememoru/rememoru.log`, which lists
  every step of every restore and whether it worked.

**Screen Recording** permission is optional. Rememoru reads window titles
through Accessibility. With Screen Recording it can also read the titles
of windows on other Spaces cheaply, which helps tell windows of the same
app apart.

### Requirements and settings

- macOS 26 (Tahoe) is the target. Moving windows between Spaces needs
  macOS 26.4 or later. Everything else also runs on 13 to 15, but is
  untested there.
- System Settings > Desktop & Dock > "Displays have separate Spaces" must
  be **on**.
- Stage Manager is not supported.

## What a restore does

Rememoru first matches saved windows to the windows open now. A window
from the same login session matches by its WindowServer ID. After a
restart, windows match by app and title. If a title changed (a browser
now shows a different tab), the window matches by position among that
app's remaining windows. Then Rememoru plans the steps and runs them,
checking each one against WindowServer before counting it as done:

1. **Create missing desktops**: presses "+" in Mission Control, through
   the Dock's accessibility tree.
2. **Unminimize or minimize** windows as saved.
3. **Leave fullscreen** for windows that were on a normal desktop.
4. **Move windows to their desktop**: uses SkyLight's
   `SLSBridgedMoveWindowsToManagedSpaceOperation`, which the WindowServer
   runs for Rememoru, so it works with SIP on (the same approach as yabai
   7.1.25 and Loop). Desktops are matched by position: desktop 2 is the
   second desktop on that display.
5. **Set positions and sizes** through Accessibility. For a window on a
   hidden Space, Rememoru switches to that Space if setting it directly
   doesn't stick.
6. **Recreate fullscreen windows** (`AXFullScreen`) and **Split View
   pairs** (Window > Full Screen Tile > Left of Screen, then a click on
   the partner window in the picker). Each window starts from the desktop
   its space followed, so the new space lands in the right place.
7. **Restore the order of Spaces** where fullscreen or Split View spaces
   sit between desktops (`SLSBridgedMoveManagedSpaceToDisplayIndexOperation`).
8. **Show the Space that was active** on each display, with the same
   synthetic Dock-swipe gesture yabai uses. Mission Control is the
   fallback.

Your pointer returns to where it was when the restore finishes. You can
cancel a running restore from the menu.

## Command line

The app binary doubles as a command-line tool. It is handy for
diagnosing problems and for scripting:

```sh
R=~/Applications/Rememoru.app/Contents/MacOS/Rememoru
$R doctor                     # permissions and private API availability
$R list                       # displays, spaces and windows right now
$R snapshot [-o file.json]    # save (default: the app's snapshot folder)
$R restore [file.json] --dry-run   # print the plan without changing anything
$R restore [file.json]        # --no-fullscreen --no-split --no-arrange ...
$R dump > dump.json           # raw WindowServer data for bug reports
$R inspect-mc                 # Mission Control's accessibility tree
```

When run from a terminal, the command uses the terminal's permissions,
not Rememoru.app's.

## Limitations

- **Private APIs.** SkyLight and a few HIServices functions are
  undocumented. Rememoru looks each one up at runtime, and `doctor` shows
  which are missing. A missing function disables its feature instead of
  crashing the app. Reports say macOS 27 moves Mission Control's
  accessibility tree and ignores the synthetic swipe, so expect breakage
  there.
- **Split View** depends on the app having a standard Window menu with
  English titles, and on the picker offering the partner window. The
  width ratio of the pair is not restored.
- **Moving a window into a Space that has never been shown** can fail on
  some systems (yabai #2789). Rememoru then shows that Space and tries
  again.
- **Windows of apps that are not running** can't be restored. Rememoru
  reports them and skips them.
- **Windows assigned to all desktops** are not captured.

## Upgrading from the Python version

The earlier Python and AppleScript tooling is gone. Snapshots it wrote
still load: copy them into the snapshots folder (**Open Snapshots
Folder**) or pass them to `restore`. Remove the old login helpers:
delete `~/Applications/RememoruRestore.app` and remove it from System
Settings > General > Login Items. If you installed the LaunchAgent, run
`launchctl bootout gui/$(id -u)/com.rememoru.restore` and delete
`~/Library/LaunchAgents/com.rememoru.restore.plist`.

## Development

```sh
swift build && swift test   # core logic; builds and tests on Linux too
scripts/build.sh            # the same, plus the app bundle on macOS
```

`RememoruCore` holds everything that can be tested without a Mac:
snapshot format, SkyLight space parsing, window matching, restore
planning, the snapshot store and command-line parsing. `RememoruMac`
wraps the system: SkyLight, CoreGraphics, Accessibility and Mission
Control. The `Rememoru` target is the menu bar app and command-line entry
point. See [`AGENTS.md`](AGENTS.md) for the macOS findings the code
depends on.
