/// Learns thumbnail order by selection, then checks the mapping in reverse.
/// A complete first pass alone can contain delayed active-Space readings.
public struct SpaceThumbnailSurvey: Sendable {
    public private(set) var order: [UInt64]?
    public private(set) var failed = false
    private let known: Set<UInt64>
    private let indices: [Int]
    private var offset = 0
    private var pending: Int?
    private var selected: [UInt64] = []

    public init?(knownIDs: [UInt64]) {
        known = Set(knownIDs)
        guard !known.isEmpty, known.count == knownIDs.count else { return nil }
        let forward = Array(knownIDs.indices)
        indices = forward + forward.reversed()
    }

    public mutating func nextIndex() -> Int? {
        guard order == nil, !failed else { return nil }
        guard pending == nil, offset < indices.count else { failed = true; return nil }
        let index = indices[offset]
        offset += 1
        pending = index
        return index
    }

    /// Check a reading without consuming the pending selection, so a native
    /// action whose effect was not confirmed can be retried at the same index.
    public func accepts(activeID: UInt64?) -> Bool {
        guard order == nil, !failed, let index = pending, let activeID, known.contains(activeID) else { return false }
        return offset <= known.count ? !selected.contains(activeID) : selected[index] == activeID
    }

    public mutating func observe(activeID: UInt64?) -> Bool {
        guard order == nil, !failed else { return order != nil }
        guard accepts(activeID: activeID), let activeID else { failed = true; return false }
        pending = nil
        if offset <= known.count {
            selected.append(activeID)
        }
        if offset == indices.count { order = selected }
        return true
    }
}
