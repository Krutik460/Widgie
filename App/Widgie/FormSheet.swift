import SwiftUI
import WidgetEngine

/// The input a form button asks for. Starts from the row's current values when the form edits a row.
struct FormSheet: View {
    let form: InputForm
    let submit: ([String: InputValue]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: FormDraft
    @State private var invalid: Set<String> = []

    init(form: InputForm, submit: @escaping ([String: InputValue]) -> Void) {
        self.form = form
        self.submit = submit
        _draft = State(initialValue: FormDraft(fields: form.fields))
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(form.fields) { field in
                    switch field.kind {
                    case .text:
                        TextField(field.label, text: binding(field.id, in: $draft.text, default: ""))
                    case .number:
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(field.label, text: binding(field.id, in: $draft.text, default: ""))
                                .keyboardType(.decimalPad)
                                .onChange(of: draft.text[field.id]) { invalid.remove(field.id) }
                            if invalid.contains(field.id) {
                                Text("Enter a number, like \(draft.format.text(12.5))")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    case .toggle:
                        Toggle(field.label, isOn: binding(field.id, in: $draft.toggles, default: false))
                    case .date:
                        DatePicker(
                            field.label, selection: binding(field.id, in: $draft.dates, default: .now),
                            displayedComponents: .date)
                    }
                }
            }
            .navigationTitle(form.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    /// A number field whose text is not a number keeps the form open and says so.
    private func save() {
        let submission = draft.submission()
        invalid = submission.invalid
        if invalid.isEmpty { submit(submission.input) }
    }

    private func binding<Value>(_ id: String, in values: Binding<[String: Value]>, default empty: Value)
        -> Binding<Value>
    {
        Binding(get: { values.wrappedValue[id] ?? empty }, set: { values.wrappedValue[id] = $0 })
    }
}

/// What the form shows, which is what Save submits. It starts from the row's values when the form edits a
/// row; otherwise a toggle shows off and a date shows today, and both are sent as shown. An empty text or
/// number field stays absent. A stored number is sent only once its text is edited, because the text shows it
/// rounded to 15 significant digits and reading that back would rewrite the stored value.
struct FormDraft {
    let fields: [InputField]
    let format: FormFormat
    var text: [String: String] = [:]
    var toggles: [String: Bool] = [:]
    var dates: [String: Date] = [:]

    init(fields: [InputField], format: FormFormat = FormFormat(), now: Date = .now) {
        self.fields = fields
        self.format = format
        for field in fields {
            switch (field.kind, field.value) {
            case (_, .text(let value)?): text[field.id] = value
            case (_, .number(let value)?): text[field.id] = format.text(value)
            case (_, .toggle(let value)?): toggles[field.id] = value
            case (_, .date(let year, let month, let day)?):
                dates[field.id] = format.date(year: year, month: month, day: day) ?? now
            case (.toggle, nil): toggles[field.id] = false
            case (.date, nil): dates[field.id] = now
            case (.text, nil), (.number, nil): break
            }
        }
    }

    /// The input to submit, and the number fields whose text is not a number, which hold the submit back.
    func submission() -> (input: [String: InputValue], invalid: Set<String>) {
        var input: [String: InputValue] = [:]
        var invalid: Set<String> = []
        for field in fields {
            switch field.kind {
            case .text:
                if let value = text[field.id], !value.isEmpty { input[field.id] = .text(value) }
            case .number:
                guard let value = text[field.id], !value.trimmingCharacters(in: .whitespaces).isEmpty else { break }
                if case .number(let stored) = field.value, value == format.text(stored) { break }
                if let number = format.number(value) {
                    input[field.id] = .number(number)
                } else {
                    invalid.insert(field.id)
                }
            case .toggle:
                if let value = toggles[field.id] { input[field.id] = .toggle(value) }
            case .date:
                if let value = dates[field.id] { input[field.id] = format.day(of: value) }
            }
        }
        return (input, invalid)
    }
}

/// How the form shows and reads values. A number uses one formatter in the person's locale both ways, so
/// "12,5" in France reads back as 12.5. A date is a Gregorian day in the person's time zone, the days the engine
/// counts, whatever calendar the picker shows.
struct FormFormat {
    var locale: Locale = .autoupdatingCurrent
    var timeZone: TimeZone = .autoupdatingCurrent

    func text(_ number: Double) -> String { numbers.string(from: number as NSNumber) ?? "" }

    /// Nil unless the whole text, spaces aside, is a number in the locale.
    func number(_ text: String) -> Double? { numbers.number(from: text)?.doubleValue }

    func date(year: Int, month: Int, day: Int) -> Date? {
        days.date(from: DateComponents(year: year, month: month, day: day))
    }

    func day(of date: Date) -> InputValue {
        let parts = days.dateComponents([.year, .month, .day], from: date)
        return .date(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
    }

    private var numbers: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        formatter.usesGroupingSeparator = false
        formatter.usesSignificantDigits = true
        formatter.maximumSignificantDigits = 15
        return formatter
    }

    private var days: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }
}
