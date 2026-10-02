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
}
