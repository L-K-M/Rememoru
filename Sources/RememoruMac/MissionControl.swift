#if os(macOS)
import AppKit
import ApplicationServices
import Foundation

/// Mission Control's AX tree lives under Dock > "mc" on macOS 15/26,
/// and directly under WindowManager on macOS 27. Both expose "mc.display"
/// (by AXDisplayID) > "mc.spaces" > "mc.spaces.add" / "mc.spaces.list".
enum MissionControl {
    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int32) -> Int32
    private static let sendNotification: CoreDockSendNotificationFn? = {
        _ = HIServicesPrivate.library.isLoaded
        guard let handle = dlopen(nil, RTLD_LAZY), let address = dlsym(handle, "CoreDockSendNotification")
        else { return nil }
        return unsafeBitCast(address, to: CoreDockSendNotificationFn.self)
    }()

    enum Observation<Node> {
        case unavailable
        case closed
        case open(Node)

        var group: Node? {
            if case .open(let group) = self { return group }
            return nil
        }

        var isOpen: Bool? {
            switch self {
            case .unavailable: return nil
            case .closed: return false
            case .open: return true
            }
        }
    }

    static func observe<Node>(
        hosts: [Node], children: (Node) -> [Node]?, identifier: (Node) -> String?
    ) -> Observation<Node> {
        var allReadable = !hosts.isEmpty
        for host in hosts {
            guard let children = children(host) else { allReadable = false; continue }
            if let group = children.first(where: { identifier($0) == "mc" }) { return .open(group) }
            if children.contains(where: { identifier($0) == "mc.display" }) { return .open(host) }
        }
        return allReadable ? .closed : .unavailable
    }

    private static var observation: Observation<AXElement> {
        var seen = Set<pid_t>()
        let hosts = ["com.apple.WindowManager", "com.apple.dock"].flatMap {
            NSRunningApplication.runningApplications(withBundleIdentifier: $0)
        }.filter { seen.insert($0.processIdentifier).inserted }.map {
            AXElement.application($0.processIdentifier)
        }
        return observe(hosts: hosts, children: { $0.elementsIfAvailable(kAXChildrenAttribute) },
                       identifier: { $0.identifier })
    }

    /// The host or wrapper containing the visible display groups.
    static var group: AXElement? {
        observation.group
    }

    static var isOpen: Bool { group != nil }

    /// An unreadable candidate host must not look like confirmed closure.
    private static var openState: Bool? {
        observation.isOpen
    }

    /// Opens Mission Control and waits for its accessibility tree.
    static func open(timeout: TimeInterval = 3) -> AXElement? {
        openIfNeeded(readState: { observation }, show: toggle,
                     waitForGroup: { wait(timeout: timeout) { group } })
    }

    static func openIfNeeded<Node>(
        readState: () -> Observation<Node>, show: () -> Void, waitForGroup: () -> Node?
    ) -> Node? {
        switch readState() {
        case .open(let group): return group
        case .unavailable: return nil
        case .closed:
            show()
            return waitForGroup()
        }
    }

    @discardableResult
    static func close(canContinue: () -> Bool = { true }) -> Bool {
        closeIfNeeded(
            isOpen: { openState }, dismiss: toggle, canContinue: canContinue,
            waitUntilClosed: {
                wait(timeout: 2) {
                    closureConfirmation(isOpen: { openState }, canContinue: canContinue)
                } == true
            }
        )
    }

    /// A toggle is safe only after confirming Mission Control is open.
    /// Keep the confirmation boundary injectable without posting UI events.
    static func closeIfNeeded(
        isOpen: () -> Bool?, dismiss: () -> Void, canContinue: () -> Bool,
        waitUntilClosed: () -> Bool
    ) -> Bool {
        guard canContinue(), let open = isOpen() else { return false }
        guard open else { return canContinue() }
        guard canContinue() else { return false }
        dismiss()
        guard canContinue() else { return false }
        return waitUntilClosed() && canContinue()
    }

    static func closureConfirmation(isOpen: () -> Bool?, canContinue: () -> Bool) -> Bool? {
        guard canContinue() else { return false }
        // Dismissal can briefly invalidate Dock's AX tree. Keep waiting
        // within the closing deadline until absence is confirmed.
        guard let open = isOpen() else { return nil }
        return open ? nil : true
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

    /// Resolves the target's current index after Mission Control opens,
    /// since a fullscreen transition may have changed the thumbnail order.
    static func showSpace(display: CGDirectDisplayID, index: () -> Int?) -> Bool {
        guard open() != nil else { return false }
        defer { close() }
        // Dock publishes its AX tree before thumbnail actions are ready.
        // hs.spaces.gotoSpace likewise waits for the opening animation.
        Thread.sleep(forTimeInterval: 0.3)
        guard let button = wait(timeout: 2, { () -> AXElement? in
            let buttons = spaceButtons(display: display)
            guard let index = index(), buttons.indices.contains(index) else { return nil }
            return buttons[index]
        }), button.perform(kAXPressAction) else { return false }
        return wait(timeout: 2) {
            closureConfirmation(isOpen: { openState }, canContinue: { true })
        } == true
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
