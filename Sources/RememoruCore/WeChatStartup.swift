import Foundation

/// WeChat can be running with only its account startup panel open.
public enum WeChatStartup {
    public static let bundleID = "com.tencent.xinWeChat"

    public static func shouldPrepare(snapshot: Snapshot, options: RestoreOptions, mode: RestoreMode) -> Bool {
        mode == .apply && options.launchApps && snapshot.windows.contains { $0.bundleID == bundleID }
    }

    /// Match a specific action, never account switching or phone approval.
    public static func isOpenButton(isButton: Bool, labels: [String]) -> Bool {
        isButton && labels.contains("Open WeChat")
    }

    public static func isMainWindow(
        isStandardWindow: Bool, isFullscreen: Bool, hasMinimizeButton: Bool, isZoomEnabled: Bool
    ) -> Bool {
        // The account startup panel can expose an enabled minimize control,
        // but its zoom control is disabled, including while content loads.
        isStandardWindow && (isFullscreen || (hasMinimizeButton && isZoomEnabled))
    }

    public static func canClickOpenButton(
        isButton: Bool, labels: [String], isEnabled: Bool, isFrontmost: Bool,
        isWindowOnscreen: Bool, hitMatchesButton: Bool
    ) -> Bool {
        isOpenButton(isButton: isButton, labels: labels) && isEnabled
            && isFrontmost && isWindowOnscreen && hitMatchesButton
    }
}
