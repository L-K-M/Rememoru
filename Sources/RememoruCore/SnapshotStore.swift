import Foundation

/// Saved layouts on disk, one JSON file per snapshot.
public struct SnapshotStore {
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var name: String
        public var modified: Date
    }

    public let directory: URL

    public init(directory: URL) {
        self.directory = directory
    }

    /// ~/Library/Application Support/Rememoru/Snapshots
    public static func standard(fileManager: FileManager = .default) throws -> SnapshotStore {
        let support = try fileManager.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )
        return SnapshotStore(directory: support
            .appendingPathComponent("Rememoru", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true))
    }

    /// Newest first.
    public func list(fileManager: FileManager = .default) -> [Entry] {
        let urls = (try? fileManager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        return urls
            .filter { $0.pathExtension == "json" }
            .map { url in
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate ?? .distantPast
                return Entry(url: url, name: url.deletingPathExtension().lastPathComponent, modified: modified)
            }
            .sorted { $0.modified != $1.modified ? $0.modified > $1.modified : $0.name > $1.name }
    }

    public var latest: Entry? { list().first }

    @discardableResult
    public func save(_ snapshot: Snapshot, date: Date = Date(), fileManager: FileManager = .default) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let base = "layout-" + Self.fileStamp(date)
        var url = directory.appendingPathComponent(base + ".json")
        var suffix = 2
        while fileManager.fileExists(atPath: url.path) {
            url = directory.appendingPathComponent("\(base)-\(suffix).json")
            suffix += 1
        }
        try snapshot.encoded().write(to: url, options: .atomic)
        return url
    }

    public func load(_ url: URL) throws -> Snapshot {
        try Snapshot.decode(Data(contentsOf: url))
    }

    static func fileStamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    /// ISO 8601 with offset, as stored in `Snapshot.created`.
    public static func timestamp(_ date: Date = Date()) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
        return formatter.string(from: date)
    }
}
