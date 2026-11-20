import Foundation
import Spec
import Testing

@Suite struct FixtureTests {
    @Test func fixturesFolderHoldsTheFourReferenceWidgets() throws {
        let names = try FileManager.default.contentsOfDirectory(
            atPath: engineDirectory.appending(path: "Fixtures").path
        )
        .filter { !$0.hasPrefix(".") }
        #expect(names.sorted() == referenceWidgets)
    }

    @Test(arguments: referenceWidgets)
    func parsesAndRoundTripsThroughCanonicalBytes(_ name: String) throws {
        let spec = try Spec.parse(fixture(name))
        let canonical = spec.encoded()
        let reparsed = try Spec.parse(canonical)
        #expect(reparsed == spec)
        #expect(reparsed.encoded() == canonical)
    }

    @Test(arguments: referenceWidgets)
    func hasAtLeastTwoSamplesAndALook(_ name: String) throws {
        let spec = try Spec.parse(fixture(name))
        #expect(spec.samples.count >= 2)
        #expect(spec.look.contains("function render(ctx)"))
    }

    @Test func waterCountsTodayAndReadsHistoryFromDaily() throws {
        let spec = try Spec.parse(fixture("water"))
        guard case .count(let table, nil, .today)? = spec.query("today")?.shape else {
            Issue.record("today is not an unfiltered count over today")
            return
        }
        #expect(table.id.raw == "glasses")
        #expect(table.fields.isEmpty)
        guard case .daily(.rows, nil, 7)? = spec.query("week")?.shape else {
            Issue.record("week is not daily over 7 days")
            return
        }
        guard case .latest(_, nil, .today)? = spec.query("last")?.shape else {
            Issue.record("last is not the newest row today")
            return
        }
        #expect(spec.action(named: "drink")?.effect.rowUse == .never)
        #expect(spec.action(named: "undo")?.effect.rowUse == .required)
        let morning = try #require(spec.sample(named: "morning"))
        #expect(morning.rows.first?.daysAgo == 0)
        #expect(morning.rows.first?.count == 2)
    }

    @Test func todoSplitsOpenAndDoneWithWhere() throws {
        let spec = try Spec.parse(fixture("todo"))
        guard case .list(_, let open?, .oldest, 20, .all)? = spec.query("open")?.shape else {
            Issue.record("open is not a filtered list of 20, oldest first")
            return
        }
        #expect(open.field.path == "items.done")
        #expect(open.value == .bool(false))
        guard case .count(_, let finished?, .all)? = spec.query("finished")?.shape else {
            Issue.record("finished is not a filtered count")
            return
        }
        #expect(finished.value == .bool(true))
        guard case .toggle(let done)? = spec.action(named: "toggle")?.effect else {
            Issue.record("toggle is not a toggle")
            return
        }
        #expect(done.path == "items.done")
        guard case .form(let form)? = spec.action(named: "add")?.effect else {
            Issue.record("add is not a form")
            return
        }
        #expect(form.fields.map(\.path) == ["items.title"])
        #expect(form.prompt == "New to-do")
        #expect(spec.action(named: "add")?.effect.rowUse == .optional)
    }

    @Test func habitHasAStreakAndFiveWeeksOfDays() throws {
        let spec = try Spec.parse(fixture("habit"))
        guard case .streak(.rows(let table), nil, 1)? = spec.query("streak")?.shape else {
            Issue.record("streak is not a streak of any row")
            return
        }
        #expect(table.id.raw == "checkins")
        guard case .daily(.rows, nil, 35)? = spec.query("days")?.shape else {
            Issue.record("days is not daily over 35 days")
            return
        }
    }

    @Test func wordOfTheDayIsWrittenByADailyAutomation() throws {
        let spec = try Spec.parse(fixture("wotd"))
        #expect(spec.actions.isEmpty)
        let automation = try #require(spec.automations.first)
        #expect(automation.schedule.cadence == .daily(hour: 6, minute: 0))
        #expect(automation.schedule.timeZone == nil)
        #expect(automation.writes.fields.map(\.id.raw) == ["definition", "example", "kind", "word"])
    }
}
