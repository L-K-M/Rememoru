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
            prepareMenu: { prepared = true; return true },
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

    func testFailedMenuPreparationReturnsNotFocusedAfterAXAttempt() {
        var setCalled = false
        var readCalled = false
        var menuCalled = false
        var confirmations: [TimeInterval] = []
        let result = FullscreenEntry.run(
            prepareMenu: { false },
            setFullscreen: { setCalled = true; return false },
            readFullscreen: { readCalled = true; return false },
            confirm: { timeout in confirmations.append(timeout); return false },
            performMenu: { _ in menuCalled = true; return true }
        )

        XCTAssertEqual(result, .notFocused)
        XCTAssertTrue(setCalled, "menu focus must not block the per-window AX setter")
        XCTAssertTrue(readCalled, "check for a pending AX transition before menu preparation")
        XCTAssertFalse(menuCalled, "failed preparation must prevent menu commands")
        XCTAssertTrue(confirmations.allSatisfy { $0 == 0 })
    }

    func testPreparationPrecedesMenuFallback() {
        var order: [String] = []
        var entered = false
        let result = FullscreenEntry.run(
            prepareMenu: { order.append("prepare"); return true },
            setFullscreen: { order.append("set"); return false },
            readFullscreen: { false },
            confirm: { _ in entered },
            performMenu: { _ in order.append("menu"); entered = true; return true }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertEqual(order, ["set", "prepare", "menu"])
    }

    func testConfirmedAXRequestDoesNotRequireMenuFocus() {
        var requested = false
        var preparations = 0
        let result = FullscreenEntry.run(
            prepareMenu: { preparations += 1; return false },
            setFullscreen: { requested = true; return true },
            readFullscreen: { false },
            confirm: { _ in requested },
            performMenu: { _ in XCTFail("AX success must not use a menu"); return false }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertTrue(requested)
        XCTAssertEqual(preparations, 0)
    }

    func testFailedMenuPreparationPreservesLateWindowServerSuccess() {
        var entered = false
        let result = FullscreenEntry.run(
            prepareMenu: { entered = true; return false },
            setFullscreen: { false },
            readFullscreen: { false },
            confirm: { _ in entered },
            performMenu: { _ in XCTFail("failed focus must not use a menu"); return false }
        )

        XCTAssertEqual(result, .entered)
    }

    func testLateAXTransitionDuringTogglePreparationDoesNotToggleBackOut() {
        var fullscreen = false
        var preparations = 0
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            prepareMenu: {
                preparations += 1
                fullscreen = preparations == 2
                return true
            },
            setFullscreen: { false },
            readFullscreen: { fullscreen },
            confirm: { timeout in timeout > 0 && fullscreen },
            performMenu: { commands.append($0); return false }
        )

        XCTAssertEqual(result, .entered)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(commands, [.enter])
    }

    func testUnknownAXStateAfterTogglePreparationPreventsToggle() {
        var fullscreen: Bool? = false
        var preparations = 0
        var commands: [FullscreenEntry.MenuCommand] = []
        let result = FullscreenEntry.run(
            prepareMenu: {
                preparations += 1
                if preparations == 2 { fullscreen = nil }
                return true
            },
            setFullscreen: { false },
            readFullscreen: { fullscreen },
            confirm: { _ in false },
            performMenu: { commands.append($0); return false }
        )

        XCTAssertEqual(result, .notConfirmed)
        XCTAssertEqual(preparations, 2)
        XCTAssertEqual(commands, [.enter])
    }
}
#endif
