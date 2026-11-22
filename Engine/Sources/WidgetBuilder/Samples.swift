import Foundation
import Rows
import Spec
import WidgetEngine

extension Engine {
    /// The names of the widget's samples, in the saved document's order, which sorts keys by their UTF-8
    /// bytes. Empty for an unknown widget.
    public func samples(of widget: WidgetID) throws(EngineError) -> [String] {
        let store = try self.store()
        guard let key = WidgetKey(parsing: widget.rawValue) else { return [] }
        return try self.widget(key, in: store)?.spec.samples.map(\.name) ?? []
    }

    /// Replaces the widget's rows with the rows of `state`, as of `date`, so a draft shows what it looks
    /// like in use. Each table moves to a new, empty dataset that the state's rows go into, in one
    /// transaction, so switching from one sample to another never mixes them, and `.empty` shows no rows.
    /// Taps then write on top of the sample as they would on real rows.
    ///
    /// Only a scratch engine (`Engine.scratch()`) takes this, because in the shared store it would hide the
    /// person's rows. Throws for any other engine, an unknown widget, or a state the widget cannot hold.
    public func load(_ state: DataState, into widget: WidgetID, at date: Date = .now) throws(EngineError) {
        guard isScratch else {
            throw EngineError(message: "samples load only into a scratch engine, never the shared store")
        }
        let store = try self.store()
        guard let key = WidgetKey(parsing: widget.rawValue), let found = try self.widget(key, in: store) else {
            throw EngineError(message: "no widget \(widget.rawValue) to load a sample into")
        }
        let sample: Spec.Sample
        do throws(Diagnostic) {
            sample = try ProofState(state, of: found.spec).sample
        } catch {
            throw EngineError(message: error.line)
        }
        try attempt { () throws(StoreError) in
            try store.replaceRows(
                of: key, tables: found.spec.tables, with: sample, today: Today(at: date, calendar: calendar))
        }
    }
}
