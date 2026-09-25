#if os(macOS)
import AppKit
import RememoruCore

// `Rememoru <command>` runs one command and exits (see CLIParser.usage);
// a plain launch starts the menu bar app.
do {
    if let command = try CLIParser.parse(Array(CommandLine.arguments.dropFirst())) {
        exit(CommandRunner().run(command))
    }
} catch {
    FileHandle.standardError.write(Data("\(error)\n\n\(CLIParser.usage)\n".utf8))
    exit(64)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
#else
print("Rememoru only runs on macOS.")
#endif
