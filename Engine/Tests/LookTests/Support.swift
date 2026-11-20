import CoreGraphics
import Foundation
import ImageIO
import Sandbox
import Spec
import SwiftUI
import Testing
import WidgetEngine

let engineDirectory = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()

let artifacts = engineDirectory.appending(path: ".artifacts/look")

/// The look language's sizes, in points.
func size(_ family: Family) -> CGSize {
    family == .small ? CGSize(width: 158, height: 158) : CGSize(width: 338, height: 158)
}

/// Wednesday 2026-11-18, in a week that starts on Monday.
let today = Day(iso: "2026-11-18")!

func fixture(_ name: String) throws -> Spec {
    try Spec.parse(Data(contentsOf: engineDirectory.appending(path: "Fixtures/\(name)/widget.json")))
}

func document(_ json: String) throws -> Spec { try Spec.parse(Data(json.utf8)) }

/// A row as the look receives it: `{ id, day, daysAgo, ...fields }`.
func row(_ id: String, daysAgo: Int = 0, _ fields: [String: JSONValue] = [:]) -> JSONValue {
    var members = fields
    members["id"] = .string(id)
    members["day"] = .string(today.adding(-daysAgo).iso)
    members["daysAgo"] = .number(Double(daysAgo))
    return .object(members)
}

/// A `daily` result: one entry per count, oldest first and today last.
func daily(_ counts: [Int]) -> JSONValue {
    .array(
        counts.enumerated().map { index, count in
            let day = today.adding(index - counts.count + 1)
            return .object([
                "date": .string(day.iso), "weekday": .string(day.weekday.short), "count": .number(Double(count)),
            ])
        })
}

/// `ctx` as JSON text, in the documented shape.
func context(_ data: [String: JSONValue], family: Family) -> String {
    let week = (0..<7).map { JSONValue.string(today.adding($0 - 2).iso) }
    let ctx = JSONValue.object([
        "data": .object(data), "family": .string(family.rawValue),
        "width": .number(Double(size(family).width)), "height": .number(Double(size(family).height)),
        "today": .object(["date": .string(today.iso), "weekday": .string(today.weekday.short), "week": .array(week)]),
    ])
    return String(decoding: ctx.encoded(), as: UTF8.self)
}

/// The row ids in `data`, under the table of the query that returned them.
func receivedRows(_ data: [String: JSONValue], spec: Spec) -> [Spec.TableID: Set<String>] {
    var rows: [Spec.TableID: Set<String>] = [:]
    for query in spec.queries {
        let values: [JSONValue] =
            switch data[query.id.raw] {
            case .array(let items)?: items
            case .object?: [data[query.id.raw]!]
            default: []
            }
        for case .object(let members) in values {
            if case .string(let id)? = members["id"] { rows[query.shape.table, default: []].insert(id) }
        }
    }
    return rows
}

func bindings(
    _ spec: Spec, family: Family = .small, rows: [Spec.TableID: Set<String>] = [:],
    images: [String: Data] = [:]
) -> Bindings {
    let assets = Dictionary(
        uniqueKeysWithValues: images.compactMap { key, bytes in spec.asset(named: key).map { ($0.id, bytes) } })
    return Bindings(
        widget: WidgetID(rawValue: "w1"), spec: spec, rows: rows, today: today, images: .inMemory(assets),
        family: family, size: size(family), pixelScale: 2)
}

/// Runs a look and validates its tree: the drawing, or the one line a model would get back.
func compose(_ look: String, context json: String, bindings: Bindings) async -> Result<Drawing, Diagnostic> {
    do throws(Sandbox.Failure) {
        let tree = try await Sandbox().run(look, context: json, budget: .widget)
        do throws(Diagnostic) {
            return .success(try Drawing.parse(tree: tree, bindings: bindings))
        } catch {
            return .failure(error)
        }
    } catch {
        return .failure(Diagnostic(error.line))
    }
}

/// Validates a tree written as a JavaScript expression, through the sandbox like a real look.
func drawing(
    _ tree: String, spec: Spec = plainSpec, family: Family = .small, rows: [Spec.TableID: Set<String>] = [:],
    images: [String: Data] = [:]
) async throws -> Drawing {
    try await compose(
        "function render(ctx) { return \(tree); }", context: context([:], family: family),
        bindings: bindings(spec, family: family, rows: rows, images: images)
    ).get()
}

let plainSpec = try! document(#"{"name": "Plain", "look": "function render() { return { type: 'spacer' }; }"}"#)

// MARK: Pixels

@MainActor func render(_ drawing: Drawing, host: FaceHost = .still, probe: GeometryProbe? = nil) -> CGImage {
    let renderer = ImageRenderer(
        content: DrawingView(drawing: drawing, host: host)
            .environment(\.geometryProbe, probe)
            .environment(\.colorScheme, .light))
    renderer.scale = 2
    renderer.proposedSize = ProposedViewSize(drawing.size)
    return renderer.cgImage!
}

struct Bitmap {
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

    /// The color at a point given in points (the render is at 2x), from the top left.
    func pixel(_ x: Double, _ y: Double) -> (r: Int, g: Int, b: Int) {
        let index = (Int(y * 2) * width + Int(x * 2)) * 4
        return (Int(bytes[index]), Int(bytes[index + 1]), Int(bytes[index + 2]))
    }

    /// The share of pixels whose color differs noticeably between two renders of the same size.
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
}

func png(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

/// A 200 x 100 picture in four solid quadrants: red, green on top; blue, yellow below.
let quadrants: Data = {
    let context = CGContext(
        data: nil, width: 200, height: 100, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let fills: [(CGRect, CGColor)] = [
        (CGRect(x: 0, y: 50, width: 100, height: 50), CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)),
        (CGRect(x: 100, y: 50, width: 100, height: 50), CGColor(srgbRed: 0, green: 1, blue: 0, alpha: 1)),
        (CGRect(x: 0, y: 0, width: 100, height: 50), CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)),
        (CGRect(x: 100, y: 0, width: 100, height: 50), CGColor(srgbRed: 1, green: 1, blue: 0, alpha: 1)),
    ]
    for (rect, color) in fills {
        context.setFillColor(color)
        context.fill(rect)
    }
    return png(context.makeImage()!)
}()

/// A soft photo-like picture: a sky gradient over a dark hill, so color adjustments have something to change.
let landscape: Data = {
    let context = CGContext(
        data: nil, width: 300, height: 200, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let sky = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            CGColor(srgbRed: 0.98, green: 0.62, blue: 0.35, alpha: 1),
            CGColor(srgbRed: 0.35, green: 0.45, blue: 0.85, alpha: 1),
        ]
            as CFArray, locations: [0, 1])!
    context.drawLinearGradient(sky, start: CGPoint(x: 0, y: 60), end: CGPoint(x: 0, y: 200), options: [])
    context.setFillColor(CGColor(srgbRed: 0.12, green: 0.22, blue: 0.16, alpha: 1))
    context.addEllipse(in: CGRect(x: -80, y: -120, width: 460, height: 220))
    context.fillPath()
    return png(context.makeImage()!)
}()

func writeArtifact(_ image: CGImage, _ name: String) throws {
    try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
    try png(image).write(to: artifacts.appending(path: "\(name).png"))
}

extension JSONValue: ExpressibleByIntegerLiteral, ExpressibleByStringLiteral, ExpressibleByArrayLiteral,
    ExpressibleByBooleanLiteral
{
    package init(integerLiteral value: Int) { self = .number(Double(value)) }
    package init(stringLiteral value: String) { self = .string(value) }
    package init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
    package init(booleanLiteral value: Bool) { self = .bool(value) }
}
