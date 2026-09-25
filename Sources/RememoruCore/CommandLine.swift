import Foundation

/// Command-line mode of the Rememoru executable. Running
/// `Rememoru.app/Contents/MacOS/Rememoru <command>` performs one command
/// and exits; launching without a command starts the menu bar app.
public enum CLICommand: Equatable {
    case help
    case version
    case doctor
    case list
    case dump
    case inspectMissionControl
    case snapshot(output: String?)
    case restore(path: String?, mode: RestoreMode, options: RestoreOptions)
}

public enum RestoreMode: Equatable, Sendable {
    case apply
    /// Print the plan, change nothing.
    case dryRun
}

public struct CLIError: Error, Equatable, CustomStringConvertible {
    public var description: String
}

public enum CLIParser {
    public static let usage = """
    usage: Rememoru <command> [options]

    Without a command, Rememoru starts as a menu bar app.

    commands:
      doctor                 check permissions and private API availability
      list                   show displays, spaces and windows
      snapshot [-o FILE]     save the current layout (default: app snapshot folder)
      restore [FILE]         restore FILE (default: the newest saved layout)
          --dry-run              print the plan, change nothing
          --launch               open apps that have saved windows but are not running
          --no-create-desktops   do not add missing desktops
          --no-fullscreen        do not recreate fullscreen windows
          --no-split             do not recreate Split View pairs
          --no-arrange           do not reorder spaces to the saved order
          --no-focus             do not switch to the saved active spaces
          --fallback-main-display
                                 put windows of missing displays on the main display
      dump                   raw SkyLight / CoreGraphics data for bug reports
      inspect-mc             dump the Mission Control accessibility tree
      help, version
    """

    /// Returns nil when the arguments are not a command (a plain app
    /// launch, or flags LaunchServices and Xcode add such as `-psn_…`).
    public static func parse(_ arguments: [String]) throws -> CLICommand? {
        guard let command = arguments.first else { return nil }
        let rest = Array(arguments.dropFirst())
        switch command {
        case "help", "-h", "--help":
            return .help
        case "version", "--version":
            return .version
        case "doctor":
            try expectNoArguments(rest, command)
            return .doctor
        case "list":
            try expectNoArguments(rest, command)
            return .list
        case "dump":
            try expectNoArguments(rest, command)
            return .dump
        case "inspect-mc":
            try expectNoArguments(rest, command)
            return .inspectMissionControl
        case "snapshot":
            return try parseSnapshot(rest)
        case "restore":
            return try parseRestore(rest)
        default:
            return nil
        }
    }

    private static func expectNoArguments(_ rest: [String], _ command: String) throws {
        if let extra = rest.first {
            throw CLIError(description: "\(command): unexpected argument \(extra)")
        }
    }

    private static func parseSnapshot(_ rest: [String]) throws -> CLICommand {
        var output: String?
        var iterator = rest.makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "-o", "--output":
                guard let path = iterator.next() else {
                    throw CLIError(description: "snapshot: \(argument) needs a file path")
                }
                output = path
            default:
                throw CLIError(description: "snapshot: unknown option \(argument)")
            }
        }
        return .snapshot(output: output)
    }

    private static func parseRestore(_ rest: [String]) throws -> CLICommand {
        var path: String?
        var mode = RestoreMode.apply
        var options = RestoreOptions()
        for argument in rest {
            switch argument {
            case "--dry-run": mode = .dryRun
            case "--launch": options.launchApps = true
            case "--no-create-desktops": options.createDesktops = false
            case "--no-fullscreen": options.fullscreen = false
            case "--no-split": options.splitView = false
            case "--no-arrange": options.arrangeSpaces = false
            case "--no-focus": options.focus = false
            case "--fallback-main-display": options.displayFallback = .mainDisplay
            default:
                if argument.hasPrefix("-") {
                    throw CLIError(description: "restore: unknown option \(argument)")
                }
                guard path == nil else {
                    throw CLIError(description: "restore: only one snapshot file, got \(argument) too")
                }
                path = argument
            }
        }
        return .restore(path: path, mode: mode, options: options)
    }
}
