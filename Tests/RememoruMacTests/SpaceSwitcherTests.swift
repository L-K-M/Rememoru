#if os(macOS)
import CoreGraphics
import XCTest
@testable import RememoruMac

final class SpaceSwitcherTests: XCTestCase {
    func testSwipeEventTargetsRequestedDisplay() throws {
        let initial = try XCTUnwrap(CGEvent(source: nil)).location
        let destination = CGPoint(x: initial.x + 2000, y: initial.y - 500)
        let event = try XCTUnwrap(SpaceSwitcher.swipeEvent(steps: -1, at: destination))

        XCTAssertEqual(event.location, destination)
    }
}
#endif
