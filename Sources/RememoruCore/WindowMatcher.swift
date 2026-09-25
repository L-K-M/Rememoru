import Foundation

public struct WindowMatch: Equatable, Sendable {
    public enum Basis: String, Equatable, Sendable {
        /// Same CGWindowID and process: the snapshot is from this session.
        case sameWindow = "same window"
        case title
        /// Title changed (browser tab, document), matched by position among
        /// the app's leftover windows.
        case position
    }

    public var live: LiveWindow
    public var basis: Basis
}

/// Pairs snapshot windows with live windows of the same app.
public enum WindowMatcher {
    /// Returns snapshot window index -> match. Each live window is used once.
    public static func match(_ saved: [WindowRecord], to live: [LiveWindow]) -> [Int: WindowMatch] {
        var result: [Int: WindowMatch] = [:]
        var usedLive = Set<Int>()

        // Pass 1: identity and title evidence, best score first.
        var scored: [(score: Double, saved: Int, live: Int, basis: WindowMatch.Basis)] = []
        for (i, s) in saved.enumerated() {
            for (j, l) in live.enumerated() where isSameApp(s, l) {
                let sameWindow = s.windowID == l.id && s.pid == l.pid
                let title = titleScore(s.title, l.title)
                guard sameWindow || title > 0 else { continue }
                let score = (sameWindow ? 1000 : 0) + title + frameBonus(s.frame, l.frame)
                scored.append((score, i, j, sameWindow ? .sameWindow : .title))
            }
        }
        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            if a.saved != b.saved { return a.saved < b.saved }
            return a.live < b.live
        }
        for candidate in scored where result[candidate.saved] == nil && !usedLive.contains(candidate.live) {
            result[candidate.saved] = WindowMatch(live: live[candidate.live], basis: candidate.basis)
            usedLive.insert(candidate.live)
        }

        // Pass 2: leftovers of the same app, nearest frame first.
        var leftovers: [(distance: Double, saved: Int, live: Int)] = []
        for (i, s) in saved.enumerated() where result[i] == nil {
            for (j, l) in live.enumerated() where !usedLive.contains(j) && isSameApp(s, l) {
                leftovers.append((s.frame.distance(to: l.frame), i, j))
            }
        }
        leftovers.sort { a, b in
            if a.distance != b.distance { return a.distance < b.distance }
            if a.saved != b.saved { return a.saved < b.saved }
            return a.live < b.live
        }
        for candidate in leftovers where result[candidate.saved] == nil && !usedLive.contains(candidate.live) {
            result[candidate.saved] = WindowMatch(live: live[candidate.live], basis: .position)
            usedLive.insert(candidate.live)
        }
        return result
    }

    static func isSameApp(_ saved: WindowRecord, _ live: LiveWindow) -> Bool {
        if let a = saved.bundleID, let b = live.bundleID {
            return a == b
        }
        return normalized(saved.appName) == normalized(live.appName)
    }

    static func titleScore(_ saved: String, _ live: String) -> Double {
        let s = normalized(saved)
        let l = normalized(live)
        if s == l { return s.isEmpty ? 50 : 100 }
        // missing titles (no Screen Recording grant) are weak evidence
        if s.isEmpty || l.isEmpty { return 20 }
        if s.hasPrefix(l) || l.hasPrefix(s) { return 60 }
        if s.contains(l) || l.contains(s) { return 40 }
        return 0
    }

    static func frameBonus(_ a: Rect, _ b: Rect) -> Double {
        max(0, 30 - a.distance(to: b) / 40)
    }

    static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
