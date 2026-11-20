import CoreGraphics
import Foundation
import ImageIO
import SwiftUI
import Synchronization
import Testing
import WidgetBuilder
import WidgetEngine

let engineDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

/// UTC with weeks from Monday, so no test depends on the machine.
let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 2
    return calendar
}()

func instant(_ text: String) -> Date { try! Date(text, strategy: .iso8601) }

/// Wednesday 2026-11-18, 09:00 UTC.
let morning = instant("2026-11-18T09:00:00Z")

let fixtureNames = ["habit", "todo", "water", "wotd"]

func fixture(_ name: String) throws -> WidgetSource {
    try WidgetSource(directory: engineDirectory.appending(path: "Fixtures/\(name)"))
}

/// An engine on a fresh directory that counts its commits. The directory goes when this does.
final class Scratch: Sendable {
    let directory = FileManager.default.temporaryDirectory.appending(path: "engine-tests-\(UUID().uuidString)")
    let engine: Engine
    private let counter: Counter

    init() {
        let counter = Counter()
        self.counter = counter
        engine = Engine(directory: directory, calendar: utc, onCommit: { counter.value.withLock { $0 += 1 } })
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    var commits: Int { counter.value.withLock { $0 } }

    func build(_ source: WidgetSource, replacing: WidgetID? = nil) async throws -> WidgetID {
        let outcome = try await engine.build(source, replacing: replacing)
        guard case .saved(let id) = outcome else {
            Issue.record("expected the widget to save, got \(outcome)")
            throw Unexpected()
        }
        return id
    }

    func line(_ source: WidgetSource, replacing: WidgetID? = nil) async throws -> String {
        let outcome = try await engine.build(source, replacing: replacing)
        guard case .rejected(let line) = outcome else {
            Issue.record("expected a rejection, got \(outcome)")
            throw Unexpected()
        }
        return line
    }

    func face(_ id: WidgetID, _ family: Family = .small, at date: Date = morning) async -> Face {
        await engine.faces(for: id, family: family, size: family.standardSize, from: date).current
    }

    private final class Counter: Sendable {
        let value = Mutex(0)
    }
}

struct Unexpected: Error {}

/// A button a face offers, as the host receives it: a tap that runs in place, or one that opens a form.
struct Offered: Hashable {
    let tap: Tap
    let opensForm: Bool
}

/// The buttons a face offers, found the way the widget finds them: by rendering it with a host.
@MainActor func buttons(_ face: Face, _ family: Family = .small) -> [Offered] {
    let seen = Mutex<[Offered]>([])
    let host = FaceHost(
        button: { tap, label in
            seen.withLock { $0.append(Offered(tap: tap, opensForm: false)) }
            return label
        },
        form: { tap, label in
            seen.withLock { $0.append(Offered(tap: tap, opensForm: true)) }
            return label
        },
        root: FaceHost.still.root)
    _ = image(FaceView(face, host: host), family)
    var unique: [Offered] = []
    for offered in seen.withLock({ $0 }) where !unique.contains(offered) { unique.append(offered) }
    return unique
}

@MainActor func button(_ action: String, on face: Face, _ family: Family = .small) throws -> Offered {
    try #require(buttons(face, family).first { $0.tap.action == action }, "no \(action) button on the face")
}

/// What the user sees: the face at 3x in light mode, as the proof renders it.
@MainActor func picture(_ face: Face, _ family: Family = .small) -> Bitmap {
    Bitmap(image(FaceView(face, host: .still), family))
}

@MainActor private func image(_ view: some View, _ family: Family) -> CGImage {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
    renderer.scale = 3
    renderer.proposedSize = ProposedViewSize(family.standardSize)
    return renderer.cgImage!
}

/// The proof of `source` with exactly these rows, in the samples grammar: what a face built from them must
/// look like.
func expected(
    _ source: WidgetSource, rows: String, _ family: Family = .small, at date: Date = morning
) async throws -> Bitmap {
    let file = FileManager.default.temporaryDirectory.appending(path: "state-\(UUID().uuidString).json")
    try Data(rows.utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let proof = try await Engine.proof(source, state: .file(file), family: family, at: date, calendar: utc)
    return try Bitmap(png: proof.png)
}

struct Bitmap: Equatable {
    let width: Int
    let height: Int
    let bytes: [UInt8]

    init(_ image: CGImage) {
        width = image.width
        height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = CGContext(
            data: &bytes, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        self.bytes = bytes
    }

    init(png: Data) throws {
        let source = try #require(CGImageSourceCreateWithData(png as CFData, nil))
        self.init(try #require(CGImageSourceCreateImageAtIndex(source, 0, nil)))
    }

    /// The share of pixels whose color differs noticeably.
    func difference(_ other: Bitmap) -> Double {
        guard width == other.width, height == other.height else { return 1 }
        var differing = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let delta =
                abs(Int(bytes[index]) - Int(other.bytes[index]))
                + abs(Int(bytes[index + 1]) - Int(other.bytes[index + 1]))
                + abs(Int(bytes[index + 2]) - Int(other.bytes[index + 2]))
            if delta > 24 { differing += 1 }
        }
        return Double(differing) / Double(width * height)
    }

    func looksLike(_ other: Bitmap) -> Bool { difference(other) < 0.001 }
}

/// A widget document from parts, so each test states only what it is about.
func document(
    name: String = "Counter", look: String, tables: [String: Any] = ["taps": ["fields": [:] as [String: Any]]],
    queries: [String: Any] = ["n": ["count": "taps", "window": "all"]],
    actions: [String: Any] = ["add": ["insert": "taps"]],
    samples: [String: Any] = ["some": ["taps": [["daysAgo": 0, "repeat": 2]]]],
    assets: [String: Any] = [:], images: [String: Data] = [:]
) -> WidgetSource {
    let object: [String: Any] = [
        "name": name, "tables": tables, "queries": queries, "actions": actions, "samples": samples,
        "assets": assets, "look": look,
    ]
    return WidgetSource(json: try! JSONSerialization.data(withJSONObject: object), images: images)
}

/// A look that passes every check: the count, and a button for `add`. `body` replaces the count's node.
func counterLook(
    _ body: String =
        "{ type: 'text', value: String(ctx.data.n), size: 30, weight: 'bold', color: '#FFFFFF', lineLimit: 1, minScale: 0.5 }",
    extra: String = ""
) -> String {
    """
    function render(ctx) {
      return { type: 'vstack', spacing: 8, padding: 14, frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
        widgetBackground: '#102030',
        children: [
          \(body),
          \(extra)
          { type: 'button', action: 'add', children: [{ type: 'symbol', name: 'plus', size: 20, color: '#FFFFFF' }] },
        ] };
    }
    """
}
