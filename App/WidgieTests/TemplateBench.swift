import CoreGraphics
import Foundation
import SwiftUI
import Synchronization
import Testing
import Vision
import WidgetBuilder
import WidgetEngine

@testable import Widgie

/// One bundled template in a scratch engine of its own, with rows the test gives, so a test can tap its face
/// at a chosen time and read what the face then shows, as a person would.
@MainActor final class TemplateBench {
    let template: Template
    let family: Family
    let engine = Engine.scratch()
    private let widget: WidgetID

    /// `rows` in the grammar of one `samples` entry, or nil for the template's first sample.
    init(_ id: String, family: Family? = nil, rows: String? = nil, at date: Date) throws {
        template = try Template.bundled(id)
        self.family = family ?? template.family
        widget = try engine.stageProved(template.source(), at: date)
        if let rows {
            let file = FileManager.default.temporaryDirectory.appending(path: "rows-\(UUID().uuidString).json")
            defer { try? FileManager.default.removeItem(at: file) }
            try Data(rows.utf8).write(to: file)
            try engine.load(.file(file), into: widget, at: date)
        }
    }

    func face(at date: Date) async -> Face {
        await engine.face(for: widget, family: family, size: family.standardSize, at: date).current
    }

    /// The actions of the buttons the face offers, found the way the widget finds them: by drawing it with a
    /// host that sees every button.
    func actions(at date: Date) async -> [String] {
        taps(on: await face(at: date), family).map(\.action)
    }

    /// Presses the face's button for `action` at `date`, with `input` for a button that opens a form.
    func tap(_ action: String, at date: Date, input: [String: InputValue] = [:]) async throws {
        let tap = try #require(
            taps(on: await face(at: date), family).first { $0.action == action }, "no \(action) button")
        try engine.perform(tap, input: input, at: date)
    }

    func picture(at date: Date) async -> Bitmap {
        Bitmap(render(FaceView(await face(at: date), host: .still), family))
    }

    /// The words the face shows, read off its picture by text recognition, in one string. How recognition splits
    /// them into lines varies, so a test looks for words in it rather than for whole lines.
    func text(at date: Date) async throws -> String {
        var request = RecognizeTextRequest()
        request.usesLanguageCorrection = false
        let observations = try await request.perform(on: render(FaceView(await face(at: date), host: .still), family))
        return observations.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
    }
}

/// The taps of the buttons `face` offers, found the way the widget finds them: by drawing it with a host that
/// sees every button.
@MainActor func taps(on face: Face, _ family: Family) -> [Tap] {
    let seen = Mutex<[Tap]>([])
    let host = FaceHost(
        button: { tap, label in
            seen.withLock { $0.append(tap) }
            return label
        },
        form: { tap, label in
            seen.withLock { $0.append(tap) }
            return label
        },
        root: FaceHost.still.root)
    _ = render(FaceView(face, host: host), family)
    var unique: [Tap] = []
    for tap in seen.withLock({ $0 }) where !unique.contains(tap) { unique.append(tap) }
    return unique
}

@MainActor private func render(_ view: some View, _ family: Family) -> CGImage {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
    renderer.scale = 3
    renderer.proposedSize = ProposedViewSize(family.standardSize)
    return renderer.cgImage!
}

/// A moment in the test's calendar, the one the engine counts days in.
func moment(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
    Calendar.autoupdatingCurrent.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
}

extension Date {
    func adding(minutes: Int) -> Date { addingTimeInterval(Double(minutes) * 60) }
}

/// A picture's pixels, to tell whether two faces look the same.
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

    /// Fewer than one pixel in a thousand differs noticeably, which allows for edge pixels the renderer draws a
    /// level apart from one run to the next.
    func looksLike(_ other: Bitmap) -> Bool {
        guard width == other.width, height == other.height else { return false }
        var differing = 0
        for index in stride(from: 0, to: bytes.count, by: 4) {
            let delta =
                abs(Int(bytes[index]) - Int(other.bytes[index]))
                + abs(Int(bytes[index + 1]) - Int(other.bytes[index + 1]))
                + abs(Int(bytes[index + 2]) - Int(other.bytes[index + 2]))
            if delta > 24 { differing += 1 }
        }
        return Double(differing) / Double(width * height) < 0.001
    }
}
