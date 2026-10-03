#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import RememoruCore

/// Qt's startup control can support focus without an accessibility press.
/// A mouse fallback must target the current button, never a saved coordinate.
enum WeChatStartupClick {
    static func click(
        button: AXElement, window: AXElement, application: AXElement, pid: pid_t,
        deadline: Date, cancellation: CancellationFlag, isReady: () -> Bool
    ) -> Bool {
        let canContinue = { !cancellation.isCancelled && Date() < deadline }
        guard canContinue(), let windowID = window.windowID, canContinue() else { return false }
        if isReady() { return true }
        guard canContinue() else { return false }

        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }

        let managed = SkyLight.managedSpaces()
        guard canContinue(),
              let spaceID = managed.resolveSpace(windowID: windowID, reported: SkyLight.spaces(ofWindow: windowID)),
              let space = managed.spaces.first(where: { $0.id == spaceID }) else { return false }
        let order = SkyLight.managedDisplaySpaces().compactMap { $0["Display Identifier"] as? String }
        guard canContinue(),
              let display = Displays.current(skyLightOrder: order).first(where: { $0.uuid == space.displayUUID }),
              SpaceSwitcher.show(spaceID: spaceID, display: display, readSpaces: { SkyLight.managedSpaces().spaces },
                                 canContinue: canContinue) != nil,
              canContinue() else { return false }

        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        guard canContinue() else { return false }
        application.setBool(kAXFrontmostAttribute, true)
        guard canContinue() else { return false }
        window.perform(kAXRaiseAction)
        guard canContinue(), MissionControl.wait(timeout: min(2, deadline.timeIntervalSinceNow), { () -> Bool? in
            guard canContinue(), isFrontmost(pid), onscreenFrame(windowID: windowID, pid: pid) != nil else { return nil }
            return true
        }) != nil, canContinue() else { return false }

        // Switching Spaces can reveal a main window that was missing earlier.
        if isReady() { return true }
        guard canContinue(), let frame = button.frame, canContinue(),
              let windowFrame = onscreenFrame(windowID: windowID, pid: pid),
              valid(frame, inside: windowFrame) else { return false }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else { return false }

        var labels: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard canContinue() else { return false }
            if let label = button.string(attribute) { labels.append(label) }
        }
        guard canContinue(), button.frame == frame, canContinue(),
              let currentWindowFrame = onscreenFrame(windowID: windowID, pid: pid),
              valid(frame, inside: currentWindowFrame), canContinue() else { return false }
        let isButton = button.role == kAXButtonRole
        guard canContinue() else { return false }
        let isEnabled = button.bool(kAXEnabledAttribute) == true
        guard canContinue(), WeChatStartup.canClickOpenButton(
            isButton: isButton, labels: labels, isEnabled: isEnabled,
            isFrontmost: isFrontmost(pid), isWindowOnscreen: true,
            hitMatchesButton: hitMatches(button: button, at: point, canContinue: canContinue)
        ), canContinue() else { return false }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        // Always release after posting down, including if cancellation arrives.
        up.post(tap: .cghidEventTap)
        return true
    }

    private static func isFrontmost(_ pid: pid_t) -> Bool {
        NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    private static func onscreenFrame(windowID: UInt32, pid: pid_t) -> Rect? {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] else { return nil }
        return WindowFilter.candidates(from: info).first { $0.id == windowID && $0.pid == pid }?.frame
    }

    private static func valid(_ frame: Rect, inside window: Rect) -> Bool {
        guard [frame.x, frame.y, frame.w, frame.h, window.x, window.y, window.w, window.h].allSatisfy(\.isFinite),
              frame.w > 0, frame.h > 0 else { return false }
        return CGRect(x: window.x, y: window.y, width: window.w, height: window.h).contains(
            CGRect(x: frame.x, y: frame.y, width: frame.w, height: frame.h)
        )
    }

    private static func hitMatches(button: AXElement, at point: CGPoint, canContinue: () -> Bool) -> Bool {
        var raw: AXUIElement?
        guard canContinue(),
              AXUIElementCopyElementAtPosition(AXElement.systemWide.element, Float(point.x), Float(point.y), &raw) == .success,
              let raw else { return false }
        var hit: AXElement? = AXElement(element: raw)
        // A hit can be the button's text child. Compare AX identity up its parents.
        for _ in 0..<8 {
            guard canContinue(), let current = hit else { return false }
            if CFEqual(current.element, button.element) { return true }
            hit = current.element(kAXParentAttribute)
        }
        return false
    }
}
#endif
