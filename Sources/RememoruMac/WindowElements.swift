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
    /// Per-app time budget for probing element ids.
    static let probeBudget: TimeInterval = 1.0
    /// yabai probes the same range.
    static let maxElementID: UInt64 = 0x7fff

    private var cache: [UInt32: AXElement] = [:]
    /// Where the next probe of an app resumes. A probe stops once it found
    /// what it was asked for, so a later lookup for another window of the
    /// same app continues the scan instead of skipping it.
    private var nextElementID: [pid_t: UInt64] = [:]

    func invalidate() {
        cache.removeAll()
        nextElementID.removeAll()
    }

    /// Windows of an app from `kAXWindows`, keyed by window id.
    func listed(pid: pid_t) -> [UInt32: AXElement] {
        var result: [UInt32: AXElement] = [:]
        for window in AXElement.application(pid).elements(kAXWindowsAttribute) {
            if let id = window.windowID { result[id] = window }
        }
        return result
    }

    func element(for windowID: UInt32, pid: pid_t) -> AXElement? {
        if let cached = cache[windowID] { return cached }
        for (id, element) in listed(pid: pid) { cache[id] = element }
        if let found = cache[windowID] { return found }
        probe(pid: pid, wanting: [windowID])
        return cache[windowID]
    }

    /// Resolves as many of `windowIDs` as possible; returns the found ones.
    func elements(for windowIDs: Set<UInt32>, pid: pid_t) -> [UInt32: AXElement] {
        var missing = windowIDs.filter { cache[$0] == nil }
        if !missing.isEmpty {
            for (id, element) in listed(pid: pid) { cache[id] = element }
            missing = missing.filter { cache[$0] == nil }
        }
        if !missing.isEmpty { probe(pid: pid, wanting: missing) }
        return cache.filter { windowIDs.contains($0.key) }
    }

    private func probe(pid: pid_t, wanting: Set<UInt32>) {
        let start = nextElementID[pid] ?? 0
        guard start < Self.maxElementID, let create = HIServicesPrivate.createWithRemoteToken else { return }
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
