import Foundation
import Testing
import WidgetBuilder
import WidgetEngine

/// A water logger in millilitres: a per-day sum chart whose bars log a glass on their own day, a goal streak,
/// and monthly and rolling totals. Built, tapped, and compared with proofs, like the reference widgets.
@Suite struct DayTrackingTests {
    static let source = document(
        name: "Hydration",
        look: """
            function render(ctx) {
              const d = ctx.data;
              const bars = d.week.map(day => ({ type: 'button', action: 'late', day: day.date, children: [
                { type: 'capsule', fill: day.sum >= 2000 ? '#7AE582' : '#4FC3F7',
                  frame: { width: 12, height: 6 + 40 * Math.min(day.sum, 2000) / 2000 } } ] }));
              return { type: 'vstack', spacing: 6, padding: 12, frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
                widgetBackground: '#0B2A3C',
                children: [
                  { type: 'text', value: d.today + ' ml', size: 22, weight: 'bold', color: '#FFFFFF', lineLimit: 1,
                    minScale: 0.4 },
                  { type: 'text', value: d.streak + ' days · ' + d.month + ' month · ' + d.last7 + ' week', size: 10,
                    color: '#9BC7DD', lineLimit: 1, minScale: 0.4 },
                  { type: 'hstack', align: 'bottom', spacing: 6, children: bars },
                  { type: 'button', action: 'sip', children: [
                    { type: 'symbol', name: 'plus', size: 16, color: '#08304A', frame: { width: 32, height: 32 },
                      background: '#4FC3F7', clip: 'circle' } ] },
                ] };
            }
            """,
        tables: ["drinks": ["fields": ["ml": "number"]]],
        queries: [
            "today": ["sum": "drinks.ml", "window": "today"],
            "week": ["daily": "drinks.ml", "days": 7],
            "streak": ["streak": "drinks.ml", "goal": 2000],
            "month": ["sum": "drinks.ml", "window": "month"],
            "last7": ["sum": "drinks.ml", "window": ["days": 7]],
        ],
        actions: [
            "sip": ["insert": "drinks", "values": ["ml": 250]],
            "late": ["insertOn": "drinks", "values": ["ml": 250]],
        ],
        samples: [
            "light": ["drinks": [["ml": 250, "repeat": 3]]],
            "kept": ["drinks": [["ml": 250, "repeat": 8], ["daysAgo": 1, "ml": 500, "repeat": 4]]],
        ])

    @Test @MainActor func aBarLogsOnItsOwnDayAndTheGoalStreakCountsIt() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(Self.source)
        let late = buttons(await scratch.face(id)).filter { $0.tap.action == "late" }
        #expect(late.map(\.tap.day) == (12...18).map { "2026-11-\($0)" }, "one bar per day, oldest first")
        let yesterday = try #require(late.first { $0.tap.day == "2026-11-17" }).tap

        for _ in 0..<8 { try scratch.engine.perform(yesterday, at: morning) }
        #expect(
            picture(await scratch.face(id))
                .looksLike(
                    try await expected(Self.source, rows: #"{"drinks": [{"daysAgo": 1, "ml": 250, "repeat": 8}]}"#)))

        for _ in 0..<8 { try scratch.engine.perform(try button("sip", on: await scratch.face(id)).tap, at: morning) }
        let both = #"{"drinks": [{"daysAgo": 1, "ml": 250, "repeat": 8}, {"ml": 250, "repeat": 8}]}"#
        #expect(picture(await scratch.face(id)).looksLike(try await expected(Self.source, rows: both)))
        #expect(
            !picture(await scratch.face(id))
                .looksLike(
                    try await expected(Self.source, rows: #"{"drinks": [{"daysAgo": 1, "ml": 250, "repeat": 8}]}"#)))
    }

    @Test @MainActor func aTapForADayOutsideTheLastYearOrInTheFutureWritesNothing() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(Self.source)
        let revision = try scratch.engine.history(of: id).first?.id
        let commits = scratch.commits
        for day in ["2026-11-19", "2025-11-17", "yesterday", "2026-02-30"] {
            try scratch.engine.perform(
                Tap(widget: id.rawValue, revision: revision, action: "late", row: nil, day: day), at: morning)
        }
        try scratch.engine.perform(Tap(widget: id.rawValue, revision: revision, action: "late", row: nil), at: morning)
        #expect(scratch.commits == commits)

        try scratch.engine.perform(
            Tap(widget: id.rawValue, revision: revision, action: "late", row: nil, day: "2025-11-18"), at: morning)
        #expect(scratch.commits == commits + 1, "365 days back is the oldest day a tap may log")
    }

    @Test @MainActor func aBarRenderedBeforeMidnightStillLogsItsOwnDayAfter() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(Self.source)
        let lateEvening = instant("2026-11-18T23:59:00Z")
        let today = try #require(
            buttons(await scratch.face(id, at: lateEvening)).first { $0.tap.day == "2026-11-18" }
        ).tap
        try scratch.engine.perform(today, at: instant("2026-11-19T00:01:00Z"))
        let nextMorning = instant("2026-11-19T09:00:00Z")
        #expect(
            picture(await scratch.face(id, at: nextMorning))
                .looksLike(
                    try await expected(
                        Self.source, rows: #"{"drinks": [{"daysAgo": 1, "ml": 250}]}"#, at: nextMorning)))
    }
}
