import Foundation
import Testing
import UIKit
import WidgetBuilder
import WidgetEngine

@testable import Widgie

@MainActor @Suite struct PreviewTests {
    private let shared = SharedStore()
    private let center = NotificationCenter()

    @Test func aShowCancelledWhileTheDraftIsPreparedPublishesNothing() async throws {
        let preview = Preview(library: shared.engine, center: center)
        let draft = try await preview.engine.saved(WidgetSource(json: Data(counterDocument().utf8)))
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

    /// A preview showing the counter, and the counter's change, built but not on show yet.
    private func aDraftAndItsChange() async throws -> (preview: Widgie.Preview, tap: Tap, change: WidgetID) {
        let preview = Preview(library: shared.engine, startsEmpty: true, center: center)
        let draft = try #require(await preview.adopt(lit(otherwise: "#2050B0")))
        let revision = try #require(try preview.engine.history(of: draft).first).id
        let change = try await preview.engine.saved(lit(otherwise: "#20A040", named: "Green counter"), replacing: draft)
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
