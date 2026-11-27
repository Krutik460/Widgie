import Foundation
import Observation
import WidgetBuilder
import WidgetEngine
import WidgetHosting
import WidgetKit

/// The app's view of the shared store: the widgets, their faces in both sizes, and the open form.
@MainActor @Observable
final class Library {
    struct Item: Identifiable {
        let summary: WidgetSummary
        var faces: [Family: Face]
        var id: WidgetID { summary.id }
    }

    private(set) var items: [Item] = []
    /// Whether `items` has been read from the store yet.
    private(set) var loaded = false
    /// The sizes each widget is placed in on the home screen. A widget missing here is not placed.
    private(set) var placed: [WidgetID: Set<Family>] = [:]
    /// The faces' sizes, set from the width of the screen showing them.
    private(set) var sizes = FaceSizes(column: Family.medium.standardSize.width)
    var form: ShownForm?
    var message: String?

    private let engine: Engine
    private var reloads = 0

    init(engine: Engine = Hosting.engine) {
        self.engine = engine
    }

    /// The reference widgets bundled in debug builds: each folder and the name its widget gives itself.
    let fixtures: [(folder: String, name: String)] = {
        guard let root = Bundle.main.url(forResource: "Fixtures", withExtension: nil),
            let folders = try? FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
        else { return [] }
        struct Named: Decodable { let name: String }
        return folders.sorted().map { folder in
            let json = root.appending(path: folder).appending(path: "widget.json")
            let name = (try? JSONDecoder().decode(Named.self, from: Data(contentsOf: json)))?.name
            return (folder, name ?? folder)
        }
    }()

    func refresh() {
        Task { await reload() }
    }

    /// Draws the faces for a column this wide, as the home screen would.
    func fit(column width: CGFloat) {
        let sizes = FaceSizes(column: width)
        guard sizes != self.sizes else { return }
        self.sizes = sizes
        refresh()
    }

    /// Each widget, newest first, and the size it is shown in.
    var shown: [(id: WidgetID, family: Family)] { Self.shown(items.map(\.id), placed: placed) }

    /// `ids` newest first, each with its size. Deleting an older unplaced widget shifts the rhythm, so the unplaced
    /// ones newer than it can change size.
    static func shown(_ ids: [WidgetID], placed: [WidgetID: Set<Family>]) -> [(id: WidgetID, family: Family)] {
        ids.enumerated().map { index, id in (id, family(placed: placed[id] ?? [], age: ids.count - 1 - index)) }
    }

    /// The size it is placed in, medium if it is placed in both, and otherwise every third widget wide, so the feed
    /// keeps a rhythm of one wide and a pair of smalls. Counted from the oldest (`age` 0), so a new widget never
    /// changes the size of the ones before it.
    static func family(placed: Set<Family>, age: Int) -> Family {
        if placed.contains(.medium) { return .medium }
        if placed.contains(.small) { return .small }
        return age % 3 == 0 ? .medium : .small
    }

    /// A reload that finishes after a later one started is stale and is dropped, so it never brings back a
    /// widget the later one no longer found.
    func reload() async {
        reloads += 1
        let reload = reloads
        do {
            var items: [Item] = []
            for summary in try engine.widgets() {
                var faces: [Family: Face] = [:]
                for family in Family.allCases {
                    faces[family] = await engine.face(for: summary.id, family: family, size: sizes[family], at: .now)
                }
                items.append(Item(summary: summary, faces: faces))
            }
            let placed = await Self.placements(latest: items.first?.id)
            if reload == reloads {
                self.items = items
                self.placed = placed
                loaded = true
            }
        } catch {
            message = error.message
            // The feed shows the empty state or what it had, rather than nothing at all.
            if reload == reloads { loaded = true }
        }
    }

    /// Which widget each home screen widget shows, and in what size. A widget never configured shows the latest
    /// creation, as `WidgetChoiceQuery.defaultResult` does.
    private static func placements(latest: WidgetID?) async -> [WidgetID: Set<Family>] {
        guard let infos = try? await WidgetCenter.shared.currentConfigurations() else { return [:] }
        return placements(
            infos.filter { $0.kind == CreationWidget.kind }.map {
                ($0.widgetConfigurationIntent(of: PickWidget.self)?.widget?.id, Family($0.family))
            }, latest: latest)
    }

    static func placements(_ shown: [(WidgetID?, Family)], latest: WidgetID?) -> [WidgetID: Set<Family>] {
        var placed: [WidgetID: Set<Family>] = [:]
        for (id, family) in shown {
            guard let id = id ?? latest else { continue }
            placed[id, default: []].insert(family)
        }
        return placed
    }

    /// A bundled fixture's source, or nil when this build bundles none.
    static func fixture(_ folder: String) throws(Rejected) -> WidgetSource? {
        guard let url = Bundle.main.url(forResource: folder, withExtension: nil, subdirectory: "Fixtures") else {
            return nil
        }
        return try WidgetSource(directory: url)
    }

    /// Builds a bundled fixture through `engine.build`, the path a model-written widget takes. Returns the new
    /// widget's id.
    func install(_ fixture: String) async -> WidgetID? {
        do throws(Rejected) {
            guard let source = try Self.fixture(fixture) else { return nil }
            switch await add(source) {
            case .success(let id): return id
            case .failure(let unsaved): message = unsaved.line
            }
        } catch {
            message = error.line
        }
        return nil
    }

    /// Builds `source` into the library through `engine.build`, the path every widget takes, and draws the feed
    /// with it. Returns the new widget's id.
    func add(_ source: WidgetSource) async -> Result<WidgetID, Unsaved> {
        do {
            switch try await engine.build(source) {
            case .saved(let id):
                await reload()
                return .success(id)
            case .rejected(let line):
                return .failure(Unsaved(line: line))
            }
        } catch {
            return .failure(Unsaved(line: error.message))
        }
    }

    /// Why a widget did not go into the library, in one line.
    struct Unsaved: Error {
        let line: String
    }

    func delete(_ widget: WidgetID) {
        attempt { () throws(EngineError) in try engine.delete(widget) }
    }

    func perform(_ tap: Tap, input: [String: InputValue] = [:]) {
        attempt { () throws(EngineError) in try engine.perform(tap, input: input) }
    }

    func showForm(for tap: Tap) {
        do {
            form = try engine.form(for: tap).map(ShownForm.init)
        } catch {
            message = error.message
        }
    }

    /// A form link from the widget.
    func open(_ url: URL) {
        guard let tap = Hosting.formTap(from: url) else { return }
        showForm(for: tap)
    }

    /// A placed widget whose id names no widget left draws nothing, so it does not count.
    var placedCount: Int { items.count { placed[$0.id] != nil } }

    private func attempt(_ write: () throws(EngineError) -> Void) {
        do {
            try write()
        } catch {
            message = error.message
        }
        refresh()
    }
}

/// The faces' sizes in a column: a small is half the column less the gap between two, and a medium is the whole
/// column at a small's height, as on the home screen.
struct FaceSizes: Equatable {
    static let gap: CGFloat = 14

    let small: CGSize
    let medium: CGSize

    init(column width: CGFloat) {
        let side = max(0, ((width - Self.gap) / 2).rounded(.down))
        self.init(small: CGSize(width: side, height: side), medium: CGSize(width: side * 2 + Self.gap, height: side))
    }

    init(small: CGSize, medium: CGSize) {
        self.small = small
        self.medium = medium
    }

    /// The look language's reference sizes.
    static let standard = FaceSizes(small: Family.small.standardSize, medium: Family.medium.standardSize)

    subscript(family: Family) -> CGSize { family == .small ? small : medium }
}
