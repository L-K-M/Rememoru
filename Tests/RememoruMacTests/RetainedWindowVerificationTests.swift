#if os(macOS)
import XCTest
import RememoruCore
@testable import RememoruMac

final class RetainedWindowVerificationTests: XCTestCase {
    private let display = LiveDisplay(
        id: 1, uuid: "D", frame: Rect(x: 0, y: 0, w: 1920, h: 1080), isMain: true
    )

    private func state(active: UInt64, windows: [LiveWindow]) -> LiveState {
        LiveState(displays: [display], spaces: (1...3).map { id in
            LiveSpace(id: UInt64(id), key: "space\(id)", kind: .desktop, displayUUID: "D",
                      index: id - 1, isActive: UInt64(id) == active)
        }, windows: windows)
    }

    private func window(_ id: UInt32, space: UInt64, onscreen: Bool = false) -> LiveWindow {
        LiveWindow(id: id, pid: 42, appName: "Notes", title: "window\(id)",
                   frame: Rect(x: 0, y: 25, w: 800, h: 600), isOnscreen: onscreen, spaceID: space)
    }

    private func saved(_ windows: [LiveWindow]) -> [WindowRecord] {
        windows.map { window in
            WindowRecord(windowID: window.id, pid: window.pid, appName: window.appName,
                         bundleID: window.bundleID, title: window.title, frame: window.frame,
                         spaceUUID: nil, displayUUID: "D")
        }
    }

    private func candidates(_ state: LiveState, matches: [Int: WindowMatch]) -> [UInt64: [LiveWindow]] {
        let windows = matches.values.map(\.live).filter {
            WindowFilter.requiresSpaceVerification(
                $0, on: state.space(id: $0.spaceID), applicationHidden: false, accessibility: .notListed
            )
        }
        return Dictionary(grouping: windows, by: { $0.spaceID! })
    }

    func testExcludedSurfaceDoesNotReturnAfterCheckingAnotherSpace() {
        let first = window(10, space: 1)
        let unmatchedHelper = window(11, space: 1)
        let second = window(20, space: 2)
        let initial = state(active: 3, windows: [first, unmatchedHelper, second])
        let reads = [state(active: 1, windows: [second]),
                     state(active: 2, windows: [first, unmatchedHelper, window(20, space: 2, onscreen: true)])]
        var readIndex = 0
        var shown: [UInt64] = []

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved([first, second]),
            candidates: candidates, showSpace: { space, _ in shown.append(space.id); return true },
            readState: { defer { readIndex += 1 }; return reads[readIndex] },
            canContinue: { true }, verificationUnavailable: { _ in XCTFail("verification should succeed") }
        )

        XCTAssertEqual(shown, [1, 2])
        XCTAssertEqual(readIndex, 2)
        XCTAssertEqual(result.windows.map(\.id), [20])
    }

    func testFailedSpaceShowPreservesCandidateAndDoesNotRetry() {
        let initial = state(active: 3, windows: [window(10, space: 1)])
        var shown: [UInt64] = []
        var unavailable: [UInt64] = []

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { space, _ in shown.append(space.id); return false },
            readState: { XCTFail("failed Space show must not read verification state"); return initial },
            canContinue: { true }, verificationUnavailable: { unavailable.append($0) }
        )

        XCTAssertEqual(shown, [1])
        XCTAssertEqual(unavailable, [1])
        XCTAssertEqual(result, initial)
    }

    func testCancellationAfterShowingSpaceStopsBeforeReading() {
        let initial = state(active: 3, windows: [window(10, space: 1)])
        var cancelled = false
        var showCount = 0

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { _, _ in showCount += 1; cancelled = true; return true },
            readState: { XCTFail("cancelled verification must not read state"); return initial },
            canContinue: { !cancelled }, verificationUnavailable: { _ in XCTFail("cancelled") }
        )

        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(result, initial)
    }

    func testUnconfirmedFreshSpaceKeepsCandidate() {
        let initial = state(active: 3, windows: [window(10, space: 1)])
        var unavailable: [UInt64] = []

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { _, _ in true }, readState: { self.state(active: 3, windows: []) },
            canContinue: { true }, verificationUnavailable: { unavailable.append($0) }
        )

        XCTAssertEqual(unavailable, [1])
        XCTAssertEqual(result.windows.map(\.id), [10])
    }

    func testFailedVerificationStaysMatchedAcrossAnotherFreshRead() {
        let first = window(10, space: 1)
        let second = window(20, space: 2)
        let initial = state(active: 3, windows: [first, second])
        var shown: [UInt64] = []
        var unavailable: [UInt64] = []

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { space, _ in shown.append(space.id); return space.id == 2 },
            readState: { self.state(active: 2, windows: [self.window(20, space: 2, onscreen: true)]) },
            canContinue: { true }, verificationUnavailable: { unavailable.append($0) }
        )

        XCTAssertEqual(shown, [1, 2])
        XCTAssertEqual(unavailable, [1])
        XCTAssertEqual(Set(result.windows.map(\.id)), [10, 20])
    }
}
#endif
