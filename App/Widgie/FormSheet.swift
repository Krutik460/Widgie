import SwiftUI
import WidgetEngine

/// One showing of a form. Each gets its own id, so the sheet starts over with fresh values whenever a form
/// link opens, even while a sheet is up or for the same form again.
struct ShownForm: Identifiable {
    let id = UUID()
    let form: InputForm
}

extension View {
    /// Shows the forms `preview`'s face opens, and performs the tap with what the person entered.
    func previewForms(_ preview: Preview) -> some View {
        sheet(item: Bindable(preview).form) { shown in
            FormSheet(form: shown.form) { input in
                preview.perform(shown.form.tap, input: input)
                preview.form = nil
            }
        }
    }
}

/// The input a form button asks for. Starts from the row's current values when the form edits a row.
struct FormSheet: View {
    let form: InputForm
    let submit: ([String: InputValue]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: FormDraft
    @State private var invalid: [String: FormDraft.Problem] = [:]

    init(form: InputForm, submit: @escaping ([String: InputValue]) -> Void) {
        self.form = form
        self.submit = submit
        _draft = State(initialValue: FormDraft(fields: form.fields, edits: form.tap.row != nil))
    }

    var body: some View {
        NavigationStack {
            Form {
                ForEach(form.fields) { field in
                    switch field.kind {
                    case .text, .number:
                        VStack(alignment: .leading, spacing: 4) {
                            TextField(field.label, text: binding(field.id, in: $draft.text, default: ""))
                                .keyboardType(field.kind == .number ? .decimalPad : .default)
                                .accessibilityLabel(field.label)
                                .onChange(of: draft.text[field.id]) { invalid[field.id] = nil }
                            if let problem = invalid[field.id] {
                                Text(hint(problem))
                                    .font(.footnote)
                                    .foregroundStyle(.red)
                            }
                        }
                    case .toggle:
                        Toggle(field.label, isOn: binding(field.id, in: $draft.toggles, default: false))
                    case .date:
                        if draft.dates[field.id] != nil {
                            DatePicker(
                                field.label, selection: binding(field.id, in: $draft.dates, default: .now),
                                displayedComponents: .date)
                        } else {
                            // Only an edit form's date the row lacks: show it unset rather than a today it would
                            // not save.
                            LabeledContent(field.label) {
                                Button("Set") { draft.dates[field.id] = .now }
                            }
                        }
                    }
                }
            }
            .navigationTitle(form.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                // A form's prompt is a question that runs longer than a bar's title fits, so it wraps.
                ToolbarItem(placement: .principal) {
                    Text(form.title)
                        .font(.headline)
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                }
            }
        }
    }

    /// A field that cannot be sent as it stands keeps the form open and says why.
    private func save() {
        let submission = draft.submission()
        invalid = submission.invalid
        if invalid.isEmpty { submit(submission.input) }
    }

    private func hint(_ problem: FormDraft.Problem) -> String {
        switch problem {
        case .empty: "Can’t be empty"
        case .notANumber: "Enter a number, like \(draft.format.text(12.5))"
        case .tooLong: "Keep it to \(InputField.textLimit) characters or fewer"
        }
    }

    private func binding<Value>(_ id: String, in values: Binding<[String: Value]>, default empty: Value)
        -> Binding<Value>
    {
        Binding(get: { values.wrappedValue[id] ?? empty }, set: { values.wrappedValue[id] = $0 })
    }
}

/// What the form shows, which is what Save submits. It starts from the row's values when the form edits a
/// row; otherwise a toggle shows off and a date shows today. A new form sends every field it shows a value
/// for, and an empty text or number field stays absent. An edit form sends only the fields the person
/// changed, so an untouched field never undoes a newer write made elsewhere while the form was open, and a
/// stored number, which the text shows rounded to 15 significant digits, is never rewritten by reading it back.
/// Emptying a stored text or number holds Save back, because an input value cannot clear a cell.
struct FormDraft {
    /// Why a field holds Save back.
    enum Problem: Equatable {
        case empty
        case notANumber
        case tooLong
    }

    let fields: [InputField]
    let format: FormFormat
    var text: [String: String] = [:]
    var toggles: [String: Bool] = [:]
    var dates: [String: Date] = [:]
    /// What each field read when an edit form opened; nil for a new form.
    private var opened: [String: Reading]?

    init(fields: [InputField], edits: Bool, format: FormFormat = FormFormat(), now: Date = .now) {
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
            // An edit form leaves a date the row lacks unset until the person picks one, so editing another
            // field never fills it with today.
            case (.date, nil): if !edits { dates[field.id] = now }
            case (.text, nil), (.number, nil): break
            }
        }
        if edits { opened = Dictionary(uniqueKeysWithValues: fields.map { ($0.id, reading(of: $0)) }) }
    }

    /// The input to submit, and the fields that hold it back.
    func submission() -> (input: [String: InputValue], invalid: [String: Problem]) {
        var input: [String: InputValue] = [:]
        var invalid: [String: Problem] = [:]
        for field in fields {
            let reading = reading(of: field)
            if let opened, opened[field.id] == reading { continue }
            switch reading {
            case .value(let value): input[field.id] = value
            case .problem(let problem): invalid[field.id] = problem
            case .empty: if opened != nil { invalid[field.id] = .empty }
            }
        }
        return (input, invalid)
    }

    private enum Reading: Equatable {
        case value(InputValue)
        case empty
        case problem(Problem)
    }

    private func reading(of field: InputField) -> Reading {
        switch field.kind {
        case .text:
            guard let value = text[field.id], !value.isEmpty else { return .empty }
            return value.utf16.count > InputField.textLimit ? .problem(.tooLong) : .value(.text(value))
        case .number:
            guard let value = text[field.id], !value.trimmingCharacters(in: .whitespaces).isEmpty else { return .empty }
            return format.number(value).map { .value(.number($0)) } ?? .problem(.notANumber)
        case .toggle:
            return toggles[field.id].map { .value(.toggle($0)) } ?? .empty
        case .date:
            return dates[field.id].map { .value(format.day(of: $0)) } ?? .empty
        }
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
    func number(_ text: String) -> Double? {
        guard let value = numbers.number(from: text)?.doubleValue, value.isFinite else { return nil }
        return value
    }

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
