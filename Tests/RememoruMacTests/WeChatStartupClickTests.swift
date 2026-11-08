#if os(macOS)
import XCTest
@testable import RememoruMac

final class WeChatStartupClickTests: XCTestCase {
    func testRediscoversMovedOrReplacedTargetBeforeClicking() {
        var discoveries = 0
        var clicked: [Int] = []
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(1), interval: 0, canContinue: { true }, isReady: { false },
            discover: { discoveries += 1; return discoveries },
            matches: { $0 == 2 }, perform: { clicked.append($0); return true }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(discoveries, 2)
        XCTAssertEqual(clicked, [2])
    }

    func testMainWindowArrivingAfterHitMissNeedsNoClick() {
        var ready = false
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(1), interval: 0, canContinue: { true }, isReady: { ready },
            discover: { 1 }, matches: { _ in ready = true; return false },
            perform: { _ in clicked = true; return true }
        )

        XCTAssertTrue(result)
        XCTAssertFalse(clicked)
    }

    func testPersistentUnrelatedTargetNeverClicks() {
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(0.001), interval: 0, canContinue: { true }, isReady: { false },
            discover: { 1 }, matches: { _ in false }, perform: { _ in clicked = true; return true }
        )

        XCTAssertFalse(result)
        XCTAssertFalse(clicked)
    }

    func testExpiredDeadlinePreventsReadinessDiscoveryAndClick() {
        XCTAssertFalse(WeChatStartupClick.performWhenReady(
            deadline: .distantPast, canContinue: { true },
            isReady: { XCTFail("expired"); return true },
            discover: { XCTFail("expired"); return 1 },
            matches: { _ in XCTFail("expired"); return true },
            perform: { _ in XCTFail("expired"); return true }
        ))
    }

    func testMainWindowArrivingAfterExactHitPreventsClick() {
        var readinessChecks = 0
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(1), canContinue: { true }, isReady: {
                readinessChecks += 1
                return readinessChecks == 2
            },
            discover: { 1 }, matches: { _ in true }, perform: { _ in clicked = true; return true }
        )

        XCTAssertTrue(result)
        XCTAssertFalse(clicked)
    }

    func testFailedFinalVerificationRediscoversBeforeRetrying() {
        var discoveries = 0
        var clicked: [Int] = []
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(1), interval: 0, canContinue: { true }, isReady: { false },
            discover: { discoveries += 1; return discoveries }, matches: { _ in true },
            perform: { target in
                guard target == 2 else { return false }
                clicked.append(target)
                return true
            }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(discoveries, 2)
        XCTAssertEqual(clicked, [2])
    }

    func testDeliveredClickRemainsSuccessfulIfCancellationArrivesDuringRelease() {
        var allowed = true
        var readinessChecks = 0
        var actions = 0
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(1), interval: 0, canContinue: { allowed },
            isReady: { readinessChecks += 1; return false },
            discover: { 1 }, matches: { _ in true },
            perform: { _ in actions += 1; allowed = false; return true }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(readinessChecks, 2)
    }

    func testFinalVerificationFailureNeverReportsSuccess() {
        var rejectedActions = 0
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(1), interval: 0, canContinue: { rejectedActions == 0 }, isReady: { false },
            discover: { 1 }, matches: { _ in true },
            perform: { _ in rejectedActions += 1; return false }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(rejectedActions, 1)
    }

    func testCancellationDuringRediscoveryPreventsHitLookupAndClick() {
        var allowed = true
        var hits = 0
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(0.01), interval: 0, canContinue: { allowed }, isReady: { false },
            discover: { allowed = false; return 1 },
            matches: { _ in hits += 1; return true },
            perform: { _ in clicked = true; return true }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(hits, 0)
        XCTAssertFalse(clicked)
    }

    func testCancellationDuringMainReadinessPreventsSuccessAndClick() {
        var allowed = true
        var discoveries = 0
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(1), canContinue: { allowed }, isReady: { allowed = false; return true },
            discover: { discoveries += 1; return 1 }, matches: { _ in true },
            perform: { _ in clicked = true; return true }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(discoveries, 0)
        XCTAssertFalse(clicked)
    }

    func testWaitsForExactHitAfterTransientMisses() {
        var probes = 0
        let confirmed = waitForHit(deadline: Date().addingTimeInterval(1), interval: 0, canContinue: { true }) {
            probes += 1
            return probes == 3
        }

        XCTAssertTrue(confirmed)
        XCTAssertEqual(probes, 3)
    }

    func testNeverAcceptsAnUnrelatedHit() {
        XCTAssertFalse(waitForHit(deadline: Date().addingTimeInterval(0.001), interval: 0, canContinue: { true }) {
            false
        })
    }

    func testReadyHitNeedsOnlyOneLookup() {
        var probes = 0
        XCTAssertTrue(waitForHit(deadline: Date().addingTimeInterval(1), canContinue: { true }) {
            probes += 1
            return true
        })
        XCTAssertEqual(probes, 1)
    }

    func testCancellationPreventsHitLookup() {
        var probes = 0
        XCTAssertFalse(waitForHit(deadline: Date().addingTimeInterval(1), canContinue: { false }) {
            probes += 1
            return true
        })
        XCTAssertEqual(probes, 0)
    }

    func testCancellationDuringLookupPreventsConfirmation() {
        var allowed = true
        var probes = 0
        XCTAssertFalse(waitForHit(deadline: Date().addingTimeInterval(1), canContinue: { allowed }) {
            probes += 1
            allowed = false
            return true
        })
        XCTAssertEqual(probes, 1)
    }

    func testCancellationAfterMissStopsRetrying() {
        var allowed = true
        var probes = 0
        XCTAssertFalse(waitForHit(deadline: Date().addingTimeInterval(1), interval: 0, canContinue: { allowed }) {
            probes += 1
            allowed = false
            return false
        })
        XCTAssertEqual(probes, 1)
    }

    func testExactHitReadinessAfterOldCapButBeforeDeadline() {
        let deadline = Date().addingTimeInterval(5)
        let hitReadyAt = Date().addingTimeInterval(2.2)
        var performedActions = 0
        let result = WeChatStartupClick.performWhenReady(
            deadline: deadline, interval: 0.05, canContinue: { true },
            isReady: { false }, discover: { 1 },
            matches: { _ in Date() >= hitReadyAt },
            perform: { _ in performedActions += 1; return true }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(performedActions, 1)
    }

    func testReadinessReturningAfterDeadlinePreventsDiscoveryAndClick() {
        XCTAssertFalse(WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(0.05), canContinue: { true },
            isReady: { Thread.sleep(forTimeInterval: 0.1); return true },
            discover: { XCTFail("expired during readiness"); return 1 },
            matches: { _ in XCTFail("expired during readiness"); return true },
            perform: { _ in XCTFail("expired during readiness"); return true }
        ))
    }

    func testHitReturningAfterDeadlinePreventsClick() {
        XCTAssertFalse(WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(0.05), canContinue: { true },
            isReady: { false }, discover: { 1 },
            matches: { _ in Thread.sleep(forTimeInterval: 0.1); return true },
            perform: { _ in XCTFail("expired during hit lookup"); return true }
        ))
    }

    func testDeliveredClickRemainsSuccessfulIfDeadlinePassesDuringRelease() {
        var actions = 0
        XCTAssertTrue(WeChatStartupClick.performWhenReady(
            deadline: Date().addingTimeInterval(0.05), canContinue: { true },
            isReady: { false }, discover: { 1 }, matches: { _ in true },
            perform: { _ in actions += 1; Thread.sleep(forTimeInterval: 0.1); return true }
        ))
        XCTAssertEqual(actions, 1)
    }

    private func waitForHit(
        deadline: Date, interval: TimeInterval = 0.05,
        canContinue: () -> Bool, matches: () -> Bool
    ) -> Bool {
        WeChatStartupClick.performWhenReady(
            deadline: deadline, interval: interval, canContinue: canContinue, isReady: { false },
            discover: { true }, matches: { _ in matches() }, perform: { _ in true }
        )
    }
}
#endif
