import Foundation
import Spec
import Testing

let engineDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

let referenceWidgets = ["habit", "todo", "water", "wotd"]

func fixture(_ name: String) throws -> Data {
    try Data(contentsOf: engineDirectory.appending(path: "Fixtures/\(name)/widget.json"))
}

func parse(_ json: String) throws -> Spec {
    try Spec.parse(Data(json.utf8))
}

/// The line `Spec.parse` rejects `json` with, or nil when it parses.
func rejection(_ json: String) -> String? {
    do throws(Diagnostic) {
        _ = try Spec.parse(Data(json.utf8))
        return nil
    } catch {
        return error.line
    }
}

let minimalLook = "function render(ctx) { return { type: 'spacer' }; }"

/// A document with a name, a look, and `rest` (comma-separated top-level members).
func document(_ rest: String) -> String {
    #"{"name": "Test", "look": "\#(minimalLook)"\#(rest.isEmpty ? "" : ", " + rest)}"#
}

/// A document whose tables are `glasses` (no fields) and `items` (done, due, size, title), plus `rest`.
func withTables(_ rest: String) -> String {
    document(
        #""tables": {"glasses": {"fields": {}}, "items": {"fields": {"title": "text", "done": "bool", "due": "date", "size": "number"}}}"#
            + (rest.isEmpty ? "" : ", " + rest))
}

func instant(_ iso: String) throws -> Date {
    try Date(iso, strategy: .iso8601)
}

extension Spec {
    func query(_ id: String) -> Query? { queries.first { $0.id.raw == id } }
}
