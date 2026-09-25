#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import RememoruCore

/// Executes a restore plan against the live system. Every step is
/// confirmed by re-reading WindowServer state; nothing is reported done
/// because an API call merely returned.
final class Restorer {
    private let snapshot: Snapshot
    private let options: RestoreOptions
    private let mode: RestoreMode
    private let cancellation: CancellationFlag
    private let log: (String) -> Void
    private let progress: (String) -> Void

    private let reader = LiveReader()
    private var state = LiveState(displays: [], spaces: [], windows: [])
    private var matches: [Int: WindowMatch] = [:]

    init(
        snapshot: Snapshot, options: RestoreOptions, mode: RestoreMode, cancellation: CancellationFlag,
        log: @escaping (String) -> Void, progress: @escaping (String) -> Void
    ) {
        self.snapshot = snapshot
        self.options = options
        self.mode = mode
        self.cancellation = cancellation
        self.log = log
        self.progress = progress
    }

    func run() -> RestoreReport {
        var report = RestoreReport()
        if mode == .apply, !AXIsProcessTrusted() {
            report.fatalError = "Accessibility permission is not granted"
            log(report.summary)
            return report
        }

        progress("Reading windows…")
        state = reader.read()
        if options.launchApps {
            launchMissingApps()
        }
        matches = WindowMatcher.match(snapshot.windows, to: state.windows)
        let plan = RestorePlanner.plan(snapshot: snapshot, live: state, matches: matches, options: options)
        report.unmatched = plan.unmatched
        report.notes = plan.notes
        logMatches()
        for note in plan.notes { log("note: \(note)") }
        log("plan: \(plan.steps.count) step(s)")

        guard mode == .apply else {
            for step in plan.steps {
                log("  would \(step)")
                report.entries.append(.init(step: step, outcome: .skipped("dry run")))
            }
            return report
        }

        let pointer = CGEvent(source: nil)?.location
        defer {
            if let pointer { CGWarpMouseCursorPosition(pointer) }
        }

        // focus steps switch spaces, so they run last, after the deferred
        // frames have had their spaces shown
        let focusSteps = plan.steps.filter { if case .focus = $0 { return true } else { return false } }
        var deferredFrames: [(entry: Int, window: WindowRef, frame: Rect)] = []

        for (number, step) in plan.steps.enumerated() {
            if case .focus = step { continue }
            if cancellation.isCancelled {
                report.cancelled = true
                break
            }
            progress("Step \(number + 1) of \(plan.steps.count)")
            log("→ \(step)")
            var outcome = execute(step)
            if case .setFrame(let window, let frame) = step, case .skipped = outcome {
                deferredFrames.append((report.entries.count, window, frame))
                outcome = .skipped("window is on a hidden Space; retried once it is shown")
            }
            logOutcome(outcome)
            report.entries.append(.init(step: step, outcome: outcome))
        }

        if !report.cancelled, !deferredFrames.isEmpty {
            log("setting \(deferredFrames.count) frame(s) that need their Space shown")
            for deferred in deferredFrames {
                if cancellation.isCancelled {
                    report.cancelled = true
                    break
                }
                let outcome = setFrameShowingSpace(deferred.window, deferred.frame)
                log("→ \(RestoreStep.setFrame(deferred.window, deferred.frame))")
                logOutcome(outcome)
                report.entries[deferred.entry].outcome = outcome
            }
        }

        if !report.cancelled {
            for step in focusSteps {
                log("→ \(step)")
                let outcome = execute(step)
                logOutcome(outcome)
                report.entries.append(.init(step: step, outcome: outcome))
            }
        }
        log(report.summary)
        return report
    }

    // MARK: - Steps

    private func execute(_ step: RestoreStep) -> RestoreReport.Outcome {
        switch step {
        case .createDesktops(let display, let count):
            return createDesktops(display: display, count: count)
        case .setMinimized(let window, let minimized):
            return setMinimized(window, minimized)
        case .exitFullscreen(let window):
            return exitFullscreen(window)
        case .setFrame(let window, let frame):
            return setFrameDirectly(window, frame)
        case .moveToDesktop(let window, let display, let ordinal):
            return moveToDesktop(window, display: display, ordinal: ordinal)
        case .enterFullscreen(let window, let display, let anchor):
            return enterFullscreen(window, display: display, anchor: anchor)
        case .splitView(let left, let right, let display, let anchor):
            return splitView(left: left, right: right, display: display, anchor: anchor)
        case .arrangeSpaces(let snapshotDisplay, let display):
            return arrangeSpaces(snapshotDisplay: snapshotDisplay, display: display)
        case .focus(let display, let target):
            return focus(display: display, target: target)
        }
    }

    private func createDesktops(display uuid: String, count: Int) -> RestoreReport.Outcome {
        guard let display = state.display(uuid: uuid) else { return .failed("display is not connected") }
        let added = MissionControl.addDesktops(
            display: display.id, count: count,
            desktopCount: { SkyLight.managedSpaces().spaces.filter { $0.displayUUID == uuid && $0.kind == .desktop }.count },
            log: { self.log("  \($0)") }
        )
        refresh()
        return added == count ? .done : .failed("added \(added) of \(count) desktop(s)")
    }

    private func setMinimized(_ window: WindowRef, _ minimized: Bool) -> RestoreReport.Outcome {
        guard let element = element(of: window) else { return .failed("no accessibility element for the window") }
        element.setBool(kAXMinimizedAttribute, minimized)
        let confirmed = MissionControl.wait(timeout: 2) {
            element.bool(kAXMinimizedAttribute) == minimized ? true : nil
        } != nil
        refresh()
        return confirmed ? .done : .failed("the app did not \(minimized ? "minimize" : "unminimize") it")
    }

    private func exitFullscreen(_ window: WindowRef) -> RestoreReport.Outcome {
        // fullscreen spaces only react while shown
        guard let element = visibleElement(of: window) else {
            return .failed("no accessibility element for the window")
        }
        guard element.setBool("AXFullScreen", false) else { return .failed("the app refused to leave fullscreen") }
        let left = MissionControl.wait(timeout: 5) { spaceOf(window.id)?.kind == .desktop ? true : nil } != nil
        Thread.sleep(forTimeInterval: 0.5)  // the exit animation outlasts the state change
        refresh()
        return left ? .done : .failed("still in fullscreen after 5 s")
    }

    /// Sets a frame without switching Spaces. `.skipped` means the window is
    /// on a hidden Space and the frame did not take; the caller retries it
    /// with the Space shown.
    private func setFrameDirectly(_ window: WindowRef, _ frame: Rect) -> RestoreReport.Outcome {
        let onVisibleSpace = spaceOf(window.id)?.isActive ?? true
        guard let element = element(of: window) else {
            return onVisibleSpace ? .failed("no accessibility element for the window") : .skipped("hidden")
        }
        element.setFrame(frame)
        if frameMatches(window.id, frame) { return .done }
        return onVisibleSpace ? .failed(frameMismatch(window.id, frame)) : .skipped("hidden")
    }

    private func setFrameShowingSpace(_ window: WindowRef, _ frame: Rect) -> RestoreReport.Outcome {
        guard let element = visibleElement(of: window) else { return .failed("could not show the window's Space") }
        element.setFrame(frame)
        return frameMatches(window.id, frame) ? .done : .failed(frameMismatch(window.id, frame))
    }

    private func moveToDesktop(_ window: WindowRef, display: String, ordinal: Int) -> RestoreReport.Outcome {
        refresh()
        let desktops = state.desktops(onDisplay: display)
        guard ordinal < desktops.count else { return .failed("display has no desktop \(ordinal + 1)") }
        return move(window, to: desktops[ordinal], display: display)
    }

    private func move(_ window: WindowRef, to target: LiveSpace, display: String) -> RestoreReport.Outcome {
        if spaceOf(window.id)?.id == target.id { return .done }
        guard BridgedOperations.canMoveWindows else {
            return .failed("this macOS version has no usable SLSBridgedMoveWindowsToManagedSpaceOperation")
        }
        func submitAndConfirm(timeout: TimeInterval) -> Bool {
            guard BridgedOperations.moveWindows([window.id], toSpace: target.id) else { return false }
            return MissionControl.wait(timeout: timeout, interval: 0.05) {
                spaceOf(window.id)?.id == target.id ? true : nil
            } != nil
        }
        if submitAndConfirm(timeout: 1.5) {
            refresh()
            return .done
        }
        // Moves into a desktop that was never shown are reported to fail
        // (yabai #2789); showing it first is the retry.
        log("  move not confirmed; showing the target desktop and retrying")
        if let liveDisplay = state.display(uuid: display) {
            _ = SpaceSwitcher.show(spaceID: target.id, display: liveDisplay, readSpaces: { SkyLight.managedSpaces().spaces })
        }
        let moved = submitAndConfirm(timeout: 2)
        refresh()
        return moved ? .done : .failed("WindowServer did not move the window")
    }

    private func enterFullscreen(_ window: WindowRef, display: String, anchor: Int) -> RestoreReport.Outcome {
        if let failure = placeOnAnchor([window], display: display, anchor: anchor) { return .failed(failure) }
        guard let element = visibleElement(of: window) else { return .failed("no accessibility element for the window") }
        raise(window, element)

        if !element.setBool("AXFullScreen", true) {
            guard let item = menuItem(pid: window.pid, path: [["View", "Window"], ["Enter Full Screen"]]),
                  item.perform(kAXPressAction) else {
                return .failed("the app has no settable fullscreen state and no Enter Full Screen menu item")
            }
        }
        let entered = MissionControl.wait(timeout: 5) { spaceOf(window.id)?.kind == .fullscreen ? true : nil } != nil
        Thread.sleep(forTimeInterval: 0.8)  // let the transition finish before the next space change
        refresh()
        return entered ? .done : .failed("window did not enter fullscreen within 5 s")
    }

    private func splitView(left: WindowRef, right: WindowRef, display: String, anchor: Int) -> RestoreReport.Outcome {
        if let failure = placeOnAnchor([left, right], display: display, anchor: anchor) { return .failed(failure) }
        guard let liveDisplay = state.display(uuid: display) else { return .failed("display is not connected") }
        guard let element = visibleElement(of: left) else { return .failed("no accessibility element for \(left)") }
        raise(left, element)

        // macOS 15/26 put "Full Screen Tile > Left of Screen" in the Window
        // menu of apps with a standard Window menu (English titles only).
        guard let item = menuItem(pid: left.pid, path: [["Window"], ["Left of Screen"]]) else {
            return .failed("\(left.appName) has no Window > Full Screen Tile > Left of Screen menu item")
        }
        guard item.perform(kAXPressAction) else { return .failed("pressing Left of Screen failed") }
        guard MissionControl.wait(timeout: 4, { spaceOf(left.id)?.kind.isFullscreenLike == true ? true : nil }) != nil
        else { return .failed("\(left) did not tile to the left") }

        // The right half now shows a picker of other windows; its miniatures
        // hit-test as the apps' real windows.
        Thread.sleep(forTimeInterval: 0.6)
        guard let point = MissionControl.wait(timeout: 4, interval: 0.3, {
            pickerPoint(for: right.id, on: liveDisplay.frame)
        }) else {
            CGEvent.keyPress(53)  // Escape: leave the picker instead of blocking the screen
            refresh()
            return .failed("\(right) was not offered in the Split View picker")
        }
        CGEvent.click(at: point)
        let paired = MissionControl.wait(timeout: 5) { () -> Bool? in
            guard let space = spaceOf(left.id), space.kind == .splitView else { return nil }
            return spaceOf(right.id)?.id == space.id ? true : nil
        } != nil
        Thread.sleep(forTimeInterval: 0.8)
        refresh()
        return paired ? .done : .failed("the Split View pair did not form")
    }

    private func arrangeSpaces(snapshotDisplay: String, display uuid: String) -> RestoreReport.Outcome {
        refresh()
        guard let saved = snapshot.displays.first(where: { $0.uuid == snapshotDisplay }) else {
            return .failed("display is not in the snapshot")
        }
        let desired = desiredOrder(saved, display: uuid)
        func current() -> [UInt64] { state.spaces(onDisplay: uuid).map(\.id) }
        func inOrder() -> Bool { current().filter { desired.contains($0) } == desired }
        if inOrder() { return .done }
        guard BridgedOperations.canMoveSpaces else {
            return .failed("this macOS version has no usable SLSBridgedMoveManagedSpaceToDisplayIndexOperation")
        }
        for (index, space) in desired.enumerated() where current().firstIndex(of: space) != index {
            guard BridgedOperations.moveSpace(space, displayIdentifier: uuid, toIndex: index) else {
                return .failed("the space reorder operation could not be submitted")
            }
            let placed = MissionControl.wait(timeout: 2) { () -> Bool? in
                refresh(windows: false)
                return current().firstIndex(of: space) == index ? true : nil
            } != nil
            if !placed { return .failed("space \(space) did not move to position \(index + 1)") }
        }
        refresh()
        return inOrder() ? .done : .failed("order still differs")
    }

    /// Live space ids in the snapshot's Mission Control order.
    private func desiredOrder(_ saved: DisplayRecord, display uuid: String) -> [UInt64] {
        let desktops = state.desktops(onDisplay: uuid)
        var order: [UInt64] = []
        for spaceUUID in saved.spaceUUIDs {
            guard let space = snapshot.space(uuid: spaceUUID) else { continue }
            var id: UInt64?
            switch space.kind {
            case .desktop:
                if let ordinal = snapshot.desktopOrdinal(ofSpace: spaceUUID), ordinal < desktops.count {
                    id = desktops[ordinal].id
                }
            case .fullscreen, .splitView:
                if let member = snapshot.windows.indices.first(where: { snapshot.windows[$0].spaceUUID == spaceUUID }),
                   let live = matches[member]?.live, let current = spaceOf(live.id),
                   current.kind.isFullscreenLike, current.displayUUID == uuid {
                    id = current.id
                }
            case .other:
                break
            }
            if let id, !order.contains(id) { order.append(id) }
        }
        return order
    }

    private func focus(display uuid: String, target: SpaceTarget) -> RestoreReport.Outcome {
        refresh()
        guard let display = state.display(uuid: uuid) else { return .failed("display is not connected") }
        let space: LiveSpace?
        switch target {
        case .desktop(let ordinal):
            let desktops = state.desktops(onDisplay: uuid)
            space = ordinal < desktops.count ? desktops[ordinal] : nil
        case .spaceOf(let window):
            space = spaceOf(window)
        }
        guard let space else { return .failed("the space no longer exists") }
        return SpaceSwitcher.show(spaceID: space.id, display: display, readSpaces: { SkyLight.managedSpaces().spaces }) != nil
            ? .done : .failed("could not switch to the space")
    }

    /// Opens apps that have saved windows but none now, then waits until
    /// they show as many windows as were saved (or 20 s pass).
    private func launchMissingApps() {
        let missing = RestorePlanner.appsToLaunch(snapshot: snapshot, live: state)
        guard !missing.isEmpty else { return }
        for bundleID in missing.keys.sorted() {
            guard mode == .apply else {
                log("would open \(bundleID)")
                continue
            }
            log("opening \(bundleID)")
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            process.arguments = ["-g", "-b", bundleID]  // -g: stay in the background
            do {
                try process.run()
                process.waitUntilExit()
            } catch {
                log("  ✗ could not open \(bundleID): \(error.localizedDescription)")
            }
        }
        guard mode == .apply else { return }
        progress("Waiting for apps to open windows…")
        _ = MissionControl.wait(timeout: 20, interval: 0.5) { () -> Bool? in
            let windows = reader.read(withTitles: false).windows
            let ready = missing.allSatisfy { bundleID, count in
                windows.filter { $0.bundleID == bundleID }.count >= count
            }
            return ready ? true : nil
        }
        state = reader.read()
    }

    // MARK: - Helpers

    private func refresh(windows: Bool = true) {
        if windows {
            state = reader.read(withTitles: false)
        } else {
            state.spaces = SkyLight.managedSpaces().spaces
        }
    }

    /// The space a window is on right now, straight from WindowServer.
    private func spaceOf(_ windowID: UInt32) -> LiveSpace? {
        let managed = SkyLight.managedSpaces()
        let id = managed.resolveSpace(windowID: windowID, reported: SkyLight.spaces(ofWindow: windowID))
        return managed.spaces.first { $0.id == id }
    }

    private func element(of window: WindowRef) -> AXElement? {
        reader.elements.element(for: window.id, pid: window.pid)
    }

    /// Shows the window's Space if needed, then returns its element.
    private func visibleElement(of window: WindowRef) -> AXElement? {
        if let space = spaceOf(window.id), !space.isActive, let display = state.display(uuid: space.displayUUID) {
            _ = SpaceSwitcher.show(spaceID: space.id, display: display, readSpaces: { SkyLight.managedSpaces().spaces })
            reader.elements.invalidate()
        }
        return element(of: window)
    }

    /// Gets windows onto the anchor desktop of a display (for fullscreen
    /// and Split View, which create their space next to it) and shows it.
    /// Returns a failure reason, or nil.
    private func placeOnAnchor(_ windows: [WindowRef], display uuid: String, anchor: Int) -> String? {
        refresh()
        guard let display = state.display(uuid: uuid) else { return "display is not connected" }
        let desktops = state.desktops(onDisplay: uuid)
        guard anchor < desktops.count else { return "display has no desktop \(anchor + 1)" }
        let target = desktops[anchor]

        for window in windows {
            if spaceOf(window.id)?.displayUUID != uuid {
                // cross-display: bring it onto the display, then onto the desktop
                guard let element = visibleElement(of: window) else { return "no accessibility element for \(window)" }
                let f = display.frame
                element.setFrame(Rect(x: f.x + f.w * 0.15, y: f.y + f.h * 0.15, w: f.w * 0.7, h: f.h * 0.7))
                Thread.sleep(forTimeInterval: 0.3)
            }
            if case .failed(let reason) = move(window, to: target, display: uuid) {
                return "could not put \(window) on desktop \(anchor + 1): \(reason)"
            }
        }
        guard SpaceSwitcher.show(spaceID: target.id, display: display, readSpaces: { SkyLight.managedSpaces().spaces }) != nil
        else { return "could not show desktop \(anchor + 1)" }
        reader.elements.invalidate()
        return nil
    }

    private func raise(_ window: WindowRef, _ element: AXElement) {
        // activate() alone is only a request since macOS 14; AXFrontmost
        // makes the app key so menu commands target this window
        NSRunningApplication(processIdentifier: window.pid)?.activate(options: [])
        AXElement.application(window.pid).setBool(kAXFrontmostAttribute, true)
        element.setBool(kAXMainAttribute, true)
        element.perform(kAXRaiseAction)
        Thread.sleep(forTimeInterval: 0.3)
    }

    /// Finds a menu item by title path; each level lists accepted titles
    /// and may sit a few menus below the previous one. Some items (the
    /// system's tiling entries) only exist once their menu has opened, so
    /// a miss opens the top-level menu and looks again.
    private func menuItem(pid: pid_t, path: [[String]]) -> AXElement? {
        guard let bar = AXElement.application(pid).element(kAXMenuBarAttribute),
              let first = path.first, let top = find(first, under: bar, depth: 1) else { return nil }
        func resolve() -> AXElement? {
            var current = top
            for titles in path.dropFirst() {
                guard let next = find(titles, under: current, depth: 4) else { return nil }
                current = next
            }
            return current
        }
        if let item = resolve() { return item }
        guard path.count > 1, top.perform(kAXPressAction) else { return nil }
        Thread.sleep(forTimeInterval: 0.3)
        if let item = resolve() { return item }
        CGEvent.keyPress(53)  // Escape closes the menu we opened
        return nil
    }

    /// Breadth-first: direct children first, then deeper menus.
    private func find(_ titles: [String], under element: AXElement, depth: Int) -> AXElement? {
        guard depth > 0 else { return nil }
        let children = element.children
        if let hit = children.first(where: {
            ($0.role == kAXMenuItemRole || $0.role == kAXMenuBarItemRole) && titles.contains($0.title ?? "")
        }) { return hit }
        for child in children {
            if let found = find(titles, under: child, depth: depth - 1) { return found }
        }
        return nil
    }

    /// Grid-searches the right half of a display for a point whose element
    /// belongs to the wanted window (SplitView.spoon's technique).
    private func pickerPoint(for windowID: UInt32, on frame: Rect) -> CGPoint? {
        let columns = 8
        let rows = 6
        let half = Rect(x: frame.x + frame.w / 2, y: frame.y, w: frame.w / 2, h: frame.h)
        for row in 0..<rows {
            for column in 0..<columns {
                let point = CGPoint(x: half.x + (Double(column) + 0.5) * half.w / Double(columns),
                                    y: half.y + (Double(row) + 0.5) * half.h / Double(rows))
                var raw: AXUIElement?
                guard AXUIElementCopyElementAtPosition(AXElement.systemWide.element, Float(point.x),
                                                       Float(point.y), &raw) == .success, let raw else { continue }
                let hit = AXElement(element: raw)
                let window = hit.role == kAXWindowRole ? hit : hit.element(kAXWindowAttribute)
                if window?.windowID == windowID { return point }
            }
        }
        return nil
    }

    private func frameMatches(_ windowID: UInt32, _ frame: Rect) -> Bool {
        guard let actual = MissionControl.wait(timeout: 1, interval: 0.1, { () -> Rect? in
            guard let bounds = LiveReader.bounds(ofWindow: windowID) else { return nil }
            return Self.acceptable(bounds, for: frame) ? bounds : nil
        }) else { return false }
        return Self.acceptable(actual, for: frame)
    }

    /// Position must match; size may differ slightly, since apps snap to
    /// their own increments (terminals to character cells, for example).
    static func acceptable(_ actual: Rect, for wanted: Rect) -> Bool {
        abs(actual.x - wanted.x) < 4 && abs(actual.y - wanted.y) < 4
            && abs(actual.w - wanted.w) < 24 && abs(actual.h - wanted.h) < 24
    }

    private func frameMismatch(_ windowID: UInt32, _ frame: Rect) -> String {
        guard let actual = LiveReader.bounds(ofWindow: windowID) else { return "the window disappeared" }
        return String(format: "app kept (%.0f, %.0f) %.0f x %.0f", actual.x, actual.y, actual.w, actual.h)
    }

    private func logMatches() {
        for (index, saved) in snapshot.windows.enumerated() {
            guard let match = matches[index], match.basis == .position else { continue }
            log("matched \(saved.appName) \u{201C}\(saved.title)\u{201D} by position (title is now \u{201C}\(match.live.title)\u{201D})")
        }
        for window in snapshot.windows.indices.filter({ matches[$0] == nil }).map({ snapshot.windows[$0] }) {
            log("not found: \(window.appName) \u{201C}\(window.title)\u{201D}")
        }
    }

    private func logOutcome(_ outcome: RestoreReport.Outcome) {
        switch outcome {
        case .done: log("  ✓")
        case .failed(let reason): log("  ✗ \(reason)")
        case .skipped(let reason): log("  – \(reason)")
        }
    }
}

extension SpaceKind {
    var isFullscreenLike: Bool { self == .fullscreen || self == .splitView }
}

extension CGEvent {
    static func click(at point: CGPoint) {
        for type in [CGEventType.leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?
                .post(tap: .cghidEventTap)
            Thread.sleep(forTimeInterval: 0.05)
        }
    }

    static func keyPress(_ keyCode: CGKeyCode) {
        for down in [true, false] {
            CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: down)?.post(tap: .cghidEventTap)
        }
    }
}
#endif
