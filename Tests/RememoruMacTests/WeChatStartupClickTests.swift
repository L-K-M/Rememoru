#if os(macOS)
import XCTest
@testable import RememoruMac

final class WeChatStartupClickTests: XCTestCase {
    func testWaitsForExactHitAfterTransientMisses() {
        var probes = 0
        let confirmed = WeChatStartupClick.waitForHit(timeout: 0.1, interval: 0, canContinue: { true }) {
            probes += 1
            return probes == 3
        }

        XCTAssertTrue(confirmed)
        XCTAssertEqual(probes, 3)
    }

    func testNeverAcceptsAnUnrelatedHit() {
        XCTAssertFalse(WeChatStartupClick.waitForHit(timeout: 0.001, interval: 0, canContinue: { true }) {
            false
        })
    }

    func testReadyHitNeedsOnlyOneLookup() {
        var probes = 0
        XCTAssertTrue(WeChatStartupClick.waitForHit(timeout: 1, canContinue: { true }) {
            probes += 1
            return true
        })
        XCTAssertEqual(probes, 1)
    }

    func testCancellationPreventsHitLookup() {
        var probes = 0
        XCTAssertFalse(WeChatStartupClick.waitForHit(timeout: 1, canContinue: { false }) {
            probes += 1
            return true
        })
        XCTAssertEqual(probes, 0)
    }

    func testCancellationDuringLookupPreventsConfirmation() {
        var allowed = true
        var probes = 0
        XCTAssertFalse(WeChatStartupClick.waitForHit(timeout: 1, canContinue: { allowed }) {
            probes += 1
            allowed = false
            return true
        })
        XCTAssertEqual(probes, 1)
    }

    func testCancellationAfterMissStopsRetrying() {
        var allowed = true
        var probes = 0
        XCTAssertFalse(WeChatStartupClick.waitForHit(timeout: 1, interval: 0, canContinue: { allowed }) {
            probes += 1
            allowed = false
            return false
        })
        XCTAssertEqual(probes, 1)
    }
}
#endif
