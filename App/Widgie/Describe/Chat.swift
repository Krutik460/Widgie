import Observation
import WidgetBuilder

/// One Make chat around its session: the ideas its empty page offers, and the question it asks in the thread before
/// work would be lost, whether to start over, to swap the draft for a template, or to leave a change unsaved. In the
/// Make tab it starts a fresh session in place; editing a library widget, it closes.
@MainActor @Observable
final class Chat {
    enum Question: Equatable {
        /// New, in the Make tab, with a draft.
        case startOver
        /// Change in chat from a template, with a draft.
        case swap(String)
        /// Close, editing a library widget, with an accepted change.
        case leave

        var words: String {
            switch self {
            case .startOver: "Start over? This widget isn’t saved yet."
            case .swap(let name): "Swap your draft for \(name)?"
            case .leave: "Leave without saving? Your changes will be lost."
            }
        }

        var replace: String { self == .leave ? "Discard changes" : "Replace draft" }
    }

    private(set) var session: DescribeSession
    /// What the empty page offers to send first, three of the catalog's suggestions, changing with each new chat.
    private(set) var ideas: [Template.Suggestion] = []
    private(set) var question: Question?
    /// Nil in the Make tab, which never closes.
    let close: (() -> Void)?

    var editing: Bool { close != nil }

    /// A template to change in chat, waiting for the person's answer or for a save to land.
    private var chosen: (source: WidgetSource, name: String)?
    private let catalog: [Template]
    private let start: (DescribeSession.Origin) -> DescribeSession

    init(
        _ origin: DescribeSession.Origin = .nothing, close: (() -> Void)? = nil,
        catalog: [Template] = Template.catalog(),
        start: @escaping (DescribeSession.Origin) -> DescribeSession = { DescribeSession($0) }
    ) {
        self.close = close
        self.catalog = catalog
        self.start = start
        session = start(origin)
        shuffle()
    }

    /// New in the Make tab, or Close while editing: at once when nothing would be lost, after asking when it would,
    /// and not while a save is under way, which would land after the session it belongs to is gone.
    func leave() {
        switch session.replacement {
        case .free: end()
        case .discards: question = editing ? .leave : .startOver
        case .waits: break
        }
    }

    /// Opens a filled template as the draft, so the person's first message refines it. A draft asks first, and a
    /// save under way lands before the template takes its place.
    func change(_ source: WidgetSource, named name: String) {
        chosen = (source, name)
        weigh()
    }

    func keepEditing() {
        question = nil
        chosen = nil
    }

    func replace() {
        switch question {
        case .startOver: begin(.nothing)
        case .swap: begin(waiting)
        case .leave: end()
        case nil: break
        }
    }

    /// A save finished its flight into the Widgets tab: a fresh chat starts, or the template that waited for it.
    func saved() {
        begin(waiting)
    }

    /// Weighs a template that waited out a save which then failed. A save that landed leaves it to `saved`.
    func resume() {
        guard chosen != nil, question == nil else { return }
        if case .saved = session.phase { return }
        weigh()
    }

    private var waiting: DescribeSession.Origin {
        chosen.map { .unsaved($0.source) } ?? .nothing
    }

    private func weigh() {
        guard let chosen else { return }
        switch session.replacement {
        case .free: begin(.unsaved(chosen.source))
        case .discards: question = .swap(chosen.name)
        case .waits: question = nil
        }
    }

    private func end() {
        if let close {
            session.cancel()
            close()
        } else {
            begin(.nothing)
        }
    }

    private func begin(_ origin: DescribeSession.Origin) {
        session.cancel()
        chosen = nil
        question = nil
        session = start(origin)
        if case .nothing = origin { shuffle() }
    }

    private func shuffle() {
        var generator = SystemRandomNumberGenerator()
        ideas = Template.ideas(from: catalog, using: &generator)
    }
}
