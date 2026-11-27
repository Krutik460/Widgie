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
        /// Set when the document places the row by minutes before the render instead of by day. Then the
        /// row's day is the day that moment falls on, and `daysAgo` is 0.
        package let minutesAgo: Int?
        /// The name of the member who wrote the row, or nil for the person.
        package let by: String?
        /// Never placed before today began, however large `minutesAgo` is: the document's `"staysToday": true`,
        /// and every today row of `full`, so they stay on today on a 23-hour day and at any hour. Without it a
        /// document's `minutesAgo` means what it says, and a row can land on yesterday.
        package let staysToday: Bool
        /// The document's `repeat`: how many identical rows this entry stands for. At least 1.
        package let count: Int
        /// In field id order. Every field belongs to `table`.
        package let values: [FieldValue]
        /// Date values given as days from the day the sample is drawn, in field id order. Every field belongs to
        /// `table`, and none is also in `values`.
        package var datesFromToday: [DateFromToday] = []

        /// Every value of the row, with each date from today resolved against `today`.
        package func values(on today: Day) -> [FieldValue] {
            (values + datesFromToday.map { $0.value(on: today) }).sorted { $0.field.id < $1.field.id }
        }
    }

    /// A sample's date written as `{"daysFromToday": 12}`: the day that many days after the day the sample is
    /// drawn, or before it when negative. A countdown's sample then shows the same count on any day, as rows
    /// placed by `daysAgo` do.
    package struct DateFromToday: Hashable, Sendable {
        package let field: Field<Day>
        package let days: Int

        package func value(on today: Day) -> FieldValue { FieldValue(field, today.adding(days)) }
    }

    /// Names of the states the builder makes itself. A document sample cannot use them.
    static let reservedSampleNames = ["empty", "full"]

    /// No rows. Every look must handle it: `latest` is null and lists are empty.
    package static let empty = Sample(name: "empty", rows: [])

    /// Rows that stress layout: every list filled to its limit, three-digit counts, streaks, and daily
    /// totals, and in every field the longest value the widget can store there. Rows for a filtered query
    /// match its filter, and every day of a goal streak reaches the goal, as far as 100 rows a day allow.
    /// Rows are written by another member whose name is as long as a name may be, except rows for a query
    /// that asks for rows by `me`. Today's rows were written `widestMinutesAgo` minutes before the render, or
    /// as the day began if that is later, so "11 h 59 min ago" is drawn at noon. It catches spills the
    /// model's own samples miss.
    package var full: Sample {
        var rows: [SampleRow] = []
        for table in tables {
            let base = table.fields.map(longestStorable)
            func matching(_ filter: Filter?) -> [FieldValue] {
                let fixed = filter?.field
                return (base.filter { $0.field != fixed?.field } + [fixed].compactMap { $0 }).sorted {
                    $0.field.id < $1.field.id
                }
            }
            /// Rows per day for a streak's days to reach `goal`, at most 100.
            func reaching(_ goal: Double, _ measure: Measure, _ filter: Filter?) -> Int {
                var each = 1.0
                if case .total(let field) = measure {
                    let value = matching(filter).first { $0.field == field.erased }?.value
                    guard case .number(let number)? = value, number > 0 else { return 1 }
                    each = number
                }
                return Int(min(100, max(1, (goal / each).rounded(.up))))
            }
            var today: [(filter: Filter?, count: Int)] = []
            var history: [(filter: Filter?, days: Int, each: Int)] = []
            /// `count` rows today and, for the `days - 1` days before it, `each` rows a day.
            func need(_ filter: Filter?, _ count: Int, days: Int = 1, each: Int = 1) {
                if let index = today.firstIndex(where: { $0.filter == filter }) {
                    today[index].count = max(today[index].count, count)
                } else {
                    today.append((filter, count))
                }
                guard days > 1 else { return }
                // Merged only with history of the same density, so a long daily beside a goal streak does
                // not fill the daily's year at the streak's rows per day.
                if let index = history.firstIndex(where: { $0.filter == filter && $0.each == each }) {
                    history[index].days = max(history[index].days, days)
                } else {
                    history.append((filter, days, each))
                }
            }
            for query in queries where query.shape.table == table.id {
                switch query.shape {
                case .count(_, let filter, _), .sum(_, let filter, _): need(filter, 100)
                case .latest(_, let filter, _): need(filter, 1)
                case .list(_, let filter, _, let limit, _): need(filter, limit)
                case .streak(let measure, let filter, let goal):
                    let each = reaching(goal, measure, filter)
                    need(filter, each, days: Self.streakDays, each: each)
                case .daily(_, let filter, let days): need(filter, 100, days: days)
                }
            }
            func author(_ filter: Filter?) -> String? { filter?.by == .me ? nil : Self.longestMemberName }
            for (filter, count) in today {
                rows.append(
                    SampleRow(
                        table: table, daysAgo: 0, minutesAgo: Self.widestMinutesAgo, by: author(filter),
                        staysToday: true, count: count, values: matching(filter)))
            }
            for (filter, days, each) in history {
                for daysAgo in 1..<days {
                    rows.append(
                        SampleRow(
                            table: table, daysAgo: daysAgo, minutesAgo: nil, by: author(filter), staysToday: false,
                            count: each, values: matching(filter)))
                }
            }
        }
        return Sample(name: "full", rows: rows)
    }

    /// How far back `full` fills a streak's days, for a three-digit streak.
    private static let streakDays = 100

    /// A real-looking name at exactly `Limits.memberNameLength` UTF-16 units, the longest `by.name` can be.
    static let longestMemberName = "Maximiliana Montgomery-Okonkwo"

    /// The age of `full`'s rows for today: the longest "h min ago" text under 12 hours. The rows never go
    /// before today began (`staysToday`), so a 23-hour day or an early proof keeps them on today.
    static let widestMinutesAgo = 719

    /// A form or an automation can write anything into a field, and a toggle flips it, so such a field gets
    /// the longest value of its kind. A field that only fixed action values write, such as one emoji per
    /// mood button, can only ever hold one of them, so it gets the longest of those.
    private func longestStorable(_ field: AnyField) -> FieldValue {
        var fixed: [FieldValue] = []
        for action in actions {
            switch action.effect {
            case .insert(_, let values), .insertOn(_, let values): fixed += values.filter { $0.field == field }
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
    /// The value the `full` state writes: text of realistic words at exactly `Limits.textLength`, a
    /// three-digit number, true, and the date with the longest English name, Wednesday, September 30.
    fileprivate var longestValue: Spec.FieldValue {
        switch self {
        case .text(let field): Spec.FieldValue(field, longestText)
        case .number(let field): Spec.FieldValue(field, 999)
        case .bool(let field): Spec.FieldValue(field, true)
        case .date(let field): Spec.FieldValue(field, Day(year: 2026, month: 9, day: 30))
        }
    }
}

/// 300 UTF-16 units, the most a text field holds, in words a person would write, so `full` renders the
/// longest text the widget can store.
private let longestText =
    "Water the plants on the balcony and porch, then call the landlord about the leaking kitchen tap, pick up the dry cleaning before six, book a table for Saturday night, renew the library books due Monday, buy oat milk, eggs, bread, and coffee beans, and send Gran the photos from our trip to the lakes."

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
        if row.has("at") {
            throw Diagnostic(
                "\"at\" comes from \"minutesAgo\"; write \"minutesAgo\": 90 for a row written 90 minutes ago")
        }
        if row.has("daysAgo") && row.has("minutesAgo") {
            throw Diagnostic("give \"daysAgo\" or \"minutesAgo\", not both")
        }
        let reserved = ["by", "daysAgo", "minutesAgo", "repeat", "staysToday"]
        var dates: [Spec.DateFromToday] = []
        for key in row.keys where !reserved.contains(key) {
            guard case .date(let field)? = table.field(named: key), case .object = row[key] else { continue }
            dates.append(try dateFromToday(row[key] ?? .null, field))
        }
        let minutesAgo = try row.wholeNumber("minutesAgo", in: Spec.Limits.minutesAgo)
        var staysToday = false
        if let value = row["staysToday"] {
            let rule =
                "\"staysToday\": true goes with \"minutesAgo\", like {\"minutesAgo\": 600, \"staysToday\": true} for 10 hours ago or as today began if that is later"
            guard value == .bool(true), minutesAgo != nil else { throw Diagnostic(rule) }
            staysToday = true
        }
        var sampleRow = Spec.SampleRow(
            table: table,
            daysAgo: try row.wholeNumber("daysAgo", in: Spec.Limits.daysAgo) ?? 0,
            minutesAgo: minutesAgo,
            by: try author(row),
            staysToday: staysToday,
            count: try row.wholeNumber("repeat", in: Spec.Limits.repeatCount) ?? 1,
            values: try table.values(row, skipping: reserved + dates.map(\.field.id.raw)))
        sampleRow.datesFromToday = dates
        return sampleRow
    }

    private static func dateFromToday(_ value: JSONValue, _ field: Spec.Field<Day>) throws(Diagnostic)
        -> Spec.DateFromToday
    {
        let rule =
            "\"\(field.path)\" is a date field; give a date like \"2026-11-18\", or {\"daysFromToday\": 12} for a date that many days after the day the sample is drawn"
        let object = try Reader(value, else: rule)
        try object.requireOnly(["daysFromToday"]) { _ in rule }
        guard let days = try object.wholeNumber("daysFromToday", in: Spec.Limits.daysFromToday) else {
            throw Diagnostic(rule)
        }
        return Spec.DateFromToday(field: field, days: days)
    }

    /// `by` is "me" in any case, or left out, for the person, or another member's name: one
    /// line, not blank, at most `Limits.memberNameLength` UTF-16 units like a text value.
    private static func author(_ row: Reader) throws(Diagnostic) -> String? {
        guard let value = row["by"] else { return nil }
        let rule =
            "\"by\" is \"me\" or another member's name on one line, like \"Sam\", up to \(Spec.Limits.memberNameLength) characters"
        guard case .string(let name) = value else { throw Diagnostic("\(rule), not \(value.described)") }
        let breaks: Set<Unicode.GeneralCategory> = [.control, .lineSeparator, .paragraphSeparator]
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty,
            !name.unicodeScalars.contains(where: { breaks.contains($0.properties.generalCategory) })
        else { throw Diagnostic(rule) }
        guard name.utf16.count <= Spec.Limits.memberNameLength else {
            throw Diagnostic(
                "\"by\" is \(name.utf16.count) characters; keep it to \(Spec.Limits.memberNameLength) or fewer")
        }
        return name.lowercased() == "me" ? nil : name
    }

    var json: JSONValue {
        var byTable: [String: [JSONValue]] = [:]
        for row in rows {
            var members: [String: JSONValue] = ["repeat": .number(Double(row.count))]
            if let minutes = row.minutesAgo {
                members["minutesAgo"] = .number(Double(minutes))
                if row.staysToday { members["staysToday"] = .bool(true) }
            } else {
                members["daysAgo"] = .number(Double(row.daysAgo))
            }
            if let by = row.by { members["by"] = .string(by) }
            for value in row.values { members[value.field.id.raw] = value.value.json }
            for date in row.datesFromToday {
                members[date.field.id.raw] = .object(["daysFromToday": .number(Double(date.days))])
            }
            byTable[row.table.id.raw, default: []].append(.object(members))
        }
        return .object(byTable.mapValues { .array($0) })
    }
}
