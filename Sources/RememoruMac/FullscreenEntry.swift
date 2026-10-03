#if os(macOS)
import Foundation

/// Coordinates fullscreen requests with WindowServer confirmation.
enum FullscreenEntry {
    enum MenuCommand: String {
        case enter = "Enter Full Screen"
        case toggle = "Toggle Full Screen"
    }

    enum Result: Equatable {
        case entered
        case unavailable
        case notConfirmed
    }

    static func run(
        setFullscreen: () -> Bool,
        readFullscreen: () -> Bool?,
        confirm: (TimeInterval) -> Bool,
        performMenu: (MenuCommand) -> Bool
    ) -> Result {
        if confirm(0) { return .entered }
        let accepted = setFullscreen()
        if accepted, confirm(5) { return .entered }

        // Some apps accept AXFullScreen without acting on it. Check both
        // sources again before falling back: a delayed transition must not
        // be reversed by a Toggle Full Screen command.
        if confirm(0) { return .entered }
        if readFullscreen() == true {
            return confirm(5) ? .entered : .notConfirmed
        }
        if performMenu(.enter) {
            return confirm(5) ? .entered : .notConfirmed
        }
        if confirm(0) { return .entered }
        guard let fullscreen = readFullscreen() else { return accepted ? .notConfirmed : .unavailable }
        guard !fullscreen else { return confirm(5) ? .entered : .notConfirmed }
        guard performMenu(.toggle) else { return accepted ? .notConfirmed : .unavailable }
        return confirm(5) ? .entered : .notConfirmed
    }
}
#endif
