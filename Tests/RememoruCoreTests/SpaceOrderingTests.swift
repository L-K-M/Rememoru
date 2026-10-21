import XCTest
@testable import RememoruCore

final class SpaceOrderingTests: XCTestCase {

    // MARK: - SpaceOrdering.moves

    func testMovesReordersPreservingExtra() throws {
        let current: [UInt64] = [1, 2, 99, 3]
        let desired: [UInt64] = [1, 3, 2]
        let moves = try XCTUnwrap(SpaceOrdering.moves(current: current, desired: desired))
        var working = current
        for move in moves {
            guard let idx = working.firstIndex(of: move.spaceID) else { XCTFail(); continue }
            working.remove(at: idx)
            let beforeIdx = working.firstIndex(of: move.beforeID) ?? 0
            working.insert(move.spaceID, at: beforeIdx)
            XCTAssertEqual(working, move.expectedOrder)
        }
        XCTAssertEqual(working, [1, 3, 99, 2])
    }

    func testMovesAlreadyCorrect() throws {
        let current: [UInt64] = [1, 2, 3]
        let desired: [UInt64] = [1, 2, 3]
        let moves = try XCTUnwrap(SpaceOrdering.moves(current: current, desired: desired))
        XCTAssertEqual(moves, [])
    }

    func testMovesMissingDesiredID() {
        let current: [UInt64] = [1, 2, 3]
        let desired: [UInt64] = [1, 4]
        XCTAssertNil(SpaceOrdering.moves(current: current, desired: desired))
    }

    func testMovesDuplicateDesired() {
        let current: [UInt64] = [1, 2, 3]
        let desired: [UInt64] = [1, 2, 2]
        XCTAssertNil(SpaceOrdering.moves(current: current, desired: desired))
    }

    func testMovesDuplicateCurrent() {
        let current: [UInt64] = [1, 2, 2, 3]
        let desired: [UInt64] = [1, 2, 3]
        XCTAssertNil(SpaceOrdering.moves(current: current, desired: desired))
    }

    // MARK: - SpaceOrderSurvey

    func testSurveyFullSweep() throws {
        let known: [UInt64] = [12, 39, 94, 87, 50, 80, 75]
        var survey = try XCTUnwrap(SpaceOrderSurvey(knownIDs: known, activeID: 50))

        // Consume left: 39, 12, then 12 again (edge — stays at 12)
        XCTAssertEqual(survey.nextDirection(), .left)
        XCTAssertTrue(survey.observe(activeID: 39))
        XCTAssertEqual(survey.nextDirection(), .left)
        XCTAssertTrue(survey.observe(activeID: 12))
        XCTAssertEqual(survey.nextDirection(), .left)
        XCTAssertTrue(survey.observe(activeID: 12))

        // Right sweep: 39, 50, 75, 80, 87, 94
        XCTAssertEqual(survey.nextDirection(), .right)
        XCTAssertTrue(survey.observe(activeID: 39))
        XCTAssertEqual(survey.nextDirection(), .right)
        XCTAssertTrue(survey.observe(activeID: 50))
        XCTAssertEqual(survey.nextDirection(), .right)
        XCTAssertTrue(survey.observe(activeID: 75))
        XCTAssertEqual(survey.nextDirection(), .right)
        XCTAssertTrue(survey.observe(activeID: 80))
        XCTAssertEqual(survey.nextDirection(), .right)
        XCTAssertTrue(survey.observe(activeID: 87))
        XCTAssertEqual(survey.nextDirection(), .right)
        XCTAssertTrue(survey.observe(activeID: 94))

        XCTAssertEqual(survey.order, [12, 39, 50, 75, 80, 87, 94])
        XCTAssertFalse(survey.failed)
    }

    func testSurveyUnknownIDFails() throws {
        var survey = try XCTUnwrap(SpaceOrderSurvey(knownIDs: [10, 20], activeID: 10))
        XCTAssertFalse(survey.observe(activeID: 99))
        XCTAssertTrue(survey.failed)
    }

    func testSurveyNilFails() throws {
        var survey = try XCTUnwrap(SpaceOrderSurvey(knownIDs: [10, 20], activeID: 10))
        XCTAssertFalse(survey.observe(activeID: nil))
        XCTAssertTrue(survey.failed)
    }

    func testSurveyCycleFails() throws {
        var survey = try XCTUnwrap(SpaceOrderSurvey(knownIDs: [10, 20, 30], activeID: 10))
        XCTAssertTrue(survey.observe(activeID: 20))
        XCTAssertFalse(survey.observe(activeID: 10))
        XCTAssertTrue(survey.failed)
    }

    func testSurveyEarlyRightEdgeFails() throws {
        var survey = try XCTUnwrap(SpaceOrderSurvey(knownIDs: [10, 20, 30], activeID: 10))
        XCTAssertTrue(survey.observe(activeID: 20))
        XCTAssertTrue(survey.observe(activeID: 30))
        XCTAssertTrue(survey.observe(activeID: 30))
        XCTAssertFalse(survey.failed)
        XCTAssertEqual(survey.nextDirection(), .right)
        XCTAssertFalse(survey.observe(activeID: 30))
        XCTAssertTrue(survey.failed)
    }

    func testSurveySingleIDCompletesImmediately() throws {
        var survey = try XCTUnwrap(SpaceOrderSurvey(knownIDs: [42], activeID: 42))
        XCTAssertEqual(survey.order, [42])
        XCTAssertNil(survey.nextDirection())
    }

    func testSurveyInvalidInit() {
        XCTAssertNil(SpaceOrderSurvey(knownIDs: [10, 20], activeID: 99))
        XCTAssertNil(SpaceOrderSurvey(knownIDs: [10, 10], activeID: 10))
    }

    func testSurveyBoundedNextDirection() throws {
        var survey = try XCTUnwrap(SpaceOrderSurvey(knownIDs: [10, 20], activeID: 10))
        for _ in 0..<5 {
            _ = survey.nextDirection()
        }
        XCTAssertTrue(survey.failed)
        XCTAssertNil(survey.nextDirection())
    }

    // MARK: - SpaceDragGeometry.path

    func testPathFrom2Before1() {
        let frames: [Rect] = [
            Rect(x: 100, y: -80, w: 160, h: 90),
            Rect(x: 300, y: -80, w: 160, h: 90),
            Rect(x: 500, y: -80, w: 160, h: 90)
        ]
        let bar = Rect(x: 0, y: -100, w: 800, h: 150)
        let path = SpaceDragGeometry.path(from: 2, before: 1, frames: frames, inside: bar)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.startX, 580)
        XCTAssertEqual(path?.startY, -35)
        XCTAssertEqual(path?.endX, 280)
        XCTAssertEqual(path?.endY, -35)
    }

    func testPathBefore0EndX() {
        let frames: [Rect] = [
            Rect(x: 100, y: -80, w: 160, h: 90),
            Rect(x: 300, y: -80, w: 160, h: 90),
            Rect(x: 500, y: -80, w: 160, h: 90)
        ]
        let bar = Rect(x: 0, y: -100, w: 800, h: 150)
        let path = SpaceDragGeometry.path(from: 2, before: 0, frames: frames, inside: bar)
        XCTAssertNotNil(path)
        XCTAssertEqual(path?.endX, 88)
    }

    func testPathRejectsOverlappingFrames() {
        let frames: [Rect] = [
            Rect(x: 100, y: -80, w: 300, h: 90),
            Rect(x: 300, y: -80, w: 160, h: 90)
        ]
        let bar = Rect(x: 0, y: -100, w: 800, h: 150)
        XCTAssertNil(SpaceDragGeometry.path(from: 1, before: 0, frames: frames, inside: bar))
    }

    func testPathRejectsNonFiniteFrames() {
        let frames: [Rect] = [
            Rect(x: .infinity, y: -80, w: 160, h: 90),
            Rect(x: 300, y: -80, w: 160, h: 90)
        ]
        let bar = Rect(x: 0, y: -100, w: 800, h: 150)
        XCTAssertNil(SpaceDragGeometry.path(from: 1, before: 0, frames: frames, inside: bar))
    }

    func testPathRejectsOutOfBarFrames() {
        let frames: [Rect] = [
            Rect(x: 100, y: -80, w: 160, h: 90),
            Rect(x: 300, y: 500, w: 160, h: 90)
        ]
        let bar = Rect(x: 0, y: -100, w: 800, h: 150)
        XCTAssertNil(SpaceDragGeometry.path(from: 1, before: 0, frames: frames, inside: bar))
    }

    func testPathRejectsNoGap() {
        let frames: [Rect] = [
            Rect(x: 0, y: -80, w: 160, h: 90),
            Rect(x: 160, y: -80, w: 160, h: 90)
        ]
        let bar = Rect(x: 0, y: -100, w: 800, h: 150)
        XCTAssertNil(SpaceDragGeometry.path(from: 1, before: 0, frames: frames, inside: bar))
    }

    func testPathRejectsInvalidDirection() {
        let frames: [Rect] = [
            Rect(x: 100, y: -80, w: 160, h: 90),
            Rect(x: 300, y: -80, w: 160, h: 90)
        ]
        let bar = Rect(x: 0, y: -100, w: 800, h: 150)
        XCTAssertNil(SpaceDragGeometry.path(from: 0, before: 1, frames: frames, inside: bar))
    }

    // MARK: - SpaceOrdering.applying

    private func makeState() -> LiveState {
        let displays: [LiveDisplay] = [
            LiveDisplay(id: 1, uuid: "A", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true),
            LiveDisplay(id: 2, uuid: "B", frame: Rect(x: 1920, y: 0, w: 1920, h: 1080), isMain: false)
        ]
        let spaces: [LiveSpace] = [
            LiveSpace(id: 1, key: "id1", kind: .desktop, displayUUID: "A", index: 0, isActive: true),
            LiveSpace(id: 2, key: "id2", kind: .fullscreen, displayUUID: "A", index: 1, isActive: false),
            LiveSpace(id: 3, key: "id3", kind: .desktop, displayUUID: "B", index: 0, isActive: true)
        ]
        let windows: [LiveWindow] = [
            LiveWindow(id: 100, pid: 1234, appName: "App", title: "Win", frame: Rect(x: 0, y: 0, w: 800, h: 600), isOnscreen: true, spaceID: 1)
        ]
        return LiveState(displays: displays, spaces: spaces, windows: windows)
    }

    func testApplyingReordersDisplayASpaces() throws {
        let state = makeState()
        let orders: [String: [UInt64]] = ["A": [2, 1]]
        let result = try XCTUnwrap(SpaceOrdering.applying(orders, to: state))

        // Display A spaces reordered: id2->index 0, id1->index 1
        let aSpaces = result.spaces(onDisplay: "A")
        XCTAssertEqual(2, aSpaces.count)
        XCTAssertEqual(2, aSpaces[0].id)
        XCTAssertEqual(0, aSpaces[0].index)
        XCTAssertEqual(1, aSpaces[1].id)
        XCTAssertEqual(1, aSpaces[1].index)

        // Original keys, kinds, and active flags preserved
        let space1 = try XCTUnwrap(result.space(id: 1))
        XCTAssertEqual("id1", space1.key)
        XCTAssertEqual(.desktop, space1.kind)
        XCTAssertTrue(space1.isActive)

        let space2 = try XCTUnwrap(result.space(id: 2))
        XCTAssertEqual("id2", space2.key)
        XCTAssertEqual(.fullscreen, space2.kind)
        XCTAssertFalse(space2.isActive)

        // Display B space untouched
        let bSpaces = result.spaces(onDisplay: "B")
        XCTAssertEqual(1, bSpaces.count)
        XCTAssertEqual(3, bSpaces[0].id)
        XCTAssertEqual(0, bSpaces[0].index)

        // Windows preserved
        XCTAssertEqual(1, result.windows.count)
        XCTAssertEqual(100, result.windows[0].id)
    }

    func testApplyingSnapshotBuilderSpaceUUIDs() throws {
        let state = makeState()
        let orders: [String: [UInt64]] = ["A": [2, 1]]
        let result = try XCTUnwrap(SpaceOrdering.applying(orders, to: state))
        let snapshot = SnapshotBuilder.build(from: result, created: "2026-01-01")

        let displayA = snapshot.displays.first { $0.uuid == "A" }
        XCTAssertNotNil(displayA)
        XCTAssertEqual(["id2", "id1"], displayA?.spaceUUIDs)
    }

    func testApplyingRejectsPartialOrder() {
        let state = makeState()
        let orders: [String: [UInt64]] = ["A": [1]]
        XCTAssertNil(SpaceOrdering.applying(orders, to: state))
    }

    func testApplyingRejectsUnknownOrderID() {
        let state = makeState()
        let orders: [String: [UInt64]] = ["A": [1, 999]]
        XCTAssertNil(SpaceOrdering.applying(orders, to: state))
    }

    func testApplyingRejectsDuplicateOrderIDs() {
        let state = makeState()
        let orders: [String: [UInt64]] = ["A": [1, 1]]
        XCTAssertNil(SpaceOrdering.applying(orders, to: state))
    }

    func testApplyingRejectsUnknownDisplayKey() {
        let state = makeState()
        let orders: [String: [UInt64]] = ["Z": [1, 2]]
        XCTAssertNil(SpaceOrdering.applying(orders, to: state))
    }
}
