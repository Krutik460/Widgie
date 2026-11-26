import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

@testable import Widgie

@Suite struct TemplateFillTests {
    /// The counter document with a blank in its name and one in its look, which draws the blank's value.
    private func document() -> Data {
        var json = try! JSONSerialization.jsonObject(with: Data(counterDocument().utf8)) as! [String: Any]
        json["name"] = "{{pet}} fed"
        json["look"] = (json["look"] as! String)
            .replacingOccurrences(of: "function render(ctx) {", with: "const PET = {{pet}};\nfunction render(ctx) {")
            .replacingOccurrences(of: "String(ctx.data.n)", with: "PET + ' ' + ctx.data.n")
        return try! JSONSerialization.data(withJSONObject: json)
    }

    private func filled(_ value: String) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: Template.fill(document(), with: ["pet": value])) as! [String: Any]
    }

    @Test func aBlankInPlainTextBecomesTheValue() throws {
        #expect(try filled("Luna")["name"] as? String == "Luna fed")
    }

    @Test func aBlankInTheLookBecomesAQuotedLiteralThatReadsBackAsTheValue() throws {
        for value in ["Luna", #"Lu"na"#, #"back\slash"#, "</script><b>", "two\nlines", "🐶 Mochi", "a\u{2028}b"] {
            let look = try filled(value)["look"] as! String
            let line = try #require(look.split(separator: "\n").first { $0.hasPrefix("const PET = ") })
            let literal = line.dropFirst("const PET = ".count).dropLast()
            #expect(!literal.contains("\u{2028}"))
            #expect(try JSONDecoder().decode(String.self, from: Data(literal.utf8)) == value)
        }
    }

    @Test func aBlankWithQuotesStillBuilds() async throws {
        let shared = SharedStore()
        let source = WidgetSource(json: try Template.fill(document(), with: ["pet": #"Lu"na's \ dog"#]))
        guard case .saved(let id) = try await shared.engine.build(source) else {
            Issue.record("expected the filled template to build")
            return
        }
        #expect(try shared.engine.widgets().first { $0.id == id }?.name == #"Lu"na's \ dog fed"#)
    }

    @Test func anEmptyOrBlankValueFallsBackToThePlaceholder() throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "template-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try document().write(to: folder.appending(path: "widget.json"))
        let template = Template(
            id: "pet", name: "Pet fed", line: "", category: .home, order: 0,
            blanks: [.init(key: "pet", label: "Your pet's name", placeholder: "Luna")], folder: folder)
        for value in [nil, "", "   "] {
            let json = try template.source(filling: value.map { ["pet": $0] } ?? [:]).json
            let name = (try JSONSerialization.jsonObject(with: json) as! [String: Any])["name"] as? String
            #expect(name == "Luna fed")
        }
    }
}

@Suite struct TemplateCatalogTests {
    /// Every bundled template reads, has every blank its document uses, and builds through `engine.build`, with
    /// its placeholders and with awkward values.
    @Test func everyBundledTemplateBuildsWithItsPlaceholdersAndWithAwkwardValues() async throws {
        let root = try #require(Bundle.main.url(forResource: "Templates", withExtension: nil))
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
        let catalog = Template.catalog(in: root)
        #expect(catalog.count == folders.count, "a template.json did not read")
        for template in catalog {
            for values in [[:], Dictionary(uniqueKeysWithValues: template.blanks.map { ($0.key, #"Mo"chi \ 🐶"#) })] {
                let source = try template.source(filling: values)
                #expect(
                    !String(decoding: source.json, as: UTF8.self).contains("{{"), "\(template.id) has an unfilled blank"
                )
                let shared = SharedStore()
                let outcome = try await shared.engine.build(source)
                guard case .saved = outcome else {
                    Issue.record("\(template.id) did not build with \(values): \(outcome)")
                    continue
                }
            }
        }
    }
}
