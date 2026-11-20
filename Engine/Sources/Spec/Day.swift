import Foundation

/// A calendar day, as the number of days since 1970-01-01 in the proleptic Gregorian calendar. Time zones
/// are gone once a `Day` exists, so day windows are integer ranges and weekdays are arithmetic.
package struct Day: Hashable, Comparable, Sendable, CustomStringConvertible {
    package let index: Int

    package init(index: Int) {
        self.index = index
    }

    /// Parses `YYYY-MM-DD`. Nil for any other text, including a date that does not exist.
    package init?(iso: String) {
        let parts = iso.split(separator: "-", omittingEmptySubsequences: false)
        guard iso.utf8.count == 10, parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2,
            parts.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
            let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
            year >= 1, (1...12).contains(month), (1...Self.length(of: month, in: year)).contains(day)
        else { return nil }
        self.init(year: year, month: month, day: day)
    }

    init(year: Int, month: Int, day: Int) {
        let shifted = month <= 2 ? year - 1 : year
        let era = (shifted >= 0 ? shifted : shifted - 399) / 400
        let yearOfEra = shifted - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        index = era * 146_097 + dayOfEra - 719_468
    }

    package var iso: String {
        let (year, month, day) = parts
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// The first and last day of the calendar month that contains this day.
    package var month: ClosedRange<Day> {
        let (year, month, day) = parts
        let first = adding(1 - day)
        return first...first.adding(Self.length(of: month, in: year) - 1)
    }

    private var parts: (year: Int, month: Int, day: Int) {
        let shifted = index + 719_468
        let era = (shifted >= 0 ? shifted : shifted - 146_096) / 146_097
        let dayOfEra = shifted - era * 146_097
        let yearOfEra = (dayOfEra - dayOfEra / 1460 + dayOfEra / 36524 - dayOfEra / 146_096) / 365
        let dayOfYear = dayOfEra - (365 * yearOfEra + yearOfEra / 4 - yearOfEra / 100)
        let monthIndex = (5 * dayOfYear + 2) / 153
        let day = dayOfYear - (153 * monthIndex + 2) / 5 + 1
        let month = monthIndex < 10 ? monthIndex + 3 : monthIndex - 9
        return (yearOfEra + era * 400 + (month <= 2 ? 1 : 0), month, day)
    }

    /// 1970-01-01 was a Thursday.
    package var weekday: Weekday {
        Weekday(rawValue: ((index % 7) + 7 + 3) % 7 + 1) ?? .monday
    }

    package func adding(_ days: Int) -> Day {
        Day(index: index + days)
    }

    package static func < (a: Day, b: Day) -> Bool { a.index < b.index }

    package var description: String { iso }

    private static func length(of month: Int, in year: Int) -> Int {
        switch month {
        case 2: year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }
}

/// ISO numbering: Monday is 1 and Sunday is 7.
package enum Weekday: Int, CaseIterable, Sendable {
    case monday = 1
    case tuesday
    case wednesday
    case thursday
    case friday
    case saturday
    case sunday

    /// The lowercase English name, as an automation's `on` key writes it: `monday`.
    package var name: String { String(describing: self) }

    /// The three-letter English name a look receives: `Mon`.
    package var short: String { name.prefix(1).uppercased() + name.dropFirst().prefix(2) }

    /// Foundation's numbering, where Sunday is 1.
    var calendarNumber: Int { rawValue % 7 + 1 }
}

/// Everything time-dependent about one render or one tap, computed once from an instant and a calendar.
/// Queries and the look context read this and never a clock.
package struct Today: Sendable, Equatable {
    package let day: Day
    /// The first day of the week that contains `day`, by the calendar's first weekday.
    package let weekStart: Day
    /// The instant the next day begins in the calendar's time zone. The calendar computes it, so a day
    /// that daylight saving shortens or lengthens ends at its real midnight.
    package let nextDayStart: Date

    /// Uses a Gregorian calendar with `calendar`'s time zone and first weekday, so a user on another
    /// calendar system still gets the same days as everyone else.
    package init(at instant: Date, calendar: Calendar) {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.firstWeekday = calendar.firstWeekday
        let parts = gregorian.dateComponents([.year, .month, .day], from: instant)
        day = Day(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
        weekStart = day.adding(-((day.weekday.calendarNumber - gregorian.firstWeekday + 7) % 7))
        nextDayStart =
            gregorian.dateInterval(of: .day, for: instant)?.end
            ?? gregorian.startOfDay(for: instant).addingTimeInterval(86_400)
    }

    package var week: [Day] { (0..<7).map { weekStart.adding($0) } }
}
