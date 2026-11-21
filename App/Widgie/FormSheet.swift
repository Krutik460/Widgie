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

    var body: some View {
        NavigationStack {
            Form {
                ForEach(form.fields) { field in
                    switch field.kind {
                    case .text:
                        TextField(field.label, text: binding(field.id, in: $text, default: ""))
                    case .number:
                        TextField(field.label, text: binding(field.id, in: $text, default: ""))
                            .keyboardType(.decimalPad)
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
                    Button("Save") { submit(input) }
                }
            }
            .onAppear(perform: fill)
        }
    }

    /// Only fields the user can see a value for are sent, so an untouched empty field stays absent.
    private var input: [String: InputValue] {
        var input: [String: InputValue] = [:]
        let calendar = Calendar.current
        for field in form.fields {
            switch field.kind {
            case .text:
                if let value = text[field.id], !value.isEmpty { input[field.id] = .text(value) }
            case .number:
                if let value = text[field.id].flatMap(Double.init) { input[field.id] = .number(value) }
            case .toggle:
                if let value = toggles[field.id] { input[field.id] = .toggle(value) }
            case .date:
                if let value = dates[field.id] {
                    let parts = calendar.dateComponents([.year, .month, .day], from: value)
                    input[field.id] = .date(year: parts.year ?? 1970, month: parts.month ?? 1, day: parts.day ?? 1)
                }
            }
        }
        return input
    }

    private func fill() {
        for field in form.fields {
            switch field.value {
            case .text(let value): text[field.id] = value
            case .number(let value): text[field.id] = value.formatted(.number.grouping(.never))
            case .toggle(let value): toggles[field.id] = value
            case .date(let year, let month, let day):
                dates[field.id] = Calendar.current.date(from: DateComponents(year: year, month: month, day: day))
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
