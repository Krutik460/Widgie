import Foundation
import Testing
import WidgetEngine

@testable import Widgie

@Suite struct FormFormatTests {
    let french = FormFormat(locale: Locale(identifier: "fr_FR"), timeZone: TimeZone(identifier: "Europe/Paris")!)

    @Test func aFrenchDecimalIsShownAndReadWithAComma() {
        #expect(french.text(12.5) == "12,5")
        #expect(french.number("12,5") == 12.5)
        #expect(french.number(" -3,25 ") == -3.25)
        #expect(french.number(french.text(1234567.891)) == 1234567.891)
    }

    @Test func textThatIsNotWhollyANumberInTheLocaleIsRefused() {
        #expect(french.number("12.5") == nil)
        #expect(french.number("12abc") == nil)
        #expect(french.number("douze") == nil)
    }

    /// The picker shows the device's calendar, Buddhist here, but the engine counts Gregorian days.
    @Test func aBuddhistCalendarDateRoundTripsAsTheSameGregorianDay() throws {
        let bangkok = TimeZone(identifier: "Asia/Bangkok")!
        let format = FormFormat(locale: Locale(identifier: "th_TH@calendar=buddhist"), timeZone: bangkok)
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok

        let shown = try #require(format.date(year: 2026, month: 11, day: 22))
        let parts = buddhist.dateComponents([.year, .month, .day], from: shown)
        #expect([parts.year, parts.month, parts.day] == [2569, 11, 22])

        let picked = try #require(buddhist.date(from: DateComponents(year: 2569, month: 11, day: 22, hour: 23)))
        #expect(format.day(of: picked) == .date(year: 2026, month: 11, day: 22))
    }
}
