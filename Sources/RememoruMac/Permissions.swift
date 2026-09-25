#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics

/// The two privacy grants Rememoru uses. Both belong to Rememoru.app
/// itself (its bundle id and signature), not to a terminal or python3.
public enum Permissions {
    public enum Kind: CaseIterable {
        /// Required to move, resize and fullscreen other apps' windows and
        /// to drive Mission Control.
        case accessibility
        /// Needed to read window titles, which makes matching precise.
        case screenRecording

        public var title: String {
            switch self {
            case .accessibility: return "Accessibility"
            case .screenRecording: return "Screen Recording"
            }
        }

        var settingsURL: URL {
            switch self {
            case .accessibility:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .screenRecording:
                return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
            }
        }
    }

    public static func isGranted(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility: return AXIsProcessTrusted()
        case .screenRecording: return CGPreflightScreenCaptureAccess()
        }
    }

    /// Shows the system prompt. macOS only shows it the first time for a
    /// given app; afterwards this just returns the current state, which is
    /// why callers also offer to open the settings pane.
    @discardableResult
    public static func request(_ kind: Kind) -> Bool {
        switch kind {
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            return AXIsProcessTrustedWithOptions(options)
        case .screenRecording:
            return CGRequestScreenCaptureAccess()
        }
    }

    public static func openSettings(_ kind: Kind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }
}
#endif
