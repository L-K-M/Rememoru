"""Tiny Objective-C runtime bridge (just enough for the SLS bridged ops
and NSRunningApplication lookups)."""
import ctypes

from . import cf

_objc = None


def _lib():
    global _objc
    if _objc is None:
        _objc = ctypes.CDLL("/usr/lib/libobjc.A.dylib")
    return _objc


def _f(name, restype, argtypes):
    def build():
        fn = getattr(_lib(), name)
        fn.restype = restype
        fn.argtypes = argtypes
        return fn

    return cf.LazySym(build)


objc_getClass = _f("objc_getClass", ctypes.c_void_p, [ctypes.c_char_p])
sel_registerName = _f("sel_registerName", ctypes.c_void_p, [ctypes.c_char_p])

_msgsend_addr = None


def _msgsend():
    global _msgsend_addr
    if _msgsend_addr is None:
        _msgsend_addr = ctypes.cast(
            _lib().objc_msgSend, ctypes.c_void_p
        ).value
    return _msgsend_addr


_sel_cache = {}


def sel(name):
    s = _sel_cache.get(name)
    if s is None:
        s = sel_registerName(name.encode("utf-8"))
        _sel_cache[name] = s
    return s


def get_class(name):
    return objc_getClass(name.encode("utf-8"))


def make_caller(restype, *argtypes):
    def build():
        return ctypes.CFUNCTYPE(
            restype, ctypes.c_void_p, ctypes.c_void_p, *argtypes
        )(_msgsend())

    return cf.LazySym(build)


# Pre-built signatures we need
_send_id = make_caller(ctypes.c_void_p)                       # (id) -> id
_send_id_id_u64 = make_caller(                                # (id, u64) -> id
    ctypes.c_void_p, ctypes.c_void_p, ctypes.c_uint64
)
_send_id_i32 = make_caller(                                   # (i32) -> id
    ctypes.c_void_p, ctypes.c_int32
)
_send_bool_sel = make_caller(                                 # (SEL) -> BOOL
    ctypes.c_bool, ctypes.c_void_p
)


def alloc(cls):
    return _send_id(cls, sel("alloc"))


def init_with_windows_space_id(obj, windows_cfarray, space_id):
    return _send_id_id_u64(obj, sel("initWithWindows:spaceID:"), windows_cfarray, space_id)


def instances_respond_to(cls, selector_name):
    return _send_bool_sel(cls, sel("instancesRespondToSelector:"), sel(selector_name))


def running_app_with_pid(pid):
    cls = get_class("NSRunningApplication")
    if not cls:
        return None
    return _send_id_i32(cls, sel("runningApplicationWithProcessIdentifier:"), pid)


def bundle_identifier_of(nsrunningapp):
    if not nsrunningapp:
        return None
    return _send_id(nsrunningapp, sel("bundleIdentifier"))


def autorelease_pool():
    """Create an NSAutoreleasePool — needed around calls that return
    autoreleased objects (NSRunningApplication lookups); without one they
    leak and spam 'no pool in place' warnings."""
    cls = get_class("NSAutoreleasePool")
    if not cls:
        return None
    pool = _send_id(cls, sel("alloc"))
    return _send_id(pool, sel("init")) if pool else None


def drain_pool(pool):
    if pool:
        _send_id(pool, sel("drain"))
