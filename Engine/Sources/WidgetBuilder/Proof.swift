import CoreGraphics
import Foundation
import Rows
import Sandbox
import Spec
import SwiftUI
import WidgetEngine

extension Engine {
    /// Renders a source in one data state, family, and appearance, offscreen, and measures it. Used by the
    /// render tool and by evals; `build` runs the same `proveCell` and `proveAppearance` for every cell of its
    /// matrix.
    ///
    /// Throws `Rejected` when there is nothing to measure: the source does not parse, the state does not
    /// match the tables, or the look fails on this data. Otherwise returns the PNG and the fit report,
    /// with `verdict` set to the exact line `build` would send for this render: for `dark` and `tinted`,
    /// the light render's line first, since layout does not change with the appearance.
    public static func proof(
        _ source: WidgetSource, state: DataState = .empty, family: Family, size: CGSize? = nil,
        appearance: Appearance = .light, at date: Date = .now, calendar: Calendar = .current
    ) async throws(Rejected) -> Proof {
        let spec: Spec
        let images: [Spec.AssetID: Data]
        let chosen: ProofState
        do throws(Diagnostic) {
            spec = try Spec.parse(source.json).fillingTimeZone(calendar.timeZone)
            images = try ingest(source.images, spec: spec, keeping: nil, store: nil)
            chosen = try ProofState(state, of: spec)
        } catch {
            throw Rejected(line: error.line)
        }
        do throws(ProofStop) {
            let cell = try await proveCell(
                spec, images: images, state: chosen, family: family, size: size ?? family.standardSize,
                today: Today(at: date, calendar: calendar).noon, sandbox: Sandbox())
            guard appearance != .light else { return cell.proof }
            let shown = try await proveAppearance(cell, appearance)
            return Proof(png: shown.png, fit: shown.fit, verdict: cell.proof.verdict ?? shown.verdict)
        } catch {
            switch error {
            case .rejected(let line): throw Rejected(line: line)
            case .broken(let message): throw Rejected(line: "the proof could not run: \(message)")
            }
        }
    }

    /// Everything `build` checks, on a source it does not save: every data state in every family, then the
    /// tinted and dark redraws, then action coverage and the content check. Unlike `build` it renders every cell even after one fails, so
    /// an eval sees them all, but `verdict` is the same first problem `build` would return. Throws only when
    /// the proof itself cannot run.
    public static func proofs(_ source: WidgetSource, at date: Date = .now, calendar: Calendar = .current)
        async throws(EngineError) -> ProofMatrix
    {
        try await proofs(source, keeping: nil, at: date, calendar: calendar)
    }

    /// `proofs` of a refine's new widget, which leaves out the bytes of the images it keeps: an asset with no
    /// bytes in `source` draws from the image of the same id in `old`, as `build` draws it from the store.
    package static func proofs(_ source: WidgetSource, keeping old: WidgetSource?, at date: Date, calendar: Calendar)
        async throws(EngineError) -> ProofMatrix
    {
        let spec: Spec
        do throws(Diagnostic) {
            spec = try Spec.parse(source.json).fillingTimeZone(calendar.timeZone)
        } catch {
            return ProofMatrix(name: nil, renders: [], verdict: error.line)
        }
        var bytes = source.images
        for asset in spec.assets where bytes[asset.id.raw] == nil {
            bytes[asset.id.raw] = old?.images[asset.id.raw]
        }
        let images: [Spec.AssetID: Data]
        do throws(Diagnostic) {
            images = try ingest(bytes, spec: spec, keeping: nil, store: nil)
        } catch {
            return ProofMatrix(name: spec.name, renders: [], verdict: error.line)
        }
        let matrix = try await prove(
            spec, images: images, today: Today(at: date, calendar: calendar), sandbox: Sandbox(),
            stopAtFirstFailure: false)
        return ProofMatrix(name: spec.name, renders: matrix.renders, verdict: matrix.verdict)
    }
}

public struct Proof: Sendable {
    /// 3x, `FaceHost.still`, in the render's appearance.
    public let png: Data
    public let fit: FitReport
    /// The exact line `build` would send the model for this render, or nil when it passes.
    public let verdict: String?
}

/// What the builder measures in one render. Points throughout, rounded to a tenth.
public struct FitReport: Codable, Sendable {
    /// The most any drawn node sits outside the widget or outside a clipping ancestor. Over 2 is rejected.
    public let spill: Double
    /// How far the root's own size exceeds the widget. Informational: padding past the edge cuts nothing.
    public let layoutOverflow: Overflow
    /// The most any drawn node sits past each edge of the widget.
    public let edges: Edges
    /// Nodes that sit outside the widget or a clipping ancestor, worst first, at most eight.
    public let cut: [Cut]
    /// Text cut short where the look did not ask for an ellipsis. Any entry is rejected.
    public let truncated: [Truncation]
    /// Text that ends in an ellipsis at its own `lineLimit`, as the look asked. Allowed.
    public let ellipsized: [Truncation]
    /// Share of sampled opaque pixels that stand out from the dominant color by at least 32 of 255 in some
    /// channel, to four places. Under 0.0005 is a blank render: nothing drawn, or drawn in the background's
    /// color.
    public let ink: Double
    /// Tinted renders only: the share of sampled opaque pixels in the most common color that is not the
    /// backdrop, to four places. Over 0.5 means a full-size shape draws the backdrop. Nil otherwise.
    public let cover: Double?
    /// Image pixels decoded for this render. Informational: a decode past `AssetImages.pixelBudget` fails the
    /// look itself, before there is a render to measure.
    public let imagePixels: Int
    /// The action of every button rendered, in tree order.
    public let buttons: [String]
    /// From the queries to the validated tree. Varies from run to run.
    public let lookMilliseconds: Double
    /// Rendering and measuring. Varies from run to run.
    public let renderMilliseconds: Double

    public struct Overflow: Codable, Sendable {
        public let width, height: Double
    }

    public struct Edges: Codable, Sendable {
        public let top, bottom, leading, trailing: Double
    }

    public struct Cut: Codable, Sendable {
        public let path: String
        /// "text", "symbol", "rect", "image", "button", ...
        public let node: String
        /// The text, the symbol name, or the button's action. Empty for shapes and images.
        public let label: String
        /// "widget", or the path of the clipping node.
        public let within: String
        /// The edge it sits furthest past: "top", "bottom", "leading", or "trailing".
        public let edge: String
        public let spill: Double
    }

    public struct Truncation: Codable, Sendable {
        public let path: String
        /// The first 60 characters.
        public let value: String
        /// At the text's smallest allowed scale, in the width it was given.
        public let linesNeeded: Int
        /// The lines its height has room for.
        public let linesShown: Int
        public let lineLimit: Int?
        public let width: Double
        public let height: Double
    }
}

/// A data state with the label its error lines use: `empty`, `full`, `sample "busy"`, `state "rows.json"`.
struct ProofState: Sendable {
    let name: String
    let label: String
    let sample: Spec.Sample

    func prefix(_ family: Family, _ appearance: Appearance = .light) -> String {
        appearance == .light
            ? "\(family.rawValue), \(label): " : "\(family.rawValue), \(label), \(appearance.rawValue): "
    }

    static let empty = ProofState(name: "empty", label: "empty", sample: Spec.empty)

    static func all(of spec: Spec) -> [ProofState] {
        [.empty]
            + spec.samples.map { ProofState(name: $0.name, label: "sample \(Diagnostic.quote($0.name))", sample: $0) }
            + [ProofState(name: "full", label: "full", sample: spec.full)]
    }

    init(name: String, label: String, sample: Spec.Sample) {
        self.name = name
        self.label = label
        self.sample = sample
    }

    init(_ state: DataState, of spec: Spec) throws(Diagnostic) {
        switch state {
        case .empty:
            self = .empty
        case .full:
            self.init(name: "full", label: "full", sample: spec.full)
        case .sample(let name):
            guard let sample = spec.sample(named: name) else {
                throw Diagnostic(
                    "no sample \(Diagnostic.quote(name)) (samples: \(spec.samples.map(\.name).joined(separator: ", ")))"
                )
            }
            self.init(name: name, label: "sample \(Diagnostic.quote(name))", sample: sample)
        case .file(let url):
            let data: Data
            do {
                data = try Data(contentsOf: url)
            } catch {
                throw Diagnostic("the state file \(url.lastPathComponent) could not be read")
            }
            let name = url.lastPathComponent
            self.init(
                name: name, label: "state \(Diagnostic.quote(name))", sample: try spec.parseState(data, name: name))
        }
    }
}

/// Proofs render at 3x, the scale of the phones the widget runs on, and text is measured on the same grid.
let renderScale = 3.0

/// Why a cell stopped: something the model can fix, or the proof machinery itself.
enum ProofStop: Error {
    case rejected(String)
    case broken(String)
}

/// One passing render of the matrix, with what coverage and the content check need from it.
struct Cell: Sendable {
    let state: ProofState
    let family: Family
    let size: CGSize
    let today: Today
    let proof: Proof
    let composition: Composition
}

/// The one acceptance path. `build` runs it before it saves, and `Engine.proofs` runs it for the render tool,
/// so the two cannot disagree. Renders `empty`, each sample, and `full` in every family, in that order, then
/// redraws the same trees tinted (`empty`, the sparsest, where a blank or a backdrop shape shows most, and
/// `full`, the busiest) and dark (`full`, where every color pair is in use). The first failing render's line
/// is the verdict. When every render passes, coverage and the content check run on the whole matrix.
/// Every proof renders at noon of `today`'s day (`Today.noon`), so the verdict never depends on the hour. A
/// look that reads the clock is also drawn in every state at 00:01 and 23:59 of that day.
func prove(
    _ spec: Spec, images: [Spec.AssetID: Data], today: Today, sandbox: Sandbox, stopAtFirstFailure: Bool
) async throws(EngineError) -> (renders: [ProofRender], verdict: String?) {
    let today = today.noon
    var renders: [ProofRender] = []
    var cells: [Cell] = []
    var verdict: String?
    /// Runs one render, lists it (a passing one only when `listsPass`), and returns its line.
    func record(
        _ state: String, _ family: Family, _ appearance: Appearance = .light, listsPass: Bool = true,
        _ render: () async throws(ProofStop) -> Proof
    ) async throws(EngineError) -> String? {
        let outcome: Result<Proof, Rejected>
        do throws(ProofStop) {
            outcome = .success(try await render())
        } catch {
            switch error {
            case .rejected(let line): outcome = .failure(Rejected(line: line))
            case .broken(let message): throw EngineError(message: "the proof could not run: \(message)")
            }
        }
        let line: String?
        switch outcome {
        case .success(let proof): line = proof.verdict
        case .failure(let rejected): line = rejected.line
        }
        if listsPass || line != nil {
            renders.append(ProofRender(state: state, family: family, appearance: appearance, outcome: outcome))
        }
        return line
    }
    for state in ProofState.all(of: spec) {
        for family in Family.allCases {
            let line = try await record(state.name, family) { () throws(ProofStop) in
                let cell = try await proveCell(
                    spec, images: images, state: state, family: family, size: family.standardSize, today: today,
                    sandbox: sandbox)
                cells.append(cell)
                return cell.proof
            }
            verdict = verdict ?? line
            if verdict != nil, stopAtFirstFailure { return (renders, verdict) }
        }
    }
    for (appearance, states) in appearanceCells {
        for state in states {
            for family in Family.allCases {
                guard let cell = cells.first(where: { $0.state.name == state && $0.family == family }) else { continue }
                let line = try await record(state, family, appearance) { () throws(ProofStop) in
                    try await proveAppearance(cell, appearance)
                }
                verdict = verdict ?? line
                if verdict != nil, stopAtFirstFailure { return (renders, verdict) }
            }
        }
    }
    // A look that reads the clock may draw something else at another hour, such as "Good morning" before
    // noon, so it is also drawn at the day's first and last minute. Those renders are listed only when they
    // fail, so a passing proof keeps the same matrix.
    if cells.contains(where: \.composition.readsClock) {
        for instant in [today.dayStart.addingTimeInterval(60), today.nextDayStart.addingTimeInterval(-60)] {
            let other = Today.at(instant, like: today)
            for state in ProofState.all(of: spec) {
                let timed = ProofState(
                    name: "\(state.name) at \(other.time)", label: "\(state.label) at \(other.time)",
                    sample: state.sample)
                for family in Family.allCases {
                    let line = try await record(timed.name, family, listsPass: false) { () throws(ProofStop) in
                        try await proveCell(
                            spec, images: images, state: timed, family: family, size: family.standardSize,
                            today: other, sandbox: sandbox
                        ).proof
                    }
                    guard let line else { continue }
                    verdict = verdict ?? line
                    if stopAtFirstFailure { return (renders, verdict) }
                }
            }
        }
    }
    if verdict == nil { verdict = uncovered(spec, cells: cells) }
    if verdict == nil { verdict = await unshown(spec, cells: cells, sandbox: sandbox) }
    return (renders, verdict)
}

/// One cell of the proof matrix: seed a scratch store with the state through the real write path, run
/// `composeDrawing` with the proof budget, render with `FaceHost.still` and a `GeometryProbe` in the
/// environment, measure, and encode the PNG.
@MainActor
func proveCell(
    _ spec: Spec, images: [Spec.AssetID: Data], state: ProofState, family: Family, size: CGSize, today: Today,
    sandbox: Sandbox
) async throws(ProofStop) -> Cell {
    let store: RowStore
    let widget = WidgetKey.mint()
    do throws(StoreError) {
        store = try RowStore.scratch()
        try store.bind(tablesOf: spec, to: widget)
        try store.seed(state.sample, widget: widget, today: today)
    } catch {
        throw .broken("the scratch store failed: \(error.message)")
    }
    let decoded = AssetImages.inMemory(images)
    let clock = ContinuousClock()
    let started = clock.now
    let composition: Composition
    do throws(Diagnostic) {
        composition = try await composeDrawing(
            spec: spec, widget: widget, revision: Bindings.unsaved, store: store, images: decoded, family: family,
            size: size,
            pixelScale: renderScale,
            today: today, sandbox: sandbox, budget: .proof)
    } catch {
        throw .rejected(state.prefix(family) + error.line)
    }
    let composed = clock.now
    let probe = GeometryProbe()
    let image = try draw(composition.drawing, .light, probe: probe)
    guard let png = encodePNG(image) else { throw .broken("the renderer produced no image") }
    let fit = analyze(
        probe, drawing: composition.drawing, image: image, imagePixels: decoded.decodedPixels,
        lookMilliseconds: milliseconds(composed - started), renderMilliseconds: milliseconds(clock.now - composed))
    let verdict = verdict(for: fit, size: size).map { state.prefix(family) + $0 }
    return Cell(
        state: state, family: family, size: size, today: today, proof: Proof(png: png, fit: fit, verdict: verdict),
        composition: composition)
}

/// The cells drawn again in another appearance, by state name, after the light matrix.
private let appearanceCells: [(Appearance, [String])] = [(.tinted, ["empty", "full"]), (.dark, ["full"])]

/// A light cell's tree drawn again in `appearance`. The look never learns the appearance, so the tree and its
/// layout are the light cell's; only the pixels change. Runs the blank check, and for tinted the cover check,
/// and keeps the light cell's fit report otherwise.
@MainActor
func proveAppearance(_ cell: Cell, _ appearance: Appearance) throws(ProofStop) -> Proof {
    let clock = ContinuousClock()
    let started = clock.now
    let image = try draw(cell.composition.drawing, appearance, probe: nil)
    guard let png = encodePNG(image) else { throw .broken("the renderer produced no image") }
    let ink = inkShare(image)
    let cover = appearance == .tinted ? coverShare(image, backdrop: Palette.backdrop) : nil
    let fit = cell.proof.fit.redrawn(ink: ink, cover: cover, renderMilliseconds: milliseconds(clock.now - started))
    let verdict = appearanceVerdict(for: fit, appearance).map { cell.state.prefix(cell.family, appearance) + $0 }
    return Proof(png: png, fit: fit, verdict: verdict)
}

/// One render at `renderScale` with `FaceHost.still`, in the appearance's rendering mode and color scheme.
/// Tinted uses the light scheme, so a color pair's light value gives the opacity.
@MainActor
private func draw(_ drawing: Drawing, _ appearance: Appearance, probe: GeometryProbe?) throws(ProofStop) -> CGImage {
    let renderer = ImageRenderer(
        content: DrawingView(drawing: drawing, host: .still)
            .environment(\.geometryProbe, probe)
            .environment(\.colorScheme, appearance == .dark ? .dark : .light)
            .environment(\.renderingMode, appearance == .tinted ? .accented : .fullColor))
    renderer.scale = renderScale
    renderer.proposedSize = ProposedViewSize(drawing.size)
    guard let image = renderer.cgImage else { throw .broken("the renderer produced no image") }
    return image
}

/// Coverage: in each family, every action has a button in at least one state, so a repair cannot pass by
/// dropping a button everywhere.
func uncovered(_ spec: Spec, cells: [Cell]) -> String? {
    for family in Family.allCases {
        let pressed = Set(cells.filter { $0.family == family }.flatMap(\.composition.drawing.taps).map(\.action))
        if let action = spec.actions.first(where: { !pressed.contains($0.id.raw) }) {
            return
                "\(family.rawValue): action \(Diagnostic.quote(action.id.raw)) has no button in any data state; keep a button for every action"
        }
    }
    return nil
}

/// The content check: every query changes what the widget shows in at least one state and family, so a
/// repair cannot pass by dropping the data it was asked to show. For each query, the look runs again on a
/// passing render's results with that query emptied (zero for a number, or one when it was zero; null for a
/// row; an empty list), and the query counts as shown when the tree changes or the look fails. `full` cells go
/// first, since every query has data there.
func unshown(_ spec: Spec, cells: [Cell], sandbox: Sandbox) async -> String? {
    for query in spec.queries {
        var shown = false
        for cell in cells.reversed() {
            guard let result = cell.composition.results[query.id], let emptied = result.emptied else { continue }
            var results = cell.composition.results
            results[query.id] = emptied
            let context = lookContext(
                results: results, spec: spec, family: cell.family, size: cell.size, today: cell.today)
            do throws(Sandbox.Failure) {
                shown = try await sandbox.run(spec.look, context: context, budget: .proof) != cell.composition.tree
            } catch {
                shown = true
            }
            if shown { break }
        }
        if !shown {
            return
                "no render shows query \(Diagnostic.quote(query.id.raw)): the widget looks the same in every state and size whatever it returns; show its data again (smaller, or fewer rows, if space is short), or remove the query if the widget does not need it"
        }
    }
    return nil
}

extension QueryResult {
    /// The same answer with nothing in it, or nil when it already has nothing. A number always changes: to
    /// zero, or to one when it was zero.
    fileprivate var emptied: QueryResult? {
        switch self {
        case .number(let number): .number(number == 0 ? 1 : 0)
        case .row(let row): row == nil ? nil : .row(nil)
        case .rows(let rows): rows.isEmpty ? nil : .rows([])
        case .days(let days): days.isEmpty ? nil : .days([])
        }
    }
}

private func milliseconds(_ duration: Duration) -> Double {
    let components = duration.components
    return ((Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15) * 10).rounded() / 10
}
