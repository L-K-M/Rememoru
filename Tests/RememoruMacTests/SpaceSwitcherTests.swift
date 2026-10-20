#if os(macOS)
import CoreGraphics
import RememoruCore
import XCTest
@testable import RememoruMac

final class SpaceSwitcherTests: XCTestCase {
    func testGestureSearchRecoversActiveSpaceAfterInitialSnapshot() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        var reads = 0
        var activeID: UInt64 = 1
        var swipes = 0
        let method = SpaceSwitcher.show(
            spaceID: 2, display: display,
            readSpaces: {
                reads += 1
                return [1, 2].enumerated().map { index, id in
                    LiveSpace(id: UInt64(id), key: String(id), kind: .desktop, displayUUID: "D",
                              index: index, isActive: reads > 2 && UInt64(id) == activeID)
                }
            },
            ensureMissionControlClosed: { true },
            performSwipe: { direction, _ in
                XCTAssertEqual(direction, 1)
                swipes += 1
                activeID = 2
            },
            showMissionControl: { _, _ in XCTFail("Recovered active state should allow gestures"); return false }
        )

        XCTAssertEqual(method, .gesture)
        XCTAssertEqual(swipes, 1)
    }

    func testGestureSearchUsesActualIDsWhenDockOrderDiffers() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let reported: [UInt64] = [12, 39, 94, 87, 50, 80, 75]
        let dock: [UInt64] = [12, 39, 50, 75, 80, 87, 94]
        var active = 0
        var hops: [UInt64] = []
        let method = SpaceSwitcher.show(
            spaceID: 80, display: display,
            readSpaces: {
                reported.enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == dock[active])
                }
            },
            ensureMissionControlClosed: { true },
            performSwipe: { direction, _ in
                active = min(max(active + direction, 0), dock.count - 1)
                hops.append(dock[active])
            },
            showMissionControl: { _, _ in
                XCTFail("Unreliable Space order cannot identify a Mission Control thumbnail")
                return false
            }
        )

        XCTAssertEqual(method, .gesture)
        XCTAssertEqual(dock[active], 80)
        XCTAssertEqual(hops, [39, 50, 75, 80])
    }

    func testGestureSearchReversesAtEdgeWhenInitialHintIsWrong() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let reported: [UInt64] = [12, 39, 94, 87, 50, 80, 75]
        let dock: [UInt64] = [12, 39, 50, 75, 80, 87, 94]
        var active = 2
        var directions: [Int] = []
        let method = SpaceSwitcher.show(
            spaceID: 94, display: display,
            readSpaces: {
                reported.enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == dock[active])
                }
            },
            ensureMissionControlClosed: { true },
            performSwipe: { direction, _ in
                directions.append(direction)
                active = min(max(active + direction, 0), dock.count - 1)
            },
            showMissionControl: { _, _ in XCTFail("The ID sweep should find the target"); return false }
        )

        XCTAssertEqual(method, .gesture)
        XCTAssertEqual(dock[active], 94)
        XCTAssertEqual(directions, [-1, -1, -1, 1, 1, 1, 1, 1, 1])
    }

    func testUnreachableTargetWithMismatchedOrderDoesNotSelectThumbnail() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let reported: [UInt64] = [12, 39, 94, 87, 50, 80, 75]
        let dock: [UInt64] = [12, 39, 50, 75]
        var active = 0
        var swipes = 0
        var thumbnailRequests = 0
        let method = SpaceSwitcher.show(
            spaceID: 80, display: display,
            readSpaces: {
                reported.enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == dock[active])
                }
            },
            ensureMissionControlClosed: { true },
            performSwipe: { direction, _ in
                swipes += 1
                active = min(max(active + direction, 0), dock.count - 1)
            },
            showMissionControl: { _, _ in thumbnailRequests += 1; return false }
        )

        XCTAssertNil(method)
        XCTAssertEqual(thumbnailRequests, 0)
        XCTAssertEqual(swipes, 8)
    }

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
                                        ensureMissionControlClosed: { true },
                                        showMissionControl: { _, index in
            XCTAssertEqual(index(), 0)
            target.isActive = true
            return false
        })

        XCTAssertEqual(method, .missionControl, "WindowServer confirmation must outlive Mission Control's closing timeout")
    }

    func testFallbackWaitsForDelayedActiveSpaceAfterClosingTimesOut() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        var target = LiveSpace(id: 42, key: "target", kind: .fullscreen, displayUUID: "D", index: 0, isActive: false)
        var fallbackAttempted = false
        var readsAfterFallback = 0
        var closeRequests = 0

        let method = SpaceSwitcher.show(
            spaceID: target.id, display: display,
            readSpaces: {
                if fallbackAttempted {
                    readsAfterFallback += 1
                    target.isActive = readsAfterFallback >= 2
                }
                return [target]
            },
            ensureMissionControlClosed: { closeRequests += 1; return true },
            showMissionControl: { _, _ in fallbackAttempted = true; return false }
        )

        XCTAssertEqual(method, .missionControl)
        XCTAssertEqual(closeRequests, 1)
    }

    func testCancellationDuringFallbackPreventsFurtherReadsAndClosure() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let target = LiveSpace(id: 42, key: "target", kind: .fullscreen, displayUUID: "D", index: 0, isActive: false)
        var allowed = true

        let method = SpaceSwitcher.show(
            spaceID: target.id, display: display,
            readSpaces: { XCTAssertTrue(allowed); return [target] },
            canContinue: { allowed },
            ensureMissionControlClosed: { XCTFail("cancelled switching must not close Mission Control"); return true },
            showMissionControl: { _, _ in allowed = false; return false }
        )

        XCTAssertNil(method)
    }

    func testShownSpaceCannotSucceedWhileMissionControlRemainsOpen() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let target = LiveSpace(id: 42, key: "target", kind: .desktop, displayUUID: "D", index: 0, isActive: true)
        var closeRequests = 0

        let method = SpaceSwitcher.show(
            spaceID: target.id, display: display, readSpaces: { [target] },
            ensureMissionControlClosed: { closeRequests += 1; return false }
        )

        XCTAssertNil(method, "an active Space still has thumbnail bounds until Mission Control closes")
        XCTAssertEqual(closeRequests, 1)
    }

    func testFallbackCannotSucceedWhenMissionControlRemainsOpen() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        var target = LiveSpace(id: 42, key: "target", kind: .desktop, displayUUID: "D", index: 0, isActive: false)
        var closeRequests = 0

        let method = SpaceSwitcher.show(
            spaceID: target.id, display: display, readSpaces: { [target] },
            ensureMissionControlClosed: { closeRequests += 1; return false },
            showMissionControl: { _, _ in target.isActive = true; return false }
        )

        XCTAssertNil(method)
        XCTAssertEqual(closeRequests, 1)
    }

    func testCancellationDuringMissionControlClosePreventsSuccess() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let target = LiveSpace(id: 42, key: "target", kind: .desktop, displayUUID: "D", index: 0, isActive: true)
        var allowed = true

        let method = SpaceSwitcher.show(
            spaceID: target.id, display: display, readSpaces: { [target] },
            canContinue: { allowed },
            ensureMissionControlClosed: { allowed = false; return true }
        )

        XCTAssertNil(method)
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
