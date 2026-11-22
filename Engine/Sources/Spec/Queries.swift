import Foundation

extension Spec {
    package struct Query: Hashable, Sendable {
        package let id: QueryID
        package let shape: Shape
    }

    /// The closed read set. A row belongs to the day it was written on, in the writer's calendar. `window`
    /// sits only on the cases that read a window, so a windowed streak or daily cannot be written. A `where`
    /// field always belongs to the query's table, and a bool field with no value counts as false.
    package enum Shape: Hashable, Sendable {
        /// Rows in the window that match `where`. The look gets a number.
        case count(Table, where: Filter?, Window)
        /// The sum of a number field over rows in the window that match `where`. The table is the field's.
        /// A row with no value adds nothing. The look gets a number.
        case sum(Field<Double>, where: Filter?, Window)
        /// The newest row in the window that matches `where`. The look gets a row or null.
        case latest(Table, where: Filter?, Window)
        /// Up to `limit` rows in the window that match `where`, in `order`. The look gets a list of rows.
        case list(Table, where: Filter?, Order, limit: Int, Window)
        /// Consecutive days whose measure over rows matching `where` reaches `goal`, ending today, or ending
        /// yesterday while today has not reached it yet. The look gets a number.
        case streak(Measure, where: Filter?, goal: Double)
        /// One entry per day for the last `days` days, oldest first and today last, with that day's count of
        /// rows matching `where` and, for a field measure, their sum. The look gets a list of
        /// `{ date, weekday, count }`, with `sum` added for a field measure.
        case daily(Measure, where: Filter?, days: Int)

        package var table: TableID {
            switch self {
            case .count(let table, _, _), .latest(let table, _, _), .list(let table, _, _, _, _): table.id
            case .sum(let field, _, _): field.table
            case .streak(let measure, _, _), .daily(let measure, _, _): measure.table
            }
        }
    }

    /// Who wrote a row, as a `where` asks it: the person on this device, or anyone else who shares the data.
    package enum Author: String, Hashable, Sendable, CaseIterable {
        case me
        case others
    }

    /// A `where`: rows whose field equals a value, rows by an author, or both. At least one is set.
    package struct Filter: Hashable, Sendable {
        package let field: FieldValue?
        package let by: Author?

        init(field: FieldValue?, by: Author?) {
            self.field = field
            self.by = by
        }

        var json: JSONValue {
            var members: [String: JSONValue] = [:]
            if let field { members[field.field.id.raw] = field.value.json }
            if let by { members["by"] = .string(by.rawValue) }
            return .object(members)
        }
    }

    /// What one day is worth to `streak` and `daily`: how many rows it has, or the sum of a number field over
    /// them. A row with no value adds nothing to a sum.
    package enum Measure: Hashable, Sendable {
        case rows(Table)
        case total(Field<Double>)

        package var table: TableID {
            switch self {
            case .rows(let table): table.id
            case .total(let field): field.table
            }
        }
    }

    /// `today` is the reader's current day, `week` is the seven days from the calendar's first weekday that
    /// contain today, `month` is the calendar month that contains today, `days` is the last that many days
    /// with today last, and `all` has no bound.
    package enum Window: Hashable, Sendable {
        case today
        case week
        case month
        case days(Int)
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
            case .streak: ["goal", "streak", "where"]
            case .daily: ["daily", "days", "where"]
            }
        }

        func refusal(of key: String) -> String {
            switch (self, key) {
            case (.streak, "window"): "streak takes no \"window\"; it always counts back from today"
            case (.daily, "window"): "daily takes no \"window\"; \"days\" sets how many days it covers"
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
                let (measure, table) = try self.measure(target, for: "streak", resolver)
                return Spec.Query(
                    id: id,
                    shape: .streak(measure, where: try filter(query, table), goal: try goal(query, measure, target)))
            case .daily:
                let (measure, table) = try self.measure(target, for: "daily", resolver)
                guard let days = try query.wholeNumber("days", in: Spec.Limits.dailyDays) else {
                    throw Diagnostic(
                        "daily needs \"days\": how many days to cover, a whole number from 1 to \(Spec.Limits.dailyDays.upperBound)"
                    )
                }
                return Spec.Query(id: id, shape: .daily(measure, where: try filter(query, table), days: days))
            }
        } catch {
            throw error.within("query \(Diagnostic.quote(id.raw))")
        }
    }

    private static let windowChoices =
        "today, week, month, all, or {\"days\": 7} for the last 7 days with today last"

    private static func window(_ query: Reader, _ kind: Kind) throws(Diagnostic) -> Spec.Window {
        guard let value = query["window"] else {
            throw Diagnostic("\(kind.rawValue) needs \"window\": \(windowChoices)")
        }
        switch value {
        case .string("today"): return .today
        case .string("week"): return .week
        case .string("month"): return .month
        case .string("all"): return .all
        case .object:
            do throws(Diagnostic) {
                let window = try Reader(value, else: "")
                try window.requireOnly(["days"]) { "takes only \"days\", not \(Diagnostic.quote($0))" }
                guard let days = try window.wholeNumber("days", in: Spec.Limits.dailyDays) else {
                    throw Diagnostic("needs \"days\": how many days back from today, like {\"days\": 7}")
                }
                return .days(days)
            } catch {
                throw error.within("window")
            }
        default:
            throw Diagnostic("\"window\" must be \(windowChoices), not \(value.described)")
        }
    }

    /// A table counts rows per day. `"table.field"` sums a number field per day.
    private static func measure(_ target: JSONValue, for key: String, _ resolver: Resolver) throws(Diagnostic) -> (
        Spec.Measure, Spec.Table
    ) {
        if case .string(let raw) = target, raw.contains(".") {
            let (table, field) = try resolver.field(target, for: key, of: Double.self)
            return (.total(field), table)
        }
        let table = try resolver.table(target, for: key)
        return (.rows(table), table)
    }

    /// A row measure's goal is a whole number of rows, 1 when left out. A field measure must say what total
    /// counts as a day kept.
    private static func goal(_ query: Reader, _ measure: Spec.Measure, _ target: JSONValue) throws(Diagnostic)
        -> Double
    {
        if case .rows = measure { return Double(try query.wholeNumber("goal", in: Spec.Limits.rowGoal) ?? 1) }
        guard let value = query["goal"] else {
            guard case .total(let field) = measure else { return 1 }
            throw Diagnostic(
                "a streak of \"\(field.path)\" needs \"goal\": the day's total that keeps the streak, like {\"streak\": \"\(field.path)\", \"goal\": 2000}"
            )
        }
        guard case .number(let goal) = value, goal > 0, goal <= Spec.Limits.goal else {
            throw Diagnostic(
                "\"goal\" must be a number above 0 and at most \(Int(Spec.Limits.goal)), like 8, not \(value.described)"
            )
        }
        return goal
    }

    private static func filter(_ query: Reader, _ table: Spec.Table) throws(Diagnostic) -> Spec.Filter? {
        guard let value = query["where"] else { return nil }
        let example = "like {\"\(table.fields.first?.id.raw ?? "done")\": false} or {\"by\": \"me\"}"
        let condition = try Reader(
            value, else: "where must be an object with one field and a value, \"by\", or both, \(example)")
        let names = condition.keys.filter { $0 != "by" }
        guard names.count <= 1, !condition.keys.isEmpty else {
            throw Diagnostic(
                "where takes at most one field and a value, plus \"by\", \(example); found \(condition.keys.count) (\(condition.keys.joined(separator: ", ")))"
            )
        }
        var by: Spec.Author?
        if let author = condition["by"] {
            guard case .string(let raw) = author, let parsed = Spec.Author(rawValue: raw) else {
                throw Diagnostic(
                    "where \"by\" must be \"me\" (rows written on this phone) or \"others\" (rows written by anyone the widget is shared with), not \(author.described)"
                )
            }
            by = parsed
        }
        guard let name = names.first, let literal = condition[name] else {
            return Spec.Filter(field: nil, by: by)
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
            return Spec.Filter(field: try field.value(from: literal), by: by)
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
        func filtered(_ key: String, _ target: String, _ filter: Spec.Filter?) -> [String: JSONValue] {
            var members: [String: JSONValue] = [key: .string(target)]
            if let filter { members["where"] = filter.json }
            return members
        }
        func windowed(_ key: String, _ target: String, _ filter: Spec.Filter?, _ window: Spec.Window) -> [String:
            JSONValue]
        {
            var members = filtered(key, target, filter)
            members["window"] = window.json
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
        case .streak(let measure, let filter, let goal):
            var members = filtered("streak", measure.raw, filter)
            // A row measure's default goal is left out, so a plain streak keeps its canonical bytes.
            let isDefault: Bool =
                switch measure {
                case .rows: goal == 1
                case .total: false
                }
            if !isDefault { members["goal"] = .number(goal) }
            return .object(members)
        case .daily(let measure, let filter, let days):
            var members = filtered("daily", measure.raw, filter)
            members["days"] = .number(Double(days))
            return .object(members)
        }
    }
}

extension Spec.Measure {
    var raw: String {
        switch self {
        case .rows(let table): table.id.raw
        case .total(let field): field.path
        }
    }
}

extension Spec.Window {
    var json: JSONValue {
        switch self {
        case .today: .string("today")
        case .week: .string("week")
        case .month: .string("month")
        case .days(let days): .object(["days": .number(Double(days))])
        case .all: .string("all")
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
