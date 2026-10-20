import XCTest
@testable import RememoruCore

final class SpaceTraversalTests: XCTestCase {
    private let reported: [UInt64] = [12, 39, 94, 87, 50, 80, 75]

    func testKeepsDirectionAcrossUnexpectedHops() throws {
        var traversal = try XCTUnwrap(SpaceTraversal(orderedIDs: reported, activeID: 12, targetID: 80))
        let visited: [UInt64] = [12, 39, 50, 75, 80]
        for (previous, next) in zip(visited, visited.dropFirst()) {
            XCTAssertEqual(traversal.nextDirection(), .right)
            XCTAssertTrue(traversal.observe(from: previous, to: next, orderedIDs: reported))
        }
        XCTAssertFalse(traversal.orderMatchesNavigation)
    }

    func testReversesOnceAtAnEdge() throws {
        var traversal = try XCTUnwrap(SpaceTraversal(orderedIDs: reported, activeID: 50, targetID: 94))
        for (previous, next) in [(UInt64(50), UInt64(39)), (39, 12)] {
            XCTAssertEqual(traversal.nextDirection(), .left)
            XCTAssertTrue(traversal.observe(from: previous, to: next, orderedIDs: reported))
        }
        XCTAssertEqual(traversal.nextDirection(), .left)
        XCTAssertTrue(traversal.observe(from: 12, to: nil, orderedIDs: reported))
        let visited: [UInt64] = [12, 39, 50, 75, 80, 87, 94]
        for (previous, next) in zip(visited, visited.dropFirst()) {
            XCTAssertEqual(traversal.nextDirection(), .right)
            XCTAssertTrue(traversal.observe(from: previous, to: next, orderedIDs: reported))
        }
        XCTAssertFalse(traversal.observe(from: 94, to: nil, orderedIDs: reported))
    }

    func testBoundsAttemptsEvenWhenEveryHopChanges() throws {
        var traversal = try XCTUnwrap(SpaceTraversal(orderedIDs: reported, activeID: 12, targetID: 80))
        for _ in 0..<(reported.count * 2) {
            XCTAssertNotNil(traversal.nextDirection())
            XCTAssertTrue(traversal.observe(from: 12, to: 39, orderedIDs: reported))
        }
        XCTAssertNil(traversal.nextDirection())
    }

    func testRequiresDistinctKnownTargets() {
        XCTAssertNil(SpaceTraversal(orderedIDs: reported, activeID: 12, targetID: 999))
        XCTAssertNil(SpaceTraversal(orderedIDs: reported, activeID: 999, targetID: 80))
        XCTAssertNil(SpaceTraversal(orderedIDs: reported, activeID: 12, targetID: 12))
    }

    func testAdjacentHopsKeepThumbnailOrderEligible() throws {
        var traversal = try XCTUnwrap(SpaceTraversal(orderedIDs: reported, activeID: 12, targetID: 39))
        XCTAssertEqual(traversal.nextDirection(), .right)
        XCTAssertTrue(traversal.observe(from: 12, to: 39, orderedIDs: reported))
        XCTAssertTrue(traversal.orderMatchesNavigation)
    }
}
