import CoreGraphics
import Foundation

// The public value types. Everything else in this module is `package` or private.

public struct WidgetID: Hashable, Sendable, Codable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

public struct WidgetSummary: Sendable, Identifiable {
    public let id: WidgetID
    public let name: String
    public let createdAt: Date
}

/// The sizes the look language supports. The host maps WidgetKit's family to this.
public enum Family: String, Sendable, CaseIterable, Codable {
    case small
    case medium

    /// The look language's reference sizes, for previews and the render tool. On a device the timeline
    /// provider passes the real display size.
    public var standardSize: CGSize {
        switch self {
        case .small: CGSize(width: 158, height: 158)
        case .medium: CGSize(width: 338, height: 158)
        }
    }
}

/// What a button in the tree is about, as the widget's App Intent and the form link carry it. Strings,
/// because they arrive from outside (an intent parameter, a URL) and the engine validates them on use.
/// `day` is the `YYYY-MM-DD` an `insertOn` button writes to, and nil for every other button.
public struct Tap: Hashable, Sendable, Codable {
    public let widget: String
    public let action: String
    public let row: String?
    public let day: String?
    public init(widget: String, action: String, row: String?, day: String? = nil) {
        self.widget = widget
        self.action = action
        self.row = row
        self.day = day
    }
}

public struct InputForm: Sendable {
    public let tap: Tap
    public let title: String
    public let fields: [InputField]
}

public struct InputField: Sendable, Identifiable {
    public enum Kind: Sendable { case text, number, toggle, date }
    public let id: String
    /// The field id made readable: `dueDate` reads "Due date".
    public let label: String
    public let kind: Kind
    /// The current value when the form edits a row.
    public let value: InputValue?
}

public enum InputValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case toggle(Bool)
    case date(year: Int, month: Int, day: Int)
}

/// Timeline entries for one widget: now, and the next day boundary, precomputed so day windows flip on time
/// without spending refresh budget.
public struct Faces: Sendable {
    /// Never empty, ascending dates.
    public let entries: [Face]
    /// The next day boundary after the last entry, or shortly after the next automation run if sooner.
    public let reloadAt: Date
    public var current: Face { entries[0] }
}

/// One render-ready frame. Opaque: the host only puts it in a timeline entry and hands it to `FaceView`.
public struct Face: Sendable {
    public let date: Date
    package let content: Content

    package enum Content: Sendable {
        case drawing(Drawing)
        /// Unknown widget, no widgets yet, store unavailable, newer format, or a look that failed on this
        /// data. Renders a calm face with the widget's name when known. Never shows a stack trace.
        case fallback(name: String?, reason: String)
    }

    /// For `TimelineProvider.placeholder`, which must return synchronously without touching the store.
    public static let placeholder = Face(date: .distantPast, content: .fallback(name: nil, reason: "placeholder"))
}

public struct EngineError: Error, Sendable {
    public let message: String

    package init(message: String) { self.message = message }
}
