import Foundation

/// Live WindowServer state, as read by the macOS layer. Kept free of
/// framework types so capture and restore planning are testable anywhere.
public struct LiveDisplay: Equatable, Sendable {
    public var id: UInt32
    public var uuid: String
    public var frame: Rect
    public var isMain: Bool

    public init(id: UInt32, uuid: String, frame: Rect, isMain: Bool) {
        self.id = id
        self.uuid = uuid
        self.frame = frame
        self.isMain = isMain
    }
}

public struct LiveTile: Equatable, Sendable {
    public var windowID: UInt32?
    public var appName: String?
    public var title: String?
    public var side: SplitSide

    public init(windowID: UInt32?, appName: String?, title: String?, side: SplitSide) {
        self.windowID = windowID
        self.appName = appName
        self.title = title
        self.side = side
    }
}

public struct LiveSpace: Equatable, Sendable {
    public var id: UInt64
    /// Unique within one reading; synthesized from the id when SkyLight
    /// reports an empty or duplicate uuid (the original desktop often has "").
    public var key: String
    public var kind: SpaceKind
    public var displayUUID: String
    /// Position in the display's Mission Control order.
    public var index: Int
    public var isActive: Bool
    public var tiles: [LiveTile]

    public init(
        id: UInt64, key: String, kind: SpaceKind, displayUUID: String,
        index: Int, isActive: Bool, tiles: [LiveTile] = []
    ) {
        self.id = id
        self.key = key
        self.kind = kind
        self.displayUUID = displayUUID
        self.index = index
        self.isActive = isActive
        self.tiles = tiles
    }
}

public struct LiveWindow: Equatable, Sendable {
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    public var bundleID: String?
    public var title: String
    public var frame: Rect
    public var isOnscreen: Bool
    public var spaceID: UInt64?
    public var isMinimized: Bool

    public init(
        id: UInt32, pid: Int32, appName: String, bundleID: String? = nil,
        title: String, frame: Rect, isOnscreen: Bool,
        spaceID: UInt64? = nil, isMinimized: Bool = false
    ) {
        self.id = id
        self.pid = pid
        self.appName = appName
        self.bundleID = bundleID
        self.title = title
        self.frame = frame
        self.isOnscreen = isOnscreen
        self.spaceID = spaceID
        self.isMinimized = isMinimized
    }
}

public struct LiveState: Equatable, Sendable {
    public var displays: [LiveDisplay]
    public var spaces: [LiveSpace]
    public var windows: [LiveWindow]

    public init(displays: [LiveDisplay], spaces: [LiveSpace], windows: [LiveWindow]) {
        self.displays = displays
        self.spaces = spaces
        self.windows = windows
    }

    public func space(id: UInt64?) -> LiveSpace? {
        guard let id else { return nil }
        return spaces.first { $0.id == id }
    }

    public func window(id: UInt32) -> LiveWindow? {
        windows.first { $0.id == id }
    }

    public func display(uuid: String) -> LiveDisplay? {
        displays.first { $0.uuid == uuid }
    }

    /// Spaces of one display in Mission Control order.
    public func spaces(onDisplay uuid: String) -> [LiveSpace] {
        spaces.filter { $0.displayUUID == uuid }.sorted { $0.index < $1.index }
    }

    public func desktops(onDisplay uuid: String) -> [LiveSpace] {
        spaces(onDisplay: uuid).filter { $0.kind == .desktop }
    }

    public func activeSpace(onDisplay uuid: String) -> LiveSpace? {
        spaces(onDisplay: uuid).first { $0.isActive }
    }
}
