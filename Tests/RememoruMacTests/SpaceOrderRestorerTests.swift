#if os(macOS)
import XCTest
import RememoruCore
@testable import RememoruMac

final class SpaceOrderRestorerTests: XCTestCase {

    func testMatchingOrderConfirmsMove() {
        let expected: [UInt64] = [1, 2, 3]
        let outcome = SpaceOrderRestorer.verifyMoveOutcome(actual: expected, expected: expected)
        XCTAssertEqual(outcome, RestoreReport.Outcome.done)
    }

    func testObservedDifferentOrderReportsMismatch() {
        let expected: [UInt64] = [1, 2, 3]
        let actual: [UInt64] = [1, 3, 2]
        let outcome = SpaceOrderRestorer.verifyMoveOutcome(actual: actual, expected: expected)
        guard case .failed(let message) = outcome else {
            XCTFail("expected .failed, got \(outcome)")
            return
        }
        XCTAssertTrue(message.contains("did not match"), "message should mention mismatch: \(message)")
    }

    func testUnreadableOrderDoesNotClaimMismatchOrSuccess() {
        let expected: [UInt64] = [1, 2, 3]
        let outcome = SpaceOrderRestorer.verifyMoveOutcome(actual: nil, expected: expected)
        guard case .failed(let message) = outcome else {
            XCTFail("expected .failed, got \(outcome)")
            return
        }
        XCTAssertTrue(message.contains("could not verify"), "message should say could not verify: \(message)")
        XCTAssertFalse(message.contains("did not match"), "unavailable should not say did not match: \(message)")
    }
}
#endif
