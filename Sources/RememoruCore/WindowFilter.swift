import Foundation

/// Turns `CGWindowListCopyWindowInfo` dictionaries into layout-relevant
/// windows: normal-layer, visible-sized windows of real apps.
public enum WindowFilter {
    /// Processes that own system UI windows we never track.
    public static let ownerBlocklist: Set<String> = [
        "Dock", "WindowServer", "Window Server", "Window Manager", "WindowManager",
        "ControlCenter", "Control Center", "SystemUIServer", "Spotlight",
        "NotificationCenter", "Notification Center", "loginwindow",
        "ScreenSaverEngine", "TextInputMenuAgent", "TextInputSwitcher",
        "UIKitSystem", "CursorUIViewService", "Accessibility Visuals Agent",
        "Wallpaper", "Rememoru",
    ]

    /// Smaller windows are helper surfaces (tooltips, drop targets, status
    /// windows), not something a user arranges.
    public static let minimumSide = 40.0

    public static func candidates(from info: [[String: Any]]) -> [LiveWindow] {
        info.compactMap(candidate)
    }

    static func candidate(_ entry: [String: Any]) -> LiveWindow? {
        guard let id = uint32(entry["kCGWindowNumber"]),
              let pid = int(entry["kCGWindowOwnerPID"]) else { return nil }
        let owner = entry["kCGWindowOwnerName"] as? String ?? ""
        guard !ownerBlocklist.contains(owner) else { return nil }
        guard (int(entry["kCGWindowLayer"]) ?? 0) == 0 else { return nil }
        guard (double(entry["kCGWindowAlpha"]) ?? 1) > 0 else { return nil }

        let bounds = entry["kCGWindowBounds"] as? [String: Any] ?? [:]
        let frame = Rect(
            x: double(bounds["X"]) ?? 0,
            y: double(bounds["Y"]) ?? 0,
            w: double(bounds["Width"]) ?? 0,
            h: double(bounds["Height"]) ?? 0
        )
        guard frame.w >= minimumSide, frame.h >= minimumSide else { return nil }

        return LiveWindow(
            id: id,
            pid: Int32(truncatingIfNeeded: pid),
            appName: owner,
            title: entry["kCGWindowName"] as? String ?? "",
            frame: frame,
            isOnscreen: (entry["kCGWindowIsOnscreen"] as? Bool) ?? (int(entry["kCGWindowIsOnscreen"]) == 1)
        )
    }
}
