import CoreGraphics
import Foundation
import ImageIO
import Rows
import Sandbox
import Spec
import WidgetEngine

extension Engine {
    /// Validates, proves, and saves a model's reply, or a widget another user shared. `.rejected(line)` for
    /// anything the model can fix, a thrown `EngineError` only for infrastructure failures (disk, database)
    /// and for a `replacing` id that names no widget. It runs on the phone, because fit can only be measured
    /// where SwiftUI runs: the app sends the user's description to the backend, the backend returns the
    /// model's document, and the app calls this and sends any rejection line back.
    ///
    /// Steps, stopping at the first problem:
    /// 1. `Spec.parse(source.json)`. A missing `format` means current.
    /// 2. With `replacing`: `spec.checkCompatible(replacing: old.spec)`, the same check against every other
    ///    widget bound to one of its datasets and against the kinds of the cells already stored in those
    ///    datasets (`store.storedKinds`), and keep its key. Without: a new key, whose tables get new datasets
    ///    on save.
    /// 3. `ingest`: every image has an asset entry, and every asset has bytes in `source.images` or a digest
    ///    whose file this store holds. Downscale and encode.
    /// 4. `spec.fillingTimeZone(calendar.timeZone)`.
    /// 5. `prove`, the matrix `Engine.proofs` also runs: every data state in every family, then the tinted and
    ///    dark redraws, then action coverage and the content check. The first problem is the rejection.
    /// 6. `store.save`: files first, then the revision, the head move, and a new dataset for each table that
    ///    has none. `onCommit` runs.
    public func build(_ source: WidgetSource, replacing: WidgetID? = nil) async throws(EngineError) -> BuildOutcome {
        let store = try self.store()
        let spec: Spec
        do throws(Diagnostic) {
            spec = try Spec.parse(source.json)
        } catch {
            return .rejected(error.line)
        }
        var key = WidgetKey.mint()
        var old: StoredWidget?
        if let replacing {
            guard let parsed = WidgetKey(parsing: replacing.rawValue), let found = try widget(parsed, in: store) else {
                throw EngineError(message: "no widget \(replacing.rawValue) to replace")
            }
            let sharers: [Sharer]
            let stored: [String: [String: Set<Spec.FieldKind>]]
            do throws(StoreError) {
                sharers = try store.sharers(of: parsed)
                stored = try store.storedKinds(of: parsed)
            } catch {
                throw EngineError(message: error.message)
            }
            do throws(Diagnostic) {
                try spec.checkCompatible(replacing: found.spec)
                for sharer in sharers {
                    try spec.checkCompatible(sharer.table, with: sharer.widget.spec, table: sharer.as)
                }
                for (table, kinds) in stored.sorted(by: { $0.key < $1.key }) {
                    try spec.checkCompatible(table, holding: kinds)
                }
            } catch {
                return .rejected(error.line)
            }
            key = parsed
            old = found
        }
        let images: [Spec.AssetID: Data]
        do throws(Diagnostic) {
            images = try ingest(source.images, spec: spec, keeping: old, store: store)
        } catch {
            return .rejected(error.line)
        }
        let zoned = spec.fillingTimeZone(calendar.timeZone)
        let matrix = try await prove(
            zoned, images: images, today: Today(at: .now, calendar: calendar), sandbox: sandbox,
            stopAtFirstFailure: true)
        if let verdict = matrix.verdict { return .rejected(verdict) }
        do throws(StoreError) {
            _ = try store.save(key, spec: zoned, assets: images)
        } catch {
            throw EngineError(message: error.message)
        }
        return .saved(WidgetID(rawValue: key.raw))
    }

    /// The stored widget in exchange form: the drawn revision's canonical bytes (`StoredWidget.revision`, the
    /// head once it is proved here) plus each asset's stored bytes under its id. Nil for an unknown or deleted
    /// widget, or one with no revision proved here.
    public func source(of widget: WidgetID) throws(EngineError) -> WidgetSource? {
        let store = try self.store()
        guard let key = WidgetKey(parsing: widget.rawValue), let stored = try self.widget(key, in: store) else {
            return nil
        }
        do {
            guard let json = try store.revision(stored.revision) else { return nil }
            var images: [String: Data] = [:]
            for asset in stored.spec.assets {
                guard let digest = asset.digest else { continue }
                images[asset.id.raw] = try Data(contentsOf: store.assetURL(digest))
            }
            return WidgetSource(json: json, images: images)
        } catch {
            throw EngineError(message: "widget \(widget.rawValue) could not be read: \(error)")
        }
    }

    /// Every revision the widget has had, newest first. The first is the head; the widget draws the newest one
    /// proved on this phone, which is the head unless a synced head is still waiting for `proveReceived`.
    public func history(of widget: WidgetID) throws(EngineError) -> [WidgetRevision] {
        let store = try self.store()
        guard let key = WidgetKey(parsing: widget.rawValue) else { return [] }
        do throws(StoreError) {
            return try store.revisions(of: key).map { WidgetRevision(id: $0.digest.hex, savedAt: $0.savedAt) }
        } catch {
            throw EngineError(message: error.message)
        }
    }

    /// Moves the widget back to an earlier revision in its history. This only moves the head: a revision
    /// saved here was proved when it was saved, and one another device saved draws once `proveReceived`
    /// passes it. `onCommit` runs.
    public func restore(_ widget: WidgetID, to revision: WidgetRevision) throws(EngineError) {
        let store = try self.store()
        guard let key = WidgetKey(parsing: widget.rawValue), let digest = Spec.Digest(hex: revision.id) else {
            throw EngineError(message: "revision \(revision.id) was never a head of widget \(widget.rawValue)")
        }
        do throws(StoreError) {
            try store.restore(key, to: digest)
        } catch {
            throw EngineError(message: error.message)
        }
    }

    private func widget(_ key: WidgetKey, in store: RowStore) throws(EngineError) -> StoredWidget? {
        do throws(StoreError) {
            return try store.widget(key)
        } catch {
            throw EngineError(message: error.message)
        }
    }
}

/// Image ingest: the bytes every asset of `spec` will be drawn from, after downscaling.
///
/// Each image must have an asset entry. Each asset takes its bytes from `images`, or, when they are absent,
/// from the file its digest names in `store`, where the digest comes from the document or from the same
/// asset of the replaced widget. Saving hashes the bytes again and fills the digests in.
func ingest(_ images: [String: Data], spec: Spec, keeping old: StoredWidget?, store: RowStore?) throws(Diagnostic)
    -> [Spec.AssetID: Data]
{
    if let stray = images.keys.sorted().first(where: { spec.asset(named: $0) == nil }) {
        throw Diagnostic(
            "image \(Diagnostic.quote(stray)) has no entry in \"assets\"; add {\"\(stray)\": {\"about\": \"what it shows\"}} or leave the image out"
        )
    }
    var stored: [Spec.AssetID: Data] = [:]
    for asset in spec.assets {
        if let bytes = images[asset.id.raw] {
            stored[asset.id] = try downscale(bytes, asset: asset.id.raw)
        } else if let digest = asset.digest ?? old?.spec.asset(named: asset.id.raw)?.digest, let store,
            let bytes = try? Data(contentsOf: store.assetURL(digest))
        {
            stored[asset.id] = bytes
        } else {
            throw Diagnostic(
                "asset \(Diagnostic.quote(asset.id.raw)) has no image; send its bytes with the reply, or remove the asset"
            )
        }
    }
    return stored
}

/// The longest side a stored image may have: the medium widget's width at 3x, rounded up.
private let maxSide = 1080

/// Decodes through ImageIO's thumbnail path, so a 12 MP photo is never decoded whole, caps the longest side
/// at `maxSide`, and keeps PNG when the image has alpha and JPEG otherwise. A PNG or JPEG that is already
/// upright and within the cap is kept byte for byte, so proving a stored widget again stores the same file.
private func downscale(_ bytes: Data, asset: String) throws(Diagnostic) -> Data {
    let unreadable = Diagnostic("asset \(Diagnostic.quote(asset)): the image could not be read; send a PNG or JPEG")
    guard let source = CGImageSourceCreateWithData(bytes as CFData, nil),
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
        let width = properties[kCGImagePropertyPixelWidth] as? Int,
        let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0
    else { throw unreadable }
    guard width * height <= 64_000_000 else {
        throw Diagnostic(
            "asset \(Diagnostic.quote(asset)) is \(width)x\(height) pixels; send an image of at most 64 megapixels")
    }
    let type = CGImageSourceGetType(source) as String?
    let upright = (properties[kCGImagePropertyOrientation] as? Int ?? 1) == 1
    if ["public.png", "public.jpeg"].contains(type), upright, max(width, height) <= maxSide { return bytes }
    let options: [CFString: Any] = [
        kCGImageSourceCreateThumbnailFromImageAlways: true,
        kCGImageSourceCreateThumbnailWithTransform: true,
        kCGImageSourceThumbnailMaxPixelSize: min(max(width, height), maxSide),
    ]
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
        throw unreadable
    }
    let opaque = [.none, .noneSkipFirst, .noneSkipLast].contains(image.alphaInfo)
    let data = NSMutableData()
    guard
        let destination = CGImageDestinationCreateWithData(
            data, (opaque ? "public.jpeg" : "public.png") as CFString, 1, nil)
    else { throw unreadable }
    CGImageDestinationAddImage(
        destination, image, opaque ? [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary : nil)
    guard CGImageDestinationFinalize(destination) else { throw unreadable }
    return data as Data
}
