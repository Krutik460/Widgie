import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

/// Each reference widget built into a fresh engine, then tapped the way a person taps it: the tap comes from
/// a button the face offers, and the next face must look exactly like a proof of the rows the taps wrote.
@Suite struct EndToEndTests {
    @Test @MainActor func waterCountsEachTapAndUndoesOne() async throws {
        let scratch = Scratch()
        let source = try fixture("water")
        let id = try await scratch.build(source)
        #expect(picture(await scratch.face(id)).looksLike(try await expected(source, rows: "{}")))

        for _ in 0..<3 {
            try scratch.engine.perform(try button("drink", on: await scratch.face(id)).tap, at: morning)
        }
        let three = picture(await scratch.face(id))
        #expect(three.looksLike(try await expected(source, rows: #"{"glasses": [{"daysAgo": 0, "repeat": 3}]}"#)))
        #expect(!three.looksLike(try await expected(source, rows: #"{"glasses": [{"daysAgo": 0, "repeat": 2}]}"#)))
        let medium = picture(await scratch.face(id, .medium), .medium)
        #expect(
            medium.looksLike(
                try await expected(source, rows: #"{"glasses": [{"daysAgo": 0, "repeat": 3}]}"#, .medium)))

        let undo = try button("undo", on: await scratch.face(id))
        #expect(undo.tap.row != nil && !undo.opensForm)
        try scratch.engine.perform(undo.tap, at: morning)
        #expect(
            picture(await scratch.face(id))
                .looksLike(try await expected(source, rows: #"{"glasses": [{"daysAgo": 0, "repeat": 2}]}"#)))
    }

    @Test @MainActor func todoAddsThroughItsFormThenTogglesAndRemoves() async throws {
        let scratch = Scratch()
        let source = try fixture("todo")
        let id = try await scratch.build(source)

        let add = try button("add", on: await scratch.face(id))
        #expect(add.opensForm && add.tap.row == nil)
        let form = try #require(try scratch.engine.form(for: add.tap))
        #expect(form.title == "New to-do")
        #expect(form.fields.map(\.id) == ["title"] && form.fields.map(\.label) == ["Title"])
        #expect(form.fields.first?.kind == .text && form.fields.first?.value == nil)
        #expect(throws: EngineError.self) { try scratch.engine.perform(form.tap, input: ["title": .number(3)]) }
        try scratch.engine.perform(form.tap, input: ["title": .text("Buy oat milk")], at: morning)
        #expect(
            picture(await scratch.face(id))
                .looksLike(try await expected(source, rows: #"{"items": [{"daysAgo": 0, "title": "Buy oat milk"}]}"#)))

        try scratch.engine.perform(try button("toggle", on: await scratch.face(id)).tap, at: morning)
        #expect(
            picture(await scratch.face(id))
                .looksLike(
                    try await expected(
                        source, rows: #"{"items": [{"daysAgo": 0, "title": "Buy oat milk", "done": true}]}"#)))

        try scratch.engine.perform(try button("remove", on: await scratch.face(id)).tap, at: morning)
        #expect(picture(await scratch.face(id)).looksLike(try await expected(source, rows: "{}")))
    }

    @Test @MainActor func habitChecksAndUnchecksToday() async throws {
        let scratch = Scratch()
        let source = try fixture("habit")
        let id = try await scratch.build(source)

        try scratch.engine.perform(try button("check", on: await scratch.face(id)).tap, at: morning)
        #expect(
            picture(await scratch.face(id))
                .looksLike(try await expected(source, rows: #"{"checkins": [{"daysAgo": 0}]}"#)))

        let uncheck = try button("uncheck", on: await scratch.face(id))
        #expect(uncheck.tap.row != nil)
        try scratch.engine.perform(uncheck.tap, at: morning)
        #expect(picture(await scratch.face(id)).looksLike(try await expected(source, rows: "{}")))
    }

    @Test @MainActor func wordOfTheDayWaitsForItsAutomation() async throws {
        let scratch = Scratch()
        let source = try fixture("wotd")
        let id = try await scratch.build(source)
        let faces = await scratch.engine.faces(
            for: id, family: .medium, size: Family.medium.standardSize, from: morning)
        #expect(buttons(faces.current, .medium).isEmpty)
        #expect(picture(faces.current, .medium).looksLike(try await expected(source, rows: "{}", .medium)))
        #expect(faces.reloadAt == instant("2026-11-19T06:05:00Z"))
    }

    @Test func aNilWidgetMeansTheLatestCreation() async throws {
        let scratch = Scratch()
        let water = try await scratch.build(try fixture("water"))
        let todo = try await scratch.build(try fixture("todo"))
        #expect(try scratch.engine.widgets().map(\.id) == [todo, water])
        #expect(try scratch.engine.widgets().map(\.name) == ["To-do", "Water"])
        let latest = await scratch.engine.faces(
            for: nil, family: .small, size: Family.small.standardSize, from: morning)
        let chosen = await scratch.face(todo)
        #expect(await picture(latest.current).looksLike(await picture(chosen)))

        try scratch.engine.delete(todo)
        #expect(try scratch.engine.widgets().map(\.name) == ["Water"])
    }
}

@Suite struct StaleTapTests {
    @Test @MainActor func aTapOnADeletedRowDoesNothing() async throws {
        let scratch = Scratch()
        let source = try fixture("water")
        let id = try await scratch.build(source)
        try scratch.engine.perform(try button("drink", on: await scratch.face(id)).tap, at: morning)
        let undo = try button("undo", on: await scratch.face(id)).tap
        try scratch.engine.perform(undo, at: morning)
        let commits = scratch.commits

        try scratch.engine.perform(undo, at: morning)
        #expect(scratch.commits == commits)
        #expect(picture(await scratch.face(id)).looksLike(try await expected(source, rows: "{}")))
    }

    @Test @MainActor func aTapOnAnActionARefinementRemovedDoesNothing() async throws {
        let scratch = Scratch()
        let source = try fixture("water")
        let id = try await scratch.build(source)
        let drink = try button("drink", on: await scratch.face(id)).tap
        let renamed = WidgetSource(
            json: Data(String(decoding: source.json, as: UTF8.self).replacing("drink", with: "sip").utf8))
        _ = try await scratch.build(renamed, replacing: id)
        let commits = scratch.commits

        try scratch.engine.perform(drink, at: morning)
        try scratch.engine.perform(Tap(widget: "not a widget", action: "sip", row: nil), at: morning)
        try scratch.engine.perform(Tap(widget: id.rawValue, action: "undo", row: "not a row"), at: morning)
        #expect(scratch.commits == commits)
        #expect(picture(await scratch.face(id)).looksLike(try await expected(renamed, rows: "{}")))
        #expect(try scratch.engine.form(for: drink) == nil)
    }
}

@Suite struct MidnightTests {
    @Test @MainActor func todaysCountReadsZeroInTheEntryAfterMidnight() async throws {
        let scratch = Scratch()
        let source = try fixture("water")
        let id = try await scratch.build(source)
        let late = instant("2026-11-18T23:00:00Z")
        for _ in 0..<3 { try scratch.engine.perform(try button("drink", on: await scratch.face(id)).tap, at: late) }

        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: late)
        let midnight = instant("2026-11-19T00:00:00Z")
        #expect(faces.entries.map(\.date) == [late, midnight])
        #expect(faces.reloadAt == instant("2026-11-20T00:00:00Z"))
        #expect(
            picture(faces.entries[0])
                .looksLike(try await expected(source, rows: #"{"glasses": [{"daysAgo": 0, "repeat": 3}]}"#, at: late)))
        #expect(
            picture(faces.entries[1])
                .looksLike(
                    try await expected(source, rows: #"{"glasses": [{"daysAgo": 1, "repeat": 3}]}"#, at: midnight)))
        #expect(buttons(faces.entries[1]).allSatisfy { $0.tap.action != "undo" })
    }
}

/// `faces` never throws. A widget named "Widget" falls back to exactly the placeholder's calm face, so these
/// compare pixels with it.
@Suite struct FallbackTests {
    @Test @MainActor func aLookThatFailsOnLiveDataFallsBackToACalmFace() async throws {
        let scratch = Scratch()
        let look = counterLook(
            "{ type: 'text', value: ctx.data.n === 3 ? undefined.boom : String(ctx.data.n), color: '#FFFFFF' }")
        let id = try await scratch.build(document(name: "Widget", look: look))
        for _ in 0..<3 { try scratch.engine.perform(try button("add", on: await scratch.face(id)).tap, at: morning) }
        let face = await scratch.face(id)
        #expect(picture(face).looksLike(picture(.placeholder)))
        #expect(buttons(face).isEmpty)
    }

    @Test @MainActor func anUnknownWidgetFallsBackUntilMidnight() async throws {
        let faces = await Scratch().engine.faces(
            for: WidgetID(rawValue: "6d1f1d8e-0000-4000-8000-000000000000"), family: .small,
            size: Family.small.standardSize, from: morning)
        #expect(faces.entries.count == 1)
        #expect(faces.reloadAt == instant("2026-11-19T00:00:00Z"))
        #expect(picture(faces.current).looksLike(picture(.placeholder)))
    }

    @Test @MainActor func aStoreThatCannotOpenFallsBackAndRetriesSoon() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "not-a-directory-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = Engine(directory: file, calendar: utc)
        let faces = await engine.faces(for: nil, family: .small, size: Family.small.standardSize, from: morning)
        #expect(faces.reloadAt == morning.addingTimeInterval(15 * 60))
        #expect(picture(faces.current).looksLike(picture(.placeholder)))
        #expect(throws: EngineError.self) { try engine.perform(Tap(widget: "w", action: "a", row: nil)) }
    }
}
