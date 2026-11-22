import Foundation
import WidgetEngine

/// The exchange format: the document JSON plus image bytes keyed by asset id. One format for a model reply,
/// a refinement context (`Engine.source(of:)`), the render tool's input, a debugging export, and a widget
/// another user shared. On disk it is a directory:
///
///     widget.json
///     assets/<asset id>.png | .jpg
///
/// Raw on purpose: this is the boundary where untrusted text enters, and it is parsed into typed blocks
/// inside `build`, `proof`, and `proofs`, never by callers.
public struct WidgetSource: Sendable {
    public var json: Data
    public var images: [String: Data]

    public init(json: Data, images: [String: Data] = [:]) {
        self.json = json
        self.images = images
    }

    /// Reads `widget.json` and every file in `assets/`, each keyed by its name without the extension. Hidden
    /// files are skipped.
    public init(directory: URL) throws(Rejected) {
        let document = directory.appending(path: "widget.json")
        do {
            json = try Data(contentsOf: document)
        } catch {
            throw Rejected(line: "no readable widget.json in \(directory.path(percentEncoded: false))")
        }
        images = [:]
        let folder = directory.appending(path: "assets")
        guard FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)) else { return }
        do {
            let files = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles)
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let id = file.deletingPathExtension().lastPathComponent
                guard images[id] == nil else {
                    throw Rejected(line: "two files in assets/ are named \"\(id)\"; keep one per asset id")
                }
                images[id] = try Data(contentsOf: file)
            }
        } catch let rejected as Rejected {
            throw rejected
        } catch {
            throw Rejected(line: "assets/ could not be read: \(error.localizedDescription)")
        }
    }

    /// Writes the directory form. Each image gets `.png` or `.jpg` by its bytes.
    public func write(to directory: URL) throws(Rejected) {
        do {
            let folder = directory.appending(path: "assets")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try json.write(to: directory.appending(path: "widget.json"), options: .atomic)
            for (id, bytes) in images {
                let png = bytes.starts(with: [0x89, 0x50, 0x4E, 0x47])
                try bytes.write(to: folder.appending(path: "\(id).\(png ? "png" : "jpg")"), options: .atomic)
            }
        } catch {
            throw Rejected(line: "the widget could not be written: \(error.localizedDescription)")
        }
    }
}

/// A problem the model, or whoever wrote the source, can fix, as one line.
public struct Rejected: Error, Sendable {
    public let line: String
}

public enum BuildOutcome: Sendable, Equatable {
    case saved(WidgetID)
    /// Send this line back to the model as the repair instruction.
    case rejected(String)
}

/// The data state for a proof.
public enum DataState: Hashable, Sendable {
    /// No rows. Every look must survive it: `latest` is null and lists are empty.
    case empty
    /// One of the source's `samples`, by name.
    case sample(String)
    /// The state the builder synthesizes: every list at its limit, three-digit counts, long text.
    case full
    /// A file in the same grammar as one `samples` entry.
    case file(URL)
}

/// How a proof draws a render. WidgetKit tells the look neither, so the same tree must work in all three.
public enum Appearance: String, Sendable, CaseIterable {
    /// Full color in the light color scheme: the cell every data state gets.
    case light
    /// Full color in the dark color scheme. `{ light, dark }` colors take their dark value.
    case dark
    /// The tinted home screen, emulated: the background replaced by a dark backdrop, every color white at its
    /// own opacity, `accent: true` nodes in a tint color, and images by their `tint`. A device must confirm it.
    case tinted
}

/// One saved revision of a widget, for "undo that change".
public struct WidgetRevision: Sendable, Hashable, Identifiable {
    /// The revision's content hash. The same document always has the same id, on every device.
    public let id: String
    public let savedAt: Date
}

/// Everything `build` checks before it saves, for a source that is not saved: every render of the proof
/// matrix and the verdict. `verdict` is exactly the line `build` would return, or nil when it would save.
public struct ProofMatrix: Sendable {
    /// The widget's name, or nil when the document does not parse.
    public let name: String?
    /// In matrix order: `empty`, each sample, then `full`, each in every family, all light; then `empty` and
    /// `full` tinted, and `full` dark, each in every family. Empty when the source was rejected before any
    /// render.
    public let renders: [ProofRender]
    public let verdict: String?
}

public struct ProofRender: Sendable {
    /// `empty`, `full`, or the sample's name.
    public let state: String
    public let family: Family
    public let appearance: Appearance
    /// The render, or the line when the look failed before there was anything to measure.
    public let outcome: Result<Proof, Rejected>
}
