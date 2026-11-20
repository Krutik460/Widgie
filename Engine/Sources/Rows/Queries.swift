import Foundation
import GRDB
import Spec

// The read side. Every shape starts from one `Selection`: the live rows of the dataset (widget, table) is bound
// to, narrowed by a day window and a `where`. The binding is a scalar subquery SQLite runs once, so the partial
// index `row_live(dataset, day, at) WHERE deleted IS NULL` serves the selection, the day windows, and the newest
// and oldest orders. A table with no binding selects nothing.

/// Live rows of the dataset one table of one widget is bound to, as a WHERE clause over `row r`.
private struct Selection {
    let sql: String
    let arguments: StatementArguments

    init(widget: WidgetKey, table: Spec.TableID, days: ClosedRange<Day>? = nil, matching filter: Spec.FieldValue? = nil)
    {
        var sql = "r.dataset = (SELECT dataset FROM binding WHERE widget = ? AND tbl = ?) AND r.deleted IS NULL"
        var arguments: StatementArguments = [widget.raw, table.raw]
        if let days {
            sql += " AND r.day BETWEEN ? AND ?"
            arguments += [days.lowerBound.index, days.upperBound.index]
        }
        if let filter {
            sql += " AND coalesce((SELECT c.value FROM cell c WHERE c.row = r.key AND c.field = ?), ?) = ?"
            arguments += [
                filter.field.id.raw, filter.field.kind == .bool ? 0 : nil, filter.value.stored.databaseValue,
            ]
        }
        self.sql = sql
        self.arguments = arguments
    }
}

extension Spec.Window {
    fileprivate func days(_ today: Today) -> ClosedRange<Day>? {
        switch self {
        case .today: today.day...today.day
        case .week: today.weekStart...today.weekStart.adding(6)
        case .month: today.day.month
        case .days(let count): today.day.adding(1 - count)...today.day
        case .all: nil
        }
    }
}

func evaluate(_ shape: Spec.Shape, widget: WidgetKey, today: Today, _ db: Database) throws -> QueryResult {
    switch shape {
    case .count(let table, let filter, let window):
        let rows = Selection(widget: widget, table: table.id, days: window.days(today), matching: filter)
        return .number(
            Double(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM row r WHERE \(rows.sql)", arguments: rows.arguments)
                    ?? 0))
    case .sum(let field, let filter, let window):
        let rows = Selection(widget: widget, table: field.table, days: window.days(today), matching: filter)
        let total = try Double.fetchOne(
            db, sql: "SELECT total(v.value) FROM row r JOIN cell v ON v.row = r.key AND v.field = ? WHERE \(rows.sql)",
            arguments: [field.id.raw] + rows.arguments)
        return .number(total ?? 0)
    case .latest(let table, let filter, let window):
        let rows = Selection(widget: widget, table: table.id, days: window.days(today), matching: filter)
        return .row(try list(table, rows, .newest, limit: 1, db).first)
    case .list(let table, let filter, let order, let limit, let window):
        let rows = Selection(widget: widget, table: table.id, days: window.days(today), matching: filter)
        return .rows(try list(table, rows, order, limit: limit, db))
    case .streak(let measure, let filter, let goal):
        let rows = Selection(widget: widget, table: measure.table, matching: filter)
        let totals = DayTotals(measure, rows)
        let days = try Int.fetchCursor(
            db,
            sql: "SELECT day FROM (\(totals.sql) AND r.day <= ? GROUP BY r.day) WHERE measure >= ? ORDER BY day DESC",
            arguments: totals.arguments + [today.day.index, goal])
        guard let newest = try days.next(), newest >= today.day.index - 1 else { return .number(0) }
        var streak = 1
        var previous = newest
        while let day = try days.next(), day == previous - 1 {
            streak += 1
            previous = day
        }
        return .number(Double(streak))
    case .daily(let measure, let filter, let count):
        let first = today.day.adding(1 - count)
        let totals = DayTotals(
            measure, Selection(widget: widget, table: measure.table, days: first...today.day, matching: filter))
        var found: [Int: Row] = [:]
        for row in try Row.fetchAll(db, sql: "\(totals.sql) GROUP BY r.day", arguments: totals.arguments) {
            found[row["day"]] = row
        }
        let sums: Bool = if case .total = measure { true } else { false }
        return .days(
            (0..<count).map { offset in
                let day = first.adding(offset)
                let row = found[day.index]
                return DayCount(day: day, count: row?["count"] ?? 0, sum: sums ? row?["measure"] ?? 0 : nil)
            })
    }
}

/// Each selected day's `day`, `count` of rows, and `measure`: the count again, or the sum of the measured
/// field. A statement up to its WHERE clause, so callers add more conditions, then `GROUP BY r.day`.
private struct DayTotals {
    let sql: String
    let arguments: StatementArguments

    init(_ measure: Spec.Measure, _ rows: Selection) {
        switch measure {
        case .rows:
            sql = "SELECT r.day AS day, count(*) AS count, count(*) AS measure FROM row r WHERE \(rows.sql)"
            arguments = rows.arguments
        case .total(let field):
            sql = """
                SELECT r.day AS day, count(*) AS count, total(v.value) AS measure FROM row r
                LEFT JOIN cell v ON v.row = r.key AND v.field = ? WHERE \(rows.sql)
                """
            arguments = [field.id.raw] + rows.arguments
        }
    }
}

/// Up to `limit` selected rows in `order`, with their values: one statement for the keys, one for their cells.
private func list(_ table: Spec.Table, _ rows: Selection, _ order: Spec.Order, limit: Int, _ db: Database) throws
    -> [RowValue]
{
    let newest = "r.day DESC, r.at DESC, r.key DESC"
    var join = ""
    var arguments: StatementArguments = []
    let sorting: String
    switch order {
    case .newest:
        sorting = newest
    case .oldest:
        sorting = "r.day, r.at, r.key"
    case .field(let field, let descending):
        join = "LEFT JOIN cell s ON s.row = r.key AND s.field = ?"
        arguments = [field.id.raw]
        let direction = descending ? " DESC" : ""
        sorting =
            switch field.kind {
            case .bool: "coalesce(s.value, 0)\(direction), \(newest)"
            case .text: "s.value IS NULL, s.value COLLATE NOCASE\(direction), \(newest)"
            case .number, .date: "s.value IS NULL, s.value\(direction), \(newest)"
            }
    }
    let keyed = try Row.fetchAll(
        db, sql: "SELECT r.key, r.day FROM row r \(join) WHERE \(rows.sql) ORDER BY \(sorting) LIMIT ?",
        arguments: arguments + rows.arguments + [limit])
    let found: [(key: RowKey, day: Day)] = keyed.compactMap { row in
        RowKey(parsing: row["key"]).map { ($0, Day(index: row["day"])) }
    }
    let values = try cells(of: found.map(\.key), in: table, db)
    return found.map { RowValue(key: $0.key, day: $0.day, values: values[$0.key] ?? [:]) }
}

/// The values of `keys` for the fields `table` declares, read as each field's kind. Fields with no cell, or
/// with a cell of another kind, are absent.
func cells(of keys: [RowKey], in table: Spec.Table, _ db: Database) throws -> [RowKey: [Spec.FieldID: Spec.Cell]] {
    guard !keys.isEmpty, !table.fields.isEmpty else { return [:] }
    let fields = Dictionary(uniqueKeysWithValues: table.fields.map { ($0.id.raw, $0) })
    let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
    var values: [RowKey: [Spec.FieldID: Spec.Cell]] = [:]
    for row in try Row.fetchAll(
        db, sql: "SELECT row, field, value FROM cell WHERE row IN (\(marks))",
        arguments: StatementArguments(keys.map(\.raw)))
    {
        guard let key = RowKey(parsing: row["row"]), let field = fields[row["field"]],
            let cell = StoredValue(row["value"])?.cell(as: field.kind)
        else { continue }
        values[key, default: [:]][field.id] = cell
    }
    return values
}
