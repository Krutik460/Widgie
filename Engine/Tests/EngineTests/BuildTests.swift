import CoreGraphics
import Foundation
import ImageIO
import Testing
import WidgetBuilder
import WidgetEngine

/// Looks that each fail exactly one check, and only in the cell the test names.
enum Broken {
    /// Draws one bar per tap, up to 30, so `full` spills and the sample does not.
    static let spills = document(
        look: counterLook(
            "{ type: 'vstack', spacing: 4, children: Array.from({ length: Math.min(ctx.data.n, 30) }, () => ({ type: 'rect', fill: '#FFFFFF', frame: { width: 60, height: 12 } })) }"
        ))

    /// A sentence in a box one line tall, with no lineLimit to make the cut intended.
    static let cutsText = document(
        look: counterLook(
            extra:
                "{ type: 'text', value: 'Hello there friend', size: 15, color: '#FFFFFF', frame: { width: 40, height: 20 } },"
        ))

    /// One word with a lineLimit and a minScale in a box too narrow for it, so the ellipsis lands inside the word.
    static let squeezesWord = document(
        look: counterLook(
            extra:
                "{ type: 'text', value: 'Monstera', size: 15, color: '#FFFFFF', lineLimit: 1, minScale: 0.7, frame: { width: 30 } },"
        ))

    /// A sentence that ends in an ellipsis after its first words, as a to-do title does.
    static let endsInEllipsis = document(
        look: counterLook(
            extra:
                "{ type: 'text', value: 'Book flights for the wedding', size: 15, color: '#FFFFFF', lineLimit: 1, frame: { width: 90 } },"
        ))

    /// White on the default white background.
    static let blank = document(
        look: """
            function render(ctx) {
              return { type: 'vstack', children: [
                { type: 'text', value: String(ctx.data.n), color: '#FFFFFF' },
                { type: 'button', action: 'add', children: [{ type: 'symbol', name: 'plus', color: '#FFFFFF' }] },
              ] };
            }
            """)

    /// The backdrop as a full-size rect instead of `widgetBackground`, with an accent button on it. Tinted mode
    /// turns the rect into one white sheet that hides the white count; only the accent plus shows.
    static let backdropShape = document(look: backdropLook(plusAccent: true))

    /// The same, with nothing in the accent group, so tinted mode shows only the white sheet.
    static let backdropShapeHidesAll = document(look: backdropLook(plusAccent: false))

    /// A background that turns white in dark mode under white text.
    static let blankInDark = document(
        look: counterLook().replacing(
            "widgetBackground: '#102030'", with: "widgetBackground: { light: '#102030', dark: '#FFFFFF' }"))

    private static func backdropLook(plusAccent: Bool) -> String {
        """
        function render(ctx) {
          return { type: 'zstack', frame: { maxWidth: 'infinity', maxHeight: 'infinity' }, children: [
            { type: 'rect', fill: '#102030' },
            { type: 'vstack', spacing: 8, children: [
              { type: 'text', value: String(ctx.data.n), size: 30, weight: 'bold', color: '#FFFFFF', lineLimit: 1, minScale: 0.5 },
              { type: 'button', action: 'add', children: [
                { type: 'symbol', name: 'plus.circle.fill', size: 30, color: '#FFFFFF', accent: \(plusAccent) }] },
            ] },
          ] };
        }
        """
    }
}

@Suite struct RejectionTests {
    @Test func aDocumentThatDoesNotParse() async throws {
        let line = try await Scratch().line(WidgetSource(json: Data(#"{"name": "Counter", "look": "#.utf8)))
        #expect(line.contains("JSON"), "\(line)")
        let missing = try await Scratch().line(WidgetSource(json: Data(#"{"name": "Counter"}"#.utf8)))
        #expect(missing.hasPrefix("missing \"look\""), "\(missing)")
    }

    @Test func aLookThatThrowsInTheEmptyState() async throws {
        let source = document(
            look: counterLook("{ type: 'text', value: ctx.data.last.id, color: '#FFFFFF' }"),
            queries: ["n": ["count": "taps", "window": "all"], "last": ["latest": "taps", "window": "all"]])
        let line = try await Scratch().line(source)
        #expect(line.hasPrefix("small, empty: look threw TypeError"), "\(line)")
    }

    @Test func aLookThatSpillsInTheFullState() async throws {
        let line = try await Scratch().line(Broken.spills)
        #expect(line.hasPrefix("small, full: content spills"), "\(line)")
        #expect(line.contains("past the top edge") || line.contains("past the bottom edge"), "\(line)")
        #expect(
            line.hasSuffix(
                "make things smaller or show fewer rows so everything fits in 158pt of height, and keep every button"),
            "\(line)")
    }

    @Test func cutText() async throws {
        let line = try await Scratch().line(Broken.cutsText)
        #expect(line.hasPrefix("small, empty: text \"Hello there friend\" at root.children[1] needs "), "\(line)")
        #expect(line.contains(" lines but has room for 1 ("), "\(line)")
    }

    @Test func anEllipsisInsideTheFirstWordIsCut() async throws {
        let line = try await Scratch().line(Broken.squeezesWord)
        #expect(line.hasPrefix("small, empty: text \"Monstera\" at root.children[1] does not fit the "), "\(line)")
        #expect(line.contains("not even its first word"), "\(line)")
    }

    @Test func anEllipsisAfterTheFirstWordIsAccepted() async throws {
        _ = try await Scratch().build(Broken.endsInEllipsis)
    }

    @Test func aBlankRender() async throws {
        let line = try await Scratch().line(Broken.blank)
        #expect(line == "small, empty: the render is blank; check colors against the background")
    }

    @Test func aBackdropDrawnAsAFullSizeShapeIsRejectedInTintedMode() async throws {
        let line = try await Scratch().line(Broken.backdropShape)
        #expect(line.hasPrefix("small, empty, tinted: "), "\(line)")
        #expect(
            line.hasSuffix(
                "% of the render is one flat color in tinted mode, so a full-size shape draws the backdrop and hides what sits on it; move that color to the root's widgetBackground"
            ), "\(line)")
        let cover = try #require(
            try await Engine.proof(Broken.backdropShape, family: .small, appearance: .tinted, calendar: utc).fit.cover)
        #expect(cover > 0.8, "far above the 0.5 limit; the four fixtures stay under 0.25")
    }

    @Test func aRenderBlankInTintedModeNamesTheBackdrop() async throws {
        let line = try await Scratch().line(Broken.backdropShapeHidesAll)
        #expect(
            line
                == "small, empty, tinted: the render is blank in tinted mode, which drops widgetBackground and draws every color white at its own opacity; put the backdrop in widgetBackground, not in a full-size shape, and show state through opacity or shape"
        )
    }

    @Test func aRenderBlankInDarkModeNamesTheColorPairs() async throws {
        let line = try await Scratch().line(Broken.blankInDark)
        #expect(
            line
                == "small, full, dark: the render is blank in dark mode; check the dark value of each { light, dark } color against the background"
        )
    }

    @Test func anActionWithNoButton() async throws {
        let source = document(
            look: counterLook().replacing(
                "{ type: 'button', action: 'add', children: [{ type: 'symbol', name: 'plus', size: 20, color: '#FFFFFF' }] },",
                with: ""))
        let line = try await Scratch().line(source)
        #expect(line == "small: action \"add\" has no button in any data state; keep a button for every action")
    }

    @Test func aLookThatNeverReadsADeclaredQuery() async throws {
        let source = document(
            look: counterLook(),
            queries: ["n": ["count": "taps", "window": "all"], "today": ["count": "taps", "window": "today"]])
        let line = try await Scratch().line(source)
        #expect(line.hasPrefix("no render shows query \"today\""), "\(line)")
    }

    @Test func aRunawayLook() async throws {
        let line = try await Scratch().line(document(look: "function render(ctx) { while (true) {} }"))
        #expect(line.hasPrefix("small, empty: look ran longer than 500 steps"), "\(line)")
    }

    @Test func aRefinementThatChangesASurvivingFieldsKind() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(
            document(look: counterLook(), tables: ["taps": ["fields": ["note": "text"]]]))
        let line = try await scratch.line(
            document(look: counterLook(), tables: ["taps": ["fields": ["note": "number"]]]), replacing: id)
        #expect(line == "field \"taps.note\" was text and is now number; keep the kind or use a new field id")
    }

    @Test func aRefinementThatRenamesATableIsRejectedWithOneLine() async throws {
        let scratch = Scratch()
        let water = try fixture("water")
        let id = try await scratch.build(water)
        let cups = WidgetSource(
            json: Data(String(decoding: water.json, as: UTF8.self).replacing("\"glasses\"", with: "\"cups\"").utf8))
        let line = try await scratch.line(cups, replacing: id)
        #expect(line == "table \"glasses\" is gone; keep every table id so the stored rows carry over")
        #expect(try scratch.engine.history(of: id).count == 1)
    }

    @Test @MainActor func aColorOnlyRefinementKeepsTheRows() async throws {
        let scratch = Scratch()
        let water = try fixture("water")
        let id = try await scratch.build(water)
        for _ in 0..<3 {
            try scratch.engine.perform(try button("drink", on: await scratch.face(id)).tap, at: morning)
        }
        let blue = WidgetSource(
            json: Data(String(decoding: water.json, as: UTF8.self).replacing("#0B2A3C", with: "#1B3A8C").utf8))
        _ = try await scratch.build(blue, replacing: id)
        let three = #"{"glasses": [{"daysAgo": 0, "repeat": 3}]}"#
        #expect(picture(await scratch.face(id)).looksLike(try await expected(blue, rows: three)))
        #expect(!picture(await scratch.face(id)).looksLike(try await expected(water, rows: three)))
    }

    @Test @MainActor func aRefinementThatStopsShowingATableKeepsItsRows() async throws {
        let scratch = Scratch()
        let both = document(
            look: counterLook(
                "{ type: 'text', value: ctx.data.n + ' ' + ctx.data.m, size: 30, color: '#FFFFFF', lineLimit: 1, minScale: 0.5 }",
                extra:
                    "{ type: 'button', action: 'miss', children: [{ type: 'symbol', name: 'minus', size: 20, color: '#FFFFFF' }] },"
            ),
            tables: ["taps": ["fields": [:] as [String: Any]], "misses": ["fields": [:] as [String: Any]]],
            queries: ["n": ["count": "taps", "window": "all"], "m": ["count": "misses", "window": "all"]],
            actions: ["add": ["insert": "taps"], "miss": ["insert": "misses"]])
        let id = try await scratch.build(both)
        try scratch.engine.perform(try button("miss", on: await scratch.face(id)).tap, at: morning)
        let hidden = document(
            look: counterLook(),
            tables: ["taps": ["fields": [:] as [String: Any]], "misses": ["fields": [:] as [String: Any]]])
        _ = try await scratch.build(hidden, replacing: id)
        _ = try await scratch.build(both, replacing: id)
        #expect(
            picture(await scratch.face(id)).looksLike(try await expected(both, rows: #"{"misses": [{"daysAgo": 0}]}"#)))
    }

    @Test func everyLineIsOneLine() async throws {
        for source in [Broken.spills, Broken.cutsText, Broken.blank, Broken.backdropShape, Broken.blankInDark] {
            let line = try await Scratch().line(source)
            #expect(!line.contains("\n") && !line.isEmpty)
        }
    }
}

@Suite struct ProofTests {
    @Test func theProofVerdictIsTheBuildLine() async throws {
        let water = try fixture("water")
        _ = try await Scratch().build(water)
        #expect(try await Engine.proofs(water, at: morning, calendar: utc).verdict == nil)
        #expect(try await Engine.proof(water, state: .full, family: .small, at: morning, calendar: utc).verdict == nil)

        let cases: [(WidgetSource, DataState)] = [
            (Broken.spills, .full), (Broken.cutsText, .empty), (Broken.blank, .empty),
        ]
        for (source, state) in cases {
            let line = try await Scratch().line(source)
            #expect(try await Engine.proof(source, state: state, family: .small, calendar: utc).verdict == line)
            #expect(try await Engine.proofs(source, calendar: utc).verdict == line)
        }
        let appearances: [(WidgetSource, DataState, Appearance)] = [
            (Broken.backdropShape, .empty, .tinted), (Broken.blankInDark, .full, .dark),
        ]
        for (source, state, appearance) in appearances {
            let line = try await Scratch().line(source)
            #expect(
                try await Engine.proof(source, state: state, family: .small, appearance: appearance, calendar: utc)
                    .verdict == line)
            #expect(try await Engine.proofs(source, calendar: utc).verdict == line)
            #expect(try await Engine.proof(source, state: state, family: .small, calendar: utc).verdict == nil)
        }
    }

    /// A mood that only the two buttons write is always one emoji, so a slot one emoji wide passes. Once a form
    /// lets the person type a mood, the full state writes long text there and the same slot is cut.
    @Test func theFullStateWritesOnlyValuesTheWidgetCanStore() async throws {
        let mood = counterLook(
            "{ type: 'text', value: ctx.data.last ? ctx.data.last.mood : '-', size: 15, frame: { width: 24, height: 24 } }",
            extra:
                "{ type: 'button', action: 'sad', children: [{ type: 'symbol', name: 'minus', size: 20, color: '#FFFFFF' }] },"
        )
        func source(sad: [String: Any]) -> WidgetSource {
            document(
                look: mood, tables: ["moods": ["fields": ["mood": "text"]]],
                queries: ["last": ["latest": "moods", "window": "all"]],
                actions: ["add": ["insert": "moods", "values": ["mood": "🙂"]], "sad": sad],
                samples: ["some": ["moods": [["mood": "🙁"]]]])
        }
        _ = try await Scratch().build(source(sad: ["insert": "moods", "values": ["mood": "🙁"]]))
        let line = try await Scratch().line(source(sad: ["form": "moods", "fields": ["mood"]]))
        #expect(line.hasPrefix("small, full: text \"Water the plants on the balcony"), "\(line)")
    }

    @Test func aProofMatrixRendersEveryCellEvenAfterAFailure() async throws {
        let matrix = try await Engine.proofs(Broken.blank, at: morning, calendar: utc)
        #expect(
            matrix.renders.map { "\($0.state) \($0.family.rawValue) \($0.appearance.rawValue)" } == [
                "empty small light", "empty medium light", "some small light", "some medium light",
                "full small light", "full medium light", "empty small tinted", "empty medium tinted",
                "full small tinted", "full medium tinted", "full small dark", "full medium dark",
            ])
        #expect(matrix.verdict == "small, empty: the render is blank; check colors against the background")
    }
}

@Suite struct RevisionTests {
    @Test func buildingTheSameSourceTwiceKeepsOneRevision() async throws {
        let scratch = Scratch()
        let water = try fixture("water")
        let id = try await scratch.build(water)
        #expect(try await scratch.build(water, replacing: id) == id)
        let history = try scratch.engine.history(of: id)
        #expect(history.count == 1)
        let other = try await scratch.build(water)
        #expect(other != id)
        #expect(try scratch.engine.history(of: other).map(\.id) == history.map(\.id))
    }

    @Test @MainActor func aRefinementAddsARevisionAndRestoreBringsTheOldLookBack() async throws {
        let scratch = Scratch()
        let water = try fixture("water")
        let id = try await scratch.build(water)
        let original = try #require(try scratch.engine.source(of: id))
        let before = picture(await scratch.face(id))

        let bluer = WidgetSource(
            json: Data(String(decoding: water.json, as: UTF8.self).replacing("#0B2A3C", with: "#1B3A8C").utf8))
        let commits = scratch.commits
        _ = try await scratch.build(bluer, replacing: id)
        #expect(scratch.commits == commits + 1)
        let history = try scratch.engine.history(of: id)
        #expect(history.count == 2)
        #expect(!picture(await scratch.face(id)).looksLike(before))

        try scratch.engine.restore(id, to: history[1])
        #expect(picture(await scratch.face(id)).looksLike(before))
        #expect(try scratch.engine.source(of: id)?.json == original.json)
        #expect(try scratch.engine.history(of: id).first == history[1])
    }

    /// The proof draws on the main actor, so while this test holds the main actor the refinement waits there,
    /// past its checks, and the delete lands during its proof.
    @Test @MainActor func aWidgetDeletedWhileItsRefinementIsProvedStaysDeletedAndTheBuildThrows() async throws {
        let scratch = Scratch()
        let id = try await scratch.build(document(look: counterLook()))
        let blue = document(look: counterLook().replacing("#102030", with: "#1B3A8C"))
        let refinement = Task.detached { try await scratch.engine.build(blue, replacing: id) }
        usleep(500_000)
        try scratch.engine.delete(id)

        await #expect(throws: EngineError.self) { try await refinement.value }
        #expect(try scratch.engine.widgets().isEmpty)
        #expect(try scratch.engine.source(of: id) == nil)
    }

    @Test func theSourceRoundTripsToTheSameBytes() async throws {
        let scratch = Scratch()
        for name in fixtureNames {
            let id = try await scratch.build(try fixture(name))
            let source = try #require(try scratch.engine.source(of: id))
            let copy = try await scratch.build(source)
            #expect(try scratch.engine.source(of: copy)?.json == source.json, "\(name)")
            #expect(try scratch.engine.history(of: copy).map(\.id) == scratch.engine.history(of: id).map(\.id))
        }
    }

    @Test func imagesAreDownscaledStoredAndRoundTrip() async throws {
        let scratch = Scratch()
        let look = counterLook(
            "{ type: 'image', asset: 'photo', frame: { maxWidth: 'infinity', maxHeight: 'infinity' }, cornerRadius: 12 }",
            extra: "{ type: 'text', value: String(ctx.data.n), color: '#FFFFFF', lineLimit: 1 },")
        let source = document(
            look: look, assets: ["photo": ["about": "a sunset"]], images: ["photo": photo(3000, 2000)])
        let id = try await scratch.build(source)
        let stored = try #require(try scratch.engine.source(of: id))
        let bytes = try #require(stored.images["photo"])
        let image = try #require(CGImageSourceCreateWithData(bytes as CFData, nil))
        #expect(CGImageSourceGetType(image) as String? == "public.jpeg")
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == 1080)
        #expect(properties[kCGImagePropertyPixelHeight] as? Int == 720)

        let copy = try await scratch.build(stored)
        #expect(try scratch.engine.history(of: copy).map(\.id) == scratch.engine.history(of: id).map(\.id))
        let unlisted = try await scratch.line(
            document(look: look, assets: ["photo": ["about": "a sunset"]], images: ["photo": bytes, "extra": bytes]))
        #expect(unlisted.hasPrefix("image \"extra\" has no entry in \"assets\""), "\(unlisted)")
        let missing = try await scratch.line(document(look: look, assets: ["photo": ["about": "a sunset"]]))
        #expect(missing.hasPrefix("asset \"photo\" has no image"), "\(missing)")
    }

    /// Each distinct crop of an asset is its own decode, so ten crops of one photo pass the 1.5 megapixel
    /// budget of one render, and the image that would cross it fails the look.
    @Test func manyDistinctCropsFailTheImageBudget() async throws {
        let source = document(
            look: counterLook(extra: croppedPhotos), assets: ["photo": ["about": "a sunset"]],
            images: ["photo": photo(3000, 2000)])
        await #expect(throws: Rejected.self) {
            try await Engine.proof(source, family: .small, at: morning, calendar: utc)
        }
        do throws(Rejected) {
            _ = try await Engine.proof(source, family: .small, at: morning, calendar: utc)
        } catch {
            #expect(
                error.line.hasPrefix("small, empty: image at root.children[")
                    && error.line.hasSuffix(
                        ": images decode to more than 1.5 megapixels in this render; draw fewer images, or fewer distinct crops of one asset, since each crop decodes again at the widget's size"
                    ), "\(error.line)")
        }
    }
}

/// Ten images of one asset, each a different half of it.
let croppedPhotos =
    "[0, 1, 2, 3, 4, 5, 6, 7, 8, 9].map(i => ({ type: 'image', asset: 'photo', crop: [i * 0.05, 0, 0.5, 0.5], frame: { width: 8, height: 8 } })),"

/// An opaque gradient, as a camera photo would be.
func photo(_ width: Int, _ height: Int) -> Data {
    let context = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
    let gradient = CGGradient(
        colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
        colors: [
            CGColor(srgbRed: 0.98, green: 0.6, blue: 0.3, alpha: 1),
            CGColor(srgbRed: 0.2, green: 0.3, blue: 0.7, alpha: 1),
        ]
            as CFArray, locations: [0, 1])!
    context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: height), options: [])
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, context.makeImage()!, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}
