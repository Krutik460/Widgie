import Foundation
import Testing
import WidgetBuilder
import WidgetEngine
import WidgetHosting

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

    @Test func addBuildsATemplateIntoTheLibraryAndDrawsItInTheFeed() async throws {
        let shared = SharedStore()
        let library = Library(engine: shared.engine)
        let template = try #require(Template.catalog().first { $0.id == "pet-fed" })

        guard case .success(let id) = await library.add(try template.source(filling: ["pet": "Mochi"])) else {
            Issue.record("expected the template to be added")
            return
        }
        #expect(try shared.engine.widgets().map(\.id) == [id])
        let item = try #require(library.items.first)
        #expect(library.items.count == 1 && item.id == id && item.summary.name == "Mochi fed")
        #expect(item.faces[.small] != nil && item.faces[.medium] != nil)
    }

    @Test func addReportsAWidgetTheLibraryRejectsAndKeepsItOut() async throws {
        let shared = SharedStore()
        let library = Library(engine: shared.engine)
        guard case .failure = await library.add(WidgetSource(json: Data(#"{"name": "Counter"}"#.utf8))) else {
            Issue.record("expected the widget to be rejected")
            return
        }
        #expect(try shared.engine.widgets().isEmpty)
        #expect(library.items.isEmpty)
    }

    /// The sheet is keyed by the shown form's id, so a new id is what makes SwiftUI start it over.
    @Test func everyFormLinkPublishesANewShownForm() async throws {
        let shared = SharedStore()
        let document = counterDocument(fields: ["note": "text"])
            .replacing(#"{"insert":"taps"}"#, with: #"{"form":"taps","fields":["note"]}"#)
        let id = try await shared.build(document)
        let revision = try #require(try shared.engine.history(of: id).first).id
        let link = Hosting.formURL(for: Tap(widget: id.rawValue, revision: revision, action: "add", row: nil))
        let library = Library(engine: shared.engine)

        library.open(link)
        let first = try #require(library.form)
        library.open(link)
        let second = try #require(library.form)
        #expect(first.form.fields.map(\.id) == ["note"] && second.form.fields.map(\.id) == ["note"])
        #expect(first.id != second.id)
    }
}
