#if os(macOS)
import AppKit
import ApplicationServices
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
        case openButton(press: () -> Bool)
        case waiting
    }

    /// nil means WeChat is not running, is ready, or has no recognized
    /// startup panel. AXWindows can omit a main window on another Space.
    static func openIfNeeded(cancellation: CancellationFlag) -> RestoreReport.Outcome? {
        guard !cancellation.isCancelled,
              let app = NSRunningApplication.runningApplications(withBundleIdentifier: WeChatStartup.bundleID).first
        else { return nil }
        let application = AXElement.application(app.processIdentifier)
        return open(observe: { deadline in
            observation(application: application, deadline: deadline, cancellation: cancellation)
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
                    guard press() else {
                        return cancellation.isCancelled ? .skipped("cancelled")
                            : .failed("could not press WeChat's Open WeChat button")
                    }
                    pressed = true
                    deadline = Date().addingTimeInterval(timeout)
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
        application: AXElement, deadline: Date, cancellation: CancellationFlag
    ) -> Observation {
        let canContinue = { !cancellation.isCancelled && Date() < deadline }
        guard canContinue() else { return .waiting }
        let windows = application.elements(kAXWindowsAttribute)
        // The account panel has no minimize button. A missing Open button
        // alone can instead mean that phone confirmation is pending.
        for window in windows {
            if canContinue(), window.role == kAXWindowRole,
               canContinue(), window.subrole == kAXStandardWindowSubrole,
               canContinue(), window.windowID != nil,
               canContinue(), window.bool("AXFullScreen") == true
                    || (canContinue() && window.element(kAXMinimizeButtonAttribute) != nil) {
                return .mainWindow
            }
        }
        for window in windows {
            guard canContinue() else { break }
            guard let button = openButton(in: window, deadline: deadline, cancellation: cancellation) else { continue }
            return .openButton(press: {
                guard canContinue(), button.bool(kAXEnabledAttribute) == true,
                      canContinue(), button.actionNames.contains(kAXPressAction), canContinue() else { return false }
                return button.perform(kAXPressAction)
            })
        }
        return .waiting
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
