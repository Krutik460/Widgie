import Foundation
import GRDB
import Spec

// The read side. Every shape starts from one `Selection`: the live rows of the dataset (widget, table) is bound
// to, narrowed by a day window and a `where`. A row's author is the replica that inserted it, and `me` is this
// store's replica, so `where by` and `RowValue.by` need no lookup beyond the row. Every window ends today, so a row written ahead for a later day
// shows on its day. A cell is read only when it claims its row's dataset and has its field's kind. The binding
// is a scalar subquery SQLite runs once, so the partial index `row_live(dataset, day, at) WHERE deleted IS NULL`
// serves the selection, the day windows, and the newest and oldest orders. A table with no binding selects
// nothing.

/// Live rows of the dataset one table of one widget is bound to, as a WHERE clause over `row r`.
private struct Selection {
    let sql: String
    let arguments: StatementArguments

    init(
        widget: WidgetKey, table: Spec.TableID, from first: Day? = nil, through last: Day,
        matching filter: Spec.Filter? = nil, me: String
    ) {
        var sql = """
            r.dataset = (SELECT dataset FROM binding WHERE widget = ? AND tbl = ?) AND r.deleted IS NULL \
            AND r.day <= ?
            """
        var arguments: StatementArguments = [widget.raw, table.raw, last.index]
        if let first {
            sql += " AND r.day >= ?"
            arguments += [first.index]
        }
        if let filter = filter?.field {
            sql += """
                 AND coalesce((SELECT c.value FROM cell c WHERE c.row = r.key AND c.dataset = r.dataset \
                AND c.field = ? AND c.kind = ?), ?) = ?
                """
            arguments += [
                filter.field.id.raw, filter.field.kind.code, filter.field.kind == .bool ? 0 : nil,
                filter.value.databaseValue,
            ]
        }
        switch filter?.by {
        case .me?:
            sql += " AND r.replica = ?"
            arguments += [me]
        case .others?:
            sql += " AND r.replica <> ?"
            arguments += [me]
        case nil:
            break
        }
        self.sql = sql
        self.arguments = arguments
    }
}

extension Spec.Window {
    /// The first day the window reads, or nil for `all`. Every window ends today.
    fileprivate func first(_ today: Today) -> Day? {
        switch self {
        case .today: today.day
        case .week: today.weekStart
        case .month: today.day.month.lowerBound
        case .days(let count): today.day.adding(1 - count)
        case .all: nil
        }
    }
}

func evaluate(_ shape: Spec.Shape, widget: WidgetKey, today: Today, me: String, _ db: Database) throws
    -> QueryResult
{
    switch shape {
    case .count(let table, let filter, let window):
        let rows = Selection(
            widget: widget, table: table.id, from: window.first(today), through: today.day, matching: filter, me: me)
        return .number(
            Double(
                try Int.fetchOne(db, sql: "SELECT count(*) FROM row r WHERE \(rows.sql)", arguments: rows.arguments)
                    ?? 0))
    case .sum(let field, let filter, let window):
        let rows = Selection(
            widget: widget, table: field.table, from: window.first(today), through: today.day, matching: filter, me: me)
        let total = try Double.fetchOne(
            db,
            sql: """
                SELECT total(v.value) FROM row r
                JOIN cell v ON v.row = r.key AND v.dataset = r.dataset AND v.field = ? AND v.kind = ? WHERE \(rows.sql)
                """, arguments: [field.id.raw, Spec.FieldKind.number.code] + rows.arguments)
        return .number(total ?? 0)
    case .latest(let table, let filter, let window):
        let rows = Selection(
            widget: widget, table: table.id, from: window.first(today), through: today.day, matching: filter, me: me)
        return .row(try list(table, rows, .newest, limit: 1, me: me, db).first)
    case .list(let table, let filter, let order, let limit, let window):
        let rows = Selection(
            widget: widget, table: table.id, from: window.first(today), through: today.day, matching: filter, me: me)
        return .rows(try list(table, rows, order, limit: limit, me: me, db))
    case .streak(let measure, let filter, let goal):
        let rows = Selection(widget: widget, table: measure.table, through: today.day, matching: filter, me: me)
        let totals = DayTotals(measure, rows)
        let days = try Int.fetchCursor(
            db, sql: "SELECT day FROM (\(totals.sql) GROUP BY r.day) WHERE measure >= ? ORDER BY day DESC",
            arguments: totals.arguments + [goal])
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
            measure,
            Selection(widget: widget, table: measure.table, from: first, through: today.day, matching: filter, me: me))
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
                LEFT JOIN cell v ON v.row = r.key AND v.dataset = r.dataset AND v.field = ? AND v.kind = ?
                WHERE \(rows.sql)
                """
            arguments = [field.id.raw, Spec.FieldKind.number.code] + rows.arguments
        }
    }
}

/// Up to `limit` selected rows in `order`, with their values: one statement for the keys, one for their cells.
private func list(
    _ table: Spec.Table, _ rows: Selection, _ order: Spec.Order, limit: Int, me: String, _ db: Database
) throws -> [RowValue] {
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
        join = "LEFT JOIN cell s ON s.row = r.key AND s.dataset = r.dataset AND s.field = ? AND s.kind = ?"
        arguments = [field.id.raw, field.kind.code]
        let direction = descending ? " DESC" : ""
        sorting =
            switch field.kind {
            case .bool: "coalesce(s.value, 0)\(direction), \(newest)"
            case .text: "s.value IS NULL, s.value COLLATE NOCASE\(direction), \(newest)"
            case .number, .date: "s.value IS NULL, s.value\(direction), \(newest)"
            }
    }
    let keyed = try Row.fetchAll(
        db,
        sql: """
            SELECT r.key, r.dataset, r.day, r.at, r.replica, m.name FROM row r \(join)
            LEFT JOIN member m ON m.replica = r.replica WHERE \(rows.sql) ORDER BY \(sorting) LIMIT ?
            """,
        arguments: arguments + rows.arguments + [limit])
    let found: [(key: RowKey, day: Day, at: Int64, by: RowAuthor)] = keyed.compactMap { row in
        RowKey(parsing: row["key"]).map {
            ($0, Day(index: row["day"]), row["at"] ?? 0, RowAuthor(me: row["replica"] == me, name: row["name"]))
        }
    }
    guard let dataset = keyed.first.flatMap({ DatasetKey(parsing: $0["dataset"]) }) else { return [] }
    let values = try cells(of: found.map(\.key), in: table, dataset: dataset, db)
    return found.map {
        RowValue(key: $0.key, day: $0.day, at: date($0.at), by: $0.by, values: values[$0.key] ?? [:])
    }
}

/// The values of rows `keys` of `dataset` for the fields `table` declares. Fields with no cell, or with a cell
/// of another kind or one that claimed another dataset, are absent.
func cells(of keys: [RowKey], in table: Spec.Table, dataset: DatasetKey, _ db: Database) throws -> [RowKey: [Spec
    .FieldID: Spec.Cell]]
{
    guard !keys.isEmpty, !table.fields.isEmpty else { return [:] }
    let fields = Dictionary(uniqueKeysWithValues: table.fields.map { ($0.id.raw, $0) })
    let marks = Array(repeating: "?", count: keys.count).joined(separator: ", ")
    var values: [RowKey: [Spec.FieldID: Spec.Cell]] = [:]
    for row in try Row.fetchAll(
        db, sql: "SELECT row, field, kind, value FROM cell WHERE dataset = ? AND row IN (\(marks))",
        arguments: StatementArguments([dataset.raw] + keys.map(\.raw)))
    {
        guard let key = RowKey(parsing: row["row"]), let field = fields[row["field"]],
            let cell = Spec.Cell(row["value"], code: row["kind"], as: field.kind)
        else { continue }
        values[key, default: [:]][field.id] = cell
    }
    return values
}
