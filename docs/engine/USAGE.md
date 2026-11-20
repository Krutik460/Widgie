# Usage

Written before the types. The types in `Engine/Sources/` are derived from these call sites.

One object, `Engine`, does everything. What a caller can do with it depends on what it imports:

| Import | Adds to `Engine` | Who imports it |
|---|---|---|
| `WidgetEngine` | `init(directory:calendar:onCommit:)`, `faces(for:family:size:from:)`, `perform(_:input:at:)`, `form(for:)`, `widgets()`, `delete(_:)`, plus `FaceView` and `FaceHost` | app, widget extension (through `WidgetHosting`) |
| `WidgetBuilder` | `build(_:replacing:)`, `source(of:)`, `history(of:)`, `restore(_:to:)`, `Engine.proof(_:state:family:...)`, `Engine.proofs(_:at:calendar:)` | app, render tool |
| `WidgetHosting` | `Hosting.engine`, `Hosting.formURL(for:)`, `Hosting.formTap(from:)`, the `RunAction` intent, the widget configuration, `FaceHost.widget` | app, widget extension |

The widget extension never imports `WidgetBuilder`, so it cannot build, ingest images, or encode PNGs. That is a link-time fact, not a convention.

No call site below touches SQL, the JavaScript engine, the tree vocabulary, or the typed blocks. Those live behind `package` access in targets the app cannot call into. The only format a caller ever handles is the exchange JSON, and only as bytes it passes through.

## 1. Widget timeline provider

Lives in `WidgetHosting`. Given a widget id and a size, produce the SwiftUI view. One engine call.

```swift
import SwiftUI
import WidgetKit
import AppIntents
import WidgetEngine

public enum Hosting {
    /// One engine per process. The app and the extension each make their own; both open the same App Group
    /// directory. In the app every committed write reloads WidgetKit. The extension passes no hook, because
    /// WidgetKit reloads after an intent on its own.
    public static let engine = Engine(directory: appGroupDirectory(), onCommit: isExtension ? nil : reloadWidgets)
}

struct Entry: TimelineEntry {
    let date: Date
    let face: Face
}

struct Provider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> Entry {
        Entry(date: .now, face: .placeholder)
    }

    func snapshot(for configuration: PickWidget, in context: Context) async -> Entry {
        let faces = await Hosting.engine.faces(
            for: configuration.widget?.id, family: Family(context.family), size: context.displaySize, from: .now)
        return Entry(date: faces.current.date, face: faces.current)
    }

    func timeline(for configuration: PickWidget, in context: Context) async -> Timeline<Entry> {
        let faces = await Hosting.engine.faces(
            for: configuration.widget?.id, family: Family(context.family), size: context.displaySize, from: .now)
        return Timeline(entries: faces.entries.map { Entry(date: $0.date, face: $0) }, policy: .after(faces.reloadAt))
    }
}

public struct CreationWidget: Widget {
    public init() {}
    public var body: some WidgetConfiguration {
        AppIntentConfiguration(kind: "creation", intent: PickWidget.self, provider: Provider()) { entry in
            FaceView(entry.face, host: .widget)
        }
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

extension FaceHost {
    /// The only place a tree button becomes an App Intent or a link, and the only place the widget
    /// background becomes a WidgetKit container background. The renderer knows none of them.
    static let widget = FaceHost(
        button: { tap, label in AnyView(Button(intent: RunAction(tap)) { label }.buttonStyle(.plain)) },
        form: { tap, label in AnyView(Link(destination: Hosting.formURL(for: tap)) { label }) },
        root: { content, background in AnyView(content.containerBackground(for: .widget) { background }) }
    )
}
```

The widget extension itself is only the bundle:

```swift
import SwiftUI
import WidgetKit
import WidgetHosting

@main struct Widgets: WidgetBundle {
    var body: some Widget { CreationWidget() }
}
```

What `faces` hides: choosing the latest creation when `widget` is nil, loading and upgrading the head revision, opening the database, computing today in the user's calendar, running every query in one read transaction, running the look in the sandbox with a time budget, validating the returned tree, decoding image assets at the display's pixel size, precomputing the entry for the next midnight so day windows flip on time without spending refresh budget, and choosing `reloadAt` from the next day boundary and the next automation run. It never throws. Any failure becomes a calm fallback face and a log line.

## 2. The App Intent

Lives in `WidgetHosting`, so the app and the extension compile the same intent. One engine call. It only ever runs actions that write in place. A form button is a link, so it never reaches the intent.

```swift
public struct RunAction: AppIntent {
    public static let title: LocalizedStringResource = "Run widget action"
    public static let isDiscoverable = false

    @Parameter(title: "Widget") var widgetID: String
    @Parameter(title: "Action") var actionID: String
    @Parameter(title: "Row") var rowID: String?

    public init() {}
    init(_ tap: Tap) {
        widgetID = tap.widget
        actionID = tap.action
        rowID = tap.row
    }

    public func perform() async throws -> some IntentResult {
        try Hosting.engine.perform(Tap(widget: widgetID, action: actionID, row: rowID))
        return .result()
    }
}
```

`perform` hides: parsing the head revision, finding the action, checking that the row belongs to the action's table and is not deleted, stamping the write with the shared hybrid logical clock, and applying it in one short immediate transaction. A tap on a stale face (row already deleted, action removed by an edit) is a quiet no-op, so WidgetKit simply reloads. It throws only when the store cannot be opened.

### 2b. The app completes a form

A widget cannot show a form, so a form button opens the app through a link: `<scheme>://form?widget=...&action=...&row=...`, with the scheme from the `EngineURLScheme` Info.plist key. The app turns the link back into a tap, asks the engine for the form, and submits it with the same verb as a tap. The app never learns which table or effect is behind the form.

```swift
import WidgetEngine
import WidgetHosting

.onOpenURL { url in
    guard let tap = Hosting.formTap(from: url), let form = try? Hosting.engine.form(for: tap) else { return }
    model.present(form)        // fields, labels, and current values when the form edits a row
}

func submit(_ form: InputForm, values: [String: InputValue]) throws {
    try Hosting.engine.perform(form.tap, input: values)   // e.g. ["title": .text("Buy oat milk")]
}
```

`submit` needs no WidgetKit call. The app's engine runs its `onCommit` hook after the write, and that reloads every timeline.

### 2c. The app shows a live, tappable preview

Same view, a different host. The app decides what a tap means in its own process.

```swift
let faces = await engine.faces(for: id, family: .small, size: Family.small.standardSize, from: .now)

FaceView(faces.current, host: FaceHost(
    button: { tap, label in AnyView(Button { model.tap(tap) } label: { label }.buttonStyle(.plain)) },
    form: { tap, label in AnyView(Button { model.openForm(tap) } label: { label }.buttonStyle(.plain)) },
    root: FaceHost.still.root))
```

## 3. The builder

Runs in the app, because fit can only be measured where SwiftUI runs, and in the eval harness on the Mac. The app sends the user's description, and any reference image, to the backend. The backend returns the model's document. The app validates and proves it, and sends any rejection line back for a repair. The backend never measures fit. The model's reply arrives as a `WidgetSource`: the document JSON plus image bytes keyed by asset id. One engine call per attempt.

```swift
import WidgetEngine
import WidgetBuilder

func create(_ prompt: Prompt, replacing existing: WidgetID? = nil) async throws -> WidgetID? {
    var request = BuildRequest(prompt, current: try existing.flatMap { try Hosting.engine.source(of: $0) })
    for _ in 0..<3 {                                       // first try, then at most two repairs
        let reply: WidgetSource = try await backend.generate(request)
        switch try await Hosting.engine.build(reply, replacing: existing) {
        case .saved(let id):
            return id                                      // onCommit already reloaded WidgetKit
        case .rejected(let line):
            request.repair(line)    // e.g. `medium, sample "busy": content spills 14pt past the bottom edge; ...`
        }
    }
    return nil
}
```

What the backend sends the model. The system prompt is `Engine/Reference/build-prompt.md`, with each `{{include <file>}}` line replaced by that file from the same folder (`blocks.md`, `look.md`) and every HTML comment removed. The user message is the person's words, with their picture as an image block when they attached one. The reply is one fenced `json` block holding the whole document, look included as a string. When the document declares the asset `reference`, the picture travels as that asset's bytes. A repair message holds the person's request, the previous document, and the verdict line. `Engine/Evals/run.py` runs exactly this loop on the Mac, with `claude -p` standing in for the model and `render-tool proof` standing in for `build`.

`build` hides: format upgrade and parsing into typed blocks, the one-line error for the first problem, checking that a replacement keeps every surviving field's kind, ingesting images (downscale to the widget pixel cap and encode), filling in what the model does not write (asset digests and the automation time zone), and the proof matrix.

The proof matrix renders every data state in every family, on a scratch in-memory store seeded through the same write path the widget uses. The states are `empty` (no rows), each sample in the source, and `full`, which the builder synthesizes: every list at its limit, three-digit counts, streaks and daily totals filled, and in every field the longest value the widget can store there. A field that a form asks for or an automation writes gets long text or 999, and a toggled bool gets `true`. A field that only fixed action values write gets the longest of them, so a mood that five emoji buttons write holds an emoji in `full`, never a sentence. `full` catches spills that the model's own samples miss. Each render must pass all of these checks:

- The look finishes inside its time budget. A look that runs over is rejected.
- It returns a valid tree, and every button's `rowId` is a row the look received for that action's table.
- Nothing drawn sits more than 2 points past the widget's edge or past a clipping ancestor. Only drawn nodes count: text, symbols, shapes, images, and buttons. A root or stack whose own frame or padding runs past the edge cuts nothing, so it passes, and the fit report shows it as `layoutOverflow` for information.
- No text is cut short. Text that ends in an ellipsis at the look's own `lineLimit` is what the look asked for and passes, in every state.
- The render is not blank. At least 0.05% of the sampled opaque pixels must stand out from the most common color by 32 levels of 255 in some channel. Anti-aliased corners and text one shade off its background do not count, and a white numeral on navy does.
- Images decode to at most 1.5 megapixels per render.

Then, over the whole matrix:

- Every action has a button in at least one state per family.
- Every query changes the render in at least one state and family. The builder reruns the look with each query emptied and requires the tree to change or the look to fail, so a repair cannot pass by dropping the data it was asked to show.

Only then does `build` save. Saving writes the asset files first, then an immutable revision named by the SHA-256 of its canonical bytes, then moves the widget's head to it, so a reader never sees a reference to a missing file. It throws only for infrastructure failures. Anything the model can fix comes back as `.rejected(line)`.

`source(of:)` returns the head revision in the same exchange format, so a refinement ("make it blue") sends the model exactly what it wrote last time.

### 3b. Undo and sharing

Every save adds a revision. Nothing rewrites one.

```swift
let revisions = try Hosting.engine.history(of: id)       // newest first; the first is the current one
try Hosting.engine.restore(id, to: revisions[1])          // "undo that change": moves the head back
```

A revision's id is its content hash, and its document lists the digest of every image it uses. So sharing a widget means fetching one revision by hash and the asset files it names. A widget that arrives from another user goes through `build` before it is saved, so it is proved on this phone with this phone's fonts and symbols:

```swift
switch try await Hosting.engine.build(WidgetSource(json: received.json, images: received.images)) { ... }
```

## 4. The render tool

An executable in the package. Given a widget and a data state, write a PNG and fit metrics. One engine call.

```swift
import Foundation
import WidgetEngine
import WidgetBuilder

// render-tool <widget dir> <small|medium> <out.png> [--sample name | --full | --state rows.json] [--date 2026-11-18T09:00:00Z]
@main struct RenderTool {
    static func main() async throws {
        let args = try Arguments.parse(CommandLine.arguments)
        do {
            let proof = try await Engine.proof(
                try WidgetSource(directory: args.widget), state: args.state, family: args.family, at: args.date)
            try proof.png.write(to: args.output)
            print(String(decoding: try JSONEncoder().encode(proof.fit), as: UTF8.self))
            if let verdict = proof.verdict { FileHandle.standardError.write(Data((verdict + "\n").utf8)) }
            exit(proof.verdict == nil ? 0 : 1)
        } catch let rejected as Rejected {
            FileHandle.standardError.write(Data(("error: " + rejected.line + "\n").utf8))
            exit(1)
        }
    }
}
```

`proof.verdict` is the exact line `build` would send the model for this render, so evals and the builder can never disagree about what passes. `proof.fit` is a `FitReport`, in points rounded to a tenth: `spill` (the worst drawn node past the widget or a clip), `layoutOverflow` (how far the root's own size exceeds the widget, informational), `edges` (the worst drawn spill past each edge), `cut` (the eight worst drawn nodes, each with its path, node type, label, the clip it is cut by, edge, and spill), `truncated` (text cut short, rejected), `ellipsized` (text ending at its own `lineLimit`, allowed), `ink` (the share of pixels that stand out, under 0.0005 is blank), `imagePixels`, `buttons` (the action of every button drawn), and `lookMilliseconds` and `renderMilliseconds` (the only values that vary between runs).

Proof mode runs the whole matrix in one call, for evals:

```swift
// render-tool proof <widget dir> <out dir> [--date ...] [--time-zone ...]
let matrix = try await Engine.proofs(try WidgetSource(directory: args.widget), at: args.date, calendar: calendar)
for render in matrix.renders { ... }   // empty, each sample, full; small then medium. Each a Proof or a Rejected line.
print(matrix.verdict ?? "accepted")
```

`Engine.proofs` runs the same `prove` as `build`, including coverage and the content check, but renders every cell even after one fails, so an eval sees them all. `matrix.verdict` is still the first problem, the exact line `build` would return. It throws only when the proof machinery itself cannot run. The tool writes `<state>-<family>.png` for each render and a `report.json` described by `render-tool --help`. A widget directory is the exchange format on disk: `widget.json` plus `assets/<asset id>.png|jpg`. The same format is a model reply, a refinement context, a debugging export, and a widget another user shared. `Engine/Fixtures/` holds the four reference widgets in this format.

## The widget document (exchange format)

What the model writes, what `source(of:)` returns, what a widget directory holds, and what a second user receives. JSON, one object, every block keyed by its id. Ids match `^[a-z][A-Za-z0-9]{0,31}$` because query ids become JavaScript keys and action ids appear in the tree. A key whose value is `null` counts as absent, as in the look. `Engine/Reference/blocks.md` is the model-facing reference for every block, and a test parses each of its examples.

| Key | Holds |
|---|---|
| `format` | Integer. The document format version. Absent in a model reply means current. |
| `name` | What the user sees in the widget picker. |
| `tables` | `{ id: { "fields": { fieldId: kind } } }`, where a kind is `text`, `number`, `bool`, or `date`. Field ids `id`, `day`, `daysAgo`, `repeat`, `newest`, and `oldest` are reserved. |
| `queries` | `{ id: { <shape>: <target>, ... } }`. Shapes: `count` (table), `sum` (`"table.field"`, number field), `latest` (table), `list` (table, with `limit` and an optional `sort`), `streak` (table), `daily` (table, with `days`). `count`, `sum`, `latest`, and `list` require `window` (`today`, `week`, or `all`) and take an optional `where`. |
| `actions` | `{ id: { <effect>: <target>, ... } }`. Effects: `insert` (table, optional `values`), `set` (`"table.field"` plus `to`), `toggle` (`"table.field"`, bool field), `delete` (table), `form` (table, `fields` list, optional `prompt`). |
| `automations` | `{ id: { "prompt": ..., "every": "hour" or "day" or "week", "at": "06:00", "on": "monday", "writes": table } }`. The builder adds `timeZone`. |
| `look` | The JavaScript source, one string. |
| `assets` | `{ assetId: { "about": "what the picture shows" } }`. Bytes travel next to the JSON, never inside it. Saving adds each asset's `digest`. |
| `samples` | `{ name: { tableId: [ { "daysAgo": 0, "repeat": 3, fieldId: value, ... } ] } }`. Rows relative to today, so a sample means the same thing on any day. `repeat` is 1 to 100. The names `empty` and `full` are taken by the states the builder makes. |

`where` is `{ field: value }`: one field of the query's table, compared for equality against a literal of that field's kind. Nothing more expressive. It is what makes "open to-dos" and "done to-dos" correct past the list limit. A bool field with no value counts as false, so `{ "done": false }` matches a new row nobody has touched. A text, number, or date field with no value matches nothing, and `where` cannot compare a date field.

A row belongs to the day it was written on, in the writer's calendar, and never moves. `today` is that day, `week` is the seven days from the calendar's first weekday that contain today, and `daily` counts rows per day.

There are no seed rows. A widget starts with no data, the empty state is a state every look must handle, and the proof checks it.

The look sees `ctx = { data, family, width, height, today }`. `data` has one key per query id:

- `count`, `sum`, and `streak` are numbers.
- `latest` is a row or `null`.
- `list` is an array of rows.
- `daily` is an array of `{ date, weekday, count }`, oldest first and today last, such as `{ "date": "2026-11-18", "weekday": "Wed", "count": 3 }`.

A row is `{ "id", "day", "daysAgo", ...fields }`, with dates as ISO strings, a bool field with no value as `false`, and any other field with no value as `null`. `today` is `{ "date": "2026-11-18", "weekday": "Wed", "week": [seven ISO dates of the user's current week, first day first] }`, so a look can show the date and draw day strips without reading the clock. History views read `daily` and do no date arithmetic.

## Worked example: water logger, end to end

### The source the model returns

`widget.json`, no assets. `Engine/Fixtures/water/widget.json` is this document with the look inlined.

```json
{
  "name": "Water",
  "tables": { "glasses": { "fields": {} } },
  "queries": {
    "today": { "count": "glasses", "window": "today" },
    "last":  { "latest": "glasses", "window": "today" },
    "week":  { "daily": "glasses", "days": 7 }
  },
  "actions": {
    "drink": { "insert": "glasses" },
    "undo":  { "delete": "glasses" }
  },
  "automations": {},
  "assets": {},
  "samples": {
    "morning":  { "glasses": [ { "daysAgo": 0, "repeat": 2 }, { "daysAgo": 1, "repeat": 6 }, { "daysAgo": 2, "repeat": 8 } ] },
    "goal met": { "glasses": [ { "daysAgo": 0, "repeat": 9 }, { "daysAgo": 1, "repeat": 8 } ] }
  },
  "look": "<the source below, as one string>"
}
```

```js
const GOAL = 8;

function render(ctx) {
  const d = ctx.data;
  const done = d.today >= GOAL;

  const drink = { type: 'button', action: 'drink', children: [
    { type: 'symbol', name: 'plus', size: 18, weight: 'bold', color: '#08304A',
      frame: { width: 40, height: 40 }, background: '#4FC3F7', clip: 'circle' } ] };

  const undo = d.last && { type: 'button', action: 'undo', rowId: d.last.id, children: [
    { type: 'symbol', name: 'minus', size: 14, weight: 'bold', color: '#4FC3F7',
      frame: { width: 30, height: 30 }, background: '#4FC3F722', clip: 'circle' } ] };

  const summary = {
    type: 'vstack', align: 'leading', spacing: 6,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity', alignment: 'topLeading' },
    children: [
      { type: 'hstack', spacing: 4, children: [
        { type: 'symbol', name: 'drop.fill', size: 13, color: '#4FC3F7' },
        { type: 'text', value: 'Water', size: 13, weight: 'semibold', color: '#9BC7DD' } ] },
      { type: 'text', value: d.today + ' / ' + GOAL, size: 30, weight: 'bold', design: 'rounded',
        color: done ? '#7AE582' : '#FFFFFF', lineLimit: 1, minScale: 0.5 },
      { type: 'spacer' },
      { type: 'hstack', children: [undo, { type: 'spacer' }, drink] },
    ],
  };

  const bars = d.week.map(day => ({
    type: 'vstack', spacing: 4, children: [
      { type: 'capsule', fill: day.date === ctx.today.date ? '#4FC3F7' : '#4FC3F766',
        frame: { width: 12, height: 8 + 80 * Math.min(day.count, GOAL) / GOAL } },
      { type: 'text', value: day.weekday.slice(0, 1), size: 10, color: '#9BC7DD' },
    ],
  }));

  return {
    type: 'hstack', spacing: 16, padding: 14,
    frame: { maxWidth: 'infinity', maxHeight: 'infinity' },
    widgetBackground: { gradient: 'linear', stops: ['#0B2A3C', '#08202E'], from: 'top', to: 'bottom' },
    children: [
      summary,
      ctx.family === 'medium' && {
        type: 'hstack', align: 'bottom', spacing: 8,
        frame: { maxHeight: 'infinity', alignment: 'bottom' }, children: bars },
    ],
  };
}
```

### Build

`engine.build(source)`:

1. Parse. `"week"` resolves to `.daily(glasses, days: 7)`. A typo such as `"count": "glass"` stops here with `query "today": no table "glass" (tables: glasses)`.
2. Proof matrix: data states `empty`, `morning`, `goal met`, and `full`, times families `small` and `medium`, so eight renders. Each opens a scratch in-memory store, seeds the state through the same insert path a tap uses (`repeat: 2` becomes two rows on today's day), runs the three queries, runs the look, validates the tree, renders, and measures. In `full`, `today` is 100 and every bar is filled, which checks that `100 / 8` still fits on one line.
3. Coverage: `drink` appears in all eight renders. `undo` appears only when `last` is not null, so it is covered by `morning`, `goal met`, and `full`. If a fit repair had dropped the minus button from every medium render, the line would be `medium: action "undo" has no button in any data state; keep a button for every action`.
4. Save: no assets, so one transaction writes the revision, named by the SHA-256 of `spec.encoded()`, and points the new widget's head at it. `onCommit` reloads WidgetKit. Result `.saved(id)`.

### Render at 09:00 on 2026-11-18 with three glasses logged today

`faces(for: id, family: .small, size: 158x158, from: 09:00)`:

1. Today in the user's calendar is day 2026-11-18. The week is 2026-11-16 to 2026-11-22 because the user's week starts on Monday.
2. One read transaction runs three statements: a count of live `glasses` rows with `day = today`, the newest row today, and the row count per day for the last seven days.
3. The context handed to the sandbox:

```json
{ "data": {
    "today": 3,
    "last": { "id": "0193f4c2-...", "day": "2026-11-18", "daysAgo": 0 },
    "week": [ { "date": "2026-11-12", "weekday": "Thu", "count": 8 }, "...",
              { "date": "2026-11-18", "weekday": "Wed", "count": 3 } ] },
  "family": "small", "width": 158, "height": 158,
  "today": { "date": "2026-11-18", "weekday": "Wed",
             "week": ["2026-11-16", "2026-11-17", "2026-11-18", "2026-11-19", "2026-11-20", "2026-11-21", "2026-11-22"] } }
```

4. The look returns a tree as JSON text. The validator turns it into a `Drawing`. The minus button becomes `.button(.run(Tap(widget: id, action: "undo", row: "0193f4c2-...")), ...)` because `undo` deletes the tapped row, the node carries a `rowId`, and that id is the row `last` returned. A button for `undo` without a `rowId`, or with an id the look never received, fails validation.
5. The same steps run for 2026-11-19 00:00, where `today` is 0, `last` is null, and the last `week` entry is the new day. Two entries go back, with `reloadAt` at the following midnight.

### Tap

The user taps the plus button on the home screen.

1. `FaceHost.widget` had wrapped that subtree in `Button(intent: RunAction(Tap(widget: id, action: "drink", row: nil)))`.
2. WidgetKit runs `RunAction.perform` in the extension. `engine.perform(tap)` finds `drink` is `.insert(glasses)`, opens an immediate transaction, takes the next clock stamp, and merges one change: insert row `0193f4c3-...` in `glasses` on day 2026-11-18. It commits. The extension's engine has no `onCommit` hook.
3. WidgetKit reloads the timeline. `faces` now sees `today = 4`.

Tapping minus twice quickly on a stale face deletes `0193f4c2-...` once. The second tap finds the row already tombstoned and does nothing, so the count never drops below what the user saw.

## The other three reference widgets

Each is in `Engine/Fixtures/` with its look and two samples.

| Widget | Tables | Queries | Actions | Automations | What the look does |
|---|---|---|---|---|---|
| To-do list | `items { title: text, done: bool }` | `open`: `list items`, `where: { done: false }`, `window: all`, `sort: oldest`, `limit: 20`. `done`: the same with `where: { done: true }` and `sort: newest`. `left` and `finished`: `count items` with the same two `where`s. | `toggle`: `toggle items.done` (tapped row). `add`: `form items`, `fields: ["title"]` (a link that opens the app). `remove`: `delete items` (tapped row) | none | Open items first, then done ones, one row each with a checkbox button carrying `rowId: item.id`, and a remove button on done items. A plus button for `add`. The header reads `finished / (left + finished)`, which stays right past the list limit. |
| Habit tracker | `checkins { }` | `streak`: `streak checkins`. `today`: `latest checkins`, `window: today`. `days`: `daily checkins`, `days: 35` | `check`: `insert checkins`. `uncheck`: `delete checkins` (tapped row) | none | One big button: `today ? uncheck with rowId today.id : check`. A grid of the last 28 or 35 days from `days`, filled where `count > 0`, with today outlined. Streak counts distinct days, so a double tap never inflates it. |
| Word of the day | `words { word: text, kind: text, definition: text, example: text }` | `word`: `latest words`, `window: all` | none | `daily`: prompt "Pick an interesting, real English word...", `every: day`, `at: "06:00"`, `writes: words` | Shows `word`, or a "your first word arrives at 6:00" face when it is null. `reloadAt` includes 06:05 so a dropped push is caught by the timeline. |
