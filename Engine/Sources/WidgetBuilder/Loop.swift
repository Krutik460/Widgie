import Foundation
import Spec
import WidgetEngine

extension Engine {
    /// The first try, then at most two repairs, as `Engine/Evals/run.py` runs it.
    public static let maxBuildAttempts = 3

    /// The build loop: asks `model` for a widget, builds its reply with `build(_:replacing:)`, and sends each
    /// rejection back as a repair, until a reply is saved or `maxBuildAttempts` attempts were rejected.
    ///
    /// - `replacing` refines that widget: the model gets its stored document as `current`, and the accepted
    ///   reply replaces it under the same id, keeping its rows.
    /// - `repairing` makes the first call a repair of the `replacing` widget's stored document with that line,
    ///   for a document another store rejected. That call is attempt 1. It needs `replacing`.
    /// - `image` goes to the model with every call. A reply that declares the asset `reference` gets it as that
    ///   asset's bytes; any other reply builds without it, and a refine that sent no image keeps the stored one.
    ///
    /// `progress` runs on the caller's actor, in order, and every step has run when the loop returns, so a
    /// main-actor screen can set its state from it directly.
    ///
    /// Only a rejected reply uses an attempt. An error from `model` is rethrown as it is. After a cancel the
    /// loop throws `CancellationError` with nothing saved, with one exception: a `build` already under way
    /// finishes, and when it saves, `.accepted` returns, so the caller decides whether to keep that widget.
    /// A reply rejected after a cancel throws `CancellationError`, never `.gaveUp`. Throws `EngineError` when
    /// `replacing` names no widget or the store fails.
    public func build(
        _ words: String, image: Attachment? = nil, replacing: WidgetID? = nil, repairing line: String? = nil,
        model: some WidgetModel, isolation: isolated (any Actor)? = #isolation,
        progress: (BuildStep) -> Void = { _ in }
    ) async throws -> LoopOutcome {
        var request = ModelRequest(words: words, image: image)
        if let replacing {
            guard let stored = try source(of: replacing) else {
                throw EngineError(message: "no widget \(replacing.rawValue) to replace")
            }
            request.current = String(decoding: stored.json, as: UTF8.self)
        }
        if let line {
            guard let current = request.current else {
                throw EngineError(message: "repairing needs the widget to repair in replacing")
            }
            request.repair = Repair(document: current, line: line)
        }
        var attempt = 1
        while true {
            try Task.checkCancellation()
            progress(request.repair.map { .repairing(attempt: attempt, line: $0.line) } ?? .writing(attempt: attempt))
            let reply: String
            do {
                reply = try await model.reply(to: request)
            } catch {
                // A cancelled URLSession throws URLError, not CancellationError.
                try Task.checkCancellation()
                throw error
            }
            try Task.checkCancellation()
            let document = extractDocument(reply)
            progress(.checking(attempt: attempt))
            switch try await build(proposal(document, image: image), replacing: replacing) {
            case .saved(let id):
                return .accepted(id, attempts: attempt)
            case .rejected(let rejection):
                try Task.checkCancellation()
                if attempt == Self.maxBuildAttempts { return .gaveUp(lastLine: rejection, attempts: attempt) }
                request.repair = Repair(document: document, line: rejection)
                attempt += 1
            }
        }
    }
}

/// The source `build` proves for a reply. `ingest` refuses an image the document has no asset for, so the
/// picture goes in only when the document declares `reference`.
private func proposal(_ document: String, image: Attachment?) -> WidgetSource {
    let json = Data(document.utf8)
    guard let image, (try? Spec.parse(json))?.asset(named: "reference") != nil else {
        return WidgetSource(json: json)
    }
    return WidgetSource(json: json, images: ["reference": image.bytes])
}

/// The document in a model reply: the longest fenced `json` block, else the longest fenced block of any kind,
/// else the whole reply, trimmed of ASCII whitespace. This is `extract` in `Engine/Evals/model.py`, so the eval
/// harness and the app take the same document from the same reply, and `Engine/Evals/testdata/extract.json`
/// holds the cases both are tested against. Lines end only at LF, with a CR before it dropped, and lengths count
/// Unicode scalars, as Python's `len` does.
package func extractDocument(_ reply: String) -> String {
    let lines = Array(reply.unicodeScalars).split(separator: "\n", omittingEmptySubsequences: false).map { line in
        line.last == "\r" ? Array(line.dropLast()) : Array(line)
    }
    var blocks: [(json: Bool, body: [Unicode.Scalar])] = []
    var index = 0
    while index < lines.count {
        guard let info = openingFence(lines[index]) else {
            index += 1
            continue
        }
        var end = index + 1
        while end < lines.count && trimmed(lines[end], of: [" ", "\t"]) != fence { end += 1 }
        blocks.append((info == "json", Array(lines[(index + 1)..<end].joined(separator: ["\n"]))))
        index = end + 1
    }
    guard !blocks.isEmpty else { return text(trimmed(Array(reply.unicodeScalars), of: whitespace)) }
    let candidates = blocks.contains(where: \.json) ? blocks.filter(\.json) : blocks
    var longest = candidates[0].body
    for block in candidates where block.body.count > longest.count { longest = block.body }
    return text(trimmed(longest, of: whitespace))
}

private let fence: [Unicode.Scalar] = ["`", "`", "`"]

/// `WHITESPACE` in model.py.
private let whitespace: Set<Unicode.Scalar> = [" ", "\t", "\n", "\r", "\u{0C}", "\u{0B}"]

/// The info string of a line that `re.fullmatch(r"```([A-Za-z0-9_-]*)[ \t]*", line)` matches, else nil.
private func openingFence(_ line: [Unicode.Scalar]) -> String? {
    guard line.starts(with: fence) else { return nil }
    let rest = line.dropFirst(fence.count)
    let info = rest.prefix {
        ("a"..."z").contains($0) || ("A"..."Z").contains($0) || ("0"..."9").contains($0) || $0 == "_" || $0 == "-"
    }
    guard rest.dropFirst(info.count).allSatisfy({ $0 == " " || $0 == "\t" }) else { return nil }
    return text(Array(info))
}

private func trimmed(_ scalars: [Unicode.Scalar], of set: Set<Unicode.Scalar>) -> [Unicode.Scalar] {
    guard let first = scalars.firstIndex(where: { !set.contains($0) }),
        let last = scalars.lastIndex(where: { !set.contains($0) })
    else { return [] }
    return Array(scalars[first...last])
}

private func text(_ scalars: [Unicode.Scalar]) -> String {
    var view = String.UnicodeScalarView()
    view.append(contentsOf: scalars)
    return String(view)
}
