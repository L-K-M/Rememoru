#if os(macOS)
import XCTest
@testable import RememoruMac

final class FullscreenEntryTests: XCTestCase {
    func testAcceptedAXRequestWithoutTransitionFallsBackToMenu() {
        var entered = false
        var commands: [FullscreenEntry.MenuCommand] = []

        let result = FullscreenEntry.run(
            setFullscreen: { true },
            readFullscreen: { false },
            confirm: { _ in entered },
            performMenu: { command in
                commands.append(command)
                if command == .enter { return false }
                entered = true
                return true
            }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertEqual(commands, [.enter, .toggle])
    }

    func testUnsupportedAXRequestUsesToggleMenu() {
        var entered = false
        let result = FullscreenEntry.run(
            setFullscreen: { false },
            readFullscreen: { false },
            confirm: { _ in entered },
            performMenu: { command in
                guard command == .toggle else { return false }
                entered = true
                return true
            }
        )

        XCTAssertEqual(result, .entered)
    }

    func testConfirmedAXRequestDoesNotToggle() {
        var requested = false
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            setFullscreen: { requested = true; return true },
            readFullscreen: { requested },
            confirm: { _ in requested },
            performMenu: { commands.append($0); return true }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertEqual(commands, [])
    }

    func testPendingAXFullscreenStateDoesNotToggleBackOut() {
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            setFullscreen: { true },
            readFullscreen: { true },
            confirm: { _ in false },
            performMenu: { commands.append($0); return true }
        )

        XCTAssertEqual(result, .notConfirmed)
        XCTAssertEqual(commands, [])
    }

    func testMenuSuccessWithoutWindowServerTransitionRemainsFailed() {
        let result = FullscreenEntry.run(
            setFullscreen: { true },
            readFullscreen: { false },
            confirm: { _ in false },
            performMenu: { _ in true }
        )

        XCTAssertEqual(result, .notConfirmed)
    }

    func testLateWindowServerConfirmationSkipsToggle() {
        var immediateProbes = 0
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            setFullscreen: { true },
            readFullscreen: { false },
            confirm: { timeout in
                guard timeout == 0 else { return false }
                immediateProbes += 1
                return immediateProbes == 3
            },
            performMenu: { commands.append($0); return false }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertEqual(commands, [.enter])
    }

    func testUnknownAXStateDoesNotToggle() {
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            setFullscreen: { true },
            readFullscreen: { nil },
            confirm: { _ in false },
            performMenu: { commands.append($0); return false }
        )

        XCTAssertEqual(result, .notConfirmed)
        XCTAssertEqual(commands, [.enter])
    }

    func testMissingAXAndMenuActionsAreUnavailable() {
        let result = FullscreenEntry.run(
            setFullscreen: { false },
            readFullscreen: { false },
            confirm: { _ in false },
            performMenu: { _ in false }
        )

        XCTAssertEqual(result, .unavailable)
    }

    func testUnsupportedAXWithUnknownStateAndNoEnterMenuIsUnavailable() {
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            setFullscreen: { false },
            readFullscreen: { nil },
            confirm: { _ in false },
            performMenu: { commands.append($0); return false }
        )

        XCTAssertEqual(result, .unavailable)
        XCTAssertEqual(commands, [.enter], "an unknown state still prevents using Toggle Full Screen")
    }

    func testAXFullscreenBecomingTrueBeforeToggleWaitsForWindowServer() {
        var reads = 0
        var timedConfirmations = 0
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            setFullscreen: { true },
            readFullscreen: {
                reads += 1
                return reads == 2
            },
            confirm: { timeout in
                guard timeout == 5 else { return false }
                timedConfirmations += 1
                return timedConfirmations == 2
            },
            performMenu: { commands.append($0); return false }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertEqual(commands, [.enter], "a late AX transition must be confirmed without toggling it back out")
    }

    func testAlreadyFullscreenSkipsPreparation() {
        var prepared = false
        var setCalled = false
        var menuCalled = false
        let result = FullscreenEntry.run(
            prepareWindow: { prepared = true; return true },
            setFullscreen: { setCalled = true; return true },
            readFullscreen: { XCTFail("confirmed fullscreen must not read AX state"); return true },
            confirm: { timeout in XCTAssertEqual(timeout, 0); return true },
            performMenu: { _ in menuCalled = true; return true }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertFalse(prepared, "already-confirmed fullscreen should never prepare")
        XCTAssertFalse(setCalled, "already-confirmed fullscreen should not send requests")
        XCTAssertFalse(menuCalled, "already-confirmed fullscreen should not send menu commands")
    }

    func testFailedPreparationReturnsNotFocused() {
        var setCalled = false
        var readCalled = false
        var menuCalled = false
        var confirmations: [TimeInterval] = []
        let result = FullscreenEntry.run(
            prepareWindow: { false },
            setFullscreen: { setCalled = true; return true },
            readFullscreen: { readCalled = true; return nil },
            confirm: { timeout in confirmations.append(timeout); return false },
            performMenu: { _ in menuCalled = true; return true }
        )

        XCTAssertEqual(result, .notFocused)
        XCTAssertFalse(setCalled, "failed preparation should not call setter")
        XCTAssertFalse(readCalled, "failed preparation should not read state")
        XCTAssertFalse(menuCalled, "failed preparation should not call menu")
        XCTAssertEqual(confirmations, [0], "only the initial confirmation may run before preparation")
    }

    func testPreparationPrecedesSetter() {
        var order: [String] = []
        var requested = false
        let result = FullscreenEntry.run(
            prepareWindow: { order.append("prepare"); return true },
            setFullscreen: { order.append("set"); requested = true; return true },
            readFullscreen: { false },
            confirm: { timeout in
                order.append("confirm(\(timeout))")
                return requested
            },
            performMenu: { _ in XCTFail("confirmed AX request must not use a menu"); return false }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertEqual(order, ["confirm(0.0)", "prepare", "set", "confirm(5.0)"])
    }
}
#endif
