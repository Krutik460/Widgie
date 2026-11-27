import Observation
import WidgetEngine

/// The app's tabs and what passes between them: the page showing, the pages built so far, the widgets arriving
/// in Widgets, the ones flown into its glyph, and the toast that says one is in.
@MainActor @Observable
final class Tabs {
    enum Page: Int, CaseIterable, Hashable {
        case widgets, make, templates
    }

    private(set) var page = Page.widgets
    /// Each page is built on its first visit and then stays alive, so it keeps its scroll and its work.
    private(set) var visited: Set<Page> = [.widgets]
    private(set) var arrivals = Arrivals()
    /// Counts the widgets that flew into the Widgets glyph, each of which squishes it.
    private(set) var caught = 0
    private(set) var toast: Toast?

    @ObservationIgnored private var toasts = 0

    /// Switches tabs. Opening Widgets clears its count and the toast, and what arrived meanwhile lands. A toast shown
    /// on Make leaves with Make.
    func go(_ next: Page) {
        visited.insert(next)
        page = next
        if next != .make, toast?.low == true { toast = nil }
        if next == .widgets {
            arrivals.openWidgets()
            toast = nil
        }
    }

    /// A widget saved or installed: it lands now on Widgets, or counts on the tab until Widgets opens.
    func arrive(_ id: WidgetID) {
        arrivals.arrive(id, onWidgets: page == .widgets)
    }

    /// A widget added from a template, flying into the Widgets tab while the person stays where they are. Its
    /// card waits hidden with the New tag from the start, so the feed never shows it before it lands. Once
    /// `flight` ends the glyph takes it in, and it lands if Widgets is showing by then, or counts on the tab with
    /// a toast that names it.
    func take(_ id: WidgetID, named name: String, flight: () async -> Void) async {
        arrivals.add(id)
        await flight()
        caught += 1
        arrive(id)
        guard page != .widgets else { return }
        toasts += 1
        let shown = Toast(id: toasts, words: "\(name) is in your widgets.", low: page == .make)
        toast = shown
        Task {
            try? await Task.sleep(for: Toast.shownFor)
            if toast == shown { toast = nil }
        }
    }
}
