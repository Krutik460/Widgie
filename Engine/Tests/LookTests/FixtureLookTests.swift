import Foundation
import Sandbox
import Spec
import Testing
import WidgetEngine

/// A data state for one reference widget, written as the `ctx.data` its queries would produce.
struct FixtureState: Sendable, CustomTestStringConvertible {
    let widget: String
    let name: String
    let data: [String: JSONValue]

    var testDescription: String { "\(widget) \(name)" }

    static let all: [FixtureState] = [
        FixtureState(
            widget: "water", name: "empty",
            data: ["today": 0, "last": .null, "week": daily(Array(repeating: 0, count: 7))]
        ),
        FixtureState(
            widget: "water", name: "busy",
            data: [
                "today": 5, "last": row("0193f4c2-0000-7000-8000-000000000005"), "week": daily([3, 8, 7, 5, 8, 6, 5]),
            ]),
        FixtureState(
            widget: "habit", name: "empty",
            data: ["streak": 0, "today": .null, "days": daily(Array(repeating: 0, count: 35))]),
        FixtureState(
            widget: "habit", name: "busy",
            data: [
                "streak": 12, "today": row("0193f4c2-0000-7000-8000-00000000000c"),
                "days": daily(
                    (0..<35).map {
                        [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 14, 15, 17, 20, 26].contains(34 - $0) ? 1 : 0
                    }),
            ]),
        FixtureState(widget: "todo", name: "empty", data: ["open": [], "done": [], "left": 0, "finished": 0]),
        FixtureState(
            widget: "todo", name: "busy",
            data: [
                "open": [
                    row("todo-1", daysAgo: 3, ["title": "Buy oat milk", "done": false]),
                    row("todo-2", daysAgo: 1, ["title": "Water the plants", "done": false]),
                    row("todo-3", daysAgo: 1, ["title": "Send rent to landlord", "done": false]),
                    row("todo-4", daysAgo: 0, ["title": "Book flights for the wedding in Lisbon", "done": false]),
                ],
                "done": [
                    row("todo-5", daysAgo: 0, ["title": "Return library books", "done": true]),
                    row("todo-6", daysAgo: 2, ["title": "Call the dentist", "done": true]),
                ],
                "left": 4, "finished": 2,
            ]),
        FixtureState(widget: "wotd", name: "empty", data: ["word": .null]),
        FixtureState(
            widget: "wotd", name: "busy",
            data: [
                "word": row(
                    "wotd-1",
                    [
                        "word": "Sesquipedalian", "kind": "adjective",
                        "definition":
                            "Given to using long words; also describes a word that has many syllables, like this one.",
                        "example": "His sesquipedalian lectures put half the room to sleep.",
                    ])
            ]),
    ]
}

@Suite struct FixtureLookTests {
    @Test(arguments: FixtureState.all, Family.allCases)
    @MainActor func runsValidatesAndRendersSomething(_ state: FixtureState, _ family: Family) async throws {
        let spec = try fixture(state.widget)
        let input = bindings(spec, family: family, rows: receivedRows(state.data, spec: spec))
        let tree = try await Sandbox().run(spec.look, context: context(state.data, family: family), budget: .proof)
        let drawing = try Drawing.parse(tree: tree, bindings: input)
        let image = render(drawing)
        try writeArtifact(image, "\(state.widget)-\(state.name)-\(family.rawValue)")

        guard case .object(let root) = try JSONValue.parse(Data(tree.utf8)) else { throw Diagnostic("no root") }
        let bare = JSONValue.object(["type": "spacer", "widgetBackground": root["widgetBackground"] ?? .null])
        let background = try Drawing.parse(tree: String(decoding: bare.encoded(), as: UTF8.self), bindings: input)
        #expect(Bitmap(image).difference(Bitmap(render(background))) > 0.01, "the look draws more than its background")
    }

    @Test(arguments: FixtureState.all.filter { $0.name == "busy" })
    func sameLookAndContextGiveIdenticalTrees(_ state: FixtureState) async throws {
        let spec = try fixture(state.widget)
        let json = context(state.data, family: .medium)
        let sandbox = Sandbox()
        var trees: Set<String> = []
        for _ in 0..<3 { trees.insert(try await sandbox.run(spec.look, context: json, budget: .proof)) }
        trees.insert(try await Sandbox().run(spec.look, context: json, budget: .proof))
        #expect(trees.count == 1)
    }

    @Test func busyButtonsCarryTheRowsTheyAreAbout() async throws {
        let state = try #require(FixtureState.all.first { $0.widget == "todo" && $0.name == "busy" })
        let spec = try fixture("todo")
        let drawing = try await compose(
            spec.look, context: context(state.data, family: .medium),
            bindings: bindings(spec, family: .medium, rows: receivedRows(state.data, spec: spec))
        ).get()
        #expect(
            drawing.taps == [
                Tap(widget: "w1", revision: "r1", action: "add", row: nil),
                Tap(widget: "w1", revision: "r1", action: "toggle", row: "todo-1"),
                Tap(widget: "w1", revision: "r1", action: "toggle", row: "todo-2"),
                Tap(widget: "w1", revision: "r1", action: "toggle", row: "todo-3"),
                Tap(widget: "w1", revision: "r1", action: "toggle", row: "todo-4"),
            ])
    }
}
