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

    func testMismatchedOrderProbesAllPhysicalIndices() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let reported: [UInt64] = [12, 39, 94, 87, 50, 80, 75]
        let dock: [UInt64] = [12, 39, 50, 75]
        var active = 0
        var swipes = 0
        var probedIndices: [Int] = []
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
            showMissionControl: { _, indexCallback in
                probedIndices.append(indexCallback() ?? -1)
                return false
            }
        )

        XCTAssertNil(method)
        XCTAssertEqual(probedIndices, Array(0..<reported.count), "all physical indices 0..<count are probed")
        XCTAssertEqual(swipes, 8)
    }

    func testMissionControlFallbackSucceedsWithMismatchedOrder() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let reported: [UInt64] = [1, 2, 3]
        // Physical order differs from reported: index 0→id1, 1→id3, 2→id2
        let physical: [UInt64] = [1, 3, 2]
        let target: UInt64 = 2
        var activeID: UInt64 = 1
        var positionsSelected: [Int] = []
        let method = SpaceSwitcher.show(
            spaceID: target, display: display,
            readSpaces: {
                reported.enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == activeID)
                }
            },
            ensureMissionControlClosed: { true },
            performSwipe: { _, _ in },
            showMissionControl: { _, indexCallback in
                guard let position = indexCallback() else { return false }
                positionsSelected.append(position)
                // Simulate the thumbnail selection activating the space at that physical position
                activeID = physical[position]
                return false
            }
        )

        XCTAssertEqual(method, .missionControl)
        // No confirmed hops so orderMatchesNavigation stays true; hint = reported index of target (1).
        // Candidates: [1, 0, 2]. Index 2 (physical id2) confirms the target.
        XCTAssertEqual(positionsSelected, [1, 0, 2], "hint-first probe order; last index hits the target")
        XCTAssertEqual(activeID, target)
    }

    func testMembershipChangeAbortsThumbnailProbe() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        let reported: [UInt64] = [1, 2, 3]
        let physical: [UInt64] = [1, 3, 2]
        let target: UInt64 = 2
        var activeID: UInt64 = 1
        var probeCount = 0
        let method = SpaceSwitcher.show(
            spaceID: target, display: display,
            readSpaces: {
                // After the first probe, a new space (id4) appears, changing membership
                let ids: [UInt64] = probeCount > 0 ? [1, 2, 3, 4] : reported
                return ids.enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == activeID)
                }
            },
            ensureMissionControlClosed: { true },
            performSwipe: { _, _ in },
            showMissionControl: { _, indexCallback in
                guard let position = indexCallback() else { return false }
                // First probe (hint index 1) activates physical[1]=id3, not the target
                activeID = physical[position]
                probeCount += 1
                return false
            }
        )

        XCTAssertNil(method, "membership change must abort before a second thumbnail selection")
        XCTAssertEqual(probeCount, 1, "only the first probe executes; guard catches the drift")
    }

    func testTransientTargetAfterClosureIsNotConfirmed() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        var closedAt: Date?
        let method = SpaceSwitcher.show(
            spaceID: 2, display: display,
            readSpaces: {
                let active: UInt64 = closedAt.map { Date().timeIntervalSince($0) >= 0.65 } == true ? 3 : 2
                return [UInt64(1), 2, 3].enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == active)
                }
            },
            ensureMissionControlClosed: { closedAt = Date(); return true },
            performSwipe: { _, _ in XCTFail("initial target is already active") },
            showMissionControl: { _, _ in XCTFail("initial target is already active"); return false }
        )
        XCTAssertNil(method)
    }

    func testLateTargetDuringClosureDoesNotSelectAnotherThumbnail() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        var active: UInt64 = 1
        var selections: [Int] = []
        let method = SpaceSwitcher.show(
            spaceID: 2, display: display,
            readSpaces: {
                [UInt64(1), 2, 3].enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == active)
                }
            },
            ensureMissionControlClosed: {
                if selections.count == 1 { active = 2 }
                return true
            },
            performSwipe: { _, _ in },
            showMissionControl: { _, index in
                guard let index = index() else { return false }
                selections.append(index)
                active = 3
                return true
            }
        )
        XCTAssertEqual(method, .missionControl)
        XCTAssertEqual(selections, [1])
    }

    func testTransientThumbnailTargetRetriesTheSamePosition() {
        let display = LiveDisplay(id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true)
        var selections: [Int] = []
        var selectedAt: Date?
        var active: UInt64 = 1
        let method = SpaceSwitcher.show(
            spaceID: 2, display: display,
            readSpaces: {
                if selections.count == 1, let selectedAt, Date().timeIntervalSince(selectedAt) >= 0.65 { active = 3 }
                return [UInt64(1), 2, 3].enumerated().map { index, id in
                    LiveSpace(id: id, key: String(id), kind: .fullscreen, displayUUID: "D",
                              index: index, isActive: id == active)
                }
            },
            ensureMissionControlClosed: { true },
            performSwipe: { _, _ in },
            showMissionControl: { _, index in
                guard let index = index() else { return false }
                selections.append(index)
                active = 2
                selectedAt = Date()
                return true
            }
        )
        XCTAssertEqual(method, .missionControl)
        XCTAssertEqual(selections, [1, 1])
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
