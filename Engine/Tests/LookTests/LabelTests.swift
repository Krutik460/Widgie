import Foundation
import Spec
import Testing
import WidgetEngine

/// What VoiceOver reads for each button: the look's label, else the words the button shows, else its action.
@Suite struct LabelTests {
    private func labels(_ tree: String) async throws -> [String] {
        let rows = [
            mistakeSpec.table(named: "items")!.id: Set(["item-1"]),
            mistakeSpec.table(named: "glasses")!.id: ["glass-1"],
        ]
        return try await drawing(tree, spec: mistakeSpec, rows: rows).root.buttonLabels
    }

    @Test func aGivenLabelIsRead() async throws {
        #expect(
            try await labels(
                "{ type: 'button', action: 'drink', label: 'Add a glass', children: [{ type: 'symbol', name: 'plus' }] }"
            )
                == ["Add a glass"])
    }

    @Test func aLabelWinsOverTheWordsShown() async throws {
        #expect(
            try await labels(
                "{ type: 'button', action: 'drink', label: 'Add a glass', children: [{ type: 'text', value: '+1' }] }")
                == ["Add a glass"])
    }

    @Test func withoutALabelTheShownWordsAreRead() async throws {
        let tree = """
            { type: 'button', action: 'toggle', rowId: 'item-1', children: [
              { type: 'symbol', name: 'circle', background: { type: 'text', value: 'Oat' } },
              { type: 'vstack', children: [{ type: 'text', value: 'Milk' }, { type: 'text', value: 2 }] }] }
            """
        #expect(try await labels(tree) == ["Oat, Milk, 2"])
    }

    @Test func aButtonThatShowsNoWordsReadsItsAction() async throws {
        #expect(
            try await labels("{ type: 'button', action: 'drink', children: [{ type: 'symbol', name: 'plus' }] }") == [
                "Drink"
            ])
        #expect(
            try await labels(
                "{ type: 'button', action: 'drink', label: '  ', children: [{ type: 'symbol', name: 'plus' }] }")
                == ["Drink"])
    }

    @Test func anActionIdReadsAsWords() async throws {
        let spec = try document(
            #"""
            {
              "name": "Pets",
              "look": "function render() { return { type: 'spacer' }; }",
              "tables": { "feeds": { "fields": {} } },
              "actions": { "markFed": { "insert": "feeds" }, "add10Pushups": { "insert": "feeds" } }
            }
            """#)
        let tree = """
            { type: 'hstack', children: [
              { type: 'button', action: 'markFed', children: [{ type: 'circle' }] },
              { type: 'button', action: 'add10Pushups', children: [{ type: 'circle' }] }] }
            """
        #expect(try await drawing(tree, spec: spec).root.buttonLabels == ["Mark fed", "Add 10 pushups"])
    }

    @Test func labelsComeInTreeOrderFromLayersToo() async throws {
        let tree = """
            { type: 'hstack', overlay: { type: 'button', action: 'drink', label: 'Over', children: [{ type: 'circle' }] },
              children: [
                { type: 'button', action: 'undo', rowId: 'glass-1', label: 'First', children: [{ type: 'circle' }] },
                { type: 'button', action: 'toggle', rowId: 'item-1', label: 'Second', children: [{ type: 'circle' }] }] }
            """
        #expect(try await labels(tree) == ["Over", "First", "Second"])
    }

    @Test func aLabelHasALimit() async throws {
        let long = String(repeating: "a", count: 1001)
        await #expect(throws: Diagnostic.self) {
            try await labels(
                "{ type: 'button', action: 'drink', label: '\(long)', children: [{ type: 'symbol', name: 'plus' }] }")
        }
    }
}
