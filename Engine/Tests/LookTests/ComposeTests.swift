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

    static let all: [StoredState] = ["habit", "todo", "water", "wotd"].flatMap { widget in
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
        let drawing = try await composeDrawing(
            spec: spec, widget: widget, store: store, images: .inMemory([:]), family: family, size: size(family),
            pixelScale: 2, today: today, sandbox: Sandbox(), budget: .proof
        ).drawing
        let image = render(drawing)
        try writeArtifact(
            image, "stored-\(state.widget)-\(state.state.replacingOccurrences(of: " ", with: "-"))-\(family.rawValue)")
        #expect(drawing.taps.allSatisfy { $0.widget == widget.raw })
    }
}
