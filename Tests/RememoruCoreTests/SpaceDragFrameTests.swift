import XCTest
@testable import RememoruCore

/// Regression tests for SpaceDragGeometry frame normalization.
/// WindowManager AXPosition reports a center anchor.  thumbnailFrame converts to top-left frames
/// so strict full containment checks work correctly.
final class SpaceDragFrameTests: XCTestCase {

    private let bar = Rect(x: 4872, y: -76, w: 1920, h: 146)

    private var reportedFrames: [Rect] {
        let xs: [Double] = [5448, 5640, 5832, 6024, 6216]
        return xs.map { Rect(x: $0, y: 2, w: 190, h: 129) }
    }

    // MARK: - thumbnailFrame normalization

    func testThumbnailFrame_center() {
        let reported = Rect(x: 6024, y: 2, w: 190, h: 129)
        let frame = SpaceDragGeometry.thumbnailFrame(reported, origin: .center)
        XCTAssertEqual(frame.x, 5929)
        XCTAssertEqual(frame.y, -62.5)
        XCTAssertEqual(frame.w, 190)
        XCTAssertEqual(frame.h, 129)
    }

    func testThumbnailFrame_topLeft() {
        let reported = Rect(x: 6024, y: 2, w: 190, h: 129)
        let frame = SpaceDragGeometry.thumbnailFrame(reported, origin: .topLeft)
        XCTAssertEqual(frame, reported)
    }

    // MARK: - Normalized frames pass strict containment

    func testPath_normalizedFrames_source3_before2() throws {
        let frames = reportedFrames.map {
            SpaceDragGeometry.thumbnailFrame($0, origin: .center)
        }
        let path = SpaceDragGeometry.path(from: 3, before: 2, frames: frames, inside: bar)
        XCTAssertNotNil(path)
        let p = try XCTUnwrap(path)
        XCTAssertEqual(p.startX, 6024)
        XCTAssertEqual(p.startY, 2)
        XCTAssertEqual(p.endX, 5736)
        XCTAssertEqual(p.endY, 2)
    }

    // MARK: - Raw unnormalized frames must reject

    func testPath_rawUnnormalizedFrames_reject() {
        let path = SpaceDragGeometry.path(
            from: 3, before: 2,
            frames: reportedFrames,
            inside: bar
        )
        XCTAssertNil(path, "raw center-anchored frames must fail strict containment")
    }

    func testCompactPositionsWithExpandedSizesAreNotReady() {
        let reported = [5652.0, 5742, 5846, 5946, 6022.5].map {
            Rect(x: $0, y: -108.5, w: 190, h: 129)
        }
        let normalized = reported.map { SpaceDragGeometry.thumbnailFrame($0, origin: .center) }
        XCTAssertFalse(SpaceDragGeometry.framesFit(normalized, inside: bar))
    }

}
