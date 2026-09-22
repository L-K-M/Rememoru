"""Rememoru — snapshot and restore macOS window layouts across displays and Spaces.

Pure-stdlib implementation using ctypes against SkyLight, CoreGraphics,
CoreFoundation and the Accessibility (HIServices) frameworks. No SIP changes
required; all restore mutations go through AX UI automation plus the private
bridged WindowServer move operation that still works under SIP.
"""

__version__ = "0.1.0"
