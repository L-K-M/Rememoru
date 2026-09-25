#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Mission Control automation through the Dock's accessibility tree
/// (macOS 15/26): Dock > "mc" > "mc.display" (by AXDisplayID) > "mc.spaces"
/// > "mc.spaces.add" / "mc.spaces.list". Same path as Hammerspoon's
/// hs.spaces. macOS 27 is reported to move this tree to WindowManager.
enum MissionControl {
    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int32) -> Int32
    private static let sendNotification: CoreDockSendNotificationFn? = {
        _ = HIServicesPrivate.library.isLoaded
        guard let handle = dlopen(nil, RTLD_LAZY), let address = dlsym(handle, "CoreDockSendNotification")
        else { return nil }
        return unsafeBitCast(address, to: CoreDockSendNotificationFn.self)
    }()

    static var dock: AXElement? {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
        else { return nil }
        return AXElement.application(app.processIdentifier)
    }

    /// The "mc" group, present only while Mission Control is shown.
    static var group: AXElement? {
        dock?.children.first { $0.identifier == "mc" }
    }

    static var isOpen: Bool { group != nil }

    /// Opens Mission Control and waits for its accessibility tree.
    static func open(timeout: TimeInterval = 3) -> AXElement? {
        if let group { return group }
        toggle()
        return wait(timeout: timeout) { group }
    }

    static func close() {
        guard isOpen else { return }
        toggle()
        _ = wait(timeout: 2) { isOpen ? nil : true }
    }

    private static func toggle() {
        if let sendNotification {
            _ = sendNotification("com.apple.expose.awake" as CFString, 0)
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Mission Control"]
        try? process.run()
        process.waitUntilExit()
    }

    /// "mc.spaces" of one display. Mission Control must be open.
    static func spacesGroup(display: CGDirectDisplayID) -> AXElement? {
        guard let group else { return nil }
        let displayGroup = group.children.first {
            $0.identifier == "mc.display"
                && ($0.value("AXDisplayID") as? NSNumber)?.uint32Value == display
        }
        return displayGroup?.children.first { $0.identifier == "mc.spaces" }
    }

    /// Space thumbnails of a display, in Mission Control order.
    static func spaceButtons(display: CGDirectDisplayID) -> [AXElement] {
        spacesGroup(display: display)?.children.first { $0.identifier == "mc.spaces.list" }?.children ?? []
    }

    static func addButton(display: CGDirectDisplayID) -> AXElement? {
        spacesGroup(display: display)?.children.first { $0.identifier == "mc.spaces.add" }
    }

    /// Adds `count` desktops to a display. Returns how many were confirmed
    /// by `desktopCount` rising.
    static func addDesktops(
        display: CGDirectDisplayID, count: Int, desktopCount: () -> Int, log: (String) -> Void
    ) -> Int {
        guard open() != nil else {
            log("could not open Mission Control")
            return 0
        }
        defer { close() }
        var added = 0
        for _ in 0..<count {
            let before = desktopCount()
            guard let button = wait(timeout: 2, { addButton(display: display) }) else {
                log("Mission Control shows no add-desktop button for display \(display)")
                break
            }
            guard button.perform(kAXPressAction) else {
                log("pressing the add-desktop button failed")
                break
            }
            guard wait(timeout: 3, { desktopCount() > before ? true : nil }) != nil else {
                log("a desktop was requested but did not appear")
                break
            }
            added += 1
        }
        return added
    }

    /// Switches a display to the space at `index` by clicking its thumbnail.
    static func showSpace(display: CGDirectDisplayID, index: Int) -> Bool {
        guard open() != nil else { return false }
        let buttons = wait(timeout: 2) { () -> [AXElement]? in
            let buttons = spaceButtons(display: display)
            return buttons.isEmpty ? nil : buttons
        } ?? []
        guard index < buttons.count, buttons[index].perform(kAXPressAction) else {
            close()
            return false
        }
        _ = wait(timeout: 2) { isOpen ? nil : true }
        return true
    }

    /// Polls `probe` until it returns a value or the timeout passes.
    static func wait<T>(timeout: TimeInterval, interval: TimeInterval = 0.1, _ probe: () -> T?) -> T? {
        let deadline = Date().addingTimeInterval(timeout)
        while true {
            if let value = probe() { return value }
            if Date() >= deadline { return nil }
            Thread.sleep(forTimeInterval: interval)
        }
    }
}
#endif
