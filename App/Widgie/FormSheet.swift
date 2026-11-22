import SwiftUI
import WidgetEngine

/// The input a form button asks for. Starts from the row's current values when the form edits a row.
struct FormSheet: View {
    let form: InputForm
    let submit: ([String: InputValue]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: [String: String] = [:]
    @State private var toggles: [String: Bool] = [:]
    @State private var dates: [String: Date] = [:]
    @State private var invalid: Set<String> = []
    private let format = FormFormat()

    var body: some View {
        NavigationStack {
            Form {
                ForEach(form.fields) { field in
                    switch field.kind {
                    case .text:
                        TextField(field.label, text: binding(field.id, in: $text, default: ""))
                    case .number:
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(field.label, text: binding(field.id, in: $text, default: ""))
                                .keyboardType(.decimalPad)
                                .onChange(of: text[field.id]) { invalid.remove(field.id) }
                            if invalid.contains(field.id) {
                                Text("Enter a number, like \(format.text(12.5))")
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    case .toggle:
                        Toggle(field.label, isOn: binding(field.id, in: $toggles, default: false))
                    case .date:
                        DatePicker(
                            field.label, selection: binding(field.id, in: $dates, default: .now),
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
            .onAppear(perform: fill)
        }
    }

    /// Only fields the user can see a value for are sent, so an untouched empty field stays absent. A number
    /// field whose text is not a number keeps the form open and says so.
    private func save() {
        var input: [String: InputValue] = [:]
        var invalid: Set<String> = []
        for field in form.fields {
            switch field.kind {
            case .text:
                if let value = text[field.id], !value.isEmpty { input[field.id] = .text(value) }
            case .number:
                guard let value = text[field.id], !value.trimmingCharacters(in: .whitespaces).isEmpty else { break }
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
        self.invalid = invalid
        if invalid.isEmpty { submit(input) }
    }

    private func fill() {
        for field in form.fields {
            switch field.value {
            case .text(let value): text[field.id] = value
            case .number(let value): text[field.id] = format.text(value)
            case .toggle(let value): toggles[field.id] = value
            case .date(let year, let month, let day): dates[field.id] = format.date(year: year, month: month, day: day)
            case nil: break
            }
        }
    }

    private func binding<Value>(_ id: String, in values: Binding<[String: Value]>, default empty: Value)
        -> Binding<Value>
    {
        Binding(get: { values.wrappedValue[id] ?? empty }, set: { values.wrappedValue[id] = $0 })
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
