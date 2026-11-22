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

    /// Records the draft's head and the rows it shows, so `rollBack(to:)` can undo a build and the `load` that
    /// showed it. A sample load moves tables to new datasets and leaves the old ones in place, so the rows
    /// recorded here, taps included, are still there to point back at.
    ///
    /// Only a scratch engine takes this, as with `load`. Throws for any other engine or an unknown widget.
    public func checkpoint(of widget: WidgetID) throws(EngineError) -> Checkpoint {
        guard isScratch else { throw EngineError(message: "only a scratch engine takes a checkpoint") }
        let store = try self.store()
        guard let key = WidgetKey(parsing: widget.rawValue),
            let head = try attempt({ () throws(StoreError) in try store.revisions(of: key) }).first
        else {
            throw EngineError(message: "no widget \(widget.rawValue) to checkpoint")
        }
        return Checkpoint(
            widget: key, head: head.digest,
            datasets: try attempt { () throws(StoreError) in try store.bindings(of: key) })
    }

    /// Moves the draft back to its checkpoint's head and the rows it showed then, in one transaction. Tables
    /// the checkpoint did not have lose their datasets, so a later build may add them again with other kinds.
    public func rollBack(to checkpoint: Checkpoint) throws(EngineError) {
        guard isScratch else { throw EngineError(message: "only a scratch engine rolls back to a checkpoint") }
        let store = try self.store()
        try attempt { () throws(StoreError) in
            try store.rollBack(checkpoint.widget, to: checkpoint.head, bindings: checkpoint.datasets)
        }
    }
}

/// A draft as `Engine.checkpoint(of:)` recorded it: its head and the dataset each of its tables read.
public struct Checkpoint: Sendable {
    let widget: WidgetKey
    let head: Spec.Digest
    let datasets: [String: DatasetKey]
}
