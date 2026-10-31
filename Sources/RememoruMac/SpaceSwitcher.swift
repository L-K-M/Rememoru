#if os(macOS)
import CoreGraphics
import Foundation
import RememoruCore

/// Switches the visible Space of a display.
///
/// Primary: synthetic Dock-swipe gestures, one per step (yabai 7.1.19+ and
/// InstantSpaceSwitcher use this with SIP enabled on macOS 15/26). They
/// need only Accessibility and skip the slide animation. Fallback: clicking
/// the thumbnail in Mission Control. Plain SLSManagedDisplaySetCurrentSpace
/// is avoided: it desynchronizes the Dock's own idea of the current Space.
enum SpaceSwitcher {
    enum Method: String {
        case alreadyShown = "already shown"
        case gesture
        case missionControl = "Mission Control"
    }

    private enum Confirmation {
        case confirmed(Method)
        case unsettled
        case failed

        var method: Method? {
            if case .confirmed(let method) = self { return method }
            return nil
        }
    }

    // The legacy private Dock swipe fields are unreliable with macOS 27.
    static var supportsNativeGestures: Bool {
        ProcessInfo.processInfo.operatingSystemVersion.majorVersion < 27
    }

    /// Makes `spaceID` the visible space of its display. Returns the method
    /// that worked, or nil.
    static func show(
        spaceID: UInt64, display: LiveDisplay, readSpaces: @escaping () -> [LiveSpace],
        canContinue: @escaping () -> Bool = { true },
        ensureMissionControlClosed: (() -> Bool)? = nil,
        performSwipe: ((Int, LiveDisplay) -> Void)? = nil,
        showMissionControl: ((UInt32, () -> Int?) -> Bool)? = nil,
        trace: (String) -> Void = { _ in }
    ) -> Method? {
        guard canContinue() else { return nil }
        func current() -> [LiveSpace] {
            guard canContinue() else { return [] }
            return readSpaces().filter { $0.displayUUID == display.uuid && $0.kind.isRestorable }
                .sorted { $0.index < $1.index }
        }
        func isShown() -> Bool { current().first { $0.isActive }?.id == spaceID }
        let closeMissionControl = ensureMissionControlClosed ?? { MissionControl.close(canContinue: canContinue) }
        func finished(_ method: Method) -> Confirmation {
            // Active-Space state can update while Mission Control still
            // exposes thumbnail bounds. Window mutations require it closed.
            guard canContinue() else { return .failed }
            let closed = closeMissionControl()
            guard canContinue() else { return .failed }
            guard closed else {
                trace("  space switch target=\(spaceID) method=\(method.rawValue): Mission Control closure not confirmed")
                return .failed
            }
            let closedAt = Date()
            var stableSince = Date()
            let shown = MissionControl.wait(timeout: MissionControl.selectionSettleTimeout, interval: 0.05) { () -> Bool? in
                guard canContinue() else { return false }
                guard isShown() else { stableSince = Date(); return nil }
                return Date().timeIntervalSince(closedAt) >= MissionControl.selectionSettleDelay
                    && Date().timeIntervalSince(stableSince) >= MissionControl.activeStableDelay ? true : nil
            } == true
            guard canContinue() else { return .failed }
            guard shown else {
                trace("  space switch target=\(spaceID) method=\(method.rawValue): target did not remain active")
                return .unsettled
            }
            trace("  space switch target=\(spaceID) confirmed via \(method.rawValue)")
            return .confirmed(method)
        }

        if isShown() { return finished(.alreadyShown).method }
        let initial = current()
        guard canContinue(), initial.contains(where: { $0.id == spaceID }) else { return nil }
        trace("  space switch target=\(spaceID) active=\(initial.first(where: \.isActive).map { String($0.id) } ?? "unknown")"
            + " count=\(initial.count)")

        let swipeSpace = performSwipe ?? SpaceSwitcher.swipe
        let useGestures = performSwipe != nil || supportsNativeGestures
        var traversal: SpaceTraversal?
        // The reported array can disagree with Dock's navigation order.
        // Confirm actual IDs and keep sweeping in one direction until an
        // edge, rather than reversing whenever a reported index is crossed.
        while useGestures {
            guard canContinue() else { return nil }
            let spaces = current()
            guard spaces.contains(where: { $0.id == spaceID }) else { break }
            guard let previousID = spaces.first(where: \.isActive)?.id else {
                trace("  space switch target=\(spaceID): no active Space available for gestures")
                break
            }
            if previousID == spaceID { return finished(.gesture).method }
            // A transition can omit the active flag in the initial read.
            // Initialize from this fresh state before consuming a hop.
            if traversal == nil {
                traversal = SpaceTraversal(orderedIDs: spaces.map(\.id), activeID: previousID, targetID: spaceID)
            }
            guard let direction = traversal?.nextDirection() else { break }
            var observedID: UInt64?
            guard canContinue() else { return nil }
            swipeSpace(direction.rawValue, display)
            let changed = MissionControl.wait(timeout: 1.5, { () -> Bool? in
                guard canContinue() else { return false }
                guard let activeID = current().first(where: \.isActive)?.id,
                      activeID != previousID else { return nil }
                observedID = activeID
                return true
            }) == true
            guard canContinue() else { return nil }
            if !changed {
                trace("  space switch gesture from=\(previousID): no active-Space change confirmed")
            } else {
                trace("  space switch gesture from=\(previousID) to=\(observedID.map { String($0) } ?? "unknown")")
            }
            if traversal?.observe(from: previousID, to: observedID, orderedIDs: spaces.map(\.id)) != true { break }
        }
        guard canContinue() else { return nil }
        if isShown() { return finished(.gesture).method }
        guard canContinue() else { return nil }
        let ids = Set(initial.map(\.id))
        guard ids.count == initial.count else { return nil }
        let select: (UInt32, () -> Int?) -> Bool = showMissionControl ?? { id, index in
            MissionControl.showSpace(display: id, index: index, expectedCount: initial.count, canContinue: canContinue)
        }
        let hint = traversal?.orderMatchesNavigation == false ? nil : initial.firstIndex(where: { $0.id == spaceID })
        let indices = hint.map { [$0] } ?? []
        let candidates = indices + initial.indices.filter { $0 != hint }
        // A reported index is only a hint. Probe actual thumbnail positions
        // and accept a selection only after the requested ID is confirmed.
        for index in candidates {
            for _ in 0..<2 {
                guard canContinue(), Set(current().map(\.id)) == ids else { return nil }
                if isShown() {
                    switch finished(.missionControl) {
                    case .confirmed(let method): return method
                    case .failed: return nil
                    case .unsettled: break
                    }
                }
                guard canContinue() else { return nil }
                let result = select(display.id, {
                    guard canContinue(), Set(current().map(\.id)) == ids else { return nil }
                    return index
                })
                guard canContinue() else { return nil }
                trace("  space switch Mission Control target=\(spaceID) index=\(index) result=\(result)")
                // A press can succeed even if the closing wait timed out.
                let observed = MissionControl.wait(timeout: 2, { () -> Bool? in
                    guard canContinue() else { return false }
                    return isShown() ? true : nil
                }) == true
                if observed {
                    switch finished(.missionControl) {
                    case .confirmed(let method): return method
                    case .failed: return nil
                    case .unsettled: break
                    }
                }
                guard canContinue(), closeMissionControl(), canContinue() else { return nil }
                // Retry the same position once if its target appeared but
                // did not remain active through the settling interval.
                if !observed { break }
            }
        }
        trace("  space switch target=\(spaceID): no thumbnail selection confirmed the target")
        return nil
    }

    /// Posts `abs(steps)` Dock-swipe gestures on a display; negative steps
    /// go left. Field numbers are private CGEvent fields (see yabai's
    /// space_manager_focus_space_using_gesture).
    static func swipe(steps: Int, on display: LiveDisplay) {
        let point = CGPoint(x: display.frame.midX, y: display.frame.midY)
        guard steps != 0, let event = swipeEvent(steps: steps, at: point) else { return }
        // gestures act on the display under the pointer
        CGWarpMouseCursorPosition(point)
        for _ in 0..<abs(steps) {
            event.setIntegerValueField(field(132), value: 1)  // phase: began
            event.post(tap: .cgSessionEventTap)
            event.setIntegerValueField(field(132), value: 4)  // phase: ended
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Builds without posting, so the display routing can be verified
    /// without changing the user's current Space.
    static func swipeEvent(steps: Int, at point: CGPoint) -> CGEvent? {
        guard let event = CGEvent(source: nil) else { return nil }
        let sign: Double = steps > 0 ? 1 : -1
        event.setIntegerValueField(field(55), value: 30)    // event type: Dock control
        event.setIntegerValueField(field(110), value: 23)   // HID gesture type: Dock swipe
        event.setIntegerValueField(field(123), value: 1)    // swipe motion: horizontal
        event.setDoubleValueField(field(124), value: sign)  // swipe progress
        event.setDoubleValueField(field(129), value: sign * 9999)  // velocity x
        // An event captures the cursor's location when it is created.
        // Warping later does not retarget it to the destination display.
        event.location = point
        return event
    }

    /// Undocumented field numbers have no named case; the type is a plain
    /// UInt32 underneath.
    private static func field(_ raw: UInt32) -> CGEventField {
        unsafeBitCast(raw, to: CGEventField.self)
    }
}
#endif
