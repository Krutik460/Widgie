import Foundation

extension Spec {
    /// An image the look may place by id. The bytes travel next to the document, never inside it.
    package struct Asset: Hashable, Sendable {
        package let id: AssetID
        /// What the picture shows, for the model that writes the look.
        package let about: String
        /// Nil only in a model reply. Saving fills it, so the revision's hash covers the image bytes and a
        /// shared revision names every file it needs.
        package let digest: Digest?
    }

    /// The SHA-256 of stored bytes as 64 lowercase hex digits. Names asset files and document revisions.
    package struct Digest: Hashable, Comparable, Sendable, CustomStringConvertible {
        package let hex: String

        package init?(hex: String) {
            guard hex.utf8.count == 64,
                hex.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) })
            else { return nil }
            self.hex = hex
        }

        package var description: String { hex }

        package static func < (a: Digest, b: Digest) -> Bool { a.hex < b.hex }
    }
}

extension Spec.Asset {
    static func parse(_ id: Spec.AssetID, _ json: JSONValue) throws(Diagnostic) -> Spec.Asset {
        do throws(Diagnostic) {
            let asset = try Reader(
                json, else: "an asset must be an object like {\"about\": \"a watercolor fox\"}, not \(json.described)")
            try asset.requireOnly(["about", "digest"]) { "unknown key \(Diagnostic.quote($0)) (keys: about)" }
            guard let about = try asset.string("about", maxLength: Spec.Limits.aboutLength), !about.isEmpty else {
                throw Diagnostic("needs \"about\": what the picture shows")
            }
            var digest: Spec.Digest?
            if let value = asset["digest"] {
                guard case .string(let hex) = value, let parsed = Spec.Digest(hex: hex) else {
                    throw Diagnostic("\"digest\" must be 64 lowercase hex digits; leave it out and the app fills it in")
                }
                digest = parsed
            }
            return Spec.Asset(id: id, about: about, digest: digest)
        } catch {
            throw error.within("asset \(Diagnostic.quote(id.raw))")
        }
    }

    var json: JSONValue {
        var members: [String: JSONValue] = ["about": .string(about)]
        if let digest { members["digest"] = .string(digest.hex) }
        return .object(members)
    }
}
