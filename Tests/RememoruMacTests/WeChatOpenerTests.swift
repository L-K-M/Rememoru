#if os(macOS)
import XCTest
import RememoruCore
@testable import RememoruMac

final class WeChatOpenerTests: XCTestCase {
    func testExplicitOpenButtonTakesPriorityOverMainWindowControls() {
        var readinessChecks = 0
        var presses = 0
        let observation = WeChatOpener.classify(
            openButton: { .openButton(press: { _ in presses += 1; return true }) },
            isMainWindow: { readinessChecks += 1; return true }
        )

        guard case .openButton(let press) = observation else { return XCTFail("expected the exact startup action") }
        XCTAssertTrue(press(Date().addingTimeInterval(1)))
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(readinessChecks, 0)
    }

    func testDelayedStartupContentRemainsWaitingWithDisabledZoom() {
        let observation = WeChatOpener.classify(openButton: { nil }, isMainWindow: {
            WeChatStartup.isMainWindow(
                isStandardWindow: true, isFullscreen: false, hasMinimizeButton: true, isZoomEnabled: false
            )
        })

        guard case .waiting = observation else { return XCTFail("startup controls do not prove main readiness") }
    }

    func testWaitsForTheMainWindowAfterPressingOnce() {
        var presses = 0
        var probes = 0
        let result = WeChatOpener.open(
            observe: { _ in
                probes += 1
                return probes == 3 ? .mainWindow : .openButton(press: { _ in presses += 1; return true })
            },
            cancellation: CancellationFlag(), timeout: 1, interval: 0.001
        )

        XCTAssertEqual(result, .done)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(probes, 3)
    }

    func testPressReceivesFreshActionDeadlineBeyondDiscoveryDeadline() {
        var pressed = false
        let result = WeChatOpener.open(observe: { discoveryDeadline in
            if pressed { return .mainWindow }
            return .openButton(press: { actionDeadline in
                XCTAssertGreaterThan(actionDeadline.timeIntervalSince(discoveryDeadline), 0.5)
                pressed = true
                return true
            })
        }, cancellation: CancellationFlag(), timeout: 1, discoveryTimeout: 0.01, interval: 0.001)

        XCTAssertEqual(result, .done)
        XCTAssertTrue(pressed)
    }

    func testReadinessGetsFreshTimeoutAfterSlowPressFinishes() {
        var observations = 0
        var presses = 0
        let result = WeChatOpener.open(observe: { _ in
            observations += 1
            if observations > 1 { return .mainWindow }
            return .openButton(press: { _ in
                presses += 1
                Thread.sleep(forTimeInterval: 0.02)
                return true
            })
        }, cancellation: CancellationFlag(), timeout: 0.01, interval: 0.001)

        XCTAssertEqual(result, .done)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(observations, 2)
    }

    func testFailedPressDoesNotWaitOrReportSuccess() {
        var probes = 0
        let result = WeChatOpener.open(
            observe: { _ in probes += 1; return .openButton(press: { _ in false }) }, cancellation: CancellationFlag()
        )

        guard case .failed = result else { return XCTFail("expected a failed press") }
        XCTAssertEqual(probes, 1)
    }

    func testPhoneConfirmationOrTimeoutIsAReportedFailure() {
        var presses = 0
        let result = WeChatOpener.open(
            observe: { _ in
                presses == 0 ? .openButton(press: { _ in presses += 1; return true }) : .waiting
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
            observe: { _ in .openButton(press: { _ in presses += 1; return true }) }, cancellation: cancellation
        )

        XCTAssertEqual(result, .skipped("cancelled"))
        XCTAssertEqual(presses, 0)
    }

    func testCancellationStopsWaitingForTheMainWindow() {
        let cancellation = CancellationFlag()
        var presses = 0
        let result = WeChatOpener.open(
            observe: { _ in
                if presses == 0 { return .openButton(press: { _ in presses += 1; return true }) }
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
            if probes == 3 { return .openButton(press: { _ in presses += 1; return true }) }
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
            return .openButton(press: { _ in presses += 1; return true })
        }, cancellation: cancellation)

        XCTAssertEqual(result, .skipped("cancelled"))
        XCTAssertEqual(presses, 0)
    }

    func testFindsHiddenStartupAndItsReplacementThroughWindowServerIDs() {
        let cancellation = CancellationFlag()
        var currentWindowIDs: [UInt32] = [200]
        var available = Set<UInt32>()
        var resolved: [Set<UInt32>] = []
        var presses = 0
        var helperPresses = 0
        let result = WeChatOpener.open(observe: { deadline in
            WeChatOpener.discover(
                windowIDs: currentWindowIDs, listedWindowIDs: [1383],
                resolveHidden: { ids in resolved.append(ids); available.formUnion(ids) },
                inspect: { id in
                    if id == 1383 { return .openButton(press: { _ in helperPresses += 1; return true }) }
                    guard available.contains(id) else { return .waiting }
                    if id == 250 { return .mainWindow }
                    return .openButton(press: { _ in
                        presses += 1
                        currentWindowIDs = [250]
                        return true
                    })
                },
                deadline: deadline, cancellation: cancellation
            )
        }, cancellation: cancellation, timeout: 1, discoveryTimeout: 0.02, interval: 0.001)

        XCTAssertEqual(result, .done)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(resolved, [[200], [250]])
        XCTAssertEqual(helperPresses, 0, "a helper without a managed Space is not a startup candidate")
    }

    func testFindsHiddenMainWithoutPressingOrChangingItsSpace() {
        let cancellation = CancellationFlag()
        var resolved = Set<UInt32>()
        let result = WeChatOpener.open(observe: { deadline in
            WeChatOpener.discover(
                windowIDs: [200], listedWindowIDs: [],
                resolveHidden: { resolved.formUnion($0) },
                inspect: { id in resolved.contains(id) ? .mainWindow : .waiting },
                deadline: deadline, cancellation: cancellation
            )
        }, cancellation: cancellation, discoveryTimeout: 0.02, interval: 0.001)

        XCTAssertNil(result)
        XCTAssertEqual(resolved, [200])
    }

    func testHiddenMainTakesPriorityOverRetainedListedStartupPanel() {
        let cancellation = CancellationFlag()
        var resolved = Set<UInt32>()
        var presses = 0
        let result = WeChatOpener.open(observe: { deadline in
            WeChatOpener.discover(
                windowIDs: [200, 250], listedWindowIDs: [200],
                resolveHidden: { resolved.formUnion($0) },
                inspect: { id in
                    if id == 250 { return resolved.contains(id) ? .mainWindow : .waiting }
                    return .openButton(press: { _ in presses += 1; return true })
                },
                deadline: deadline, cancellation: cancellation
            )
        }, cancellation: cancellation, timeout: 0.01, interval: 0.001)

        XCTAssertNil(result)
        XCTAssertEqual(presses, 0)
        XCTAssertEqual(resolved, [250])
    }

    func testListedMainDoesNotNeedHiddenLookup() {
        _ = WeChatOpener.discover(
            windowIDs: [200, 250], listedWindowIDs: [200],
            resolveHidden: { _ in XCTFail("a ready listed main window needs no remote probe") },
            inspect: { id in
                XCTAssertEqual(id, 200)
                return .mainWindow
            },
            deadline: Date().addingTimeInterval(1), cancellation: CancellationFlag()
        )
    }

    func testListedMainWithoutSingleManagedSpaceTakesPriorityOverStartup() {
        let cancellation = CancellationFlag()
        var presses = 0
        let result = WeChatOpener.open(observe: { deadline in
            WeChatOpener.discover(
                windowIDs: [200], listedWindowIDs: [200, 250],
                resolveHidden: { _ in XCTFail("both windows are already listed") },
                inspect: { id in
                    if id == 250 { return .mainWindow }
                    return .openButton(press: { _ in presses += 1; return true })
                },
                deadline: deadline, cancellation: cancellation
            )
        }, cancellation: cancellation, timeout: 0.01, interval: 0.001)

        XCTAssertNil(result)
        XCTAssertEqual(presses, 0)
    }

    func testNewHiddenMainRestartsRemoteProbeBelowTheOldCursor() {
        let cancellation = CancellationFlag()
        var currentWindowIDs: [UInt32] = [200]
        var previousWindowIDs = Set<UInt32>()
        var available = Set<UInt32>()
        var cursor = 0
        var resets = 0
        var presses = 0
        let result = WeChatOpener.open(observe: { deadline in
            WeChatOpener.updateCandidates(currentWindowIDs, previous: &previousWindowIDs, reset: {
                resets += 1
                available.removeAll()
                cursor = 0
            })
            return WeChatOpener.discover(
                windowIDs: currentWindowIDs, listedWindowIDs: [],
                resolveHidden: { ids in
                    for id in ids {
                        let elementID = id == 200 ? 44 : 30
                        if cursor <= elementID { available.insert(id) }
                        cursor = max(cursor, elementID + 1)
                    }
                },
                inspect: { id in
                    guard available.contains(id) else { return .waiting }
                    if id == 250 { return .mainWindow }
                    return .openButton(press: { _ in
                        presses += 1
                        currentWindowIDs = [250]
                        return true
                    })
                },
                deadline: deadline, cancellation: cancellation
            )
        }, cancellation: cancellation, timeout: 0.01, interval: 0.001)

        XCTAssertEqual(result, .done)
        XCTAssertEqual(presses, 1)
        XCTAssertEqual(resets, 2)
    }

    func testUnchangedWindowSetPreservesRemoteProbeProgress() {
        var previousWindowIDs: Set<UInt32> = [200, 250]
        WeChatOpener.updateCandidates([250, 200], previous: &previousWindowIDs, reset: {
            XCTFail("window order alone must not restart a bounded remote probe")
        })
        XCTAssertEqual(previousWindowIDs, [200, 250])
    }

    func testCancellationAfterHiddenLookupPreventsInspectionAndPressing() {
        let cancellation = CancellationFlag()
        var inspections = 0
        _ = WeChatOpener.discover(
            windowIDs: [200], listedWindowIDs: [],
            resolveHidden: { _ in cancellation.cancel() },
            inspect: { _ in inspections += 1; return .mainWindow },
            deadline: Date().addingTimeInterval(1), cancellation: cancellation
        )

        XCTAssertTrue(cancellation.isCancelled)
        XCTAssertEqual(inspections, 0)
    }
}
#endif
