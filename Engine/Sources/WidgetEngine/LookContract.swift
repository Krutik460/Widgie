import CoreGraphics
import Foundation
import Rows
import Sandbox
import Spec

// The look contract: what goes into `render(ctx)` and what may come out. Both halves live in this module,
// beside the renderer, so the shape the model is taught and the shape the engine enforces have one owner.
// The vocabulary itself is the registry in Vocabulary.swift.

/// Builds `ctx` as JSON text:
/// `{ data: { queryId: result }, family, width, height, now, today: { date, weekday, week } }`.
/// - `count`, `sum`, `streak`: a number. `latest`: a row or null. `list`: a list of rows.
/// - `daily`: a list of `{ date, weekday, count }`, oldest first and today last, with `sum` added when it
///   measures a field.
/// - A row is `{ id, day, daysAgo, at, minutesAgo, by: { me, name }, ...fields }`. `at` is the time it was
///   written as `HH:MM` in the reader's time zone, `minutesAgo` the whole minutes from then to `now`, and
///   `by.name` the writer's name or null when no name is known. Dates are ISO strings, weekdays are `Mon` to `Sun`, a bool
///   field with no value is `false`, and any other field with no value is `null`. The fields come from the
///   query's table in `spec`, so a row lists every field of its table.
/// - `now` is the render's time as `HH:MM` on a 24-hour clock.
/// - `today.week` is the seven ISO dates of the current week, first day first, by the user's calendar.
/// Numbers that are whole encode without a fraction, so `3` reads as `3`, not `3.0`. Keys are sorted, so the
/// same input always gives the same bytes.
package func lookContext(
    results: [Spec.QueryID: QueryResult], spec: Spec, family: Family, size: CGSize, today: Today
) -> String {
    var data: [String: JSONValue] = [:]
    for query in spec.queries {
        guard let result = results[query.id] else { continue }
        let fields = spec.table(named: query.shape.table.raw)?.fields ?? []
        func row(_ row: RowValue) -> JSONValue {
            var members: [String: JSONValue] = [
                "id": .string(row.key.raw), "day": .string(row.day.iso),
                "daysAgo": .number(Double(today.day.index - row.day.index)),
                "at": .string(today.clock(row.at)), "minutesAgo": .number(Double(today.minutes(since: row.at))),
                "by": .object(["me": .bool(row.by.me), "name": row.by.name.map(JSONValue.string) ?? .null]),
            ]
            for field in fields {
                members[field.id.raw] = row.values[field.id].map(cell) ?? (field.kind == .bool ? .bool(false) : .null)
            }
            return .object(members)
        }
        switch result {
        case .number(let number): data[query.id.raw] = .number(number)
        case .row(let value): data[query.id.raw] = value.map(row) ?? .null
        case .rows(let values): data[query.id.raw] = .array(values.map(row))
        case .days(let days):
            data[query.id.raw] = .array(
                days.map { entry in
                    var members: [String: JSONValue] = [
                        "date": .string(entry.day.iso), "weekday": .string(entry.day.weekday.short),
                        "count": .number(Double(entry.count)),
                    ]
                    if let sum = entry.sum { members["sum"] = .number(sum) }
                    return .object(members)
                })
        }
    }
    let context = JSONValue.object([
        "data": .object(data),
        "family": .string(family.rawValue),
        "width": .number(Double(size.width)),
        "height": .number(Double(size.height)),
        "now": .string(today.time),
        "today": .object([
            "date": .string(today.day.iso), "weekday": .string(today.day.weekday.short),
            "week": .array(today.week.map { .string($0.iso) }),
        ]),
    ])
    return String(decoding: context.encoded(), as: UTF8.self)
}

private func cell(_ cell: Spec.Cell) -> JSONValue {
    switch cell {
    case .text(let text): .string(text)
    case .number(let number): .number(number)
    case .bool(let flag): .bool(flag)
    case .date(let day): .string(day.iso)
    }
}

/// What a tree may refer to, resolved before validation.
package struct Bindings: Sendable {
    package let widget: WidgetID
    /// The digest of the revision being drawn, stamped on every tap. Proofs draw a spec that may never be
    /// saved, so they pass `Bindings.unsaved`, which is not a digest and so never names a stored revision.
    package let revision: String
    package let spec: Spec
    /// The ids of the rows the look received, by the table each came from. A button's `rowId` must be one
    /// of these for its action's table. `rows(in:spec:)` derives it from the query results.
    package let rows: [Spec.TableID: Set<String>]
    /// The render's day. A button's `day` must be in `Spec.Effect.loggableDays(from: today)`.
    package let today: Day
    package let images: AssetImages
    package let family: Family
    package let size: CGSize
    package let pixelScale: Double

    package static let unsaved = "unsaved"

    package init(
        widget: WidgetID, revision: String, spec: Spec, rows: [Spec.TableID: Set<String>], today: Day,
        images: AssetImages,
        family: Family, size: CGSize, pixelScale: Double
    ) {
        self.widget = widget
        self.revision = revision
        self.spec = spec
        self.rows = rows
        self.today = today
        self.images = images
        self.family = family
        self.size = size
        self.pixelScale = pixelScale
    }

    /// Every row id in `results`, under the table its query reads.
    package static func rows(in results: [Spec.QueryID: QueryResult], spec: Spec) -> [Spec.TableID: Set<String>] {
        var rows: [Spec.TableID: Set<String>] = [:]
        for query in spec.queries {
            switch results[query.id] {
            case .row(let value?)?: rows[query.shape.table, default: []].insert(value.key.raw)
            case .rows(let values)?: rows[query.shape.table, default: []].formUnion(values.map(\.key.raw))
            default: break
            }
        }
        return rows
    }
}

extension Drawing {
    /// The one tree validator. Runs on every widget render and on every proof render.
    ///
    /// Grammar: the registry in Vocabulary.swift. Unknown node types and props fail with the allowed list.
    /// Values are range-checked (finite numbers, hex colors, alignment names, 0...1 trims and crops),
    /// `fontName` must be in `Vocabulary.fonts`, and symbol names must exist on this platform. The tree has
    /// at most `Limits.nodes` nodes, nested at most `Limits.depth` deep.
    ///
    /// References: a button's `action` must name an action in the spec. Its `rowId` must be present exactly
    /// when that action's `rowUse` requires it, and must be a row the look received for the action's table.
    /// Its `day` must be present exactly when the action `needsDay`, and must be a loggable day.
    /// An image's `asset` must be a spec asset that `images` can decode. A button for a form action becomes
    /// `.form`, which the host turns into a link. Every failure is one line that names the node path:
    /// `button at root.children[4].children[0]: action "undo" needs "rowId": the id of the row it deletes`.
    package static func parse(tree json: String, bindings: Bindings) throws(Diagnostic) -> Drawing {
        let tree: JSONValue
        do throws(Diagnostic) {
            tree = try JSONValue.parse(Data(json.utf8))
        } catch {
            throw Diagnostic("render(ctx) returned text that is not JSON: \(error.line)")
        }
        var parser = TreeParser(bindings: bindings)
        let root = try parser.node(tree, at: "root", depth: 0, place: .tree, extra: Vocabulary.rootProps)
        var background: Layer?
        if case .object(let members) = tree, case .string(let type)? = members["type"] {
            let props = Props(type: type, path: "root", depth: 0, place: .tree, members: members)
            background = try parser.layer(
                props, "widgetBackground",
                place: .untappable("the widget background cannot be tapped, so it cannot hold a button"))
        }
        return Drawing(
            root: root, background: background, size: bindings.size, family: bindings.family, taps: parser.taps)
    }
}

/// The most UTF-8 bytes of JSON `composeDrawing` hands a look as `ctx`. The parse-time cell cap keeps real
/// widgets well under it; this is the backstop for long text in every cell.
package let contextLimit = 1024 * 1024

/// What one pass of `composeDrawing` made, and what it was made from. The builder reruns the look on these
/// results with one query emptied, and compares the tree, to find a query no render depends on.
package struct Composition: Sendable {
    package let drawing: Drawing
    package let results: [Spec.QueryID: QueryResult]
    /// The tree as the look returned it, before validation.
    package let tree: String
    /// Whether the look read `ctx.now` or a row's `minutesAgo`, so its picture can change while the data
    /// stands still.
    package let readsClock: Bool
}

/// The context keys whose values change with the render time alone.
let clockKeys = ["now", "minutesAgo"]

/// The one path from stored state to a `Drawing`. `Engine.faces` and the builder's proofs both call it, so
/// a proof exercises exactly what a widget will run.
///
/// Steps: `store.results(of: spec.queries, ...)`, then `lookContext`, refused over `contextLimit` bytes, then
/// `sandbox.run(spec.look, ...)` (a `Sandbox.Failure` becomes `Diagnostic(failure.line)`), then
/// `Drawing.parse` with the row ids of the same results and `revision` in its `Bindings`.
package func composeDrawing(
    spec: Spec, widget: WidgetKey, revision: String, store: RowStore, images: AssetImages,
    family: Family, size: CGSize, pixelScale: Double, today: Today, sandbox: Sandbox, budget: Sandbox.Budget
) async throws(Diagnostic) -> Composition {
    let results: [Spec.QueryID: QueryResult]
    do throws(StoreError) {
        results = try store.results(of: spec.queries, widget: widget, today: today)
    } catch {
        throw Diagnostic("the widget's data could not be read: \(error.message)")
    }
    let context = lookContext(results: results, spec: spec, family: family, size: size, today: today)
    guard context.utf8.count <= contextLimit else {
        throw Diagnostic(
            "ctx is \(context.utf8.count / 1024) KB of JSON, more than \(contextLimit / 1024) KB; lower the list limits so the queries return fewer rows"
        )
    }
    let output: Sandbox.Output
    do throws(Sandbox.Failure) {
        output = try await sandbox.run(spec.look, context: context, watching: clockKeys, budget: budget)
    } catch {
        throw Diagnostic(error.line)
    }
    let tree = output.tree
    let drawing = try Drawing.parse(
        tree: tree,
        bindings: Bindings(
            widget: WidgetID(rawValue: widget.raw), revision: revision, spec: spec,
            rows: Bindings.rows(in: results, spec: spec),
            today: today.day, images: images, family: family, size: size, pixelScale: pixelScale))
    return Composition(drawing: drawing, results: results, tree: tree, readsClock: output.readWatched)
}
