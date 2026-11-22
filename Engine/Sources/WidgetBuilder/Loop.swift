import Foundation
import Spec
import WidgetEngine

/// The first try, then at most two repairs, as `Engine/Evals/run.py` runs it.
private let maxAttempts = 3

extension Engine {
    /// The build loop: asks `model` for a widget, builds its reply with `build(_:replacing:)`, and sends each
    /// rejection back as a repair, until a reply is saved or three attempts were rejected.
    ///
    /// - `replacing` refines that widget: the model gets its stored document as `current`, and the accepted
    ///   reply replaces it under the same id, keeping its rows.
    /// - `repairing` makes the first call a repair of the `replacing` widget's stored document with that line,
    ///   for a document another store rejected. It needs `replacing`.
    /// - `image` goes to the model with every call. A reply that declares the asset `reference` gets it as that
    ///   asset's bytes; any other reply builds without it, and a refine that sent no image keeps the stored one.
    ///
    /// Only a rejected reply uses an attempt. An error from `model` is rethrown as it is. Cancellation is
    /// checked around each model call and throws `CancellationError` with nothing saved; a `build` already
    /// under way finishes, and its outcome is returned. Throws `EngineError` when `replacing` names no widget
    /// or the store fails.
    public func build(
        _ words: String, image: Attachment? = nil, replacing: WidgetID? = nil, repairing line: String? = nil,
        model: some WidgetModel, progress: @Sendable (BuildStep) -> Void = { _ in }
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
                if attempt == maxAttempts { return .gaveUp(lastLine: rejection, attempts: attempt) }
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
/// else the whole reply trimmed. This is `extract` in `Engine/Evals/model.py`, line for line, so the eval
/// harness and the app take the same document from the same reply. `Engine/Evals/testdata/extract.json` holds
/// the cases both are tested against.
package func extractDocument(_ reply: String) -> String {
    let lines = Python.lines(reply)
    var blocks: [(json: Bool, body: String)] = []
    var index = 0
    while index < lines.count {
        guard let info = Python.openingFence(lines[index]) else {
            index += 1
            continue
        }
        var end = index + 1
        while end < lines.count && Python.strip(lines[end]) != "```" { end += 1 }
        blocks.append((info == "json", lines[(index + 1)..<end].joined(separator: "\n")))
        index = end + 1
    }
    guard !blocks.isEmpty else { return Python.strip(reply) }
    let tagged = blocks.filter(\.json)
    var longest = (tagged.first ?? blocks[0]).body
    for block in tagged.isEmpty ? blocks : tagged where block.body.unicodeScalars.count > longest.unicodeScalars.count {
        longest = block.body
    }
    return longest
}

/// Python's string rules where `model.extract` relies on them: lengths count code points, and lines and
/// whitespace are wider than Swift's `isNewline` and `isWhitespace`.
private enum Python {
    /// `str.splitlines()`: no line terminators kept, and no empty line after a final terminator.
    static func lines(_ text: String) -> [String] {
        var lines: [String] = []
        var line = String.UnicodeScalarView()
        var afterReturn = false
        for scalar in text.unicodeScalars {
            if afterReturn {
                afterReturn = false
                if scalar == "\n" { continue }
            }
            if lineBreaks.contains(scalar.value) {
                lines.append(String(line))
                line = String.UnicodeScalarView()
                afterReturn = scalar == "\r"
            } else {
                line.append(scalar)
            }
        }
        if !line.isEmpty { lines.append(String(line)) }
        return lines
    }

    /// `str.strip()`.
    static func strip(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard let first = scalars.firstIndex(where: { !isSpace($0) }),
            let last = scalars.lastIndex(where: { !isSpace($0) })
        else { return "" }
        return String(scalars[first...last])
    }

    /// The info string of a line that `re.fullmatch(r"```([A-Za-z0-9_-]*)\s*", line)` matches, else nil.
    static func openingFence(_ line: String) -> String? {
        let scalars = line.unicodeScalars
        guard scalars.starts(with: "```".unicodeScalars) else { return nil }
        let info = scalars.dropFirst(3).prefix { isInfo($0) }
        guard scalars[info.endIndex...].allSatisfy(isSpace) else { return nil }
        return String(info)
    }

    /// `str.splitlines` boundaries. `\r\n` is one boundary.
    private static let lineBreaks: Set<UInt32> = [
        0x0A, 0x0B, 0x0C, 0x0D, 0x1C, 0x1D, 0x1E, 0x85, 0x2028, 0x2029,
    ]

    /// `str.isspace`, which `\s` and `strip()` use: Unicode White_Space plus the four information separators.
    private static func isSpace(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || (0x1C...0x1F).contains(scalar.value)
    }

    private static func isInfo(_ scalar: Unicode.Scalar) -> Bool {
        ("a"..."z").contains(scalar) || ("A"..."Z").contains(scalar) || ("0"..."9").contains(scalar)
            || scalar == "_" || scalar == "-"
    }
}
