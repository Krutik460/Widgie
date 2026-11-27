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
            id: "pet", name: "Pet fed", line: "", category: .home, order: 0, family: .small, hint: "",
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

@MainActor @Suite struct TemplateGalleryTests {
    private let gallery = TemplateGallery()

    @Test func theSixTemplatesSitOnTheirShelvesInGalleryOrder() {
        let shelves = Template.Category.allCases.map { gallery.templates(in: $0).map(\.id) }
        #expect(
            shelves == [
                ["thinking-of-you"], ["pet-fed", "to-do-list"], ["habit-squares", "water"], ["word-of-the-day"],
            ])
    }

    @Test func aTypedNameNamesTheAddedWidget() async throws {
        let names = ["thinking-of-you": "Hearts for Alex", "pet-fed": "Alex fed", "habit-squares": "Alex"]
        for (id, expected) in names {
            let template = try #require(gallery.catalog.first { $0.id == id })
            let values = Dictionary(uniqueKeysWithValues: template.blanks.map { ($0.key, "  Alex ") })
            let shared = SharedStore()
            guard case .saved(let widget) = try await shared.engine.build(template.source(filling: values)) else {
                Issue.record("\(id) did not build")
                continue
            }
            #expect(try shared.engine.widgets().first { $0.id == widget }?.name == expected)
        }
    }

    @Test func everyTemplateDrawsAFaceFromItsSampleInThePile() async throws {
        gallery.fit(column: 362)
        for template in gallery.catalog {
            await gallery.draw(template)
            #expect(gallery.faces[template.id] != nil, "\(template.id) drew no face")
        }
    }
}

@MainActor @Suite struct TemplateTrialTests {
    @Test func aTapIsPracticeAndATypedNameRebuildsTheFace() async throws {
        let template = try #require(Template.catalog().first { $0.id == "pet-fed" })
        let trial = TemplateTrial(template: template, preview: Preview(library: SharedStore().engine))
        await trial.open()
        let draft = try #require(trial.preview.widget)
        trial.greet()
        #expect(trial.said == template.hint)

        let revision = try #require(try trial.preview.engine.history(of: draft).first).id
        trial.tap(Tap(widget: draft.rawValue, revision: revision, action: "feed", row: nil))
        #expect(trial.said == "Just practice. Yours starts fresh.")

        trial.values["pet"] = "Mochi"
        await trial.refill()
        #expect(trial.said == "Mochi it is.")
        #expect(try trial.preview.engine.widgets().first { $0.id == draft }?.name == "Mochi fed")
        #expect(try trial.choice().name == "Mochi fed")
    }
}
