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

    /// Makes `spaceID` the visible space of its display. Returns the method
    /// that worked, or nil.
    static func show(
        spaceID: UInt64, display: LiveDisplay, readSpaces: @escaping () -> [LiveSpace],
        canContinue: @escaping () -> Bool = { true },
        ensureMissionControlClosed: (() -> Bool)? = nil,
        showMissionControl: (UInt32, () -> Int?) -> Bool = { MissionControl.showSpace(display: $0, index: $1) }
    ) -> Method? {
        guard canContinue() else { return nil }
        func current() -> [LiveSpace] {
            guard canContinue() else { return [] }
            return readSpaces().filter { $0.displayUUID == display.uuid }.sorted { $0.index < $1.index }
        }
        func isShown() -> Bool { current().first { $0.isActive }?.id == spaceID }
        let closeMissionControl = ensureMissionControlClosed ?? { MissionControl.close(canContinue: canContinue) }
        func finished(_ method: Method) -> Method? {
            // Active-Space state can update while Mission Control still
            // exposes thumbnail bounds. Window mutations require it closed.
            guard canContinue(), closeMissionControl(), canContinue(), isShown(), canContinue() else { return nil }
            return method
        }

        if isShown() { return finished(.alreadyShown) }
        let initial = current()
        guard canContinue(), initial.contains(where: { $0.id == spaceID }) else { return nil }

        // Dock processes gestures asynchronously. Confirm each hop before
        // sending another, and recalculate after Spaces are reordered or
        // removed by a fullscreen transition. Bound retries if state keeps
        // changing while the restore runs.
        for _ in 0..<initial.count {
            guard canContinue() else { return nil }
            let spaces = current()
            guard let target = spaces.firstIndex(where: { $0.id == spaceID }),
                  let active = spaces.firstIndex(where: \.isActive) else { break }
            if active == target { return finished(.gesture) }
            let previousID = spaces[active].id
            guard canContinue() else { return nil }
            swipe(steps: target > active ? 1 : -1, on: display)
            guard MissionControl.wait(timeout: 1.5, { () -> Bool? in
                guard canContinue() else { return false }
                guard let activeID = current().first(where: \.isActive)?.id,
                      activeID != previousID else { return nil }
                return true
            }) == true else { break }
        }
        guard canContinue() else { return nil }
        if isShown() { return finished(.gesture) }
        guard canContinue() else { return nil }
        if showMissionControl(display.id, {
            current().firstIndex(where: { $0.id == spaceID })
        }),
           MissionControl.wait(timeout: 2, { () -> Bool? in
               guard canContinue() else { return false }
               return isShown() ? true : nil
           }) == true {
            return finished(.missionControl)
        }
        // A thumbnail press can change the Space even when its initial
        // closing wait times out. Retry closure before reporting success.
        guard canContinue(), isShown(), canContinue() else { return nil }
        return finished(.missionControl)
    }

    /// Posts `abs(steps)` Dock-swipe gestures on a display; negative steps
    /// go left. Field numbers are private CGEvent fields (see yabai's
    /// space_manager_focus_space_using_gesture).
    private static func swipe(steps: Int, on display: LiveDisplay) {
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
