#if os(macOS)
import XCTest
import RememoruCore
@testable import RememoruMac

final class WeChatOpenerTests: XCTestCase {
    func testWaitsForTheMainWindowAfterPressingOnce() {
        var presses = 0
        var probes = 0
        let result = WeChatOpener.open(
            observe: { _ in
                probes += 1
                return probes == 3 ? .mainWindow : .openButton(press: { presses += 1; return true })
            },
            cancellation: CancellationFlag(), timeout: 1, interval: 0.001
        )

        XCTAssertEqual(result, .done)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(probes, 3)
    }

    func testFailedPressDoesNotWaitOrReportSuccess() {
        var probes = 0
        let result = WeChatOpener.open(
            observe: { _ in probes += 1; return .openButton(press: { false }) }, cancellation: CancellationFlag()
        )

        guard case .failed = result else { return XCTFail("expected a failed press") }
        XCTAssertEqual(probes, 1)
    }

    func testPhoneConfirmationOrTimeoutIsAReportedFailure() {
        var presses = 0
        let result = WeChatOpener.open(
            observe: { _ in
                presses == 0 ? .openButton(press: { presses += 1; return true }) : .waiting
            }, cancellation: CancellationFlag(), timeout: 0.01, interval: 0.001
        )
        guard let result, case .failed(let reason) = result else { return XCTFail("expected readiness failure") }
        XCTAssertTrue(reason.contains("phone confirmation"))
        XCTAssertEqual(presses, 1)

        var report = RestoreReport()
        report.entries.append(.init(step: .openWeChat, outcome: result))
        XCTAssertFalse(report.isClean)
        XCTAssertEqual(report.failures.count, 1)
    }

    func testCancellationPreventsPressing() {
        let cancellation = CancellationFlag()
        cancellation.cancel()
        var presses = 0
        let result = WeChatOpener.open(
            observe: { _ in .openButton(press: { presses += 1; return true }) }, cancellation: cancellation
        )

        XCTAssertEqual(result, .skipped("cancelled"))
        XCTAssertEqual(presses, 0)
    }

    func testCancellationStopsWaitingForTheMainWindow() {
        let cancellation = CancellationFlag()
        var presses = 0
        let result = WeChatOpener.open(
            observe: { _ in
                if presses == 0 { return .openButton(press: { presses += 1; return true }) }
                cancellation.cancel()
                return .waiting
            }, cancellation: cancellation,
            timeout: 1, interval: 0.001
        )

        XCTAssertEqual(result, .skipped("cancelled"))
        XCTAssertEqual(presses, 1)
    }

    func testWaitsForStartupControlsBeforePressing() {
        var presses = 0
        var probes = 0
        let result = WeChatOpener.open(observe: { _ in
            probes += 1
            if probes < 3 { return .waiting }
            if probes == 3 { return .openButton(press: { presses += 1; return true }) }
            return .mainWindow
        }, cancellation: CancellationFlag(), timeout: 1, interval: 0.001)

        XCTAssertEqual(result, .done)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(probes, 4)
    }

    func testAlreadyOpenMainWindowNeedsNoPreparationEntry() {
        let result = WeChatOpener.open(
            observe: { _ in .mainWindow }, cancellation: CancellationFlag()
        )
        XCTAssertNil(result)
    }

    func testHiddenMainWindowOrAbsentStartupPanelDoesNotFailPreparation() {
        let result = WeChatOpener.open(
            observe: { _ in .waiting }, cancellation: CancellationFlag(), discoveryTimeout: 0
        )
        XCTAssertNil(result, "AXWindows can omit a valid main window on another Space")
    }

    func testCancellationDuringDiscoveryPreventsPressing() {
        let cancellation = CancellationFlag()
        var presses = 0
        let result = WeChatOpener.open(observe: { _ in
            cancellation.cancel()
            return .openButton(press: { presses += 1; return true })
        }, cancellation: cancellation)

        XCTAssertEqual(result, .skipped("cancelled"))
        XCTAssertEqual(presses, 0)
    }
}
#endif
