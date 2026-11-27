import Foundation

/// The part of the day the clock is in, which picks the Widgets title and Widgie's greeting.
enum Daypart: Equatable {
    case morning, afternoon, evening

    init(hour: Int) {
        switch hour {
        case 5..<12: self = .morning
        case 12..<17: self = .afternoon
        default: self = .evening
        }
    }

    init(_ date: Date, calendar: Calendar = .current) {
        self.init(hour: calendar.component(.hour, from: date))
    }

    var title: String {
        switch self {
        case .morning: "Good morning"
        case .afternoon: "Good afternoon"
        case .evening: "Good evening"
        }
    }
}

/// What Widgie says on Widgets. The app cannot read meaning from an AI-made widget, so every line names the widget
/// and what just happened, never its data.
enum Speech {
    /// About the widget Widgie stands on, or an invitation when there is none.
    static func greeting(_ perch: String?, _ part: Daypart) -> String {
        guard let perch else { return "Tell me a widget." }
        switch part {
        case .morning: return "Morning! Here’s \(perch)."
        case .afternoon: return "Afternoon! Here’s \(perch)."
        case .evening: return "I’ll keep an eye on \(perch) tonight."
        }
    }

    static func tapped(_ name: String) -> String {
        "\(name), updated."
    }

    static func landed(_ name: String, buttons: Bool) -> String {
        buttons ? "Here’s \(name). Give it a tap." : "Here’s \(name), ready to go."
    }
}
