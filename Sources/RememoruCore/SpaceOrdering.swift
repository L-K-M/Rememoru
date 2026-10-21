/// Reorders saved Spaces within their existing slots, preserving Spaces
/// that were not part of the saved layout.
public enum SpaceOrdering {
    public struct Move: Equatable, Sendable {
        public let spaceID: UInt64
        public let beforeID: UInt64
        public let expectedOrder: [UInt64]
    }

    public static func moves(current: [UInt64], desired: [UInt64]) -> [Move]? {
        let currentIDs = Set(current)
        let desiredIDs = Set(desired)
        guard currentIDs.count == current.count, desiredIDs.count == desired.count,
              desiredIDs.isSubset(of: currentIDs) else { return nil }
        var target = current
        var next = desired.makeIterator()
        for index in target.indices where desiredIDs.contains(target[index]) {
            guard let id = next.next() else { return nil }
            target[index] = id
        }
        var working = current
        var result: [Move] = []
        for index in target.indices where working[index] != target[index] {
            guard let source = working.firstIndex(of: target[index]), source > index else { return nil }
            let before = working[index]
            let id = working.remove(at: source)
            working.insert(id, at: index)
            result.append(Move(spaceID: id, beforeID: before, expectedOrder: working))
        }
        return result
    }

    /// Applies independently verified display orders to a capture. Reject a
    /// partial or stale reading rather than saving an invented sequence.
    public static func applying(_ orders: [String: [UInt64]], to state: LiveState) -> LiveState? {
        guard Set(orders.keys).isSubset(of: Set(state.displays.map(\.uuid))) else { return nil }
        var result = state
        for (display, order) in orders {
            let known = state.spaces(onDisplay: display).filter { $0.kind.isRestorable }.map(\.id)
            guard Set(order).count == order.count, Set(known) == Set(order), known.count == order.count else {
                return nil
            }
            let positions = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($0.element, $0.offset) })
            for index in result.spaces.indices where result.spaces[index].displayUUID == display {
                if let position = positions[result.spaces[index].id] { result.spaces[index].index = position }
            }
        }
        return result
    }
}

/// Discovers Dock's actual Space order by a bounded left sweep followed
/// by a right sweep. WindowServer's array is only a membership check.
public struct SpaceOrderSurvey {
    public enum Direction: Int { case left = -1, right = 1 }
    public private(set) var order: [UInt64]?
    public private(set) var failed = false
    private let knownIDs: Set<UInt64>
    private var activeID: UInt64
    private var direction = Direction.left
    private var visitedLeft: Set<UInt64>
    private var visitedRight: [UInt64] = []
    private var awaitingEdgeConfirmation = false
    private var remaining: Int

    public init?(knownIDs: [UInt64], activeID: UInt64) {
        let known = Set(knownIDs)
        guard known.count == knownIDs.count, known.contains(activeID) else { return nil }
        self.knownIDs = known
        self.activeID = activeID
        visitedLeft = [activeID]
        remaining = known.count * 2 + 2
        if known.count == 1 { order = [activeID] }
    }

    public mutating func nextDirection() -> Direction? {
        guard order == nil, !failed else { return nil }
        guard remaining > 0 else { failed = true; return nil }
        remaining -= 1
        return direction
    }

    /// Two stationary hops confirm the left edge. A single dropped gesture
    /// must not reverse a sweep. Missing or unexpected IDs never count as
    /// a boundary, and the right sweep must still visit every known Space.
    public mutating func observe(activeID next: UInt64?) -> Bool {
        guard order == nil, !failed else { return order != nil }
        guard let next, knownIDs.contains(next) else {
            failed = true
            return false
        }
        switch direction {
        case .left:
            if next == activeID {
                if awaitingEdgeConfirmation {
                    direction = .right
                    visitedRight = [next]
                } else {
                    awaitingEdgeConfirmation = true
                }
            } else {
                awaitingEdgeConfirmation = false
                if !visitedLeft.insert(next).inserted { failed = true }
            }
        case .right:
            if next == activeID || visitedRight.contains(next) {
                failed = true
            } else {
                visitedRight.append(next)
                if visitedRight.count == knownIDs.count { order = visitedRight }
            }
        }
        activeID = next
        return !failed
    }
}

/// Drops into a gap in the Spaces bar, outside every thumbnail. Dropping
/// onto another fullscreen thumbnail can create Split View instead.
public enum SpaceDragGeometry {
    public struct Path: Equatable, Sendable {
        public let startX: Double
        public let startY: Double
        public let endX: Double
        public let endY: Double
    }

    public static func path(from source: Int, before target: Int, frames: [Rect], inside bar: Rect) -> Path? {
        guard frames.indices.contains(source), frames.indices.contains(target), source > target,
              valid(bar), frames.allSatisfy({ valid($0) && contains($0, in: bar) }) else { return nil }
        for (left, right) in zip(frames, frames.dropFirst()) {
            guard left.x + left.w < right.x else { return nil }
        }
        let destination = frames[target]
        let x = target == 0 ? destination.x - min(12, destination.w * 0.1)
            : (frames[target - 1].x + frames[target - 1].w + destination.x) / 2
        let y = destination.midY
        guard bar.contains(x: x, y: y), !frames.contains(where: { $0.contains(x: x, y: y) }) else { return nil }
        return Path(startX: frames[source].midX, startY: frames[source].midY, endX: x, endY: y)
    }

    private static func valid(_ frame: Rect) -> Bool {
        [frame.x, frame.y, frame.w, frame.h].allSatisfy(\.isFinite) && frame.w > 0 && frame.h > 0
    }

    private static func contains(_ frame: Rect, in bar: Rect) -> Bool {
        frame.x >= bar.x && frame.y >= bar.y && frame.x + frame.w <= bar.x + bar.w
            && frame.y + frame.h <= bar.y + bar.h
    }
}
