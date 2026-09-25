#if os(macOS)
import Foundation
import RememoruCore
import RememoruMac

/// Command-line mode. Note that permissions then belong to whatever
/// launched the binary (Terminal, iTerm, ...), not to Rememoru.app.
struct CommandRunner {
    private enum ExitCode {
        static let ok: Int32 = 0
        static let partial: Int32 = 1
        static let failure: Int32 = 2
    }

    func run(_ command: CLICommand) -> Int32 {
        switch command {
        case .help:
            print(CLIParser.usage)
            return ExitCode.ok
        case .version:
            print("Rememoru \(AppInfo.version)")
            return ExitCode.ok
        case .doctor:
            return doctor()
        case .list:
            return list()
        case .dump:
            return dump()
        case .inspectMissionControl:
            LayoutService.missionControlTree().forEach { print($0) }
            return ExitCode.ok
        case .snapshot(let output):
            return snapshot(output: output)
        case .restore(let path, let mode, let options):
            return restore(path: path, mode: mode, options: options)
        }
    }

    private func service() throws -> LayoutService {
        LayoutService(store: try SnapshotStore.standard())
    }

    private func doctor() -> Int32 {
        print("Rememoru \(AppInfo.version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)\n")
        let checks = LayoutService.checks()
        for check in checks {
            print("\(check.ok ? "ok     " : "MISSING") \(check.name) (\(check.detail))")
        }
        print("\nIn command-line mode the permissions checked are those of the app that started this")
        print("process. Rememoru.app has its own entries in System Settings > Privacy & Security.")
        return checks.first { $0.name == "Accessibility" }?.ok == true ? ExitCode.ok : ExitCode.partial
    }

    private func list() -> Int32 {
        do {
            let state = try service().liveState()
            for display in state.displays {
                let f = display.frame
                print(String(format: "display %@%@  %.0f x %.0f at (%.0f, %.0f)",
                             String(display.uuid.prefix(8)), display.isMain ? " [main]" : "", f.w, f.h, f.x, f.y))
                for space in state.spaces(onDisplay: display.uuid) {
                    print("  \(space.isActive ? "→" : " ") \(space.index + 1). \(space.kind.displayName) (id \(space.id))")
                    for window in state.windows where window.spaceID == space.id {
                        print("       \(window.appName): \(window.title.isEmpty ? "—" : window.title)")
                    }
                }
            }
            let loose = state.windows.filter { window in !state.spaces.contains { $0.id == window.spaceID } }
            if !loose.isEmpty {
                print("not on a single space (minimized, hidden or on all desktops):")
                for window in loose {
                    print("       \(window.appName): \(window.title.isEmpty ? "—" : window.title)\(window.isMinimized ? " [minimized]" : "")")
                }
            }
            return ExitCode.ok
        } catch {
            print("error: \(error)")
            return ExitCode.failure
        }
    }

    private func dump() -> Int32 {
        let object = Self.jsonSafe(LayoutService.dump())
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
        else {
            print("error: could not serialize the dump")
            return ExitCode.failure
        }
        FileHandle.standardOutput.write(data)
        print()
        return ExitCode.ok
    }

    /// Property lists can carry types JSON cannot (data, dates).
    private static func jsonSafe(_ value: Any) -> Any {
        switch value {
        case let dictionary as [String: Any]:
            return dictionary.mapValues(jsonSafe)
        case let array as [Any]:
            return array.map(jsonSafe)
        case is String, is NSNumber, is NSNull:
            return value
        default:
            return String(describing: value)
        }
    }

    private func snapshot(output: String?) -> Int32 {
        do {
            let service = try service()
            let snapshot = service.captureSnapshot()
            let url: URL
            if let output {
                url = URL(fileURLWithPath: output)
                try snapshot.encoded().write(to: url, options: .atomic)
            } else {
                url = try service.store.save(snapshot)
            }
            print("saved \(snapshot.windows.count) window(s) on \(snapshot.spaces.count) space(s) "
                + "across \(snapshot.displays.count) display(s) to \(url.path)")
            if !Permissions.isGranted(.accessibility) && !Permissions.isGranted(.screenRecording) {
                print("note: without Accessibility or Screen Recording, window titles were not captured")
            }
            return ExitCode.ok
        } catch {
            print("error: \(error)")
            return ExitCode.failure
        }
    }

    private func restore(path: String?, mode: RestoreMode, options: RestoreOptions) -> Int32 {
        do {
            let service = try service()
            let url: URL
            if let path {
                url = URL(fileURLWithPath: path)
            } else if let latest = service.store.latest {
                url = latest.url
            } else {
                print("error: no saved layout; run `snapshot` first or pass a file")
                return ExitCode.failure
            }
            let snapshot = try service.store.load(url)
            print("restoring \(url.path)")
            let report = service.restore(snapshot, options: options, mode: mode, echo: { print($0) })
            if report.fatalError != nil { return ExitCode.failure }
            return report.isClean ? ExitCode.ok : ExitCode.partial
        } catch {
            print("error: \(error)")
            return ExitCode.failure
        }
    }
}

enum AppInfo {
    static var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "development build"
    }
}
#endif
