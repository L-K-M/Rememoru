#if os(macOS)
import Darwin
import Foundation

/// SkyLight's bridged window-management operations: Objective-C objects
/// the WindowServer runs on the caller's behalf, which is why they still
/// work on other apps' windows with SIP enabled (macOS 26.4+ per yabai
/// 7.1.25 and Loop; the classes exist on 15.x but are unproven there).
///
/// Every operation is asynchronous: dispatching it only means "submitted",
/// so callers poll WindowServer state to confirm the effect.
enum BridgedOperations {
    private static let skyLight = SkyLight.library
    private static let messageSend: UnsafeMutableRawPointer? = dlopen(nil, RTLD_LAZY).flatMap {
        dlsym($0, "objc_msgSend")
    }

    private static let performSelector = NSSelectorFromString("performWithWMBridgeDelegate")
    private static let moveWindowsInit = NSSelectorFromString("initWithWindows:spaceID:")
    private static let moveSpaceInit = NSSelectorFromString("initWithSpaceID:displayIdentifier:index:")

    private static var moveWindowsClass: AnyClass? {
        _ = skyLight.isLoaded
        return NSClassFromString("SLSBridgedMoveWindowsToManagedSpaceOperation")
    }

    private static var moveSpaceClass: AnyClass? {
        _ = skyLight.isLoaded
        return NSClassFromString("SLSBridgedMoveManagedSpaceToDisplayIndexOperation")
    }

    static var canMoveWindows: Bool {
        isUsable(moveWindowsClass, initializer: moveWindowsInit)
    }

    static var canMoveSpaces: Bool {
        isUsable(moveSpaceClass, initializer: moveSpaceInit)
    }

    private static func isUsable(_ cls: AnyClass?, initializer: Selector) -> Bool {
        guard messageSend != nil, let object = cls as? NSObject.Type else { return false }
        return object.instancesRespond(to: initializer) && object.instancesRespond(to: performSelector)
    }

    /// Submits moving windows to a user Space. Returns false if the
    /// operation is unavailable on this macOS version.
    static func moveWindows(_ ids: [UInt32], toSpace space: UInt64) -> Bool {
        typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, NSArray, UInt64) -> UnsafeMutableRawPointer?
        guard canMoveWindows, let cls = moveWindowsClass, let initialize = send(as: InitFn.self),
              let allocated = allocate(cls) else { return false }
        let windows = ids.map { NSNumber(value: $0) } as NSArray
        guard let raw = initialize(allocated, moveWindowsInit, windows, space) else { return false }
        return perform(Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue())
    }

    /// Submits moving a Space to a zero-based final position among its
    /// display's Spaces.
    static func moveSpace(_ space: UInt64, displayIdentifier: String, toIndex index: Int) -> Bool {
        typealias InitFn = @convention(c) (UnsafeMutableRawPointer, Selector, UInt64, NSString, UInt32)
            -> UnsafeMutableRawPointer?
        guard canMoveSpaces, let cls = moveSpaceClass, let initialize = send(as: InitFn.self),
              let position = UInt32(exactly: index), let allocated = allocate(cls) else { return false }
        guard let raw = initialize(allocated, moveSpaceInit, space, displayIdentifier as NSString, position)
        else { return false }
        return perform(Unmanaged<AnyObject>.fromOpaque(raw).takeRetainedValue())
    }

    /// `+alloc`, returned at +1 as a raw pointer: `-init…` consumes it, so
    /// it must not pass through ARC in between.
    private static func allocate(_ cls: AnyClass) -> UnsafeMutableRawPointer? {
        typealias AllocFn = @convention(c) (AnyClass, Selector) -> UnsafeMutableRawPointer?
        return send(as: AllocFn.self)?(cls, NSSelectorFromString("alloc"))
    }

    /// `objc_msgSend` cast to one concrete method signature.
    private static func send<T>(as type: T.Type) -> T? {
        messageSend.map { unsafeBitCast($0, to: type) }
    }

    /// Asynchronous operations return void from `performWithWMBridgeDelegate`.
    private static func perform(_ operation: AnyObject) -> Bool {
        typealias PerformFn = @convention(c) (AnyObject, Selector) -> Void
        guard operation.responds(to: performSelector), let run = send(as: PerformFn.self) else { return false }
        run(operation, performSelector)
        return true
    }
}
#endif
