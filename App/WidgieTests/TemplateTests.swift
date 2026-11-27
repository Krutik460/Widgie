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

    /// Each value holds the other blank, so filling one blank after the other expands one of them again in any
    /// order, which in the look ends a string literal early.
    @Test func aValueHoldingAnotherBlankIsFilledInAsTypedInOnePass() throws {
        let document = try JSONSerialization.data(withJSONObject: [
            "name": "{{pet}} and {{owner}}", "look": "const PET = {{pet}};\nconst OWNER = {{owner}};",
        ])
        let blanks = [("pet", "{{owner}}"), ("owner", "+alert(1)+{{pet}}")]
        for order in [blanks, blanks.reversed()] {
            for capacity in 1...32 {
                var values = [String: String](minimumCapacity: capacity)
                for (key, value) in order { values[key] = value }
                let filled =
                    try JSONSerialization.jsonObject(with: Template.fill(document, with: values))
                    as! [String: Any]
                #expect(filled["name"] as? String == "{{owner}} and +alert(1)+{{pet}}")
                #expect(
                    filled["look"] as? String == "const PET = \"{{owner}}\";\nconst OWNER = \"+alert(1)+{{pet}}\";")
            }
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

    /// A pet fed template over the counter document, whose one blank keeps at most `maxLength` characters.
    private func petFed(maxLength: Int = 36) throws -> (template: Template, folder: URL) {
        let folder = FileManager.default.temporaryDirectory.appending(path: "template-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try document().write(to: folder.appending(path: "widget.json"))
        let template = Template(
            id: "pet", name: "Pet fed", line: "", category: .home, order: 0, family: .small, hint: "",
            blanks: [.init(key: "pet", label: "Your pet's name", placeholder: "Luna", maxLength: maxLength)],
            folder: folder)
        return (template, folder)
    }

    private func name(of source: WidgetSource) throws -> String? {
        (try JSONSerialization.jsonObject(with: source.json) as? [String: Any])?["name"] as? String
    }

    @Test func anEmptyOrBlankValueFallsBackToThePlaceholder() throws {
        let (template, folder) = try petFed()
        defer { try? FileManager.default.removeItem(at: folder) }
        for value in [nil, "", "   "] {
            #expect(try name(of: template.source(filling: value.map { ["pet": $0] } ?? [:])) == "Luna fed")
        }
    }

    @Test func aValuePastTheBlanksLengthIsCutToItWithoutATrailingSpace() throws {
        let (template, folder) = try petFed(maxLength: 6)
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(try name(of: template.source(filling: ["pet": "  Mochi the Great"])) == "Mochi fed")
        #expect(try name(of: template.source(filling: ["pet": "Biscuit"])) == "Biscui fed")
        #expect(try name(of: template.source(filling: ["pet": "🐶🐶🐶🐶"])) == "🐶🐶🐶 fed", "an emoji is two units")
        #expect(try name(of: template.source(filling: ["pet": "Bo🐶🐶🐶"])) == "Bo🐶🐶 fed", "never half an emoji")
    }
}

@Suite struct TemplateCatalogTests {
    /// Every bundled template reads, has every blank its document uses, and builds through `engine.build`, with
    /// its placeholders, with awkward values, and with every blank at its longest, which also proves the face.
    @Test func everyBundledTemplateBuildsWithItsPlaceholdersAwkwardValuesAndTheLongestValues() async throws {
        let root = try #require(Bundle.main.url(forResource: "Templates", withExtension: nil))
        let folders = try FileManager.default.contentsOfDirectory(atPath: root.path(percentEncoded: false))
            .filter { !$0.hasPrefix(".") }
        let catalog = Template.catalog(in: root)
        #expect(catalog.count == folders.count, "a template.json did not read")
        for template in catalog {
            let awkward = Dictionary(uniqueKeysWithValues: template.blanks.map { ($0.key, #"Mo"chi \ 🐶"#) })
            // Past each blank's length, so the source cuts every value to the longest a person can type, in the
            // widest letter and in emoji, which count two units each.
            let longest = ["W", "🐶"].map { glyph in
                Dictionary(
                    uniqueKeysWithValues: template.blanks.map {
                        ($0.key, String(repeating: glyph, count: $0.maxLength + 5))
                    })
            }
            for values in [[:], awkward] + longest {
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
                ["thinking-of-you"], ["pet-fed", "shared-groceries"], ["habit-squares", "water"], ["word-of-the-day"],
            ])
    }

    @Test func aTypedNameNamesTheAddedWidget() async throws {
        let names = ["thinking-of-you": "Hearts for Alex", "pet-fed": "Alex fed"]
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
    private let shared = SharedStore()

    private func petFed() throws -> TemplateTrial {
        let template = try #require(Template.catalog().first { $0.id == "pet-fed" })
        return TemplateTrial(template: template, preview: Preview(library: shared.engine))
    }

    @Test func aTapIsPracticeOnScratchRowsAndATypedNameRebuildsTheFace() async throws {
        let trial = try petFed()
        await trial.fill()
        let draft = try #require(trial.preview.widget)
        trial.greet()
        #expect(trial.said == trial.template.hint)

        // Pet fed paints red until the first feed and amber after it.
        await trial.preview.select(.empty)
        func hue() async -> Double? {
            await trial.preview.engine.faces(for: draft, family: .small, size: Family.small.standardSize, from: .now)
                .current.traits.hue
        }
        let unfed = try #require(await hue())
        let revision = try #require(try trial.preview.engine.history(of: draft).first).id
        trial.tap(Tap(widget: draft.rawValue, revision: revision, action: "feed", row: nil))
        #expect(trial.said == "Just practice. Yours starts fresh.")
        let fed = try #require(await hue())
        #expect(abs(unfed - fed) > 20, "the tap wrote a feed to the scratch rows")

        trial.values["pet"] = "Mochi"
        await trial.fill()
        #expect(trial.said == "Mochi it is.")
        #expect(try trial.preview.engine.widgets().first { $0.id == draft }?.name == "Mochi fed")
        #expect(try trial.choice().name == "Mochi fed")
        #expect(try shared.engine.widgets().isEmpty, "practice never reaches the shared store")
    }

    @Test func theFaceEndsOnTheLatestNameHoweverTheBuildsOverlap() async throws {
        let trial = try petFed()
        trial.values["pet"] = "Bo"
        let opening = Task { await trial.fill() }
        await Task.yield()
        trial.values["pet"] = "Pip"
        let typing = Task { await trial.fill() }
        await Task.yield()
        trial.values["pet"] = "Mochi"
        await trial.fill()
        await opening.value
        await typing.value

        #expect(trial.preview.widget != nil)
        #expect(try trial.preview.engine.widgets().map(\.name) == ["Mochi fed"])
        #expect(trial.said == "Mochi it is.")
    }
}
