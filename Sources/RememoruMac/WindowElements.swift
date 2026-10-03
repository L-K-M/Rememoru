#if os(macOS)
import ApplicationServices
import Foundation

/// Finds the AX element of a window by its CGWindowID.
///
/// `kAXWindows` lists an app's windows on the current Space plus its
/// minimized windows, but not windows sitting on other Spaces. For those
/// the element is recreated from a remote token (pid + "coco" magic +
/// element id), probing element ids the way AltTab and yabai do.
final class WindowElements {
    enum ProbeMode {
        case oncePerInvalidation
        case repeatCompletedScans
    }

    struct Listing<Element> {
        let windows: [UInt32: Element]
        let isComplete: Bool

        init(_ elements: [Element], windowID: (Element) -> UInt32?) {
            var windows: [UInt32: Element] = [:]
            var complete = true
            for element in elements {
                guard let id = windowID(element) else {
                    complete = false
                    continue
                }
                windows[id] = element
            }
            self.windows = windows
            self.isComplete = complete
        }
    }

    /// Per-app time budget for probing element ids.
    static let probeBudget: TimeInterval = 1.0
    /// yabai probes the same range.
    static let maxElementID: UInt64 = 0x7fff

    static func probeStart(after cursor: UInt64, mode: ProbeMode) -> UInt64? {
        guard cursor >= maxElementID else { return cursor }
        switch mode {
        case .oncePerInvalidation: return nil
        case .repeatCompletedScans: return 0
        }
    }

    private let probeMode: ProbeMode
    private var cache: [UInt32: AXElement] = [:]
    /// Where the next probe of an app resumes. A probe stops once it found
    /// what it was asked for, so a later lookup for another window of the
    /// same app continues the scan instead of skipping it.
    private var nextElementID: [pid_t: UInt64] = [:]

    init(probeMode: ProbeMode = .oncePerInvalidation) {
        self.probeMode = probeMode
    }

    func invalidate() {
        cache.removeAll()
        nextElementID.removeAll()
    }

    /// Windows of an app from `kAXWindows`, keyed by window id. nil means
    /// AX failed, rather than a successful read with no listed windows.
    func listed(pid: pid_t) -> Listing<AXElement>? {
        guard HIServicesPrivate.getWindow != nil else { return nil }
        guard let windows = AXElement.application(pid).elementsIfAvailable(kAXWindowsAttribute) else { return nil }
        // Keep known IDs for lookup, but an unmapped window prevents
        // proving that another CG candidate is absent from this list.
        return Listing(windows, windowID: { $0.windowID })
    }

    func element(for windowID: UInt32, pid: pid_t) -> AXElement? {
        if let cached = cache[windowID] { return cached }
        for (id, element) in listed(pid: pid)?.windows ?? [:] { cache[id] = element }
        if let found = cache[windowID] { return found }
        probe(pid: pid, wanting: [windowID])
        return cache[windowID]
    }

    /// Resolves as many of `windowIDs` as possible; returns the found ones.
    func elements(for windowIDs: Set<UInt32>, pid: pid_t) -> [UInt32: AXElement] {
        var missing = windowIDs.filter { cache[$0] == nil }
        if !missing.isEmpty {
            for (id, element) in listed(pid: pid)?.windows ?? [:] { cache[id] = element }
            missing = missing.filter { cache[$0] == nil }
        }
        if !missing.isEmpty { probe(pid: pid, wanting: missing) }
        return cache.filter { windowIDs.contains($0.key) }
    }

    private func probe(pid: pid_t, wanting: Set<UInt32>) {
        guard let create = HIServicesPrivate.createWithRemoteToken else { return }
        let previous = nextElementID[pid] ?? 0
        // Bounded startup preparation can repeat a completed scan because
        // a CG window may precede its AX element. General misses stay cached
        // until invalidation to avoid repeating the full probe budget.
        guard let start = Self.probeStart(after: previous, mode: probeMode) else { return }
        var remaining = wanting
        let deadline = Date().addingTimeInterval(Self.probeBudget)
        var token = Data(count: 20)
        token.withUnsafeMutableBytes { raw in
            raw.storeBytes(of: Int32(pid), toByteOffset: 0, as: Int32.self)
            raw.storeBytes(of: Int32(0), toByteOffset: 4, as: Int32.self)
            raw.storeBytes(of: Int32(0x636f_636f), toByteOffset: 8, as: Int32.self)
        }
        var elementID = start
        defer { nextElementID[pid] = elementID }
        while elementID < Self.maxElementID {
            if remaining.isEmpty || Date() > deadline { break }
            defer { elementID += 1 }
            token.withUnsafeMutableBytes { raw in
                raw.storeBytes(of: elementID, toByteOffset: 12, as: UInt64.self)
            }
            guard let raw = create(token as CFData)?.takeRetainedValue() else { continue }
            let element = AXElement(element: raw)
            AXUIElementSetMessagingTimeout(raw, AXElement.messagingTimeout)
            // _AXUIElementGetWindow also answers for a window's descendants
            guard element.role == kAXWindowRole, let id = element.windowID else { continue }
            if cache[id] == nil { cache[id] = element }
            remaining.remove(id)
        }
    }
}
#endif
