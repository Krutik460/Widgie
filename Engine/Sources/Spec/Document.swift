import Foundation

extension Spec {
    /// The format this build of the engine writes. Older documents are upgraded when parsed.
    package static let currentFormat = 1

    private static let topLevelKeys = [
        "actions", "assets", "automations", "format", "look", "name", "queries", "samples", "tables",
    ]

    /// Text to typed blocks: parse the JSON, upgrade it step by step to `currentFormat`, then resolve every
    /// name into a typed reference. A missing `format` means current, which is how a model reply arrives.
    /// The first problem comes back as one `Diagnostic`.
    package static func parse(_ json: Data) throws(Diagnostic) -> Spec {
        try parse(document: Upgrade.toCurrent(JSONValue.parse(json)))
    }

    /// Canonical JSON at `currentFormat`: compact, keys sorted, defaults written out. Equal specs encode to
    /// equal bytes, so the bytes' hash names a revision, and `parse(encoded())` returns an equal spec.
    package func encoded() -> Data {
        JSONValue.object([
            "format": .number(Double(Self.currentFormat)),
            "name": .string(name),
            "tables": .object(Dictionary(uniqueKeysWithValues: tables.map { ($0.id.raw, $0.json) })),
            "queries": .object(Dictionary(uniqueKeysWithValues: queries.map { ($0.id.raw, $0.json) })),
            "actions": .object(Dictionary(uniqueKeysWithValues: actions.map { ($0.id.raw, $0.json) })),
            "automations": .object(Dictionary(uniqueKeysWithValues: automations.map { ($0.id.raw, $0.json) })),
            "assets": .object(Dictionary(uniqueKeysWithValues: assets.map { ($0.id.raw, $0.json) })),
            "samples": .object(Dictionary(uniqueKeysWithValues: samples.map { ($0.name, $0.json) })),
            "look": .string(look),
        ]).encoded()
    }

    /// A refinement may add and remove tables and fields, but a field id that survives keeps its kind,
    /// because stored values were written with that kind.
    package func checkCompatible(replacing old: Spec) throws(Diagnostic) {
        for table in tables {
            guard let before = old.table(named: table.id.raw), let (field, was) = clash(table, before) else {
                continue
            }
            throw Diagnostic(
                "field \"\(field.path)\" was \(was) and is now \(field.kind); keep the kind or use a new field id")
        }
    }

    /// Two widgets that read the same rows must agree on every field id both declare. `table` is this spec's
    /// table, and `theirs` is the table of `other` bound to the same dataset.
    package func checkCompatible(_ table: String, with other: Spec, table theirs: String) throws(Diagnostic) {
        guard let mine = self.table(named: table), let shared = other.table(named: theirs),
            let (field, was) = clash(mine, shared)
        else { return }
        throw Diagnostic(
            "field \"\(field.path)\" is \(was) in widget \(Diagnostic.quote(other.name)), which shares this data, and is \(field.kind) here; keep the kind or use a new field id"
        )
    }

    /// A field of `table` keeps the kind of the cells already stored under it, whoever wrote them: a deleted
    /// widget, another device, another user. `kinds` maps field ids to the kinds stored. A field with no
    /// cells may change kind, since nothing can be misread.
    package func checkCompatible(_ table: String, holding kinds: [String: Set<FieldKind>]) throws(Diagnostic) {
        guard let mine = self.table(named: table) else { return }
        for field in mine.fields {
            guard let held = kinds[field.id.raw]?.subtracting([field.kind]).map(\.rawValue).min() else { continue }
            throw Diagnostic(
                "field \"\(field.path)\" already holds \(held) values, and is \(field.kind) here; keep the kind or use a new field id"
            )
        }
    }
}

/// The first field of `table` whose id `other` declares with another kind, and that other kind.
private func clash(_ table: Spec.Table, _ other: Spec.Table) -> (Spec.AnyField, Spec.FieldKind)? {
    for field in table.fields {
        if let was = other.field(named: field.id.raw), was.kind != field.kind { return (field, was.kind) }
    }
    return nil
}

extension Spec {

    /// Gives every automation without a time zone this one. The builder calls it before saving.
    package func fillingTimeZone(_ zone: TimeZone) -> Spec {
        replacing(
            automations: automations.map { automation in
                Automation(
                    id: automation.id, prompt: automation.prompt,
                    schedule: Schedule(
                        cadence: automation.schedule.cadence, timeZone: automation.schedule.timeZone ?? zone),
                    writes: automation.writes)
            })
    }

    /// Records the stored bytes behind each listed asset. Saving calls it before hashing the revision.
    package func fillingDigests(_ digests: [AssetID: Digest]) -> Spec {
        replacing(
            assets: assets.map { asset in
                Asset(id: asset.id, about: asset.about, digest: digests[asset.id] ?? asset.digest)
            })
    }

    private func replacing(automations: [Automation]? = nil, assets: [Asset]? = nil) -> Spec {
        Spec(
            name: name, tables: tables, queries: queries, actions: actions,
            automations: automations ?? self.automations,
            assets: assets ?? self.assets, samples: samples, look: look)
    }

    private static func parse(document: JSONValue) throws(Diagnostic) -> Spec {
        let top = try Reader(document, else: "the document must be a JSON object, not \(document.described)")
        try top.requireOnly(topLevelKeys) {
            "unknown top-level key \(Diagnostic.quote($0)) (keys: \(topLevelKeys.joined(separator: ", ")))"
        }
        guard let name = try top.string("name", maxLength: Limits.nameLength) else {
            throw Diagnostic("missing \"name\": what the widget picker shows, like \"Water\"")
        }
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Diagnostic("\"name\" is empty; give what the widget picker shows, like \"Water\"")
        }
        guard case .string(let look)? = top["look"] else {
            throw Diagnostic(
                "\(top.has("look") ? "\"look\" must be" : "missing \"look\":") the JavaScript source as one string that defines function render(ctx)"
            )
        }
        guard !look.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Diagnostic("\"look\" is empty; write the JavaScript source that defines function render(ctx)")
        }
        guard look.utf8.count <= Limits.lookBytes else {
            throw Diagnostic("\"look\" is \(look.utf8.count) bytes; keep it to \(Limits.lookBytes) or fewer")
        }

        var tables: [Table] = []
        for (id, json) in try top.blocks(
            "tables", of: TableID.self, noun: "table", max: Limits.tables,
            example: "{\"items\": {\"fields\": {\"title\": \"text\"}}}")
        {
            tables.append(try Table.parse(id, json))
        }
        let resolver = Resolver(tables: tables)

        var queries: [Query] = []
        for (id, json) in try top.blocks(
            "queries", of: QueryID.self, noun: "query", max: Limits.queries,
            example: "{\"today\": {\"count\": \"items\", \"window\": \"today\"}}")
        {
            queries.append(try Query.parse(id, json, resolver))
        }
        let cells = queries.reduce(0) { total, query in
            switch query.shape {
            case .latest(let table, _, _): total + table.fields.count
            case .list(let table, _, _, let limit, _): total + limit * table.fields.count
            default: total
            }
        }
        guard cells <= Limits.queryCells else {
            throw Diagnostic(
                "list and latest queries return up to \(cells) field values together (rows times their table's fields, a latest counting one row); keep it to \(Limits.queryCells) or fewer by lowering list limits"
            )
        }
        var actions: [Action] = []
        for (id, json) in try top.blocks(
            "actions", of: ActionID.self, noun: "action", max: Limits.actions,
            example: "{\"add\": {\"insert\": \"items\"}}")
        {
            actions.append(try Action.parse(id, json, resolver))
        }
        var automations: [Automation] = []
        for (id, json) in try top.blocks(
            "automations", of: AutomationID.self, noun: "automation", max: Limits.automations,
            example: "{\"daily\": {\"prompt\": \"...\", \"every\": \"day\", \"at\": \"06:00\", \"writes\": \"words\"}}")
        {
            automations.append(try Automation.parse(id, json, resolver))
        }
        var assets: [Asset] = []
        for (id, json) in try top.blocks(
            "assets", of: AssetID.self, noun: "asset", max: Limits.assets,
            example: "{\"fox\": {\"about\": \"a watercolor fox\"}}")
        {
            assets.append(try Asset.parse(id, json))
        }
        return Spec(
            name: name, tables: tables, queries: queries, actions: actions, automations: automations, assets: assets,
            samples: try Sample.parseAll(top["samples"], resolver), look: look)
    }
}

/// Upgrade steps on raw JSON, keyed by the format they upgrade from. Blocks are data, so a format change
/// rewrites them here. A look is code and cannot be rewritten, so the look vocabulary is append-only: a node
/// or prop never disappears or changes meaning. Any addition to the blocks or the vocabulary bumps the
/// format, so an older engine refuses a newer document up front instead of failing on an unknown node
/// while rendering.
enum Upgrade {
    static let steps: [Int: @Sendable (JSONValue) throws(Diagnostic) -> JSONValue] = [:]

    static func toCurrent(_ document: JSONValue) throws(Diagnostic) -> JSONValue {
        guard case .object(let members) = document else {
            throw Diagnostic("the document must be a JSON object, not \(document.described)")
        }
        let current = Spec.currentFormat
        let format: Int
        switch members["format"] {
        case nil, .null?:
            return document
        case .number(let number)? where Int(exactly: number) != nil:
            format = Int(number)
        case let value?:
            throw Diagnostic(
                "\"format\" must be a whole number; leave it out or write \(current), not \(value.described)")
        }
        guard format <= current else {
            throw Diagnostic("format \(format) is newer than this app reads (\(current)); update the app")
        }
        guard format >= 1 else {
            throw Diagnostic("format \(format) does not exist; leave \"format\" out or write \(current)")
        }
        var upgraded = document
        for from in format..<current {
            guard let step = steps[from] else {
                throw Diagnostic("format \(from) has no upgrade to format \(from + 1) in this app")
            }
            upgraded = try step(upgraded)
        }
        return upgraded
    }
}
