import Foundation
import Spec
import SwiftUI
import Synchronization
import Testing
import WidgetEngine

/// Renders a tree on the default white background.
@MainActor private func pixels(_ tree: String, family: Family = .small) async throws -> Bitmap {
    Bitmap(render(try await drawing(tree, spec: mistakeSpec, family: family, images: ["photo": quadrants])))
}

@MainActor private func photo(_ tree: String) async throws -> Bitmap {
    Bitmap(render(try await drawing(tree, spec: mistakeSpec, images: ["photo": landscape])))
}

private func isGray(_ pixel: (r: Int, g: Int, b: Int)) -> Bool {
    max(pixel.r, pixel.g, pixel.b) - min(pixel.r, pixel.g, pixel.b) < 12
}

private func near(_ pixel: (r: Int, g: Int, b: Int), _ r: Int, _ g: Int, _ b: Int) -> Bool {
    abs(pixel.r - r) < 24 && abs(pixel.g - g) < 24 && abs(pixel.b - b) < 24
}

/// One tree per node kind, each drawing something visible on white.
private let everyKind: [(String, String)] = [
    (
        "vstack",
        "{ type: 'vstack', spacing: 4, children: [{ type: 'rect', fill: '#FF0000', frame: { width: 60, height: 20 } }, { type: 'rect', fill: '#0000FF', frame: { width: 60, height: 20 } }] }"
    ),
    (
        "hstack",
        "{ type: 'hstack', spacing: 4, children: [{ type: 'rect', fill: '#FF0000', frame: { width: 20, height: 60 } }, { type: 'rect', fill: '#0000FF', frame: { width: 20, height: 60 } }] }"
    ),
    (
        "zstack",
        "{ type: 'zstack', children: [{ type: 'rect', fill: '#0000FF', frame: { width: 80, height: 80 } }, { type: 'circle', fill: '#FFFF00', frame: { width: 40, height: 40 } }] }"
    ),
    ("text", "{ type: 'text', value: 'Hello', size: 34, weight: 'bold', color: '#222222' }"),
    ("symbol", "{ type: 'symbol', name: 'star.fill', size: 60, color: '#FF9500' }"),
    ("rect", "{ type: 'rect', cornerRadius: 12, fill: '#3366FF', frame: { width: 90, height: 60 } }"),
    ("circle", "{ type: 'circle', fill: '#3366FF', frame: { width: 80, height: 80 } }"),
    ("capsule", "{ type: 'capsule', fill: '#3366FF', frame: { width: 100, height: 40 } }"),
    ("ellipse", "{ type: 'ellipse', fill: '#3366FF', frame: { width: 100, height: 60 } }"),
    (
        "path",
        "{ type: 'path', d: 'M 50 0 L 100 100 L 0 100 Z', viewBox: [0, 0, 100, 100], fill: '#34C759', frame: { width: 90, height: 90 } }"
    ),
    (
        "path with arcs and curves",
        "{ type: 'path', d: 'M10 50 A40 40 0 1 1 90 50 Q50 90 10 50 z', viewBox: [0, 0, 100, 100], stroke: { color: '#AF52DE', width: 4 }, frame: { width: 90, height: 90 } }"
    ),
    ("image", "{ type: 'image', asset: 'photo', frame: { width: 100, height: 100 } }"),
    (
        "button",
        "{ type: 'button', action: 'drink', children: [{ type: 'rect', fill: '#FF2D55', frame: { width: 60, height: 60 } }] }"
    ),
]

@Suite @MainActor struct RendererTests {
    @Test(arguments: everyKind.map(\.0))
    func eachNodeKindDraws(_ kind: String) async throws {
        let tree = try #require(everyKind.first { $0.0 == kind }?.1)
        let blank = try await pixels("{ type: 'spacer' }")
        #expect(try await pixels(tree).difference(blank) > 0.02)
    }

    @Test func aSpacerPushesItsSiblings() async throws {
        let pushed = try await pixels(
            "{ type: 'hstack', frame: { maxWidth: 'infinity' }, children: [{ type: 'rect', fill: '#FF0000', frame: { width: 20, height: 20 } }, { type: 'spacer' }] }"
        )
        let centered = try await pixels(
            "{ type: 'hstack', frame: { maxWidth: 'infinity' }, children: [{ type: 'rect', fill: '#FF0000', frame: { width: 20, height: 20 } }] }"
        )
        #expect(near(pushed.pixel(10, 79), 255, 0, 0))
        #expect(near(centered.pixel(10, 79), 255, 255, 255))
        #expect(near(centered.pixel(79, 79), 255, 0, 0))
    }

    @Test(arguments: ["'dashed'", "'dotted'", "[10, 6]"])
    func dashedAndDottedStrokesBreakTheLine(_ dash: String) async throws {
        let ring = "{ type: 'circle', stroke: { color: '#000000', width: 6%@ }, frame: { width: 120, height: 120 } }"
        let solid = try await pixels(ring.replacingOccurrences(of: "%@", with: ""))
        let broken = try await pixels(ring.replacingOccurrences(of: "%@", with: ", dash: \(dash)"))
        #expect(broken.difference(solid) > 0.004)
    }

    @Test func blendModesBlendWithWhatIsBehind() async throws {
        let stack =
            "{ type: 'zstack', children: [{ type: 'rect', fill: '#0000FF', frame: { width: 100, height: 100 } }, { type: 'rect', fill: '#FF0000', frame: { width: 100, height: 100 }%@ }] }"
        #expect(near(try await pixels(stack.replacingOccurrences(of: "%@", with: "")).pixel(79, 79), 255, 0, 0))
        #expect(
            near(
                try await pixels(stack.replacingOccurrences(of: "%@", with: ", blend: 'multiply'")).pixel(79, 79), 0, 0,
                0))
        #expect(
            near(
                try await pixels(stack.replacingOccurrences(of: "%@", with: ", blend: 'screen'")).pixel(79, 79), 255, 0,
                255))
    }

    @Test func saturationZeroMakesAPhotoGray() async throws {
        let image = "{ type: 'image', asset: 'photo', frame: { width: 150, height: 150 }%@ }"
        #expect(!isGray(try await photo(image.replacingOccurrences(of: "%@", with: "")).pixel(79, 40)))
        #expect(isGray(try await photo(image.replacingOccurrences(of: "%@", with: ", saturation: 0")).pixel(79, 40)))
    }

    @Test func brightnessLightensAPhoto() async throws {
        let image = "{ type: 'image', asset: 'photo', frame: { width: 150, height: 150 }%@ }"
        let plain = try await photo(image.replacingOccurrences(of: "%@", with: "")).pixel(79, 130)
        let bright = try await photo(image.replacingOccurrences(of: "%@", with: ", brightness: 0.4")).pixel(79, 130)
        #expect(bright.r + bright.g + bright.b > plain.r + plain.g + plain.b + 150)
    }

    @Test func contrastZeroFlattensAPhoto() async throws {
        let image = "{ type: 'image', asset: 'photo', frame: { width: 150, height: 150 }%@ }"
        let flat = try await photo(image.replacingOccurrences(of: "%@", with: ", contrast: 0"))
        let plain = try await photo(image.replacingOccurrences(of: "%@", with: ""))
        #expect(!near(plain.pixel(79, 20), plain.pixel(79, 140).r, plain.pixel(79, 140).g, plain.pixel(79, 140).b))
        #expect(near(flat.pixel(79, 20), flat.pixel(79, 140).r, flat.pixel(79, 140).g, flat.pixel(79, 140).b))
    }

    @Test func blurSoftensAnImage() async throws {
        let image = "{ type: 'image', asset: 'photo', frame: { width: 120, height: 120 }%@ }"
        let sharp = try await pixels(image.replacingOccurrences(of: "%@", with: ""))
        let soft = try await pixels(image.replacingOccurrences(of: "%@", with: ", blur: 8"))
        #expect(soft.difference(sharp) > 0.02)
    }

    @Test func cropPicksThePartOfTheImage() async throws {
        let crop = "{ type: 'image', asset: 'photo', crop: %@, frame: { width: 100, height: 100 } }"
        #expect(
            near(
                try await pixels(crop.replacingOccurrences(of: "%@", with: "[0, 0, 0.5, 0.5]")).pixel(79, 79), 255, 0, 0
            ))
        #expect(
            near(
                try await pixels(crop.replacingOccurrences(of: "%@", with: "[0.5, 0.5, 0.5, 0.5]")).pixel(79, 79), 255,
                255, 0))
    }

    @Test func fitShowsTheWholeImageAndFillCoversTheFrame() async throws {
        let image = "{ type: 'image', asset: 'photo', mode: '%@', frame: { width: 100, height: 100 } }"
        let fit = try await pixels(image.replacingOccurrences(of: "%@", with: "fit"))
        let fill = try await pixels(image.replacingOccurrences(of: "%@", with: "fill"))
        #expect(near(fit.pixel(79, 35), 255, 255, 255))
        #expect(near(fit.pixel(35, 60), 255, 0, 0))
        #expect(near(fill.pixel(45, 35), 255, 0, 0))
        #expect(near(fill.pixel(110, 35), 0, 255, 0))
        #expect(near(fill.pixel(110, 120), 255, 255, 0))
    }

    @Test func aNamedFontChangesTheType() async throws {
        let text = "{ type: 'text', value: 'Water the plants', size: 20%@ }"
        let system = try await pixels(text.replacingOccurrences(of: "%@", with: ""))
        let chalk = try await pixels(text.replacingOccurrences(of: "%@", with: ", fontName: 'Chalkduster'"))
        #expect(chalk.difference(system) > 0.01)
    }

    @Test func weightPicksAFaceOfANamedFont() async throws {
        let text =
            "{ type: 'text', value: 'Water the plants', size: 20, fontName: 'Avenir Next Condensed', weight: '%@' }"
        let regular = try await pixels(text.replacingOccurrences(of: "%@", with: "regular"))
        let heavy = try await pixels(text.replacingOccurrences(of: "%@", with: "heavy"))
        #expect(heavy.difference(regular) > 0.01)
    }

    @Test func aGradientMaskFadesANode() async throws {
        let rect = "{ type: 'rect', fill: '#FF0000', frame: { width: 120, height: 120 }%@ }"
        let plain = try await pixels(rect.replacingOccurrences(of: "%@", with: ""))
        let faded = try await pixels(
            rect.replacingOccurrences(
                of: "%@",
                with: ", mask: { gradient: 'linear', stops: ['#000000FF', '#00000000'], from: 'top', to: 'bottom' }"))
        #expect(near(plain.pixel(79, 135), 255, 0, 0))
        #expect(near(faded.pixel(79, 135), 255, 235, 235) || faded.pixel(79, 135).g > 200)
        #expect(near(faded.pixel(79, 22), 255, 0, 0) || faded.pixel(79, 22).g < 40)
    }

    @Test func theWidgetBackgroundCanBeANode() async throws {
        let colored = try await pixels("{ type: 'spacer', widgetBackground: '#112233' }")
        let drawn = try await pixels(
            "{ type: 'spacer', widgetBackground: { type: 'zstack', children: [{ type: 'rect', fill: '#112233' }, { type: 'circle', fill: '#FFCC00', frame: { width: 60, height: 60 } }] } }"
        )
        #expect(near(colored.pixel(79, 79), 0x11, 0x22, 0x33))
        #expect(near(drawn.pixel(79, 79), 0xFF, 0xCC, 0x00))
        #expect(near(drawn.pixel(20, 79), 0x11, 0x22, 0x33))
    }

    @Test func buttonsReachTheHostWithTheirActionAndRow() async throws {
        let seen = Mutex<[String]>([])
        let host = FaceHost(
            button: { tap, label in
                seen.withLock { $0.append("run \(tap.action) \(tap.row ?? "-")") }
                return label
            },
            form: { tap, label in
                seen.withLock { $0.append("form \(tap.action) \(tap.row ?? "-")") }
                return label
            },
            root: FaceHost.still.root)
        let look = """
            function render(ctx) {
              const d = ctx.data;
              return { type: 'hstack', children: [
                { type: 'button', action: 'undo', rowId: d.last.id, children: [{ type: 'symbol', name: 'minus' }] },
                { type: 'button', action: 'drink', children: [{ type: 'symbol', name: 'plus' }] },
                { type: 'button', action: 'add', children: [{ type: 'symbol', name: 'square.and.pencil' }] },
              ] };
            }
            """
        let drawing = try await compose(
            look, context: context(mistakeData, family: .small),
            bindings: bindings(mistakeSpec, rows: receivedRows(mistakeData, spec: mistakeSpec))
        ).get()
        _ = render(drawing, host: host)
        #expect(Set(seen.withLock { $0 }) == ["run undo glass-1", "run drink -", "form add -"])
    }

    @Test func theProbeReportsFramesInWidgetSpace() async throws {
        let drawing = try await drawing(
            "{ type: 'vstack', spacing: 10, children: [{ type: 'rect', fill: '#000000', frame: { width: 40, height: 40 } }, { type: 'text', value: 'Hi', cornerRadius: 4 }] }"
        )
        let probe = GeometryProbe()
        _ = render(drawing, probe: probe)
        let square = try #require(probe.frames["root.children[0]"])
        #expect(abs(square.width - 40) < 0.5 && abs(square.height - 40) < 0.5)
        #expect(abs(square.midX - 79) < 0.5)
        #expect(probe.textSizes["root.children[1]"] != nil)
        #expect(probe.clips["root.children[1]"] != nil)
        let root = try #require(probe.rootSize)
        #expect(abs(root.width - 40) < 0.5 && root.height > 50)
    }

    @Test func theFallbackFaceIsCalmAndDrawn() async throws {
        let renderer = ImageRenderer(content: FaceView(.placeholder, host: .still).frame(width: 158, height: 158))
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        let bitmap = Bitmap(image)
        #expect(near(bitmap.pixel(20, 20), 28, 28, 31))
        #expect(
            bitmap.difference(Bitmap(render(try await drawing("{ type: 'spacer', widgetBackground: '#1C1C1F' }"))))
                > 0.005)
    }
}

/// The rendering modes: color pairs by color scheme, and tinted mode as the renderer emulates it.
@Suite @MainActor struct RenderingModeTests {
    private func shown(
        _ tree: String, mode: RenderingMode = .fullColor, scheme: ColorScheme = .light, host: FaceHost = .still
    ) async throws -> Bitmap {
        let drawing = try await drawing(tree, spec: mistakeSpec, images: ["photo": quadrants])
        return Bitmap(render(drawing, host: host, mode: mode, scheme: scheme))
    }

    private let backdrop = (r: 33, g: 36, b: 41)
    private let tint = (r: 255, g: 179, b: 64)

    @Test func aColorPairFollowsTheColorSchemeInFillsTextAndGradientStops() async throws {
        let solid = "{ type: 'rect', fill: { light: '#FF0000', dark: '#0000FF' }, frame: { width: 60, height: 60 } }"
        #expect(near(try await shown(solid).pixel(79, 79), 255, 0, 0))
        #expect(near(try await shown(solid, scheme: .dark).pixel(79, 79), 0, 0, 255))
        let gradient =
            "{ type: 'rect', fill: { gradient: 'linear', stops: [{ light: '#FF0000', dark: '#0000FF' }, { color: { light: '#FF0000', dark: '#0000FF' }, at: 1 }] }, frame: { width: 60, height: 60 } }"
        #expect(near(try await shown(gradient).pixel(79, 79), 255, 0, 0))
        #expect(near(try await shown(gradient, scheme: .dark).pixel(79, 79), 0, 0, 255))
        let text =
            "{ type: 'symbol', name: 'square.fill', size: 80, color: { light: '#000000', dark: '#FFFFFF' }, widgetBackground: '#808080' }"
        #expect(near(try await shown(text).pixel(79, 79), 0, 0, 0))
        #expect(near(try await shown(text, scheme: .dark).pixel(79, 79), 255, 255, 255))
    }

    @Test func tintedModeDrawsOneColorAtEachNodesOpacityOnTheBackdrop() async throws {
        let tree = """
            { type: 'hstack', spacing: 0, widgetBackground: '#FF0000', children: [
              { type: 'rect', fill: '#0000FF', frame: { width: 40, height: 40 } },
              { type: 'rect', fill: '#00FF00', opacity: 0.5, frame: { width: 40, height: 40 } },
              { type: 'rect', fill: '#123456', accent: true, frame: { width: 40, height: 40 } },
            ] }
            """
        let tinted = try await shown(tree, mode: .accented)
        #expect(near(tinted.pixel(20, 20), backdrop.r, backdrop.g, backdrop.b))
        #expect(near(tinted.pixel(39, 79), 255, 255, 255))
        #expect(near(tinted.pixel(79, 79), 144, 146, 148))
        #expect(near(tinted.pixel(119, 79), tint.r, tint.g, tint.b))
        let full = try await shown(tree)
        #expect(near(full.pixel(20, 20), 255, 0, 0))
        #expect(near(full.pixel(39, 79), 0, 0, 255))
    }

    @Test func anAccentNodeTintsItsLayersAndChildren() async throws {
        let tree =
            "{ type: 'zstack', accent: true, background: '#00FF00', frame: { width: 80, height: 80 }, children: [{ type: 'symbol', name: 'square.fill', size: 30, color: '#000000' }] }"
        let tinted = try await shown(tree, mode: .accented)
        #expect(near(tinted.pixel(45, 45), tint.r, tint.g, tint.b))
        #expect(near(tinted.pixel(79, 79), tint.r, tint.g, tint.b))
        let own = try await shown(
            "{ type: 'symbol', name: 'square.fill', size: 80, color: '#000000', accent: true }", mode: .accented)
        #expect(near(own.pixel(79, 79), tint.r, tint.g, tint.b), "the node's own color, not only its children")
    }

    @Test func imagesFollowTheirTintInTintedMode() async throws {
        // Red top left, green top right, blue bottom left, yellow bottom right.
        let image = "{ type: 'image', asset: 'photo', frame: { width: 158, height: 158 }%@ }"
        func tinted(_ tint: String) async throws -> Bitmap {
            try await shown(image.replacingOccurrences(of: "%@", with: tint), mode: .accented)
        }
        let gray = try await tinted("")
        #expect(isGray(gray.pixel(40, 40)) && isGray(gray.pixel(120, 120)))
        #expect(near(try await tinted(", tint: 'fullColor'").pixel(40, 40), 255, 0, 0))
        let accented = try await tinted(", tint: 'accented'")
        let bright = accented.pixel(120, 120)
        let dark = accented.pixel(40, 120)
        #expect(near(bright, tint.r, tint.g, tint.b), "yellow is bright, so nearly the full tint: \(bright)")
        #expect(dark.r < 120 && dark.r > backdrop.r - 10, "blue is dark, so a faint tint: \(dark)")
        let full = try await shown(image.replacingOccurrences(of: "%@", with: ", tint: 'accented'"))
        #expect(near(full.pixel(40, 40), 255, 0, 0), "tint changes nothing in full color")
    }

    @Test func accentAndImageTintReachTheHost() async throws {
        let seen = Mutex<[String]>([])
        let host = FaceHost(
            button: FaceHost.still.button, form: FaceHost.still.form, root: FaceHost.still.root,
            accent: { content in
                seen.withLock { $0.append("accent") }
                return content
            },
            tint: { tint, image in
                seen.withLock { $0.append("image \(tint.rawValue)") }
                return AnyView(image)
            })
        _ = try await shown(
            "{ type: 'vstack', children: [{ type: 'text', value: 'Hi', accent: true }, { type: 'image', asset: 'photo', tint: 'fullColor', frame: { width: 40, height: 40 } }] }",
            host: host)
        #expect(Set(seen.withLock { $0 }) == ["accent", "image fullColor"])
    }

    @Test func theFallbackFaceDrawsOnTheBackdropInTintedMode() async throws {
        let renderer = ImageRenderer(
            content: FaceView(.placeholder, host: .still).frame(width: 158, height: 158)
                .environment(\.renderingMode, .accented))
        renderer.scale = 2
        let bitmap = Bitmap(try #require(renderer.cgImage))
        #expect(near(bitmap.pixel(20, 20), backdrop.r, backdrop.g, backdrop.b))
        #expect(
            bitmap.difference(Bitmap(render(try await drawing("{ type: 'spacer' }"), mode: .accented))) > 0.005,
            "it draws its symbol and name on the backdrop")
    }
}
