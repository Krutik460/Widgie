import Foundation
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

    @Test @MainActor func restoringACheckpointBringsBackTheHeadAndTheRowsTapsIncluded() async throws {
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

        try engine.restore(checkpoint)
        #expect(picture(await face(id, in: engine, .medium), .medium).looksLike(tapped))
        #expect(try engine.source(of: id)?.json == saved)
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
