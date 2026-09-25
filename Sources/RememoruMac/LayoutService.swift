#if os(macOS)
import AppKit
import CoreGraphics
import RememoruCore

/// What the app and the command line use: capture, restore, diagnostics.
public final class LayoutService {
    public let store: SnapshotStore
    public let logFile: LogFile

    public init(store: SnapshotStore, logFile: LogFile = .standard()) {
        self.store = store
        self.logFile = logFile
    }

    public func captureSnapshot() -> Snapshot {
        let state = LiveReader().read()
        return SnapshotBuilder.build(from: state, created: SnapshotStore.timestamp())
    }

    /// Runs a restore synchronously; call it off the main thread. `echo`
    /// receives every log line (also written to the log file).
    public func restore(
        _ snapshot: Snapshot,
        options: RestoreOptions = RestoreOptions(),
        mode: RestoreMode = .apply,
        cancellation: CancellationFlag = CancellationFlag(),
        echo: @escaping (String) -> Void = { _ in },
        progress: @escaping (String) -> Void = { _ in }
    ) -> RestoreReport {
        let logFile = self.logFile
        let log: (String) -> Void = { line in
            logFile.write(line)
            echo(line)
        }
        log("restore \(mode == .dryRun ? "(dry run) " : "")of snapshot from \(snapshot.created)")
        return Restorer(
            snapshot: snapshot, options: options, mode: mode, cancellation: cancellation,
            log: log, progress: progress
        ).run()
    }

    public func liveState() -> LiveState {
        LiveReader().read()
    }

    // MARK: - Diagnostics

    public struct Check {
        public var name: String
        public var ok: Bool
        public var detail: String
    }

    public static func checks() -> [Check] {
        var checks: [Check] = [
            Check(name: "Accessibility", ok: Permissions.isGranted(.accessibility),
                  detail: "required to move, resize and fullscreen windows"),
            Check(name: "Screen Recording", ok: Permissions.isGranted(.screenRecording),
                  detail: "optional; titles of windows on other Spaces are read through it"),
            Check(name: "Displays have separate Spaces", ok: separateSpaces,
                  detail: "System Settings > Desktop & Dock"),
            Check(name: "display UUIDs (CGDisplayCreateUUIDFromDisplayID)", ok: Displays.canReadUUIDs,
                  detail: "else displays are matched by enumeration order"),
            Check(name: "window moves (SLSBridgedMoveWindowsToManagedSpaceOperation)",
                  ok: BridgedOperations.canMoveWindows, detail: "needed to put windows on their desktops"),
            Check(name: "space order (SLSBridgedMoveManagedSpaceToDisplayIndexOperation)",
                  ok: BridgedOperations.canMoveSpaces, detail: "needed to reorder fullscreen spaces"),
            Check(name: "_AXUIElementGetWindow", ok: HIServicesPrivate.getWindow != nil,
                  detail: "ties accessibility elements to window ids"),
            Check(name: "_AXUIElementCreateWithRemoteToken", ok: HIServicesPrivate.createWithRemoteToken != nil,
                  detail: "reaches windows on other Spaces"),
        ]
        for (name, ok) in SkyLight.availability {
            checks.append(Check(name: name, ok: ok, detail: "SkyLight"))
        }
        return checks
    }

    /// "Displays have separate Spaces" is stored inverted as spans-displays.
    static var separateSpaces: Bool {
        !(UserDefaults(suiteName: "com.apple.spaces")?.bool(forKey: "spans-displays") ?? false)
    }

    /// Raw WindowServer data for bug reports.
    public static func dump() -> [String: Any] {
        let managed = SkyLight.managedDisplaySpaces()
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let windows = WindowFilter.candidates(from: info).map { window -> [String: Any] in
            [
                "id": window.id, "pid": window.pid, "app": window.appName, "title": window.title,
                "frame": ["x": window.frame.x, "y": window.frame.y, "w": window.frame.w, "h": window.frame.h],
                "onscreen": window.isOnscreen,
                "spaces": SkyLight.spaces(ofWindow: window.id).map { NSNumber(value: $0) },
            ]
        }
        let displays = Displays.activeDisplayIDs().map { id -> [String: Any] in
            let bounds = CGDisplayBounds(id)
            return [
                "id": id, "uuid": Displays.uuid(of: id).map { $0 as Any } ?? NSNull(), "main": id == CGMainDisplayID(),
                "frame": ["x": bounds.origin.x, "y": bounds.origin.y, "w": bounds.width, "h": bounds.height],
            ]
        }
        return ["managedDisplaySpaces": managed, "displays": displays, "windows": windows]
    }

    /// Mission Control's accessibility tree, one line per element.
    public static func missionControlTree() -> [String] {
        guard let group = MissionControl.open() else { return ["could not open Mission Control"] }
        defer { MissionControl.close() }
        var lines: [String] = []
        func walk(_ element: AXElement, depth: Int) {
            guard depth < 12, lines.count < 2000 else { return }
            var line = String(repeating: "  ", count: depth) + (element.role ?? "?")
            if let identifier = element.identifier { line += " id=\(identifier)" }
            if let title = element.title, !title.isEmpty { line += " title=\u{201C}\(title)\u{201D}" }
            if let display = element.value("AXDisplayID") as? NSNumber { line += " display=\(display)" }
            if let frame = element.frame {
                line += String(format: " (%.0f, %.0f) %.0f x %.0f", frame.x, frame.y, frame.w, frame.h)
            }
            lines.append(line)
            for child in element.children { walk(child, depth: depth + 1) }
        }
        walk(group, depth: 0)
        return lines
    }
}
#endif
