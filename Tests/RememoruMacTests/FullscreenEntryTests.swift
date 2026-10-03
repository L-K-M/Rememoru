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
}
#endif
