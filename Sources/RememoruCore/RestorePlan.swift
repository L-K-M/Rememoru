import Foundation

/// A live window a restore step acts on.
public struct WindowTarget: Equatable, Sendable, CustomStringConvertible {
    public var id: UInt32
    public var pid: Int32
    public var appName: String
    public var title: String

    public init(_ window: LiveWindow) {
        id = window.id
        pid = window.pid
        appName = window.appName
        title = window.title
    }

    public var description: String {
        title.isEmpty ? "\(appName) window \(id)" : "\(appName) \u{201C}\(title)\u{201D}"
    }
}

/// A space the restore wants to show, resolved against live state when
/// the step runs (space ids change when desktops are created).
public enum SpaceTarget: Equatable, Sendable {
    /// The n-th desktop (0-based) of a display, in Mission Control order.
    case desktop(ordinal: Int)
    /// The fullscreen or Split View space holding this window.
    case spaceOf(window: UInt32)
}

public enum RestoreStep: Equatable, Sendable, CustomStringConvertible {
    case createDesktops(display: String, count: Int)
    case setMinimized(WindowTarget, Bool)
    case exitFullscreen(WindowTarget)
    case setFrame(WindowTarget, Rect)
    case moveToDesktop(WindowTarget, display: String, ordinal: Int)
    /// Fullscreen the window from the given desktop. macOS inserts a new
    /// fullscreen space right after the space the window was on, so the
    /// anchor desktop decides where the space lands in Mission Control.
    case enterFullscreen(WindowTarget, display: String, anchorOrdinal: Int)
    case splitView(left: WindowTarget, right: WindowTarget, display: String, anchorOrdinal: Int)
    /// Put the display's spaces in the snapshot's Mission Control order,
    /// if they are not already.
    case arrangeSpaces(snapshotDisplay: String, display: String)
    case focus(display: String, SpaceTarget)

    public var description: String {
        switch self {
        case .createDesktops(let display, let count):
            return "create \(count) desktop(s) on display \(display.prefix(8))"
        case .setMinimized(let window, let minimized):
            return "\(minimized ? "minimize" : "unminimize") \(window)"
        case .exitFullscreen(let window):
            return "exit fullscreen: \(window)"
        case .setFrame(let window, let frame):
            return String(format: "frame %@ -> (%.0f, %.0f) %.0f x %.0f",
                          window.description, frame.x, frame.y, frame.w, frame.h)
        case .moveToDesktop(let window, let display, let ordinal):
            return "move \(window) to desktop \(ordinal + 1) of display \(display.prefix(8))"
        case .enterFullscreen(let window, let display, let anchor):
            return "fullscreen \(window) after desktop \(anchor + 1) of display \(display.prefix(8))"
        case .splitView(let left, let right, let display, let anchor):
            return "split view \(left) | \(right) after desktop \(anchor + 1) of display \(display.prefix(8))"
        case .arrangeSpaces(_, let display):
            return "arrange spaces of display \(display.prefix(8)) in saved order"
        case .focus(let display, let target):
            switch target {
            case .desktop(let ordinal):
                return "show desktop \(ordinal + 1) on display \(display.prefix(8))"
            case .spaceOf(let window):
                return "show the space of window \(window) on display \(display.prefix(8))"
            }
        }
    }
}

public struct RestoreOptions: Equatable, Sendable {
    public enum DisplayFallback: String, Equatable, Sendable {
        /// Leave windows of disconnected displays alone.
        case skip
        /// Put them on the main display, same relative position.
        case mainDisplay
    }

    /// Open apps that have saved windows but are not running, before
    /// matching windows.
    public var launchApps = false
    public var createDesktops = true
    public var fullscreen = true
    public var splitView = true
    public var arrangeSpaces = true
    public var focus = true
    public var displayFallback = DisplayFallback.skip

    public init() {}
}

public struct RestorePlan: Equatable, Sendable {
    public var steps: [RestoreStep]
    /// Snapshot windows with no live counterpart.
    public var unmatched: [WindowRecord]
    /// Things the plan will not attempt, with the reason.
    public var notes: [String]
}

public enum RestorePlanner {
    /// Bundle ids of apps with saved windows that are not running, with the
    /// number of windows each had. Running apps are left alone even when
    /// they have no windows: opening them again only sends a reopen event,
    /// which shows an Open panel or a new empty window. Apps saved without
    /// a bundle id cannot be launched reliably and are left out.
    public static func appsToLaunch(snapshot: Snapshot, running: Set<String>) -> [String: Int] {
        var result: [String: Int] = [:]
        for window in snapshot.windows {
            guard let bundleID = window.bundleID, !running.contains(bundleID) else { continue }
            result[bundleID, default: 0] += 1
        }
        return result
    }

    public static func plan(
        snapshot: Snapshot,
        live: LiveState,
        matches: [Int: WindowMatch],
        options: RestoreOptions = RestoreOptions()
    ) -> RestorePlan {
        var steps: [RestoreStep] = []
        var notes: [String] = []
        let displayMap = mapDisplays(snapshot: snapshot, live: live, fallback: options.displayFallback)

        for display in snapshot.displays where displayMap[display.uuid] == nil {
            notes.append("display \(display.uuid.prefix(8)) is not connected; its windows stay where they are")
        }

        // Several snapshot displays can land on one live display (fallback).
        // Its own saved layout, else the first one mapped to it, decides
        // space order and focus; desktops cover the largest of them.
        var primary: [String: String] = [:]
        var neededDesktops: [(display: String, count: Int)] = []
        for display in snapshot.displays {
            guard let liveUUID = displayMap[display.uuid]?.uuid else { continue }
            if display.uuid == liveUUID || primary[liveUUID] == nil {
                primary[liveUUID] = display.uuid
            }
            let count = snapshot.desktopCount(onDisplay: display.uuid)
            if let index = neededDesktops.firstIndex(where: { $0.display == liveUUID }) {
                neededDesktops[index].count = max(neededDesktops[index].count, count)
            } else {
                neededDesktops.append((liveUUID, count))
            }
        }

        // 1. Desktops
        for (liveUUID, needed) in neededDesktops {
            let deficit = needed - live.desktops(onDisplay: liveUUID).count
            guard deficit > 0 else { continue }
            if options.createDesktops {
                steps.append(.createDesktops(display: liveUUID, count: deficit))
            } else {
                notes.append("display \(liveUUID.prefix(8)) needs \(deficit) more desktop(s); creation disabled")
            }
        }

        // 2. Windows that live on desktops
        for (index, saved) in snapshot.windows.enumerated() {
            guard let match = matches[index] else { continue }
            let window = match.live
            let ref = WindowTarget(window)
            guard let savedDisplay = saved.displayUUID,
                  let liveDisplay = displayMap[savedDisplay],
                  let snapDisplay = snapshot.displays.first(where: { $0.uuid == savedDisplay })
            else { continue }
            let liveSpace = live.space(id: window.spaceID)

            if saved.isMinimized == true {
                if !window.isMinimized { steps.append(.setMinimized(ref, true)) }
                continue
            }
            guard let savedSpace = snapshot.space(uuid: saved.spaceUUID), savedSpace.kind == .desktop,
                  let ordinal = snapshot.desktopOrdinal(ofSpace: savedSpace.uuid)
            else { continue }

            if window.isMinimized { steps.append(.setMinimized(ref, false)) }
            if let kind = liveSpace?.kind, kind == .fullscreen || kind == .splitView {
                steps.append(.exitFullscreen(ref))
            }
            let target = translate(saved.frame, from: snapDisplay.frame, to: liveDisplay.frame)
            if !window.frame.isClose(to: target) {
                steps.append(.setFrame(ref, target))
            }
            let liveDesktops = live.desktops(onDisplay: liveDisplay.uuid)
            let currentOrdinal = liveDesktops.firstIndex { $0.id == window.spaceID }
            if currentOrdinal != ordinal {
                steps.append(.moveToDesktop(ref, display: liveDisplay.uuid, ordinal: ordinal))
            }
        }

        // 3. Fullscreen and Split View spaces, per display. Spaces anchored
        // to the same desktop are created last-first: each new space is
        // inserted right after its anchor, pushing earlier ones right.
        for display in snapshot.displays {
            guard let liveDisplay = displayMap[display.uuid] else { continue }
            var anchor = 0
            var anchored: [(anchor: Int, space: SpaceRecord)] = []
            var seenDesktop = false
            for uuid in display.spaceUUIDs {
                guard let space = snapshot.space(uuid: uuid) else { continue }
                switch space.kind {
                case .desktop:
                    if seenDesktop { anchor += 1 }
                    seenDesktop = true
                case .fullscreen, .splitView:
                    anchored.append((anchor, space))
                case .other:
                    break
                }
            }
            let order = anchored.enumerated().sorted { a, b in
                a.element.anchor != b.element.anchor
                    ? a.element.anchor < b.element.anchor
                    : a.offset > b.offset
            }
            for (_, entry) in order {
                let space = entry.space
                let members = snapshot.windows.enumerated().filter { $0.element.spaceUUID == space.uuid }
                switch space.kind {
                case .fullscreen:
                    guard options.fullscreen else {
                        notes.append("fullscreen space \(space.uuid.prefix(8)) skipped (disabled)")
                        continue
                    }
                    guard let member = snapshot.primaryWindowIndex(onSpace: space.uuid),
                          let match = matches[member] else {
                        notes.append("fullscreen space \(space.uuid.prefix(8)): its window is gone")
                        continue
                    }
                    let current = live.space(id: match.live.spaceID)
                    if current?.kind == .fullscreen, current?.displayUUID == liveDisplay.uuid { continue }
                    let ref = WindowTarget(match.live)
                    // a Split View tile, or fullscreen on another display
                    if current?.kind.isFullscreenLike == true { steps.append(.exitFullscreen(ref)) }
                    if match.live.isMinimized { steps.append(.setMinimized(ref, false)) }
                    steps.append(.enterFullscreen(ref, display: liveDisplay.uuid, anchorOrdinal: entry.anchor))
                case .splitView:
                    guard options.splitView else {
                        notes.append("split view space \(space.uuid.prefix(8)) skipped (disabled)")
                        continue
                    }
                    let left = members.first { $0.element.splitSide == .left } ?? members.first
                    let right = members.first { $0.element.splitSide == .right && $0.offset != left?.offset }
                    guard let left, let right, let l = matches[left.offset], let r = matches[right.offset] else {
                        notes.append("split view space \(space.uuid.prefix(8)): a window of the pair is gone")
                        continue
                    }
                    let current = live.space(id: l.live.spaceID)
                    if current?.kind == .splitView, l.live.spaceID == r.live.spaceID,
                       current?.displayUUID == liveDisplay.uuid { continue }
                    for window in [l.live, r.live] {
                        let kind = live.space(id: window.spaceID)?.kind
                        if kind == .fullscreen || kind == .splitView {
                            steps.append(.exitFullscreen(WindowTarget(window)))
                        }
                        if window.isMinimized { steps.append(.setMinimized(WindowTarget(window), false)) }
                    }
                    steps.append(.splitView(
                        left: WindowTarget(l.live), right: WindowTarget(r.live),
                        display: liveDisplay.uuid, anchorOrdinal: entry.anchor
                    ))
                case .desktop, .other:
                    break
                }
            }
            // desktops are interchangeable by ordinal, so order only matters
            // when fullscreen or Split View spaces sit between them
            if options.arrangeSpaces, !anchored.isEmpty, primary[liveDisplay.uuid] == display.uuid {
                steps.append(.arrangeSpaces(snapshotDisplay: display.uuid, display: liveDisplay.uuid))
            }
        }

        // 4. Active space per display
        if options.focus {
            for display in snapshot.displays {
                guard let liveDisplay = displayMap[display.uuid], primary[liveDisplay.uuid] == display.uuid,
                      let active = snapshot.space(uuid: display.activeSpaceUUID) else { continue }
                switch active.kind {
                case .desktop:
                    if let ordinal = snapshot.desktopOrdinal(ofSpace: active.uuid) {
                        steps.append(.focus(display: liveDisplay.uuid, .desktop(ordinal: ordinal)))
                    }
                case .fullscreen, .splitView:
                    if let member = snapshot.primaryWindowIndex(onSpace: active.uuid), let match = matches[member] {
                        steps.append(.focus(display: liveDisplay.uuid, .spaceOf(window: match.live.id)))
                    }
                case .other:
                    break
                }
            }
        }

        let unmatched = snapshot.windows.indices.filter { matches[$0] == nil }.map { snapshot.windows[$0] }
        return RestorePlan(steps: steps, unmatched: unmatched, notes: notes)
    }

    /// Snapshot display uuid -> live display.
    public static func mapDisplays(
        snapshot: Snapshot, live: LiveState, fallback: RestoreOptions.DisplayFallback
    ) -> [String: LiveDisplay] {
        var map: [String: LiveDisplay] = [:]
        for display in snapshot.displays {
            if let same = live.display(uuid: display.uuid) {
                map[display.uuid] = same
            } else if fallback == .mainDisplay, let main = live.displays.first(where: \.isMain) ?? live.displays.first {
                map[display.uuid] = main
            }
        }
        return map
    }

    /// Keeps a frame's position relative to its display, so a display that
    /// moved in the arrangement (or a fallback display) still gets it. Only
    /// clamps when the display size changed; windows deliberately hanging
    /// over an edge of an unchanged display stay as saved.
    public static func translate(_ frame: Rect, from old: Rect, to new: Rect) -> Rect {
        let moved = Rect(x: frame.x - old.x + new.x, y: frame.y - old.y + new.y, w: frame.w, h: frame.h)
        if old.w == new.w, old.h == new.h { return moved }
        let w = min(frame.w, new.w)
        let h = min(frame.h, new.h)
        let x = min(max(moved.x, new.x), new.x + new.w - w)
        let y = min(max(moved.y, new.y), new.y + new.h - h)
        return Rect(x: x, y: y, w: w, h: h)
    }
}
