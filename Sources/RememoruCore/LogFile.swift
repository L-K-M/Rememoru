import Foundation

/// Append-only text log, safe to call from any thread. Rotates once to
/// `<name>.1` past `maxBytes` so it cannot grow without bound.
public final class LogFile: @unchecked Sendable {
    public let url: URL
    private let maxBytes: Int
    private let lock = NSLock()

    public init(url: URL, maxBytes: Int = 1_000_000) {
        self.url = url
        self.maxBytes = maxBytes
    }

    /// ~/Library/Logs/Rememoru/rememoru.log
    public static func standard(fileManager: FileManager = .default) -> LogFile {
        let library = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return LogFile(url: library
            .appendingPathComponent("Logs/Rememoru", isDirectory: true)
            .appendingPathComponent("rememoru.log"))
    }

    public func write(_ message: String, date: Date = Date()) {
        let line = "\(Self.stamp(date)) \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? Int, size > maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fileManager.removeItem(at: rotated)
            try? fileManager.moveItem(at: url, to: rotated)
        }
        guard let data = line.data(using: .utf8) else { return }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    private static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
}
