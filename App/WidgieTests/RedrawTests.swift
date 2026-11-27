import Foundation
import SwiftUI
import Testing
import UIKit
import WidgetBuilder
import WidgetEngine

@testable import Widgie

/// Faces on show draw again when they change while the app stays open, on a clock the test moves.
@MainActor @Suite struct RedrawTests {
    /// Wednesday, 9 in the morning.
    private let nine = moment(2026, 11, 18, 9)
    private let shared = SharedStore()
    private let center = NotificationCenter()

    private func pushups() throws -> Template {
        try Template.bundled("pushups")
    }

    /// The feed with pushups in it, a set of ten just tapped at nine, so its face offers the undo.
    private func feedWithATap(_ clock: TestClock) async throws -> Library {
        _ = try await shared.engine.saved(try pushups().source())
        let library = Library(engine: shared.engine, clock: clock.clock, center: center)
        await library.reload()
        let face = try #require(library.items.first?.faces[.small])
        library.perform(try #require(taps(on: face, .small).first { $0.action == "ten" }))
        try await until({ undo(on: library) }, "the tap offers its undo")
        return library
    }

    private func undo(on library: Library) -> Bool {
        guard let face = library.items.first?.faces[.small] else { return false }
        return taps(on: face, .small).contains { $0.action == "undo" }
    }

    @Test func theFeedDropsAnUndoWhenItsWindowHasClosed() async throws {
        let clock = TestClock(nine)
        let library = try await feedWithATap(clock)
        #expect(clock.soonest == nine.adding(minutes: 15), "a face that reads the clock draws again in 15 minutes")

        clock.move(to: nine.adding(minutes: 15))
        try await until({ !undo(on: library) }, "the undo goes once its ten minutes are up")
    }

    @Test func theBackgroundStopsTheWaitAndComingBackCatchesUp() async throws {
        let clock = TestClock(nine)
        let library = try await feedWithATap(clock)

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        try await until({ clock.soonest == nil }, "nothing waits in the background")
        clock.move(to: nine.adding(minutes: 20))
        #expect(undo(on: library))

        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try await until({ !undo(on: library) }, "coming back draws the face whose moment passed")
    }

    @Test func aTimeChangeDrawsAtOnce() async throws {
        let clock = TestClock(nine)
        let library = try await feedWithATap(clock)

        clock.move(to: nine.adding(minutes: 11))
        center.post(name: UIApplication.significantTimeChangeNotification, object: nil)
        try await until({ !undo(on: library) }, "a new time zone or a clock set by hand draws at once")
    }

    @Test func aTemplatesTrialDropsAnUndoWhenItsWindowHasClosed() async throws {
        let clock = TestClock(nine)
        let preview = Preview(library: shared.engine, clock: clock.clock, center: center)
        let trial = TemplateTrial(template: try pushups(), preview: preview)
        await trial.fill()
        func undo() -> Bool {
            preview.faces[.small].map { taps(on: $0, .small).contains { $0.action == "undo" } } ?? false
        }
        let face = try #require(preview.faces[.small])
        trial.tap(try #require(taps(on: face, .small).first { $0.action == "ten" }))
        try await until(undo, "the tap offers its undo")

        clock.move(to: nine.adding(minutes: 15))
        try await until({ !undo() }, "the undo goes once its ten minutes are up")
    }
}

/// The pile's faces show their samples as staged that day, and a template that failed is tried again.
@MainActor @Suite struct GalleryRedrawTests {
    private let nine = moment(2026, 11, 18, 9)

    private func picture(_ gallery: TemplateGallery, _ id: Template.ID) throws -> Bitmap {
        let template = try #require(gallery.catalog.first { $0.id == id })
        let face = try #require(gallery.card(id).face, "\(id) has no face")
        let renderer = ImageRenderer(content: FaceView(face, host: .still).environment(\.colorScheme, .light))
        renderer.proposedSize = ProposedViewSize(gallery.sizes[template.family])
        return Bitmap(try #require(renderer.cgImage))
    }

    /// Baby feeds' sample was fed three hours ago. Drawn again later the same day at another width and back, it
    /// still shows that, not a feed hours older.
    @Test func aFaceDrawnAgainLaterTheSameDayShowsTheSameSample() async throws {
        let clock = TestClock(nine)
        let gallery = TemplateGallery(clock: clock.clock, center: NotificationCenter())
        gallery.fit(column: 362)
        await gallery.drawn()
        let morning = try picture(gallery, "baby-feeds")

        clock.move(to: moment(2026, 11, 18, 15))
        gallery.fit(column: 330)
        await gallery.drawn()
        gallery.fit(column: 362)
        await gallery.drawn()
        #expect(try picture(gallery, "baby-feeds").looksLike(morning))
    }

    /// A copy of the pushups template in a catalog of its own, whose `widget.json` `edit` changes. The copy's
    /// folder goes when the test ends.
    private final class Copy {
        let root = FileManager.default.temporaryDirectory.appending(path: "templates-\(UUID().uuidString)")
        let id = "pushups"
        let document: URL
        let original: Data

        init(_ edit: (inout [String: Any]) -> Void) throws {
            let source = try Template.bundled("pushups")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: source.folder, to: root.appending(path: id))
            document = root.appending(path: id).appending(path: "widget.json")
            original = try Data(contentsOf: document)
            var json = try #require(try JSONSerialization.jsonObject(with: original) as? [String: Any])
            edit(&json)
            try JSONSerialization.data(withJSONObject: json).write(to: document)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        var catalog: [Template] { Template.catalog(in: root) }
    }

    /// A face that shows the date shows the new one once the day turns, with the app left open.
    @Test func theSamplesAreStagedAgainWhenTheDayTurns() async throws {
        let copy = try Copy { json in
            json["look"] = """
                function render(ctx) {
                  return { type: 'text', value: ctx.today.date, size: 24, color: '#FFFFFF', widgetBackground: '#102030' };
                }
                """
        }
        let clock = TestClock(nine)
        let gallery = TemplateGallery(catalog: copy.catalog, clock: clock.clock, center: NotificationCenter())
        gallery.fit(column: 362)
        await gallery.drawn()
        let yesterday = try picture(gallery, copy.id)
        #expect(clock.soonest == moment(2026, 11, 19, 0), "the pile waits for midnight")

        clock.move(to: moment(2026, 11, 19, 0, 1))
        try await until({ (try? picture(gallery, copy.id).looksLike(yesterday)) == false }, "the date is today's")
    }

    /// A template that did not stage, or drew a fallback face, keeps no face, and the next fit tries it again.
    @Test(arguments: ["unparsable", "throwing look"])
    func aFailedTemplateIsTriedAgainOnTheNextFit(breakage: String) async throws {
        let copy = try Copy { json in json["look"] = "function render(ctx) { throw new Error('boom'); }" }
        if breakage == "unparsable" { try Data("{".utf8).write(to: copy.document) }

        let gallery = TemplateGallery(catalog: copy.catalog, center: NotificationCenter())
        gallery.fit(column: 362)
        await gallery.drawn()
        #expect(gallery.card(copy.id).face == nil, "a \(breakage) template keeps no face")

        try copy.original.write(to: copy.document)
        gallery.fit(column: 362)
        await gallery.drawn()
        let face = try #require(gallery.card(copy.id).face, "the next fit tries it again")
        #expect(!face.isFallback)
    }
}
