import WidgetEngine

/// The widgets added while the app runs. The newest wears the New tag until the next one arrives. One saved while
/// you are away from Widgets counts on the tab until you open it, and then lands in the feed.
struct Arrivals: Equatable {
    private(set) var fresh: WidgetID?
    /// Saved while away from Widgets, newest first.
    private(set) var unseen: [WidgetID] = []
    /// The widget landing in the feed now, which Widgie points out.
    private(set) var landing: WidgetID?

    var badge: Int { unseen.count }

    mutating func arrive(_ id: WidgetID, onWidgets: Bool) {
        fresh = id
        if onWidgets {
            landing = id
        } else {
            unseen.insert(id, at: 0)
        }
    }

    mutating func openWidgets() {
        guard let newest = unseen.first else { return }
        landing = newest
        unseen = []
    }
}
