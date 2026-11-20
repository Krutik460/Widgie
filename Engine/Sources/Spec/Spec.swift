import Foundation

/// The parsed widget document.
///
/// Every type in this namespace has internal initializers, so only this target constructs one, and it does
/// so only in `Spec.parse` and the states it derives from a parsed spec. Any value another target holds has
/// resolved references and matching kinds. Other targets read these types; they never build them.
///
/// The block types are nested here because the struct shares its module's name, which makes `Spec.Table`
/// unreachable as a module-qualified name, and because SwiftUI also declares `Table`, `Shape`, and `Form`.
package struct Spec: Hashable, Sendable {
    package let name: String
    /// Every list in a spec is sorted by id, so iteration order never depends on the document's key order.
    package let tables: [Table]
    package let queries: [Query]
    package let actions: [Action]
    package let automations: [Automation]
    package let assets: [Asset]
    package let samples: [Sample]
    /// The JavaScript source that defines `render(ctx)`.
    package let look: String

    package func table(named raw: String) -> Table? { tables.first { $0.id.raw == raw } }

    /// Untrusted strings from a tap or a tree resolve here.
    package func action(named raw: String) -> Action? { actions.first { $0.id.raw == raw } }
    package func asset(named raw: String) -> Asset? { assets.first { $0.id.raw == raw } }
    package func sample(named name: String) -> Sample? { samples.first { $0.name == name } }
}

extension Spec {
    /// An id the document gives a block: a lowercase letter, then letters and digits, at most 32 in all.
    /// Query ids become JavaScript keys and action ids appear in the tree, so the pattern keeps both
    /// safe and readable.
    package struct Name<Tag>: Hashable, Comparable, Sendable, CustomStringConvertible {
        package let raw: String

        init?(_ raw: String) {
            guard let first = raw.unicodeScalars.first, ("a"..."z").contains(first), raw.unicodeScalars.count <= 32,
                raw.unicodeScalars.allSatisfy({
                    ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0)
                })
            else { return nil }
            self.raw = raw
        }

        package var description: String { raw }

        package static func < (a: Self, b: Self) -> Bool { a.raw < b.raw }
    }

    package enum TableTag {}
    package enum FieldTag {}
    package enum QueryTag {}
    package enum ActionTag {}
    package enum AutomationTag {}
    package enum AssetTag {}

    package typealias TableID = Name<TableTag>
    package typealias FieldID = Name<FieldTag>
    package typealias QueryID = Name<QueryTag>
    package typealias ActionID = Name<ActionTag>
    package typealias AutomationID = Name<AutomationTag>
    package typealias AssetID = Name<AssetTag>

    /// Caps that keep a widget inside the extension's memory and time, and a proof fast.
    enum Limits {
        static let nameLength = 40
        static let tables = 8
        static let fieldsPerTable = 16
        static let queries = 24
        static let actions = 16
        static let automations = 4
        static let assets = 8
        static let samples = 6
        static let rowsPerSample = 1000
        static let repeatCount = 1...100
        static let daysAgo = 0...400
        static let listLimit = 1...100
        static let dailyDays = 1...366
        static let goal = 1_000_000.0
        static let rowGoal = 1...100
        static let textLength = 300
        static let promptLength = 2000
        static let formPromptLength = 80
        static let aboutLength = 200
        static let lookBytes = 65_536
    }
}

/// One JSON object of the document, read key by key. A key whose value is null counts as absent, as in
/// the look language.
struct Reader {
    private let members: [String: JSONValue]

    init(_ value: JSONValue, else message: @autoclosure () -> String) throws(Diagnostic) {
        guard case .object(let members) = value else { throw Diagnostic(message()) }
        self.members = members.filter { $0.value != .null }
    }

    var keys: [String] { members.keys.sorted() }

    subscript(key: String) -> JSONValue? { members[key] }

    func has(_ key: String) -> Bool { members[key] != nil }

    /// Fails on the first key, in sorted order, that `allowed` does not list.
    func requireOnly(_ allowed: [String], else message: (String) -> String) throws(Diagnostic) {
        if let key = keys.first(where: { !allowed.contains($0) }) { throw Diagnostic(message(key)) }
    }

    func string(_ key: String, maxLength: Int) throws(Diagnostic) -> String? {
        guard let value = members[key] else { return nil }
        guard case .string(let text) = value else {
            throw Diagnostic("\"\(key)\" must be a string, not \(value.described)")
        }
        guard text.count <= maxLength else {
            throw Diagnostic("\"\(key)\" is \(text.count) characters; keep it to \(maxLength) or fewer")
        }
        return text
    }

    func wholeNumber(_ key: String, in range: ClosedRange<Int>) throws(Diagnostic) -> Int? {
        guard let value = members[key] else { return nil }
        guard case .number(let number) = value, let whole = Int(exactly: number), range.contains(whole) else {
            throw Diagnostic(
                "\"\(key)\" must be a whole number from \(range.lowerBound) to \(range.upperBound), not \(value.described)"
            )
        }
        return whole
    }

    /// The blocks under `key`, an object keyed by id, in id order.
    func blocks<Tag>(_ key: String, of _: Spec.Name<Tag>.Type, noun: String, max: Int, example: String)
        throws(Diagnostic) -> [(
            Spec.Name<Tag>, JSONValue
        )]
    {
        guard let value = members[key] else { return [] }
        let entries = try Reader(value, else: "\"\(key)\" must be an object of \(key) keyed by id, like \(example)")
        guard entries.keys.count <= max else {
            throw Diagnostic("at most \(max) \(key), found \(entries.keys.count)")
        }
        var result: [(Spec.Name<Tag>, JSONValue)] = []
        for raw in entries.keys {
            guard let id = Spec.Name<Tag>(raw), let block = entries[raw] else {
                throw Diagnostic(
                    "an id starts with a lowercase letter and has only letters and digits, at most 32",
                    at: ["\(noun) \(Diagnostic.quote(raw))"])
            }
            result.append((id, block))
        }
        return result
    }
}

/// Resolves the names a block writes (`"items"`, `"items.done"`) against the document's tables.
struct Resolver {
    let tables: [Spec.Table]

    var tableChoices: String {
        Diagnostic.choices("tables", tables.map(\.id.raw), none: "there are no tables; add one under \"tables\"")
    }

    func table(_ value: JSONValue, for key: String) throws(Diagnostic) -> Spec.Table {
        guard case .string(let raw) = value else {
            throw Diagnostic(
                "\(key) must name a table, like \"\(tables.first?.id.raw ?? "items")\", not \(value.described)")
        }
        if let table = tables.first(where: { $0.id.raw == raw }) { return table }
        if let dot = raw.firstIndex(of: "."), tables.contains(where: { $0.id.raw == raw[..<dot] }) {
            throw Diagnostic("\(key) takes a table, not a field; write \"\(raw[..<dot])\"")
        }
        throw Diagnostic("no table \(Diagnostic.quote(raw)) \(tableChoices)")
    }

    func field(_ value: JSONValue, for key: String) throws(Diagnostic) -> (table: Spec.Table, field: Spec.AnyField) {
        try field(value, for: key, listing: nil)
    }

    /// Resolves `"table.field"` to a field of `V`'s kind. The error for any other kind lists the fields
    /// that would do.
    func field<V: Spec.CellType>(_ value: JSONValue, for key: String, of _: V.Type) throws(Diagnostic) -> (
        table: Spec.Table, field: Spec.Field<V>
    ) {
        let (table, field) = try field(value, for: key, listing: V.kind)
        guard let typed = V.unerase(field) else {
            throw Diagnostic(
                "\(key) needs a \(V.kind) field; \"\(field.path)\" is \(field.kind) \(choices(of: V.kind))")
        }
        return (table, typed)
    }

    private func field(_ value: JSONValue, for key: String, listing kind: Spec.FieldKind?) throws(Diagnostic) -> (
        table: Spec.Table, field: Spec.AnyField
    ) {
        guard case .string(let raw) = value else {
            throw Diagnostic("\(key) must name a field as \"table.field\" \(choices(of: kind)), not \(value.described)")
        }
        let parts = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 2 else {
            throw Diagnostic("\(key) takes \"table.field\" \(choices(of: kind)), not \(Diagnostic.quote(raw))")
        }
        guard let table = tables.first(where: { $0.id.raw == parts[0] }) else {
            throw Diagnostic("no table \(Diagnostic.quote(String(parts[0]))) \(tableChoices)")
        }
        guard let field = table.field(named: String(parts[1])) else {
            throw Diagnostic("no field \(Diagnostic.quote(String(parts[1]))) in \(table.id.raw) \(table.fieldChoices)")
        }
        return (table, field)
    }

    private func choices(of kind: Spec.FieldKind?) -> String {
        let candidates = tables.flatMap(\.fields).filter { kind == nil || $0.kind == kind }
        return Diagnostic.choices(
            kind.map { "\($0) fields" } ?? "fields", candidates.map(\.path),
            none: kind.map { "no table has a \($0) field" } ?? "no table has fields")
    }
}
