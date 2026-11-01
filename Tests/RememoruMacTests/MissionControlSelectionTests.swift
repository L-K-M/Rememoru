#if os(macOS)
import XCTest
@testable import RememoruMac

final class MissionControlSelectionTests: XCTestCase {
    func testIgnoredClickUsesOneValidatedNativePress() {
        var actions: [String] = []
        var closed = false
        XCTAssertTrue(MissionControl.selectWithFallback(
            canContinue: { true }, press: { actions.append("click"); return true },
            waitUntilClosed: { closed }, isOpen: { !closed },
            validateFallback: { actions.append("validate"); return true },
            pressFallback: { actions.append("AXPress"); closed = true; return true }
        ))
        XCTAssertEqual(actions, ["click", "validate", "AXPress"])
    }

    func testSuccessfulClickNeedsNoFallback() {
        XCTAssertTrue(MissionControl.selectWithFallback(
            canContinue: { true }, press: { true }, waitUntilClosed: { true },
            isOpen: { XCTFail("already closed"); return false },
            validateFallback: { XCTFail("already closed"); return false },
            pressFallback: { XCTFail("already closed"); return false }
        ))
    }

    func testRejectedClickNeverUsesFallback() {
        XCTAssertFalse(MissionControl.selectWithFallback(
            canContinue: { true }, press: { false },
            waitUntilClosed: { XCTFail("no click was posted"); return false },
            isOpen: { XCTFail("no click was posted"); return true },
            validateFallback: { XCTFail("no click was posted"); return true },
            pressFallback: { XCTFail("no click was posted"); return true }
        ))
    }

    func testLateClosureNeedsNoFallback() {
        XCTAssertTrue(MissionControl.selectWithFallback(
            canContinue: { true }, press: { true }, waitUntilClosed: { false },
            isOpen: { false }, validateFallback: { XCTFail("closed"); return true },
            pressFallback: { XCTFail("closed"); return true }
        ))
    }

    func testUnavailableOverviewNeverUsesFallback() {
        XCTAssertFalse(MissionControl.selectWithFallback(
            canContinue: { true }, press: { true }, waitUntilClosed: { false },
            isOpen: { nil }, validateFallback: { XCTFail("unknown visibility"); return true },
            pressFallback: { XCTFail("unknown visibility"); return true }
        ))
    }

    func testChangedTargetNeverReceivesFallbackPress() {
        XCTAssertFalse(MissionControl.selectWithFallback(
            canContinue: { true }, press: { true }, waitUntilClosed: { false },
            isOpen: { true }, validateFallback: { false },
            pressFallback: { XCTFail("target changed"); return true }
        ))
    }

    func testVisibilityChangingDuringValidationPreventsAnotherPress() {
        for finalState: Bool? in [false, nil] {
            var state: Bool? = true
            let confirmed = MissionControl.selectWithFallback(
                canContinue: { true }, press: { true }, waitUntilClosed: { false },
                isOpen: { state }, validateFallback: { state = finalState; return true },
                pressFallback: { XCTFail("overview is no longer confirmed open"); return true }
            )
            XCTAssertEqual(confirmed, finalState == false)
        }
    }

    func testRejectedNativePressDoesNotConfirmSelection() {
        XCTAssertFalse(MissionControl.selectWithFallback(
            canContinue: { true }, press: { true }, waitUntilClosed: { false },
            isOpen: { true }, validateFallback: { true }, pressFallback: { false }
        ))
    }

    func testNativePressStillRequiresObservedClosure() {
        var presses = 0
        XCTAssertFalse(MissionControl.selectWithFallback(
            canContinue: { true }, press: { true }, waitUntilClosed: { false },
            isOpen: { true }, validateFallback: { true },
            pressFallback: { presses += 1; return true }
        ))
        XCTAssertEqual(presses, 1)
    }

    func testCancellationAtEachBoundaryPreventsFallbackPress() {
        for cancellationPoint in ["before", "click", "wait", "state", "validate"] {
            var allowed = cancellationPoint != "before"
            XCTAssertFalse(MissionControl.selectWithFallback(
                canContinue: { allowed }, press: {
                    if cancellationPoint == "click" { allowed = false }
                    return true
                }, waitUntilClosed: {
                    if cancellationPoint == "wait" { allowed = false }
                    return false
                }, isOpen: {
                    if cancellationPoint == "state" { allowed = false }
                    return true
                }, validateFallback: {
                    if cancellationPoint == "validate" { allowed = false }
                    return true
                }, pressFallback: { XCTFail("cancelled at \(cancellationPoint)"); return true }
            ))
        }
    }
}
#endif
