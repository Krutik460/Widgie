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
        #expect(!(await scratch.face(id)).isFallback)
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
        #expect(chosen.hasButtons)

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

    @Test @MainActor func aTapWithoutARevisionOfThisLiveWidgetDoesNothing() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("water"))
        let todo = try await scratch.build(try fixture("todo"))
        let drink = try button("drink", on: await scratch.face(id)).tap
        let foreign = try button("add", on: await scratch.face(todo)).tap.revision
        let commits = scratch.commits

        for revision in [nil, "not a digest", foreign] {
            try scratch.engine.perform(
                Tap(widget: id.rawValue, revision: revision, action: "drink", row: nil), at: morning)
        }
        try scratch.engine.perform(
            Tap(widget: "not a widget", revision: drink.revision, action: "drink", row: nil), at: morning)
        try scratch.engine.perform(
            Tap(widget: id.rawValue, revision: drink.revision, action: "undo", row: "not a row"), at: morning)
        try scratch.engine.perform(
            Tap(widget: id.rawValue, revision: drink.revision, action: "sip", row: nil), at: morning)
        #expect(scratch.commits == commits)

        try scratch.engine.delete(id)
        try scratch.engine.perform(drink, at: morning)
        #expect(scratch.commits == commits + 1, "a deleted widget takes no taps")
    }
}

/// A tap runs the action as the revision it was drawn from defines it, so a refinement that lands between
/// the render and the press never changes what the press does.
@Suite struct TapRevisionTests {
    @Test @MainActor func aTapFromBeforeARefinementRunsTheEffectItWasDrawnWith() async throws {
        let scratch = Scratch()
        let before = document(look: counterLook())
        let id = try await scratch.build(before)
        let old = try button("add", on: await scratch.face(id)).tap
        let after = document(
            look: counterLook(
                "{ type: 'text', value: ctx.data.n + ' ' + ctx.data.m, size: 30, color: '#FFFFFF', lineLimit: 1, minScale: 0.5 }"
            ),
            tables: ["taps": ["fields": [:] as [String: Any]], "misses": ["fields": [:] as [String: Any]]],
            queries: ["n": ["count": "taps", "window": "all"], "m": ["count": "misses", "window": "all"]],
            actions: ["add": ["insert": "misses"]])
        _ = try await scratch.build(after, replacing: id)
        let new = try button("add", on: await scratch.face(id)).tap
        #expect(new.revision != old.revision)

        try scratch.engine.perform(old, at: morning)
        #expect(
            picture(await scratch.face(id))
                .looksLike(try await expected(after, rows: #"{"taps": [{"daysAgo": 0}]}"#)))
        try scratch.engine.perform(new, at: morning)
        #expect(
            picture(await scratch.face(id))
                .looksLike(try await expected(after, rows: #"{"taps": [{"daysAgo": 0}], "misses": [{"daysAgo": 0}]}"#)))
    }

    @Test @MainActor func aFormRefusesANumberThatIsNotFinite() async throws {
        let scratch = Scratch()
        let todo = String(decoding: try fixture("todo").json, as: UTF8.self)
        let counted = todo.replacing(#""title": "text","#, with: #""title": "text", "count": "number","#)
            .replacing(
                #"""
                "fields": [
                        "title"
                """#, with: #""fields": ["title", "count""#)
        #expect(counted.contains(#""count": "number""#) && counted.contains(#"["title", "count""#))
        let id = try await scratch.build(WidgetSource(json: Data(counted.utf8)))
        let form = try #require(try scratch.engine.form(for: try button("add", on: await scratch.face(id)).tap))

        for number in [Double.nan, .infinity, -.infinity] {
            #expect(throws: EngineError.self) {
                try scratch.engine.perform(form.tap, input: ["title": .text("Count"), "count": .number(number)])
            }
        }
        try scratch.engine.perform(form.tap, input: ["title": .text("Count"), "count": .number(3)], at: morning)
    }

    @Test @MainActor func aFormOpensAsTheRevisionItWasDrawnFromDefinesIt() async throws {
        let scratch = Scratch()
        let source = try fixture("todo")
        let id = try await scratch.build(source)
        let old = try button("add", on: await scratch.face(id)).tap
        let refined = WidgetSource(
            json: Data(
                String(decoding: source.json, as: UTF8.self).replacing("New to-do", with: "Another thing").utf8))
        _ = try await scratch.build(refined, replacing: id)

        let form = try #require(try scratch.engine.form(for: old))
        #expect(form.title == "New to-do" && form.tap == old)
        let current = try #require(try scratch.engine.form(for: try button("add", on: await scratch.face(id)).tap))
        #expect(current.title == "Another thing")
        #expect(try scratch.engine.form(for: Tap(widget: id.rawValue, revision: nil, action: "add", row: nil)) == nil)
    }
}

@Suite struct ClockTests {
    /// Dog fed shows how long ago the last feed was, so its picture changes within 15 minutes and the
    /// timeline gets quarter-hour entries for two hours, then reloads.
    @Test @MainActor func aLookThatShowsMinutesAgoGetsQuarterHourEntries() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("dogfed"))
        let fed = instant("2026-11-18T14:00:00Z")
        try scratch.engine.perform(try button("feed", on: await scratch.face(id, at: fed)).tap, at: fed)

        let from = instant("2026-11-18T14:10:00Z")
        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: from)
        let quarters = (0...8).map { from.addingTimeInterval(Double($0) * 15 * 60) }
        #expect(faces.entries.map(\.date) == quarters + [instant("2026-11-19T00:00:00Z")])
        #expect(faces.reloadAt == from.addingTimeInterval(2 * 3600))
    }

    /// A host showing one face draws it again when it may change: in 15 minutes for a look that reads the clock,
    /// at midnight for one that does not.
    @Test @MainActor func aSingleFaceSaysWhenItNextChanges() async throws {
        let scratch = Scratch()
        let dogfed = try await scratch.build(try fixture("dogfed"))
        let water = try await scratch.build(try fixture("water"))
        let fed = instant("2026-11-18T14:00:00Z")
        try scratch.engine.perform(try button("feed", on: await scratch.face(dogfed, at: fed)).tap, at: fed)

        let from = instant("2026-11-18T14:10:00Z")
        let size = Family.small.standardSize
        let clock = await scratch.engine.face(for: dogfed, family: .small, size: size, at: from)
        #expect(clock.entries.map(\.date) == [from])
        #expect(clock.reloadAt == from.addingTimeInterval(15 * 60))
        let late = instant("2026-11-18T23:50:00Z")
        #expect(
            await scratch.engine.face(for: dogfed, family: .small, size: size, at: late).reloadAt
                == instant("2026-11-19T00:00:00Z"))
        #expect(
            await scratch.engine.face(for: water, family: .small, size: size, at: from).reloadAt
                == instant("2026-11-19T00:00:00Z"))
    }

    @Test @MainActor func midnightCutsTheQuarterHoursShort() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("dogfed"))
        let late = instant("2026-11-18T23:20:00Z")
        try scratch.engine.perform(try button("feed", on: await scratch.face(id, at: late)).tap, at: late)

        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: late)
        #expect(
            faces.entries.map(\.date)
                == ["23:20", "23:35", "23:50"].map { instant("2026-11-18T\($0):00Z") }
                + [instant("2026-11-19T00:00:00Z")])
        #expect(faces.reloadAt == instant("2026-11-19T01:20:00Z"))
    }

    /// The case a single 15-minute probe missed: "10 h ago" reads the same for two hours, then turns into
    /// "Feed me!" at the 12th hour. Only the entry where the picture changes is kept.
    @Test @MainActor func aThresholdHoursAwayStillGetsItsEntry() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("dogfed"))
        let fed = instant("2026-11-18T08:00:00Z")
        try scratch.engine.perform(try button("feed", on: await scratch.face(id, at: fed)).tap, at: fed)

        let from = instant("2026-11-18T18:05:00Z")
        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: from)
        #expect(
            faces.entries.map(\.date)
                == ["18:05", "19:05", "20:05"].map { instant("2026-11-18T\($0):00Z") }
                + [instant("2026-11-19T00:00:00Z")],
            "10 h, 11 h, then Feed me!; the quarters in between draw the same and are dropped")
        #expect(faces.reloadAt == instant("2026-11-18T20:05:00Z"))
    }

    /// Proofs render at noon of the day, so the hour a proof runs cannot change its renders or verdict.
    @Test @MainActor func aProofGivesTheSameRendersAtAnyHour() async throws {
        let source = try fixture("hearts")
        let early = try await Engine.proofs(source, at: instant("2026-11-18T03:00:00Z"), calendar: utc)
        let late = try await Engine.proofs(source, at: instant("2026-11-18T21:30:00Z"), calendar: utc)
        #expect(early.verdict == nil && late.verdict == nil)
        #expect(early.renders.count == late.renders.count)
        for (a, b) in zip(early.renders, late.renders) {
            let pictures = try [a, b].map { try Bitmap(png: $0.outcome.get().png) }
            #expect(pictures[0].looksLike(pictures[1]), "\(a.state) \(a.family) \(a.appearance)")
        }
    }

    /// A look that greets the morning with text too long to fit passes at noon, so only the 00:01 render
    /// catches it, and its line names the time.
    @Test @MainActor func aMorningOnlySpillIsCaughtAtTheDaysFirstMinute() async throws {
        let greeting =
            "ctx.now < '12:00' ? { type: 'text', value: 'Good morning! ' + 'Have a wonderful day ahead. '.repeat(20), size: 20, color: '#FFFFFF' } : { type: 'text', value: 'Hi', size: 20, color: '#FFFFFF' }"
        let source = document(look: counterLook(greeting))
        let matrix = try await Engine.proofs(source, at: instant("2026-11-18T15:00:00Z"), calendar: utc)
        let verdict = try #require(matrix.verdict)
        #expect(verdict.hasPrefix("small, empty at 00:01: "), "\(verdict)")
        #expect(matrix.renders.contains { $0.state == "empty at 00:01" })
        #expect(!matrix.renders.contains { $0.state.hasSuffix("at 23:59") }, "passing day-edge renders are not listed")
    }

    /// Each quarter hour draws its own crop of a photo, 474 by 632 pixels in a small widget, so five faces fit
    /// the 1.5 megapixel budget and the sixth does not. The timeline ends before the sixth instead of showing a
    /// fallback, and the timeline WidgetKit asks for at that instant draws it.
    @Test @MainActor func aClockPhotoWhoseEntriesOutgrowTheImageBudgetEndsItsTimelineEarly() async throws {
        let scratch = Scratch()
        let crop =
            "{ type: 'image', asset: 'photo', crop: [((Number(ctx.now.slice(0, 2)) * 4 + Number(ctx.now.slice(3, 5)) / 15) % 8) * 0.05, 0, 0.5, 1], frame: { width: 40, height: 40 } },"
        let id = try await scratch.build(
            document(
                look: counterLook(extra: crop), assets: ["photo": ["about": "a sunset"]],
                images: ["photo": photo(1200, 800)]))

        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: morning)
        let cut = instant("2026-11-18T10:15:00Z")
        #expect(
            faces.entries.map(\.date)
                == ["09:00", "09:15", "09:30", "09:45", "10:00"].map { instant("2026-11-18T\($0):00Z") })
        #expect(faces.reloadAt == cut)
        for face in faces.entries {
            guard case .drawing = face.content else { throw Unexpected() }
        }
        guard case .drawing = await scratch.face(id, at: cut).content else { throw Unexpected() }
    }

    @Test @MainActor func aLookThatIgnoresTheClockGetsOnlyMidnight() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("habit"))
        let morning = instant("2026-11-18T09:00:00Z")
        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: morning)
        #expect(faces.entries.map(\.date) == [morning, instant("2026-11-19T00:00:00Z")])
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
        #expect(!face.hasButtons)
    }

    /// The image budget holds for the whole `faces` call, the same cap and the same line as the proof.
    @Test @MainActor func imagesPastTheBudgetOnLiveDataFallBack() async throws {
        let scratch = Scratch()
        let look = counterLook(extra: "...(ctx.data.n === 3 ? [\(croppedPhotos)] : []),")
        let id = try await scratch.build(
            document(
                name: "Widget", look: look, assets: ["photo": ["about": "a sunset"]],
                images: ["photo": photo(3000, 2000)]))
        for _ in 0..<3 { try scratch.engine.perform(try button("add", on: await scratch.face(id)).tap, at: morning) }
        let face = await scratch.face(id)
        #expect(picture(face).looksLike(picture(.placeholder)))
        #expect(face.isFallback)
        guard case .fallback(_, let reason) = face.content else { throw Unexpected() }
        #expect(reason.contains("images decode to more than 1.5 megapixels"), "\(reason)")
    }

    @Test @MainActor func anUnknownWidgetFallsBackUntilMidnight() async throws {
        let faces = await Scratch().engine.faces(
            for: WidgetID(rawValue: "6d1f1d8e-0000-4000-8000-000000000000"), family: .small,
            size: Family.small.standardSize, from: morning)
        #expect(faces.entries.count == 1)
        #expect(faces.reloadAt == instant("2026-11-19T00:00:00Z"))
        #expect(picture(faces.current).looksLike(picture(.placeholder)))
        #expect(faces.current.isFallback)
    }

    @Test @MainActor func aStoreThatCannotOpenFallsBackAndRetriesSoon() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "not-a-directory-\(UUID().uuidString)")
        try Data("x".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = Engine(directory: file, calendar: utc)
        let faces = await engine.faces(for: nil, family: .small, size: Family.small.standardSize, from: morning)
        #expect(faces.reloadAt == morning.addingTimeInterval(15 * 60))
        #expect(picture(faces.current).looksLike(picture(.placeholder)))
        #expect(throws: EngineError.self) { try engine.perform(Tap(widget: "w", revision: nil, action: "a", row: nil)) }
    }
}
