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
            suggestion: .init(title: "When was the dog fed?", subtitle: "", icon: "pawprint.fill", tint: .amber),
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
    /// its placeholders, with awkward values, with every blank at its longest, and with every blank "me" or "Me",
    /// which also proves the face.
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
            // "me" in any case is how a sample names the person, so a blank must never reach a sample's author.
            let me = ["me", "Me"].map { word in Dictionary(uniqueKeysWithValues: template.blanks.map { ($0.key, word) })
            }
            for values in [[:], awkward] + longest + me {
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

    /// A name typed into a template sheet keeps the taps practised on its face, which is right only while a
    /// blank changes the name and the look and nothing else: no table, action or sample.
    @Test func blanksChangeOnlyTheNameAndTheLook() throws {
        func document(_ source: WidgetSource) throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: source.json) as? [String: Any])
        }
        func canonical(_ value: Any) throws -> Data {
            try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])
        }
        for template in Template.catalog() where !template.blanks.isEmpty {
            let placeholders = try document(template.source())
            let typed = try document(
                template.source(filling: Dictionary(uniqueKeysWithValues: template.blanks.map { ($0.key, "Zed") })))
            #expect(Set(placeholders.keys) == Set(typed.keys), "\(template.id)")
            for (key, value) in placeholders where key != "name" && key != "look" {
                #expect(try canonical(value) == canonical(typed[key] ?? NSNull()), "\(template.id): a blank in \(key)")
            }
        }
    }
}

/// What VoiceOver reads for each button a template draws, in every state the builder proves.
@Suite struct TemplateLabelTests {
    private func labels(_ template: Template) async throws -> [(state: String, family: Family, labels: [String])] {
        let engine = Engine.scratch()
        let id = try engine.stageProved(template.source())
        let states = [DataState.empty] + (try engine.samples(of: id)).map(DataState.sample) + [.full]
        var found: [(String, Family, [String])] = []
        for state in states {
            try engine.load(state, into: id)
            for family in Family.allCases {
                let face = await engine.faces(for: id, family: family, size: family.standardSize, from: .now).current
                #expect(!face.isFallback, "\(template.id), \(state), \(family) draws its look")
                found.append(("\(state)", family, face.buttonLabels))
            }
        }
        return found
    }

    @Test func everyButtonOnEveryTemplateSaysWhatItIsAndNoTwoReadTheSame() async throws {
        for template in Template.catalog() {
            for (state, family, labels) in try await labels(template) {
                // The full state gives every row the same long title, so only there may two rows read the same.
                if state != "full" {
                    #expect(Set(labels).count == labels.count, "\(template.id), \(state), \(family): \(labels)")
                }
            }
        }
    }

    /// Keys that show only a mark read what they do, and squares read which habit and whether it is done.
    @Test func keysWithoutWordsReadWhatTheyDo() async throws {
        let expected: [(id: String, state: String, labels: [String])] = [
            ("pet-fed", #"sample("just fed")"#, ["Undo", "Fed Luna"]),
            ("thinking-of-you", #"sample("only mine")"#, ["Send Sam a heart"]),
            ("baby-feeds", #"sample("just fed")"#, ["Fed on the left", "Fed on the right", "Fed a bottle", "Undo"]),
            ("habit-squares", "empty", ["Gym, today", "Read, today", "No sugar, today"]),
            (
                "habit-squares", #"sample("all done today")"#,
                ["Gym, today, done", "Read, today, done", "No sugar, today, done"]
            ),
            ("streak", #"sample("done today")"#, ["Meditate, today, done"]),
            ("our-moods", "empty", ["Your mood, not set"]),
            (
                "shared-groceries", #"sample("all crossed off")"#,
                ["Add to the list", "Bread, crossed off", "Remove Bread", "Tomatoes, crossed off", "Remove Tomatoes"]
            ),
            ("trip-countdown", "empty", ["Lisbon, set the date"]),
            (
                "trip-countdown", #"sample("a trip in twelve days")"#,
                ["Lisbon, 12 days until our trip, change the date"]
            ),
            ("days-together", "empty", ["Together, set the day of your first date"]),
            ("days-free", "empty", ["Alcohol-free, set the day you started"]),
        ]
        for (id, state, labels) in expected {
            let template = try #require(Template.catalog().first { $0.id == id })
            let found = try await self.labels(template).first { $0.state == state && $0.family == .small }
            #expect(found?.labels == labels, "\(id), \(state)")
        }
    }
}

/// What a template's face offers to tap in a given state: the action of every button it draws.
@Suite struct TemplateBehaviourTests {
    private func buttons(_ id: String, family: Family = .small, rows: String) async throws -> [String] {
        let template = try #require(Template.catalog().first { $0.id == id })
        let file = FileManager.default.temporaryDirectory.appending(path: "state-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(rows.utf8).write(to: file)
        let proof = try await Engine.proof(template.source(), state: .file(file), family: family)
        #expect(proof.verdict == nil, "\(id) draws this state")
        return proof.fit.buttons
    }

    @Test func yourMoodFaceStepsToTheNextFaceAndWrapsAround() async throws {
        #expect(try await buttons("our-moods", rows: "{}") == ["mood2"], "no mood yet starts on a smile")
        for (mood, next) in [(0, 1), (1, 2), (2, 3), (3, 4), (4, 0)] {
            let rows = #"{"moods": [{"mood": 3, "by": "Sam"}, {"mood": \#(mood)}]}"#
            #expect(try await buttons("our-moods", rows: rows) == ["mood\(next)"])
        }
        #expect(
            try await buttons("our-moods", rows: #"{"moods": [{"mood": 4, "daysAgo": 1}]}"#) == ["mood2"],
            "yesterday's mood is not today's")
    }

    @Test func sayingYoullCookCanBeTakenBackButOnlyYourOwnSay() async throws {
        #expect(try await buttons("dinner-tonight", rows: "{}") == ["cook"])
        #expect(try await buttons("dinner-tonight", rows: #"{"cooks": [{"by": "Sam"}]}"#) == ["cook"])
        #expect(try await buttons("dinner-tonight", rows: #"{"cooks": [{"by": "Sam"}, {}]}"#) == ["unsay"])
        #expect(try await buttons("dinner-tonight", rows: #"{"cooks": [{"daysAgo": 1}]}"#) == ["cook"])
    }

    @Test func answeringTodaysQuestionCanBeUndoneUntilTomorrow() async throws {
        #expect(try await buttons("todays-question", family: .medium, rows: "{}") == ["answer"])
        #expect(try await buttons("todays-question", family: .medium, rows: #"{"answers": [{}]}"#) == ["unanswer"])
        #expect(
            try await buttons("todays-question", family: .medium, rows: #"{"answers": [{"daysAgo": 1}]}"#)
                == ["answer"])
    }

    @Test func theStreakCheckMarksTodayOrTakesItBack() async throws {
        #expect(try await buttons("streak", rows: #"{"sessions": [{"daysAgo": 1}]}"#) == ["done"])
        #expect(try await buttons("streak", rows: #"{"sessions": [{"daysAgo": 1}, {}]}"#) == ["undo"])
    }
}

@MainActor @Suite struct TemplateGalleryTests {
    private let gallery = TemplateGallery()

    @Test func everyTemplateSitsOnItsShelfInThePrototypesOrder() {
        let shelves = Template.Category.allCases.map { gallery.templates(in: $0).map(\.id) }
        #expect(
            shelves == [
                ["thinking-of-you", "our-moods", "trip-countdown", "days-together", "todays-question"],
                [
                    "pet-fed", "bins-night", "shared-groceries", "plant-care", "dinner-tonight", "baby-feeds",
                    "chores-scoreboard",
                ],
                ["habit-squares", "streak", "water", "pushups"],
                ["savings-jar", "days-free", "word-of-the-day"],
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
        await gallery.drawn()
        for template in gallery.catalog {
            let face = try #require(gallery.card(template.id).face, "\(template.id) drew no face")
            #expect(!face.isFallback, "\(template.id) fell back instead of drawing its look")
        }
    }

    /// Every face is drawn once the pile's width is known, the shown category's first, and drawn again when the
    /// width changes.
    @Test func theFacesDrawInTheBackgroundTheShownCategoryFirst() async throws {
        var landed: [Template.ID] = []
        func watch() {
            for template in gallery.catalog {
                let card = gallery.card(template.id)
                withObservationTracking {
                    _ = card.face
                } onChange: {
                    MainActor.assumeIsolated { landed.append(template.id) }
                }
            }
        }
        watch()
        gallery.show(.goals)
        gallery.fit(column: 362)
        await gallery.drawn()
        let goals = gallery.templates(in: .goals).map(\.id)
        #expect(Set(landed.prefix(goals.count)) == Set(goals), "the shown category comes first")
        #expect(Set(landed) == Set(gallery.catalog.map(\.id)) && landed.count == gallery.catalog.count)

        gallery.fit(column: 330)
        #expect(gallery.catalog.allSatisfy { gallery.card($0.id).face == nil }, "the old size's faces go")
        await gallery.drawn()
        #expect(gallery.catalog.allSatisfy { gallery.card($0.id).face != nil }, "and the new size's come")
    }

    /// A value typed into any blank changes what the face draws, in both sizes, so it reaches the face and not
    /// only the widget's name: the empty face a new widget starts on, or the first sample, which the pile and the
    /// trial show while the person types.
    @Test func everyBlankReachesTheFace() async throws {
        let date = Date(timeIntervalSince1970: 1_795_000_000)
        for template in gallery.catalog {
            let document = try JSONSerialization.jsonObject(with: template.source().json) as? [String: Any]
            let first = (document?["samples"] as? [String: Any] ?? [:]).keys
                .min { Array($0.utf8).lexicographicallyPrecedes($1.utf8) }
            let states = [DataState.empty] + (first.map { [.sample($0)] } ?? [])
            for family in Family.allCases {
                var placeholders: [Data] = []
                for state in states {
                    placeholders.append(
                        try await Engine.proof(template.source(), state: state, family: family, at: date).png)
                }
                for blank in template.blanks {
                    let typed = try template.source(filling: [blank.key: "Zed"])
                    var reaches = false
                    for (state, placeholder) in zip(states, placeholders) where !reaches {
                        reaches =
                            try await Engine.proof(typed, state: state, family: family, at: date).png != placeholder
                    }
                    #expect(reaches, "\(template.id), \(family): \(blank.label) does not reach the face")
                }
            }
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
        let template = try #require(Template.catalog().first { $0.id == "pet-fed" })
        let trial = TemplateTrial(template: template, preview: Preview(library: shared.engine, startsEmpty: true))
        await trial.fill()
        let draft = try #require(trial.preview.widget)
        trial.greet()
        #expect(trial.said == trial.template.hint)

        // Pet fed paints red until the first feed and amber after it.
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
        let renamed = try #require(await hue())
        #expect(abs(renamed - fed) < abs(renamed - unfed), "a typed name keeps the feed tried on the face")
        #expect(try trial.preview.engine.widgets().first { $0.id == draft }?.name == "Mochi fed")
        #expect(try trial.choice().name == "Mochi fed")
        #expect(try shared.engine.widgets().isEmpty, "practice never reaches the shared store")
    }

    @Test func widgieTakesUpTheFieldThatChangedAndNotTheFirstOneFilledIn() async throws {
        let template = try #require(Template.catalog().first { $0.id == "habit-squares" })
        let trial = TemplateTrial(template: template, preview: Preview(library: shared.engine))
        await trial.fill()
        trial.values["first"] = "Swim"
        await trial.fill()
        #expect(trial.said == "Swim it is.")

        trial.values["second"] = "Read"
        await trial.fill()
        #expect(trial.said == "Read it is.")

        let reactions = trial.reactions
        trial.values["second"] = " "
        await trial.fill()
        #expect(trial.reactions == reactions, "a cleared field says nothing")
        #expect(trial.said == "Read it is.")
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
