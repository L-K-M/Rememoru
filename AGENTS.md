# Rememoru — agent brief

macOS menu bar app (Swift, SwiftPM, no Xcode project): snapshot the full
window/Spaces layout to JSON, restore it later (windows that still
exist). SIP stays enabled: mutations go through Accessibility, SkyLight's
bridged window-management operations, synthetic Dock-swipe gestures and
Mission Control's accessibility tree.

## Layout

- `Sources/RememoruCore/` (Foundation only, builds and tests on Linux):
  snapshot format (`Snapshot`, JSON keys compatible with the old Python
  files), SkyLight space parsing (`SpaceParser`), CGWindowList filtering,
  window matching (`WindowMatcher`), restore planning (`RestorePlanner`,
  pure: snapshot + live state -> ordered `RestoreStep`s), snapshot store,
  log file, CLI parsing, `RestoreReport`
- `Sources/RememoruMac/` (`#if os(macOS)`): `SkyLight` (reads),
  `BridgedOperations` (window and space moves via
  `performWithWMBridgeDelegate`), `Displays`, `AXElement` /
  `WindowElements` (AX windows by CGWindowID, remote-token lookup for
  other Spaces), `LiveReader`, `MissionControl`, `SpaceSwitcher`,
  `Restorer` (executes and verifies each step), `Permissions`, `Session`,
  `LayoutService` (the API the app uses)
- `Sources/Rememoru/`: menu bar app (`AppDelegate`, `Preferences`,
  `LoginItem` via `SMAppService`) and command-line mode (`CommandRunner`,
  runs when the first argument is a command)
- `scripts/build-app.sh`: assembles and signs `dist/Rememoru.app`

Private symbols are resolved with `dlopen`/`dlsym` (`NativeLibrary`),
never linked, so a symbol missing on some macOS disables one feature
instead of aborting launch. Keep it that way.

## Test / verify

```sh
swift build && swift test        # anywhere; Core logic + fixtures
scripts/build.sh                 # plus the app bundle on macOS
dist/Rememoru.app/Contents/MacOS/Rememoru doctor   # on a Mac
```

Keep decision logic in `RememoruCore` so it stays testable without a
Mac; `RememoruMac` should only read state and perform steps. CI's macOS
job smoke-tests `doctor`/`list`/`snapshot`/`restore --dry-run`/`dump`
on a real macOS runner, then runs `scripts/e2e-macos.sh` (the runner's
shell has Accessibility): a frame restore and a move onto a newly
created desktop, checked against WindowServer. Fullscreen, Split View
and multi-display paths still need a real Mac; `Rememoru dump` prints
raw SkyLight data for diagnosis.

## macOS findings — don't regress these

- `SLSCopySpacesForWindows` with several windows returns the **union** of
  their spaces, not one entry per window: query one window per call
- `CGDisplayCreateUUIDFromDisplayID` lives in **ColorSync** on current
  macOS (looking only in CoreGraphics made it look "gone" on 26). It
  yields SkyLight's `Display Identifier`; enumeration order is only the
  fallback
- Split View spaces report `type: 4` (same as plain fullscreen). Real
  signal: `TileLayoutManager.TileSpaces` has **≥2 entries** for a pair,
  1 for a solo fullscreen. `type 5` now means a tile *sub*-space.
- Windows on fullscreen/tiled spaces report the **tile sub-space id** to
  `SLSCopySpacesForWindows`, not the outer space id → translate via
  `ManagedSpaces.tileParents`
- `TileRect.X <= Layout Rect.X` → tile is on the left
- Type `6` = `WallSpace` (wallpaper backing) — never a restore target
- Fullscreen/tiled space dicts also carry `pid` (int or list) and
  `fs_wid`/`TileWindowID` (CG window ids)
- The original desktop's `uuid` can be empty: spaces are keyed by uuid
  if unique, else `id:<ManagedSpaceID>`
- Moving other apps' windows between Spaces: only
  `SLSBridgedMoveWindowsToManagedSpaceOperation` works with SIP on
  (macOS 26.4+; `SLSMoveWindowsToManagedSpace` is a no-op since 14.5).
  It is asynchronous; confirm by polling. Dispatch with
  `performWithWMBridgeDelegate` (no argument, void for async ops)
- `kAXWindows` omits windows on other Spaces (minimized ones are
  included); `_AXUIElementCreateWithRemoteToken` reaches them. Titles
  via AX need only Accessibility; `kCGWindowName` needs Screen Recording
- Plain `SLSManagedDisplaySetCurrentSpace` desyncs the Dock; switch
  Spaces with the Dock-swipe gesture or Mission Control instead
- Login-app history: an osacompile'd AppleScript applet showed an
  uncaught "AppleEvent timed out (-1712)" because its `display dialog`
  calls time out when the applet isn't frontmost; `with timeout` never
  applied to `do shell script`. The native app replaced it

<!-- shared-rules:start -->

## Working practices

- Follow explicit task instructions over the default workflow below.
- Writing the code is not finishing the task. A task is finished when
  its changes are merged to main through a PR that passed CI and review,
  or when the user explicitly accepts a different end state.
- Start every task on current code. Fetch first, then cut the task
  branch from origin/main — never from a stale local branch or an old
  checkout. To continue existing work, rebase or merge the latest
  origin/main into it before editing. Never overwrite existing work to
  update.
- Resolve ambiguity before making consequential changes. State low-risk
  assumptions; ask when scope, safety, or expected behavior is unclear.
- Keep changes focused. Do not modify unrelated code, formatting, or comments.
- Prefer surgical edits over whole-file rewrites when the result is equivalent.
- Stage only intended files. Inspect the diff before committing.

## Communication

- Be concise, factual, and direct. Preserve necessary context and uncertainty.
- Avoid praise, motivational filler, emojis, and em dashes in new prose.
- Address the reader directly in user-facing copy.
- Report what was verified and what remains unverified. Never imply that an
  unavailable check passed.

## Code design

- Prefer early returns and shallow nesting. Separate logical blocks with
  blank lines.
- Use descriptive constants or enums for meaningful or repeated values.
  Use existing standard definitions for protocol/specification constants.
  Keep obvious, one-off values inline.
- Use enums for behavioral modes that would otherwise require ambiguous
  boolean arguments.
- Default members to private. Widen visibility only for required consumers,
  and review the change as an API design decision.
- Follow the repository's declared dependency boundaries. UI and controllers
  must use application services rather than directly accessing databases,
  subprocesses, sockets, or other low-level mechanisms.
- Encapsulate low-level mechanics behind domain-oriented interfaces.
- Reuse genuinely shared logic. Avoid speculative abstractions and layers
  that only forward calls.
- Prefer pure functions for business rules and immutable data where practical.
  Isolate side effects; document non-obvious state ownership or synchronization.
- Explain non-obvious intent, constraints, and tradeoffs in comments.
  Do not narrate obvious code. Add examples or diagrams when they clarify it.

## Validation and errors

- Validate untrusted input at entry points. Where practical, represent valid
  states in types and enforce persistent invariants in database schemas.
- Represent absence and failure explicitly.
- Use assertions for internal programming invariants, not external-input
  validation or required runtime error handling.
- Prefer explicit, actionable errors over silent failure or undocumented
  fallback. Document intentional recovery behavior.
- Never report a skipped or failed operation as successful.

## Bug fixes

1. Identify the root cause and define an observable success criterion.
2. Add a regression test and observe the relevant failure before fixing it.
3. Implement the fix and observe the test passing.
4. Check surrounding behavior for regressions and architectural consistency.

If an automated regression test is impractical, document the reproduction
and verification procedure. State any inability to reproduce the failure.

## Verification

- Run relevant tests and lint after changes.
- Choose coverage by affected behavior and risk, not patch size.
- Use integration or end-to-end tests for critical workflows and boundaries;
  test isolated business rules at the lowest effective level.
- Run broader suites for cross-cutting or high-risk changes, and the full
  required release checks before releasing.
- Validate the requested command, options, platform, and configuration.
  Unrelated green CI is not proof that the reported problem is fixed.
- Recheck after the final edit. Distinguish local checks from CI results.

## Commit messages

- Use a capitalized, imperative subject without a final period.
- Target 50 characters; never exceed 72.
- Separate the subject and body with one blank line.
- Wrap body text at 72 characters.
- Explain what changed and why. Leave implementation mechanics to the code.

## Implementation and review

Unless explicitly instructed otherwise:

1. Work on a focused branch cut from the latest origin/main and open a PR
   against main before reporting the task as done.
2. Inspect CI results and completed review feedback for the latest commit.
   A successful reviewer job does not mean the review found no problems.
3. Address important findings or explain why they do not apply. Handle minor
   findings according to the stopping rules below.
4. Evaluate each fix in the surrounding project, add regression coverage,
   and rerun affected checks before pushing.
5. Repeat until a stopping criterion is met.
6. Merge without asking again once the stopping criterion is met, required
   checks pass on the latest commit, and no unresolved blockers or required
   human review requests remain.

### Reviewer context limits

The automated PR reviewer does not see the user's original prompt or
conversation. It may suggest changes that go against or beyond what the
user asked for. Do not implement such suggestions. Note each conflict and
report it to the user at the end of the thread.

### Automated review stopping rules

Judge findings by verified impact, not the reviewer's severity label.
Important findings concern correctness, security, data loss, broken builds,
or materially degraded behavior/performance.

Track completed review rounds and consecutive rounds without important
findings. Reruns of the same revision and integration failures do not count.

- No applicable actionable feedback: finish immediately.
- First minor-only round: optionally fix worthwhile, low-risk findings.
  Do not manufacture another push merely to obtain another review.
- Two consecutive rounds without important findings: stop responding to
  automated nitpicks, even if actionable minor suggestions remain.
  Defer worthwhile leftovers rather than continuing the cycle.
- A confirmed important finding resets the minor-only streak. Address it
  and verify the fix before continuing.

After ten completed rounds, enter stabilization:

- Stop optional cleanup, refactoring, and nitpick fixes.
- One completed review without confirmed important findings is sufficient
  to finish, even if minor suggestions remain.
- Continue only for confirmed important defects. If resolving them stalls,
  report the blockers rather than continuing indefinitely.

These limits end optional automated-feedback work. They do not waive
confirmed blockers, unresolved human review requests, or required checks.

### Reviewer integration failures

After two consecutive reviewer-integration failures, stop and report the
review gap. Do not treat failures as approval. An explicit user instruction
may waive review; report that waiver rather than claiming review passed.

## Ending a task

- A task ends with its changes merged to main — not with code written,
  and not with a PR merely opened. An open PR is work in progress:
  monitor CI on the latest commit, address review findings per the
  stopping rules, and merge once the criteria are met.
- Never finish with uncommitted changes or unpushed commits in the
  worktree. Commit, push, and open or update the PR first.
- If a step is impossible (missing push access, CI failure, reviewer
  outage), report the exact blocker instead. Never present unreviewed or
  unmerged work as finished.
- Before finishing, confirm: the requested behavior is implemented
  without unrelated changes; relevant checks pass on the latest code;
  important review findings are addressed or rejected with reasons;
  deferred suggestions, remaining risks, and validation gaps are
  disclosed.
- The final response states where the work stands: branch, PR, CI
  status, review rounds completed, and whether it is merged.

<!-- shared-rules:end -->
