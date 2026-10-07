#if os(macOS)
import XCTest
@testable import RememoruMac

final class MissionControlTests: XCTestCase {
    func testClosedMissionControlIsNeverToggledOpen() {
        var dismissals = 0
        var waits = 0

        XCTAssertTrue(MissionControl.closeIfNeeded(
            isOpen: { false }, dismiss: { dismissals += 1 }, canContinue: { true },
            waitUntilClosed: { waits += 1; return true }
        ))
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(waits, 0)
    }

    func testOpenMissionControlRequiresConfirmedClosure() {
        for confirmed in [true, false] {
            var dismissals = 0
            var waits = 0

            XCTAssertEqual(MissionControl.closeIfNeeded(
                isOpen: { true }, dismiss: { dismissals += 1 }, canContinue: { true },
                waitUntilClosed: { waits += 1; return confirmed }
            ), confirmed)
            XCTAssertEqual(dismissals, 1)
            XCTAssertEqual(waits, 1)
        }
    }

    func testUnavailableMissionControlStateCannotConfirmClosure() {
        var dismissals = 0
        var waits = 0

        XCTAssertFalse(MissionControl.closeIfNeeded(
            isOpen: { nil }, dismiss: { dismissals += 1 }, canContinue: { true },
            waitUntilClosed: { waits += 1; return true }
        ))
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(waits, 0)
    }

    func testDismissalWaitRetriesUnavailableStateUntilExplicitClosure() {
        let states: [Bool?] = [nil, false]
        var reads = 0
        let confirmed = MissionControl.wait(timeout: 0.1, interval: 0) {
            MissionControl.closureConfirmation(isOpen: {
                let state = states[min(reads, states.count - 1)]
                reads += 1
                return state
            }, canContinue: { true })
        }

        XCTAssertEqual(confirmed, true)
        XCTAssertEqual(reads, 2)
    }

    func testCancelledDismissalWaitDoesNotReadState() {
        XCTAssertEqual(MissionControl.closureConfirmation(
            isOpen: { XCTFail("cancelled closure must not read state"); return nil },
            canContinue: { false }
        ), false)
    }

    func testUnavailableDismissalStateStaysUnconfirmedAtDeadline() {
        let confirmed = MissionControl.wait(timeout: 0) {
            MissionControl.closureConfirmation(isOpen: { nil }, canContinue: { true })
        }

        XCTAssertNil(confirmed)
    }

    func testCancellationPreventsReadsAndDismissal() {
        XCTAssertFalse(MissionControl.closeIfNeeded(
            isOpen: { XCTFail("cancelled closure must not read state"); return true },
            dismiss: { XCTFail("cancelled closure must not dismiss") }, canContinue: { false },
            waitUntilClosed: { XCTFail("cancelled closure must not wait"); return true }
        ))
    }

    func testCancellationDuringDismissalStopsWaiting() {
        var allowed = true

        XCTAssertFalse(MissionControl.closeIfNeeded(
            isOpen: { true }, dismiss: { allowed = false }, canContinue: { allowed },
            waitUntilClosed: { XCTFail("cancelled closure must not wait"); return true }
        ))
    }
}
#endif
