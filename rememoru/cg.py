"""CoreGraphics: window enumeration, display geometry, synthetic events."""
import ctypes
import time

from . import cf

CG_PATH = "/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics"
_CG = None


def _lib():
    global _CG
    if _CG is None:
        _CG = ctypes.CDLL(CG_PATH)
    return _CG


class CGPoint(ctypes.Structure):
    _fields_ = [("x", ctypes.c_double), ("y", ctypes.c_double)]


class CGSize(ctypes.Structure):
    _fields_ = [("width", ctypes.c_double), ("height", ctypes.c_double)]


class CGRect(ctypes.Structure):
    _fields_ = [("origin", CGPoint), ("size", CGSize)]

    def as_dict(self):
        return {
            "x": self.origin.x,
            "y": self.origin.y,
            "w": self.size.width,
            "h": self.size.height,
        }


def _f(name, restype, argtypes, required=True):
    def build():
        fn = getattr(_lib(), name, None)
        if fn is None:
            return None
        fn.restype = restype
        fn.argtypes = argtypes
        return fn

    return cf.LazySym(build)


# --- window list -----------------------------------------------------------
CGWindowListCopyWindowInfo = _f(
    "CGWindowListCopyWindowInfo",
    ctypes.c_void_p,
    [ctypes.c_uint32, ctypes.c_uint32],
)

K_CG_WINDOW_LIST_OPTION_ALL = 0
K_CG_WINDOW_LIST_ONSCREEN_ONLY = 1
K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS = 16


def window_list(onscreen_only=False):
    """All windows in this session as a list of dicts (front-to-back order)."""
    opt = K_CG_WINDOW_LIST_EXCLUDE_DESKTOP_ELEMENTS
    if onscreen_only:
        opt |= K_CG_WINDOW_LIST_ONSCREEN_ONLY
    arr = CGWindowListCopyWindowInfo(opt, 0)
    if not arr:
        return []
    try:
        return cf.to_py(arr)
    finally:
        cf.CFRelease(arr)


# --- displays --------------------------------------------------------------
CGGetActiveDisplayList = _f(
    "CGGetActiveDisplayList",
    ctypes.c_int32,
    [ctypes.c_uint32, ctypes.c_void_p, ctypes.c_void_p],
)
CGDisplayBounds = _f("CGDisplayBounds", CGRect, [ctypes.c_uint32])
CGMainDisplayID = _f("CGMainDisplayID", ctypes.c_uint32, [])
CGDisplayCreateUUIDFromDisplayID = _f(
    "CGDisplayCreateUUIDFromDisplayID",
    ctypes.c_void_p,
    [ctypes.c_uint32],
)


def displays():
    """[{id, uuid, frame, main}] — uuid matches SLS 'Display Identifier'."""
    count = ctypes.c_uint32(0)
    if CGGetActiveDisplayList(32, None, ctypes.byref(count)) != 0:
        return []
    ids = (ctypes.c_uint32 * count.value)()
    if CGGetActiveDisplayList(count.value, ids, ctypes.byref(count)) != 0:
        return []
    main = CGMainDisplayID()
    out = []
    for did in ids:
        uuid = None
        if CGDisplayCreateUUIDFromDisplayID:
            uref = CGDisplayCreateUUIDFromDisplayID(did)
            if uref:
                sref = cf.CFUUIDCreateString(None, uref)
                if sref:
                    uuid = cf.cfstring_to_str(sref)
                    cf.CFRelease(sref)
                cf.CFRelease(uref)
        b = CGDisplayBounds(did)
        out.append(
            {
                "id": int(did),
                "uuid": uuid,
                "frame": b.as_dict(),
                "main": bool(did == main),
            }
        )
    return out


# --- screen recording permission ------------------------------------------
CGPreflightScreenCaptureAccess = _f(
    "CGPreflightScreenCaptureAccess", ctypes.c_bool, []
)
CGRequestScreenCaptureAccess = _f(
    "CGRequestScreenCaptureAccess", ctypes.c_bool, [ctypes.c_bool]
)


def has_screen_recording():
    if not CGPreflightScreenCaptureAccess:
        return None  # pre-10.15, always had titles
    return bool(CGPreflightScreenCaptureAccess())


def request_screen_recording():
    if CGRequestScreenCaptureAccess:
        return bool(CGRequestScreenCaptureAccess(True))
    return True


# --- synthetic events ------------------------------------------------------
CGEventCreateKeyboardEvent = _f(
    "CGEventCreateKeyboardEvent",
    ctypes.c_void_p,
    [ctypes.c_void_p, ctypes.c_uint16, ctypes.c_bool],
)
CGEventCreateMouseEvent = _f(
    "CGEventCreateMouseEvent",
    ctypes.c_void_p,
    [ctypes.c_void_p, ctypes.c_uint32, CGPoint, ctypes.c_uint32],
)
CGEventSetFlags = _f("CGEventSetFlags", None, [ctypes.c_void_p, ctypes.c_uint64])
CGEventPost = _f("CGEventPost", None, [ctypes.c_uint32, ctypes.c_void_p])
CGEventCreate = _f("CGEventCreate", ctypes.c_void_p, [ctypes.c_void_p])
CGEventGetLocation = _f("CGEventGetLocation", CGPoint, [ctypes.c_void_p])

K_CG_HID_EVENT_TAP = 0
K_CG_EVENT_LEFT_MOUSE_DOWN = 1
K_CG_EVENT_LEFT_MOUSE_UP = 2
K_CG_EVENT_MOUSE_MOVED = 5
K_CG_EVENT_LEFT_MOUSE_DRAGGED = 6

K_FLAG_SHIFT = 0x00020000
K_FLAG_CONTROL = 0x00040000
K_FLAG_OPTION = 0x00080000
K_FLAG_COMMAND = 0x00100000

KEY_ESCAPE = 53
KEY_F = 3
KEY_UP = 126
KEY_LEFT = 123
KEY_RIGHT = 124


def _post(ev):
    if not ev:
        return
    CGEventPost(K_CG_HID_EVENT_TAP, ev)
    cf.CFRelease(ev)


def key(keycode, flags=0):
    down = CGEventCreateKeyboardEvent(None, keycode, True)
    up = CGEventCreateKeyboardEvent(None, keycode, False)
    if flags:
        if down:
            CGEventSetFlags(down, flags)
        if up:
            CGEventSetFlags(up, flags)
    _post(down)
    _post(up)


def mouse_pos():
    ev = CGEventCreate(None)
    if not ev:
        return None
    p = CGEventGetLocation(ev)
    cf.CFRelease(ev)
    return (p.x, p.y)


def _mouse(evtype, x, y):
    ev = CGEventCreateMouseEvent(None, evtype, CGPoint(x, y), 0)
    _post(ev)


def move_mouse(x, y):
    _mouse(K_CG_EVENT_MOUSE_MOVED, x, y)


def click(x, y):
    _mouse(K_CG_EVENT_LEFT_MOUSE_DOWN, x, y)
    _mouse(K_CG_EVENT_LEFT_MOUSE_UP, x, y)


def mouse_down(x, y):
    _mouse(K_CG_EVENT_LEFT_MOUSE_DOWN, x, y)


def mouse_up(x, y):
    _mouse(K_CG_EVENT_LEFT_MOUSE_UP, x, y)


def drag(x0, y0, x1, y1, steps=14, step_delay=0.03, hold=0.15):
    """Slow left-button drag — Mission Control ignores fast synthetic drags."""
    mouse_down(x0, y0)
    time.sleep(hold)
    for i in range(1, steps + 1):
        t = i / steps
        _mouse(K_CG_EVENT_LEFT_MOUSE_DRAGGED, x0 + (x1 - x0) * t, y0 + (y1 - y0) * t)
        time.sleep(step_delay)
    mouse_up(x1, y1)
