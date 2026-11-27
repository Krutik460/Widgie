import Foundation
import Testing
import UIKit
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
        #expect(preview.name == nil)
        #expect(preview.faces.isEmpty)
    }

    enum Meanwhile: CaseIterable {
        case tap, timeChange
    }

    private let shared = SharedStore()
    private let center = NotificationCenter()

    /// A preview showing the counter, and the counter's change, built but not on show yet.
    private func aDraftAndItsChange() async throws -> (preview: Widgie.Preview, tap: Tap, change: WidgetID) {
        let preview = Preview(library: shared.engine, startsEmpty: true, center: center)
        let draft = try #require(await preview.adopt(lit(otherwise: "#2050B0")))
        let revision = try #require(try preview.engine.history(of: draft).first).id
        let outcome = try await preview.engine.build(
            lit(otherwise: "#20A040", named: "Green counter"), replacing: draft)
        guard case .saved(let change) = outcome else {
            Issue.record("expected the change to save, got \(outcome)")
            throw Unexpected()
        }
        return (preview, Tap(widget: draft.rawValue, revision: revision, action: "add", row: nil), change)
    }

    /// The draft on show stays live while a change is built, so a tap on it, or a time change that draws it
    /// again, can land while the change is drawn. The change still goes on show, with the tap's row on it.
    @Test(arguments: Meanwhile.allCases)
    func aChangeGoesOnShowThoughTheDraftOnShowDrawsAgainMeanwhile(_ meanwhile: Meanwhile) async throws {
        let (preview, tap, change) = try await aDraftAndItsChange()

        let show = Task { await preview.show(change) }
        await Task.yield()
        switch meanwhile {
        case .tap: preview.perform(tap)
        case .timeChange: center.post(name: UIApplication.significantTimeChangeNotification, object: nil)
        }

        #expect(await show.value)
        #expect(preview.name == "Green counter")
        #expect(preview.faces[.small].map(hue) == (meanwhile == .tap ? .red : .green), "with the tap's row, if any")
    }

    @Test func aShowCancelledWhileTheDraftOnShowDrawsAgainPublishesNothing() async throws {
        let (preview, tap, change) = try await aDraftAndItsChange()

        let show = Task { await preview.show(change) }
        await Task.yield()
        preview.perform(tap)
        show.cancel()

        #expect(await show.value == false)
        #expect(preview.name == "Counter")
    }
}

/// The counter called `name`, red once a row is stored and `otherwise` before then.
private func lit(otherwise background: String, named name: String = "Counter") -> WidgetSource {
    let document = counterDocument()
        .replacing(
            "widgetBackground: '#102030'", with: "widgetBackground: ctx.data.n > 0 ? '#B02020' : '\(background)'"
        )
        .replacing(#""name":"Counter""#, with: #""name":"\#(name)""#)
    return WidgetSource(json: Data(document.utf8))
}

private enum Hue {
    case red, green
}

private func hue(of face: Face) -> Hue? {
    switch face.traits.hue {
    case let hue? where hue < 30 || hue > 330: .red
    case let hue? where (90..<180).contains(hue): .green
    default: nil
    }
}

@MainActor @Suite struct LibraryTests {
    @Test func aFirstLoadThatFailsStillCountsAsLoadedSoTheFeedShowsSomething() async throws {
        let blocker = FileManager.default.temporaryDirectory.appending(path: "app-tests-\(UUID().uuidString)")
        try Data().write(to: blocker)
        defer { try? FileManager.default.removeItem(at: blocker) }
        let library = Library(engine: Engine(directory: blocker.appending(path: "store")))

        await library.reload()
        #expect(library.message != nil, "the store could not be read")
        #expect(library.loaded)
        #expect(library.items.isEmpty)
    }

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
