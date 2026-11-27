import Foundation
import Rows
import Testing
import WidgetBuilder
import WidgetEngine

/// The account's automation replica, as a page names it.
private let automations = "7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b"

/// What the server writes for one automation run, in the wire format of docs/engine/WIRE.md.
struct Run {
    let dataset: String
    let at: Date
    let written: Date
    var cells: [String: String] = [:]
    let key = Run.key()

    /// Ids from `first`: the row, then one change per cell.
    func changes(from first: Int) -> [[String: Any]] {
        let stamp = String(Int64(written.timeIntervalSince1970 * 1000) << 16)
        let insert: [String: Any] = [
            "op": "insertRow", "row": key, "dataset": dataset, "at": Int64(at.timeIntervalSince1970 * 1000),
            "day": Int(at.timeIntervalSince1970 / 86_400), "stamp": stamp, "replica": automations,
        ]
        let sets: [[String: Any]] = cells.sorted { $0.key < $1.key }.map { field, text in
            [
                "op": "setCell", "row": key, "dataset": dataset, "field": field, "kind": "text", "value": text,
                "stamp": stamp, "replica": automations,
            ]
        }
        return ([insert] + sets).enumerated().map { ["id": first + $0.offset, "change": $0.element] }
    }

    /// A UUIDv7 with random bits.
    static func key() -> String {
        let hex = Array(UUID().uuidString.lowercased().replacing("-", with: ""))
        let text = "0190" + String(hex[4..<12]) + "7" + String(hex[13..<16]) + "a" + String(hex[17..<32])
        let parts = [0..<8, 8..<12, 12..<16, 16..<20, 20..<32].map { range in
            String(Array(text)[range])
        }
        return parts.joined(separator: "-")
    }
}

/// A page of changes as the server returns it.
func page(_ changes: [[String: Any]], nextWrite: Date? = nil) throws -> RemotePage {
    let object: [String: Any] = [
        "replica": automations, "changes": changes,
        "nextWrite": nextWrite.map { Int64($0.timeIntervalSince1970 * 1000) } ?? NSNull(),
    ]
    return try RemotePage(json: JSONSerialization.data(withJSONObject: object))
}

/// The payload's automations, as JSON objects.
func entries(_ payload: AutomationPayload) throws -> [[String: Any]] {
    let object = try #require(try JSONSerialization.jsonObject(with: payload.json) as? [String: Any])
    return try #require(object["automations"] as? [[String: Any]])
}

/// The dataset the payload says an automation writes, as the server learns it.
func dataset(of widget: WidgetID, in engine: Engine) throws -> String {
    let entry = try #require(
        try entries(engine.automationPayload()).first { $0["widget"] as? String == widget.rawValue })
    return try #require(entry["dataset"] as? String)
}

/// Rows the server writes a period ahead stay hidden until their `at`, and the timeline draws them then, with no
/// reload and no network.
@Suite struct RevealTests {
    let word = ["word": "Petrichor", "kind": "noun", "definition": "The smell after rain.", "example": "Rain came."]

    @Test @MainActor func aWordWrittenAheadAppearsInTheEntryDatedAtItsRun() async throws {
        let scratch = Scratch()
        let source = try fixture("wotd")
        let id = try await scratch.build(source)
        let run = instant("2026-11-19T06:00:00Z")
        let written = Run(
            dataset: try dataset(of: id, in: scratch.engine), at: run, written: instant("2026-11-18T05:00:00Z"),
            cells: word)
        try scratch.engine.receive(try page(written.changes(from: 1)), at: morning)

        let evening = instant("2026-11-18T20:00:00Z")
        let faces = await scratch.engine.faces(
            for: id, family: .medium, size: Family.medium.standardSize, from: evening)
        #expect(faces.entries.map(\.date) == [evening, instant("2026-11-19T00:00:00Z"), run])
        #expect(faces.reloadAt == instant("2026-11-19T06:05:00Z"), "five minutes after the run, to pull the next")
        let none = try await expected(source, rows: "{}", .medium, at: evening)
        #expect(picture(faces.entries[0], .medium).looksLike(none))
        #expect(
            picture(faces.entries[1], .medium)
                .looksLike(try await expected(source, rows: "{}", .medium, at: faces.entries[1].date)),
            "midnight still shows no word")
        let shown = try await expected(
            source,
            rows:
                #"{"words": [{"daysAgo": 0, "word": "Petrichor", "kind": "noun", "definition": "The smell after rain.", "example": "Rain came."}]}"#,
            .medium, at: run)
        #expect(picture(faces.entries[2], .medium).looksLike(shown))
        #expect(!picture(faces.entries[2], .medium).looksLike(none))

        let early = instant("2026-11-19T05:00:00Z")
        let single = await scratch.engine.face(for: id, family: .medium, size: Family.medium.standardSize, at: early)
        #expect(single.reloadAt == run, "a single face is drawn again when the word appears")
        #expect(picture(single.current, .medium).looksLike(try await expected(source, rows: "{}", .medium, at: early)))
    }

    /// A row's `minutesAgo` counts from its `at`, so a row revealed at its time reads 0 minutes ago then, and is
    /// the person's own once the page named its replica: exactly what a feed the person tapped then shows.
    @Test @MainActor func aRevealedRowReadsJustNowAndAsThePersonsOwn() async throws {
        let scratch = Scratch()
        let source = try fixture("dogfed")
        let id = try await scratch.build(source)
        let pull = instant("2026-11-18T13:00:00Z")
        let fed = instant("2026-11-18T14:00:00Z")
        let feeds = try #require(try scratch.engine.store().bindings(of: .init(parsing: id.rawValue)!)["feeds"])
        try scratch.engine.receive(
            try page(Run(dataset: feeds.raw, at: fed, written: pull).changes(from: 1)), at: pull)

        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: pull)
        #expect(faces.entries.map(\.date).contains(fed))
        #expect(picture(faces.current).looksLike(try await expected(source, rows: "{}", at: pull)))
        let revealed = try #require(faces.entries.first { $0.date == fed })

        let tapped = Scratch()
        let other = try await tapped.build(source)
        try tapped.engine.perform(try button("feed", on: await tapped.face(other, at: fed)).tap, at: fed)
        #expect(picture(revealed).looksLike(picture(await tapped.face(other, at: fed))))
        #expect(!picture(revealed).looksLike(picture(faces.current)))
    }

    /// The dataset a table of a built widget is bound to, which the server writes for it.
    func bound(_ table: String, of id: WidgetID, in scratch: Scratch) throws -> String {
        let key = try #require(WidgetKey(parsing: id.rawValue))
        return try #require(try scratch.engine.store().bindings(of: key)[table]).raw
    }

    /// Two rows written ahead: the first gets its entry, and the timeline ends at the second, whose reload draws
    /// it. The midnight entry stays even past that end.
    @Test @MainActor func twoRevealsDrawTheFirstAndEndAtTheSecond() async throws {
        let scratch = Scratch()
        let source = try fixture("water")
        let id = try await scratch.build(source)
        let glasses = try bound("glasses", of: id, in: scratch)
        let first = instant("2026-11-18T14:00:00Z")
        let second = instant("2026-11-18T16:00:00Z")
        let written = instant("2026-11-18T08:00:00Z")
        let changes =
            Run(dataset: glasses, at: first, written: written).changes(from: 1)
            + Run(dataset: glasses, at: second, written: written).changes(from: 2)
        try scratch.engine.receive(try page(changes), at: morning)

        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: morning)
        #expect(faces.entries.map(\.date) == [morning, first, instant("2026-11-19T00:00:00Z")])
        #expect(faces.reloadAt == second)
        #expect(picture(faces.entries[0]).looksLike(try await expected(source, rows: "{}", at: morning)))
        #expect(
            picture(faces.entries[1])
                .looksLike(try await expected(source, rows: #"{"glasses": [{"daysAgo": 0}]}"#, at: first)))
    }

    /// A look that reads the clock steps every 15 minutes, but no step is drawn after the timeline's end, here
    /// the second reveal: the reload there draws it again.
    @Test @MainActor func noClockStepIsDrawnAfterTheTimelinesEnd() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("dogfed"))
        let fed = instant("2026-11-18T14:00:00Z")
        try scratch.engine.perform(try button("feed", on: await scratch.face(id, at: fed)).tap, at: fed)
        let feeds = try bound("feeds", of: id, in: scratch)
        let changes =
            Run(dataset: feeds, at: instant("2026-11-18T14:30:00Z"), written: fed).changes(from: 1)
            + Run(dataset: feeds, at: instant("2026-11-18T14:50:00Z"), written: fed).changes(from: 2)
        try scratch.engine.receive(try page(changes), at: fed)

        let from = instant("2026-11-18T14:10:00Z")
        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: from)
        #expect(
            faces.entries.map(\.date)
                == ["14:10", "14:25", "14:30", "14:40"].map { instant("2026-11-18T\($0):00Z") }
                + [instant("2026-11-19T00:00:00Z")],
            "the steps at 14:55 and later are past the second reveal")
        #expect(faces.reloadAt == instant("2026-11-18T14:50:00Z"))
    }

    /// The image budget covers the reveal too. A clock photo fits five faces, so a reveal that would be the
    /// sixth cuts the timeline at its instant, and the call WidgetKit makes then draws it with a fresh budget.
    @Test @MainActor func aRevealPastTheImageBudgetCutsTheTimelineAtItsInstant() async throws {
        let scratch = Scratch()
        let crop =
            "{ type: 'image', asset: 'photo', crop: [((Number(ctx.now.slice(0, 2)) * 4 + Number(ctx.now.slice(3, 5)) / 15) % 8) * 0.05, 0, 0.5, 1], frame: { width: 40, height: 40 } },"
        let source = document(
            look: counterLook(extra: crop), assets: ["photo": ["about": "a sunset"]],
            images: ["photo": photo(1200, 800)])
        let id = try await scratch.build(source)
        let reveal = instant("2026-11-18T10:10:00Z")
        try scratch.engine.receive(
            try page(
                Run(dataset: try bound("taps", of: id, in: scratch), at: reveal, written: morning).changes(from: 1)),
            at: morning)

        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: morning)
        #expect(
            faces.entries.map(\.date)
                == ["09:00", "09:15", "09:30", "09:45", "10:00"].map { instant("2026-11-18T\($0):00Z") })
        #expect(faces.reloadAt == reveal)
        let next = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: reveal)
        guard case .drawing = next.current.content else { throw Unexpected() }
        #expect(next.entries.first?.date == reveal)
    }

    /// A reveal at the same instant as a clock step replaces the step, and is kept even when nothing changed.
    @Test @MainActor func aRevealOnAClockStepIsOneEntryThatShowsTheRow() async throws {
        let scratch = Scratch()
        let source = try fixture("dogfed")
        let id = try await scratch.build(source)
        let fed = instant("2026-11-18T14:00:00Z")
        try scratch.engine.perform(try button("feed", on: await scratch.face(id, at: fed)).tap, at: fed)
        let step = instant("2026-11-18T14:40:00Z")
        try scratch.engine.receive(
            try page(Run(dataset: try bound("feeds", of: id, in: scratch), at: step, written: fed).changes(from: 1)),
            at: fed)

        let from = instant("2026-11-18T14:10:00Z")
        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: from)
        let quarters = (0...8).map { from.addingTimeInterval(Double($0) * 15 * 60) }
        #expect(faces.entries.map(\.date) == quarters + [instant("2026-11-19T00:00:00Z")])
        let revealed = try #require(faces.entries.first { $0.date == step })
        let tapped = Scratch()
        let other = try await tapped.build(source)
        try tapped.engine.perform(try button("feed", on: await tapped.face(other, at: step)).tap, at: step)
        #expect(picture(revealed).looksLike(picture(await tapped.face(other, at: step))), "fed just now")
    }

    /// A reveal at midnight is the midnight entry, which shows the row on its new day.
    @Test @MainActor func aRevealAtMidnightIsTheMidnightEntry() async throws {
        let scratch = Scratch()
        let source = try fixture("water")
        let id = try await scratch.build(source)
        let midnight = instant("2026-11-19T00:00:00Z")
        try scratch.engine.receive(
            try page(
                Run(dataset: try bound("glasses", of: id, in: scratch), at: midnight, written: morning).changes(
                    from: 1)),
            at: morning)

        let faces = await scratch.engine.faces(for: id, family: .small, size: Family.small.standardSize, from: morning)
        #expect(faces.entries.map(\.date) == [morning, midnight])
        #expect(faces.reloadAt == instant("2026-11-20T00:00:00Z"))
        #expect(
            picture(faces.entries[1])
                .looksLike(try await expected(source, rows: #"{"glasses": [{"daysAgo": 0}]}"#, at: midnight)))
    }
}

@Suite struct PullTests {
    @Test func aReplayedPageChangesNothingAndReloadsNothing() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("wotd"))
        let run = Run(
            dataset: try dataset(of: id, in: scratch.engine), at: instant("2026-11-19T06:00:00Z"),
            written: instant("2026-11-18T05:00:00Z"), cells: ["word": "Petrichor"])
        let commits = scratch.commits
        try scratch.engine.receive(try page(run.changes(from: 1)), at: morning)
        #expect(scratch.commits == commits + 1)
        #expect(try scratch.engine.watermark() == 2)

        try scratch.engine.receive(try page(run.changes(from: 1)), at: morning)
        try scratch.engine.receive(try page([]), at: morning)
        #expect(scratch.commits == commits + 1, "a replay, and an empty page from a known replica, reload nothing")
        #expect(try scratch.engine.watermark() == 2)
    }

    @Test func aChangeStampedTooFarAheadStopsThePageAndItsWatermark() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("wotd"))
        let dataset = try dataset(of: id, in: scratch.engine)
        let at = instant("2026-11-19T06:00:00Z")
        let soon = Run(dataset: dataset, at: at, written: morning, cells: ["word": "Soon"]).changes(from: 1)
        let ahead = Run(dataset: dataset, at: at, written: morning + 11 * 60, cells: ["word": "Ahead"])
            .changes(from: 3)
        try scratch.engine.receive(try page(soon + ahead), at: morning)
        #expect(try scratch.engine.watermark() == 2, "the held change and everything after it wait")

        try scratch.engine.receive(try page(soon + ahead), at: morning + 2 * 60)
        #expect(try scratch.engine.watermark() == 4)
    }

    /// The app and the extension each pull with their own engine on one store. A slower pull that returns an
    /// older page never moves the watermark back.
    @Test func theWatermarkNeverMovesBackwardsAcrossProcesses() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(try fixture("wotd"))
        let extensionEngine = Engine(directory: scratch.directory, calendar: utc)
        let run = Run(
            dataset: try dataset(of: id, in: scratch.engine), at: instant("2026-11-19T06:00:00Z"), written: morning,
            cells: ["word": "Petrichor"])
        try scratch.engine.receive(try page(run.changes(from: 7)), at: morning)
        try extensionEngine.receive(try page(run.changes(from: 3)), at: morning)
        #expect(try scratch.engine.watermark() == 8)
        #expect(try extensionEngine.watermark() == 8)
    }

    @Test func aPageThatDoesNotDecodeIsRefusedWhole() {
        #expect(throws: EngineError.self) { try RemotePage(json: Data("{}".utf8)) }
        #expect(throws: EngineError.self) {
            try page([["id": 1, "change": ["op": "moveHead"]]])
        }
    }
}

/// The body the app uploads with `PUT /v1/automations`, and the digest it compares with the server's.
@Suite struct PayloadTests {
    @Test func thePayloadNamesEachAutomationWithItsDatasetFieldsAndTheTimeZone() async throws {
        let scratch = Scratch()
        #expect(try entries(scratch.engine.automationPayload()).isEmpty)
        let id = try await scratch.build(try fixture("wotd"))
        _ = try await scratch.build(try fixture("water"))
        let payload = try scratch.engine.automationPayload()
        let object = try #require(try JSONSerialization.jsonObject(with: payload.json) as? [String: Any])
        #expect(object["timeZone"] as? String == utc.timeZone.identifier)
        let entry = try #require(try entries(payload).first)
        #expect(try entries(payload).count == 1, "the water logger has no automation")
        #expect(entry["widget"] as? String == id.rawValue)
        #expect(entry["automation"] as? String == "daily")
        #expect(entry["every"] as? String == "day" && entry["at"] as? String == "06:00" && entry["on"] == nil)
        #expect((entry["prompt"] as? String)?.hasPrefix("Pick an interesting, real English word") == true)
        #expect(
            entry["fields"] as? [String: String]
                == ["word": "text", "kind": "text", "definition": "text", "example": "text"])
        let stored = try scratch.engine.store().bindings(of: .init(parsing: id.rawValue)!)["words"]
        #expect(entry["dataset"] as? String == stored?.raw)
        #expect(payload.digest.count == 64)
        #expect(try scratch.engine.automationPayload() == payload, "the same account gives the same bytes")
    }

    @Test func theDigestFollowsSaveRestoreAndDelete() async throws {
        let scratch = Scratch()
        let empty = try scratch.engine.automationPayload().digest
        let id = try await scratch.build(try fixture("wotd"))
        let saved = try scratch.engine.automationPayload().digest
        #expect(saved != empty)

        _ = try await scratch.build(try refined("wotd"), replacing: id)
        let refinedDigest = try scratch.engine.automationPayload().digest
        #expect(refinedDigest != saved)

        try scratch.engine.restore(id, to: try scratch.engine.history(of: id)[1])
        #expect(try scratch.engine.automationPayload().digest == saved, "a restore brings the old prompt back")

        try scratch.engine.delete(id)
        #expect(try scratch.engine.automationPayload().digest == empty)
    }

    @Test func theDigestFollowsARollBack() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "payload-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let scratch = Engine.scratch(under: root, calendar: utc)
        guard case .saved(let id) = try await scratch.build(try fixture("wotd")) else { throw Unexpected() }
        let saved = try scratch.automationPayload().digest
        let checkpoint = try scratch.checkpoint(of: id)
        _ = try await scratch.build(try refined("wotd"), replacing: id)
        #expect(try scratch.automationPayload().digest != saved)
        try scratch.rollBack(to: checkpoint)
        #expect(try scratch.automationPayload().digest == saved)
    }

    /// Automations follow the phone's current time zone, so moving changes the payload and the app uploads it.
    @Test func theDigestFollowsTheTimeZone() async throws {
        let scratch = Scratch()
        _ = try await scratch.build(try fixture("wotd"))
        var tokyo = utc
        tokyo.timeZone = TimeZone(identifier: "Asia/Tokyo")!
        let moved = Engine(directory: scratch.directory, calendar: tokyo)
        #expect(try moved.automationPayload().digest != scratch.engine.automationPayload().digest)
        #expect(String(decoding: try moved.automationPayload().json, as: UTF8.self).contains(#""Asia/Tokyo""#))
    }

    /// The fixture with another prompt.
    func refined(_ name: String) throws -> WidgetSource {
        let source = try fixture(name)
        return WidgetSource(
            json: Data(
                String(decoding: source.json, as: UTF8.self).replacing(
                    "Pick an interesting", with: "Pick a nursing exam term, an interesting"
                ).utf8))
    }
}
