#if os(macOS)
import AppKit
import ApplicationServices
import CoreGraphics
import RememoruCore

/// Opens the account startup panel before window ids are matched.
enum WeChatOpener {
    private static let timeout: TimeInterval = 20
    private static let discoveryTimeout: TimeInterval = 3
    private static let maximumNodes = 512
    private static let maximumDepth = 12
    private static let discoveryBudget: TimeInterval = 1

    enum Observation {
        case mainWindow
        case openButton(press: (Date) -> Bool)
        case waiting
    }

    /// nil means WeChat is not running, is ready, or has no recognized
    /// startup panel. AXWindows can omit a main window on another Space.
    static func openIfNeeded(cancellation: CancellationFlag) -> RestoreReport.Outcome? {
        guard !cancellation.isCancelled,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: WeChatStartup.bundleID).first
        else { return nil }
        let application = AXElement.application(app.processIdentifier)
        let elements = WindowElements(probeMode: .repeatCompletedScans)
        var previousWindowIDs = Set<UInt32>()
        return open(observe: { deadline in
            observation(application: application, pid: app.processIdentifier, elements: elements,
                        previousWindowIDs: &previousWindowIDs, deadline: deadline, cancellation: cancellation)
        }, cancellation: cancellation)
    }

    /// Separated from AX discovery so readiness, failure and cancellation
    /// can be exercised without changing a user's account or windows.
    static func open(
        observe: (Date) -> Observation, cancellation: CancellationFlag,
        timeout: TimeInterval = timeout, discoveryTimeout: TimeInterval = discoveryTimeout,
        interval: TimeInterval = 0.1
    ) -> RestoreReport.Outcome? {
        var deadline = Date().addingTimeInterval(discoveryTimeout)
        var pressed = false
        while true {
            if cancellation.isCancelled { return .skipped("cancelled") }
            // AX controls can appear after the CG window that app launch waits for.
            let observation = observe(deadline)
            if cancellation.isCancelled { return .skipped("cancelled") }
            switch observation {
            case .mainWindow:
                return pressed ? .done : nil
            case .openButton(let press):
                if !pressed {
                    deadline = Date().addingTimeInterval(timeout)
                    guard press(deadline) else {
                        return cancellation.isCancelled ? .skipped("cancelled")
                            : .failed("could not press WeChat's Open WeChat button")
                    }
                    pressed = true
                }
            case .waiting:
                break
            }
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            Thread.sleep(forTimeInterval: min(interval, remaining))
        }
        guard pressed else { return nil }
        return .failed(
            "WeChat did not open its main window; finish any phone confirmation in WeChat, then retry"
        )
    }

    private static func observation(
        application: AXElement, pid: pid_t, elements: WindowElements,
        previousWindowIDs: inout Set<UInt32>, deadline: Date, cancellation: CancellationFlag
    ) -> Observation {
        let canContinue = { !cancellation.isCancelled && Date() < deadline }
        guard canContinue() else { return .waiting }
        let windowIDs = candidateWindowIDs(pid: pid, canContinue: canContinue)
        updateCandidates(windowIDs, previous: &previousWindowIDs, reset: elements.invalidate)
        guard canContinue() else { return .waiting }
        let windows = application.elements(kAXWindowsAttribute)
        var available: [UInt32: AXElement] = [:]
        for window in windows {
            guard canContinue() else { return .waiting }
            if let id = window.windowID { available[id] = window }
        }
        return discover(
            windowIDs: windowIDs, listedWindowIDs: Set(available.keys),
            resolveHidden: { missing in
                guard canContinue() else { return }
                for (id, window) in elements.elements(for: missing, pid: pid) { available[id] = window }
            },
            inspect: { id in
                guard let window = available[id] else { return .waiting }
                return inspect(window: window, application: application, pid: pid, elements: elements,
                               deadline: deadline, cancellation: cancellation)
            },
            deadline: deadline, cancellation: cancellation
        )
    }

    static func updateCandidates(_ windowIDs: [UInt32], previous: inout Set<UInt32>, reset: () -> Void) {
        let current = Set(windowIDs)
        guard current != previous else { return }
        // Opening can create a main window with an AX element id below the old cursor.
        reset()
        previous = current
    }

    /// WindowServer sees windows on every Space, while AXWindows may omit them.
    /// The injected lookup keeps that discovery boundary testable without UI actions.
    static func discover(
        windowIDs: [UInt32], listedWindowIDs: Set<UInt32>, resolveHidden: (Set<UInt32>) -> Void,
        inspect: (UInt32) -> Observation, deadline: Date, cancellation: CancellationFlag
    ) -> Observation {
        let canContinue = { !cancellation.isCancelled && Date() < deadline }
        let eligible = Set(windowIDs)
        func inspectWindows(_ ids: [UInt32]) -> Observation {
            var startup: Observation?
            for id in ids {
                guard canContinue() else { return .waiting }
                switch inspect(id) {
                case .mainWindow: return .mainWindow
                case .openButton(let press):
                    if eligible.contains(id) { startup = startup ?? .openButton(press: press) }
                case .waiting: continue
                }
            }
            return startup ?? .waiting
        }

        // Sticky or minimized main windows may lack a single managed Space.
        // They still prove readiness; only startup actions require a candidate id.
        let listedIDs = windowIDs.filter { listedWindowIDs.contains($0) }
            + listedWindowIDs.subtracting(eligible).sorted()
        let listed = inspectWindows(listedIDs)
        if case .mainWindow = listed { return .mainWindow }
        let hidden = windowIDs.filter { !listedWindowIDs.contains($0) }
        guard !hidden.isEmpty else { return listed }
        guard canContinue() else { return .waiting }
        resolveHidden(Set(hidden))
        guard canContinue() else { return .waiting }
        let resolved = inspectWindows(hidden)
        if case .mainWindow = resolved { return .mainWindow }
        if case .openButton = listed { return listed }
        return resolved
    }

    private static func candidateWindowIDs(pid: pid_t, canContinue: () -> Bool) -> [UInt32] {
        guard canContinue() else { return [] }
        let info = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        guard canContinue() else { return [] }
        let managed = SkyLight.managedSpaces()
        var result: [UInt32] = []
        for window in WindowFilter.candidates(from: info) where window.pid == pid {
            guard canContinue() else { break }
            if managed.resolveSpace(windowID: window.id, reported: SkyLight.spaces(ofWindow: window.id)) != nil {
                result.append(window.id)
            }
        }
        return result
    }

    private static func inspect(
        window: AXElement, application: AXElement, pid: pid_t, elements: WindowElements,
        deadline: Date, cancellation: CancellationFlag
    ) -> Observation {
        let canContinue = { !cancellation.isCancelled && Date() < deadline }
        return classify(openButton: {
            guard canContinue(), let button = openButton(in: window, deadline: deadline, cancellation: cancellation)
            else { return nil }
            return .openButton(press: { openingDeadline in
                let canPress = { !cancellation.isCancelled && Date() < openingDeadline }
                guard canPress(), button.bool(kAXEnabledAttribute) == true, canPress() else { return false }
                if button.actionNames.contains(kAXPressAction) {
                    guard canPress() else { return false }
                    return button.perform(kAXPressAction)
                }
                // This button can advertise only AXRaise. When AXPress
                // is not offered, click its verified hit target.
                var currentIDs = Set<UInt32>()
                return WeChatStartupClick.click(
                    button: button, window: window, application: application, pid: pid,
                    deadline: openingDeadline, cancellation: cancellation, isReady: {
                        let current = observation(
                            application: application, pid: pid, elements: elements,
                            previousWindowIDs: &currentIDs, deadline: openingDeadline, cancellation: cancellation
                        )
                        if case .mainWindow = current { return true }
                        return false
                    }
                )
            })
        }, isMainWindow: {
            guard canContinue(), window.role == kAXWindowRole,
                  canContinue(), window.subrole == kAXStandardWindowSubrole,
                  canContinue(), window.windowID != nil, canContinue() else { return false }
            let fullscreen = window.bool("AXFullScreen") == true
            guard canContinue() else { return false }
            let minimize = window.element(kAXMinimizeButtonAttribute) != nil
            guard canContinue() else { return false }
            let zoom = window.element(kAXZoomButtonAttribute)
            guard canContinue() else { return false }
            let zoomEnabled = zoom?.bool(kAXEnabledAttribute) == true
            return WeChatStartup.isMainWindow(
                isStandardWindow: true, isFullscreen: fullscreen,
                hasMinimizeButton: minimize, isZoomEnabled: zoomEnabled
            )
        })
    }

    static func classify(openButton: () -> Observation?, isMainWindow: () -> Bool) -> Observation {
        if let startup = openButton() { return startup }
        return isMainWindow() ? .mainWindow : .waiting
    }

    private static func openButton(in window: AXElement, deadline: Date, cancellation: CancellationFlag) -> AXElement? {
        var queue: [(element: AXElement, depth: Int)] = [(window, 0)]
        var index = 0
        let discoveryDeadline = min(deadline, Date().addingTimeInterval(discoveryBudget))
        let canContinue = { !cancellation.isCancelled && Date() < discoveryDeadline }
        while index < queue.count, index < maximumNodes, canContinue() {
            let (element, depth) = queue[index]
            index += 1
            if element.role == kAXButtonRole {
                for attribute in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
                    guard canContinue() else { return nil }
                    if let label = element.string(attribute), WeChatStartup.isOpenButton(isButton: true, labels: [label]) {
                        return element
                    }
                }
            }
            guard depth < maximumDepth else { continue }
            let remaining = maximumNodes - queue.count
            guard remaining > 0, canContinue() else { continue }
            queue += element.children.prefix(remaining).map { ($0, depth + 1) }
        }
        return nil
    }
}
#endif
