import Foundation
import WidgetBuilder
import WidgetEngine

@main
struct RenderTool {
    static func main() async {
        exit(await run(Array(CommandLine.arguments.dropFirst())))
    }

    /// The whole tool, as a function of its arguments, so a test runs exactly what the command line runs.
    /// Returns the exit status.
    static func run(_ arguments: [String]) async -> Int32 {
        let command: Command
        do {
            command = try Command(arguments)
        } catch {
            standardError("error: \(error.line)\nrun render-tool --help for usage")
            return 2
        }
        switch command {
        case .help:
            print(help)
            return 0
        case .render(let render):
            return await render.run()
        case .proof(let proof):
            return await proof.run()
        case .loop(let loop):
            return await loop.run()
        case .refine(let refine):
            return await refine.run()
        }
    }

    static let help = """
        render-tool: renders a widget the way the builder proves it.

        USAGE
          render-tool <widget dir> <small|medium> <out.png> [--sample <name> | --full | --state <rows.json>]
                      [--appearance <light|dark|tinted>] [--size <width>x<height>] [--date <ISO 8601>]
                      [--time-zone <identifier>]
          render-tool proof <widget dir> <out dir> [--date <ISO 8601>] [--time-zone <identifier>]
          render-tool loop <words> <out dir> [--image <png|jpg>] [--bridge <url>] [--time-zone <identifier>]
          render-tool refine <old widget dir> <new widget dir> <out dir> [--date <ISO 8601>]
                      [--time-zone <identifier>]
          render-tool --help

        A widget dir holds widget.json and, when the widget has images, assets/<asset id>.png or .jpg.

        RENDER MODE
          Draws one data state in one family: the empty state unless --sample, --full, or --state picks
          another. --state reads rows in the grammar of one "samples" entry. --appearance draws it in
          full color light (the default) or dark, or in the emulated tinted mode. --size draws it at that
          size in points, like 358x172 for a face in the app, instead of the family's standard size; the
          builder proves only the standard sizes. Writes the PNG (3x),
          prints the fit report as one line of JSON on stdout, and prints the verdict or the error on
          stderr.

        PROOF MODE
          Runs exactly what the app's builder runs before it saves a widget: the empty state, every
          sample, and the synthesized full state, each in small and medium, then empty and full again
          tinted and full again dark, then action coverage and the content check. Every cell is rendered
          even after one fails. Writes into <out dir>:
            <state>-<family>.png   one per light render that produced an image. <state> is "empty",
                                   "full", or "sample-" and the sample name in lowercase with every
                                   run of other characters turned into "-".
            <state>-<family>-<tinted|dark>.png   one per tinted or dark render.
            report.json            the verdict and every render, described below.
          Prints one line on stdout: "accepted", or the verdict line the builder would send the model.

        LOOP MODE
          Runs the app's build loop against the dev bridge (Engine/Evals/bridge.py, default
          --bridge http://127.0.0.1:8787): sends <words>, and the picture when --image is given, builds
          the reply into a fresh engine in a temporary folder, and sends each rejection back as a repair,
          at most three attempts in all. Prints each step on stderr with the seconds since the start,
          then the seconds each attempt spent with the model and in the build. Prints one line on
          stdout: "accepted in <n> attempts", or "gave up after 3 attempts: " and the last verdict. On
          acceptance, writes the saved widget to <out dir> as a widget dir.

        REFINE MODE
          Runs what the app runs when a person refines a widget. Builds the old widget into a scratch
          engine, then builds the new one in its place with the builder's replacing check: every table
          id kept, every field id kept with its kind, then the full proof. The scratch engine holds no
          other widget and no rows, so the builder's two store checks always pass here: agreement with
          widgets that share the data, and with the kinds of the cells already stored. Only the app can
          fail those. Writes into <out dir>:
            current/               the old widget as the app sends it to the model to refine: the stored
                                   source, widget.json and assets/, with digests and time zone filled in.
            the PNGs and report.json of proof mode, for the widget that would draw: the saved one when
                                   the builder accepts the new widget, else the new widget as sent, with
                                   the old widget's image for each asset it sends no bytes for.
          Prints one line on stdout: "accepted", or the verdict line the builder would send the model.
          The report's verdict is that line. An old widget the builder rejects is an error.

        REPORT (report.json, keys sorted, two-space indent)
          {
            "date":     the instant the widget was rendered at, ISO 8601,
            "timeZone": the time zone days were computed in,
            "widget":   the widget's name, or null when widget.json does not parse,
            "verdict":  null when the builder would save the widget, else its one-line rejection,
            "renders":  [ in matrix order: empty, each sample, full, then empty and full tinted, then
                          full dark; small before medium
              {
                "state":   "empty", "full", or the sample name,
                "family":  "small" or "medium",
                "appearance": "light", "tinted", or "dark",
                "png":     the file name, or null when the look failed before drawing,
                "verdict": null, or the line this render alone would get,
                "error":   null, or the line when the look failed before drawing,
                "fit":     null when the look failed, else {
                  "spill", "layoutOverflow" {width, height}, "edges" {top, bottom, leading, trailing},
                  "cut" [{path, node, label, within, edge, spill}], "truncated" and "ellipsized"
                  [{path, value, linesNeeded, linesShown, lineLimit, width, height}], "ink", "cover"
                  (tinted renders only), "imagePixels", "buttons" [action ids], "lookMilliseconds", "renderMilliseconds"
                }
              }
            ]
          }
          Points are rounded to a tenth. For the same widget, --date, and --time-zone, every byte of
          report.json and of every PNG is the same on every run, except lookMilliseconds and
          renderMilliseconds.

        DAYS
          Days are computed in --time-zone (default UTC) with weeks starting on Monday, so the output
          does not depend on the machine. --date defaults to now; pass it for repeatable output.

        EXIT STATUS
          0  the builder would accept the widget (render mode: this render passes)
          1  the builder would reject it; the verdict says why (loop mode: it gave up)
          2  usage error, a file could not be read or written, or the bridge did not answer
        """
}

private enum Command {
    case help
    case render(Render)
    case proof(ProofRun)
    case loop(LoopRun)
    case refine(RefineRun)

    init(_ arguments: [String]) throws(Usage) {
        var options = Options(arguments)
        if options.flag("--help") || options.flag("-h") || arguments.isEmpty {
            self = .help
            return
        }
        let (calendar, zone) = try options.calendar()
        if options.positional.first == "loop" {
            self = .loop(try LoopRun(&options, calendar: calendar))
            return
        }
        let date = try options.date()
        if options.positional.first == "proof" {
            try options.done(positionals: 3)
            self = .proof(
                ProofRun(
                    widget: URL(filePath: options.positional[1]), output: URL(filePath: options.positional[2]),
                    date: date, calendar: calendar, zone: zone))
            return
        }
        if options.positional.first == "refine" {
            try options.done(positionals: 4)
            self = .refine(
                RefineRun(
                    old: URL(filePath: options.positional[1]), new: URL(filePath: options.positional[2]),
                    output: URL(filePath: options.positional[3]), date: date, calendar: calendar, zone: zone))
            return
        }
        let sample = try options.value("--sample")
        let named = try options.value("--appearance")
        let full = options.flag("--full")
        let state = try options.value("--state")
        let size = try options.size()
        try options.done(positionals: 3)
        guard [sample != nil, full, state != nil].filter({ $0 }).count <= 1 else {
            throw Usage(line: "pick at most one of --sample, --full, and --state")
        }
        guard let family = Family(rawValue: options.positional[1]) else {
            throw Usage(line: "the family must be small or medium, not \"\(options.positional[1])\"")
        }
        var appearance = Appearance.light
        if let named {
            guard let picked = Appearance(rawValue: named) else {
                throw Usage(line: "the appearance must be light, dark, or tinted, not \"\(named)\"")
            }
            appearance = picked
        }
        var chosen = DataState.empty
        if let sample { chosen = .sample(sample) }
        if full { chosen = .full }
        if let state {
            guard FileManager.default.isReadableFile(atPath: state) else {
                throw Usage(line: "the state file \"\(state)\" cannot be read")
            }
            chosen = .file(URL(filePath: state))
        }
        self = .render(
            Render(
                widget: URL(filePath: options.positional[0]), family: family,
                output: URL(filePath: options.positional[2]), state: chosen, appearance: appearance, size: size,
                date: date, calendar: calendar))
    }
}

/// A command line the tool cannot run.
private struct Usage: Error {
    let line: String
}

/// `--name value` pairs and flags in any order, and the positional arguments left over.
private struct Options {
    private var remaining: [String]

    init(_ arguments: [String]) { remaining = arguments }

    var positional: [String] { remaining }

    mutating func flag(_ name: String) -> Bool {
        guard let index = remaining.firstIndex(of: name) else { return false }
        remaining.remove(at: index)
        return true
    }

    mutating func value(_ name: String) throws(Usage) -> String? {
        guard let index = remaining.firstIndex(of: name) else { return nil }
        guard index + 1 < remaining.count else { throw Usage(line: "\(name) needs a value") }
        let value = remaining[index + 1]
        remaining.removeSubrange(index...index + 1)
        return value
    }

    mutating func date() throws(Usage) -> Date {
        guard let text = try value("--date") else { return .now }
        guard let date = try? Date(text, strategy: .iso8601) else {
            throw Usage(line: "--date must be ISO 8601, like 2026-11-18T09:00:00Z, not \"\(text)\"")
        }
        return date
    }

    /// The calendar days are computed in, and the time zone's name as given.
    mutating func calendar() throws(Usage) -> (Calendar, String) {
        let name = try value("--time-zone") ?? "UTC"
        guard let zone = TimeZone(identifier: name) else {
            throw Usage(line: "--time-zone must be a time zone name like Europe/Berlin, not \"\(name)\"")
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        calendar.firstWeekday = 2
        return (calendar, name)
    }

    mutating func size() throws(Usage) -> CGSize? {
        guard let text = try value("--size") else { return nil }
        let sides = text.split(separator: "x", omittingEmptySubsequences: false).compactMap { Double($0) }
        guard sides.count == 2, sides.allSatisfy({ $0 > 0 && $0 <= 2000 }) else {
            throw Usage(line: "--size must be a width and height in points, like 358x172, not \"\(text)\"")
        }
        return CGSize(width: sides[0], height: sides[1])
    }

    func done(positionals count: Int) throws(Usage) {
        if let unknown = remaining.first(where: { $0.hasPrefix("--") }) {
            throw Usage(line: "unknown option \"\(unknown)\"")
        }
        guard remaining.count == count else {
            throw Usage(line: "expected \(count) arguments, got \(remaining.count)")
        }
    }
}

private struct Render {
    let widget: URL
    let family: Family
    let output: URL
    let state: DataState
    let appearance: Appearance
    let size: CGSize?
    let date: Date
    let calendar: Calendar

    func run() async -> Int32 {
        let source: WidgetSource
        do throws(Rejected) {
            source = try WidgetSource(directory: widget)
        } catch {
            standardError("error: \(error.line)")
            return 2
        }
        let proof: Proof
        do throws(Rejected) {
            proof = try await Engine.proof(
                source, state: state, family: family, size: size, appearance: appearance, at: date,
                calendar: calendar)
        } catch {
            standardError("error: \(error.line)")
            return 1
        }
        do {
            try proof.png.write(to: output, options: .atomic)
        } catch {
            standardError("error: \(output.path(percentEncoded: false)) could not be written")
            return 2
        }
        print(String(decoding: encode(proof.fit, pretty: false), as: UTF8.self))
        if let verdict = proof.verdict { standardError(verdict) }
        return proof.verdict == nil ? 0 : 1
    }
}

private struct ProofRun {
    let widget: URL
    let output: URL
    let date: Date
    let calendar: Calendar
    let zone: String

    func run() async -> Int32 {
        let source: WidgetSource
        do throws(Rejected) {
            source = try WidgetSource(directory: widget)
        } catch {
            standardError("error: \(error.line)")
            return 2
        }
        let matrix: ProofMatrix
        do throws(EngineError) {
            matrix = try await Engine.proofs(source, at: date, calendar: calendar)
        } catch {
            standardError("error: \(error.message)")
            return 2
        }
        return write(matrix, verdict: matrix.verdict, to: output, date: date, zone: zone)
    }
}

/// Builds the old widget into a scratch engine, then the new one with `replacing:`, as a refine runs on the
/// phone, so the document-only replacing check runs here exactly as it runs there.
private struct RefineRun {
    let old: URL
    let new: URL
    let output: URL
    let date: Date
    let calendar: Calendar
    let zone: String

    func run() async -> Int32 {
        let before: WidgetSource
        let after: WidgetSource
        do throws(Rejected) {
            before = try WidgetSource(directory: old)
            after = try WidgetSource(directory: new)
        } catch {
            standardError("error: \(error.line)")
            return 2
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "render-tool-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = Engine(directory: directory, calendar: calendar)
        let current: WidgetSource
        let drawn: WidgetSource
        let verdict: String?
        let matrix: ProofMatrix
        do throws(EngineError) {
            let id: WidgetID
            switch try await engine.build(before, replacing: nil, at: date) {
            case .saved(let saved):
                id = saved
            case .rejected(let line):
                standardError("error: the old widget is rejected: \(line)")
                return 2
            }
            guard let stored = try engine.source(of: id) else {
                standardError("error: the old widget was saved but could not be read back")
                return 2
            }
            current = stored
            switch try await engine.build(after, replacing: id, at: date) {
            case .saved:
                drawn = try engine.source(of: id) ?? after
                verdict = nil
            case .rejected(let line):
                drawn = after
                verdict = line
            }
            matrix = try await Engine.proofs(drawn, keeping: current, at: date, calendar: calendar)
        } catch {
            standardError("error: \(error.message)")
            return 2
        }
        do throws(Rejected) {
            try current.write(to: output.appending(path: "current"))
        } catch {
            standardError("error: \(error.line)")
            return 2
        }
        return write(matrix, verdict: verdict, to: output, date: date, zone: zone)
    }
}

/// Writes a matrix's PNGs and report.json into `output`, prints `verdict` or "accepted", and returns the exit
/// status.
private func write(_ matrix: ProofMatrix, verdict: String?, to output: URL, date: Date, zone: String) -> Int32 {
    var used: Set<String> = []
    var renders: [Report.Render] = []
    for render in matrix.renders {
        let suffix = render.appearance == .light ? "" : "-\(render.appearance.rawValue)"
        switch render.outcome {
        case .success(let proof):
            let file = unique("\(slug(render.state))-\(render.family.rawValue)\(suffix)", in: &used) + ".png"
            renders.append(
                Report.Render(
                    state: render.state, family: render.family.rawValue, appearance: render.appearance.rawValue,
                    png: file, verdict: proof.verdict, error: nil, fit: proof.fit, bytes: proof.png))
        case .failure(let rejected):
            renders.append(
                Report.Render(
                    state: render.state, family: render.family.rawValue, appearance: render.appearance.rawValue,
                    png: nil, verdict: rejected.line, error: rejected.line, fit: nil, bytes: nil))
        }
    }
    let report = Report(
        date: date.formatted(.iso8601), timeZone: zone, widget: matrix.name, verdict: verdict, renders: renders)
    do {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for render in renders {
            if let file = render.png, let bytes = render.bytes {
                try bytes.write(to: output.appending(path: file), options: .atomic)
            }
        }
        try encode(report, pretty: true).write(to: output.appending(path: "report.json"), options: .atomic)
    } catch {
        standardError("error: \(output.path(percentEncoded: false)) could not be written: \(error)")
        return 2
    }
    print(verdict ?? "accepted")
    return verdict == nil ? 0 : 1
}

/// "sample-goal-met" for the sample "goal met". The builder's own states keep their names, and no sample can
/// share them, because the parser refuses a sample named "empty" or "full".
private func slug(_ state: String) -> String {
    if ["empty", "full"].contains(state) { return state }
    var slug = ""
    for character in state.lowercased() {
        if character.isASCII && (character.isLetter || character.isNumber) {
            slug.append(character)
        } else if slug.last != "-" {
            slug.append("-")
        }
    }
    return "sample-" + slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
}

private func unique(_ name: String, in used: inout Set<String>) -> String {
    var candidate = name
    var counter = 2
    while used.contains(candidate) {
        candidate = "\(name)-\(counter)"
        counter += 1
    }
    used.insert(candidate)
    return candidate
}

private struct LoopRun {
    let words: String
    let output: URL
    let image: Attachment?
    let bridge: BridgeModel
    let calendar: Calendar

    init(_ options: inout Options, calendar: Calendar) throws(Usage) {
        let image = try options.value("--image")
        let bridge = try options.value("--bridge") ?? "http://127.0.0.1:8787"
        try options.done(positionals: 3)
        guard let url = URL(string: bridge), url.scheme == "http" || url.scheme == "https" else {
            throw Usage(line: "--bridge must be a URL like http://127.0.0.1:8787, not \"\(bridge)\"")
        }
        if let image {
            let types = ["png": "image/png", "jpg": "image/jpeg", "jpeg": "image/jpeg"]
            guard let mime = types[URL(filePath: image).pathExtension.lowercased()],
                let bytes = FileManager.default.contents(atPath: image)
            else { throw Usage(line: "the image \"\(image)\" must be a readable PNG or JPEG") }
            self.image = Attachment(mime: mime, bytes: bytes)
        } else {
            self.image = nil
        }
        words = options.positional[1]
        output = URL(filePath: options.positional[2])
        self.bridge = BridgeModel(base: url)
        self.calendar = calendar
    }

    func run() async -> Int32 {
        let directory = FileManager.default.temporaryDirectory.appending(path: "render-tool-loop-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = Engine(directory: directory, calendar: calendar)
        let started = ContinuousClock.now
        var steps: [(step: BuildStep, at: ContinuousClock.Instant)] = []
        let outcome: LoopOutcome
        do {
            outcome = try await engine.build(words, image: image, model: bridge) { step in
                let now = ContinuousClock.now
                steps.append((step, now))
                standardError(String(format: "%7.2f s  ", (now - started) / .seconds(1)) + describe(step))
            }
        } catch let error as EngineError {
            standardError("error: \(error.message)")
            return 2
        } catch let error as BridgeModel.Refused {
            standardError("error: the bridge failed: \(error.description)")
            return 2
        } catch {
            standardError(
                "error: the bridge at \(bridge.base.absoluteString) did not answer: \(error.localizedDescription)")
            return 2
        }
        let ended = ContinuousClock.now
        var model: [String] = []
        var build: [String] = []
        for (index, mark) in steps.enumerated() {
            let seconds = String(
                format: "%.2f s", ((index + 1 < steps.count ? steps[index + 1].at : ended) - mark.at) / .seconds(1))
            if case .checking = mark.step { build.append(seconds) } else { model.append(seconds) }
        }
        standardError("model \(model.joined(separator: ", ")); build \(build.joined(separator: ", "))")
        switch outcome {
        case .accepted(let id, let attempts):
            let saved: WidgetSource?
            do throws(EngineError) {
                saved = try engine.source(of: id)
            } catch {
                standardError("error: \(error.message)")
                return 2
            }
            do throws(Rejected) {
                try saved?.write(to: output)
            } catch {
                standardError("error: \(error.line)")
                return 2
            }
            print("accepted in \(attempts) attempt\(attempts == 1 ? "" : "s")")
            return 0
        case .gaveUp(let line, let attempts):
            print("gave up after \(attempts) attempts: \(line)")
            return 1
        }
    }

    private func describe(_ step: BuildStep) -> String {
        switch step {
        case .writing(let attempt): "writing, attempt \(attempt)"
        case .checking(let attempt): "checking, attempt \(attempt)"
        case .repairing(let attempt, let line): "repairing, attempt \(attempt): \(line)"
        }
    }
}

/// report.json. Optional values encode as null, so every key is always present.
private struct Report: Encodable {
    let date: String
    let timeZone: String
    let widget: String?
    let verdict: String?
    let renders: [Render]

    struct Render: Encodable {
        let state: String
        let family: String
        let appearance: String
        let png: String?
        let verdict: String?
        let error: String?
        let fit: FitReport?
        let bytes: Data?

        enum CodingKeys: String, CodingKey { case state, family, appearance, png, verdict, error, fit }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(family, forKey: .family)
            try container.encode(appearance, forKey: .appearance)
            try container.encode(png, forKey: .png)
            try container.encode(verdict, forKey: .verdict)
            try container.encode(error, forKey: .error)
            try container.encode(fit, forKey: .fit)
        }
    }

    enum CodingKeys: String, CodingKey { case date, timeZone, widget, verdict, renders }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(date, forKey: .date)
        try container.encode(timeZone, forKey: .timeZone)
        try container.encode(widget, forKey: .widget)
        try container.encode(verdict, forKey: .verdict)
        try container.encode(renders, forKey: .renders)
    }
}

private func encode(_ value: some Encodable, pretty: Bool) -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = pretty ? [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes] : [.sortedKeys]
    return (try? encoder.encode(value)) ?? Data("null".utf8)
}

private func standardError(_ line: String) {
    FileHandle.standardError.write(Data((line + "\n").utf8))
}
