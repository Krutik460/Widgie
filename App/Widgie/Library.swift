import Foundation
import Observation
import WidgetBuilder
import WidgetEngine
import WidgetHosting

/// The app's view of the shared store: the widgets, a small face of each, and the open form.
@MainActor @Observable
final class Library {
    struct Item: Identifiable {
        let summary: WidgetSummary
        var face: Face?
        var id: WidgetID { summary.id }
    }

    private(set) var items: [Item] = []
    var form: InputForm?
    var message: String?
    /// The widget saved last in this run, which the library marks as new.
    var justSaved: WidgetID?

    private var engine: Engine { Hosting.engine }

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

    func reload() async {
        do {
            var items: [Item] = []
            for summary in try engine.widgets() {
                let face = await engine.faces(
                    for: summary.id, family: .small, size: Family.small.standardSize, from: .now
                ).current
                items.append(Item(summary: summary, face: face))
            }
            self.items = items
        } catch {
            message = error.message
        }
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
            form = try engine.form(for: tap)
        } catch {
            message = error.message
        }
    }

    /// A form link from the widget.
    func open(_ url: URL) {
        guard let tap = Hosting.formTap(from: url) else { return }
        showForm(for: tap)
    }

    private func attempt(_ write: () throws(EngineError) -> Void) {
        do {
            try write()
        } catch {
            message = error.message
        }
        refresh()
    }
}
