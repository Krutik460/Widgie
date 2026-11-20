import AppIntents
import Foundation
import SwiftUI
import WidgetEngine
import WidgetKit

// The only target that imports AppIntents or WidgetKit. Linked by the app and by the widget extension,
// so both compile the same intent and the same entity, which App Intents requires.

public enum Hosting {
    /// One engine per process, on the App Group directory named by the `EngineAppGroup` Info.plist key. In
    /// the app it reloads WidgetKit after every write. In the extension it does not, because WidgetKit
    /// reloads after an intent on its own.
    public static let engine = Engine(directory: appGroupDirectory(), onCommit: isExtension ? nil : reloadWidgets)

    /// The link a form button opens: `<scheme>://form?widget=...&action=...&row=...`, with the scheme from
    /// the `EngineURLScheme` Info.plist key.
    public static func formURL(for tap: Tap) -> URL {
        var link = URLComponents()
        link.scheme = scheme
        link.host = "form"
        link.queryItems =
            [URLQueryItem(name: "widget", value: tap.widget), URLQueryItem(name: "action", value: tap.action)]
            + (tap.row.map { [URLQueryItem(name: "row", value: $0)] } ?? [])
        return link.url ?? URL(filePath: "/")
    }

    /// The tap inside a form link, or nil for any other URL. The app passes it to `engine.form(for:)` and
    /// submits the form with `engine.perform(form.tap, input:)`.
    public static func formTap(from url: URL) -> Tap? {
        guard let link = URLComponents(url: url, resolvingAgainstBaseURL: false), link.scheme == scheme,
            link.host == "form"
        else { return nil }
        func value(_ name: String) -> String? { link.queryItems?.first { $0.name == name }?.value }
        guard let widget = value("widget"), let action = value("action") else { return nil }
        return Tap(widget: widget, action: action, row: value("row"))
    }

    private static let scheme = Bundle.main.object(forInfoDictionaryKey: "EngineURLScheme") as? String ?? "engine"
}

/// The App Group container named by `EngineAppGroup`. Without one (a misconfigured target, a preview) the
/// engine falls back to this process's Application Support folder, so the widget still draws its fallback
/// face instead of crashing; the app and the extension then do not share data.
func appGroupDirectory() -> URL {
    if let group = Bundle.main.object(forInfoDictionaryKey: "EngineAppGroup") as? String,
        let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
    {
        return container.appending(path: "Engine")
    }
    return URL.applicationSupportDirectory.appending(path: "Engine")
}

private var isExtension: Bool { Bundle.main.bundleURL.pathExtension == "appex" }

private let reloadWidgets: @Sendable () -> Void = { WidgetCenter.shared.reloadAllTimelines() }

/// Lets the app and the extension discover the intent and entity declared in this package: each lists
/// this in its own `AppIntentsPackage.includedPackages`.
public struct HostingIntents: AppIntentsPackage {}

// MARK: The one intent

/// Every tap on every user-created widget that writes in place. Its four parameters are exactly `Tap`. Form
/// buttons never reach it: they are links that open the app.
public struct RunAction: AppIntent {
    public static let title: LocalizedStringResource = "Run widget action"
    public static let isDiscoverable = false

    @Parameter(title: "Widget") var widgetID: String
    @Parameter(title: "Action") var actionID: String
    @Parameter(title: "Row") var rowID: String?
    @Parameter(title: "Day") var day: String?

    public init() {}

    init(_ tap: Tap) {
        widgetID = tap.widget
        actionID = tap.action
        rowID = tap.row
        day = tap.day
    }

    public func perform() async throws -> some IntentResult {
        try Hosting.engine.perform(Tap(widget: widgetID, action: actionID, row: rowID, day: day))
        return .result()
    }
}

// MARK: The widget picker

public struct PickWidget: WidgetConfigurationIntent {
    public static let title: LocalizedStringResource = "Choose widget"
    @Parameter(title: "Widget") public var widget: WidgetChoice?
    public init() {}
}

public struct WidgetChoice: AppEntity {
    public static let typeDisplayRepresentation: TypeDisplayRepresentation = "Widget"
    public static let defaultQuery = WidgetChoiceQuery()
    public let id: WidgetID
    public let name: String
    public var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(name)") }
}

public struct WidgetChoiceQuery: EntityQuery {
    public init() {}

    public func entities(for identifiers: [WidgetID]) async throws -> [WidgetChoice] {
        try Hosting.engine.widgets().filter { identifiers.contains($0.id) }.map(WidgetChoice.init)
    }

    public func suggestedEntities() async throws -> [WidgetChoice] {
        try Hosting.engine.widgets().map(WidgetChoice.init)
    }

    /// The latest creation, which is `Engine.widgets().first`.
    public func defaultResult() async -> WidgetChoice? {
        try? Hosting.engine.widgets().first.map(WidgetChoice.init)
    }
}

extension WidgetChoice {
    init(_ summary: WidgetSummary) {
        self.init(id: summary.id, name: summary.name)
    }
}

extension WidgetID: EntityIdentifierConvertible {
    public var entityIdentifierString: String { rawValue }
    public static func entityIdentifier(for entityIdentifierString: String) -> WidgetID? {
        WidgetID(rawValue: entityIdentifierString)
    }
}

// MARK: The widget

struct Entry: TimelineEntry {
    let date: Date
    let face: Face
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, face: .placeholder)
    }

    func snapshot(for configuration: PickWidget, in context: Context) async -> Entry {
        let faces = await Hosting.engine.faces(
            for: configuration.widget?.id, family: Family(context.family), size: context.displaySize, from: .now)
        return Entry(date: faces.current.date, face: faces.current)
    }

    func timeline(for configuration: PickWidget, in context: Context) async -> Timeline<Entry> {
        let faces = await Hosting.engine.faces(
            for: configuration.widget?.id, family: Family(context.family), size: context.displaySize, from: .now)
        return Timeline(entries: faces.entries.map { Entry(date: $0.date, face: $0) }, policy: .after(faces.reloadAt))
    }
}

public struct CreationWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "creation", intent: PickWidget.self, provider: Provider()) { entry in
            FaceView(entry.face, host: .widget)
        }
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension FaceHost {
    /// The only place a tree button becomes an App Intent or a link, and the background becomes a container
    /// background.
    static let widget = FaceHost(
        button: { tap, label in AnyView(Button(intent: RunAction(tap)) { label }.buttonStyle(.plain)) },
        form: { tap, label in AnyView(Link(destination: Hosting.formURL(for: tap)) { label }) },
        root: { content, background in AnyView(content.containerBackground(for: .widget) { background }) }
    )
}

extension Family {
    init(_ family: WidgetFamily) {
        self = family == .systemMedium ? .medium : .small
    }
}
