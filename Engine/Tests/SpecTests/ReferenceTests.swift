import Foundation
import Spec
import Testing

/// One `json` block of Reference/blocks.md, and the line it must fail with when a `text` block follows it.
/// After the comment `replacesMarker`, the block is a refinement of the `json` block before it, `replaces`.
struct ReferenceExample: CustomTestStringConvertible, Sendable {
    let line: Int
    let json: String
    let expectedError: String?
    let replaces: String?

    static let replacesMarker = "<!-- replaces the json block above -->"

    var testDescription: String { "blocks.md line \(line)" }

    static let all: [ReferenceExample] = {
        let text =
            (try? String(contentsOf: engineDirectory.appending(path: "Reference/blocks.md"), encoding: .utf8)) ?? ""
        let lines = text.components(separatedBy: "\n")
        var blocks: [(info: String, start: Int, body: String, end: Int)] = []
        var index = 0
        while index < lines.count {
            if lines[index].hasPrefix("```"), lines[index].count > 3 {
                let info = String(lines[index].dropFirst(3))
                let start = index + 1
                var end = start
                while end < lines.count, lines[end] != "```" { end += 1 }
                blocks.append((info, start, lines[start..<min(end, lines.count)].joined(separator: "\n"), end))
                index = end + 1
            } else {
                index += 1
            }
        }
        var examples: [ReferenceExample] = []
        var previous: String?
        for (position, block) in blocks.enumerated() where block.info == "json" {
            let next = blocks.indices.contains(position + 1) ? blocks[position + 1] : nil
            let between = next.map {
                lines[(block.end + 1)..<($0.start - 1)].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
            }
            let error = next?.info == "text" && between == true ? next?.body : nil
            let marked = block.start >= 2 && lines[block.start - 2] == replacesMarker
            examples.append(
                ReferenceExample(
                    line: block.start, json: block.body, expectedError: error, replaces: marked ? previous : nil))
            previous = block.body
        }
        return examples
    }()

    /// The example as a whole document: a `name` and a `look` are added when it leaves them out.
    func completed() throws -> Data { try Self.completed(json) }

    static func completed(_ json: String) throws -> Data {
        guard case .object(var members) = try JSONValue.parse(Data(json.utf8)) else { return Data(json.utf8) }
        if members["name"] == nil { members["name"] = .string("Example") }
        if members["look"] == nil { members["look"] = .string(minimalLook) }
        return JSONValue.object(members).encoded()
    }
}

@Suite struct ReferenceTests {
    @Test func referenceHasDocumentAndMistakeExamples() {
        #expect(ReferenceExample.all.filter { $0.expectedError == nil }.count >= 5)
        #expect(ReferenceExample.all.filter { $0.expectedError != nil }.count >= 5)
        #expect(ReferenceExample.all.contains { $0.replaces != nil && $0.expectedError != nil })
    }

    @Test(arguments: ReferenceExample.all)
    func exampleParsesOrFailsWithItsLine(_ example: ReferenceExample) throws {
        let document = try example.completed()
        if let old = example.replaces {
            let before = try Spec.parse(ReferenceExample.completed(old))
            let after = try Spec.parse(document)
            do throws(Diagnostic) {
                try after.checkCompatible(replacing: before)
                #expect(example.expectedError == nil, "refined, but the reference says it fails")
            } catch {
                #expect(error.line == example.expectedError)
            }
        } else if let expected = example.expectedError {
            do throws(Diagnostic) {
                _ = try Spec.parse(document)
                Issue.record("parsed, but the reference says it fails with: \(expected)")
            } catch {
                #expect(error.line == expected)
            }
        } else {
            let spec = try Spec.parse(document)
            #expect(try Spec.parse(spec.encoded()) == spec)
        }
    }
}
