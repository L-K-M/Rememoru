# Rememoru — agent brief

macOS utility: snapshot the full window/Spaces layout to JSON, restore it
later (windows that still exist). SIP stays enabled — all mutations go
through Accessibility APIs and Mission Control UI automation, plus the
private bridged WindowServer move op.

## Layout

- `rememoru/cf.py` — CoreFoundation via ctypes + `LazySym` (lazy symbol
  binding; every framework loads on first call, never at import — keep it
  that way so `doctor`/`--help` work off-macOS)
- `rememoru/cg.py` — CoreGraphics: window list, display geometry, synthetic
  mouse/key events
- `rememoru/macho.py` — walks a loaded image's local symtab (dyld APIs) to
  find non-exported symbols
- `rememoru/objcrt.py` — objc runtime bridge for the bridged op +
  NSRunningApplication (wrap lookups in `autorelease_pool`/`drain_pool`)
- `rememoru/skylight.py` — private SkyLight bindings, space enumeration,
  the bridged move (`SLSBridgedMoveWindowsToManagedSpaceOperation`,
  Hammerspoon PR #3889 technique)
- `rememoru/ax.py` — Accessibility helpers (frames, fullscreen, menus,
  element-at-point)
- `rememoru/mc.py` — Mission Control UI automation: create spaces,
  thumbnail drags for reorder/moves, the Split View green-button flow
- `rememoru/model.py` — snapshot capture + window matching helpers
- `rememoru/restore.py` — phased restore orchestration
- `rememoru/cli.py` — argparse CLI (`doctor`/`list`/`snapshot`/`restore`/
  `inspect-mc`/`dump`); entry points: `./rememoru-cli` and
  `python3 -m rememoru`

## Test / verify

```sh
python3 -m compileall rememoru rememoru-cli
python3 -m unittest discover -s tests
./rememoru-cli doctor          # on a Mac: permissions + binding health
```

The offline tests mock the native layer (cg/skylight/ax) — keep new logic
testable that way where possible. macOS-only paths need a real Mac;
`./rememoru-cli dump` prints raw SkyLight dicts for diagnosis.

## macOS 26 (Tahoe) findings — don't regress these

- `CGDisplayCreateUUIDFromDisplayID` is gone → display UUIDs come from
  SkyLight `Display Identifier`, joined to CG displays by enumeration
  order (`model.display_list`)
- Split View spaces report `type: 4` (same as plain fullscreen). Real
  signal: `TileLayoutManager.TileSpaces` has **≥2 entries** for a pair,
  1 for a solo fullscreen. `type 5` now means a tile *sub*-space.
- Windows on fullscreen/tiled spaces report the **tile sub-space id** to
  `SLSCopySpacesForWindows`, not the outer space id → translate via
  `Connection.tile_parents` (populated by `spaces()`)
- `TileRect.X <= Layout Rect.X` → tile is on the left
- Type `6` = `WallSpace` (wallpaper backing) — never a restore target
- Fullscreen/tiled space dicts also carry `pid` (int or list) and
  `fs_wid`/`TileWindowID` (CG window ids)
