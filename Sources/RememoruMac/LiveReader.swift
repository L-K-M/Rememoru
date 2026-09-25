#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import RememoruCore

/// Reads the live display / space / window state from WindowServer, with
/// AX filling in what CoreGraphics cannot see (titles without Screen
/// Recording, minimized state).
final class LiveReader {
    let elements = WindowElements()
    private(set) var managed = ManagedSpaces(spaces: [], tileParents: [:], tileWindowSpaces: [:])

    func read(withTitles: Bool = true) -> LiveState {
        managed = SkyLight.managedSpaces()
        let skyLightOrder = SkyLight.managedDisplaySpaces().compactMap { $0["Display Identifier"] as? String }
        let displays = Displays.current(skyLightOrder: skyLightOrder)

        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        var windows = WindowFilter.candidates(from: info)

        var apps: [pid_t: NSRunningApplication] = [:]
        windows = windows.filter { window in
            let app = apps[window.pid] ?? NSRunningApplication(processIdentifier: window.pid)
            apps[window.pid] = app
            // background-only processes (renderers, services) own helper
            // windows nobody arranges
            return app != nil && app?.activationPolicy != .prohibited
        }

        let trusted = AXIsProcessTrusted()
        elements.invalidate()
        for index in windows.indices {
            let window = windows[index]
            windows[index].bundleID = apps[window.pid]?.bundleIdentifier
            windows[index].spaceID = managed.resolveSpace(
                windowID: window.id, reported: SkyLight.spaces(ofWindow: window.id)
            )
        }
        guard trusted else { return LiveState(displays: displays, spaces: managed.spaces, windows: windows) }

        // AX pass: minimized flags for every window, titles when CG gave
        // none (it only reports titles with Screen Recording granted)
        let byPID = Dictionary(grouping: windows.indices, by: { windows[$0].pid })
        for (pid, indices) in byPID {
            let listed = elements.listed(pid: pid)
            var wanted = Set<UInt32>()
            for index in indices {
                let id = windows[index].id
                if let element = listed[id] {
                    windows[index].isMinimized = element.bool(kAXMinimizedAttribute) ?? false
                    if windows[index].title.isEmpty { windows[index].title = element.title ?? "" }
                } else if withTitles && windows[index].title.isEmpty && windows[index].spaceID != nil {
                    wanted.insert(id)
                }
            }
            guard !wanted.isEmpty else { continue }
            let found = elements.elements(for: wanted, pid: pid)
            for index in indices {
                if let element = found[windows[index].id] {
                    windows[index].title = element.title ?? ""
                }
            }
        }
        return LiveState(displays: displays, spaces: managed.spaces, windows: windows)
    }

    /// Bounds of one window straight from WindowServer; works for windows
    /// on any Space, so it verifies frame changes AX cannot see.
    static func bounds(ofWindow id: UInt32) -> Rect? {
        guard let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], CGWindowID(id))
            as? [[String: Any]], let entry = info.first,
            let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
            let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary) else { return nil }
        return Rect(rect)
    }
}
#endif
