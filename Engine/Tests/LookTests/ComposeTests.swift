import CoreGraphics
import Foundation
import Rows
import Sandbox
import Spec
import Testing
import WidgetEngine

/// One reference widget in one data state: no rows, one of its samples, or the synthesized full state.
struct StoredState: Sendable, CustomTestStringConvertible {
    let widget: String
    let state: String

    var testDescription: String { "\(widget) \(state)" }

    static let all: [StoredState] = ["dogfed", "habit", "hearts", "todo", "water", "wotd"].flatMap { widget in
        let samples = (try? fixture(widget).samples.map(\.name)) ?? []
        return (["empty"] + samples + ["full"]).map { StoredState(widget: widget, state: $0) }
    }

    func sample(of spec: Spec) -> Spec.Sample? {
        switch state {
        case "empty": Spec.empty
        case "full": spec.full
        default: spec.sample(named: state)
        }
    }
}

@Suite struct ComposeTests {
    /// The path a widget and a proof both take: rows seeded through the store's insert path, queries, the
    /// context, the sandbox, and the validator.
    @Test(arguments: StoredState.all, Family.allCases)
    @MainActor func storedStateComposesAndRenders(_ state: StoredState, _ family: Family) async throws {
        let spec = try fixture(state.widget)
        let sample = try #require(state.sample(of: spec))
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        calendar.firstWeekday = 2
        let today = Today(at: try Date("2026-11-18T09:00:00Z", strategy: .iso8601), calendar: calendar)
        let store = try RowStore.scratch()
        let widget = WidgetKey.mint()
        try store.bind(tablesOf: spec, to: widget)
        try store.seed(sample, widget: widget, today: today)
        let folder = engineDirectory.appending(path: "Fixtures/\(state.widget)/assets")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        var images: [Spec.AssetID: Data] = [:]
        for asset in spec.assets {
            let file = try #require(files.first { $0.deletingPathExtension().lastPathComponent == asset.id.raw })
            images[asset.id] = try Data(contentsOf: file)
        }
        let drawing = try await composeDrawing(
            spec: spec, widget: widget, revision: Bindings.unsaved, store: store, images: .inMemory(images),
            family: family, size: size(family),
            pixelScale: 2, today: today, sandbox: Sandbox(), budget: .proof
        ).drawing
        let image = render(drawing)
        try writeArtifact(
            image, "stored-\(state.widget)-\(state.state.replacingOccurrences(of: " ", with: "-"))-\(family.rawValue)")
        #expect(drawing.taps.allSatisfy { $0.widget == widget.raw })
    }

    /// The parse-time cell cap keeps ordinary text under the context cap, but a character JSON escapes takes
    /// six bytes, so text full of them can still make `ctx` large. `composeDrawing` refuses it before the look
    /// runs.
    @Test func aContextOverOneMegabyteIsRefused() async throws {
        let fields = (0..<10).map { "f\($0)" }
        let text = String(repeating: #"\u0001"#, count: 300)
        let values = fields.map { #""\#($0)": "\#(text)""# }.joined(separator: ", ")
        let spec = try document(
            #"{"name": "Notes", "look": "function render(ctx) { return { type: 'spacer' }; }", "tables": {"notes": {"fields": {\#(fields.map { #""\#($0)": "text""# }.joined(separator: ", "))}}}, "queries": {"all": {"list": "notes", "window": "all", "limit": 100}}, "samples": {"long": {"notes": [{"repeat": 100, \#(values)}]}}}"#
        )
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let today = Today(at: try Date("2026-11-18T09:00:00Z", strategy: .iso8601), calendar: calendar)
        let store = try RowStore.scratch()
        let widget = WidgetKey.mint()
        try store.bind(tablesOf: spec, to: widget)
        try store.seed(try #require(spec.sample(named: "long")), widget: widget, today: today)
        do throws(Diagnostic) {
            _ = try await composeDrawing(
                spec: spec, widget: widget, revision: Bindings.unsaved, store: store, images: .inMemory([:]),
                family: .small, size: size(.small), pixelScale: 2, today: today, sandbox: Sandbox(), budget: .proof)
            Issue.record("composed a context over the limit")
        } catch {
            #expect(
                error.line.hasPrefix("ctx is ")
                    && error.line.hasSuffix(
                        " KB of JSON, more than 1024 KB; lower the list limits so the queries return fewer rows"),
                "\(error.line)")
        }
    }
}
