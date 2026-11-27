import WidgetEngine

/// The feed's rows: a wide widget fills a row, and smalls sit in pairs. A small waits past at most one wide
/// for a partner, so the order stays close to newest first and a row is rarely left half empty. The Templates
/// pile lays out its cards by the same rule.
enum FeedRow<ID: Hashable>: Equatable, Identifiable {
    case wide(ID)
    case pair(ID, ID?)

    var id: ID {
        switch self {
        case .wide(let id), .pair(let id, _): id
        }
    }

    static func rows(_ shown: [(id: ID, family: Family)]) -> [FeedRow] {
        var rows: [FeedRow] = []
        /// A small without a partner yet, the row it would have taken, and how many wides it has waited past.
        var waiting: (id: ID, at: Int, passed: Int)?
        for (id, family) in shown {
            switch family {
            case .medium:
                if let small = waiting {
                    if small.passed == 1 {
                        rows.insert(.pair(small.id, nil), at: small.at)
                        waiting = nil
                    } else {
                        waiting?.passed += 1
                    }
                }
                rows.append(.wide(id))
            case .small:
                if let small = waiting {
                    rows.append(.pair(small.id, id))
                    waiting = nil
                } else {
                    waiting = (id, rows.count, 0)
                }
            }
        }
        if let small = waiting { rows.insert(.pair(small.id, nil), at: small.at) }
        return rows
    }
}
