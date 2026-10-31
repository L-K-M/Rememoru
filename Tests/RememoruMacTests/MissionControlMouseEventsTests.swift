#if os(macOS)
import CoreGraphics
import RememoruCore
import XCTest
@testable import RememoruMac

final class MissionControlMouseEventsTests: XCTestCase {
    private func makeGesture() throws -> MissionControlMouseEvents.Events {
        let frames = [Rect(x: 100, y: -80, w: 160, h: 90), Rect(x: 300, y: -80, w: 160, h: 90)]
        let path = try XCTUnwrap(SpaceDragGeometry.path(from: 1, before: 0, frames: frames,
                                                       inside: Rect(x: 0, y: -100, w: 800, h: 150)))
        return try XCTUnwrap(MissionControlMouseEvents.make(path))
    }

    func testWholeGestureSharesANonzeroEventNumber() throws {
        let gesture = try makeGesture()
        let number = gesture.down.getIntegerValueField(.mouseEventNumber)
        XCTAssertGreaterThan(number, 0)
        XCTAssertEqual(gesture.down.type, .leftMouseDown)
        XCTAssertEqual(gesture.up.type, .leftMouseUp)
        for event in [gesture.down] + gesture.dragged + [gesture.up] {
            XCTAssertEqual(event.getIntegerValueField(.mouseEventNumber), number)
            XCTAssertEqual(event.getIntegerValueField(.mouseEventClickState), 1)
            XCTAssertEqual(event.flags, [])
        }
        XCTAssertGreaterThan(try makeGesture().down.getIntegerValueField(.mouseEventNumber), number)
    }

    func testClickSharesNumberAndKeepsTheButtonAtOnePoint() throws {
        let point = CGPoint(x: 6024, y: 2)
        let click = try XCTUnwrap(MissionControlMouseEvents.click(at: point))
        XCTAssertTrue(click.dragged.isEmpty)
        XCTAssertEqual(click.down.location, point)
        XCTAssertEqual(click.up.location, point)
        XCTAssertEqual(click.down.getIntegerValueField(.mouseEventNumber), click.up.getIntegerValueField(.mouseEventNumber))
        XCTAssertGreaterThan(click.down.getIntegerValueField(.mouseEventNumber), 0)
        XCTAssertNil(MissionControlMouseEvents.click(at: CGPoint(x: CGFloat.infinity, y: 0)))
    }

    func testDragDeltasMatchMovementAndBeginWithASmallStep() throws {
        let gesture = try makeGesture()
        let first = try XCTUnwrap(gesture.dragged.first)
        XCTAssertEqual(abs(first.location.x - gesture.down.location.x), 8, accuracy: 0.001)
        XCTAssertEqual(first.location.y, gesture.down.location.y)
        XCTAssertEqual(gesture.dragged.last?.location, gesture.up.location)
        XCTAssertEqual(gesture.dragged.reduce(Int64(0)) { $0 + $1.getIntegerValueField(.mouseEventDeltaX) }, -292)
        XCTAssertEqual(gesture.dragged.reduce(Int64(0)) { $0 + $1.getIntegerValueField(.mouseEventDeltaY) }, 0)
        XCTAssertTrue(gesture.dragged.allSatisfy { $0.type == .leftMouseDragged })
    }
}
#endif
