#if os(macOS)
import XCTest
@testable import RememoruMac

final class MissionControlReadinessTests: XCTestCase {
    private let opened = Date(timeIntervalSinceReferenceDate: 0)

    func testStableFramesBeforeInputReadinessDoNotAllowSelection() {
        // Native failures occurred around 0.7 seconds after opening. AX
        // frames can already be stable while WindowManager ignores input.
        XCTAssertFalse(MissionControl.thumbnailsReady(
            openedAt: opened, stableSince: opened.addingTimeInterval(0.1),
            now: opened.addingTimeInterval(0.75), minimumOpeningDelay: 1
        ))
    }

    func testReadyOverviewStillRequiresStableGeometry() {
        XCTAssertFalse(MissionControl.thumbnailsReady(
            openedAt: opened, stableSince: opened.addingTimeInterval(1.2),
            now: opened.addingTimeInterval(1.3), minimumOpeningDelay: 1
        ))
    }

    func testOpeningAndGeometryRequirementsCanBothBeSatisfied() {
        XCTAssertTrue(MissionControl.thumbnailsReady(
            openedAt: opened, stableSince: opened.addingTimeInterval(0.5),
            now: opened.addingTimeInterval(1.3), minimumOpeningDelay: 1
        ))
    }

    func testLegacyOpeningDelayCanRemainShorter() {
        XCTAssertTrue(MissionControl.thumbnailsReady(
            openedAt: opened, stableSince: opened,
            now: opened.addingTimeInterval(0.4), minimumOpeningDelay: 0.3
        ))
    }
}
#endif
