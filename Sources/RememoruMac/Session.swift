#if os(macOS)
import Darwin
import Foundation

/// Facts about the current login session.
public enum Session {
    /// When the current user logged in on the console, from the utmpx
    /// records `who` reads.
    public static func consoleLoginDate(user: String = NSUserName()) -> Date? {
        setutxent()
        defer { endutxent() }
        var latest: Date?
        while let record = getutxent() {
            let entry = record.pointee
            guard Int32(entry.ut_type) == USER_PROCESS,
                  string(from: entry.ut_line) == "console",
                  string(from: entry.ut_user) == user else { continue }
            let date = Date(timeIntervalSince1970: TimeInterval(entry.ut_tv.tv_sec))
            if latest.map({ date > $0 }) ?? true { latest = date }
        }
        return latest
    }

    /// Whether this process started shortly after login. A login item
    /// launched by `SMAppService` gets no marker saying so, so "early in
    /// the session" is the signal; it also covers launchd restarting the
    /// app during login. Falls back to system uptime if utmpx has no record.
    public static func startedNearLogin(within window: TimeInterval = 300) -> Bool {
        let processStart = Date().addingTimeInterval(-processAge)
        if let login = consoleLoginDate() {
            return processStart.timeIntervalSince(login) < window
        }
        return ProcessInfo.processInfo.systemUptime - processAge < window
    }

    /// Seconds since this process started.
    private static var processAge: TimeInterval {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0) == 0 else { return 0 }
        let start = info.kp_proc.p_un.__p_starttime
        let started = TimeInterval(start.tv_sec) + TimeInterval(start.tv_usec) / 1_000_000
        return max(0, Date().timeIntervalSince1970 - started)
    }

    private static func string<T>(from tuple: T) -> String {
        withUnsafeBytes(of: tuple) { raw in
            String(decoding: raw.prefix { $0 != 0 }, as: UTF8.self)
        }
    }
}
#endif
