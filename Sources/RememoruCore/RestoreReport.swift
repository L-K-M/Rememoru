import Foundation

/// Outcome of a restore, for the log, the CLI and the app's alert.
public struct RestoreReport: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        case done
        case failed(String)
        /// A later step or fallback already took care of it.
        case skipped(String)
    }

    public struct Entry: Equatable, Sendable {
        public var step: RestoreStep
        public var outcome: Outcome

        public init(step: RestoreStep, outcome: Outcome) {
            self.step = step
            self.outcome = outcome
        }
    }

    public var entries: [Entry] = []
    public var unmatched: [WindowRecord] = []
    public var notes: [String] = []
    public var cancelled = false
    /// Set when the restore could not start at all (no permission, ...).
    public var fatalError: String?

    public init() {}

    public var failures: [Entry] {
        entries.filter { if case .failed = $0.outcome { return true } else { return false } }
    }

    public var succeeded: Int {
        entries.filter { $0.outcome == .done }.count
    }

    public var isClean: Bool {
        fatalError == nil && !cancelled && failures.isEmpty
    }

    public var summary: String {
        if let fatalError { return "Restore did not run: \(fatalError)" }
        var parts = ["\(succeeded) of \(entries.count) step(s) done"]
        if !failures.isEmpty { parts.append("\(failures.count) failed") }
        if !unmatched.isEmpty { parts.append("\(unmatched.count) window(s) not found") }
        if cancelled { parts.append("cancelled") }
        return parts.joined(separator: ", ")
    }
}

/// Cooperative cancellation shared between the UI and a running restore.
public final class CancellationFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    public init() {}

    public var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func cancel() {
        lock.lock()
        value = true
        lock.unlock()
    }
}
