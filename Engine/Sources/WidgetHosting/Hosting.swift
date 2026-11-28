import AppIntents
import Foundation
import SwiftUI
import WidgetEngine
import WidgetKit

// The only target that imports AppIntents or WidgetKit. Linked by the app and by the widget extension,
// so both compile the same intent and the same entity, which App Intents requires.

public enum Hosting {
    /// One engine per process, on the App Group directory named by the `EngineAppGroup` Info.plist key. It
    /// reloads every widget after every write, in the extension too: the reload WidgetKit runs after an
    /// intent covers only the tapped widget, so another widget on the same rows, even the same widget in the
    /// other size, would stay stale until its timeline ran out.
    public static let engine = Engine(directory: appGroupDirectory(), onCommit: committed)

    /// Posted on `NotificationCenter.default` after every write `engine` commits in this process. The app uploads
    /// the account's automations when one moved them, whichever write it was.
    public static let didCommit = Notification.Name("WidgieHostingDidCommit")

    /// This process's account: the Worker named by the `WidgieModelService` Info.plist key, the token in the
    /// Keychain group named by `WidgieKeychainGroup`, and the account state in the App Group's defaults.
    public static let account = AccountClient(
        base: info("WidgieModelService").flatMap(URL.init(string:)), engine: engine,
        tokens: KeychainTokens(group: info("WidgieKeychainGroup")),
        state: AccountState(defaults: info("EngineAppGroup").flatMap(UserDefaults.init(suiteName:)) ?? .standard))

    /// The link a form button opens: `<scheme>://form?widget=...&revision=...&action=...&row=...`, with the
    /// scheme from the `EngineURLScheme` Info.plist key.
    public static func formURL(for tap: Tap) -> URL {
        var link = URLComponents()
        link.scheme = scheme
        link.host = "form"
        let items: [(String, String?)] = [
            ("widget", tap.widget), ("revision", tap.revision), ("action", tap.action), ("row", tap.row),
        ]
        link.queryItems = items.compactMap { name, value in value.map { URLQueryItem(name: name, value: $0) } }
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
        return Tap(widget: widget, revision: value("revision"), action: action, row: value("row"))
    }

    private static let scheme = info("EngineURLScheme") ?? "engine"

    private static func info(_ key: String) -> String? { Bundle.main.object(forInfoDictionaryKey: key) as? String }
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

private let committed: @Sendable () -> Void = {
    WidgetCenter.shared.reloadAllTimelines()
    NotificationCenter.default.post(name: Hosting.didCommit, object: nil)
}

/// Lets the app and the extension discover the intent and entity declared in this package: each lists
/// this in its own `AppIntentsPackage.includedPackages`.
public struct HostingIntents: AppIntentsPackage {}

// MARK: The one intent

/// Every tap on every user-created widget that writes in place. Its five parameters are exactly `Tap`. Form
/// buttons never reach it: they are links that open the app.
public struct RunAction: AppIntent {
    public static let title: LocalizedStringResource = "Run widget action"
    public static let isDiscoverable = false

    @Parameter(title: "Widget") var widgetID: String
    @Parameter(title: "Revision") var revision: String?
    @Parameter(title: "Action") var actionID: String
    @Parameter(title: "Row") var rowID: String?
    @Parameter(title: "Day") var day: String?

    public init() {}

    init(_ tap: Tap) {
        widgetID = tap.widget
        revision = tap.revision
        actionID = tap.action
        rowID = tap.row
        day = tap.day
    }

    public func perform() async throws -> some IntentResult {
        try Hosting.engine.perform(Tap(widget: widgetID, revision: revision, action: actionID, row: rowID, day: day))
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
    public let createdAt: Date
    /// The creation time tells apart widgets that share a name, such as three made from "water tracker".
    public var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "Made \(createdAt.formatted(.dateTime.month(.abbreviated).day().hour().minute()))")
    }
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
        self.init(id: summary.id, name: summary.name, createdAt: summary.createdAt)
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
        // The zone the phone is in now, which Foundation caches until told it moved, for the faces and for the
        // payload an upload after the pull sends.
        NSTimeZone.resetSystemTimeZone()
        // Rows the server wrote since the last pull, when one is due, so this render draws them, then the upload of
        // the automations when the server lacks them, such as the zone after travel with the app closed. At most
        // 4 s for the network (a merge already running finishes first), and any failure, or no token before the
        // first unlock, draws what the store holds.
        await Hosting.account.pullBeforeRender()
        let faces = await Hosting.engine.faces(
            for: configuration.widget?.id, family: Family(context.family), size: context.displaySize, from: .now)
        return Timeline(entries: faces.entries.map { Entry(date: $0.date, face: $0) }, policy: .after(faces.reloadAt))
    }
}

public struct CreationWidget: Widget {
    /// The kind WidgetKit knows this widget by, which `WidgetCenter` reports for each placed copy.
    public static let kind = "creation"

    public init() {}
    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: Self.kind, intent: PickWidget.self, provider: Provider()) { entry in
            WidgetFace(face: entry.face)
        }
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// The face in the mode WidgetKit draws it in, which only the view can read.
struct WidgetFace: View {
    let face: Face
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        FaceView(face, host: .widget).environment(\.renderingMode, mode == .fullColor ? .fullColor : .accented)
    }
}

extension FaceHost {
    /// The only place a tree button becomes an App Intent or a link, the background becomes a container
    /// background, and `accent` and image `tint` become WidgetKit's accented rendering.
    static let widget = FaceHost(
        button: { tap, label in AnyView(Button(intent: RunAction(tap)) { label }.buttonStyle(.plain)) },
        form: { tap, label in AnyView(Link(destination: Hosting.formURL(for: tap)) { label }) },
        root: { content, background in AnyView(content.containerBackground(for: .widget) { background }) },
        accent: { content in AnyView(content.widgetAccentable()) },
        tint: { tint, image in AnyView(image.widgetAccentedRenderingMode(tint.widgetMode)) }
    )
}

extension ImageTint {
    /// `accented` maps the image's brightness to the tint, as the proof emulates it.
    fileprivate var widgetMode: WidgetAccentedRenderingMode {
        switch self {
        case .fullColor: .fullColor
        case .desaturated: .desaturated
        case .accented: .accentedDesaturated
        }
    }
}

extension Family {
    public init(_ family: WidgetFamily) {
        self = family == .systemMedium ? .medium : .small
    }
}
