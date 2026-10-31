#if os(macOS)
import CoreGraphics
import Foundation
import RememoruCore

/// A complete mouse gesture shares one event number on macOS 27.
/// Construct everything before posting so a failed allocation cannot leave
/// the button down. Callers own posting and must always release the button.
enum MissionControlMouseEvents {
    struct Events {
        let move: CGEvent
        let down: CGEvent
        let dragged: [CGEvent]
        let up: CGEvent
    }

    private static let lock = NSLock()
    private static var previousNumber: Int64 = 0

    private static func nextNumber() -> Int64? {
        lock.lock()
        defer { lock.unlock() }
        // The first synthetic gesture must follow the current HID counters.
        let hardwareCount = [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown].reduce(Int64(0)) {
            $0 + Int64(CGEventSource.counterForEventType(.hidSystemState, eventType: $1))
        }
        let last = max(previousNumber, hardwareCount)
        guard last < Int64(Int32.max) else { return nil }
        previousNumber = last + 1
        return previousNumber
    }

    private static func event(number: Int64, _ type: CGEventType, at point: CGPoint) -> CGEvent? {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type,
                                  mouseCursorPosition: point, mouseButton: .left) else { return nil }
        event.flags = []
        event.setIntegerValueField(.mouseEventNumber, value: number)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
        event.setIntegerValueField(.mouseEventDeltaX, value: 0)
        event.setIntegerValueField(.mouseEventDeltaY, value: 0)
        return event
    }

    static func post(_ event: CGEvent) {
        // Events are preallocated, but their timestamps must match posting.
        event.timestamp = DispatchTime.now().uptimeNanoseconds
        event.post(tap: .cghidEventTap)
    }

    static func click(at point: CGPoint) -> Events? {
        guard point.x.isFinite, point.y.isFinite, let number = nextNumber(),
              let move = event(number: number, .mouseMoved, at: point),
              let down = event(number: number, .leftMouseDown, at: point),
              let up = event(number: number, .leftMouseUp, at: point) else { return nil }
        return Events(move: move, down: down, dragged: [], up: up)
    }

    static func make(_ path: SpaceDragGeometry.Path) -> Events? {
        let start = CGPoint(x: path.startX, y: path.startY)
        let end = CGPoint(x: path.endX, y: path.endY)
        let dx = end.x - start.x
        let dy = end.y - start.y
        let distance = hypot(dx, dy)
        guard distance.isFinite, distance > 0, let number = nextNumber() else { return nil }
        guard let move = event(number: number, .mouseMoved, at: start), let down = event(number: number, .leftMouseDown, at: start),
              let up = event(number: number, .leftMouseUp, at: end) else { return nil }
        let firstFraction = min(8 / distance, 0.5)
        let fractions = [firstFraction] + (1...12).map { firstFraction + (1 - firstFraction) * Double($0) / 12 }
        var previous = start
        var dragged: [CGEvent] = []
        for fraction in fractions {
            let point = CGPoint(x: start.x + dx * fraction, y: start.y + dy * fraction)
            guard let drag = event(number: number, .leftMouseDragged, at: point) else { return nil }
            guard let deltaX = Int64(exactly: point.x.rounded() - previous.x.rounded()),
                  let deltaY = Int64(exactly: point.y.rounded() - previous.y.rounded()) else { return nil }
            drag.setIntegerValueField(.mouseEventDeltaX, value: deltaX)
            drag.setIntegerValueField(.mouseEventDeltaY, value: deltaY)
            dragged.append(drag)
            previous = point
        }
        return Events(move: move, down: down, dragged: dragged, up: up)
    }
}
#endif
