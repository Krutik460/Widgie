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
        }
    }

    static let help = """
        render-tool: renders a widget the way the builder proves it.

        USAGE
          render-tool <widget dir> <small|medium> <out.png> [--sample <name> | --full | --state <rows.json>]
                      [--date <ISO 8601>] [--time-zone <identifier>]
          render-tool proof <widget dir> <out dir> [--date <ISO 8601>] [--time-zone <identifier>]
          render-tool --help

        A widget dir holds widget.json and, when the widget has images, assets/<asset id>.png or .jpg.

        RENDER MODE
          Draws one data state in one family: the empty state unless --sample, --full, or --state picks
          another. --state reads rows in the grammar of one "samples" entry. Writes the PNG (3x, light),
          prints the fit report as one line of JSON on stdout, and prints the verdict or the error on
          stderr.

        PROOF MODE
          Runs exactly what the app's builder runs before it saves a widget: the empty state, every
          sample, and the synthesized full state, each in small and medium, then action coverage and
          the content check. Every cell is rendered even after one fails. Writes into <out dir>:
            <state>-<family>.png   one per render that produced an image. <state> is "empty", "full",
                                   or "sample-" and the sample name in lowercase with every run of
                                   other characters turned into "-".
            report.json            the verdict and every render, described below.
          Prints one line on stdout: "accepted", or the verdict line the builder would send the model.

        REPORT (report.json, keys sorted, two-space indent)
          {
            "date":     the instant the widget was rendered at, ISO 8601,
            "timeZone": the time zone days were computed in,
            "widget":   the widget's name, or null when widget.json does not parse,
            "verdict":  null when the builder would save the widget, else its one-line rejection,
            "renders":  [ in matrix order: empty, each sample, full; small before medium
              {
                "state":   "empty", "full", or the sample name,
                "family":  "small" or "medium",
                "png":     the file name, or null when the look failed before drawing,
                "verdict": null, or the line this render alone would get,
                "error":   null, or the line when the look failed before drawing,
                "fit":     null when the look failed, else {
                  "spill", "layoutOverflow" {width, height}, "edges" {top, bottom, leading, trailing},
                  "cut" [{path, node, label, within, edge, spill}], "truncated" and "ellipsized"
                  [{path, value, linesNeeded, linesShown, lineLimit, width, height}], "ink",
                  "imagePixels", "buttons" [action ids], "lookMilliseconds", "renderMilliseconds"
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
          1  the builder would reject it; the verdict says why
          2  usage error, or a file could not be read or written
        """
}

private enum Command {
    case help
    case render(Render)
    case proof(ProofRun)

    init(_ arguments: [String]) throws(Usage) {
        var options = Options(arguments)
        if options.flag("--help") || options.flag("-h") || arguments.isEmpty {
            self = .help
            return
        }
        let date = try options.date()
        let (calendar, zone) = try options.calendar()
        if options.positional.first == "proof" {
            try options.done(positionals: 3)
            self = .proof(
                ProofRun(
                    widget: URL(filePath: options.positional[1]), output: URL(filePath: options.positional[2]),
                    date: date, calendar: calendar, zone: zone))
            return
        }
        let sample = try options.value("--sample")
        let full = options.flag("--full")
        let state = try options.value("--state")
        try options.done(positionals: 3)
        guard [sample != nil, full, state != nil].filter({ $0 }).count <= 1 else {
            throw Usage(line: "pick at most one of --sample, --full, and --state")
        }
        guard let family = Family(rawValue: options.positional[1]) else {
            throw Usage(line: "the family must be small or medium, not \"\(options.positional[1])\"")
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
                output: URL(filePath: options.positional[2]), state: chosen, date: date, calendar: calendar))
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
            proof = try await Engine.proof(source, state: state, family: family, at: date, calendar: calendar)
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
        var used: Set<String> = []
        var renders: [Report.Render] = []
        for render in matrix.renders {
            switch render.outcome {
            case .success(let proof):
                let file = unique("\(slug(render.state))-\(render.family.rawValue)", in: &used) + ".png"
                renders.append(
                    Report.Render(
                        state: render.state, family: render.family.rawValue, png: file, verdict: proof.verdict,
                        error: nil, fit: proof.fit, bytes: proof.png))
            case .failure(let rejected):
                renders.append(
                    Report.Render(
                        state: render.state, family: render.family.rawValue, png: nil, verdict: rejected.line,
                        error: rejected.line, fit: nil, bytes: nil))
            }
        }
        let report = Report(
            date: date.formatted(.iso8601), timeZone: zone, widget: matrix.name,
            verdict: matrix.verdict, renders: renders)
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
        print(matrix.verdict ?? "accepted")
        return matrix.verdict == nil ? 0 : 1
    }

    /// "sample-goal-met" for the sample "goal met". The builder's own states keep their names, and no sample
    /// can share them, because the parser refuses a sample named "empty" or "full".
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
        let png: String?
        let verdict: String?
        let error: String?
        let fit: FitReport?
        let bytes: Data?

        enum CodingKeys: String, CodingKey { case state, family, png, verdict, error, fit }

        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(state, forKey: .state)
            try container.encode(family, forKey: .family)
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
