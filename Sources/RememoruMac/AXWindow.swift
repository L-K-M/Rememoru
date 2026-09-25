#if os(macOS)
import ApplicationServices
import Foundation
import RememoruCore

/// Thin Swift layer over AXUIElement for the handful of attributes and
/// actions Rememoru needs.
struct AXElement {
    let element: AXUIElement

    /// Unresponsive apps otherwise block each AX call for about six seconds.
    static let messagingTimeout: Float = 1.5

    static func application(_ pid: pid_t) -> AXElement {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, messagingTimeout)
        return AXElement(element: app)
    }

    static var systemWide: AXElement {
        AXElement(element: AXUIElementCreateSystemWide())
    }

    func value(_ attribute: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value
    }

    func string(_ attribute: String) -> String? {
        value(attribute) as? String
    }

    func bool(_ attribute: String) -> Bool? {
        (value(attribute) as? NSNumber)?.boolValue
    }

    func elements(_ attribute: String) -> [AXElement] {
        guard let array = value(attribute) as? [AXUIElement] else { return [] }
        return array.map(AXElement.init)
    }

    func element(_ attribute: String) -> AXElement? {
        guard let raw = value(attribute), CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return AXElement(element: raw as! AXUIElement)
    }

    var role: String? { string(kAXRoleAttribute) }
    var subrole: String? { string(kAXSubroleAttribute) }
    var title: String? { string(kAXTitleAttribute) }
    var identifier: String? { string(kAXIdentifierAttribute) }
    var children: [AXElement] { elements(kAXChildrenAttribute) }

    var pid: pid_t? {
        var pid: pid_t = 0
        return AXUIElementGetPid(element, &pid) == .success ? pid : nil
    }

    var position: CGPoint? {
        guard let raw = value(kAXPositionAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(raw as! AXValue, .cgPoint, &point) ? point : nil
    }

    var size: CGSize? {
        guard let raw = value(kAXSizeAttribute), CFGetTypeID(raw) == AXValueGetTypeID() else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(raw as! AXValue, .cgSize, &size) ? size : nil
    }

    var frame: Rect? {
        guard let position, let size else { return nil }
        return Rect(x: position.x, y: position.y, w: size.width, h: size.height)
    }

    @discardableResult
    func set(_ attribute: String, _ value: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(element, attribute as CFString, value)
    }

    @discardableResult
    func setBool(_ attribute: String, _ flag: Bool) -> Bool {
        set(attribute, (flag ? kCFBooleanTrue : kCFBooleanFalse)!) == .success
    }

    @discardableResult
    func perform(_ action: String) -> Bool {
        AXUIElementPerformAction(element, action as CFString) == .success
    }

    var actionNames: [String] {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { return [] }
        return names as? [String] ?? []
    }

    func setPosition(_ point: CGPoint) {
        var point = point
        if let value = AXValueCreate(.cgPoint, &point) { set(kAXPositionAttribute, value) }
    }

    func setSize(_ size: CGSize) {
        var size = size
        if let value = AXValueCreate(.cgSize, &size) { set(kAXSizeAttribute, value) }
    }

    /// Size, then position, then size again: moving to another display
    /// first can clamp the size, and resizing first can be refused when the
    /// window would extend past the screen edge.
    @discardableResult
    func setFrame(_ frame: Rect) -> Bool {
        setSize(CGSize(width: frame.w, height: frame.h))
        setPosition(CGPoint(x: frame.x, y: frame.y))
        setSize(CGSize(width: frame.w, height: frame.h))
        guard let actual = self.frame else { return false }
        return actual.isClose(to: frame, tolerance: 4)
    }

    /// CGWindowID of a window element, via the private but long-stable
    /// `_AXUIElementGetWindow` (used by AltTab, Rectangle, Hammerspoon,
    /// yabai). This is the only reliable way to tie an AX window to the
    /// WindowServer's window list; matching by title or frame is not.
    var windowID: UInt32? {
        guard let getWindow = HIServicesPrivate.getWindow else { return nil }
        var id: UInt32 = 0
        return getWindow(element, &id) == .success && id != 0 ? id : nil
    }
}

enum HIServicesPrivate {
    typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<UInt32>) -> AXError
    typealias CreateWithRemoteTokenFn = @convention(c) (CFData) -> Unmanaged<AXUIElement>?

    static let library = NativeLibrary(
        path: "/System/Library/Frameworks/ApplicationServices.framework/Frameworks/HIServices.framework/HIServices"
    )
    static let getWindow = library.symbol("_AXUIElementGetWindow", as: GetWindowFn.self)
    static let createWithRemoteToken = library.symbol(
        "_AXUIElementCreateWithRemoteToken", as: CreateWithRemoteTokenFn.self
    )
}
#endif
