import Foundation
import Spec
import Testing

private func calendar(_ zone: String, firstWeekday: Int = 2, identifier: Calendar.Identifier = .gregorian) throws
    -> Calendar
{
    var calendar = Calendar(identifier: identifier)
    calendar.timeZone = try #require(TimeZone(identifier: zone))
    calendar.firstWeekday = firstWeekday
    return calendar
}

@Suite struct DayTests {
    @Test func springForwardDayIsTwentyThreeHoursLong() throws {
        let newYork = try calendar("America/New_York")
        let earlyMorning = Today(at: try instant("2026-03-08T05:30:00Z"), calendar: newYork)
        let noon = Today(at: try instant("2026-03-08T16:00:00Z"), calendar: newYork)
        #expect(earlyMorning.day.iso == "2026-03-08")
        #expect(noon.day == earlyMorning.day)
        #expect(noon.nextDayStart == (try instant("2026-03-09T04:00:00Z")))
        #expect(earlyMorning.nextDayStart.timeIntervalSince(try instant("2026-03-08T05:00:00Z")) == 23 * 3600)
    }

    @Test func fallBackDayIsTwentyFiveHoursLong() throws {
        let newYork = try calendar("America/New_York")
        let today = Today(at: try instant("2026-11-01T17:00:00Z"), calendar: newYork)
        #expect(today.day.iso == "2026-11-01")
        #expect(today.nextDayStart == (try instant("2026-11-02T05:00:00Z")))
        #expect(today.nextDayStart.timeIntervalSince(try instant("2026-11-01T04:00:00Z")) == 25 * 3600)
    }

    @Test func halfAnHourBeforeMidnightIsStillTheOldDay() throws {
        let today = Today(at: try instant("2026-03-08T04:30:00Z"), calendar: try calendar("America/New_York"))
        #expect(today.day.iso == "2026-03-07")
        #expect(today.nextDayStart == (try instant("2026-03-08T05:00:00Z")))
    }

    @Test func oneInstantIsTwoDaysAcrossTheYearBoundary() throws {
        let moment = try instant("2026-12-31T23:30:00Z")
        let utc = Today(at: moment, calendar: try calendar("UTC"))
        let auckland = Today(at: moment, calendar: try calendar("Pacific/Auckland"))
        #expect(utc.day.iso == "2026-12-31")
        #expect(utc.nextDayStart == (try instant("2027-01-01T00:00:00Z")))
        #expect(auckland.day.iso == "2027-01-01")
        #expect(auckland.day == utc.day.adding(1))
    }

    @Test func weekStartsOnTheCalendarsFirstWeekday() throws {
        let newYearsDay = try instant("2027-01-01T12:00:00Z")
        let monday = Today(at: newYearsDay, calendar: try calendar("UTC", firstWeekday: 2))
        let sunday = Today(at: newYearsDay, calendar: try calendar("UTC", firstWeekday: 1))
        #expect(monday.day.weekday == .friday)
        #expect(monday.weekStart.iso == "2026-12-28")
        #expect(
            monday.week.map(\.iso) == [
                "2026-12-28", "2026-12-29", "2026-12-30", "2026-12-31", "2027-01-01", "2027-01-02", "2027-01-03",
            ])
        #expect(sunday.weekStart.iso == "2026-12-27")
        #expect(sunday.week.map(\.iso).last == "2027-01-02")
    }

    @Test func todayIsItsOwnWeekStartOnTheFirstWeekday() throws {
        let sundayFirst = Today(at: try instant("2026-11-15T12:00:00Z"), calendar: try calendar("UTC", firstWeekday: 1))
        let mondayFirst = Today(at: try instant("2026-11-15T12:00:00Z"), calendar: try calendar("UTC", firstWeekday: 2))
        #expect(sundayFirst.day.weekday == .sunday)
        #expect(sundayFirst.weekStart == sundayFirst.day)
        #expect(mondayFirst.weekStart.iso == "2026-11-09")
    }

    @Test func anotherCalendarSystemGetsTheSameDays() throws {
        let moment = try instant("2026-11-18T09:00:00Z")
        let buddhist = Today(at: moment, calendar: try calendar("Asia/Bangkok", identifier: .buddhist))
        let gregorian = Today(at: moment, calendar: try calendar("Asia/Bangkok"))
        #expect(buddhist == gregorian)
        #expect(buddhist.day.iso == "2026-11-18")
    }

    @Test func isoDatesRoundTripAndRejectDaysThatDoNotExist() throws {
        for iso in ["1970-01-01", "2026-11-18", "2028-02-29", "2000-02-29", "1969-12-31", "9999-12-31"] {
            #expect(Day(iso: iso)?.iso == iso)
        }
        for text in [
            "2027-02-29", "1900-02-29", "2026-13-01", "2026-11-31", "2026-1-5", "26-11-18", "2026/11/18", "today",
        ] {
            #expect(Day(iso: text) == nil, "\(text)")
        }
        #expect(Day(iso: "1970-01-01")?.index == 0)
        #expect(Day(iso: "2026-12-31")?.adding(1).iso == "2027-01-01")
        #expect(Day(iso: "2028-03-01")?.adding(-1).iso == "2028-02-29")
    }

    @Test func weekdaysHaveTheirNames() throws {
        let wednesday = try #require(Day(iso: "2026-11-18")).weekday
        #expect(wednesday == .wednesday)
        #expect(wednesday.short == "Wed")
        #expect(wednesday.name == "wednesday")
        #expect(Day(index: 0).weekday == .thursday)
        #expect(Day(iso: "1969-12-29")?.weekday == .monday)
    }
}
