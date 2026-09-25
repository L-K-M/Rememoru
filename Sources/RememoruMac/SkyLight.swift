#if os(macOS)
import CoreFoundation
import Foundation
import RememoruCore

/// Private WindowServer (SkyLight) reads. All symbols resolve at runtime;
/// see `NativeLibrary`.
enum SkyLight {
    static let library = NativeLibrary(path: "/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight")

    private typealias MainConnectionIDFn = @convention(c) () -> Int32
    private typealias CopyManagedDisplaySpacesFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias SpaceGetTypeFn = @convention(c) (Int32, UInt64) -> Int32

    private static let mainConnectionID = library.symbol("SLSMainConnectionID", as: MainConnectionIDFn.self)
    private static let copyManagedDisplaySpaces = library.symbol(
        "SLSCopyManagedDisplaySpaces", as: CopyManagedDisplaySpacesFn.self
    )
    private static let copySpacesForWindows = library.symbol(
        "SLSCopySpacesForWindows", as: CopySpacesForWindowsFn.self
    )
    private static let spaceGetType = library.symbol("SLSSpaceGetType", as: SpaceGetTypeFn.self)

    /// Current, other and user spaces (kCGSAllSpacesMask).
    private static let allSpacesMask: Int32 = 0x7

    static var connection: Int32? { mainConnectionID?() }

    static var availability: [(String, Bool)] {
        [
            ("SLSMainConnectionID", mainConnectionID != nil),
            ("SLSCopyManagedDisplaySpaces", copyManagedDisplaySpaces != nil),
            ("SLSCopySpacesForWindows", copySpacesForWindows != nil),
            ("SLSSpaceGetType", spaceGetType != nil),
        ]
    }

    /// Raw `SLSCopyManagedDisplaySpaces` dictionaries.
    static func managedDisplaySpaces() -> [[String: Any]] {
        guard let cid = connection, let copy = copyManagedDisplaySpaces,
              let array = copy(cid)?.takeRetainedValue() else { return [] }
        return array as? [[String: Any]] ?? []
    }

    static func spaceType(_ id: UInt64) -> Int? {
        guard let cid = connection, let spaceGetType else { return nil }
        return Int(spaceGetType(cid, id))
    }

    static func managedSpaces() -> ManagedSpaces {
        SpaceParser.parse(managedDisplaySpaces(), spaceType: spaceType)
    }

    /// Space ids of ONE window. The call takes an array, but for several
    /// windows it returns the union of their spaces, not one entry per
    /// window, so windows must be queried one at a time.
    static func spaces(ofWindow id: UInt32) -> [UInt64] {
        guard let cid = connection, let copy = copySpacesForWindows else { return [] }
        let windows = [NSNumber(value: id)] as CFArray
        guard let result = copy(cid, allSpacesMask, windows)?.takeRetainedValue() else { return [] }
        return (result as? [NSNumber] ?? []).map(\.uint64Value)
    }
}
#endif
