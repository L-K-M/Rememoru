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
            restoreSpace: { _, _ in true },
            readSpaces: { initial.spaces },
            readState: {
                defer { readIndex += 1 }
                guard readIndex < reads.count else {
                    XCTFail("unexpected verification read")
                    return initial
                }
                return reads[readIndex]
            },
            canContinue: { true }, verificationUnavailable: { _ in XCTFail("verification should succeed") },
            returnUnavailable: { _, _ in XCTFail("return should succeed") }
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
            restoreSpace: { _, _ in true },
            readSpaces: { initial.spaces },
            readState: { XCTFail("failed Space show must not read verification state"); return initial },
            canContinue: { true }, verificationUnavailable: { unavailable.append($0) },
            returnUnavailable: { _, _ in XCTFail("return should succeed") }
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
            restoreSpace: { _, _ in true },
            readSpaces: { initial.spaces },
            readState: { XCTFail("cancelled verification must not read state"); return initial },
            canContinue: { !cancelled }, verificationUnavailable: { _ in XCTFail("cancelled") },
            returnUnavailable: { _, _ in XCTFail("return should succeed") }
        )

        XCTAssertEqual(showCount, 1)
        XCTAssertEqual(result, initial)
    }

    func testUnconfirmedFreshSpaceKeepsCandidate() {
        let initial = state(active: 3, windows: [window(10, space: 1)])
        var unavailable: [UInt64] = []

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { _, _ in true },
            restoreSpace: { _, _ in true },
            readSpaces: { initial.spaces }, readState: { self.state(active: 3, windows: []) },
            canContinue: { true }, verificationUnavailable: { unavailable.append($0) },
            returnUnavailable: { _, _ in XCTFail("return should succeed") }
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
            restoreSpace: { _, _ in true },
            readSpaces: { initial.spaces },
            readState: { self.state(active: 2, windows: [self.window(20, space: 2, onscreen: true)]) },
            canContinue: { true }, verificationUnavailable: { unavailable.append($0) },
            returnUnavailable: { _, _ in XCTFail("return should succeed") }
        )

        XCTAssertEqual(shown, [1, 2])
        XCTAssertEqual(unavailable, [1])
        XCTAssertEqual(Set(result.windows.map(\.id)), [10, 20])
    }

    func testReturnsChangedDisplaysToOriginalSpacesWithoutResurrectingSurfaces() {
        let secondDisplay = LiveDisplay(id: 2, uuid: "E", frame: display.frame, isMain: false)
        let untouchedDisplay = LiveDisplay(id: 3, uuid: "F", frame: display.frame, isMain: false)
        let first = window(10, space: 1)
        let second = window(20, space: 10)
        var initial = state(active: 3, windows: [first, second])
        initial.displays += [secondDisplay, untouchedDisplay]
        initial.spaces += [
            LiveSpace(id: 10, key: "E1", kind: .desktop, displayUUID: "E", index: 0, isActive: false),
            LiveSpace(id: 30, key: "E2", kind: .desktop, displayUUID: "E", index: 1, isActive: true),
            LiveSpace(id: 100, key: "F1", kind: .desktop, displayUUID: "F", index: 0, isActive: true),
        ]
        var currentSpaces = initial.spaces
        var restored: [UInt64] = []
        var readCount = 0

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { space, _ in currentSpaces = self.showing(space, in: currentSpaces); return true },
            restoreSpace: { space, _ in
                restored.append(space.id)
                currentSpaces = self.showing(space, in: currentSpaces)
                return true
            },
            readSpaces: { currentSpaces },
            readState: {
                readCount += 1
                let windows = readCount == 1 ? [second] : (readCount == 2 ? [] : initial.windows)
                return LiveState(displays: initial.displays, spaces: currentSpaces, windows: windows)
            },
            canContinue: { true }, verificationUnavailable: { _ in XCTFail("verification should succeed") },
            returnUnavailable: { _, _ in XCTFail("return should succeed") }
        )

        XCTAssertEqual(restored, [3, 30])
        XCTAssertEqual(readCount, 3)
        XCTAssertEqual(result.spaces.filter(\.isActive).map(\.id), [3, 30, 100])
        XCTAssertTrue(result.windows.isEmpty)
    }

    func testCancellationAfterFailedShowStillReturnsActualChangedSpace() {
        let initial = state(active: 3, windows: [window(10, space: 1)])
        var currentSpaces = initial.spaces
        var cancelled = false
        var restored: [UInt64] = []

        let result = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { space, _ in
                currentSpaces = self.showing(space, in: currentSpaces)
                cancelled = true
                return false
            },
            restoreSpace: { space, _ in
                restored.append(space.id)
                currentSpaces = self.showing(space, in: currentSpaces)
                return true
            },
            readSpaces: { currentSpaces },
            readState: { XCTFail("cancelled cleanup must avoid a full AX read"); return initial },
            canContinue: { !cancelled }, verificationUnavailable: { _ in XCTFail("cancelled") },
            returnUnavailable: { _, _ in XCTFail("return should succeed") }
        )

        XCTAssertEqual(restored, [3])
        XCTAssertEqual(currentSpaces.filter(\.isActive).map(\.id), [3])
        XCTAssertEqual(result.spaces.filter(\.isActive).map(\.id), [3])
    }

    func testFailedOriginalSpaceReturnIsReported() {
        let initial = state(active: 3, windows: [window(10, space: 1)])
        var currentSpaces = initial.spaces
        var unavailable: [UInt64] = []

        _ = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { space, _ in currentSpaces = self.showing(space, in: currentSpaces); return true },
            restoreSpace: { _, _ in false }, readSpaces: { currentSpaces },
            readState: { LiveState(displays: initial.displays, spaces: currentSpaces, windows: []) },
            canContinue: { true }, verificationUnavailable: { _ in XCTFail("verification should succeed") },
            returnUnavailable: { space, _ in unavailable.append(space.id) }
        )

        XCTAssertEqual(unavailable, [3])
    }

    func testAlreadyOriginalSpaceStillConfirmsInspectionClosure() {
        let initial = state(active: 3, windows: [window(10, space: 1)])
        var cleanupCount = 0
        var unavailable: [UInt64] = []

        _ = RetainedWindowVerification.run(
            initialState: initial, savedWindows: saved(initial.windows), candidates: candidates,
            showSpace: { _, _ in false },
            restoreSpace: { _, _ in cleanupCount += 1; return false }, readSpaces: { initial.spaces },
            readState: { XCTFail("unchanged Space needs no full read"); return initial },
            canContinue: { true }, verificationUnavailable: { _ in },
            returnUnavailable: { space, _ in unavailable.append(space.id) }
        )

        XCTAssertEqual(cleanupCount, 1)
        XCTAssertEqual(unavailable, [3])
    }

    private func showing(_ space: LiveSpace, in spaces: [LiveSpace]) -> [LiveSpace] {
        spaces.map { current in
            var result = current
            if current.displayUUID == space.displayUUID { result.isActive = current.id == space.id }
            return result
        }
    }
}
#endif
