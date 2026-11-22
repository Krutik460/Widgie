import Foundation
import Rows
import Spec
import WidgetEngine

extension Engine {
    /// Proves every widget head that another device saved and this one has not proved, and records each
    /// verdict, so a design that arrives by sync is checked on this phone, with its fonts and symbols, before
    /// it draws. Until then the widget draws its newest revision proved here, or stays hidden when it has
    /// none, and a rejected revision never draws. The app calls this after a sync pull; the extension never
    /// does. `onCommit` runs after each verdict. Throws only for infrastructure failures.
    ///
    /// The revision is proved exactly as stored: its bytes are canonical and named by their hash, so nothing
    /// is filled in (the sender filled the time zone before saving). Images come from the store's asset files,
    /// and the proof is `build`'s: `prove(..., stopAtFirstFailure: true)`. A revision this build cannot parse
    /// (a newer format) or whose asset files have not arrived yet gets no verdict, so it is tried again later.
    public func proveReceived() async throws(EngineError) {
        let store = try self.store()
        for revision in try attempt({ () throws(StoreError) in try store.unprovedHeads() }) {
            guard let body = try attempt({ () throws(StoreError) in try store.revision(revision) }),
                let spec = try? Spec.parse(body),
                spec.assets.allSatisfy({ asset in
                    asset.digest.map { FileManager.default.fileExists(atPath: store.assetURL($0).path()) } ?? true
                })
            else { continue }
            let images: [Spec.AssetID: Data]
            do throws(Diagnostic) {
                images = try ingest([:], spec: spec, keeping: nil, store: store)
            } catch {
                try attempt { () throws(StoreError) in try store.recordProof(of: revision, verdict: error.line) }
                continue
            }
            let verdict = try await prove(
                spec, images: images, today: Today(at: .now, calendar: calendar), sandbox: sandbox,
                stopAtFirstFailure: true
            ).verdict
            try attempt { () throws(StoreError) in try store.recordProof(of: revision, verdict: verdict) }
        }
    }
}
