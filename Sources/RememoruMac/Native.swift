#if os(macOS)
import Darwin

/// A dynamically loaded image whose symbols are resolved at runtime.
///
/// Private SkyLight and HIServices functions are looked up with `dlsym`
/// rather than linked: if a macOS update removes one, the feature that
/// needs it reports itself unavailable instead of the app failing to
/// launch with a missing-symbol error.
final class NativeLibrary {
    let path: String
    private let handle: UnsafeMutableRawPointer?

    init(path: String) {
        self.path = path
        handle = dlopen(path, RTLD_LAZY)
    }

    var isLoaded: Bool { handle != nil }

    func symbol<T>(_ name: String, as type: T.Type) -> T? {
        guard let handle, let address = dlsym(handle, name) else { return nil }
        return unsafeBitCast(address, to: type)
    }

    func address(of name: String) -> UnsafeMutableRawPointer? {
        guard let handle else { return nil }
        return dlsym(handle, name)
    }
}
#endif
