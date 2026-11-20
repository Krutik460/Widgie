import Foundation

extension Spec {
    package struct Action: Hashable, Sendable {
        package let id: ActionID
        package let effect: Effect
    }

    /// The closed write set.
    package enum Effect: Hashable, Sendable {
        /// A new row on today's day with these values. Fields it does not list have no value.
        case insert(Table, [FieldValue])
        /// A new row with these values on the day the button names, one of `loggableDays`: "I forgot
        /// yesterday".
        case insertOn(Table, [FieldValue])
        /// One field of the tapped row.
        case set(FieldValue)
        /// Flips one bool field of the tapped row. A field with no value counts as false.
        case toggle(Field<Bool>)
        /// Deletes the tapped row.
        case delete(Table)
        /// Asks the user for values in the app. With a tapped row it edits that row, without one it inserts.
        case form(Form)

        package var table: TableID {
            switch self {
            case .insert(let table, _), .insertOn(let table, _), .delete(let table): table.id
            case .set(let value): value.field.table
            case .toggle(let field): field.table
            case .form(let form): form.table.id
            }
        }

        /// Derived from the case, so the tree validator and `perform` agree on whether a button needs a
        /// `rowId`.
        package var rowUse: RowUse {
            switch self {
            case .insert, .insertOn: .never
            case .set, .toggle, .delete: .required
            case .form: .optional
            }
        }

        /// Whether a button for this effect names a day. Derived from the case, so the tree validator and
        /// `apply` agree.
        package var needsDay: Bool {
            if case .insertOn = self { true } else { false }
        }

        /// The days an `insertOn` may write to, seen from `today`: today and the 365 days before it. The tree
        /// validator checks a button's day against the render's today, and `apply` against the tap's.
        package static func loggableDays(from today: Day) -> ClosedRange<Day> {
            today.adding(-365)...today
        }
    }

    package enum RowUse: Sendable {
        case never
        case required
        case optional
    }

    /// A widget cannot show a form, so a button for this effect opens the app through a link.
    package struct Form: Hashable, Sendable {
        package let table: Table
        /// In the order the document lists them. Never empty, and every field belongs to `table`.
        package let fields: [AnyField]
        /// The form's title. Nil means the app picks one.
        package let prompt: String?
    }
}

extension Spec.Action {
    private enum Kind: String, CaseIterable {
        case insert, insertOn, set, toggle, delete, form

        var keys: [String] {
            switch self {
            case .insert: ["insert", "values"]
            case .insertOn: ["insertOn", "values"]
            case .set: ["set", "to"]
            case .toggle: ["toggle"]
            case .delete: ["delete"]
            case .form: ["fields", "form", "prompt"]
            }
        }
    }

    static func parse(_ id: Spec.ActionID, _ json: JSONValue, _ resolver: Resolver) throws(Diagnostic) -> Spec.Action {
        do throws(Diagnostic) {
            let action = try Reader(
                json, else: "an action must be an object like {\"insert\": \"items\"}, not \(json.described)")
            let kinds = Kind.allCases.filter { action.has($0.rawValue) }
            let effectList = Kind.allCases.map(\.rawValue).joined(separator: ", ")
            guard let kind = kinds.first else {
                throw Diagnostic("needs one of \(effectList), like {\"insert\": \"items\"}")
            }
            guard kinds.count == 1 else {
                throw Diagnostic(
                    "has both \"\(kinds[0].rawValue)\" and \"\(kinds[1].rawValue)\"; use exactly one of \(effectList)")
            }
            try action.requireOnly(kind.keys) {
                "\(kind.rawValue) takes no \(Diagnostic.quote($0)) (keys: \(kind.keys.joined(separator: ", ")))"
            }
            let target = action[kind.rawValue] ?? .null
            switch kind {
            case .insert, .insertOn:
                let table = try resolver.table(target, for: kind.rawValue)
                var values: [Spec.FieldValue] = []
                if let given = action["values"] {
                    do throws(Diagnostic) {
                        values = try table.values(
                            Reader(given, else: "must map field ids to values, like {\"done\": false}"))
                    } catch {
                        throw error.within("values")
                    }
                }
                return Spec.Action(id: id, effect: kind == .insert ? .insert(table, values) : .insertOn(table, values))
            case .set:
                let (_, field) = try resolver.field(target, for: "set")
                guard let given = action["to"] else {
                    throw Diagnostic("set needs \"to\": the value to store in \"\(field.path)\", a \(field.kind)")
                }
                do throws(Diagnostic) {
                    return Spec.Action(id: id, effect: .set(try field.value(from: given)))
                } catch {
                    throw error.within("to")
                }
            case .toggle:
                return Spec.Action(
                    id: id, effect: .toggle(try resolver.field(target, for: "toggle", of: Bool.self).field))
            case .delete:
                return Spec.Action(id: id, effect: .delete(try resolver.table(target, for: "delete")))
            case .form:
                let table = try resolver.table(target, for: "form")
                return Spec.Action(
                    id: id,
                    effect: .form(
                        Spec.Form(
                            table: table, fields: try formFields(action["fields"], table),
                            prompt: try action.string("prompt", maxLength: Spec.Limits.formPromptLength))))
            }
        } catch {
            throw error.within("action \(Diagnostic.quote(id.raw))")
        }
    }

    private static func formFields(_ value: JSONValue?, _ table: Spec.Table) throws(Diagnostic) -> [Spec.AnyField] {
        let request = "form needs \"fields\": a list of field ids of \(table.id.raw) to ask for \(table.fieldChoices)"
        guard case .array(let names) = value, !names.isEmpty else { throw Diagnostic(request) }
        var fields: [Spec.AnyField] = []
        for name in names {
            guard case .string(let raw) = name else { throw Diagnostic("\(request), not \(name.described)") }
            guard let field = table.field(named: raw) else {
                throw Diagnostic(
                    "form asks for no field \(Diagnostic.quote(raw)) in \(table.id.raw) \(table.fieldChoices)")
            }
            guard !fields.contains(field) else { throw Diagnostic("form lists \(Diagnostic.quote(raw)) twice") }
            fields.append(field)
        }
        return fields
    }

    var json: JSONValue {
        switch effect {
        case .insert(let table, let values):
            return .object(["insert": .string(table.id.raw), "values": values.json])
        case .insertOn(let table, let values):
            return .object(["insertOn": .string(table.id.raw), "values": values.json])
        case .set(let value):
            return .object(["set": .string(value.field.path), "to": value.value.json])
        case .toggle(let field):
            return .object(["toggle": .string(field.path)])
        case .delete(let table):
            return .object(["delete": .string(table.id.raw)])
        case .form(let form):
            var members: [String: JSONValue] = [
                "form": .string(form.table.id.raw), "fields": .array(form.fields.map { .string($0.id.raw) }),
            ]
            if let prompt = form.prompt { members["prompt"] = .string(prompt) }
            return .object(members)
        }
    }
}

extension Spec.Table {
    /// Reads `{ field: value }` pairs, in field id order, from every key of `object` except `skipping`.
    func values(_ object: Reader, skipping: [String] = []) throws(Diagnostic) -> [Spec.FieldValue] {
        var values: [Spec.FieldValue] = []
        for key in object.keys where !skipping.contains(key) {
            guard let field = field(named: key) else {
                throw Diagnostic("no field \(Diagnostic.quote(key)) in \(id.raw) \(fieldChoices)")
            }
            values.append(try field.value(from: object[key] ?? .null))
        }
        return values
    }
}
