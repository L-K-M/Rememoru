/// Searches for a Space by confirmed IDs when Dock's navigation order can
/// differ from WindowServer's reported array. Use the array only to choose
/// the first direction, then reverse once at an edge instead of oscillating.
public struct SpaceTraversal {
    public enum Direction: Int {
        case left = -1
        case right = 1
    }

    public private(set) var orderMatchesNavigation = true
    private var direction: Direction
    private var reversed = false
    private var remaining: Int

    public init?(orderedIDs: [UInt64], activeID: UInt64, targetID: UInt64) {
        guard let active = orderedIDs.firstIndex(of: activeID),
              let target = orderedIDs.firstIndex(of: targetID), active != target else { return nil }
        direction = target > active ? .right : .left
        remaining = orderedIDs.count * 2
    }

    public mutating func nextDirection() -> Direction? {
        guard remaining > 0 else { return nil }
        remaining -= 1
        return direction
    }

    /// nil means no active-Space change was confirmed within the hop wait.
    /// A second such boundary ends the sweep. Unexpected hops also prohibit
    /// selecting a Mission Control thumbnail by the reported array index.
    public mutating func observe(from previousID: UInt64, to activeID: UInt64?, orderedIDs: [UInt64]) -> Bool {
        guard let activeID, activeID != previousID else {
            guard !reversed else { return false }
            reversed = true
            direction = direction == .left ? .right : .left
            return true
        }
        if let previous = orderedIDs.firstIndex(of: previousID),
           let active = orderedIDs.firstIndex(of: activeID), active == previous + direction.rawValue {
            return true
        }
        orderMatchesNavigation = false
        return true
    }
}
