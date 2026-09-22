"""CoreFoundation plumbing via ctypes.

Everything here is a plain C API, so it works on a stock macOS python3.
"""
import ctypes

CF_PATH = "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation"
_CF = None


def _lib():
    """Load CoreFoundation on first use — keeps the module importable (and
    --help/doctor usable) off-macOS or on broken installs."""
    global _CF
    if _CF is None:
        _CF = ctypes.CDLL(CF_PATH)
    return _CF


class LazySym(object):
    """Callable proxy that resolves a native symbol on first call.

    Truthiness reports availability (False when the library or symbol is
    missing), so `if sym:` / `sym is not None`-style feature checks keep
    working without loading anything at import time.
    """

    __slots__ = ("_builder", "_fn", "_done")

    def __init__(self, builder):
        self._builder = builder
        self._fn = None
        self._done = False

    def resolve(self):
        if not self._done:
            self._done = True
            try:
                self._fn = self._builder()
            except (OSError, AttributeError):
                self._fn = None
        return self._fn

    def __call__(self, *args):
        fn = self.resolve()
        if fn is None:
            raise RuntimeError("native symbol unavailable (not macOS?)")
        return fn(*args)

    def __bool__(self):
        return self.resolve() is not None


CFIndex = ctypes.c_long
CFTypeID = ctypes.c_ulong


class CFRange(ctypes.Structure):
    _fields_ = [("location", CFIndex), ("length", CFIndex)]


kCFStringEncodingUTF8 = 0x08000100

# CFNumberType values we care about
_CFNUM_FLOAT_TYPES = {5, 6, 12, 13, 16}  # Float32, Float64, Float, Double, CGFloat
_KCFNUM_SINT64 = 4
_KCFNUM_FLOAT64 = 6


def _f(name, restype, argtypes):
    def build():
        fn = getattr(_lib(), name)
        fn.restype = restype
        fn.argtypes = argtypes
        return fn

    return LazySym(build)


CFGetTypeID = _f("CFGetTypeID", CFTypeID, [ctypes.c_void_p])
CFRelease = _f("CFRelease", None, [ctypes.c_void_p])
CFRetain = _f("CFRetain", ctypes.c_void_p, [ctypes.c_void_p])

CFStringGetTypeID = _f("CFStringGetTypeID", CFTypeID, [])
CFStringCreateWithCString = _f(
    "CFStringCreateWithCString",
    ctypes.c_void_p,
    [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_uint32],
)
CFStringGetLength = _f("CFStringGetLength", CFIndex, [ctypes.c_void_p])
CFStringGetCStringPtr = _f(
    "CFStringGetCStringPtr", ctypes.c_char_p, [ctypes.c_void_p, ctypes.c_uint32]
)
CFStringGetCString = _f(
    "CFStringGetCString",
    ctypes.c_bool,
    [ctypes.c_void_p, ctypes.c_char_p, CFIndex, ctypes.c_uint32],
)
CFStringGetMaximumSizeForEncoding = _f(
    "CFStringGetMaximumSizeForEncoding", CFIndex, [CFIndex, ctypes.c_uint32]
)

CFNumberGetTypeID = _f("CFNumberGetTypeID", CFTypeID, [])
CFNumberGetType = _f("CFNumberGetType", ctypes.c_int, [ctypes.c_void_p])
CFNumberGetValue = _f(
    "CFNumberGetValue", ctypes.c_bool, [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
)
CFNumberCreate = _f(
    "CFNumberCreate", ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_int, ctypes.c_void_p]
)

CFBooleanGetTypeID = _f("CFBooleanGetTypeID", CFTypeID, [])
CFBooleanGetValue = _f("CFBooleanGetValue", ctypes.c_bool, [ctypes.c_void_p])

CFArrayGetTypeID = _f("CFArrayGetTypeID", CFTypeID, [])
CFArrayGetCount = _f("CFArrayGetCount", CFIndex, [ctypes.c_void_p])
CFArrayGetValueAtIndex = _f(
    "CFArrayGetValueAtIndex", ctypes.c_void_p, [ctypes.c_void_p, CFIndex]
)
CFArrayCreate = _f(
    "CFArrayCreate",
    ctypes.c_void_p,
    [ctypes.c_void_p, ctypes.c_void_p, CFIndex, ctypes.c_void_p],
)

CFDictionaryGetTypeID = _f("CFDictionaryGetTypeID", CFTypeID, [])
CFDictionaryGetCount = _f("CFDictionaryGetCount", CFIndex, [ctypes.c_void_p])
CFDictionaryGetValue = _f(
    "CFDictionaryGetValue", ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_void_p]
)
CFDictionaryGetKeysAndValues = _f(
    "CFDictionaryGetKeysAndValues",
    None,
    [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_void_p],
)

CFUUIDCreateString = _f(
    "CFUUIDCreateString", ctypes.c_void_p, [ctypes.c_void_p, ctypes.c_void_p]
)

def __getattr__(name):
    # kCFBooleanTrue / kCFBooleanFalse — resolved lazily via in_dll
    if name in ("kCFBooleanTrue", "kCFBooleanFalse"):
        v = ctypes.c_void_p.in_dll(_lib(), name)
        globals()[name] = v
        return v
    raise AttributeError(name)

_str_cache = {}


def cfstr(s):
    """Return a cached (never released) CFStringRef for a python str."""
    if s is None:
        return None
    ref = _str_cache.get(s)
    if ref is None:
        ref = CFStringCreateWithCString(None, s.encode("utf-8"), kCFStringEncodingUTF8)
        _str_cache[s] = ref
    return ref


def cfstring_to_str(ref):
    if not ref:
        return None
    ptr = CFStringGetCStringPtr(ref, kCFStringEncodingUTF8)
    if ptr:
        return ptr.decode("utf-8", "replace")
    size = CFStringGetMaximumSizeForEncoding(
        CFStringGetLength(ref), kCFStringEncodingUTF8
    ) + 1
    buf = ctypes.create_string_buffer(size)
    if CFStringGetCString(ref, buf, size, kCFStringEncodingUTF8):
        return buf.value.decode("utf-8", "replace")
    return None


def cfnumber_to_py(ref):
    t = CFNumberGetType(ref)
    if t in _CFNUM_FLOAT_TYPES:
        v = ctypes.c_double(0)
        if CFNumberGetValue(ref, _KCFNUM_FLOAT64, ctypes.byref(v)):
            return v.value
    v = ctypes.c_int64(0)
    if CFNumberGetValue(ref, _KCFNUM_SINT64, ctypes.byref(v)):
        return v.value
    v = ctypes.c_double(0)
    if CFNumberGetValue(ref, _KCFNUM_FLOAT64, ctypes.byref(v)):
        return v.value
    return None


def to_py(ref, depth=0):
    """Convert a CFTypeRef to plain python objects.

    Unknown types come back as {"__cfref__": <address>} so callers can still
    use the pointer (e.g. AXUIElementRef). NOTE: the pointer is only valid
    while the containing CF object is alive — callers that CFRelease the
    container right after conversion get dead pointers here.
    """
    if not ref or depth > 16:
        return None
    tid = CFGetTypeID(ref)
    if tid == CFStringGetTypeID():
        return cfstring_to_str(ref)
    if tid == CFNumberGetTypeID():
        return cfnumber_to_py(ref)
    if tid == CFBooleanGetTypeID():
        return bool(CFBooleanGetValue(ref))
    if tid == CFArrayGetTypeID():
        return [
            to_py(CFArrayGetValueAtIndex(ref, i), depth + 1)
            for i in range(CFArrayGetCount(ref))
        ]
    if tid == CFDictionaryGetTypeID():
        n = CFDictionaryGetCount(ref)
        keys = (ctypes.c_void_p * n)()
        vals = (ctypes.c_void_p * n)()
        CFDictionaryGetKeysAndValues(ref, keys, vals)
        out = {}
        for i in range(n):
            k = cfstring_to_str(keys[i])
            out[k if k else "__nonstring_key__%d" % i] = to_py(vals[i], depth + 1)
        return out
    return {"__cfref__": ref}


def array_to_refs(arr):
    """Return the raw CFTypeRef elements of a CFArray as a list of ints."""
    if not arr:
        return []
    return [CFArrayGetValueAtIndex(arr, i) for i in range(CFArrayGetCount(arr))]


def cfarray_of_ints(ints):
    """Build a CFArray of CFNumbers from python ints.

    The array is created with NULL callbacks, so it does NOT retain its
    elements — the CFNumbers are deliberately leaked to keep the pointers
    valid even if the array outlives this call (e.g. inside the async
    bridged WindowServer operation).
    """
    nums = []
    for i in ints:
        v = ctypes.c_int64(int(i))
        nums.append(CFNumberCreate(None, _KCFNUM_SINT64, ctypes.byref(v)))
    if nums:
        backing = (ctypes.c_void_p * len(nums))(*nums)
        return CFArrayCreate(None, backing, len(nums), None)
    return CFArrayCreate(None, None, 0, None)
