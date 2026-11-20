import Foundation

extension Spec {
    package struct Query: Hashable, Sendable {
        package let id: QueryID
        package let shape: Shape
    }

    /// The closed read set. A row belongs to the day it was written on, in the writer's calendar. `window`
    /// and `where` sit only on the cases that use them, so a windowed streak or a filtered daily cannot be
    /// written. A `where` field always belongs to the query's table, and a bool field with no value
    /// counts as false.
    package enum Shape: Hashable, Sendable {
        /// Rows in the window that match `where`. The look gets a number.
        case count(Table, where: FieldValue?, Window)
        /// The sum of a number field over rows in the window that match `where`. The table is the field's.
        /// A row with no value adds nothing. The look gets a number.
        case sum(Field<Double>, where: FieldValue?, Window)
        /// The newest row in the window that matches `where`. The look gets a row or null.
        case latest(Table, where: FieldValue?, Window)
        /// Up to `limit` rows in the window that match `where`, in `order`. The look gets a list of rows.
        case list(Table, where: FieldValue?, Order, limit: Int, Window)
        /// Consecutive days with at least one row, ending today, or ending yesterday while today has none.
        /// The look gets a number.
        case streak(Table)
        /// One entry per day for the last `days` days, oldest first and today last, each with that day's
        /// row count. The look gets a list of `{ date, weekday, count }`.
        case daily(Table, days: Int)

        package var table: TableID {
            switch self {
            case .count(let table, _, _), .latest(let table, _, _), .list(let table, _, _, _, _), .streak(let table),
                .daily(let table, _):
                table.id
            case .sum(let field, _, _): field.table
            }
        }
    }

    /// `today` is the reader's current day, `week` is the seven days from the calendar's first weekday
    /// that contain today, and `all` has no bound.
    package enum Window: String, CaseIterable, Hashable, Sendable {
        case today
        case week
        case all
    }

    /// Ties break newest first. A text, number, or date field with no value sorts last.
    package enum Order: Hashable, Sendable {
        case newest
        case oldest
        case field(AnyField, descending: Bool)
    }
}

extension Spec.Query {
    private enum Kind: String, CaseIterable {
        case count, sum, latest, list, streak, daily

        var keys: [String] {
            switch self {
            case .count: ["count", "where", "window"]
            case .sum: ["sum", "where", "window"]
            case .latest: ["latest", "where", "window"]
            case .list: ["limit", "list", "sort", "where", "window"]
            case .streak: ["streak"]
            case .daily: ["daily", "days"]
            }
        }

        func refusal(of key: String) -> String {
            switch (self, key) {
            case (.streak, "window"): "streak takes no \"window\"; it always counts back from today"
            case (.streak, "where"): "streak takes no \"where\"; it counts days that have any row"
            case (.daily, "window"): "daily takes no \"window\"; \"days\" sets how many days it covers"
            case (.daily, "where"): "daily takes no \"where\"; it counts every row of each day"
            default: "\(rawValue) takes no \(Diagnostic.quote(key)) (keys: \(keys.joined(separator: ", ")))"
            }
        }
    }

    static func parse(_ id: Spec.QueryID, _ json: JSONValue, _ resolver: Resolver) throws(Diagnostic) -> Spec.Query {
        do throws(Diagnostic) {
            let query = try Reader(
                json,
                else:
                    "a query must be an object like {\"count\": \"items\", \"window\": \"today\"}, not \(json.described)"
            )
            let kinds = Kind.allCases.filter { query.has($0.rawValue) }
            let shapeList = Kind.allCases.map(\.rawValue).joined(separator: ", ")
            guard let kind = kinds.first else {
                throw Diagnostic("needs one of \(shapeList), like {\"count\": \"items\", \"window\": \"today\"}")
            }
            guard kinds.count == 1 else {
                throw Diagnostic(
                    "has both \"\(kinds[0].rawValue)\" and \"\(kinds[1].rawValue)\"; use exactly one of \(shapeList)")
            }
            try query.requireOnly(kind.keys, else: kind.refusal)
            let target = query[kind.rawValue] ?? .null
            switch kind {
            case .count:
                let table = try resolver.table(target, for: "count")
                return Spec.Query(
                    id: id, shape: .count(table, where: try filter(query, table), try window(query, kind)))
            case .sum:
                let (table, field) = try resolver.field(target, for: "sum", of: Double.self)
                return Spec.Query(
                    id: id, shape: .sum(field, where: try filter(query, table), try window(query, kind)))
            case .latest:
                let table = try resolver.table(target, for: "latest")
                return Spec.Query(
                    id: id, shape: .latest(table, where: try filter(query, table), try window(query, kind)))
            case .list:
                let table = try resolver.table(target, for: "list")
                guard
                    let limit = try query.wholeNumber("limit", in: Spec.Limits.listLimit)
                else {
                    throw Diagnostic(
                        "list needs \"limit\": the most rows to return, a whole number from 1 to \(Spec.Limits.listLimit.upperBound)"
                    )
                }
                return Spec.Query(
                    id: id,
                    shape: .list(
                        table, where: try filter(query, table), try order(query["sort"], table), limit: limit,
                        try window(query, kind)))
            case .streak:
                return Spec.Query(id: id, shape: .streak(try resolver.table(target, for: "streak")))
            case .daily:
                let table = try resolver.table(target, for: "daily")
                guard let days = try query.wholeNumber("days", in: Spec.Limits.dailyDays) else {
                    throw Diagnostic(
                        "daily needs \"days\": how many days to cover, a whole number from 1 to \(Spec.Limits.dailyDays.upperBound)"
                    )
                }
                return Spec.Query(id: id, shape: .daily(table, days: days))
            }
        } catch {
            throw error.within("query \(Diagnostic.quote(id.raw))")
        }
    }

    private static func window(_ query: Reader, _ kind: Kind) throws(Diagnostic) -> Spec.Window {
        guard let value = query["window"] else {
            throw Diagnostic("\(kind.rawValue) needs \"window\": today, week, or all")
        }
        guard case .string(let raw) = value, let window = Spec.Window(rawValue: raw) else {
            throw Diagnostic("\"window\" must be today, week, or all, not \(value.described)")
        }
        return window
    }

    private static func filter(_ query: Reader, _ table: Spec.Table) throws(Diagnostic) -> Spec.FieldValue? {
        guard let value = query["where"] else { return nil }
        let example = "like {\"\(table.fields.first?.id.raw ?? "done")\": false}"
        let condition = try Reader(value, else: "where must be an object with one field and a value, \(example)")
        guard condition.keys.count == 1, let name = condition.keys.first, let literal = condition[name] else {
            throw Diagnostic(
                "where takes exactly one field and a value, \(example); found \(condition.keys.count) (\(condition.keys.joined(separator: ", ")))"
            )
        }
        guard let field = table.field(named: name) else {
            throw Diagnostic("where names no field \(Diagnostic.quote(name)) in \(table.id.raw) \(table.fieldChoices)")
        }
        guard field.kind != .date else {
            throw Diagnostic(
                "where cannot compare a date field (\"\(field.path)\"); compare a text, number, or bool field, or sort by the date"
            )
        }
        do throws(Diagnostic) {
            return try field.value(from: literal)
        } catch {
            throw error.within("where")
        }
    }

    private static func order(_ value: JSONValue?, _ table: Spec.Table) throws(Diagnostic) -> Spec.Order {
        guard let value else { return .newest }
        let refusal =
            "must be newest, oldest, or a field of \(table.id.raw) \(table.fieldChoices) with \"-\" in front to sort descending"
        guard case .string(let raw) = value else { throw Diagnostic("\"sort\" \(refusal), not \(value.described)") }
        switch raw {
        case "newest": return .newest
        case "oldest": return .oldest
        default:
            let descending = raw.hasPrefix("-")
            guard let field = table.field(named: descending ? String(raw.dropFirst()) : raw) else {
                throw Diagnostic("\"sort\" \(refusal), not \(value.described)")
            }
            return .field(field, descending: descending)
        }
    }

    var json: JSONValue {
        func windowed(_ key: String, _ target: String, _ filter: Spec.FieldValue?, _ window: Spec.Window) -> [String:
            JSONValue]
        {
            var members: [String: JSONValue] = [key: .string(target), "window": .string(window.rawValue)]
            if let filter { members["where"] = [filter].json }
            return members
        }
        switch shape {
        case .count(let table, let filter, let window):
            return .object(windowed("count", table.id.raw, filter, window))
        case .sum(let field, let filter, let window):
            return .object(windowed("sum", field.path, filter, window))
        case .latest(let table, let filter, let window):
            return .object(windowed("latest", table.id.raw, filter, window))
        case .list(let table, let filter, let order, let limit, let window):
            var members = windowed("list", table.id.raw, filter, window)
            members["limit"] = .number(Double(limit))
            members["sort"] = .string(order.raw)
            return .object(members)
        case .streak(let table):
            return .object(["streak": .string(table.id.raw)])
        case .daily(let table, let days):
            return .object(["daily": .string(table.id.raw), "days": .number(Double(days))])
        }
    }
}

extension Spec.Order {
    var raw: String {
        switch self {
        case .newest: "newest"
        case .oldest: "oldest"
        case .field(let field, let descending): (descending ? "-" : "") + field.id.raw
        }
    }
}
