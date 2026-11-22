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
        #expect(FormFormat(locale: Locale(identifier: "en_US")).number("-∞") == nil)
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

    @Test func aNewFormSavesTheDateAndToggleItShows() throws {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = french.timeZone
        let now = try #require(paris.date(from: DateComponents(year: 2026, month: 11, day: 22, hour: 9)))
        let draft = FormDraft(
            fields: [
                InputField(id: "when", label: "When", kind: .date, value: nil),
                InputField(id: "done", label: "Done", kind: .toggle, value: nil),
            ], edits: false, format: french, now: now)

        let saved = draft.submission()
        #expect(saved.input == ["when": .date(year: 2026, month: 11, day: 22), "done": .toggle(false)])
        #expect(saved.invalid.isEmpty)
    }

    @Test func anUntouchedStoredNumberIsLeftOutAndAnEditedOneIsRead() {
        var draft = FormDraft(
            fields: [InputField(id: "amount", label: "Amount", kind: .number, value: .number(0.12345678901234566))],
            edits: true, format: french)
        #expect(draft.text["amount"] == "0,123456789012346")
        #expect(draft.submission().input.isEmpty)

        draft.text["amount"] = "2,5"
        #expect(draft.submission().input == ["amount": .number(2.5)])
    }

    /// A home-screen tap can write the row while its form is open, so Save must not send back what it showed.
    @Test func anEditFormSendsOnlyTheFieldsThePersonChanged() throws {
        var paris = Calendar(identifier: .gregorian)
        paris.timeZone = french.timeZone
        var draft = FormDraft(
            fields: [
                InputField(id: "title", label: "Title", kind: .text, value: .text("Oat milk")),
                InputField(id: "done", label: "Done", kind: .toggle, value: .toggle(false)),
                InputField(id: "due", label: "Due", kind: .date, value: .date(year: 2026, month: 11, day: 20)),
                InputField(id: "seen", label: "Seen", kind: .toggle, value: nil),
                InputField(id: "start", label: "Start", kind: .date, value: nil),
            ], edits: true, format: french)
        #expect(draft.submission().input.isEmpty)
        #expect(draft.submission().invalid.isEmpty)

        draft.toggles["done"] = true
        draft.dates["due"] = try #require(paris.date(from: DateComponents(year: 2026, month: 11, day: 24, hour: 15)))
        #expect(draft.submission().input == ["done": .toggle(true), "due": .date(year: 2026, month: 11, day: 24)])

        let today = Date.now
        draft.dates["start"] = today
        #expect(draft.submission().input["start"] == french.day(of: today))
    }

    @Test func emptyingAStoredTextOrNumberHoldsSaveBack() {
        var draft = FormDraft(
            fields: [
                InputField(id: "title", label: "Title", kind: .text, value: .text("Oat milk")),
                InputField(id: "amount", label: "Amount", kind: .number, value: .number(2.5)),
                InputField(id: "note", label: "Note", kind: .text, value: nil),
            ], edits: true, format: french)
        draft.text["title"] = ""
        draft.text["amount"] = " "
        draft.text["note"] = ""
        #expect(draft.submission().invalid == ["title": .empty, "amount": .empty])

        draft.text["title"] = "Bread"
        draft.text["amount"] = "3"
        #expect(draft.submission().invalid.isEmpty)
        #expect(draft.submission().input == ["title": .text("Bread"), "amount": .number(3)])
    }

    /// The engine counts UTF-16 units, where this emoji is 2, so half the limit in emoji fills a field.
    @Test func textOverTheEngineLimitHoldsSaveBack() {
        let fills = String(repeating: "🥛", count: InputField.textLimit / 2)
        var draft = FormDraft(
            fields: [InputField(id: "title", label: "Title", kind: .text, value: nil)], edits: false, format: french)
        draft.text["title"] = fills + "🥛"
        #expect(draft.submission().invalid == ["title": .tooLong])
        #expect(draft.submission().input.isEmpty)

        draft.text["title"] = fills
        #expect(draft.submission().invalid.isEmpty)
        #expect(draft.submission().input == ["title": .text(fills)])
    }
}
