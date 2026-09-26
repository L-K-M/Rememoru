#if os(macOS)
import AppKit
import RememoruCore
import RememoruMac

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private let preferences = Preferences()
    private var service: LayoutService?
    private let queue = DispatchQueue(label: "Rememoru.restore", qos: .userInitiated)

    /// Non-nil while a restore runs.
    private var cancellation: CancellationFlag?
    private var status: String?
    private var lastResult: String?
    /// True while a capture runs; it can take seconds (one AX round trip
    /// per app, more for windows on other Spaces), so it runs on `queue`.
    private var saving = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                           accessibilityDescription: "Rememoru")
        menu.delegate = self
        statusItem.menu = menu

        do {
            service = LayoutService(store: try SnapshotStore.standard())
        } catch {
            lastResult = "Cannot open the snapshot folder: \(error.localizedDescription)"
        }

        if !preferences.onboardingShown {
            preferences.onboardingShown = true
            showOnboarding()
        } else if preferences.restoreAtLogin, Session.startedNearLogin() {
            scheduleLoginRestore()
        }
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let running = cancellation != nil || saving
        let snapshots = service?.store.list() ?? []

        let save = item("Save Current Layout", #selector(saveLayout), key: "s")
        save.isEnabled = !running && service != nil
        menu.addItem(save)

        let restoreLatest = item("Restore Latest Layout", #selector(restoreLatest), key: "r")
        restoreLatest.isEnabled = !running && !snapshots.isEmpty
        menu.addItem(restoreLatest)

        let restoreMenu = NSMenu()
        for entry in snapshots.prefix(15) {
            let entryItem = item(Self.label(for: entry), #selector(restoreChosen(_:)))
            entryItem.representedObject = entry.url
            entryItem.isEnabled = !running
            restoreMenu.addItem(entryItem)
        }
        if snapshots.isEmpty {
            restoreMenu.addItem(disabled("No saved layouts"))
        }
        let restoreSubmenu = NSMenuItem(title: "Restore", action: nil, keyEquivalent: "")
        restoreSubmenu.submenu = restoreMenu
        menu.addItem(restoreSubmenu)

        if cancellation != nil {
            menu.addItem(.separator())
            menu.addItem(disabled(status ?? "Restoring…"))
            menu.addItem(item("Cancel Restore", #selector(cancelRestore)))
        } else if let lastResult {
            menu.addItem(.separator())
            menu.addItem(disabled(lastResult))
        }

        menu.addItem(.separator())
        let atLogin = item("Restore Latest Layout at Login", #selector(toggleRestoreAtLogin))
        atLogin.state = preferences.restoreAtLogin && LoginItem.isEnabled ? .on : .off
        menu.addItem(atLogin)
        let delayMenu = NSMenu()
        for seconds in Preferences.loginDelayChoices {
            let choice = item("\(seconds) seconds", #selector(chooseLoginDelay(_:)))
            choice.tag = seconds
            choice.state = preferences.loginDelay == seconds ? .on : .off
            delayMenu.addItem(choice)
        }
        let delayItem = NSMenuItem(title: "Wait After Login", action: nil, keyEquivalent: "")
        delayItem.submenu = delayMenu
        menu.addItem(delayItem)
        let launch = item("Open Apps That Aren\u{2019}t Running", #selector(toggleLaunchApps))
        launch.state = preferences.launchApps ? .on : .off
        menu.addItem(launch)

        menu.addItem(.separator())
        for kind in Permissions.Kind.allCases {
            if Permissions.isGranted(kind) {
                menu.addItem(disabled("\(kind.title): granted"))
            } else {
                let grant = item("Grant \(kind.title)…", #selector(grantPermission(_:)))
                grant.representedObject = kind == .accessibility ? "accessibility" : "screenRecording"
                menu.addItem(grant)
            }
        }

        menu.addItem(.separator())
        menu.addItem(item("Open Snapshots Folder", #selector(openSnapshotsFolder)))
        menu.addItem(item("Show Log", #selector(showLog)))
        menu.addItem(.separator())
        menu.addItem(item("Quit Rememoru", #selector(NSApplication.terminate(_:)), key: "q"))
    }

    private func item(_ title: String, _ action: Selector, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        if action == #selector(NSApplication.terminate(_:)) {
            item.target = NSApp
        } else {
            item.target = self
        }
        return item
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private static func label(for entry: SnapshotStore.Entry) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: entry.date)
    }

    // MARK: - Actions

    @objc private func saveLayout() {
        guard let service else { return }
        if !Permissions.isGranted(.accessibility) && !Permissions.isGranted(.screenRecording) {
            alert("Window titles need a permission",
                  "Without Accessibility or Screen Recording, Rememoru cannot read window titles, so it "
                  + "would have to tell windows of the same app apart by position alone. Grant "
                  + "Accessibility, then save again.",
                  buttons: ["OK"])
            return
        }
        guard !saving, cancellation == nil else { return }
        saving = true
        lastResult = "Saving…"
        queue.async { [weak self] in
            let snapshot = service.captureSnapshot()
            let saved = Result { try service.store.save(snapshot) }
            DispatchQueue.main.async {
                guard let self else { return }
                self.saving = false
                switch saved {
                case .success(let url):
                    service.logFile.write("saved \(snapshot.windows.count) window(s) to \(url.lastPathComponent)")
                    self.lastResult = "Saved \(snapshot.windows.count) windows on \(snapshot.spaces.count) spaces"
                case .failure(let error):
                    self.lastResult = nil
                    self.alert("Could not save the layout", error.localizedDescription, buttons: ["OK"])
                }
            }
        }
    }

    @objc private func restoreLatest() {
        guard let latest = service?.store.latest else { return }
        restore(latest.url, trigger: .manual)
    }

    @objc private func restoreChosen(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        restore(url, trigger: .manual)
    }

    @objc private func cancelRestore() {
        cancellation?.cancel()
        status = "Cancelling…"
    }

    @objc private func toggleRestoreAtLogin() {
        if preferences.restoreAtLogin && LoginItem.isEnabled {
            _ = LoginItem.setEnabled(false)
            preferences.restoreAtLogin = false
            return
        }
        guard LoginItem.isInApplicationsFolder else {
            alert("Move Rememoru to Applications first",
                  "Login items are registered by location. Put Rememoru.app in /Applications or "
                  + "~/Applications, open it from there, and turn this on again.",
                  buttons: ["OK"])
            return
        }
        switch LoginItem.setEnabled(true) {
        case .enabled:
            preferences.restoreAtLogin = true
        case .needsApproval:
            preferences.restoreAtLogin = true
            if alert("Allow Rememoru to open at login",
                     "macOS needs your approval: turn Rememoru on under Login Items in System Settings.",
                     buttons: ["Open Login Items Settings", "Later"]) == .alertFirstButtonReturn {
                LoginItem.openSettings()
            }
        case .disabled:
            break
        case .failed(let reason):
            alert("Could not add Rememoru to your login items", reason, buttons: ["OK"])
        }
    }

    @objc private func toggleLaunchApps() {
        preferences.launchApps = !preferences.launchApps
    }

    @objc private func chooseLoginDelay(_ sender: NSMenuItem) {
        preferences.loginDelay = sender.tag
    }

    @objc private func grantPermission(_ sender: NSMenuItem) {
        let kind: Permissions.Kind = sender.representedObject as? String == "screenRecording"
            ? .screenRecording : .accessibility
        // the system prompt only ever appears once per app; the settings
        // pane always works
        if !Permissions.request(kind) {
            Permissions.openSettings(kind)
        }
    }

    @objc private func openSnapshotsFolder() {
        guard let directory = service?.store.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    @objc private func showLog() {
        guard let url = service?.logFile.url else { return }
        if !FileManager.default.fileExists(atPath: url.path) {
            service?.logFile.write("log created")
        }
        NSWorkspace.shared.open(url)
    }

    // MARK: - Restore

    private enum Trigger {
        case manual
        case login
    }

    private func scheduleLoginRestore() {
        let delay = preferences.loginDelay
        status = "Restoring in \(delay) seconds…"
        lastResult = status
        DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(delay)) { [weak self] in
            guard let self, let latest = self.service?.store.latest else {
                self?.lastResult = "No saved layout to restore at login"
                return
            }
            self.restore(latest.url, trigger: .login)
        }
    }

    private func restore(_ url: URL, trigger: Trigger) {
        guard let service, cancellation == nil else { return }
        guard Permissions.isGranted(.accessibility) else {
            askForAccessibility(reason: trigger == .login
                ? "Rememoru was about to restore your window layout, but it does not have Accessibility permission."
                : "Restoring a layout moves other apps' windows, which needs Accessibility permission.")
            return
        }
        let snapshot: Snapshot
        do {
            snapshot = try service.store.load(url)
        } catch {
            alert("Could not read the saved layout", "\(url.lastPathComponent): \(error)", buttons: ["OK"])
            return
        }

        let flag = CancellationFlag()
        let options = preferences.restoreOptions
        cancellation = flag
        status = "Restoring…"
        statusItem.button?.image = NSImage(systemSymbolName: "hourglass", accessibilityDescription: "Restoring")

        queue.async { [weak self] in
            let report = service.restore(snapshot, options: options, cancellation: flag, progress: { message in
                DispatchQueue.main.async { self?.status = message }
            })
            DispatchQueue.main.async { self?.finish(report, trigger: trigger) }
        }
    }

    private func finish(_ report: RestoreReport, trigger: Trigger) {
        cancellation = nil
        status = nil
        lastResult = "Last restore: \(report.summary)"
        statusItem.button?.image = NSImage(systemSymbolName: "macwindow.on.rectangle",
                                           accessibilityDescription: "Rememoru")
        guard !report.isClean || (trigger == .manual && !report.unmatched.isEmpty) else { return }

        var lines = report.failures.prefix(8).map { entry -> String in
            if case .failed(let reason) = entry.outcome { return "• \(entry.step): \(reason)" }
            return "• \(entry.step)"
        }
        if report.failures.count > 8 { lines.append("• …and \(report.failures.count - 8) more") }
        if !report.unmatched.isEmpty {
            lines.append("\(report.unmatched.count) saved window(s) could not be matched: "
                + report.unmatched.prefix(5).map(\.appName).joined(separator: ", "))
        }
        if alert(report.summary, lines.joined(separator: "\n"), buttons: ["OK", "Show Log"])
            == .alertSecondButtonReturn {
            showLog()
        }
    }

    // MARK: - Dialogs

    private func showOnboarding() {
        let granted = Permissions.isGranted(.accessibility)
        let response = alert(
            "Rememoru lives in the menu bar",
            "Save your window layout from the menu bar icon, and restore it later or automatically "
                + "at login.\n\nTo move other apps' windows, Rememoru needs Accessibility permission"
                + (granted ? " (already granted)." : ". macOS will ask for it now."),
            buttons: granted ? ["OK"] : ["Continue", "Later"]
        )
        if !granted, response == .alertFirstButtonReturn, !Permissions.request(.accessibility) {
            Permissions.openSettings(.accessibility)
        }
    }

    private func askForAccessibility(reason: String) {
        if alert("Accessibility permission needed",
                 reason + "\n\nTurn on Rememoru under Privacy & Security > Accessibility, then try again.",
                 buttons: ["Open Accessibility Settings", "Cancel"]) == .alertFirstButtonReturn {
            Permissions.request(.accessibility)
            Permissions.openSettings(.accessibility)
        }
    }

    /// Menu bar apps are never frontmost on their own; without activating,
    /// the alert would open behind other windows.
    @discardableResult
    private func alert(_ title: String, _ text: String, buttons: [String]) -> NSApplication.ModalResponse {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        buttons.forEach { alert.addButton(withTitle: $0) }
        return alert.runModal()
    }
}
#endif
