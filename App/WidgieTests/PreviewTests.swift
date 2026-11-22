import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

@testable import Widgie

@MainActor @Suite struct PreviewTests {
    @Test func aShowCancelledWhileTheDraftIsPreparedPublishesNothing() async throws {
        let shared = SharedStore()
        let preview = Preview(library: shared.engine)
        let outcome = try await preview.engine.build(WidgetSource(json: Data(counterDocument().utf8)))
        guard case .saved(let draft) = outcome else {
            Issue.record("expected the draft to save, got \(outcome)")
            return
        }
        let show = Task { await preview.show(draft) }
        show.cancel()

        #expect(await show.value == false)
        #expect(preview.widget == nil)
        #expect(preview.states.isEmpty)
        #expect(preview.faces.isEmpty)
    }
}

@MainActor @Suite struct LibraryTests {
    @Test func aReloadThatFinishesAfterALaterOneNeverBringsBackADeletedWidget() async throws {
        let shared = SharedStore()
        let id = try await shared.build(counterDocument())
        let library = Library(engine: shared.engine)
        let older = Task { await library.reload() }
        await Task.yield()
        try shared.engine.delete(id)

        await library.reload()
        await older.value
        #expect(library.items.isEmpty)
    }
}
