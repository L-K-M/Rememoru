"""SkyLight (private WindowServer API) bindings.

Reads work fine under SIP. The only write we rely on is
SLSBridgedMoveWindowsToManagedSpaceOperation — the bridged WindowServer
operation that still moves windows between spaces with SIP enabled on
macOS 15/26 (technique from Hammerspoon PR #3889). Everything else that
mutates state goes through UI automation in mc.py / ax.py.
"""
import ctypes

from . import cf, macho, objcrt

SL_PATH = "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight"
_SL = None


def _lib():
    global _SL
    if _SL is None:
        _SL = ctypes.CDLL(SL_PATH)
    return _SL

# mangled name of the non-exported symbol (from Hammerspoon PR #3889)
_BRIDGED_PERFORM_MANGLED = (
    "__ZL54SLSPerformAsynchronousBridgedWindowManagementOperation"
    "P47SLSAsynchronousBridgedWindowManagementOperation"
)
_BRIDGED_OP_CLASS = "SLSBridgedMoveWindowsToManagedSpaceOperation"


def _bind(names, restype, argtypes):
    def build():
        for n in names:
            fn = getattr(_lib(), n, None)
            if fn is not None:
                fn.restype = restype
                fn.argtypes = argtypes
                return fn
        return None

    return cf.LazySym(build)


SLSMainConnectionID = _bind(
    ["SLSMainConnectionID", "CGSMainConnectionID"], ctypes.c_uint32, []
)
SLSCopyManagedDisplaySpaces = _bind(
    ["SLSCopyManagedDisplaySpaces", "CGSCopyManagedDisplaySpaces"],
    ctypes.c_void_p,
    [ctypes.c_uint32],
)
SLSSpaceGetType = _bind(
    ["SLSSpaceGetType", "CGSSpaceGetType"],
    ctypes.c_int,
    [ctypes.c_uint32, ctypes.c_uint64],
)
SLSGetActiveSpace = _bind(
    ["SLSGetActiveSpace", "CGSGetActiveSpace"], ctypes.c_uint64, [ctypes.c_uint32]
)
SLSManagedDisplayGetCurrentSpace = _bind(
    ["SLSManagedDisplayGetCurrentSpace", "CGSManagedDisplayGetCurrentSpace"],
    ctypes.c_uint64,
    [ctypes.c_uint32, ctypes.c_void_p],
)
SLSManagedDisplaySetCurrentSpace = _bind(
    ["SLSManagedDisplaySetCurrentSpace", "CGSManagedDisplaySetCurrentSpace"],
    None,
    [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint64],
)
SLSCopySpacesForWindows = _bind(
    ["SLSCopySpacesForWindows", "CGSCopySpacesForWindows"],
    ctypes.c_void_p,
    [ctypes.c_uint32, ctypes.c_int32, ctypes.c_void_p],
)
SLSShowSpaces = _bind(
    ["SLSShowSpaces", "CGSShowSpaces"], None, [ctypes.c_uint32, ctypes.c_void_p]
)
SLSHideSpaces = _bind(
    ["SLSHideSpaces", "CGSHideSpaces"], None, [ctypes.c_uint32, ctypes.c_void_p]
)

K_CGS_ALL_SPACES_MASK = 0x7

SPACE_TYPE_NAMES = {0: "user", 2: "system", 4: "fullscreen", 5: "tiled",
                    6: "wall"}

_bridge_checked = False
_bridge_perform = None


def _resolve_bridge():
    """Locate SLSPerformAsynchronousBridgedWindowManagementOperation."""
    global _bridge_checked, _bridge_perform
    if _bridge_checked:
        return _bridge_perform
    _bridge_checked = True
    try:
        addr = macho.find_local_symbol("SkyLight", _BRIDGED_PERFORM_MANGLED)
    except (OSError, RuntimeError):
        addr = None
    if addr is None:
        # some builds may export it after all, or with one less underscore
        try:
            lib = _lib()
        except OSError:
            lib = None
        if lib is not None:
            for cand in (
                "SLSPerformAsynchronousBridgedWindowManagementOperation",
                "_SLSPerformAsynchronousBridgedWindowManagementOperation",
            ):
                fn = getattr(lib, cand, None)
                if fn is not None:
                    addr = ctypes.cast(fn, ctypes.c_void_p).value
                    break
    if addr:
        _bridge_perform = ctypes.CFUNCTYPE(ctypes.c_int64, ctypes.c_void_p)(addr)
    return _bridge_perform


def bridged_move_available():
    if _resolve_bridge() is None:
        return False
    cls = objcrt.get_class(_BRIDGED_OP_CLASS)
    if not cls:
        return False
    return objcrt.instances_respond_to(cls, "initWithWindows:spaceID:")


class Connection(object):
    def __init__(self):
        if not SLSMainConnectionID:
            raise RuntimeError("SLSMainConnectionID not found")
        self.cid = SLSMainConnectionID()
        # tile sub-space id -> outer space id (fullscreen/split-view windows
        # report the tile id via SLSCopySpacesForWindows, not the outer one)
        self.tile_parents = {}

    # -- enumeration -------------------------------------------------------
    def managed_displays(self):
        """Raw managed-display dicts from the WindowServer."""
        arr = SLSCopyManagedDisplaySpaces(self.cid)
        if not arr:
            return []
        try:
            return cf.to_py(arr) or []
        finally:
            cf.CFRelease(arr)

    def space_type(self, space_id):
        if not SLSSpaceGetType:
            return None
        return SLSSpaceGetType(self.cid, int(space_id))

    def spaces(self):
        """Flattened space list: [{id, uuid, type, type_name, display_uuid,
        index, active, tiles?}] in Mission Control order per display.

        macOS 26 reports EVERY fullscreen-ish space as type 4; a real
        Split View pair is a type-4 space whose TileLayoutManager has 2+
        TileSpaces entries (single-app fullscreen has exactly 1). Tile
        entries carry their own ManagedSpaceID — windows report those —
        so we build tile_parents to translate them to the outer space."""
        out = []
        self.tile_parents = {}
        for d in self.managed_displays():
            disp_uuid = d.get("Display Identifier")
            current_id = (d.get("Current Space") or {}).get("ManagedSpaceID")
            if current_id is None and SLSManagedDisplayGetCurrentSpace and disp_uuid:
                sid = SLSManagedDisplayGetCurrentSpace(
                    self.cid, cf.cfstr(disp_uuid)
                )
                current_id = sid or None
            for i, s in enumerate(d.get("Spaces") or []):
                sid = s.get("ManagedSpaceID") or s.get("id64")
                if sid is None:
                    continue
                tlm = s.get("TileLayoutManager") or {}
                tiles = tlm.get("TileSpaces") or []
                t = s.get("type")
                if t is None:
                    t = self.space_type(sid)
                tiled = t == 4 and len(tiles) >= 2
                layout = tlm.get("Layout Rect") or {}
                tiles_info = []
                for tile in tiles:
                    tsid = tile.get("ManagedSpaceID") or tile.get("id64")
                    if tsid is not None:
                        self.tile_parents[int(tsid)] = int(sid)
                    tr = tile.get("TileRect") or {}
                    wid = tile.get("TileWindowID") or tile.get("fs_wid")
                    tiles_info.append({
                        "window_id": int(wid) if wid is not None else None,
                        "pid": tile.get("pid"),
                        "app": tile.get("appName"),
                        "title": tile.get("name"),
                        "side": ("left" if tr.get("X", 1e18)
                                 <= layout.get("X", 0) + 1 else "right"),
                        "rect": {
                            "x": tr.get("X"), "y": tr.get("Y"),
                            "w": tr.get("Width"), "h": tr.get("Height"),
                        },
                    })
                eff = 5 if tiled else t
                entry = {
                    "id": int(sid),
                    "uuid": s.get("uuid"),
                    "type": eff,
                    "type_name": SPACE_TYPE_NAMES.get(
                        eff, "unknown(%s)" % eff),
                    "display_uuid": disp_uuid,
                    "index": i,
                    "active": sid == current_id,
                }
                if tiles_info:
                    entry["tiles"] = tiles_info
                out.append(entry)
        return out

    def spaces_for_windows(self, window_ids):
        """Parallel list of space ids for the given CG window numbers."""
        if not SLSCopySpacesForWindows or not window_ids:
            return [None] * len(window_ids)
        warr = cf.cfarray_of_ints(window_ids)
        res = SLSCopySpacesForWindows(self.cid, K_CGS_ALL_SPACES_MASK, warr)
        cf.CFRelease(warr)
        if not res:
            return [None] * len(window_ids)
        try:
            vals = cf.to_py(res) or []
        finally:
            cf.CFRelease(res)
        vals = [v if isinstance(v, int) else None for v in vals]
        if len(vals) < len(window_ids):
            vals += [None] * (len(window_ids) - len(vals))
        return vals[: len(window_ids)]

    # -- mutation ----------------------------------------------------------
    def set_active_space(self, display_uuid, space_id):
        """Switch a display's active space. Works under SIP, but does not
        trigger the transition animation/repaint on macOS 15+ — pair with
        UI automation (mc.focus_space) for a clean switch."""
        if not SLSManagedDisplaySetCurrentSpace or not display_uuid:
            return False
        SLSManagedDisplaySetCurrentSpace(
            self.cid, cf.cfstr(display_uuid), int(space_id)
        )
        return True

    def hide_spaces(self, space_ids):
        if not SLSHideSpaces:
            return False
        arr = cf.cfarray_of_ints(space_ids)
        SLSHideSpaces(self.cid, arr)
        cf.CFRelease(arr)
        return True

    def move_windows_to_space(self, window_ids, space_id):
        """Move windows to another space via the bridged WindowServer op.
        Returns True if the operation was submitted (it is async)."""
        perform = _resolve_bridge()
        if perform is None:
            return False
        cls = objcrt.get_class(_BRIDGED_OP_CLASS)
        if not cls or not objcrt.instances_respond_to(
            cls, "initWithWindows:spaceID:"
        ):
            return False
        op = objcrt.alloc(cls)
        op = objcrt.init_with_windows_space_id(
            op, cf.cfarray_of_ints(window_ids), int(space_id)
        )
        if not op:
            return False
        perform(op)
        return True


def available_symbols():
    """For `doctor`: which bindings resolved."""
    return {
        "SLSMainConnectionID": bool(SLSMainConnectionID),
        "SLSCopyManagedDisplaySpaces": bool(SLSCopyManagedDisplaySpaces),
        "SLSSpaceGetType": bool(SLSSpaceGetType),
        "SLSGetActiveSpace": bool(SLSGetActiveSpace),
        "SLSManagedDisplayGetCurrentSpace": bool(
            SLSManagedDisplayGetCurrentSpace
        ),
        "SLSManagedDisplaySetCurrentSpace": bool(
            SLSManagedDisplaySetCurrentSpace
        ),
        "SLSCopySpacesForWindows": bool(SLSCopySpacesForWindows),
        "SLSShowSpaces": bool(SLSShowSpaces),
        "SLSHideSpaces": bool(SLSHideSpaces),
        "bridged_move_operation": bridged_move_available(),
    }
