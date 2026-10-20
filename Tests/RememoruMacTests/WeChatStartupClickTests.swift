#if os(macOS)
import XCTest
@testable import RememoruMac

final class WeChatStartupClickTests: XCTestCase {
    func testRediscoversMovedOrReplacedTargetBeforeClicking() {
        var discoveries = 0
        var clicked: [Int] = []
        let result = WeChatStartupClick.performWhenReady(
            timeout: 1, interval: 0, canContinue: { true }, isReady: { false },
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
            timeout: 1, interval: 0, canContinue: { true }, isReady: { ready },
            discover: { 1 }, matches: { _ in ready = true; return false },
            perform: { _ in clicked = true; return true }
        )

        XCTAssertTrue(result)
        XCTAssertFalse(clicked)
    }

    func testPersistentUnrelatedTargetNeverClicks() {
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            timeout: 0.001, interval: 0, canContinue: { true }, isReady: { false },
            discover: { 1 }, matches: { _ in false }, perform: { _ in clicked = true; return true }
        )

        XCTAssertFalse(result)
        XCTAssertFalse(clicked)
    }

    func testChecksReadinessAgainAfterTheHitWaitExpires() {
        var readinessChecks = 0
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            timeout: 0, interval: 0, canContinue: { true }, isReady: {
                readinessChecks += 1
                return readinessChecks == 2
            },
            discover: { 1 }, matches: { _ in false }, perform: { _ in clicked = true; return true }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(readinessChecks, 2)
        XCTAssertFalse(clicked)
    }

    func testMainWindowArrivingAfterExactHitPreventsClick() {
        var readinessChecks = 0
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            timeout: 1, canContinue: { true }, isReady: {
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
            timeout: 1, interval: 0, canContinue: { true }, isReady: { false },
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
            timeout: 1, interval: 0, canContinue: { allowed },
            isReady: { readinessChecks += 1; return false },
            discover: { 1 }, matches: { _ in true },
            perform: { _ in actions += 1; allowed = false; return true }
        )

        XCTAssertTrue(result)
        XCTAssertEqual(actions, 1)
        XCTAssertEqual(readinessChecks, 2)
    }

    func testPersistentFinalVerificationFailureNeverReportsSuccess() {
        var rejectedActions = 0
        let result = WeChatStartupClick.performWhenReady(
            timeout: 0.001, interval: 0, canContinue: { true }, isReady: { false },
            discover: { 1 }, matches: { _ in true },
            perform: { _ in rejectedActions += 1; return false }
        )

        XCTAssertFalse(result)
        XCTAssertGreaterThan(rejectedActions, 0)
    }

    func testCancellationDuringRediscoveryPreventsHitLookupAndClick() {
        var allowed = true
        var hits = 0
        var clicked = false
        let result = WeChatStartupClick.performWhenReady(
            timeout: 0.01, interval: 0, canContinue: { allowed }, isReady: { false },
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
            timeout: 1, canContinue: { allowed }, isReady: { allowed = false; return true },
            discover: { discoveries += 1; return 1 }, matches: { _ in true },
            perform: { _ in clicked = true; return true }
        )

        XCTAssertFalse(result)
        XCTAssertEqual(discoveries, 0)
        XCTAssertFalse(clicked)
    }

    func testWaitsForExactHitAfterTransientMisses() {
        var probes = 0
        let confirmed = waitForHit(timeout: 1, interval: 0, canContinue: { true }) {
            probes += 1
            return probes == 3
        }

        XCTAssertTrue(confirmed)
        XCTAssertEqual(probes, 3)
    }

    func testNeverAcceptsAnUnrelatedHit() {
        XCTAssertFalse(waitForHit(timeout: 0.001, interval: 0, canContinue: { true }) {
            false
        })
    }

    func testReadyHitNeedsOnlyOneLookup() {
        var probes = 0
        XCTAssertTrue(waitForHit(timeout: 1, canContinue: { true }) {
            probes += 1
            return true
        })
        XCTAssertEqual(probes, 1)
    }

    func testCancellationPreventsHitLookup() {
        var probes = 0
        XCTAssertFalse(waitForHit(timeout: 1, canContinue: { false }) {
            probes += 1
            return true
        })
        XCTAssertEqual(probes, 0)
    }

    func testCancellationDuringLookupPreventsConfirmation() {
        var allowed = true
        var probes = 0
        XCTAssertFalse(waitForHit(timeout: 1, canContinue: { allowed }) {
            probes += 1
            allowed = false
            return true
        })
        XCTAssertEqual(probes, 1)
    }

    func testCancellationAfterMissStopsRetrying() {
        var allowed = true
        var probes = 0
        XCTAssertFalse(waitForHit(timeout: 1, interval: 0, canContinue: { allowed }) {
            probes += 1
            allowed = false
            return false
        })
        XCTAssertEqual(probes, 1)
    }

    private func waitForHit(
        timeout: TimeInterval, interval: TimeInterval = 0.05,
        canContinue: () -> Bool, matches: () -> Bool
    ) -> Bool {
        WeChatStartupClick.performWhenReady(
            timeout: timeout, interval: interval, canContinue: canContinue, isReady: { false },
            discover: { true }, matches: { _ in matches() }, perform: { _ in true }
        )
    }
}
#endif
