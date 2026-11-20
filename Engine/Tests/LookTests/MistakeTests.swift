import Foundation
import Spec
import Testing
import WidgetEngine

/// A widget with a list of items, the latest glass of water, an action of every row use, and one asset.
let mistakeSpec = try! document(
    #"""
    {
      "name": "Mistakes",
      "look": "function render() { return { type: 'spacer' }; }",
      "tables": { "items": { "fields": { "title": "text", "done": "bool" } }, "glasses": { "fields": {} } },
      "queries": {
        "open": { "list": "items", "window": "all", "limit": 5 },
        "last": { "latest": "glasses", "window": "today" }
      },
      "actions": {
        "toggle": { "toggle": "items.done" },
        "drink": { "insert": "glasses" },
        "undo": { "delete": "glasses" },
        "add": { "form": "items", "fields": ["title"] },
        "late": { "insertOn": "glasses" }
      },
      "assets": { "photo": { "about": "a mountain lake at dusk" } }
    }
    """#)

let mistakeData: [String: JSONValue] = [
    "open": [row("item-1", ["title": "Milk", "done": false])], "last": row("glass-1"),
]

/// A look and the exact line the model gets back for it.
struct Mistake: Sendable, CustomTestStringConvertible {
    let name: String
    let look: String
    let line: String

    var testDescription: String { name }

    /// `tree` is the expression `render` returns; `d` is `ctx.data`.
    init(_ name: String, returning tree: String, _ line: String) {
        self.init(name, look: "function render(ctx) {\n  const d = ctx.data;\n  return \(tree);\n}", line)
    }

    init(_ name: String, look: String, _ line: String) {
        self.name = name
        self.look = look
        self.line = line
    }

    static let all: [Mistake] = [
        Mistake(
            "unknown node", returning: "{ type: 'vstack', children: [{ type: 'label', value: 'Hi' }] }",
            #"node at root.children[0]: unknown type "label" (types: vstack, hstack, zstack, spacer, text, symbol, rect, circle, capsule, ellipse, path, image, button)"#
        ),
        Mistake(
            "unknown prop", returning: "{ type: 'vstack', children: [{ type: 'text', value: 'Hi', font: 'Futura' }] }",
            #"text at root.children[0]: unknown prop "font" (text props: value, size, weight, design, italic, color, lineLimit, minScale, align, strikethrough, kerning, fontName; common props: aspectRatio, padding, frame, background, overlay, cornerRadius, clip, mask, opacity, shadow, blur, scale, rotation, offset, blend)"#
        ),
        Mistake(
            "bad color", returning: "{ type: 'text', value: 'Hi', color: 'red' }",
            ##"text at root: "color" must be a hex color like "#RRGGBB" or "#RRGGBBAA", not the string "red""##),
        Mistake(
            "bad nested color",
            returning: "{ type: 'circle', stroke: { color: '#FFF', width: 2 }, frame: { width: 20, height: 20 } }",
            ##"circle at root: "stroke.color" must be a hex color like "#RRGGBB" or "#RRGGBBAA", not the string "#FFF""##
        ),
        Mistake(
            "button naming a missing action",
            returning: "{ type: 'button', action: 'refill', children: [{ type: 'symbol', name: 'plus' }] }",
            #"button at root: no action "refill" (actions: add, drink, late, toggle, undo)"#),
        Mistake(
            "missing row id",
            returning: "{ type: 'button', action: 'undo', children: [{ type: 'symbol', name: 'minus' }] }",
            #"button at root: action "undo" needs "rowId": the id of the row it deletes"#),
        Mistake(
            "missing row id for a toggle",
            returning: "{ type: 'button', action: 'toggle', children: [{ type: 'symbol', name: 'circle' }] }",
            #"button at root: action "toggle" needs "rowId": the id of the row whose "done" it flips"#),
        Mistake(
            "unknown row id",
            returning:
                "{ type: 'button', action: 'toggle', rowId: 'item-9', children: [{ type: 'symbol', name: 'circle' }] }",
            #"button at root: "rowId" "item-9" is not the id of a row the look received (items rows come from: open); use a row's id field"#
        ),
        Mistake(
            "row id from another table",
            returning:
                "{ type: 'button', action: 'toggle', rowId: d.last.id, children: [{ type: 'symbol', name: 'circle' }] }",
            #"button at root: "rowId" "glass-1" is not the id of a row the look received (items rows come from: open); use a row's id field"#
        ),
        Mistake(
            "row id on an insert",
            returning:
                "{ type: 'button', action: 'drink', rowId: d.last.id, children: [{ type: 'symbol', name: 'plus' }] }",
            #"button at root: action "drink" adds a new row, so it takes no "rowId""#),
        Mistake(
            "insertOn without a day",
            returning: "{ type: 'button', action: 'late', children: [{ type: 'symbol', name: 'plus' }] }",
            #"button at root: action "late" needs "day": the date it adds a row on, like "2026-11-18" (take dates from ctx.today or a daily entry)"#
        ),
        Mistake(
            "a day on an insert",
            returning:
                "{ type: 'button', action: 'drink', day: ctx.today.date, children: [{ type: 'symbol', name: 'plus' }] }",
            #"button at root: action "drink" does not write to a chosen day, so it takes no "day"; use an insertOn action to add a row on another day"#
        ),
        Mistake(
            "a day that is not a date",
            returning:
                "{ type: 'button', action: 'late', day: 'yesterday', children: [{ type: 'symbol', name: 'plus' }] }",
            #"button at root: "day" must be a date as "YYYY-MM-DD", like "2026-11-18", not "yesterday""#
        ),
        Mistake(
            "a button inside a button",
            returning:
                "{ type: 'button', action: 'drink', children: [{ type: 'button', action: 'add', children: [{ type: 'spacer' }] }] }",
            #"button at root.children[0]: is inside another button; a button cannot hold a button"#),
        Mistake(
            "unknown asset", returning: "{ type: 'image', asset: 'sunset' }",
            #"image at root: no asset "sunset" (assets: photo)"#),
        Mistake(
            "font outside the allowlist", returning: "{ type: 'text', value: 'Hi', fontName: 'Comic Sans' }",
            #"text at root: "fontName" must be one of Bradley Hand, Noteworthy, Marker Felt, Chalkduster, Snell Roundhand, American Typewriter, Rockwell, DIN Condensed, Avenir Next Condensed, Futura, Copperplate, Didot, not the string "Comic Sans""#
        ),
        Mistake(
            "unknown symbol", returning: "{ type: 'symbol', name: 'flame.fil' }",
            #"symbol at root: "name" is "flame.fil", which is not an SF Symbol here; use a real name such as "plus", "flame.fill", or "checkmark.circle.fill""#
        ),
        Mistake(
            "too many nodes",
            returning: "{ type: 'vstack', children: Array.from({ length: 2000 }, () => ({ type: 'spacer' })) }",
            #"node at root.children[1999]: the tree has more than 2000 nodes; draw fewer, for example fewer rows or grid cells"#
        ),
        Mistake(
            "nested too deep",
            look:
                "function render() {\n  let node = { type: 'spacer' };\n  for (let i = 0; i < 45; i++) node = { type: 'zstack', children: [node] };\n  return node;\n}",
            #"node at root.children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0].children[0]: is nested more than 40 levels deep; flatten the tree"#
        ),
        Mistake(
            "a root that is not a node", returning: "'hello'",
            #"node at root: must be a node object like {"type": "text", "value": "Hi"}, not the string "hello""#),
        Mistake(
            "a node without a type", returning: "{ type: 'vstack', children: [{ value: 'Hi' }] }",
            #"node at root.children[0]: needs "type" (types: vstack, hstack, zstack, spacer, text, symbol, rect, circle, capsule, ellipse, path, image, button)"#
        ),
        Mistake(
            "a value out of range", returning: "{ type: 'rect', opacity: 1.5 }",
            #"rect at root: "opacity" must be a number from 0 to 1, not the number 1.5"#),
        Mistake(
            "a thrown exception",
            look: "function render(ctx) {\n  const d = ctx.data;\n  return { type: 'text', value: d.today.count };\n}",
            "look threw TypeError: undefined is not an object (evaluating 'd.today.count') (line 3)"),
        Mistake(
            "a missing render", look: "function draw(ctx) { return { type: 'spacer' }; }",
            "look defines no function render(ctx); define it at the top level of the script"),
        Mistake(
            "a clock read",
            look:
                "function render(ctx) {\n  const hour = new Date().getHours();\n  return { type: 'text', value: hour };\n}",
            "look is not pure: Date() reads the clock (line 2); draw from ctx only (ctx.today has the date, and nothing may be random)"
        ),
        Mistake(
            "an endless loop", look: "function render(ctx) {\n  while (true) {}\n}",
            "look ran longer than 250 ms; render(ctx) must finish quickly, so look for an endless loop"),
    ]
}

@Suite struct MistakeTests {
    @Test(arguments: Mistake.all)
    func eachMistakeGetsItsOneLine(_ mistake: Mistake) async {
        let result = await compose(
            mistake.look, context: context(mistakeData, family: .small),
            bindings: bindings(
                mistakeSpec, rows: receivedRows(mistakeData, spec: mistakeSpec), images: ["photo": quadrants]))
        guard case .failure(let error) = result else {
            Issue.record("the look validated, but it should fail with: \(mistake.line)")
            return
        }
        #expect(error.line == mistake.line)
        #expect(!error.line.contains("\n"))
    }

    @Test func theSameButtonsPassWithRealRows() async throws {
        let look = """
            function render(ctx) {
              const d = ctx.data;
              return { type: 'vstack', children: [
                { type: 'button', action: 'toggle', rowId: d.open[0].id, children: [{ type: 'symbol', name: 'circle' }] },
                { type: 'button', action: 'undo', rowId: d.last.id, children: [{ type: 'symbol', name: 'minus' }] },
                { type: 'button', action: 'drink', children: [{ type: 'symbol', name: 'plus' }] },
                { type: 'button', action: 'add', children: [{ type: 'symbol', name: 'plus.circle' }] },
                { type: 'button', action: 'add', rowId: d.open[0].id, children: [{ type: 'symbol', name: 'pencil' }] },
                ctx.today.week.map(day => ({ type: 'button', action: 'late', day: day,
                  children: [{ type: 'symbol', name: 'clock' }] })),
                { type: 'button', action: 'late', day: '2025-11-17', children: [{ type: 'symbol', name: 'clock' }] },
              ] };
            }
            """
        let drawing = try await compose(
            look, context: context(mistakeData, family: .small),
            bindings: bindings(mistakeSpec, rows: receivedRows(mistakeData, spec: mistakeSpec))
        ).get()
        #expect(
            drawing.taps == [
                Tap(widget: "w1", action: "toggle", row: "item-1"), Tap(widget: "w1", action: "undo", row: "glass-1"),
                Tap(widget: "w1", action: "drink", row: nil), Tap(widget: "w1", action: "add", row: nil),
                Tap(widget: "w1", action: "add", row: "item-1"),
                Tap(widget: "w1", action: "late", row: nil, day: "2026-11-16"),
                Tap(widget: "w1", action: "late", row: nil, day: "2026-11-17"),
                Tap(widget: "w1", action: "late", row: nil, day: "2026-11-18"),
            ], "days after today and more than a year back draw without a tap")
    }

    @Test func childrenFlattenAndSkipEmptyEntries() async throws {
        let drawing = try await drawing(
            "{ type: 'vstack', children: [[{ type: 'spacer' }, [{ type: 'spacer' }]], null, false, 0, '', undefined, { type: 'spacer' }] }"
        )
        guard case .vstack(_, _, let children) = drawing.root.kind else {
            Issue.record("the root is not a vstack")
            return
        }
        #expect(children.map(\.path) == ["root.children[0]", "root.children[1]", "root.children[2]"])
    }
}
