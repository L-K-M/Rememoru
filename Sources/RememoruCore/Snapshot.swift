import Foundation

/// A saved window layout. The JSON keys match the format written by the
/// earlier Python implementation, so existing snapshot files still load.
public struct Snapshot: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var created: String
    public var displays: [DisplayRecord]
    public var spaces: [SpaceRecord]
    public var windows: [WindowRecord]

    public init(
        version: Int = Snapshot.currentVersion,
        created: String,
        displays: [DisplayRecord],
        spaces: [SpaceRecord],
        windows: [WindowRecord]
    ) {
        self.version = version
        self.created = created
        self.displays = displays
        self.spaces = spaces
        self.windows = windows
    }

    public func space(uuid: String?) -> SpaceRecord? {
        guard let uuid else { return nil }
        return spaces.first { $0.uuid == uuid }
    }

    public func windows(onSpace uuid: String) -> [WindowRecord] {
        windows.filter { $0.spaceUUID == uuid }
    }

    /// Ordinal of a desktop among the desktops of its display, in Mission
    /// Control order. Desktops are recreated by count, so the ordinal is
    /// what identifies "the same desktop" across logins.
    public func desktopOrdinal(ofSpace uuid: String) -> Int? {
        for display in displays {
            var ordinal = 0
            for spaceUUID in display.spaceUUIDs {
                guard space(uuid: spaceUUID)?.kind == .desktop else { continue }
                if spaceUUID == uuid { return ordinal }
                ordinal += 1
            }
        }
        return nil
    }

    public func desktopCount(onDisplay uuid: String) -> Int {
        guard let display = displays.first(where: { $0.uuid == uuid }) else { return 0 }
        return display.spaceUUIDs.filter { space(uuid: $0)?.kind == .desktop }.count
    }

    public static func decode(_ data: Data) throws -> Snapshot {
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: data)
        guard snapshot.version == currentVersion else {
            throw SnapshotError.unsupportedVersion(snapshot.version)
        }
        return snapshot
    }

    public func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}

public enum SnapshotError: Error, CustomStringConvertible, Equatable {
    case unsupportedVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedVersion(let version):
            return "unsupported snapshot version \(version)"
        }
    }
}

public struct Rect: Codable, Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var w: Double
    public var h: Double

    public init(x: Double, y: Double, w: Double, h: Double) {
        self.x = x
        self.y = y
        self.w = w
        self.h = h
    }

    public var midX: Double { x + w / 2 }
    public var midY: Double { y + h / 2 }

    public func contains(x px: Double, y py: Double) -> Bool {
        px >= x && px <= x + w && py >= y && py <= y + h
    }

    /// Sum of edge offsets; 0 for identical rects.
    public func distance(to other: Rect) -> Double {
        abs(x - other.x) + abs(y - other.y) + abs(w - other.w) + abs(h - other.h)
    }

    public func isClose(to other: Rect, tolerance: Double = 3) -> Bool {
        abs(x - other.x) < tolerance && abs(y - other.y) < tolerance
            && abs(w - other.w) < tolerance && abs(h - other.h) < tolerance
    }
}

public enum SpaceKind: Codable, Equatable, Hashable, Sendable {
    case desktop
    case fullscreen
    case splitView
    /// System or unknown space types; never restore targets.
    case other(String)

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "user": self = .desktop
        case "fullscreen": self = .fullscreen
        case "tiled": self = .splitView
        default: self = .other(raw)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawName)
    }

    public var rawName: String {
        switch self {
        case .desktop: return "user"
        case .fullscreen: return "fullscreen"
        case .splitView: return "tiled"
        case .other(let raw): return raw
        }
    }

    public var displayName: String {
        switch self {
        case .desktop: return "desktop"
        case .fullscreen: return "fullscreen"
        case .splitView: return "split view"
        case .other(let raw): return raw
        }
    }
}

public enum SplitSide: String, Codable, Equatable, Sendable {
    case left
    case right
}

public struct DisplayRecord: Codable, Equatable, Sendable {
    public var uuid: String
    public var frame: Rect
    public var isMain: Bool
    /// Space UUIDs in Mission Control order.
    public var spaceUUIDs: [String]
    public var activeSpaceUUID: String?

    public init(uuid: String, frame: Rect, isMain: Bool, spaceUUIDs: [String], activeSpaceUUID: String?) {
        self.uuid = uuid
        self.frame = frame
        self.isMain = isMain
        self.spaceUUIDs = spaceUUIDs
        self.activeSpaceUUID = activeSpaceUUID
    }

    enum CodingKeys: String, CodingKey {
        case uuid
        case frame
        case isMain = "main"
        case spaceUUIDs = "spaces"
        case activeSpaceUUID = "active_space"
    }
}

public struct SpaceRecord: Codable, Equatable, Sendable {
    public var uuid: String
    /// WindowServer id at capture time; informational only, ids change
    /// across logins.
    public var id: UInt64
    public var kind: SpaceKind
    public var displayUUID: String
    public var index: Int
    public var isActive: Bool

    public init(uuid: String, id: UInt64, kind: SpaceKind, displayUUID: String, index: Int, isActive: Bool) {
        self.uuid = uuid
        self.id = id
        self.kind = kind
        self.displayUUID = displayUUID
        self.index = index
        self.isActive = isActive
    }

    enum CodingKeys: String, CodingKey {
        case uuid
        case id
        case kind = "type"
        case displayUUID = "display_uuid"
        case index
        case isActive = "active"
    }
}

public struct WindowRecord: Codable, Equatable, Sendable {
    /// CGWindowID at capture time. Stable only within one login session.
    public var windowID: UInt32
    public var pid: Int32
    public var appName: String
    public var bundleID: String?
    public var title: String
    public var frame: Rect
    public var spaceUUID: String?
    public var displayUUID: String?
    public var splitSide: SplitSide?
    public var isMinimized: Bool?

    public init(
        windowID: UInt32, pid: Int32, appName: String, bundleID: String?, title: String,
        frame: Rect, spaceUUID: String?, displayUUID: String?,
        splitSide: SplitSide? = nil, isMinimized: Bool? = nil
    ) {
        self.windowID = windowID
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.spaceUUID = spaceUUID
        self.displayUUID = displayUUID
        self.splitSide = splitSide
        self.isMinimized = isMinimized
    }

    enum CodingKeys: String, CodingKey {
        case windowID = "id"
        case pid
        case appName = "app"
        case bundleID = "bundle_id"
        case title
        case frame
        case spaceUUID = "space_uuid"
        case displayUUID = "display_uuid"
        case splitSide = "side"
        case isMinimized = "minimized"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        windowID = try c.decode(UInt32.self, forKey: .windowID)
        pid = try c.decode(Int32.self, forKey: .pid)
        appName = try c.decode(String.self, forKey: .appName)
        bundleID = try c.decodeIfPresent(String.self, forKey: .bundleID)
        // the Python writer emitted "" or null for untitled windows
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        frame = try c.decode(Rect.self, forKey: .frame)
        spaceUUID = try c.decodeIfPresent(String.self, forKey: .spaceUUID)
        displayUUID = try c.decodeIfPresent(String.self, forKey: .displayUUID)
        splitSide = try c.decodeIfPresent(SplitSide.self, forKey: .splitSide)
        isMinimized = try c.decodeIfPresent(Bool.self, forKey: .isMinimized)
    }
}
