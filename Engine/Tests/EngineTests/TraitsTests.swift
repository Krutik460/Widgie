import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

/// What a host can read off a face to suggest a change: whether it shows a number, and the color it paints most.
@Suite struct TraitsTests {
    @Test func eachReferenceWidgetNamesItsNumberAndItsColor() async throws {
        let scratch = Scratch()
        let expected: [(name: String, showsNumber: Bool, hues: Range<Double>?)] = [
            ("water", true, 180..<240),
            ("hearts", false, 300..<360),
            ("wotd", false, 30..<60),
            ("todo", false, 90..<150),
            ("dogfed", false, 340..<360),
            // Every square is grey until a day is checked.
            ("habit", false, nil),
        ]
        for (name, showsNumber, hues) in expected {
            let id = try await scratch.build(try fixture(name))
            let traits = await scratch.face(id, .medium).traits
            #expect(traits.showsNumber == showsNumber, "\(name)")
            if let hues {
                let hue = try #require(traits.hue, "\(name) paints a color")
                #expect(hues.contains(hue), "\(name) hue \(hue)")
            } else {
                #expect(traits.hue == nil, "\(name)")
            }
        }
    }

    @Test @MainActor func aCheckedDayPaintsTheHabitGreen() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("habit"))
        try scratch.engine.perform(try button("check", on: await scratch.face(id, .medium), .medium).tap, at: morning)
        let hue = try #require(await scratch.face(id, .medium).traits.hue)
        #expect((100..<150).contains(hue), "hue \(hue)")
    }

    @Test func aFallbackFaceShowsNothing() async {
        let face = await Scratch().face(WidgetID(rawValue: "missing"))
        #expect(!face.traits.showsNumber)
        #expect(face.traits.hue == nil)
    }
}
