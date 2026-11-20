import Foundation

extension Spec {
    /// A named data state: rows relative to today, so a sample means the same thing on any day. The builder
    /// proves a look against `Spec.empty`, every sample in the document, and `full`. The render tool draws
    /// any of them.
    package struct Sample: Hashable, Sendable {
        package let name: String
        /// Insert order, which is the order the document lists rows within each table.
        package let rows: [SampleRow]
    }

    package struct SampleRow: Hashable, Sendable {
        package let table: Table
        package let daysAgo: Int
        /// The document's `repeat`: how many identical rows this entry stands for. At least 1.
        package let count: Int
        /// In field id order. Every field belongs to `table`.
        package let values: [FieldValue]
    }

    /// Names of the states the builder makes itself. A document sample cannot use them.
    static let reservedSampleNames = ["empty", "full"]

    /// No rows. Every look must handle it: `latest` is null and lists are empty.
    package static let empty = Sample(name: "empty", rows: [])

    /// Rows that stress layout: every list filled to its limit, three-digit counts, streaks, and daily
    /// totals, and in every field the longest value the widget can store there. It catches spills the
    /// model's own samples miss.
    package var full: Sample {
        var rows: [SampleRow] = []
        for table in tables {
            let base = table.fields.map(longestStorable)
            var groups: [(filter: FieldValue?, count: Int)] = []
            var historyDays = 0
            func need(_ filter: FieldValue?, _ count: Int) {
                if let index = groups.firstIndex(where: { $0.filter == filter }) {
                    groups[index].count = max(groups[index].count, count)
                } else {
                    groups.append((filter, count))
                }
            }
            for query in queries where query.shape.table == table.id {
                switch query.shape {
                case .count(_, let filter, _), .sum(_, let filter, _): need(filter, 100)
                case .latest(_, let filter, _): need(filter, 1)
                case .list(_, let filter, _, let limit, _): need(filter, limit)
                case .streak:
                    need(nil, 1)
                    historyDays = max(historyDays, 100)
                case .daily(_, let days):
                    need(nil, 100)
                    historyDays = max(historyDays, days)
                }
            }
            for (filter, count) in groups {
                let values = (base.filter { $0.field != filter?.field } + [filter].compactMap { $0 })
                    .sorted { $0.field.id < $1.field.id }
                rows.append(SampleRow(table: table, daysAgo: 0, count: count, values: values))
            }
            for daysAgo in 1..<max(historyDays, 1) {
                rows.append(SampleRow(table: table, daysAgo: daysAgo, count: 1, values: base))
            }
        }
        return Sample(name: "full", rows: rows)
    }

    /// A form or an automation can write anything into a field, and a toggle flips it, so such a field gets
    /// the longest value of its kind. A field that only fixed action values write, such as one emoji per
    /// mood button, can only ever hold one of them, so it gets the longest of those.
    private func longestStorable(_ field: AnyField) -> FieldValue {
        var fixed: [FieldValue] = []
        for action in actions {
            switch action.effect {
            case .insert(_, let values): fixed += values.filter { $0.field == field }
            case .set(let value) where value.field == field: fixed.append(value)
            case .toggle(let toggled) where toggled.erased == field: return field.longestValue
            case .form(let form) where form.fields.contains(field): return field.longestValue
            default: break
            }
        }
        if automations.contains(where: { $0.writes.id == field.table }) { return field.longestValue }
        return fixed.max { $0.value.width < $1.value.width } ?? field.longestValue
    }

    /// A data state file for the render tool, in the grammar of one `samples` entry, resolved against this
    /// spec's tables. One grammar and one parser for samples and states.
    package func parseState(_ json: Data, name: String) throws(Diagnostic) -> Sample {
        do throws(Diagnostic) {
            return try Sample.parse(rows: JSONValue.parse(json), name: name, Resolver(tables: tables))
        } catch {
            throw error.within("state \(Diagnostic.quote(name))")
        }
    }
}

extension Spec.AnyField {
    /// The value the `full` state writes: long text, a three-digit number, true, and the date with the
    /// longest English name, Wednesday, September 30.
    fileprivate var longestValue: Spec.FieldValue {
        switch self {
        case .text(let field): Spec.FieldValue(field, "Water the plants on the balcony and porch")
        case .number(let field): Spec.FieldValue(field, 999)
        case .bool(let field): Spec.FieldValue(field, true)
        case .date(let field): Spec.FieldValue(field, Day(year: 2026, month: 9, day: 30))
        }
    }
}

extension Spec.Cell {
    /// How much room the value takes on screen, to pick the widest of one field's fixed values.
    fileprivate var width: Double {
        switch self {
        case .text(let text): Double(text.count)
        case .number(let number): abs(number)
        case .bool(let bool): bool ? 1 : 0
        case .date: 0
        }
    }
}

extension Spec.Sample {
    static func parseAll(_ value: JSONValue?, _ resolver: Resolver) throws(Diagnostic) -> [Spec.Sample] {
        guard let value else { return [] }
        let example = "like {\"busy\": {\"items\": [{\"daysAgo\": 0, \"title\": \"Buy milk\"}]}}"
        let samples = try Reader(value, else: "\"samples\" must be an object of samples keyed by name, \(example)")
        guard samples.keys.count <= Spec.Limits.samples else {
            throw Diagnostic("at most \(Spec.Limits.samples) samples, found \(samples.keys.count)")
        }
        var result: [Spec.Sample] = []
        for name in samples.keys {
            do throws(Diagnostic) {
                guard !name.isEmpty, name.count <= Spec.Limits.nameLength,
                    !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
                else {
                    throw Diagnostic("a sample name has 1 to \(Spec.Limits.nameLength) characters on one line")
                }
                guard !Spec.reservedSampleNames.contains(name.lowercased()) else {
                    throw Diagnostic(
                        "the name \(Diagnostic.quote(name)) is reserved for a state the builder makes; pick another")
                }
                result.append(try parse(rows: samples[name] ?? .null, name: name, resolver))
            } catch {
                throw error.within("sample \(Diagnostic.quote(name))")
            }
        }
        return result
    }

    /// One sample's body: `{ table: [row, ...] }`. Diagnostics carry the path below the sample.
    static func parse(rows value: JSONValue, name: String, _ resolver: Resolver) throws(Diagnostic) -> Spec.Sample {
        let byTable = try Reader(
            value,
            else: "must map table ids to lists of rows, like {\"items\": [{\"daysAgo\": 0}]}, not \(value.described)")
        var rows: [Spec.SampleRow] = []
        for key in byTable.keys {
            let table = try resolver.table(.string(key), for: "a sample")
            guard case .array(let entries) = byTable[key] else {
                throw Diagnostic("\"\(key)\" must be a list of rows, like [{\"daysAgo\": 0}]")
            }
            for (index, entry) in entries.enumerated() {
                do throws(Diagnostic) {
                    rows.append(try row(entry, table))
                } catch {
                    throw error.within("\(key)[\(index)]")
                }
            }
        }
        let total = rows.reduce(0) { $0 + $1.count }
        guard total <= Spec.Limits.rowsPerSample else {
            throw Diagnostic("\(total) rows after repeat; keep a sample to \(Spec.Limits.rowsPerSample) or fewer")
        }
        return Spec.Sample(name: name, rows: rows)
    }

    private static func row(_ value: JSONValue, _ table: Spec.Table) throws(Diagnostic) -> Spec.SampleRow {
        let example = table.fields.first.map { ", \"\($0.id.raw)\": ..." } ?? ""
        let row = try Reader(
            value, else: "a row must be an object like {\"daysAgo\": 0\(example)}, not \(value.described)")
        if row.has("id") { throw Diagnostic("\"id\" is made by the app; leave it out") }
        if row.has("day") { throw Diagnostic("\"day\" comes from \"daysAgo\"; write \"daysAgo\" instead") }
        return Spec.SampleRow(
            table: table,
            daysAgo: try row.wholeNumber("daysAgo", in: Spec.Limits.daysAgo) ?? 0,
            count: try row.wholeNumber("repeat", in: Spec.Limits.repeatCount) ?? 1,
            values: try table.values(row, skipping: ["daysAgo", "repeat"]))
    }

    var json: JSONValue {
        var byTable: [String: [JSONValue]] = [:]
        for row in rows {
            var members: [String: JSONValue] = [
                "daysAgo": .number(Double(row.daysAgo)), "repeat": .number(Double(row.count)),
            ]
            for value in row.values { members[value.field.id.raw] = value.value.json }
            byTable[row.table.id.raw, default: []].append(.object(members))
        }
        return .object(byTable.mapValues { .array($0) })
    }
}
