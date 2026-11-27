import Foundation

extension Spec {
    package enum FieldKind: String, CaseIterable, Sendable, CustomStringConvertible {
        case text
        case number
        case bool
        case date

        package var description: String { rawValue }

        func field(table: TableID, id: FieldID) -> AnyField {
            switch self {
            case .text: .text(Field(table: table, id: id))
            case .number: .number(Field(table: table, id: id))
            case .bool: .bool(Field(table: table, id: id))
            case .date: .date(Field(table: table, id: id))
            }
        }
    }

    /// The Swift type a field holds. The four conformances are the four field kinds.
    package protocol CellType: Hashable, Sendable {
        static var kind: FieldKind { get }
        var cell: Cell { get }
        static func erase(_ field: Field<Self>) -> AnyField
        /// The typed handle, or nil when the field has another kind.
        static func unerase(_ field: AnyField) -> Field<Self>?
    }

    /// A field of a known kind. The table is part of the reference, so a block that names a field never
    /// names its table separately and the two cannot disagree.
    package struct Field<Value: CellType>: Hashable, Sendable {
        package let table: TableID
        package let id: FieldID

        package var erased: AnyField { Value.erase(self) }

        /// `items.done`, as the document writes it.
        package var path: String { "\(table.raw).\(id.raw)" }
    }

    package enum AnyField: Hashable, Sendable {
        case text(Field<String>)
        case number(Field<Double>)
        case bool(Field<Bool>)
        case date(Field<Day>)

        package var table: TableID {
            switch self {
            case .text(let field): field.table
            case .number(let field): field.table
            case .bool(let field): field.table
            case .date(let field): field.table
            }
        }

        package var id: FieldID {
            switch self {
            case .text(let field): field.id
            case .number(let field): field.id
            case .bool(let field): field.id
            case .date(let field): field.id
            }
        }

        package var kind: FieldKind {
            switch self {
            case .text: .text
            case .number: .number
            case .bool: .bool
            case .date: .date
            }
        }

        package var path: String { "\(table.raw).\(id.raw)" }
    }

    package enum Cell: Hashable, Sendable {
        case text(String)
        case number(Double)
        case bool(Bool)
        case date(Day)
    }

    /// A field paired with a value of its kind: a value an action writes, a sample row holds, or a `where`
    /// compares against. The only initializer takes a `Field<V>` and a `V`, so a kind mismatch does not
    /// compile.
    package struct FieldValue: Hashable, Sendable {
        package let field: AnyField
        package let value: Cell

        init<V: CellType>(_ field: Field<V>, _ value: V) {
            self.field = field.erased
            self.value = value.cell
        }
    }

    package struct Table: Hashable, Sendable {
        package let id: TableID
        /// In id order. Empty for an event table, whose rows only record that something happened on a day.
        package let fields: [AnyField]

        package func field(named raw: String) -> AnyField? { fields.first { $0.id.raw == raw } }

        var fieldChoices: String {
            Diagnostic.choices("fields", fields.map(\.id.raw), none: "\(id.raw) has no fields")
        }
    }

    /// Keys a row already uses for something else: the look receives `id`, `day`, `daysAgo`, `at`, `minutesAgo`,
    /// and `by`, a sample row uses `daysAgo`, `minutesAgo`, `staysToday`, `by`, and `repeat`, `where` reads `by` as
    /// the author, and `sort` reads `newest` and `oldest` as orders. `now` is the look's clock key, so a field of
    /// that name would make every look that reads it count as reading the clock.
    static let reservedFieldIDs = [
        "at", "by", "day", "daysAgo", "id", "minutesAgo", "newest", "now", "oldest", "repeat", "staysToday",
    ]
}

extension String: Spec.CellType {
    package static var kind: Spec.FieldKind { .text }
    package var cell: Spec.Cell { .text(self) }
    package static func erase(_ field: Spec.Field<String>) -> Spec.AnyField { .text(field) }
    package static func unerase(_ field: Spec.AnyField) -> Spec.Field<String>? {
        if case .text(let typed) = field { typed } else { nil }
    }
}

extension Double: Spec.CellType {
    package static var kind: Spec.FieldKind { .number }
    package var cell: Spec.Cell { .number(self) }
    package static func erase(_ field: Spec.Field<Double>) -> Spec.AnyField { .number(field) }
    package static func unerase(_ field: Spec.AnyField) -> Spec.Field<Double>? {
        if case .number(let typed) = field { typed } else { nil }
    }
}

extension Bool: Spec.CellType {
    package static var kind: Spec.FieldKind { .bool }
    package var cell: Spec.Cell { .bool(self) }
    package static func erase(_ field: Spec.Field<Bool>) -> Spec.AnyField { .bool(field) }
    package static func unerase(_ field: Spec.AnyField) -> Spec.Field<Bool>? {
        if case .bool(let typed) = field { typed } else { nil }
    }
}

extension Day: Spec.CellType {
    package static var kind: Spec.FieldKind { .date }
    package var cell: Spec.Cell { .date(self) }
    package static func erase(_ field: Spec.Field<Day>) -> Spec.AnyField { .date(field) }
    package static func unerase(_ field: Spec.AnyField) -> Spec.Field<Day>? {
        if case .date(let typed) = field { typed } else { nil }
    }
}

extension Spec.Table {
    static func parse(_ id: Spec.TableID, _ json: JSONValue) throws(Diagnostic) -> Spec.Table {
        do throws(Diagnostic) {
            let table = try Reader(
                json, else: "a table must be an object like {\"fields\": {\"title\": \"text\"}}, not \(json.described)")
            try table.requireOnly(["fields"]) { "unknown key \(Diagnostic.quote($0)) (a table has only \"fields\")" }
            guard let value = table["fields"] else { return Spec.Table(id: id, fields: []) }
            let declared = try Reader(
                value, else: "\"fields\" must map field ids to kinds, like {\"title\": \"text\", \"done\": \"bool\"}")
            guard declared.keys.count <= Spec.Limits.fieldsPerTable else {
                throw Diagnostic("at most \(Spec.Limits.fieldsPerTable) fields, found \(declared.keys.count)")
            }
            var fields: [Spec.AnyField] = []
            for raw in declared.keys {
                guard !Spec.reservedFieldIDs.contains(raw) else {
                    throw Diagnostic(
                        "field id \(Diagnostic.quote(raw)) is reserved (reserved: \(Spec.reservedFieldIDs.joined(separator: ", ")))"
                    )
                }
                guard let fieldID = Spec.FieldID(raw) else {
                    throw Diagnostic(
                        "field id \(Diagnostic.quote(raw)) must start with a lowercase letter and have only letters and digits, at most 32"
                    )
                }
                let kind = declared[raw] ?? .null
                guard case .string(let name) = kind, let fieldKind = Spec.FieldKind(rawValue: name) else {
                    throw Diagnostic(
                        "field \(Diagnostic.quote(raw)) must be text, number, bool, or date, not \(kind.described)")
                }
                fields.append(fieldKind.field(table: id, id: fieldID))
            }
            return Spec.Table(id: id, fields: fields)
        } catch {
            throw error.within("table \(Diagnostic.quote(id.raw))")
        }
    }

    var json: JSONValue {
        .object([
            "fields": .object(Dictionary(uniqueKeysWithValues: fields.map { ($0.id.raw, .string($0.kind.rawValue)) }))
        ])
    }
}

extension Spec.AnyField {
    /// A value of this field's kind from JSON, as a document, a sample, or a submitted form gives it.
    package func value(from json: JSONValue) throws(Diagnostic) -> Spec.FieldValue {
        let name = "\"\(path)\""
        switch self {
        case .text(let field):
            guard case .string(let text) = json else {
                throw Diagnostic("\(name) is a text field; give a string, not \(json.described)")
            }
            guard Spec.Limits.allows(text) else {
                throw Diagnostic(
                    "the value for \(name) is \(text.utf16.count) characters as JavaScript counts them (an emoji counts as 2); keep it to \(Spec.Limits.textLength) or fewer"
                )
            }
            return Spec.FieldValue(field, text)
        case .number(let field):
            guard case .number(let number) = json else {
                throw Diagnostic("\(name) is a number field; give a number like 250, not \(json.described)")
            }
            guard number.isFinite else {
                throw Diagnostic("\(name) is a number field; give a finite number like 250, not \(number)")
            }
            return Spec.FieldValue(field, number)
        case .bool(let field):
            guard case .bool(let flag) = json else {
                throw Diagnostic("\(name) is a bool field; give true or false, not \(json.described)")
            }
            return Spec.FieldValue(field, flag)
        case .date(let field):
            guard case .string(let text) = json, let day = Day(iso: text) else {
                throw Diagnostic("\(name) is a date field; give a date like \"2026-11-18\", not \(json.described)")
            }
            return Spec.FieldValue(field, day)
        }
    }
}

extension Spec.Limits {
    /// Whether a text value fits `textLength`, counted in UTF-16 units, which is what JavaScript holds: an
    /// emoji counts as 2. Every path that stores text asks this, so the rule lives here.
    static func allows(_ text: String) -> Bool { text.utf16.count <= textLength }
}

extension Spec.Cell {
    /// False for a text over `Limits.textLength` or a number that is not finite, which a parsed value can
    /// never be. `RowStore.receive` refuses such a cell from sync.
    package var withinLimits: Bool {
        switch self {
        case .text(let text): Spec.Limits.allows(text)
        case .number(let number): number.isFinite
        case .bool, .date: true
        }
    }

    var json: JSONValue {
        switch self {
        case .text(let text): .string(text)
        case .number(let number): .number(number)
        case .bool(let flag): .bool(flag)
        case .date(let day): .string(day.iso)
        }
    }
}

extension [Spec.FieldValue] {
    var json: JSONValue {
        .object(Dictionary(uniqueKeysWithValues: map { ($0.field.id.raw, $0.value.json) }))
    }
}
