#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import RememoruCore

/// WeChat's startup control can omit an accessibility press action.
/// A mouse fallback must target the current button, never a saved coordinate.
enum WeChatStartupClick {
    static func click(
        button: AXElement, window: AXElement, application: AXElement, pid: pid_t,
        deadline: Date, cancellation: CancellationFlag, reportFailure: (String) -> Void = { _ in },
        isReady: () -> Bool
    ) -> Bool {
        let canContinue = { !cancellation.isCancelled && Date() < deadline }
        func fail(_ reason: String) -> Bool {
            reportFailure(Date() >= deadline ? "the startup action timed out" : reason)
            return false
        }
        guard canContinue(), let windowID = window.windowID, canContinue() else {
            return fail("the startup window is unavailable")
        }
        if isReady() { return true }
        guard canContinue() else { return fail("the startup action was cancelled") }

        let pointer = CGEvent(source: nil)?.location
        defer { if let pointer { CGWarpMouseCursorPosition(pointer) } }

        let managed = SkyLight.managedSpaces()
        guard canContinue(),
              let spaceID = managed.resolveSpace(windowID: windowID, reported: SkyLight.spaces(ofWindow: windowID)),
              let space = managed.spaces.first(where: { $0.id == spaceID }) else {
            return fail("the startup window has no known Space")
        }
        let order = SkyLight.managedDisplaySpaces().compactMap { $0["Display Identifier"] as? String }
        guard canContinue(),
              let display = Displays.current(skyLightOrder: order).first(where: { $0.uuid == space.displayUUID }) else {
            return fail("the startup window's display is unavailable")
        }
        guard SpaceSwitcher.show(spaceID: spaceID, display: display, readSpaces: { SkyLight.managedSpaces().spaces },
                                 canContinue: canContinue) != nil,
              canContinue() else { return fail("could not show the startup window's Space") }

        NSRunningApplication(processIdentifier: pid)?.activate(options: [])
        guard canContinue() else { return fail("the startup action was cancelled") }
        application.setBool(kAXFrontmostAttribute, true)
        guard canContinue() else { return fail("the startup action was cancelled") }
        window.perform(kAXRaiseAction)
        guard canContinue(), MissionControl.wait(timeout: min(2, deadline.timeIntervalSinceNow), { () -> Bool? in
            guard canContinue(), isFrontmost(pid), onscreenFrame(windowID: windowID, pid: pid) != nil else { return nil }
            return true
        }) != nil, canContinue() else { return fail("the startup window did not become frontmost and visible") }

        // Switching Spaces can reveal a main window that was missing earlier.
        if isReady() { return true }
        guard canContinue(), let frame = button.frame, canContinue() else {
            return fail("the startup button's frame is unavailable")
        }
        guard let windowFrame = onscreenFrame(windowID: windowID, pid: pid) else {
            return fail("the startup window is no longer visible")
        }
        guard valid(frame, inside: windowFrame) else {
            return fail("the startup button is outside its visible window (button \(describe(frame)); window \(describe(windowFrame))); close Mission Control and retry")
        }
        let point = CGPoint(x: frame.midX, y: frame.midY)
        guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                 mouseCursorPosition: point, mouseButton: .left),
              let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                               mouseCursorPosition: point, mouseButton: .left) else {
            return fail("could not create the mouse click")
        }

        // Frontmost and onscreen flags can precede AX hit-test readiness
        // during activation. Wait for the same exact system-wide target;
        // an unrelated or covered control must never authorize a click.
        var hitFailure = "the pointer target is not the Open WeChat button"
        guard waitForHit(timeout: min(2, deadline.timeIntervalSinceNow), canContinue: canContinue, matches: {
            hitMatches(button: button, at: point, canContinue: canContinue, reportMiss: { hitFailure = $0 })
        }) else { return fail(hitFailure) }

        // Re-read every action guard after waiting: the window or account
        // panel may have changed while AX was becoming ready.
        var labels: [String] = []
        for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            guard canContinue() else { return fail("the startup action was cancelled") }
            if let label = button.string(attribute) { labels.append(label) }
        }
        guard canContinue(), button.frame == frame, canContinue(),
              let currentWindowFrame = onscreenFrame(windowID: windowID, pid: pid),
              valid(frame, inside: currentWindowFrame), canContinue() else {
            return fail("the startup button or window moved before the click")
        }
        let isButton = button.role == kAXButtonRole
        guard canContinue() else { return fail("the startup action was cancelled") }
        let isEnabled = button.bool(kAXEnabledAttribute) == true
        guard canContinue() else { return fail("the startup action was cancelled") }
        let frontmost = isFrontmost(pid)
        let targetMatches = hitMatches(button: button, at: point, canContinue: canContinue,
                                       reportMiss: { hitFailure = $0 })
        guard canContinue(), WeChatStartup.canClickOpenButton(
            isButton: isButton, labels: labels, isEnabled: isEnabled,
            isFrontmost: frontmost, isWindowOnscreen: true, hitMatchesButton: targetMatches
        ), canContinue() else {
            if !isButton || !WeChatStartup.isOpenButton(isButton: isButton, labels: labels) || !isEnabled {
                return fail("the startup control is no longer the enabled Open WeChat button")
            }
            if !frontmost { return fail("WeChat is no longer frontmost") }
            return fail(hitFailure)
        }

        down.setIntegerValueField(.mouseEventClickState, value: 1)
        up.setIntegerValueField(.mouseEventClickState, value: 1)
        down.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        // Always release after posting down, including if cancellation arrives.
        up.post(tap: .cghidEventTap)
        return true
    }

    static func waitForHit(
        timeout: TimeInterval, interval: TimeInterval = 0.05,
        canContinue: () -> Bool, matches: () -> Bool
    ) -> Bool {
        let confirmed = MissionControl.wait(timeout: timeout, interval: interval) { () -> Bool? in
            guard canContinue() else { return false }
            let matched = matches()
            guard canContinue() else { return false }
            return matched ? true : nil
        }
        return confirmed == true && canContinue()
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

    private static func describe(_ frame: Rect) -> String {
        String(format: "(%.0f, %.0f) %.0f x %.0f", frame.x, frame.y, frame.w, frame.h)
    }

    private static func hitMatches(
        button: AXElement, at point: CGPoint, canContinue: () -> Bool,
        reportMiss: (String) -> Void
    ) -> Bool {
        var raw: AXUIElement?
        guard canContinue() else { return false }
        let error = AXUIElementCopyElementAtPosition(
            AXElement.systemWide.element, Float(point.x), Float(point.y), &raw
        )
        guard error == .success, let raw else {
            reportMiss("the pointer target is unavailable (AX error \(error.rawValue))")
            return false
        }
        var hit: AXElement? = AXElement(element: raw)
        // A hit can be the button's text child. Compare AX identity up its parents.
        for _ in 0..<8 {
            guard canContinue() else { return false }
            guard let current = hit else { break }
            if CFEqual(current.element, button.element) { return true }
            hit = current.element(kAXParentAttribute)
        }
        guard canContinue() else { return false }
        let role = AXElement(element: raw).role ?? "unknown role"
        reportMiss("the pointer target is not the Open WeChat button (hit \(role))")
        return false
    }
}
#endif
