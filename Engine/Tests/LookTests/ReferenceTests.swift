import CoreText
import Foundation
import Sandbox
import Spec
import Testing
import WidgetEngine

/// Reference/look.md, read as the model reads it: fenced blocks, tables, and lists.
enum LookReference {
    static let lines: [String] =
        ((try? String(contentsOf: engineDirectory.appending(path: "Reference/look.md"), encoding: .utf8)) ?? "")
        .components(separatedBy: "\n")

    struct Block {
        let info: String
        let start: Int
        let end: Int
        let body: String
    }

    static let blocks: [Block] = {
        var blocks: [Block] = []
        var index = 0
        while index < lines.count {
            if lines[index].hasPrefix("```"), lines[index].count > 3 {
                let start = index + 1
                var end = start
                while end < lines.count, lines[end] != "```" { end += 1 }
                blocks.append(
                    Block(
                        info: String(lines[index].dropFirst(3)), start: start, end: end,
                        body: lines[start..<min(end, lines.count)].joined(separator: "\n")))
                index = end + 1
            } else {
                index += 1
            }
        }
        return blocks
    }()

    static let examples: [LookExample] = blocks.enumerated().compactMap { position, block in
        guard block.info == "js" else { return nil }
        let next = blocks.indices.contains(position + 1) ? blocks[position + 1] : nil
        let adjacent = next.map { next in
            lines[(block.end + 1)..<(next.start - 1)].allSatisfy { $0.trimmingCharacters(in: .whitespaces).isEmpty }
        }
        let error = next?.info == "text" && adjacent == true ? next?.body : nil
        return LookExample(line: block.start, source: block.body, expectedError: error)
    }

    /// The json block whose top level has `key`.
    static func json(with key: String) throws -> [String: JSONValue] {
        for block in blocks where block.info == "json" {
            if case .object(let members) = try JSONValue.parse(Data(block.body.utf8)), members[key] != nil {
                return members
            }
        }
        throw Diagnostic("look.md has no json block with \"\(key)\"")
    }

    static func widget() throws -> Spec {
        var members = try json(with: "queries")
        members["look"] = "function render() { return { type: 'spacer' }; }"
        return try Spec.parse(JSONValue.object(members).encoded())
    }

    /// The example ctx in `family`, and its data.
    static func context(_ family: Family) throws -> (json: String, data: [String: JSONValue]) {
        var members = try json(with: "data")
        guard case .object(let data)? = members["data"] else { throw Diagnostic("the example ctx has no data") }
        members["family"] = .string(family.rawValue)
        members["width"] = .number(Double(size(family).width))
        members["height"] = .number(Double(size(family).height))
        return (String(decoding: JSONValue.object(members).encoded(), as: UTF8.self), data)
    }

    /// The cells of each body row of the first table after `heading`.
    static func table(under heading: String) -> [[String]] {
        guard let start = lines.firstIndex(of: heading) else { return [] }
        let rows = lines[(start + 1)...].drop { !$0.hasPrefix("|") }.prefix { $0.hasPrefix("|") }
        return rows.dropFirst(2).map { row in
            row.split(separator: "|", omittingEmptySubsequences: false).dropFirst().dropLast()
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
    }

    /// The first code span of each numbered line after `heading`, up to the next heading.
    static func numbered(under heading: String) -> [String] {
        guard let start = lines.firstIndex(of: heading) else { return [] }
        return lines[(start + 1)...].prefix { !$0.hasPrefix("#") }.compactMap { line in
            guard line.first?.isNumber == true, line.contains(". `") else { return nil }
            return codeSpans(line).first
        }
    }

    static func codeSpans(_ text: String) -> [String] {
        text.split(separator: "`", omittingEmptySubsequences: false).enumerated().compactMap {
            $0.offset % 2 == 1 ? String($0.element) : nil
        }
    }
}

struct LookExample: Sendable, CustomTestStringConvertible {
    let line: Int
    let source: String
    let expectedError: String?

    var testDescription: String { "look.md line \(line)" }
}

@Suite struct ReferenceTests {
    @Test func referenceHasLooksAndMistakes() {
        #expect(LookReference.examples.filter { $0.expectedError == nil }.count >= 7)
        #expect(LookReference.examples.filter { $0.expectedError != nil }.count >= 5)
    }

    @Test(arguments: LookReference.examples)
    @MainActor func exampleRunsOrFailsWithItsLine(_ example: LookExample) async throws {
        let spec = try LookReference.widget()
        if let expected = example.expectedError {
            let (json, data) = try LookReference.context(.small)
            let result = await compose(
                example.source, context: json,
                bindings: bindings(spec, rows: receivedRows(data, spec: spec), images: ["cover": landscape]))
            guard case .failure(let error) = result else {
                Issue.record("the look validated, but the reference says it fails with: \(expected)")
                return
            }
            #expect(error.line == expected)
            return
        }
        for family in Family.allCases {
            let (json, data) = try LookReference.context(family)
            let input = bindings(
                spec, family: family, rows: receivedRows(data, spec: spec), images: ["cover": landscape])
            let tree = try await Sandbox().run(example.source, context: json, budget: .proof)
            let image = render(try Drawing.parse(tree: tree, bindings: input))
            let number = (LookReference.examples.firstIndex { $0.line == example.line } ?? 0) + 1
            try writeArtifact(image, "reference-\(number)-\(family.rawValue)")
            guard case .object(let root) = try JSONValue.parse(Data(tree.utf8)) else { throw Diagnostic("no root") }
            let bare = JSONValue.object(["type": "spacer", "widgetBackground": root["widgetBackground"] ?? .null])
            let background = render(
                try Drawing.parse(tree: String(decoding: bare.encoded(), as: UTF8.self), bindings: input))
            #expect(Bitmap(image).difference(Bitmap(background)) > 0.01, "the look draws more than its background")
        }
    }

    @Test func nodeTableAndCommonPropsMatchTheValidator() async throws {
        let rows = LookReference.table(under: "### Node types")
        let common = LookReference.numbered(under: "### Common props")
        #expect(rows.count == 13)
        #expect(common.count == 16)
        let spec = try LookReference.widget()
        for row in rows {
            let type = try #require(LookReference.codeSpans(row[0]).first)
            let props = LookReference.codeSpans(row[2])
            let result = await compose(
                "function render() { return { type: 'vstack', children: [{ type: '\(type)', notAProp: 1 }] }; }",
                context: context([:], family: .small), bindings: bindings(spec))
            guard case .failure(let error) = result else {
                Issue.record("\(type) accepted an unknown prop")
                continue
            }
            #expect(
                error.line.hasSuffix(
                    "(\(type) props: \(props.joined(separator: ", ")); common props: \(common.filter { !props.contains($0) }.joined(separator: ", ")))"
                ), "\(type)")
        }
    }

    @Test func fontTableIsTheAllowlist() {
        let names = LookReference.table(under: "### Named fonts").compactMap { LookReference.codeSpans($0[0]).first }
        #expect(names == Vocabulary.fonts.map(\.name))
    }

    /// Every allowlisted family is installed on the platform the tests run on, or bundled and registered by the
    /// engine. A missing family would not fail a render: SwiftUI would quietly draw the system font.
    /// `scripts/check` runs this on macOS, and `xcodebuild test` on an iOS simulator runs it against the fonts iOS
    /// ships.
    @Test(arguments: Vocabulary.fonts.map(\.name)) func namedFontShipsHere(_ family: String) {
        BundledFonts.register()
        let wanted = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
        let found = CTFontDescriptorCreateMatchingFontDescriptor(wanted, nil)
        #expect(found.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String } == family)
    }
}
