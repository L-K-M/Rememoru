import Foundation

/// Spaces parsed from `SLSCopyManagedDisplaySpaces`, plus the lookup tables
/// needed to attribute windows on fullscreen and Split View spaces.
public struct ManagedSpaces: Equatable, Sendable {
    public var spaces: [LiveSpace]
    /// Tile sub-space id -> outer space id. On macOS 26 windows on
    /// fullscreen and Split View spaces report the tile id, not the space
    /// Mission Control shows.
    public var tileParents: [UInt64: UInt64]
    /// Window id -> outer space id, from the tile/fullscreen window fields.
    /// Authoritative for windows that fill a fullscreen or tiled space.
    public var tileWindowSpaces: [UInt32: UInt64]

    public init(spaces: [LiveSpace], tileParents: [UInt64: UInt64], tileWindowSpaces: [UInt32: UInt64]) {
        self.spaces = spaces
        self.tileParents = tileParents
        self.tileWindowSpaces = tileWindowSpaces
    }

    /// The space a window lives on, given the ids `SLSCopySpacesForWindows`
    /// reported for that single window. Returns nil for windows on no known
    /// space (minimized, hidden) and for windows shown on every desktop.
    public func resolveSpace(windowID: UInt32, reported: [UInt64]) -> UInt64? {
        if let outer = tileWindowSpaces[windowID] {
            return outer
        }
        let known = Set(spaces.map(\.id))
        var resolved: [UInt64] = []
        for id in reported {
            let outer = tileParents[id] ?? id
            if known.contains(outer), !resolved.contains(outer) {
                resolved.append(outer)
            }
        }
        return resolved.count == 1 ? resolved[0] : nil
    }
}

public enum SpaceParser {
    /// Raw SkyLight space type numbers (macOS 15/26).
    public enum RawType {
        public static let desktop = 0
        public static let fullscreen = 4
    }

    /// Parses the `SLSCopyManagedDisplaySpaces` array.
    ///
    /// macOS 26 reports every fullscreen-like space as type 4. A Split View
    /// pair is a type 4 space whose `TileLayoutManager.TileSpaces` has two or
    /// more entries; a solo fullscreen window has exactly one.
    ///
    /// - Parameter spaceType: fallback for dictionaries without a `type`.
    public static func parse(
        _ displays: [[String: Any]],
        spaceType: (UInt64) -> Int? = { _ in nil }
    ) -> ManagedSpaces {
        var spaces: [LiveSpace] = []
        var tileParents: [UInt64: UInt64] = [:]
        var tileWindowSpaces: [UInt32: UInt64] = [:]
        var usedKeys = Set<String>()

        for display in displays {
            guard let displayUUID = display["Display Identifier"] as? String else { continue }
            let current = (display["Current Space"] as? [String: Any])
                .flatMap { uint64($0["ManagedSpaceID"]) }
            let rawSpaces = display["Spaces"] as? [[String: Any]] ?? []

            for (index, raw) in rawSpaces.enumerated() {
                guard let id = uint64(raw["ManagedSpaceID"]) ?? uint64(raw["id64"]) else { continue }
                let rawType = int(raw["type"]) ?? spaceType(id) ?? -1
                let layoutManager = raw["TileLayoutManager"] as? [String: Any] ?? [:]
                let rawTiles = layoutManager["TileSpaces"] as? [[String: Any]] ?? []
                let layoutX = double((layoutManager["Layout Rect"] as? [String: Any])?["X"]) ?? 0

                var tiles: [LiveTile] = []
                for tile in rawTiles {
                    // ManagedSpaceID and id64 of a tile may differ; windows
                    // can report either, so map both to the outer space
                    for key in ["id64", "ManagedSpaceID"] {
                        if let tileID = uint64(tile[key]) {
                            tileParents[tileID] = id
                        }
                    }
                    let windowID = uint32(tile["TileWindowID"]) ?? uint32(tile["fs_wid"])
                    if let windowID {
                        tileWindowSpaces[windowID] = id
                    }
                    let tileX = double((tile["TileRect"] as? [String: Any])?["X"])
                    let side: SplitSide = (tileX.map { $0 <= layoutX + 1 } ?? true) ? .left : .right
                    tiles.append(LiveTile(
                        windowID: windowID,
                        appName: tile["appName"] as? String,
                        title: tile["name"] as? String,
                        side: side
                    ))
                }
                if rawType == RawType.fullscreen, let windowID = uint32(raw["fs_wid"]),
                   tileWindowSpaces[windowID] == nil {
                    tileWindowSpaces[windowID] = id
                }

                let kind: SpaceKind
                switch rawType {
                case RawType.desktop: kind = .desktop
                case RawType.fullscreen: kind = rawTiles.count >= 2 ? .splitView : .fullscreen
                default: kind = .other("type\(rawType)")
                }

                var key = raw["uuid"] as? String ?? ""
                if key.isEmpty || usedKeys.contains(key) {
                    key = "id:\(id)"
                }
                usedKeys.insert(key)

                spaces.append(LiveSpace(
                    id: id,
                    key: key,
                    kind: kind,
                    displayUUID: displayUUID,
                    index: index,
                    isActive: id == current,
                    tiles: tiles
                ))
            }
        }
        return ManagedSpaces(spaces: spaces, tileParents: tileParents, tileWindowSpaces: tileWindowSpaces)
    }
}

// MARK: - Loose number extraction

// Property-list numbers arrive as NSNumber on macOS and as either NSNumber
// or Swift numerics from JSONSerialization on Linux.

func int(_ value: Any?) -> Int? {
    switch value {
    case let number as NSNumber: return number.intValue
    case let number as Int: return number
    case let number as Double: return Int(exactly: number.rounded())
    default: return nil
    }
}

func uint64(_ value: Any?) -> UInt64? {
    switch value {
    case let number as NSNumber: return number.int64Value >= 0 ? number.uint64Value : nil
    case let number as Int: return number >= 0 ? UInt64(number) : nil
    case let number as UInt64: return number
    default: return nil
    }
}

func uint32(_ value: Any?) -> UInt32? {
    guard let wide = uint64(value) else { return nil }
    return UInt32(exactly: wide)
}

func double(_ value: Any?) -> Double? {
    switch value {
    case let number as NSNumber: return number.doubleValue
    case let number as Double: return number
    case let number as Int: return Double(number)
    default: return nil
    }
}
