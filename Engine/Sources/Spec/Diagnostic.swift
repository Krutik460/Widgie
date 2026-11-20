/// One line a language model can act on: where the problem is, what is wrong, and what would be valid.
///
/// `path` runs from the outermost block inward, so a diagnostic with path `["sample \"busy\"", "glasses[2]"]`
/// reads `sample "busy", glasses[2]: no field "ml" in glasses (glasses has no fields)`.
package struct Diagnostic: Error, Sendable, Equatable, CustomStringConvertible {
    package let path: [String]
    package let message: String

    package init(_ message: String, at path: [String] = []) {
        self.message = Self.oneLine(message)
        self.path = path.map(Self.oneLine)
    }

    package var line: String {
        path.isEmpty ? message : path.joined(separator: ", ") + ": " + message
    }

    package var description: String { line }

    package func within(_ context: String) -> Diagnostic {
        Diagnostic(message, at: [context] + path)
    }

    /// Text from a document, quoted for an error line: escaped, on one line, and at most 40 characters.
    package static func quote(_ text: String) -> String {
        var body = ""
        for scalar in text.prefix(40).unicodeScalars {
            switch scalar {
            case "\"": body += "\\\""
            case "\\": body += "\\\\"
            case "\n": body += "\\n"
            case "\t": body += "\\t"
            default: body.unicodeScalars.append(scalar.properties.generalCategory == .control ? " " : scalar)
            }
        }
        return "\"" + body + (text.count > 40 ? "...\"" : "\"")
    }

    /// `(tables: glasses, items)`, or `(<none>)` when there is nothing to list.
    static func choices(_ label: String, _ items: [String], none: String) -> String {
        items.isEmpty ? "(\(none))" : "(\(label): \(items.joined(separator: ", ")))"
    }

    private static func oneLine(_ text: String) -> String {
        text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).joined(separator: " ")
    }
}
