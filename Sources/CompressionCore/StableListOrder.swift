import Foundation

/// Measurements can change immediately while navigation keeps its current
/// ordering until the caller commits the pending sort after an idle interval.
public struct StableListOrder<ID: Hashable> {
    public private(set) var ids: [ID] = []
    public private(set) var pending: [ID]?
    public init() {}

    public mutating func propose(_ proposed: [ID]) {
        let existing = Set(ids), incoming = Set(proposed)
        if ids.isEmpty || existing.isDisjoint(with: incoming) { apply(proposed); return }
        ids.removeAll { !incoming.contains($0) }
        ids.append(contentsOf: proposed.filter { !existing.contains($0) })
        pending = ids == proposed ? nil : proposed
    }

    public mutating func apply(_ proposed: [ID]) { ids = proposed; pending = nil }
    public mutating func commit() { if let pending { apply(pending) } }
}
