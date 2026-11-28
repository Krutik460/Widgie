import Foundation
import Rows
import Testing
import WidgetBuilder
import WidgetEngine

/// A draft in a scratch engine: live and tappable with sample rows, invisible to every other engine, and gone
/// from disk once the engine is released.
@Suite struct PreviewTests {
    @Test @MainActor func aLoadedSampleDrawsExactlyItsRows() async throws {
        let engine = Engine.scratch(calendar: utc)
        let source = try fixture("water")
        let id = try await build(source, in: engine)

        try engine.load(.sample("morning"), into: id, at: morning)
        for family in Family.allCases {
            let face = picture(await face(id, in: engine, family), family)
            #expect(face.looksLike(try await proof(source, .sample("morning"), family)))
            #expect(!face.looksLike(try await proof(source, .empty, family)))
        }
    }

    @Test @MainActor func switchingStatesReplacesTheRowsInsteadOfAddingToThem() async throws {
        let engine = Engine.scratch(calendar: utc)
        let source = try fixture("water")
        let id = try await build(source, in: engine)

        try engine.load(.sample("morning"), into: id, at: morning)
        try engine.load(.sample("goal met"), into: id, at: morning)
        let goal = picture(await face(id, in: engine, .medium), .medium)
        #expect(goal.looksLike(try await proof(source, .sample("goal met"), .medium)))

        try engine.load(.empty, into: id, at: morning)
        #expect(picture(await face(id, in: engine)).looksLike(try await proof(source, .empty)))
    }

    @Test @MainActor func aTapWritesOnTopOfTheSample() async throws {
        let engine = Engine.scratch(calendar: utc)
        let source = try fixture("water")
        let id = try await build(source, in: engine)
        try engine.load(.sample("morning"), into: id, at: morning)

        for _ in 0..<2 {
            try engine.perform(try button("drink", on: await face(id, in: engine)).tap, at: morning)
        }
        let rows = #"""
            {"glasses": [{"daysAgo": 0, "repeat": 4}, {"daysAgo": 1, "repeat": 6}, {"daysAgo": 2, "repeat": 8},
              {"daysAgo": 3, "repeat": 5}, {"daysAgo": 4, "repeat": 7}, {"daysAgo": 5, "repeat": 8},
              {"daysAgo": 6, "repeat": 3}]}
            """#
        for family in Family.allCases {
            #expect(
                picture(await face(id, in: engine, family), family)
                    .looksLike(try await expected(source, rows: rows, family)))
        }
    }

    @Test @MainActor func rollingBackToACheckpointBringsBackTheHeadAndTheRowsTapsIncluded() async throws {
        let engine = Engine.scratch(calendar: utc)
        let source = try fixture("water")
        let id = try await build(source, in: engine)
        try engine.load(.sample("morning"), into: id, at: morning)
        try engine.perform(try button("drink", on: await face(id, in: engine)).tap, at: morning)
        let tapped = picture(await face(id, in: engine, .medium), .medium)
        let saved = try engine.source(of: id)?.json
        let checkpoint = try engine.checkpoint(of: id)

        let bluer = WidgetSource(
            json: Data(String(decoding: source.json, as: UTF8.self).replacing("#0B2A3C", with: "#1B3A8C").utf8))
        #expect(try await engine.build(bluer, replacing: id) == .saved(id))
        try engine.load(.sample("goal met"), into: id, at: morning)
        #expect(!picture(await face(id, in: engine, .medium), .medium).looksLike(tapped))

        try engine.rollBack(to: checkpoint)
        #expect(picture(await face(id, in: engine, .medium), .medium).looksLike(tapped))
        #expect(try engine.source(of: id)?.json == saved)
    }

    @Test @MainActor func rollingBackToACheckpointDropsTheTablesACancelledRefinementAdded() async throws {
        let engine = Engine.scratch(calendar: utc)
        let water = try fixture("water")
        let id = try await build(water, in: engine)
        let checkpoint = try engine.checkpoint(of: id)
        func extras(_ kind: String, _ value: String) -> WidgetSource {
            WidgetSource(
                json: Data(
                    String(decoding: water.json, as: UTF8.self)
                        .replacing(#""tables": {"#, with: #""tables": {"extras": {"fields": {"value": "\#(kind)"}}, "#)
                        .replacing(#""morning": {"#, with: #""morning": {"extras": [{"value": \#(value)}], "#)
                        .utf8))
        }

        #expect(try await engine.build(extras("text", #""a""#), replacing: id) == .saved(id))
        try engine.load(.sample("morning"), into: id, at: morning)
        try engine.rollBack(to: checkpoint)

        let outcome = try await engine.build(extras("number", "3"), replacing: id)
        #expect(outcome == .saved(id))
    }

    @Test func aDraftIsInvisibleToEveryOtherEngine() async throws {
        let engine = Engine.scratch(calendar: utc)
        let id = try await build(try fixture("water"), in: engine)
        #expect(try engine.widgets().map(\.id) == [id])

        let other = Scratch()
        #expect(try other.engine.widgets().isEmpty)
        #expect(try Engine.scratch(calendar: utc).widgets().isEmpty)
    }

    @Test func samplesAreListedByName() async throws {
        let engine = Engine.scratch(calendar: utc)
        let id = try await build(try fixture("water"), in: engine)
        #expect(try engine.samples(of: id) == ["goal met", "morning"])
        #expect(try engine.samples(of: WidgetID(rawValue: "nothing")).isEmpty)
    }

    @Test func anUnknownSampleThrowsWithTheNamesItHas() async throws {
        let engine = Engine.scratch(calendar: utc)
        let id = try await build(try fixture("water"), in: engine)
        let error = #expect(throws: EngineError.self) { try engine.load(.sample("noon"), into: id) }
        #expect(error?.message == #"no sample "noon" (samples: goal met, morning)"#)
    }

    @Test func theSharedStoreRefusesSamples() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("water"))
        let error = #expect(throws: EngineError.self) { try scratch.engine.load(.sample("morning"), into: id) }
        #expect(error?.message == "samples load only into a scratch engine, never the shared store")
        #expect(scratch.commits == 1)
    }

    @Test func aScratchEngineDeletesItsFolderOnceReleased() async throws {
        var engine: Engine? = Engine.scratch(calendar: utc)
        let folder = try #require(engine).directory
        let id = try await build(try fixture("water"), in: try #require(engine))
        try engine?.load(.sample("morning"), into: id)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "store.sqlite").path()))

        engine = nil
        #expect(!FileManager.default.fileExists(atPath: folder.path()))
    }

    @Test func releasingAnEngineOnAGivenFolderLeavesTheFolderInPlace() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "preview-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: folder) }
        var engine: Engine? = Engine(directory: folder, calendar: utc)
        let id = try await build(try fixture("water"), in: try #require(engine))

        engine = nil
        #expect(try Engine(directory: folder, calendar: utc).widgets().map(\.id) == [id])
    }

    @Test func theLeftoverSweepRemovesEarlierRunsScratchFoldersAndKeepsThisRunsOnes() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "preview-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let engine = Engine.scratch(under: root, calendar: utc)
        let id = try await build(try fixture("water"), in: engine)
        let earlier = root.appending(path: UUID().uuidString).appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: earlier, withIntermediateDirectories: true)

        Engine.removeLeftoverScratch(under: root)
        #expect(!FileManager.default.fileExists(atPath: earlier.deletingLastPathComponent().path()))
        #expect(FileManager.default.fileExists(atPath: engine.directory.appending(path: "store.sqlite").path()))
        try engine.load(.sample("morning"), into: id)
    }

    @Test @MainActor func savingADraftCarriesItsDocumentAndNoneOfItsSampleRows() async throws {
        let draft = Engine.scratch(calendar: utc)
        let source = try fixture("water")
        let id = try await build(source, in: draft)
        try draft.load(.sample("morning"), into: id, at: morning)
        try draft.perform(try button("drink", on: await face(id, in: draft)).tap, at: morning)
        #expect(!picture(await face(id, in: draft)).looksLike(try await proof(source, .empty)))

        let shared = Scratch()
        let saved = try await shared.build(try #require(try draft.source(of: id)))
        for family in Family.allCases {
            #expect(
                picture(await shared.face(saved, family), family).looksLike(try await proof(source, .empty, family)))
        }
    }

    @Test func samplesOfAnIdThatNamesNoWidgetHereAreEmpty() async throws {
        let elsewhere = try await build(try fixture("water"), in: Engine.scratch(calendar: utc))
        #expect(try Engine.scratch(calendar: utc).samples(of: elsewhere).isEmpty)
    }

    @Test @MainActor func theEmptyStateLoadsIntoAWidgetWithNoTables() async throws {
        let engine = Engine.scratch(calendar: utc)
        let still = document(
            name: "Still",
            look: """
                function render(ctx) {
                  return { type: 'vstack', padding: 14, frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
                    widgetBackground: '#102030',
                    children: [{ type: 'text', value: 'Hello', size: 30, weight: 'bold', color: '#FFFFFF' }] };
                }
                """,
            tables: [:], queries: [:], actions: [:], samples: [:])
        let id = try await build(still, in: engine)
        #expect(try engine.samples(of: id).isEmpty)

        try engine.load(.empty, into: id, at: morning)
        #expect(picture(await face(id, in: engine)).looksLike(try await proof(still, .empty)))
    }

    @Test @MainActor func aSampleLoadsIntoARefinedDraft() async throws {
        let engine = Engine.scratch(calendar: utc)
        let water = try fixture("water")
        let id = try await build(water, in: engine)
        try engine.load(.sample("morning"), into: id, at: morning)
        let bluer = WidgetSource(
            json: Data(String(decoding: water.json, as: UTF8.self).replacing("#0B2A3C", with: "#1B3A8C").utf8))
        #expect(try await build(bluer, in: engine, replacing: id) == id)

        try engine.load(.sample("goal met"), into: id, at: morning)
        for family in Family.allCases {
            let face = picture(await face(id, in: engine, family), family)
            #expect(face.looksLike(try await proof(bluer, .sample("goal met"), family)))
            #expect(!face.looksLike(try await proof(water, .sample("goal met"), family)))
        }
    }

    @Test @MainActor func aStagedWidgetShowsItsFirstSampleInOneFace() async throws {
        let engine = Engine.scratch(calendar: utc)
        let source = try fixture("water")
        let id = try engine.stageProved(source, at: morning)

        let first = try #require(try engine.samples(of: id).first)
        for family in Family.allCases {
            let face = await engine.face(for: id, family: family, size: family.standardSize, at: morning).current
            #expect(picture(face, family).looksLike(try await proof(source, .sample(first), family)))
            let timeline = await engine.faces(for: id, family: family, size: family.standardSize, from: morning)
            #expect(picture(face, family).looksLike(picture(timeline.current, family)), "the timeline's first face")
        }
    }

    /// Staging trusts the source, so a look the proof turns down still draws: the proof is what it saves.
    @Test @MainActor func stagingSkipsTheProof() async throws {
        let wide = document(
            look: """
                function render(ctx) {
                  return { type: 'text', value: String(ctx.data.n), size: 30, frame: { width: 900 },
                    widgetBackground: '#102030', color: '#FFFFFF' };
                }
                """)
        guard case .rejected = try await Engine.scratch(calendar: utc).build(wide) else {
            Issue.record("the proof should turn a 900 point frame down")
            return
        }
        let engine = Engine.scratch(calendar: utc)
        let id = try engine.stageProved(wide, at: morning)
        #expect(
            !(await engine.face(for: id, family: .small, size: Family.small.standardSize, at: morning)).current
                .isFallback)
    }

    @Test func onlyAScratchEngineStages() throws {
        #expect(throws: EngineError.self) { try Scratch().engine.stageProved(try fixture("water")) }
    }

    @Test @MainActor func aCopyDrawsTheRowsTheWidgetReadsAndItsTapsStayInTheCopy() async throws {
        let shared = Scratch()
        let source = try fixture("water")
        let saved = try await shared.build(source)
        for _ in 0..<3 { try shared.engine.perform(try button("drink", on: await shared.face(saved)).tap, at: morning) }
        let before = picture(await shared.face(saved, .medium), .medium)

        let draft = Engine.scratch(calendar: utc)
        let id = try #require(try await draft.copy(saved, from: shared.engine))
        for family in Family.allCases {
            #expect(
                picture(await face(id, in: draft, family), family).looksLike(
                    picture(await shared.face(saved, family), family)))
        }

        try draft.perform(try button("drink", on: await face(id, in: draft)).tap, at: morning)
        let four = #"{"glasses": [{"daysAgo": 0, "repeat": 4}]}"#
        #expect(
            picture(await face(id, in: draft, .medium), .medium).looksLike(
                try await expected(source, rows: four, .medium)))
        #expect(
            picture(await shared.face(saved, .medium), .medium).looksLike(before), "the library's rows are untouched")
    }

    @Test @MainActor func aCopyKeepsRowsWrittenAheadAndTheAutomationsRowsAsThePersonsOwn() async throws {
        let shared = Scratch()
        let source = try fixture("dogfed")
        let saved = try await shared.build(source)
        let pull = instant("2026-11-18T13:00:00Z")
        let fed = instant("2026-11-18T14:00:00Z")
        let key = try #require(WidgetKey(parsing: saved.rawValue))
        let feeds = try #require(try shared.engine.store().bindings(of: key)["feeds"])
        try shared.engine.receive(try page(Run(dataset: feeds.raw, at: fed, written: pull).changes(from: 1)), at: pull)

        let draft = Engine.scratch(calendar: utc)
        let id = try #require(try await draft.copy(saved, from: shared.engine))
        let size = Family.small.standardSize
        let original = await shared.engine.faces(for: saved, family: .small, size: size, from: pull)
        let copied = await draft.faces(for: id, family: .small, size: size, from: pull)
        #expect(copied.entries.map(\.date) == original.entries.map(\.date))
        #expect(copied.entries.map(\.date).contains(fed), "the feed written ahead still reveals at its time")
        for (copy, entry) in zip(copied.entries, original.entries) {
            #expect(picture(copy).looksLike(picture(entry)))
        }
        let revealed = try #require(copied.entries.first { $0.date == fed })
        #expect(!picture(revealed).looksLike(picture(copied.current)))
    }

    @Test @MainActor func aRefinementOfACopyKeepsTheRowsOfTheTablesItKeeps() async throws {
        let shared = Scratch()
        let water = try fixture("water")
        let saved = try await shared.build(water)
        for _ in 0..<3 { try shared.engine.perform(try button("drink", on: await shared.face(saved)).tap, at: morning) }
        let draft = Engine.scratch(calendar: utc)
        let id = try #require(try await draft.copy(saved, from: shared.engine))

        let bluer = WidgetSource(
            json: Data(String(decoding: water.json, as: UTF8.self).replacing("#0B2A3C", with: "#1B3A8C").utf8))
        #expect(try await build(bluer, in: draft, replacing: id) == id)
        let three = #"{"glasses": [{"daysAgo": 0, "repeat": 3}]}"#
        for family in Family.allCases {
            #expect(
                picture(await face(id, in: draft, family), family).looksLike(
                    try await expected(bluer, rows: three, family)))
        }
    }

    /// Another widget bound to the same dataset writes rows the copied widget reads, so the copy has them too.
    @Test @MainActor func aCopyReadsTheRowsAnotherWidgetWroteIntoItsDataset() async throws {
        let shared = Scratch()
        let source = try fixture("water")
        let saved = try await shared.build(source)
        let other = try await shared.build(source)
        let store = try shared.engine.store()
        let owner = try #require(WidgetKey(parsing: saved.rawValue))
        let reader = try #require(WidgetKey(parsing: other.rawValue))
        let glasses = try #require(try store.widget(owner)?.spec.table(named: "glasses")).id
        try store.bind(reader, table: glasses, to: try #require(try store.dataset(of: owner, table: glasses)))
        try shared.engine.perform(try button("drink", on: await shared.face(saved)).tap, at: morning)
        for _ in 0..<2 { try shared.engine.perform(try button("drink", on: await shared.face(other)).tap, at: morning) }

        let draft = Engine.scratch(calendar: utc)
        let id = try #require(try await draft.copy(saved, from: shared.engine))
        let three = #"{"glasses": [{"daysAgo": 0, "repeat": 3}]}"#
        for family in Family.allCases {
            #expect(
                picture(await face(id, in: draft, family), family).looksLike(
                    try await expected(source, rows: three, family)))
        }
    }

    /// A row deleted in the library is not copied, so it never comes back in the draft.
    @Test @MainActor func aRowDeletedInTheLibraryStaysOutOfTheCopy() async throws {
        let shared = Scratch()
        let source = try fixture("water")
        let saved = try await shared.build(source)
        for _ in 0..<3 { try shared.engine.perform(try button("drink", on: await shared.face(saved)).tap, at: morning) }
        try shared.engine.perform(try button("undo", on: await shared.face(saved)).tap, at: morning)

        let draft = Engine.scratch(calendar: utc)
        let id = try #require(try await draft.copy(saved, from: shared.engine))
        let two = #"{"glasses": [{"daysAgo": 0, "repeat": 2}]}"#
        for family in Family.allCases {
            #expect(
                picture(await face(id, in: draft, family), family).looksLike(
                    try await expected(source, rows: two, family)))
        }
    }

    /// A restore drops a table a later revision added, but keeps its binding, so a refinement that adds it back
    /// reads its rows again. The copy keeps that binding and those rows, so the draft shows what Save will.
    @Test @MainActor func aCopyKeepsTheBindingOfATableARestoreDroppedAndItsRows() async throws {
        let shared = Scratch()
        let first = document(look: counterLook())
        let spilled = document(
            look: counterLook(
                "{ type: 'text', value: ctx.data.n + '/' + ctx.data.s, size: 30, color: '#FFFFFF', lineLimit: 1 }",
                extra: "{ type: 'button', action: 'spill', children: [{ type: 'text', value: 'spill', size: 12 }] },"),
            tables: ["taps": ["fields": [:] as [String: Any]], "spills": ["fields": [:] as [String: Any]]],
            queries: ["n": ["count": "taps", "window": "all"], "s": ["count": "spills", "window": "all"]],
            actions: ["add": ["insert": "taps"], "spill": ["insert": "spills"]])
        let saved = try await shared.build(first)
        _ = try await shared.build(spilled, replacing: saved)
        for _ in 0..<2 { try shared.engine.perform(try button("spill", on: await shared.face(saved)).tap, at: morning) }
        try shared.engine.restore(saved, to: try #require(try shared.engine.history(of: saved).last))
        let key = try #require(WidgetKey(parsing: saved.rawValue))
        let library = try shared.engine.store().bindings(of: key)
        #expect(library["spills"] != nil)

        let draft = Engine.scratch(calendar: utc)
        let id = try #require(try await draft.copy(saved, from: shared.engine))
        let copy = try #require(WidgetKey(parsing: id.rawValue))
        #expect(try draft.store().bindings(of: copy) == library)
        #expect(try await build(spilled, in: draft, replacing: id) == id)
        let two = #"{"spills": [{"daysAgo": 0, "repeat": 2}]}"#
        #expect(picture(await face(id, in: draft)).looksLike(try await expected(spilled, rows: two)))
    }

    /// The copy holds the person's dataset keys, so a scratch engine refuses both ways to sync: an automation
    /// upload from its drafts would replace the person's automations, and a pull would write into the copy.
    @Test func aScratchEngineNeverSyncs() async throws {
        let shared = Scratch()
        let saved = try await shared.build(try fixture("wotd"))
        let words = try dataset(of: saved, in: shared.engine)
        let draft = Engine.scratch(calendar: utc)
        _ = try #require(try await draft.copy(saved, from: shared.engine))
        let pulled = try page(
            Run(dataset: words, at: morning, written: morning, cells: ["word": "Petrichor"]).changes(from: 1))

        #expect(throws: EngineError.self) { try draft.automationPayload() }
        #expect(throws: EngineError.self) { try draft.receive(pulled, at: morning) }
        #expect(try draft.watermark() == 0)
    }

    @Test func aCopyOfAWidgetTheLibraryDoesNotHaveIsNil() async throws {
        let draft = Engine.scratch(calendar: utc)
        #expect(try await draft.copy(WidgetID(rawValue: "nothing"), from: Scratch().engine) == nil)
    }

    @Test func onlyAScratchEngineTakesACopy() async throws {
        let shared = Scratch()
        let saved = try await shared.build(try fixture("water"))
        await #expect(throws: EngineError.self) { try await Scratch().engine.copy(saved, from: shared.engine) }
    }

    private func build(_ source: WidgetSource, in engine: Engine, replacing: WidgetID? = nil) async throws
        -> WidgetID
    {
        let outcome = try await engine.build(source, replacing: replacing)
        guard case .saved(let id) = outcome else {
            Issue.record("expected the widget to save, got \(outcome)")
            throw Unexpected()
        }
        return id
    }

    private func face(_ id: WidgetID, in engine: Engine, _ family: Family = .small) async -> Face {
        await engine.faces(for: id, family: family, size: family.standardSize, from: morning).current
    }

    private func proof(_ source: WidgetSource, _ state: DataState, _ family: Family = .small) async throws -> Bitmap {
        try Bitmap(png: try await Engine.proof(source, state: state, family: family, at: morning, calendar: utc).png)
    }
}
