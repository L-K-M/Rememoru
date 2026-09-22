"""Snapshot capture: displays -> ordered spaces -> windows."""
import time

from . import cg, cf, skylight, objcrt

SNAPSHOT_VERSION = 1

# Process names that own system UI "windows" we never want to track.
OWNER_BLOCKLIST = {
    "Dock", "WindowServer", "Window Manager", "WindowManager",
    "ControlCenter", "Control Center", "SystemUIServer", "Spotlight",
    "NotificationCenter", "Notification Center", "loginwindow",
    "ScreenSaverEngine", "ScreenSaver", "TextInputMenuAgent",
    "TextInputSwitcher", "UIKitSystem", "CursorUIViewService",
    "Accessibility Visuals Agent", "rememoru",
}


def _bundle_ids(pids):
    """pid -> bundle identifier via NSRunningApplication (best effort)."""
    try:
        ctypes_appkit = __import__("ctypes").CDLL(
            "/System/Library/Frameworks/AppKit.framework/AppKit"
        )
        del ctypes_appkit
    except OSError:
        pass
    out = {}
    pool = objcrt.autorelease_pool()
    try:
        for pid in set(pids):
            try:
                app = objcrt.running_app_with_pid(pid)
                ref = objcrt.bundle_identifier_of(app)
                out[pid] = cf.cfstring_to_str(ref) if ref else None
            except Exception:
                out[pid] = None
    finally:
        objcrt.drain_pool(pool)
    return out


def display_list(sls_conn, log=None):
    """Displays with frames (CoreGraphics) joined to SLS 'Display Identifier'
    UUIDs. CGDisplayCreateUUIDFromDisplayID is gone on macOS 26, so when CG
    can't produce a uuid we join by enumeration order — CGGetActiveDisplayList
    and SLSCopyManagedDisplaySpaces iterate the same hardware order."""
    disps = cg.displays()
    if disps and all(d["uuid"] for d in disps):
        return disps
    try:
        uuids = [
            m.get("Display Identifier") for m in sls_conn.managed_displays()
        ]
    except Exception:
        uuids = []
    if len(uuids) == len(disps) and all(uuids):
        if log:
            log("note: display UUIDs taken from SkyLight order "
                "(CGDisplayCreateUUIDFromDisplayID unavailable)")
        for d, u in zip(disps, uuids):
            if not d["uuid"]:
                d["uuid"] = u
    return disps


def current_windows(sls_conn):
    """Live window list, each with space_id attached."""
    raw = cg.window_list()
    wins = []
    wids = []
    for w in raw:
        wid = w.get("kCGWindowNumber")
        owner = w.get("kCGWindowOwnerName") or ""
        bounds = w.get("kCGWindowBounds") or {}
        layer = w.get("kCGWindowLayer", 0)
        alpha = w.get("kCGWindowAlpha", 1)
        if wid is None or owner in OWNER_BLOCKLIST:
            continue
        if layer != 0 or not alpha:
            continue
        frame = {
            "x": bounds.get("X", 0.0),
            "y": bounds.get("Y", 0.0),
            "w": bounds.get("Width", 0.0),
            "h": bounds.get("Height", 0.0),
        }
        if frame["w"] < 4 or frame["h"] < 4:
            continue
        wins.append(
            {
                "id": int(wid),
                "pid": int(w.get("kCGWindowOwnerPID") or 0),
                "app": owner,
                "title": w.get("kCGWindowName") or "",
                "frame": frame,
                "onscreen": bool(w.get("kCGWindowIsOnscreen", False)),
            }
        )
        wids.append(int(wid))
    space_ids = sls_conn.spaces_for_windows(wids)
    tile_parents = getattr(sls_conn, "tile_parents", {}) or {}
    for w, sid in zip(wins, space_ids):
        # windows on fullscreen/split-view spaces report the tile sub-space
        w["space_id"] = tile_parents.get(sid, sid)
    bundle_ids = _bundle_ids([w["pid"] for w in wins])
    for w in wins:
        w["bundle_id"] = bundle_ids.get(w["pid"])
    return wins


def capture(log=print):
    """Return the full snapshot dict."""
    sls = skylight.Connection()
    displays = display_list(sls, log=log)
    spaces = sls.spaces()  # ordered per display
    windows = current_windows(sls)

    space_by_id = {s["id"]: s for s in spaces}
    for w in windows:
        s = space_by_id.get(w.get("space_id"))
        w["space_uuid"] = s["uuid"] if s else None
        w["space_type"] = s["type_name"] if s else None
        w["display_uuid"] = s["display_uuid"] if s else None

    # side for windows living on a tiled (split-view) space — prefer the
    # TileLayoutManager metadata (macOS 26), fall back to frame x-order
    by_space = {}
    for w in windows:
        by_space.setdefault(w.get("space_id"), []).append(w)
    for sid, ws in by_space.items():
        s = space_by_id.get(sid)
        if not s or s["type"] != 5:
            continue
        side_of_wid = {
            t["window_id"]: t["side"]
            for t in s.get("tiles") or [] if t.get("window_id")
        }
        leftover = []
        for w in ws:
            side = side_of_wid.get(w["id"])
            if side:
                w["side"] = side
            else:
                leftover.append(w)
        for i, w in enumerate(sorted(leftover,
                                     key=lambda w: w["frame"]["x"])):
            w["side"] = "left" if i == 0 else "right"

    disp_list = []
    for d in displays:
        sspaces = [s for s in spaces if s["display_uuid"] == d["uuid"]]
        sspaces.sort(key=lambda s: s["index"])
        disp_list.append(
            {
                "uuid": d["uuid"],
                "frame": d["frame"],
                "main": d["main"],
                "spaces": [s["uuid"] for s in sspaces if s["type"] != 2],
                "active_space": next(
                    (s["uuid"] for s in sspaces if s["active"]), None
                ),
            }
        )

    snap = {
        "version": SNAPSHOT_VERSION,
        "created": time.strftime("%Y-%m-%dT%H:%M:%S%z"),
        "displays": disp_list,
        "spaces": [
            {
                "uuid": s["uuid"],
                "id": s["id"],
                "type": s["type_name"],
                "type_id": s["type"],
                "display_uuid": s["display_uuid"],
                "index": s["index"],
                "active": s["active"],
            }
            for s in spaces
            if s["type"] != 2  # skip system spaces
        ],
        "windows": [
            {k: w[k] for k in (
                "id", "pid", "app", "bundle_id", "title", "frame",
                "onscreen", "space_uuid", "space_type", "display_uuid",
            ) if k in w} | ({"side": w["side"]} if "side" in w else {})
            for w in windows
        ],
    }
    return snap
