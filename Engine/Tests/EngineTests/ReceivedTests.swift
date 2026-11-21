import Foundation
import Rows
import Spec
import Testing
import WidgetBuilder
import WidgetEngine

/// Designs and data that arrive from another device: proved here before they draw, and checked against the
/// kinds already stored.
@Suite struct ReceivedTests {
    func key(_ id: WidgetID) throws -> WidgetKey { try #require(WidgetKey(parsing: id.rawValue)) }

    /// Sends everything `from` wrote to `to`, as a sync pull would.
    func sync(_ from: Scratch, to: Scratch) throws {
        let feed = try from.engine.store().changes().values.joined().sorted { $0.stamp < $1.stamp }
        try to.engine.store().receive(Array(feed), now: Date())
    }

    @Test func aReceivedDesignDrawsOnlyAfterItsProofPasses() async throws {
        let phone = Scratch()
        let pad = Scratch()
        let id = try await phone.build(document(look: counterLook()))
        try sync(phone, to: pad)
        #expect(try pad.engine.widgets().isEmpty, "a new widget stays hidden until proved")
        try await pad.engine.proveReceived()
        #expect(try pad.engine.widgets().map(\.id) == [id])
        let first = try #require(try pad.engine.store().widget(key(id))?.revision)

        _ = try await phone.build(document(name: "Renamed", look: counterLook()), replacing: id)
        try sync(phone, to: pad)
        #expect(try pad.engine.store().widget(key(id))?.revision == first, "the unproved head waits")
        #expect(try pad.engine.widgets().map(\.name) == ["Counter"])
        try await pad.engine.proveReceived()
        #expect(try pad.engine.widgets().map(\.name) == ["Renamed"])
        #expect(try pad.engine.store().unprovedHeads().isEmpty)
    }

    @Test func aRejectedDesignNeverDraws() async throws {
        let phone = Scratch()
        let pad = Scratch()
        let id = try await phone.build(document(look: counterLook()))
        try sync(phone, to: pad)
        try await pad.engine.proveReceived()
        let blank = try Spec.parse(
            document(name: "Blank", look: "function render(ctx) { return { type: 'spacer' }; }").json)
        let store = try phone.engine.store()
        _ = try store.save(key(id), spec: blank, assets: [:])
        try sync(phone, to: pad)
        try await pad.engine.proveReceived()
        #expect(try pad.engine.store().unprovedHeads().isEmpty, "the verdict is recorded")
        #expect(try pad.engine.widgets().map(\.name) == ["Counter"], "the last proved revision still draws")

        let fresh = WidgetKey.mint()
        _ = try store.save(fresh, spec: blank, assets: [:])
        try sync(phone, to: pad)
        try await pad.engine.proveReceived()
        #expect(try pad.engine.store().widget(fresh) == nil, "with no proved revision, it stays hidden")
    }

    /// A deleted widget wrote numbers into a dataset another widget now reads.
    func orphaned(_ scratch: Scratch, insert values: [String: Any]) async throws -> WidgetID {
        let scores = document(
            name: "Scores", look: counterLook(), tables: ["taps": ["fields": ["score": "number"]]],
            actions: ["add": ["insert": "taps", "values": values]])
        let owner = try key(try await scratch.build(scores))
        let reader = try await scratch.build(document(look: counterLook()))
        let store = try scratch.engine.store()
        let spec = try #require(try store.widget(owner)?.spec)
        let taps = try #require(spec.table(named: "taps")).id
        try store.bind(key(reader), table: taps, to: try #require(try store.dataset(of: owner, table: taps)))
        _ = try store.apply(
            try #require(spec.action(named: "add")), widget: owner, row: nil, input: [],
            today: Today(at: morning, calendar: utc), at: morning)
        try store.delete(owner)
        return reader
    }

    func scored(_ kind: String) -> WidgetSource {
        document(look: counterLook(), tables: ["taps": ["fields": ["score": kind]]])
    }

    @Test func storedCellsKeepTheirKindAfterTheirWidgetIsDeleted() async throws {
        let scratch = Scratch()
        let reader = try await orphaned(scratch, insert: ["score": 1])
        #expect(
            try await scratch.line(scored("text"), replacing: reader)
                == "field \"taps.score\" already holds number values, and is text here; keep the kind or use a new field id"
        )
        _ = try await scratch.build(scored("number"), replacing: reader)
    }

    @Test func aFieldWithNoCellsMayChangeKind() async throws {
        let scratch = Scratch()
        let reader = try await orphaned(scratch, insert: [:])
        _ = try await scratch.build(scored("text"), replacing: reader)
    }
}
