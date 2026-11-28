import CoreGraphics
import Foundation
import Rows
import Sandbox
import Spec
import Synchronization
import os

/// The whole runtime behind a few calls. The app and the widget extension each make one on the same App Group
/// directory, and the app makes a scratch engine (`scratch()`) for each draft it previews. `WidgetBuilder`
/// adds the builder methods to this type for the processes that import it; "Interface depth" in
/// docs/engine/RATIONALE.md lists them.
public final class Engine: Sendable {
    /// Opens nothing yet. The store opens, and migrates if needed, on first use. A failure to open is reported
    /// by that call (a fallback face, or a thrown `EngineError`), and the next call tries again.
    ///
    /// `onCommit` runs after every committed write this engine makes: a tap, a form, a build, a restore, a
    /// delete. The app and the extension pass a WidgetKit reload, so no call site can forget one.
    public convenience init(
        directory: URL, calendar: Calendar = .autoupdatingCurrent, onCommit: (@Sendable () -> Void)? = nil
    ) {
        self.init(directory: directory, calendar: calendar, onCommit: onCommit, isScratch: false)
    }

    /// A throwaway engine for a draft the person has not saved, in a new folder of its own under the app's
    /// temporary directory. It deletes that folder when it is released, after closing its database, and runs
    /// no commit hook, so nothing it saves reaches the home screen or another engine. It keeps writing after
    /// `suspend()`, so a build can finish in the background. Only a scratch engine takes `load(_:into:)`,
    /// which replaces a widget's rows with sample rows.
    public static func scratch(calendar: Calendar = .autoupdatingCurrent) -> Engine {
        scratch(under: scratchRoot, calendar: calendar)
    }

    /// Deletes the folders of scratch engines that an earlier run never released, because it crashed or iOS
    /// ended it. The app calls this at launch. This run's scratch engines keep theirs.
    public static func removeLeftoverScratch() { removeLeftoverScratch(under: scratchRoot) }

    /// Scratch folders are `<root>/<run>/<engine>`, so the sweep can tell this run's folders from leftovers.
    package static func scratch(under root: URL, calendar: Calendar = .autoupdatingCurrent) -> Engine {
        Engine(
            directory: root.appending(path: run).appending(path: UUID().uuidString), calendar: calendar,
            onCommit: nil, isScratch: true)
    }

    package static func removeLeftoverScratch(under root: URL) {
        let runs = (try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))) ?? []
        for name in runs where name != run {
            try? FileManager.default.removeItem(at: root.appending(path: name))
        }
    }

    private init(directory: URL, calendar: Calendar, onCommit: (@Sendable () -> Void)?, isScratch: Bool) {
        BundledFonts.register()
        self.directory = directory
        self.calendar = calendar
        self.onCommit = onCommit
        self.isScratch = isScratch
        self.sandbox = Sandbox()
        self.opened = Mutex(nil)
    }

    /// Timeline entries for a widget. `widget == nil` means the latest creation, or an onboarding face when
    /// there is none. Never throws: every failure becomes a fallback face and a log line.
    ///
    /// Runs `composeDrawing` at `date` and again at the next midnight, decoding each image once for all
    /// entries, so day windows flip on time without spending refresh budget. When the look reads the clock
    /// (`ctx.now` or a row's `minutesAgo`), it is also drawn every 15 minutes for two hours, up to midnight,
    /// keeping only the entries whose picture changed, and the timeline reloads after those two hours, so
    /// "fed 11 h ago" turns into "Feed me!" within 15 minutes of the 12th hour. A row written ahead (an
    /// automation writes the next word a period early) stays hidden until its `at`, so the next such row gets an
    /// entry at its `at` too, and the timeline ends by the one after. `reloadAt` is the earliest of that reload,
    /// the midnight after the next one, five minutes after the next automation run in the phone's current time
    /// zone, so the pull after a run happens, and the second hidden row's `at`. No 15-minute step is drawn past
    /// that reload, which draws the face again.
    ///
    /// All entries share one image budget. When a later face's images would pass it, the timeline ends before
    /// that face and reloads at its date, so the next call draws it with a fresh budget. Only a current face
    /// whose images pass the budget on their own falls back.
    public func faces(for widget: WidgetID?, family: Family, size: CGSize, from date: Date) async -> Faces {
        await faces(for: widget, family: family, size: size, from: date, timeline: true)
    }

    /// The widget's face at `date` alone, without the later entries `faces` draws for a timeline, for a host
    /// that shows one picture now: the app's feed, a preview, the template pile. Never throws, as `faces`.
    ///
    /// Its one entry is the face, and `reloadAt` is when that face may next change, for the host to draw it
    /// again then: 15 minutes on for a look that reads the clock, else the next midnight, or five minutes after
    /// the next automation run or the `at` of the next row written ahead when either comes first.
    public func face(for widget: WidgetID?, family: Family, size: CGSize, at date: Date) async -> Faces {
        await faces(for: widget, family: family, size: size, from: date, timeline: false)
    }

    private func faces(for widget: WidgetID?, family: Family, size: CGSize, from date: Date, timeline: Bool)
        async -> Faces
    {
        let today = Today(at: date, calendar: calendar)
        let store: RowStore
        do throws(EngineError) {
            store = try self.store()
        } catch {
            log.error("faces fell back: \(error.message, privacy: .public)")
            return Faces(fallback: "store unavailable", at: date, reloadAt: date.addingTimeInterval(15 * 60))
        }
        let stored: StoredWidget
        do throws(StoreError) {
            guard let found = try find(widget, in: store) else {
                log.info("faces fell back: no widget \(widget?.rawValue ?? "yet", privacy: .public)")
                return Faces(fallback: "no widget", at: date, reloadAt: today.nextDayStart)
            }
            stored = found
        } catch {
            log.error("faces fell back: \(error.message, privacy: .private)")
            return Faces(fallback: "unreadable widget", at: date, reloadAt: today.nextDayStart)
        }

        // WidgetKit gives the provider no display scale, so images decode for 3x, the densest iPhone screen.
        let images = AssetImages.stored(stored.spec, store: store)
        let midnight = Today(at: today.nextDayStart, calendar: calendar)
        func compose(at instant: Date) async throws(Diagnostic) -> Composition {
            try await composeDrawing(
                spec: stored.spec, widget: stored.key, revision: stored.revision.hex, store: store, images: images,
                family: family, size: size,
                pixelScale: 3, today: Today(at: instant, calendar: calendar), sandbox: sandbox, budget: .widget)
        }
        func fallback(at instant: Date, _ error: Diagnostic) -> Face {
            let day = Today(at: instant, calendar: calendar)
            log.error(
                "widget \(stored.key.raw, privacy: .public) fell back on \(day.day.iso, privacy: .public) \(day.time, privacy: .public): \(error.line, privacy: .private)"
            )
            return Face(date: instant, content: .fallback(name: stored.spec.name, reason: error.line))
        }
        /// A later face and the tree the look returned, nil when the face fell back. The whole result is nil
        /// when the images this call already decoded leave no room for the face's own.
        func later(at instant: Date) async -> (face: Face, tree: String?)? {
            do throws(Diagnostic) {
                let composition = try await compose(at: instant)
                return (Face(date: instant, content: .drawing(composition.drawing)), composition.tree)
            } catch {
                if error.kind == .overImageBudget { return nil }
                return (fallback(at: instant, error), nil)
            }
        }

        let first: (face: Face, tree: String?, readsClock: Bool)
        do throws(Diagnostic) {
            let composition = try await compose(at: date)
            first = (Face(date: date, content: .drawing(composition.drawing)), composition.tree, composition.readsClock)
        } catch {
            first = (fallback(at: date, error), nil, false)
        }
        // Automations run in the phone's current time zone, the engine's calendar's, never the zone a document
        // was built in.
        let automation = stored.spec.automations.compactMap {
            $0.schedule.nextRun(after: date, in: calendar.timeZone)
        }.min()
        let automationReload = automation?.addingTimeInterval(5 * 60) ?? .distantFuture
        // Rows written ahead show from their `at` on: the next one gets an entry of its own, and the one after
        // ends the timeline, so each reveal lands at its time with no reload and no network.
        let reveals: [Date]
        do throws(StoreError) {
            reveals = try store.reveals(of: stored.key, after: date)
        } catch {
            log.error("faces drew no reveals: \(error.message, privacy: .public)")
            reveals = []
        }
        guard timeline else {
            let clock = first.readsClock ? date.addingTimeInterval(Self.clockStep) : .distantFuture
            return Faces(
                entries: [first.face],
                reloadAt: min(today.nextDayStart, clock, automationReload, reveals.first ?? .distantFuture))
        }
        let clockReload =
            first.readsClock ? date.addingTimeInterval(Self.clockStep * Double(Self.clockSteps)) : .distantFuture
        let end = min(
            midnight.nextDayStart, clockReload, automationReload, reveals.dropFirst().first ?? .distantFuture)
        // Each later instant, and whether its face is kept even when it draws what the one before drew.
        var planned: [(instant: Date, kept: Bool)] = []
        if first.readsClock {
            for index in 1...Self.clockSteps {
                let instant = date.addingTimeInterval(Self.clockStep * Double(index))
                // A step after `end` would only spend the image budget: the reload at `end` draws it again.
                guard instant < today.nextDayStart, instant <= end else { break }
                planned.append((instant, false))
            }
        }
        planned.append((today.nextDayStart, true))
        if let reveal = reveals.first, reveal <= end {
            planned.removeAll { $0.instant == reveal }
            planned.append((reveal, true))
            planned.sort { $0.instant < $1.instant }
        }
        var entries = [first.face]
        // The first later instant whose images do not fit. The timeline ends there, and the one WidgetKit asks
        // for at that instant starts with a fresh image budget.
        var cut: Date?
        var shown = first.tree
        for (instant, kept) in planned {
            guard let next = await later(at: instant) else {
                cut = instant
                break
            }
            if kept || next.tree == nil || next.tree != shown { entries.append(next.face) }
            shown = next.tree
        }
        return Faces(entries: entries, reloadAt: min(cut ?? .distantFuture, end))
    }

    /// Applies a tapped action. Resolves the action by name in the revision the button was drawn from (the
    /// tap's `revision`, which must be in the live widget's history), parses the row id and the day, and asks
    /// the store to apply it at `date` in this engine's calendar. So what the user pressed is what runs, even
    /// after a refinement reused the action's id for another effect. A form action needs `input`, checked
    /// against the form's field kinds before anything is written; any other action ignores it. A stale tap
    /// (the widget is gone, the revision is missing, malformed, or not this widget's, the action is not in that
    /// revision) is a no-op with a log line, and so is a malformed row id or day. Throws only when
    /// the store cannot be opened or written, or when form input names a field the form lacks or has the wrong
    /// kind.
    public func perform(_ tap: Tap, input: [String: InputValue] = [:], at date: Date = .now) throws(EngineError) {
        let store = try self.store()
        guard let target = try target(of: tap, in: store) else { return }
        var row: RowKey?
        if let raw = tap.row {
            guard let key = RowKey(parsing: raw) else {
                log.info("tap ignored: row id \(raw, privacy: .public) is malformed")
                return
            }
            row = key
        }
        var day: Day?
        if let raw = tap.day {
            guard let parsed = Day(iso: raw) else {
                log.info("tap ignored: day \(raw, privacy: .public) is malformed")
                return
            }
            day = parsed
        }
        var values: [Spec.FieldValue] = []
        if case .form(let form) = target.action.effect { values = try Self.values(input, for: form) }
        let applied = try attempt { () throws(StoreError) in
            try store.apply(
                target.action, widget: target.widget.key, row: row, day: day, input: values,
                today: Today(at: date, calendar: calendar), at: date)
        }
        if case .ignored(let reason) = applied {
            log.info("tap ignored: \(reason, privacy: .public)")
        }
    }

    /// The form a form button asks for, as the tap's revision defines it, with the tapped row's current values
    /// when it edits one. Nil when the tap is stale, as `perform` judges it, or its action is not a form. The
    /// app calls this when the widget's link opens it.
    public func form(for tap: Tap) throws(EngineError) -> InputForm? {
        let store = try self.store()
        guard let target = try target(of: tap, in: store), case .form(let form) = target.action.effect else {
            return nil
        }
        var current: [Spec.FieldID: Spec.Cell]?
        if let raw = tap.row {
            guard let row = RowKey(parsing: raw) else { return nil }
            guard
                let cells = try attempt({ () throws(StoreError) in
                    try store.values(of: row, in: form.table, widget: target.widget.key)
                })
            else { return nil }
            current = cells
        }
        return InputForm(
            tap: tap, title: form.prompt ?? readable(target.action.id.raw),
            fields: form.fields.map { field in
                InputField(
                    id: field.id.raw, label: readable(field.id.raw), kind: field.kind.input,
                    value: current.flatMap { field.input(from: $0[field.id]) })
            })
    }

    /// Newest first. The widget picker's default is the first entry.
    public func widgets() throws(EngineError) -> [WidgetSummary] {
        let store = try self.store()
        return try attempt { () throws(StoreError) in try store.widgets() }.map {
            WidgetSummary(id: WidgetID(rawValue: $0.key.raw), name: $0.spec.name, createdAt: $0.createdAt)
        }
    }

    /// Removes the widget from `widgets()`. An id that names no widget changes nothing.
    public func delete(_ widget: WidgetID) throws(EngineError) {
        guard let key = WidgetKey(parsing: widget.rawValue) else { return }
        let store = try self.store()
        try attempt { () throws(StoreError) in try store.delete(key) }
    }

    /// Merges a page of the account's changes from the server, in one transaction with the page's automation
    /// replica (whose rows then count as the person's own) and the watermark, which never moves backwards. It
    /// stops at the first change stamped more than 10 minutes ahead of `date`, so that change and the rest come
    /// again in the next pull, and drops for good a cell over the limits a tap obeys; both are logged.
    /// `onCommit` runs only when the page changed a row, a cell, or who counts as the person, so a replayed page
    /// reloads nothing. Throws for a scratch engine, which never syncs (its rows may be a copy of the person's under
    /// their dataset keys), and when the store cannot be opened or written.
    public func receive(_ page: RemotePage, at date: Date = .now) throws(EngineError) {
        let store = try self.store()
        let received = try attempt { () throws(StoreError) in try store.receive(page.page, now: date) }
        if let first = received.held.first {
            let ahead = Int((first.stamp.milliseconds - Int64(date.timeIntervalSince1970 * 1000)) / 1000)
            log.error(
                "pull stopped at a change stamped \(ahead, privacy: .public) s ahead of this clock; \(received.held.count, privacy: .public) changes wait for the next pull"
            )
        }
        for refused in received.refused {
            guard case .setCell(let row, _, let field, _) = refused.change else { continue }
            log.error(
                "pull refused a cell over the limits: field \(field, privacy: .public) of row \(row.raw, privacy: .public)"
            )
        }
    }

    /// The server id of the last change a page passed, or 0 before the first: the `after` of the next pull.
    public func watermark() throws(EngineError) -> Int {
        let store = try self.store()
        return Int(try attempt { () throws(StoreError) in try store.watermark() })
    }

    /// Every automation of the account, as the body of `PUT /v1/automations` (docs/engine/WIRE.md): one entry
    /// per automation of each live widget, as the revision it draws defines it, with the dataset it writes, plus
    /// this engine's current time zone, which every automation runs in. The digest changes whenever the body
    /// does: after a save, a refinement, a restore, a delete, or a move to another time zone.
    /// Throws when a live widget's drawn revision cannot be read on this device, since the upload replaces every
    /// automation and leaving that widget's automations out would make the server delete their future rows. Throws
    /// for a scratch engine, which never syncs: its widgets are drafts, and their upload would replace the person's.
    public func automationPayload() throws(EngineError) -> AutomationPayload {
        let store = try self.store()
        let payload = try attempt { () throws(StoreError) in try store.automationPayload(timeZone: calendar.timeZone) }
        return AutomationPayload(json: payload.json, digest: payload.digest.hex)
    }

    /// Every engine in this process but the scratch ones stops writing, and reads still work, so iOS never
    /// finds the app holding the shared database lock while suspended. An engine whose store is not open yet
    /// cannot open it until `resume`, and says so with `EngineError.isSuspended`. The app calls this when it moves to the
    /// background, and `resume` when it returns. It is static because it reaches every store in the process.
    public static func suspend() { RowStore.suspend() }

    public static func resume() { RowStore.resume() }

    // MARK: Shared with WidgetBuilder

    package let directory: URL
    package let calendar: Calendar
    package let onCommit: (@Sendable () -> Void)?
    package let isScratch: Bool
    package let sandbox: Sandbox
    private let opened: Mutex<RowStore?>

    /// A look that reads the clock is drawn again every `clockStep`, `clockSteps` times: two hours.
    static let clockStep: TimeInterval = 15 * 60
    static let clockSteps = 8

    private static let scratchRoot = URL.temporaryDirectory.appending(path: "scratch-engines")
    private static let run = UUID().uuidString

    /// Opens the store once per engine. Later calls return the same instance. A failure is not kept, so the
    /// next call tries again.
    package func store() throws(EngineError) -> RowStore {
        try opened.withLock { (opened: inout RowStore?) throws(EngineError) -> RowStore in
            if let opened { return opened }
            do throws(StoreError) {
                let store = try RowStore.open(directory: directory, onCommit: onCommit, isScratch: isScratch)
                opened = store
                return store
            } catch {
                throw EngineError(message: "the store did not open: \(error.message)", isSuspended: error.suspended)
            }
        }
    }

    // MARK: Private

    private struct Target {
        let widget: StoredWidget
        let action: Spec.Action
    }

    private func find(_ widget: WidgetID?, in store: RowStore) throws(StoreError) -> StoredWidget? {
        guard let widget else { return try store.widgets().first }
        guard let key = WidgetKey(parsing: widget.rawValue) else { return nil }
        return try store.widget(key)
    }

    /// The live widget a tap names and its action as the tap's revision defines it, or nil with a log line
    /// when the tap is stale: the widget is gone, the tap has no revision, a malformed one, or one outside the
    /// widget's history, that revision does not parse, or it has no such action.
    private func target(of tap: Tap, in store: RowStore) throws(EngineError) -> Target? {
        func stale(_ reason: String) -> Target? {
            log.info("tap ignored: \(reason, privacy: .public)")
            return nil
        }
        guard let key = WidgetKey(parsing: tap.widget) else { return stale("no widget \(tap.widget)") }
        return try attempt { () throws(StoreError) -> Target? in
            guard let widget = try store.widget(key) else { return stale("widget \(key.raw) is not live") }
            guard let raw = tap.revision, let revision = Spec.Digest(hex: raw) else {
                return stale("the tap names no revision of widget \(key.raw)")
            }
            let spec: Spec
            if revision == widget.revision {
                spec = widget.spec
            } else {
                guard let body = try store.revision(revision, of: key) else {
                    return stale("revision \(revision) is not in the history of widget \(key.raw)")
                }
                guard let parsed = try? Spec.parse(body) else {
                    return stale("revision \(revision) of widget \(key.raw) does not parse")
                }
                spec = parsed
            }
            guard let action = spec.action(named: tap.action) else {
                return stale("revision \(revision) has no action \(tap.action)")
            }
            return Target(widget: widget, action: action)
        }
    }

    private static func values(_ input: [String: InputValue], for form: Spec.Form) throws(EngineError)
        -> [Spec.FieldValue]
    {
        var values: [Spec.FieldValue] = []
        for (name, value) in input.sorted(by: { $0.key < $1.key }) {
            guard let field = form.fields.first(where: { $0.id.raw == name }) else {
                throw EngineError(
                    message:
                        "the form has no field \"\(name)\" (fields: \(form.fields.map(\.id.raw).joined(separator: ", ")))"
                )
            }
            do throws(Diagnostic) {
                values.append(try field.value(from: value.json))
            } catch {
                throw EngineError(message: error.line)
            }
        }
        return values
    }
}

private let log = Logger(subsystem: "WidgetEngine", category: "engine")

/// Runs a store call and reports its failure as an `EngineError`, the one error the public API throws.
package func attempt<T>(_ body: () throws(StoreError) -> T) throws(EngineError) -> T {
    do throws(StoreError) {
        return try body()
    } catch {
        throw EngineError(message: error.message, isSuspended: error.suspended)
    }
}

extension Faces {
    /// One calm face for a whole widget that cannot be drawn.
    fileprivate init(fallback reason: String, at date: Date, reloadAt: Date) {
        self.init(entries: [Face(date: date, content: .fallback(name: nil, reason: reason))], reloadAt: reloadAt)
    }
}

/// An id as words: `dueDate` reads "Due date", `add10Pushups` "Add 10 pushups".
func readable(_ id: String) -> String {
    var words = ""
    for character in id {
        if character.isUppercase || (character.isNumber && !(words.last?.isNumber ?? true)) { words.append(" ") }
        words.append(Character(character.lowercased()))
    }
    return words.prefix(1).uppercased() + words.dropFirst()
}

extension InputValue {
    fileprivate var json: JSONValue {
        switch self {
        case .text(let text): .string(text)
        case .number(let number): .number(number)
        case .toggle(let flag): .bool(flag)
        case .date(let year, let month, let day): .string(String(format: "%04d-%02d-%02d", year, month, day))
        }
    }
}

extension Spec.FieldKind {
    fileprivate var input: InputField.Kind {
        switch self {
        case .text: .text
        case .number: .number
        case .bool: .toggle
        case .date: .date
        }
    }
}

extension Spec.AnyField {
    /// A stored value as the form shows it. A bool with no value is off, as everywhere else.
    fileprivate func input(from cell: Spec.Cell?) -> InputValue? {
        switch cell {
        case .text(let text)?:
            return .text(text)
        case .number(let number)?:
            return .number(number)
        case .bool(let flag)?:
            return .toggle(flag)
        case .date(let day)?:
            let parts = day.iso.split(separator: "-").compactMap { Int($0) }
            return .date(year: parts[0], month: parts[1], day: parts[2])
        case nil:
            return kind == .bool ? .toggle(false) : nil
        }
    }
}
