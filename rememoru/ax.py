"""Accessibility (AXUIElement) helpers — the UI-automation backbone."""
import ctypes
import time

from . import cf
from .cg import CGPoint, CGSize, CGRect

_AX_CANDIDATES = [
    "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
    "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/"
    "HIServices.framework/HIServices",
]
_AX = None


def _lib():
    global _AX
    if _AX is None:
        for p in _AX_CANDIDATES:
            try:
                lib = ctypes.CDLL(p)
                getattr(lib, "AXUIElementCreateApplication")
                _AX = lib
                break
            except (OSError, AttributeError):
                continue
        if _AX is None:
            _AX = ctypes.CDLL(_AX_CANDIDATES[0])  # let it raise on use
    return _AX


def _f(name, restype, argtypes):
    def build():
        fn = getattr(_lib(), name)
        fn.restype = restype
        fn.argtypes = argtypes
        return fn

    return cf.LazySym(build)


AXIsProcessTrusted = _f("AXIsProcessTrusted", ctypes.c_bool, [])
AXIsProcessTrustedWithOptions = _f(
    "AXIsProcessTrustedWithOptions", ctypes.c_bool, [ctypes.c_void_p]
)
AXUIElementCreateApplication = _f(
    "AXUIElementCreateApplication", ctypes.c_void_p, [ctypes.c_int32]
)
AXUIElementCreateSystemWide = _f("AXUIElementCreateSystemWide", ctypes.c_void_p, [])
AXUIElementCopyAttributeValue = _f(
    "AXUIElementCopyAttributeValue",
    ctypes.c_int,
    [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p],
)
AXUIElementCopyAttributeNames = _f(
    "AXUIElementCopyAttributeNames",
    ctypes.c_int,
    [ctypes.c_void_p, ctypes.c_void_p],
)
AXUIElementCopyParameterizedAttributeValue = _f(
    "AXUIElementCopyParameterizedAttributeValue",
    ctypes.c_int,
    [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p],
)
AXUIElementSetAttributeValue = _f(
    "AXUIElementSetAttributeValue",
    ctypes.c_int,
    [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p],
)
AXUIElementPerformAction = _f(
    "AXUIElementPerformAction", ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p]
)
AXUIElementCopyElementAtPosition = _f(
    "AXUIElementCopyElementAtPosition",
    ctypes.c_int,
    [ctypes.c_void_p, ctypes.c_float, ctypes.c_float, ctypes.c_void_p],
)
AXUIElementGetPid = _f(
    "AXUIElementGetPid", ctypes.c_int, [ctypes.c_void_p, ctypes.c_void_p]
)
AXValueCreate = _f(
    "AXValueCreate", ctypes.c_void_p, [ctypes.c_int, ctypes.c_void_p]
)
AXValueGetValue = _f(
    "AXValueGetValue", ctypes.c_bool, [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
)

K_AX_VALUE_CGPOINT = 1
K_AX_VALUE_CGSIZE = 2
K_AX_VALUE_CGRECT = 3

AX_ERROR_SUCCESS = 0

# Refs returned by AXUIElementCopy* are owned (Copy rule) but never released:
# arrays own the AXUIElementRefs we hand out, so releasing parents could kill
# live elements. Deliberate small leak — this is a short-lived CLI.


def trusted():
    return bool(AXIsProcessTrusted) and bool(AXIsProcessTrusted())


def prompt_trusted():
    """Trigger the native TCC prompt ("<app> would like to control this
    computer") via AXIsProcessTrustedWithOptions, then return the current
    trust state. Without this the app context just fails silently."""
    if not AXIsProcessTrustedWithOptions:
        return trusted()
    # the real key is the exported kAXTrustedCheckOptionPrompt constant;
    # a CFString with equal contents works identically as a dict key
    opts = cf.cfdict(
        [(cf.cfstr("AXTrustedCheckOptionPrompt"), cf.kCFBooleanTrue)]
    )
    try:
        return bool(AXIsProcessTrustedWithOptions(opts))
    finally:
        cf.CFRelease(opts)


def _copy_attr(el, name):
    out = ctypes.c_void_p()
    err = AXUIElementCopyAttributeValue(el, cf.cfstr(name), ctypes.byref(out))
    if err != AX_ERROR_SUCCESS:
        return None
    return out.value


def attr(el, name):
    """Attribute as a python object (str/int/bool/list/dict)."""
    return cf.to_py(_copy_attr(el, name))


def attr_ref(el, name):
    """Attribute as a raw CFTypeRef (for AXUIElementRef / AXValueRef)."""
    return _copy_attr(el, name)


def children(el):
    refs = cf.array_to_refs(_copy_attr(el, "AXChildren"))
    return refs


def attr_names(el):
    return cf.to_py(_copy_attr(el, "AXAttributeNames")) or []


AXUIElementCopyActionNames = _f(
    "AXUIElementCopyActionNames",
    ctypes.c_int,
    [ctypes.c_void_p, ctypes.c_void_p],
)


def action_names(el):
    if not AXUIElementCopyActionNames:
        return []
    out = ctypes.c_void_p()
    if AXUIElementCopyActionNames(el, ctypes.byref(out)) != AX_ERROR_SUCCESS:
        return []
    return cf.to_py(out.value) or []


def set_attr(el, name, value_ref):
    return AXUIElementSetAttributeValue(el, cf.cfstr(name), value_ref)


def set_bool(el, name, value):
    return (
        set_attr(el, name, cf.kCFBooleanTrue if value else cf.kCFBooleanFalse)
        == AX_ERROR_SUCCESS
    )


def perform(el, action):
    return AXUIElementPerformAction(el, cf.cfstr(action)) == AX_ERROR_SUCCESS


def press(el):
    return perform(el, "AXPress")


def raise_window(el):
    return perform(el, "AXRaise")


def axvalue_point(x, y):
    p = CGPoint(float(x), float(y))
    return AXValueCreate(K_AX_VALUE_CGPOINT, ctypes.byref(p))


def axvalue_size(w, h):
    s = CGSize(float(w), float(h))
    return AXValueCreate(K_AX_VALUE_CGSIZE, ctypes.byref(s))


def read_axvalue(ref, vtype):
    if vtype == K_AX_VALUE_CGPOINT:
        v = CGPoint()
    elif vtype == K_AX_VALUE_CGSIZE:
        v = CGSize()
    elif vtype == K_AX_VALUE_CGRECT:
        v = CGRect()
    else:
        return None
    if not AXValueGetValue(ref, vtype, ctypes.byref(v)):
        return None
    return v


def position(el):
    v = read_axvalue(_copy_attr(el, "AXPosition"), K_AX_VALUE_CGPOINT)
    return (v.x, v.y) if v else None


def size(el):
    v = read_axvalue(_copy_attr(el, "AXSize"), K_AX_VALUE_CGSIZE)
    return (v.width, v.height) if v else None


def frame(el):
    """AXFrame (CGRect) -> dict, or position+size."""
    v = read_axvalue(_copy_attr(el, "AXFrame"), K_AX_VALUE_CGRECT)
    if v:
        return v.as_dict()
    p, s = position(el), size(el)
    if p and s:
        return {"x": p[0], "y": p[1], "w": s[0], "h": s[1]}
    return None


def center(el):
    f = frame(el)
    if not f:
        return None
    return (f["x"] + f["w"] / 2.0, f["y"] + f["h"] / 2.0)


def pid_of(el):
    p = ctypes.c_int32(0)
    if AXUIElementGetPid(el, ctypes.byref(p)) != AX_ERROR_SUCCESS:
        return None
    return p.value


def app_element(pid):
    return AXUIElementCreateApplication(int(pid))


def system_wide():
    return AXUIElementCreateSystemWide()


def element_at(x, y):
    """Element under a screen point (used for the Split View picker)."""
    out = ctypes.c_void_p()
    err = AXUIElementCopyElementAtPosition(
        system_wide(), float(x), float(y), ctypes.byref(out)
    )
    if err != AX_ERROR_SUCCESS:
        return None
    return out.value


def window_of(el):
    """The AXWindow that owns `el` (or el itself if it is one)."""
    if el is None:
        return None
    if attr(el, "AXRole") == "AXWindow":
        return el
    return attr_ref(el, "AXWindow")


def app_windows(pid):
    app = app_element(pid)
    wins = cf.array_to_refs(_copy_attr(app, "AXWindows"))
    if not wins:
        wins = [
            c for c in children(app) if attr(c, "AXRole") == "AXWindow"
        ]
    return wins


def title_of(el):
    return attr(el, "AXTitle")


def describe(el):
    """Compact one-line description for debugging/inspection."""
    return {
        "role": attr(el, "AXRole"),
        "subrole": attr(el, "AXSubrole"),
        "identifier": attr(el, "AXIdentifier"),
        "title": attr(el, "AXTitle"),
        "description": attr(el, "AXDescription"),
        "frame": frame(el),
    }


def find_window(pid, title=None, approx_frame=None, tol=40):
    """Best matching AXWindow element of an app for a snapshot window."""
    best, best_score = None, -1
    for w in app_windows(pid):
        score = 0
        wt = attr(w, "AXTitle")
        if title is not None:
            if wt == title:
                score += 4
            elif wt and title and (wt.startswith(title) or title.startswith(wt)):
                score += 2
            elif title and wt and title in wt:
                score += 1
            elif not wt:
                score += 1
        if approx_frame:
            p, s = position(w), size(w)
            if p and s:
                d = abs(p[0] - approx_frame["x"]) + abs(p[1] - approx_frame["y"])
                d += abs(s[0] - approx_frame["w"]) + abs(s[1] - approx_frame["h"])
                score += max(0, 3 - int(d / tol))
        if score > best_score:
            best, best_score = w, score
    return best


def set_frame(el, x, y, w, h, retries=2):
    """Set window frame; verify and retry with swapped order if needed."""
    set_attr(el, "AXSize", axvalue_size(w, h))
    set_attr(el, "AXPosition", axvalue_point(x, y))
    time.sleep(0.05)
    for _ in range(retries):
        p, s = position(el), size(el)
        if not p or not s:
            break
        ok = (
            abs(p[0] - x) < 3
            and abs(p[1] - y) < 3
            and abs(s[0] - w) < 3
            and abs(s[1] - h) < 3
        )
        if ok:
            return True
        set_attr(el, "AXPosition", axvalue_point(x, y))
        set_attr(el, "AXSize", axvalue_size(w, h))
        time.sleep(0.05)
    return False


def set_fullscreen(el, on=True):
    return set_bool(el, "AXFullScreen", on)


def is_fullscreen(el):
    v = attr(el, "AXFullScreen")
    return bool(v)


def set_minimized(el, on=True):
    return set_bool(el, "AXMinimized", on)


def set_frontmost(app_el, on=True):
    return set_bool(app_el, "AXFrontmost", on)


def zoom_button(win_el):
    """The green traffic-light button (AXFullScreenButton / AXZoomButton)."""
    for c in children(win_el):
        sub = attr(c, "AXSubrole")
        if sub in ("AXFullScreenButton", "AXZoomButton"):
            return c
    # some apps nest buttons inside a group
    for c in children(win_el):
        for cc in children(c):
            sub = attr(cc, "AXSubrole")
            if sub in ("AXFullScreenButton", "AXZoomButton"):
                return cc
    return None


def _collect_menu_items(el, out, depth):
    if depth > 8 or el is None:
        return
    role = attr(el, "AXRole")
    if role == "AXMenuItem":
        out.append(el)
    for c in children(el):
        _collect_menu_items(c, out, depth + 1)


def menu_items_under(el):
    out = []
    _collect_menu_items(el, out, 0)
    return out


def find_menu_item(pid, menu_titles, item_pred):
    """Find a menu item in an app's menu bar.

    menu_titles: iterable of menu-bar titles to search (e.g. ["Window"]).
    item_pred: function(title) -> bool for the item.
    """
    app = app_element(pid)
    bar = attr_ref(app, "AXMenuBar")
    if not bar:
        return None
    wanted = {t.lower() for t in menu_titles}
    for item in children(bar):
        t = (attr(item, "AXTitle") or "").lower()
        if t not in wanted:
            continue
        for mi in menu_items_under(item):
            if item_pred(attr(mi, "AXTitle") or ""):
                return mi
    return None
