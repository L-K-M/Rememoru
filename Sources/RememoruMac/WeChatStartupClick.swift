#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import RememoruCore

/// WeChat's startup control can omit an accessibility press action.
/// A mouse fallback must target the current button, never a saved coordinate.
enum WeChatStartupClick {
    private struct ClickTarget {
        let button: AXElement
        let frame: Rect
        let labels: [String]

        var point: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
    }

    static func click(
        window: AXElement, application: AXElement, pid: pid_t, findButton: () -> AXElement?,
        deadline: Date, cancellation: CancellationFlag, reportFailure: (String) -> Void = { _ in },
        isReady: () -> Bool
    ) -> Bool {
        let canContinue = { !cancellation.isCancelled && Date() < deadline }
        func fail(_ reason: String) -> Bool {
            reportFailure(Date() >= deadline ? "the startup action timed out" : reason)
            return false
        }
        guard canContinue(), window.pid == pid, canContinue(),
              let windowID = window.windowID, canContinue() else {
            return fail("the startup window is unavailable")
        }
        if isReady() { return canContinue() }
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
        var mainReady = false
        let visible = MissionControl.wait(timeout: min(2, deadline.timeIntervalSinceNow)) { () -> Bool? in
            guard canContinue() else { return false }
            mainReady = isReady()
            guard canContinue() else { return false }
            if mainReady { return true }
            return isFrontmost(pid) && onscreenFrame(windowID: windowID, pid: pid) != nil ? true : nil
        }
        if mainReady && canContinue() { return true }
        guard visible == true, canContinue() else {
            if canContinue(), isReady(), canContinue() { return true }
            return fail("the startup window did not become frontmost and visible")
        }

        var lastFailure = "the pointer target is not the Open WeChat button"
        func validatedTarget(_ button: AXElement, expectedFrame: Rect? = nil) -> ClickTarget? {
            guard canContinue(), window.pid == pid, canContinue(), window.windowID == windowID,
                  canContinue(), button.pid == pid, canContinue(), button.windowID == windowID,
                  canContinue() else {
                lastFailure = "the startup window or button is no longer available"
                return nil
            }
            var labels: [String] = []
            for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                guard canContinue() else { return nil }
                if let label = button.string(attribute) { labels.append(label) }
            }
            guard canContinue() else { return nil }
            let isButton = button.role == kAXButtonRole
            guard canContinue() else { return nil }
            let enabled = button.bool(kAXEnabledAttribute) == true
            guard canContinue(), WeChatStartup.isOpenButton(isButton: isButton, labels: labels), enabled else {
                lastFailure = "the startup control is no longer the enabled Open WeChat button"
                return nil
            }
            guard isFrontmost(pid), canContinue() else {
                lastFailure = "WeChat is no longer frontmost"
                return nil
            }
            guard let frame = button.frame, canContinue() else {
                lastFailure = "the startup button's frame is unavailable"
                return nil
            }
            guard expectedFrame == nil || frame == expectedFrame else {
                lastFailure = "the startup button moved before the click"
                return nil
            }
            guard let windowFrame = onscreenFrame(windowID: windowID, pid: pid), canContinue() else {
                lastFailure = "the startup window is no longer visible"
                return nil
            }
            guard valid(frame, inside: windowFrame) else {
                lastFailure = "the startup button is outside its visible window (button \(describe(frame)); window \(describe(windowFrame))); close Mission Control and retry"
                return nil
            }
            return ClickTarget(button: button, frame: frame, labels: labels)
        }

        // Activation can move or replace a startup control. Each probe must
        // rediscover it and hit-test its current frame, while a main window
        // appearing during the wait needs no click at all.
        let completed = performWhenReady(
            timeout: min(2, deadline.timeIntervalSinceNow), canContinue: canContinue, isReady: isReady,
            discover: { () -> ClickTarget? in
                guard canContinue(), window.pid == pid, canContinue(), window.windowID == windowID,
                      canContinue(), let button = findButton(), canContinue() else {
                    lastFailure = "the startup window or button is no longer available"
                    return nil
                }
                return validatedTarget(button)
            },
            matches: { target in
                hitMatches(button: target.button, at: target.point, canContinue: canContinue,
                           reportMiss: { lastFailure = $0 })
            },
            perform: { target in
                // Re-read all guards after readiness checks, immediately
                // before posting. Failed verification retries without a click.
                guard let current = validatedTarget(target.button, expectedFrame: target.frame), canContinue() else {
                    return false
                }
                let frontmost = isFrontmost(pid)
                guard frontmost, canContinue() else {
                    lastFailure = "WeChat is no longer frontmost"
                    return false
                }
                let hit = hitMatches(button: current.button, at: current.point, canContinue: canContinue,
                                     reportMiss: { lastFailure = $0 })
                guard canContinue(), WeChatStartup.canClickOpenButton(
                    isButton: true, labels: current.labels, isEnabled: true,
                    isFrontmost: frontmost, isWindowOnscreen: true, hitMatchesButton: hit
                ), canContinue() else { return false }
                guard let down = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown,
                                         mouseCursorPosition: current.point, mouseButton: .left),
                      let up = CGEvent(mouseEventSource: nil, mouseType: .leftMouseUp,
                                       mouseCursorPosition: current.point, mouseButton: .left), canContinue() else {
                    lastFailure = "could not create the mouse click"
                    return false
                }
                down.setIntegerValueField(.mouseEventClickState, value: 1)
                up.setIntegerValueField(.mouseEventClickState, value: 1)
                down.post(tap: .cghidEventTap)
                Thread.sleep(forTimeInterval: 0.05)
                // Always release after posting down, including cancellation.
                up.post(tap: .cghidEventTap)
                return true
            }
        )
        return completed || fail(lastFailure)
    }

    static func performWhenReady<Target>(
        timeout: TimeInterval, interval: TimeInterval = 0.05,
        canContinue: () -> Bool, isReady: () -> Bool, discover: () -> Target?,
        matches: (Target) -> Bool, perform: (Target) -> Bool
    ) -> Bool {
        let completed = MissionControl.wait(timeout: timeout, interval: interval) { () -> Bool? in
            guard canContinue() else { return false }
            let ready = isReady()
            guard canContinue() else { return false }
            if ready { return true }
            let discovered = discover()
            guard canContinue() else { return false }
            guard let target = discovered else { return nil }
            let matched = matches(target)
            guard canContinue() else { return false }
            guard matched else { return nil }
            let readyBeforeAction = isReady()
            guard canContinue() else { return false }
            if readyBeforeAction { return true }
            let performed = perform(target)
            guard canContinue() else { return false }
            return performed ? true : nil
        }
        if completed == true { return canContinue() }
        guard canContinue() else { return false }
        let ready = isReady()
        return ready && canContinue()
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
