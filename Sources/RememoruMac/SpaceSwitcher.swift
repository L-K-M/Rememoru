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
    static func show(spaceID: UInt64, display: LiveDisplay, readSpaces: @escaping () -> [LiveSpace]) -> Method? {
        func current() -> [LiveSpace] {
            readSpaces().filter { $0.displayUUID == display.uuid }.sorted { $0.index < $1.index }
        }
        func isShown() -> Bool { current().first { $0.isActive }?.id == spaceID }

        if isShown() { return .alreadyShown }
        let spaces = current()
        guard let target = spaces.firstIndex(where: { $0.id == spaceID }) else { return nil }

        if let active = spaces.firstIndex(where: \.isActive) {
            swipe(steps: target - active, on: display)
            if MissionControl.wait(timeout: 1.5, { isShown() ? true : nil }) != nil {
                return .gesture
            }
        }
        if MissionControl.showSpace(display: display.id, index: target),
           MissionControl.wait(timeout: 2, { isShown() ? true : nil }) != nil {
            return .missionControl
        }
        return nil
    }

    /// Posts `abs(steps)` Dock-swipe gestures on a display; negative steps
    /// go left. Field numbers are private CGEvent fields (see yabai's
    /// space_manager_focus_space_using_gesture).
    static func swipe(steps: Int, on display: LiveDisplay) {
        guard steps != 0, let event = CGEvent(source: nil) else { return }
        // gestures act on the display under the pointer
        CGWarpMouseCursorPosition(CGPoint(x: display.frame.midX, y: display.frame.midY))

        let sign: Double = steps > 0 ? 1 : -1
        event.setIntegerValueField(field(55), value: 30)    // event type: Dock control
        event.setIntegerValueField(field(110), value: 23)   // HID gesture type: Dock swipe
        event.setIntegerValueField(field(123), value: 1)    // swipe motion: horizontal
        event.setDoubleValueField(field(124), value: sign)  // swipe progress
        event.setDoubleValueField(field(129), value: sign * 9999)  // velocity x
        for _ in 0..<abs(steps) {
            event.setIntegerValueField(field(132), value: 1)  // phase: began
            event.post(tap: .cgSessionEventTap)
            event.setIntegerValueField(field(132), value: 4)  // phase: ended
            event.post(tap: .cgSessionEventTap)
        }
    }

    /// Undocumented field numbers have no named case; the type is a plain
    /// UInt32 underneath.
    private static func field(_ raw: UInt32) -> CGEventField {
        unsafeBitCast(raw, to: CGEventField.self)
    }
}
#endif
