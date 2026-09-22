"""Find non-exported (local symtab) symbols inside loaded Mach-O images.

Needed for SLSPerformAsynchronousBridgedWindowManagementOperation, which is
not in SkyLight's export table, so dlsym() cannot see it. Same technique as
Hammerspoon PR #3889.
"""
import ctypes
import struct

from . import cf

_libc = None


def _lib():
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL("/usr/lib/libSystem.B.dylib")
    return _libc


def _f(name, restype, argtypes):
    def build():
        fn = getattr(_lib(), name)
        fn.restype = restype
        fn.argtypes = argtypes
        return fn

    return cf.LazySym(build)


_dyld_image_count = _f("_dyld_image_count", ctypes.c_uint32, [])
_dyld_get_image_name = _f(
    "_dyld_get_image_name", ctypes.c_char_p, [ctypes.c_uint32]
)
_dyld_get_image_vmaddr_slide = _f(
    "_dyld_get_image_vmaddr_slide", ctypes.c_long, [ctypes.c_uint32]
)
_dyld_get_image_header = _f(
    "_dyld_get_image_header", ctypes.c_void_p, [ctypes.c_uint32]
)

MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2

_MACH_HEADER_64 = struct.Struct("<8I")          # magic..reserved, 32 bytes
_SEGMENT_64_FIXED = struct.Struct("<II16sQQQQ")  # through filesize
_SYMTAB = struct.Struct("<6I")                   # cmd,cmdsize,symoff,nsyms,stroff,strsize
_NLIST_64 = struct.Struct("<IBBHQ")              # n_strx,n_type,n_sect,n_desc,n_value


def _parse_header(addr):
    raw = ctypes.string_at(addr, _MACH_HEADER_64.size)
    fields = _MACH_HEADER_64.unpack(raw)
    if fields[0] != MH_MAGIC_64:
        return None
    return fields[4]  # ncmds


def find_image(substr):
    """Return (header_addr, slide, name) for the first loaded image whose
    path contains `substr`."""
    for i in range(_dyld_image_count()):
        name = _dyld_get_image_name(i)
        if name and substr.encode() in name:
            return (
                _dyld_get_image_header(i),
                _dyld_get_image_vmaddr_slide(i),
                name.decode("utf-8", "replace"),
            )
    return None


def find_local_symbol(image_substr, symbol_name):
    """Return the slid address of `symbol_name` in the image whose path
    contains `image_substr`, or None."""
    found = find_image(image_substr)
    if not found:
        return None
    header, slide, _name = found
    ncmds = _parse_header(header)
    if ncmds is None:
        return None

    linkedit_vmaddr = linkedit_fileoff = None
    symoff = nsyms = stroff = None

    cursor = header + _MACH_HEADER_64.size
    for _ in range(ncmds):
        cmd, cmdsize = struct.unpack("<II", ctypes.string_at(cursor, 8))
        if cmd == LC_SEGMENT_64:
            seg = _SEGMENT_64_FIXED.unpack(
                ctypes.string_at(cursor, _SEGMENT_64_FIXED.size)
            )
            if seg[2].rstrip(b"\x00") == b"__LINKEDIT":
                linkedit_vmaddr, linkedit_fileoff = seg[3], seg[5]
        elif cmd == LC_SYMTAB:
            st = _SYMTAB.unpack(ctypes.string_at(cursor, _SYMTAB.size))
            symoff, nsyms, stroff = st[2], st[3], st[4]
        cursor += cmdsize

    if linkedit_vmaddr is None or symoff is None:
        return None

    linkedit_base = slide + linkedit_vmaddr - linkedit_fileoff
    strs = linkedit_base + stroff
    syms = linkedit_base + symoff

    wanted = symbol_name.encode()
    for i in range(nsyms):
        rec = ctypes.string_at(syms + i * _NLIST_64.size, _NLIST_64.size)
        n_strx, _t, _s, _d, n_value = _NLIST_64.unpack(rec)
        if n_strx == 0:
            continue
        if ctypes.string_at(strs + n_strx) == wanted:
            return slide + n_value
    return None
