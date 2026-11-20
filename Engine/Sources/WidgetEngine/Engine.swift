import CoreGraphics
import Foundation
import Rows
import Sandbox
import Spec
import Synchronization
import os

/// The whole runtime behind a few calls. One per process. The app and the widget extension each make one on
/// the same App Group directory. `WidgetBuilder` adds `build`, `source(of:)`, `history(of:)`, `restore`, and
/// `proof` to this type for the processes that import it.
public final class Engine: Sendable {
    /// Opens nothing yet. The store opens, and migrates if needed, on first use. A failure to open is reported
    /// by that call (a fallback face, or a thrown `EngineError`), and the next call tries again.
    ///
    /// `onCommit` runs after every committed write this engine makes: a tap, a form, a build, a restore, a
    /// delete. The app passes a WidgetKit reload, so no call site can forget one. The extension passes
    /// nothing, because WidgetKit reloads after an intent on its own.
    public init(
        directory: URL, calendar: Calendar = .autoupdatingCurrent, onCommit: (@Sendable () -> Void)? = nil
    ) {
        self.directory = directory
        self.calendar = calendar
        self.onCommit = onCommit
        self.sandbox = Sandbox()
        self.opened = Mutex(nil)
    }

    /// Timeline entries for a widget. `widget == nil` means the latest creation, or an onboarding face when
    /// there is none. Never throws: every failure becomes a fallback face and a log line.
    ///
    /// Runs `composeDrawing` at `date` and again at the next midnight, decoding each image once for both, so
    /// day windows flip on time without spending refresh budget. `reloadAt` is the midnight after that, or
    /// five minutes after the next automation run if that is sooner, so a dropped push is caught by the
    /// timeline.
    public func faces(for widget: WidgetID?, family: Family, size: CGSize, from date: Date) async -> Faces {
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
        var entries: [Face] = []
        for (instant, day) in [(date, today), (today.nextDayStart, midnight)] {
            do throws(Diagnostic) {
                let composition = try await composeDrawing(
                    spec: stored.spec, widget: stored.key, store: store, images: images, family: family, size: size,
                    pixelScale: 3, today: day, sandbox: sandbox, budget: .widget)
                entries.append(Face(date: instant, content: .drawing(composition.drawing)))
            } catch {
                log.error(
                    "widget \(stored.key.raw, privacy: .public) fell back on \(day.day.iso, privacy: .public): \(error.line, privacy: .private)"
                )
                entries.append(Face(date: instant, content: .fallback(name: stored.spec.name, reason: error.line)))
            }
        }
        let automation = stored.spec.automations.compactMap { $0.schedule.nextRun(after: date) }.min()
        let reloadAt = min(midnight.nextDayStart, automation?.addingTimeInterval(5 * 60) ?? .distantFuture)
        return Faces(entries: entries, reloadAt: reloadAt)
    }

    /// Applies a tapped action. Resolves the action by name, parses the row id, and asks the store to apply
    /// it at `date` in this engine's calendar. A form action needs `input`, checked against the form's field
    /// kinds before anything is written; any other action ignores it. A stale tap is a quiet no-op. Throws
    /// only when the store cannot be opened or written, or when form input has the wrong kind.
    public func perform(_ tap: Tap, input: [String: InputValue] = [:], at date: Date = .now) throws(EngineError) {
        let store = try self.store()
        guard let target = try target(of: tap, in: store) else { return }
        var row: RowKey?
        if let raw = tap.row {
            guard let key = RowKey(parsing: raw) else { return }
            row = key
        }
        var values: [Spec.FieldValue] = []
        if case .form(let form) = target.action.effect { values = try Self.values(input, for: form) }
        do throws(StoreError) {
            let applied = try store.apply(
                target.action, widget: target.widget.key, row: row, input: values,
                today: Today(at: date, calendar: calendar), at: date)
            if case .ignored(let reason) = applied {
                log.info("tap ignored: \(reason, privacy: .public)")
            }
        } catch {
            throw EngineError(message: error.message)
        }
    }

    /// The form a form button asks for, with the tapped row's current values when it edits one. Nil when the
    /// tap is stale or its action is not a form. The app calls this when the widget's link opens it.
    public func form(for tap: Tap) throws(EngineError) -> InputForm? {
        let store = try self.store()
        guard let target = try target(of: tap, in: store), case .form(let form) = target.action.effect else {
            return nil
        }
        var current: [Spec.FieldID: Spec.Cell]?
        if let raw = tap.row {
            guard let row = RowKey(parsing: raw) else { return nil }
            do throws(StoreError) {
                guard let cells = try store.values(of: row, in: form.table, widget: target.widget.key) else {
                    return nil
                }
                current = cells
            } catch {
                throw EngineError(message: error.message)
            }
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
        do throws(StoreError) {
            return try store.widgets().map {
                WidgetSummary(id: WidgetID(rawValue: $0.key.raw), name: $0.spec.name, createdAt: $0.createdAt)
            }
        } catch {
            throw EngineError(message: error.message)
        }
    }

    /// Removes the widget from `widgets()`. An id that names no widget changes nothing.
    public func delete(_ widget: WidgetID) throws(EngineError) {
        guard let key = WidgetKey(parsing: widget.rawValue) else { return }
        let store = try self.store()
        do throws(StoreError) {
            try store.delete(key)
        } catch {
            throw EngineError(message: error.message)
        }
    }

    /// Every engine in this process stops writing, and reads still work, so iOS never finds the app holding
    /// the database lock while suspended. The app calls this when it moves to the background, and `resume`
    /// when it returns. It is static because it reaches every store in the process.
    public static func suspend() { RowStore.suspend() }

    public static func resume() { RowStore.resume() }

    // MARK: Shared with WidgetBuilder

    package let directory: URL
    package let calendar: Calendar
    package let onCommit: (@Sendable () -> Void)?
    package let sandbox: Sandbox
    private let opened: Mutex<RowStore?>

    /// Opens the store once per engine. Later calls return the same instance. A failure is not kept, so the
    /// next call tries again.
    package func store() throws(EngineError) -> RowStore {
        try opened.withLock { (opened: inout RowStore?) throws(EngineError) -> RowStore in
            if let opened { return opened }
            do throws(StoreError) {
                let store = try RowStore.open(directory: directory, onCommit: onCommit)
                opened = store
                return store
            } catch {
                throw EngineError(message: "the store did not open: \(error.message)")
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

    /// The widget and action a tap names, or nil when the tap is stale: the widget is gone or the action was
    /// removed by a refinement.
    private func target(of tap: Tap, in store: RowStore) throws(EngineError) -> Target? {
        guard let key = WidgetKey(parsing: tap.widget) else { return nil }
        do throws(StoreError) {
            guard let widget = try store.widget(key), let action = widget.spec.action(named: tap.action) else {
                return nil
            }
            return Target(widget: widget, action: action)
        } catch {
            throw EngineError(message: error.message)
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

extension Faces {
    /// One calm face for a whole widget that cannot be drawn.
    fileprivate init(fallback reason: String, at date: Date, reloadAt: Date) {
        self.init(entries: [Face(date: date, content: .fallback(name: nil, reason: reason))], reloadAt: reloadAt)
    }
}

/// `dueDate` reads "Due date".
private func readable(_ id: String) -> String {
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
