#if os(macOS)
import CoreGraphics
import RememoruCore
import XCTest
@testable import RememoruMac

final class SpaceSwitcherTests: XCTestCase {
    func testSwipeEventTargetsRequestedDisplay() throws {
        let initial = try XCTUnwrap(CGEvent(source: nil)).location
        let destination = CGPoint(x: initial.x + 2000, y: initial.y - 500)
        let event = try XCTUnwrap(SpaceSwitcher.swipeEvent(steps: -1, at: destination))

        XCTAssertEqual(event.location, destination)
    }

    func testFallbackConfirmsSpaceEvenWhenMissionControlClosingTimesOut() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        // No active Space while Dock is changing state, so no gesture is posted.
        var target = LiveSpace(id: 42, key: "target", kind: .fullscreen, displayUUID: "D", index: 0, isActive: false)

        let method = SpaceSwitcher.show(spaceID: target.id, display: display, readSpaces: { [target] },
                                        showMissionControl: { _, index in
            XCTAssertEqual(index(), 0)
            target.isActive = true
            return false
        })

        XCTAssertEqual(method, .missionControl, "WindowServer confirmation must outlive Mission Control's closing timeout")
    }

    func testCancelledShowDoesNotReadOrDispatchMissionControl() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        var reads = 0
        var requests = 0
        let method = SpaceSwitcher.show(
            spaceID: 42, display: display,
            readSpaces: { reads += 1; return [] },
            canContinue: { false },
            showMissionControl: { _, _ in requests += 1; return true }
        )

        XCTAssertNil(method)
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(requests, 0)
    }

    func testCancellationBeforeFallbackDoesNotOpenMissionControl() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let target = LiveSpace(id: 42, key: "target", kind: .fullscreen, displayUUID: "D", index: 0, isActive: false)
        var allowed = true
        var requests = 0
        let method = SpaceSwitcher.show(
            spaceID: target.id, display: display,
            readSpaces: { allowed = false; return [target] },
            canContinue: { allowed },
            showMissionControl: { _, _ in requests += 1; return true }
        )

        XCTAssertNil(method)
        XCTAssertEqual(requests, 0)
    }
}
#endif
