import CoreGraphics
import Foundation
import Rows
import Spec

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
/// `revision` is the digest of the revision the button was drawn from, so the engine runs the action as that
/// revision defines it: what the user pressed is what runs. `day` is the `YYYY-MM-DD` an `insertOn` button
/// writes to, and nil for every other button.
public struct Tap: Hashable, Sendable, Codable {
    public let widget: String
    public let revision: String?
    public let action: String
    public let row: String?
    public let day: String?
    public init(widget: String, revision: String?, action: String, row: String?, day: String? = nil) {
        self.widget = widget
        self.revision = revision
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
    /// The most a text field holds, in UTF-16 units as JavaScript counts them: an emoji counts as 2.
    public static let textLimit = Spec.Limits.textLength
    public let id: String
    /// The field id made readable: `dueDate` reads "Due date".
    public let label: String
    public let kind: Kind
    /// The current value when the form edits a row.
    public let value: InputValue?

    public init(id: String, label: String, kind: Kind, value: InputValue?) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
    }
}

public enum InputValue: Sendable, Equatable {
    case text(String)
    case number(Double)
    case toggle(Bool)
    case date(year: Int, month: Int, day: Int)
}

/// Timeline entries for one widget, precomputed so day windows flip on time without spending refresh budget:
/// now and the next midnight, and, for a look that reads the clock, each quarter hour of the next two hours
/// before that midnight whose picture changed. `Engine.face` returns the first entry alone, with `reloadAt` the
/// moment that face may next change.
public struct Faces: Sendable {
    /// Never empty, ascending dates.
    public let entries: [Face]
    /// The soonest of the midnight after the last entry, two hours from now for a look that reads the clock,
    /// five minutes after the next automation run, and the first later face whose images did not fit beside
    /// the earlier entries' images.
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

    /// Whether this is the calm face shown instead of the look, for a host that checks a look really drew.
    public var isFallback: Bool {
        if case .fallback = content { true } else { false }
    }

    /// Whether the face draws a button to tap.
    public var hasButtons: Bool {
        if case .drawing(let drawing) = content { !drawing.taps.isEmpty } else { false }
    }

    /// What VoiceOver reads for each button the face draws, in tree order. None is empty.
    public var buttonLabels: [String] {
        if case .drawing(let drawing) = content { drawing.root.buttonLabels } else { [] }
    }
}

/// A page of the account's changes, as `GET /v1/changes` returns it (docs/engine/WIRE.md). The transport hands
/// over the response body and the engine parses it, so no caller handles the format.
public struct RemotePage: Sendable {
    package let page: Page

    /// Throws, naming the first problem, when the bytes are not a page. One change that does not decode refuses
    /// the whole page.
    public init(json: Data) throws(EngineError) {
        do throws(Diagnostic) {
            page = try Page(json: json)
        } catch {
            throw EngineError(message: "not a page of changes: \(error.line)")
        }
    }

    /// When the server next expects to write a change for this account, or nil when it expects none.
    public var nextWrite: Date? { page.nextWrite }

    /// How many changes the page carries. A page holding `RemotePage.limit` may have more after it.
    public var count: Int { page.changes.count }

    /// The most changes the server puts in one page (docs/engine/WIRE.md).
    public static let limit = 500
}

/// The body of `PUT /v1/automations` and its SHA-256 (docs/engine/WIRE.md).
public struct AutomationPayload: Sendable, Equatable {
    /// Canonical JSON: equal payloads are equal bytes.
    public let json: Data
    /// The SHA-256 of `json` as lowercase hex.
    public let digest: String
    /// How many automations it names. With none, there is nothing for the server to run.
    public let automations: Int
}

public struct EngineError: Error, Sendable {
    public let message: String
    /// The store refused a write because `Engine.suspend()` holds. The same call can succeed after
    /// `Engine.resume()`; every other error is not worth retrying as it is.
    public let isSuspended: Bool

    package init(message: String, isSuspended: Bool = false) {
        self.message = message
        self.isSuspended = isSuspended
    }
}
