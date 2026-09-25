import Foundation

public enum SnapshotBuilder {
    /// Builds a snapshot from live state. Windows that sit on no single
    /// known space (hidden helper windows, windows shown on all desktops)
    /// are left out unless minimized: there is nothing to restore for them.
    public static func build(from state: LiveState, created: String) -> Snapshot {
        let restorable = state.spaces.filter { $0.kind.isRestorable }
        let spaceByID = Dictionary(restorable.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })

        let displays = state.displays.map { display -> DisplayRecord in
            let spaces = state.spaces(onDisplay: display.uuid).filter { $0.kind.isRestorable }
            return DisplayRecord(
                uuid: display.uuid,
                frame: display.frame,
                isMain: display.isMain,
                spaceUUIDs: spaces.map(\.key),
                activeSpaceUUID: spaces.first { $0.isActive }?.key
            )
        }

        var windows: [WindowRecord] = []
        for window in state.windows {
            let space = window.spaceID.flatMap { spaceByID[$0] }
            guard space != nil || window.isMinimized else { continue }
            let displayUUID = space?.displayUUID
                ?? state.displays.first { $0.frame.contains(x: window.frame.midX, y: window.frame.midY) }?.uuid
            windows.append(WindowRecord(
                windowID: window.id,
                pid: window.pid,
                appName: window.appName,
                bundleID: window.bundleID,
                title: window.title,
                frame: window.frame,
                spaceUUID: space?.key,
                displayUUID: displayUUID,
                isMinimized: window.isMinimized ? true : nil
            ))
        }
        assignSplitSides(&windows, spaces: restorable)

        return Snapshot(
            created: created,
            displays: displays,
            spaces: restorable.map {
                SpaceRecord(
                    uuid: $0.key, id: $0.id, kind: $0.kind,
                    displayUUID: $0.displayUUID, index: $0.index, isActive: $0.isActive
                )
            },
            windows: windows
        )
    }

    /// Side per window on a Split View space: the tile metadata when it
    /// names the window, otherwise left-to-right frame order.
    static func assignSplitSides(_ windows: inout [WindowRecord], spaces: [LiveSpace]) {
        for space in spaces where space.kind == .splitView {
            let tileSide = Dictionary(
                space.tiles.compactMap { tile in tile.windowID.map { ($0, tile.side) } },
                uniquingKeysWith: { a, _ in a }
            )
            var leftover: [Int] = []
            for index in windows.indices where windows[index].spaceUUID == space.key {
                if let side = tileSide[windows[index].windowID] {
                    windows[index].splitSide = side
                } else {
                    leftover.append(index)
                }
            }
            let taken = Set(tileSide.values)
            let free = [SplitSide.left, .right].filter { !taken.contains($0) }
            let byX = leftover.sorted { windows[$0].frame.x < windows[$1].frame.x }
            for (side, index) in zip(free, byX) {
                windows[index].splitSide = side
            }
        }
    }
}

extension SpaceKind {
    public var isRestorable: Bool {
        if case .other = self { return false }
        return true
    }

    public var isFullscreenLike: Bool {
        self == .fullscreen || self == .splitView
    }
}
