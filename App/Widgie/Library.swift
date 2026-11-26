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

    /// The size a widget is shown in: the size it is placed in, medium if it is placed in both, and otherwise
    /// every third widget wide, so the feed keeps a rhythm of one wide and a pair of smalls.
    func family(of item: Item, at index: Int) -> Family {
        let placed = placed[item.id] ?? []
        if placed.contains(.medium) { return .medium }
        if placed.contains(.small) { return .small }
        return index % 3 == 0 ? .medium : .small
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
                    faces[family] = await engine.faces(
                        for: summary.id, family: family, size: sizes[family], from: .now
                    ).current
                }
                items.append(Item(summary: summary, faces: faces))
            }
            let placed = await Self.placements(latest: items.first?.id)
            if reload == reloads {
                self.items = items
                self.placed = placed
            }
        } catch {
            message = error.message
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

    /// Builds a bundled fixture through `engine.build`, the path a model-written widget takes.
    func install(_ fixture: String) {
        Task {
            do {
                guard let source = try Self.fixture(fixture) else { return }
                switch try await engine.build(source) {
                case .saved: await reload()
                case .rejected(let line): message = line
                }
            } catch let error as EngineError {
                message = error.message
            } catch let error as Rejected {
                message = error.line
            } catch {
                message = "\(error)"
            }
        }
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
        let side = ((width - Self.gap) / 2).rounded(.down)
        small = CGSize(width: side, height: side)
        medium = CGSize(width: side * 2 + Self.gap, height: side)
    }

    subscript(family: Family) -> CGSize { family == .small ? small : medium }
}
