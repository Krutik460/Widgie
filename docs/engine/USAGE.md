# Usage

Written before the types. The types in `Engine/Sources/` are derived from these call sites.

One object, `Engine`, does everything. What a caller can do with it depends on what it imports:

| Import | Adds to `Engine` | Who imports it |
|---|---|---|
| `WidgetEngine` | `init(directory:calendar:onCommit:)`, `faces(for:family:size:from:)`, `perform(_:input:at:)`, `form(for:)`, `widgets()`, `delete(_:)`, `Engine.suspend()`, `Engine.resume()`, `Engine.scratch()`, `Engine.removeLeftoverScratch()`, plus `FaceView`, `FaceHost`, and `Face.traits` | app, widget extension (through `WidgetHosting`) |
| `WidgetBuilder` | `build(_:replacing:)`, `build(_:image:replacing:repairing:model:progress:)` and `Engine.maxBuildAttempts`, `source(of:)`, `history(of:)`, `restore(_:to:)`, `samples(of:)`, `load(_:into:at:)`, `checkpoint(of:)` and `restore(_:)`, `proveReceived()`, `Engine.proof(_:state:family:...)`, `Engine.proofs(_:at:calendar:)`, plus `BridgeModel` | app, render tool |
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
    /// directory. Every committed write reloads WidgetKit, in the extension too: the reload WidgetKit runs
    /// after an intent covers only the tapped widget, so another widget on the same rows would stay stale.
    public static let engine = Engine(directory: appGroupDirectory(), onCommit: reloadWidgets)
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
            WidgetFace(face: entry.face)
        }
        .contentMarginsDisabled()
        .supportedFamilies([.systemSmall, .systemMedium])
    }
}

/// WidgetKit tells only the view how it draws the widget (full color, or accented for tinted and clear), never
/// the provider. The look cannot branch on it, so the renderer resolves it from this environment value.
struct WidgetFace: View {
    let face: Face
    @Environment(\.widgetRenderingMode) private var mode

    var body: some View {
        FaceView(face, host: .widget).environment(\.renderingMode, mode == .fullColor ? .fullColor : .accented)
    }
}

extension FaceHost {
    /// The only place a tree button becomes an App Intent or a link, the widget background becomes a WidgetKit
    /// container background, and `accent` and image `tint` become WidgetKit's accented rendering. The renderer
    /// knows none of them.
    static let widget = FaceHost(
        button: { tap, label in AnyView(Button(intent: RunAction(tap)) { label }.buttonStyle(.plain)) },
        form: { tap, label in AnyView(Link(destination: Hosting.formURL(for: tap)) { label }) },
        root: { content, background in AnyView(content.containerBackground(for: .widget) { background }) },
        accent: { content in AnyView(content.widgetAccentable()) },
        tint: { tint, image in   // widgetMode: .fullColor, .desaturated, or .accentedDesaturated for accented
            AnyView(image.widgetAccentedRenderingMode(tint.widgetMode))
        }
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

What `faces` hides: choosing the latest creation when `widget` is nil, loading and upgrading the revision it draws (the head once this device has proved it), opening the database, computing today in the user's calendar, running every query in one read transaction, running the look in the sandbox with a step and memory budget, validating the returned tree, decoding image assets at the display's pixel size within a 1.5 megapixel budget for the whole call, stamping every button with the revision it was drawn from, precomputing the entry for the next midnight so day windows flip on time without spending refresh budget, adding an entry every 15 minutes for two hours, where the picture changed, when the look read `now` or a row's `minutesAgo`, and choosing `reloadAt` from the next day boundary, the end of those two hours, and the next automation run. It never throws. Any failure becomes a calm fallback face and a log line.

## 2. The App Intent

Lives in `WidgetHosting`, so the app and the extension compile the same intent. One engine call. It only ever runs actions that write in place. A form button is a link, so it never reaches the intent.

```swift
public struct RunAction: AppIntent {
    public static let title: LocalizedStringResource = "Run widget action"
    public static let isDiscoverable = false

    @Parameter(title: "Widget") var widgetID: String
    @Parameter(title: "Revision") var revision: String?
    @Parameter(title: "Action") var actionID: String
    @Parameter(title: "Row") var rowID: String?
    @Parameter(title: "Day") var day: String?

    public init() {}
    init(_ tap: Tap) {
        widgetID = tap.widget
        revision = tap.revision
        actionID = tap.action
        rowID = tap.row
        day = tap.day
    }

    public func perform() async throws -> some IntentResult {
        try Hosting.engine.perform(Tap(widget: widgetID, revision: revision, action: actionID, row: rowID, day: day))
        return .result()
    }
}
```

The five parameters are exactly `Tap`. `revision` is the digest of the revision the button was drawn from, which `faces` stamps on every tap, so what the user pressed is what runs: a refinement that lands between the render and the press, even one that reuses the action's id for another effect, does not change what the press does. Proofs stamp the placeholder `unsaved`, which is not a digest and so never names a stored revision.

`perform` hides: checking that the widget is live, loading the tap's revision when it is not the drawn one (it must be in that widget's history) and finding the action as that revision defines it, checking that the row belongs to the dataset the action's table is bound to and is not deleted, stamping the write with the shared hybrid logical clock, and applying it in one short immediate transaction. A stale tap is a no-op with a log line, so WidgetKit simply reloads: the widget is deleted, the tap has no revision, a malformed one, or one outside the widget's history (another widget's, say), that revision does not parse, it has no such action, the row is missing, not of that table, or already deleted, or an `insertOn` tap has no day or one outside today and the 365 days before it. It throws only when the store cannot be opened or written, or when form input has the wrong kind.

### 2b. The app completes a form

A widget cannot show a form, so a form button opens the app through a link: `<scheme>://form?widget=...&revision=...&action=...&row=...`, with the scheme from the `EngineURLScheme` Info.plist key. The app turns the link back into a tap, asks the engine for the form (as the tap's revision defines it), and submits it with the same verb as a tap. The app never learns which table or effect is behind the form.

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

A draft the person has not saved lives in a scratch engine, never in `Hosting.engine`, so the widget picker cannot list it. `Engine.scratch()` makes one in a new folder of its own under the app's temporary directory. It runs no commit hook, it deletes that folder when it is released, after closing its database, and it keeps writing after `Engine.suspend()`, so a build can finish in the background. `App/Widgie/Preview.swift` owns one per draft. The app calls `Engine.removeLeftoverScratch()` at launch, which deletes the folders an earlier run left behind when it crashed or iOS ended it.

```swift
Engine.removeLeftoverScratch()                        // once, at launch

let scratch = Engine.scratch()
guard case .saved(let draft) = try await scratch.build(source) else { return }   // or the build loop

let samples = try scratch.samples(of: draft)          // ["goal met", "morning"], sorted like the saved document
try scratch.load(.sample(samples[0]), into: draft)    // the face now shows exactly that sample's rows
try scratch.load(.empty, into: draft)                 // and now no rows

// Save: prove the draft once more against the shared store, keeping a refined widget's rows.
if let source = try scratch.source(of: draft) {
    do {
        let outcome = try await Hosting.engine.build(source, replacing: editing)   // .rejected(line) is a repair
    } catch where error.isSuspended {
        // The app went to the background and the shared store refused the write: save again once it is back.
    }
}
```

A refinement is checked against the head of the widget it replaces twice: before the proof, so a mismatch costs no rendering, and again inside the write that moves the head, so a widget deleted while the draft was proved throws, and one refined or written to meanwhile is checked as it is now. The head counts even when it came from another device and is not proved here yet, so the refinement keeps the fields it added, and a head this device cannot read declines the refinement. `EngineError.isSuspended` is true only when the store refused a write, or a shared store refused to open, because `Engine.suspend()` holds; no other error is worth retrying as it is.

`load` moves each table to a new, empty dataset and inserts the state's rows there in one transaction, so switching samples never mixes rows, and taps then write on top of the sample. It throws on any engine but a scratch one, because in the shared store it would hide the person's rows.

To undo a refinement the person cancelled, take a checkpoint before the build and restore it after. The checkpoint records the draft's head and the dataset each table reads. The rows those datasets hold, taps included, stay in place when a later `load` moves the tables on, so `restore` brings back exactly what was on show, in one transaction. A table the checkpoint did not have loses its dataset, so a later refinement may add it again with other field kinds. Both calls throw on any engine but a scratch one.

```swift
let checkpoint = try scratch.checkpoint(of: draft)
// build a refinement of draft, load a sample into it to show it, then the person cancels
try scratch.restore(checkpoint)                       // the old head, and the rows the preview showed before
``` To refine a library widget, build its `source(of:)` into the scratch engine and load a sample. No call copies rows between engines, so the preview never shows the person's rows.

```swift
let faces = await engine.faces(for: id, family: .small, size: Family.small.standardSize, from: .now)

FaceView(faces.current, host: FaceHost(
    button: { tap, label in AnyView(Button { model.tap(tap) } label: { label }.buttonStyle(.plain)) },
    form: { tap, label in AnyView(Button { model.openForm(tap) } label: { label }.buttonStyle(.plain)) },
    root: FaceHost.still.root))
```

## 3. The builder

Runs in the app, because fit can only be measured where SwiftUI runs, and in the eval harness on the Mac. The app sends the model service a `ModelRequest`: the person's words, any picture they attached, the document being refined, and, on a repair, the rejected document with its line. The service returns the model's raw reply. The app takes the document out of it, validates and proves it, and sends any rejection back as a repair. The service never measures fit. `build(_ words:...)` runs that loop, and `build(_ source:replacing:)` is one attempt of it.

```swift
import WidgetEngine
import WidgetBuilder

// The model service: `BridgeModel` posts the request as JSON to the dev bridge on the Mac and returns the reply
// text; the backend's client will conform to `WidgetModel` the same way. It throws only when the service did
// not answer: `URLError` when it cannot be reached, `BridgeModel.Refused` when it answered with an error.
let model = BridgeModel(base: URL(string: "http://127.0.0.1:8787")!)

// Called from the main actor, `progress` runs on the main actor, so it sets the screen's state directly.
let outcome = try await engine.build(
    "a water tracker with a big blue drop", image: Attachment(mime: "image/jpeg", bytes: jpeg), model: model
) { step in
    // .writing(attempt: 1), .checking(attempt: 1), then on a rejection
    // .repairing(attempt: 2, line: "medium, sample \"busy\": content spills 14pt past the bottom edge; ..."), ...
    screen.step = step
}
switch outcome {
case .accepted(let id, let attempts):   // saved in `engine`; onCommit ran
case .gaveUp(let lastLine, let attempts):   // Engine.maxBuildAttempts rejections; nothing was saved
}

// A refinement: the model gets the stored document as `current`, and the reply replaces the widget under the
// same id, keeping its rows.
try await engine.build("make it blue", replacing: id, model: model)

// A document another store rejected (the real store on Save): the first call repairs the stored document
// with that line, and it is attempt 1, so progress starts at .repairing(attempt: 1, line: line).
try await engine.build("make it blue", replacing: draft, repairing: line, model: model)
```

The loop makes at most `Engine.maxBuildAttempts` attempts, three: the first try and two repairs, as `Engine/Evals/run.py` does. A loop started with `repairing` has no fresh try: its first call is already a repair and counts as attempt 1, so it makes at most three repairs. `progress` runs on the caller's actor, in order, and every step has run before the outcome returns. Only a rejected reply uses an attempt. An error the model service throws is rethrown as it is, and nothing is saved. A repair holds the person's words, the same `current` as the first call, the document the model sent last, and the exact line `build` rejected it with. The document is the reply's longest fenced `json` block, else its longest fenced block of any kind, else the whole reply trimmed, by the same rule as `extract` in `Engine/Evals/model.py`; `Engine/Evals/testdata/extract.json` holds the cases both are tested against. The picture goes to the model with every call. A reply that declares the asset `reference` gets the picture as that asset's bytes, any other reply builds without it, and a refinement that sends no picture keeps the stored one. After the task is cancelled the loop throws `CancellationError` with nothing saved, with one exception: a `build` already under way finishes, and when it saves, `.accepted` returns, so the caller decides whether to keep that widget (the app restores the previous head). A reply rejected after the cancel throws `CancellationError`, never `.gaveUp`. `render-tool loop` runs the same loop against the dev bridge on the Mac.

The request on the wire, as the dev bridge (`Engine/Evals/bridge.py`) and the backend accept it. Every key but `words` is left out when it is nil:

```json
{ "words": "make it blue",
  "image": { "mime": "image/jpeg", "base64": "/9j/4AAQ..." },
  "current": "{\"name\": \"Water\", ...}",
  "repair": { "document": "{\"name\": \"Water\", ...}", "line": "small, empty: the render is blank; ..." } }
```

What the service sends the model. The system prompt is `Engine/Reference/build-prompt.md`, with each `{{include <file>}}` line replaced by that file from the same folder (`blocks.md`, `look.md`) and every HTML comment removed. The user message is the person's words, with their picture as an image block when they attached one. The reply is one fenced `json` block holding the whole document, look included as a string. A refine message holds the person's request and the current document, the bytes `source(of:)` returns, in a fenced `json` block. A repair message holds the person's request, the current document for a refine, the previous document, and the verdict line. The service owns this wording, so a prompt change never needs an app release. `Engine/Evals/run.py` runs the same loop on the Mac, with `claude -p` standing in for the model and `render-tool proof` standing in for `build`.

`build` hides: format upgrade and parsing into typed blocks, the one-line error for the first problem, checking that a replacement keeps every table id and every field id with its kind, so the stored rows and their values carry over, and agrees with the widgets that share its data and with the cells already stored, ingesting images (downscale to the widget pixel cap and encode), filling in what the model does not write (asset digests and the automation time zone), and the proof matrix.

The proof matrix renders every data state in every family, on a scratch in-memory store seeded through the same write path the widget uses. The states are `empty` (no rows), each sample in the source, and `full`, which the builder synthesizes: every list at its limit, three-digit counts, streaks and daily totals filled, and in every field the longest value the widget can store there. A field that a form asks for or an automation writes gets 999 or text at the real limit, 300 UTF-16 units of ordinary words, and a toggled bool gets `true`. A field that only fixed action values write gets the longest of them, so a mood that five emoji buttons write holds an emoji in `full`, never a sentence. `full` catches spills that the model's own samples miss. Each render must pass all of these checks:

- The look finishes inside the proof's step and memory budget, which is stricter than the widget's. Steps count interpreter work, never time, so the verdict is the same on every machine. A look that runs over is rejected.
- `ctx` is at most 1 MB of JSON. The parse-time cell cap keeps ordinary text under it; text full of characters JSON escapes can still reach it, so `composeDrawing` refuses a larger context before the look runs, in the widget and in the proof alike.
- It returns a valid tree, and every button's `rowId` is a row the look received for that action's table.
- Nothing drawn sits more than 2 points past the widget's edge or past a clipping ancestor. Only drawn nodes count: text, symbols, shapes, images, and buttons. A root or stack whose own frame or padding runs past the edge cuts nothing, so it passes, and the fit report shows it as `layoutOverflow` for information.
- No text is cut short. Text that ends in an ellipsis at the look's own `lineLimit` is what the look asked for and passes, in every state.
- The render is not blank. At least 0.05% of the sampled opaque pixels must stand out from the most common color by 32 levels of 255 in some channel. Anti-aliased corners and text one shade off its background do not count, and a white numeral on navy does.
- Images decode to at most 1.5 megapixels per render. `AssetImages` holds the budget for its whole lifetime, one proof cell or one `faces` call (both entries), and the image whose decode would cross it fails validation with one line, so the widget falls back on the same data the proof rejects. The decode cache keys on the crop, so each distinct crop of one asset counts again. `FitReport.imagePixels` reports what was decoded, for information.

Then the same trees are drawn again, since the look is never told the rendering mode or color scheme: tinted with `empty` and `full` (the sparsest render, where a blank or a backdrop shape shows most, and the busiest), and dark with `full` (where every `{ light, dark }` color is in use), in both families. Layout is the light cell's, so only two pixel checks run. Each must not be blank, by the rule above. A tinted render must also not be mostly one flat color: at most 50% of the sampled opaque pixels may share the most common color that is not the backdrop (`cover`). A full-size shape that draws the backdrop becomes one white sheet in tinted mode and scores near 1 (0.97 in the test look); the four fixtures score at most 0.25. Tinted mode is emulated: the backdrop replaces the widget background, every color turns white at its own opacity, `accent: true` nodes turn a fixed tint color, and images follow `tint` (`desaturated` in gray, `accented` in the tint color with brightness as opacity). On a device the system recolors the same views by their opacity, which should leave this unchanged, but only a device can confirm it. Their lines start with the family, state, and appearance, such as `small, empty, tinted: `.

Then, over the whole matrix:

- Every action has a button in at least one state per family.
- Every query changes the render in at least one state and family. The builder reruns the look with each query emptied and requires the tree to change or the look to fail, so a repair cannot pass by dropping the data it was asked to show.

Only then does `build` save. Saving writes the asset files first, so a reader never sees a reference to a missing file. Then one transaction writes an immutable revision named by the SHA-256 of its canonical bytes, moves the widget's head to it, and binds each table that has no dataset to a new one. It throws only for infrastructure failures and for a `replacing` id that names no widget. Anything the model can fix comes back as `.rejected(line)`.

`source(of:)` returns the revision the widget draws (the head once this device has proved it) in the same exchange format, so a refinement ("make it blue") sends the model exactly what it wrote last time.

### 3b. Undo and sharing

Every save adds a revision. Nothing rewrites one.

```swift
let revisions = try Hosting.engine.history(of: id)       // newest first; the first is the head
try Hosting.engine.restore(id, to: revisions[1])          // "undo that change": moves the head back
```

A revision's id is its content hash, and its document lists the digest of every image it uses. So sharing a widget means fetching one revision by hash and the asset files it names. A widget that arrives from another user goes through `build` before it is saved, so it is proved on this phone with this phone's fonts and symbols:

```swift
switch try await Hosting.engine.build(WidgetSource(json: received.json, images: received.images)) { ... }
```

A design that arrives by sync instead (a refinement made on the user's other device, or a head move on a shared widget) is already a revision in the store. It does not draw until this phone proves it. After each sync pull the app calls:

```swift
try await Hosting.engine.proveReceived()   // proves every unproved head with build's proof; onCommit runs per verdict
```

Until then each widget draws its newest revision that passed its proof here, or stays hidden when it has none, and a rejected revision never draws. A head this build cannot parse (a newer format), or whose asset files have not arrived, gets no verdict and is tried again on the next call. The extension never proves, so it keeps drawing the last proved revision. The sync layer itself (phase 4) moves `RowStore.changes(after:)`, which groups this device's changes by scope (one entry per dataset, plus `.account` for revisions, heads, bindings, and widget deletes), and `RowStore.receive(_:now:)`, which merges what arrives and returns what it held back (stamped more than 10 minutes ahead, to offer again later) and what it refused (text over the limit).

## 4. The render tool

An executable in the package. Given a widget and a data state, write a PNG and fit metrics. One engine call.

```swift
import Foundation
import WidgetEngine
import WidgetBuilder

// render-tool <widget dir> <small|medium> <out.png> [--sample name | --full | --state rows.json]
//             [--appearance light|dark|tinted] [--date 2026-11-18T09:00:00Z] [--time-zone Europe/Berlin]
@main struct RenderTool {
    static func main() async throws {
        let args = try Arguments.parse(CommandLine.arguments)   // a usage error exits 2
        let source = try WidgetSource(directory: args.widget)    // an unreadable widget exits 2
        do {
            let proof = try await Engine.proof(
                source, state: args.state, family: args.family, appearance: args.appearance, at: args.date,
                calendar: args.calendar)   // days in --time-zone (default UTC), weeks from Monday
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

For `dark` and `tinted`, `proof.verdict` is the light render's line when it has one, then the appearance's own. `proof.verdict` is the exact line `build` would send the model for this render, so evals and the builder can never disagree about what passes. `proof.fit` is a `FitReport`, in points rounded to a tenth: `spill` (the worst drawn node past the widget or a clip), `layoutOverflow` (how far the root's own size exceeds the widget, informational), `edges` (the worst drawn spill past each edge), `cut` (the eight worst drawn nodes, each with its path, node type, label, the clip it is cut by, edge, and spill), `truncated` (text cut short, rejected), `ellipsized` (text ending at its own `lineLimit`, allowed), `ink` (the share of pixels that stand out, under 0.0005 is blank), `cover` (tinted renders only: the share in the most common color that is not the backdrop, over 0.5 is rejected), `imagePixels`, `buttons` (the action of every button drawn), and `lookMilliseconds` and `renderMilliseconds` (the only values that vary between runs).

Proof mode runs the whole matrix in one call, for evals:

```swift
// render-tool proof <widget dir> <out dir> [--date ...] [--time-zone ...]
let matrix = try await Engine.proofs(try WidgetSource(directory: args.widget), at: args.date, calendar: calendar)
for render in matrix.renders { ... }   // empty, each sample, full; then empty and full tinted, full dark; each
                                       // small then medium. Each has its appearance and a Proof or a Rejected line.
print(matrix.verdict ?? "accepted")
```

`Engine.proofs` runs the same `prove` as `build`, including coverage and the content check, but renders every cell even after one fails, so an eval sees them all. `matrix.verdict` is still the first problem, the exact line `build` would return. It throws only when the proof machinery itself cannot run. The tool writes `<state>-<family>.png` for each light render that produced an image, `<state>-<family>-<tinted|dark>.png` for the others, where a sample's `<state>` is `sample-` and its name made file-safe (`sample-goal-met`), and a `report.json` described by `render-tool --help`. A widget directory is the exchange format on disk: `widget.json` plus `assets/<asset id>.png|jpg`. The same format is a model reply, a refinement context, a debugging export, and a widget another user shared. `Engine/Fixtures/` holds the six reference widgets in this format.

Loop mode runs the app's build loop on the Mac, for checking a model service by hand:

```swift
// render-tool loop <words> <out dir> [--image <png|jpg>] [--bridge http://127.0.0.1:8787] [--time-zone ...]
let outcome = try await scratch.build(words, image: image, model: Bridge(url: bridge)) { step in ... }
```

It builds into a fresh engine in a temporary folder, prints each step on stderr with the seconds since the start, then the seconds each attempt spent with the model and in `build`. It prints `accepted in <n> attempts` or `gave up after 3 attempts: <line>`, and writes an accepted widget to `<out dir>` as a widget directory. It exits 0 when accepted, 1 when it gave up, and 2 when the bridge did not answer.

## The widget document (exchange format)

What the model writes, what `source(of:)` returns, what a widget directory holds, and what a second user receives. JSON, one object, every block keyed by its id. Ids match `^[a-z][A-Za-z0-9]{0,31}$` because query ids become JavaScript keys and action ids appear in the tree. A key whose value is `null` counts as absent, as in the look. `Engine/Reference/blocks.md` is the model-facing reference for every block, and a test parses each of its examples.

| Key | Holds |
|---|---|
| `format` | Integer. The document format version. Absent in a model reply means current. |
| `name` | What the user sees in the widget picker. |
| `tables` | `{ id: { "fields": { fieldId: kind } } }`, where a kind is `text`, `number`, `bool`, or `date`. Field ids `id`, `day`, `daysAgo`, `at`, `minutesAgo`, `by`, `now`, `repeat`, `newest`, and `oldest` are reserved. |
| `queries` | `{ id: { <shape>: <target>, ... } }`. Shapes: `count` (table), `sum` (`"table.field"`, number field), `latest` (table), `list` (table, with `limit` and an optional `sort`), `streak` (table with an optional `goal`, or number field with a required `goal`), `daily` (table or number field, with `days`). `count`, `sum`, `latest`, and `list` require `window` (`today`, `week`, `month`, `all`, or `{ "days": N }`). Every window ends today, so a row written ahead for a later day shows on its day. Every shape takes an optional `where`. |
| `actions` | `{ id: { <effect>: <target>, ... } }`. Effects: `insert` (table, optional `values`), `insertOn` (table, optional `values`; its button names a `day`), `set` (`"table.field"` plus `to`), `toggle` (`"table.field"`, bool field), `delete` (table), `form` (table, `fields` list, optional `prompt`). |
| `automations` | `{ id: { "prompt": ..., "every": "hour" or "day" or "week", "at": "06:00", "on": "monday", "writes": table } }`. The builder adds `timeZone`. |
| `look` | The JavaScript source, one string. |
| `assets` | `{ assetId: { "about": "what the picture shows" } }`. Bytes travel next to the JSON, never inside it. Saving adds each asset's `digest`. |
| `samples` | `{ name: { tableId: [ { "daysAgo": 0, "repeat": 3, fieldId: value, ... } ] } }`. Rows relative to today, so a sample means the same thing on any day. `minutesAgo` (0 to 10080) places a row that many minutes before the render instead of `daysAgo`. `by` names another member who wrote the row (up to 30 characters), and `"me"` or no `by` is the person. `repeat` is 1 to 100. The names `empty` and `full` are taken by the states the builder makes. |

`where` is `{ field: value }`: one field of the query's table, compared for equality against a literal of that field's kind. Nothing more expressive. It is what makes "open to-dos" and "done to-dos" correct past the list limit. A bool field with no value counts as false, so `{ "done": false }` matches a new row nobody has touched. A text, number, or date field with no value matches nothing, and `where` cannot compare a date field. `where` may also hold `"by": "me"` or `"by": "others"`, alone or beside the field: `me` is the person and `others` is everyone they share with. Until sharing maps an account's replicas, the engine takes the replica that inserted a row as its author, so `me` is this store's replica.

Two limits bound what a look receives. A text value holds at most 300 UTF-16 units, which is what JavaScript holds, so an emoji counts as 2; `Spec.Limits.allows` is the one rule every write path asks, a tap, a form, a sample, and a sync batch alike. And `list` and `latest` queries together may return at most 1,000 field values: rows times the fields of the query's table, a `list` at its `limit` and a `latest` as one row, checked at parse time.

A row belongs to the day it was written on, in the writer's calendar, and never moves. `insertOn` writes a row on an earlier day, today or up to 365 days back, which the button names. `today` is the reader's day, `week` is the seven days from the calendar's first weekday that contain today, `month` is the calendar month that contains today, and `{ "days": N }` is the last N days with today last. `daily` and `streak` measure each day by its row count, or with a number field by that field's sum. A `streak` day counts when its measure reaches `goal` (1 row when left out).

There are no seed rows. A widget starts with no data, the empty state is a state every look must handle, and the proof checks it.

The look sees `ctx = { data, family, width, height, today }`. `data` has one key per query id:

- `count`, `sum`, and `streak` are numbers.
- `latest` is a row or `null`.
- `list` is an array of rows.
- `daily` is an array of `{ date, weekday, count }`, oldest first and today last, such as `{ "date": "2026-11-18", "weekday": "Wed", "count": 3 }`. Over a number field each entry also has `sum`.

A row is `{ "id", "day", "daysAgo", "at", "minutesAgo", "by", ...fields }`, with dates as ISO strings, a bool field with no value as `false`, and any other field with no value as `null`. `at` is the insert time as `HH:MM` in the reader's time zone, `minutesAgo` the whole minutes from then to the render (0 for a peer's clock that runs ahead), and `by` is `{ "me", "name" }`, where `name` comes from the local `member` table and is null for a writer it does not name. `now` is the render's time as `HH:MM`. `today` is `{ "date": "2026-11-18", "weekday": "Wed", "week": [seven ISO dates of the user's current week, first day first] }`, so a look can show the date and draw day strips without reading the clock. History views read `daily` and do no date arithmetic.

## Worked example: water logger, end to end

### The source the model returns

`widget.json`, no assets. `Engine/Fixtures/water/widget.json` is this document with `"format": 1` and the look inlined.

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
    "morning":  { "glasses": [ { "daysAgo": 0, "repeat": 2 }, { "daysAgo": 1, "repeat": 6 }, { "daysAgo": 2, "repeat": 8 },
                               { "daysAgo": 3, "repeat": 5 }, { "daysAgo": 4, "repeat": 7 }, { "daysAgo": 5, "repeat": 8 },
                               { "daysAgo": 6, "repeat": 3 } ] },
    "goal met": { "glasses": [ { "daysAgo": 0, "repeat": 9 }, { "daysAgo": 1, "repeat": 8 }, { "daysAgo": 2, "repeat": 8 } ] }
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
      frame: { width: 40, height: 40 }, clip: 'circle',
      background: { type: 'rect', fill: '#4FC3F7', accent: true } } ] };

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
      // Small spreads the buttons to both corners. Medium keeps them together under the count, so the plus
      // does not float against the chart.
      ctx.family === 'medium'
        ? { type: 'hstack', spacing: 10, children: [undo, drink] }
        : { type: 'hstack', children: [undo, { type: 'spacer' }, drink] },
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
2. Proof matrix: data states `empty`, `morning`, `goal met`, and `full`, times families `small` and `medium`, so eight renders, then four tinted and two dark redraws of the same trees. In tinted mode the plus stays visible because its disc is in the accent group: without `accent: true` the disc and the plus would both turn white. Each opens a scratch in-memory store, seeds the state through the same insert path a tap uses (`repeat: 2` becomes two rows on today's day), runs the three queries, runs the look, validates the tree, renders, and measures. In `full`, `today` is 100 and every bar is filled, which checks that `100 / 8` still fits on one line.
3. Coverage: `drink` appears in all eight renders. `undo` appears only when `last` is not null, so it is covered by `morning`, `goal met`, and `full`. If a fit repair had dropped the minus button from every medium render, the line would be `medium: action "undo" has no button in any data state; keep a button for every action`.
4. Save: no assets, so one transaction writes the revision, named by the SHA-256 of `spec.encoded()`, points the new widget's head at it, and binds `glasses` to a new dataset. `onCommit` reloads WidgetKit. Result `.saved(id)`.

### Render at 09:00 on 2026-11-18 with three glasses logged today

`faces(for: id, family: .small, size: 158x158, from: 09:00)`:

1. Today in the user's calendar is day 2026-11-18. The week is 2026-11-16 to 2026-11-22 because the user's week starts on Monday.
2. One read transaction runs three statements over the live rows of the dataset `glasses` is bound to: a count of rows with `day = today`, the newest row today, and the row count per day for the last seven days.
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

4. The look returns a tree as JSON text. The validator turns it into a `Drawing`. The minus button becomes `.button(.run(Tap(widget: id, revision: drawn, action: "undo", row: "0193f4c2-...")), ...)`, with `drawn` the digest of the revision `faces` loaded, because `undo` deletes the tapped row, the node carries a `rowId`, and that id is the row `last` returned. A button for `undo` without a `rowId`, or with an id the look never received, fails validation.
5. The same steps run for 2026-11-19 00:00, where `today` is 0, `last` is null, and the last `week` entry is the new day. Two entries go back, with `reloadAt` at the following midnight.

### Tap

The user taps the plus button on the home screen.

1. `FaceHost.widget` had wrapped that subtree in `Button(intent: RunAction(Tap(widget: id, revision: drawn, action: "drink", row: nil)))`.
2. WidgetKit runs `RunAction.perform` in the extension. `engine.perform(tap)` finds the widget live and `drawn` its drawn revision, finds `drink` is `.insert(glasses)` there, opens an immediate transaction, takes the next clock stamp, and merges one change: insert row `0193f4c3-...` in the dataset `glasses` is bound to, on day 2026-11-18. It commits. The extension's engine has no `onCommit` hook.
3. WidgetKit reloads the timeline. `faces` now sees `today = 4`.

Tapping minus twice quickly on a stale face deletes `0193f4c2-...` once. The second tap finds the row already tombstoned and does nothing, so the count never drops below what the user saw.

## The other five reference widgets

Each is in `Engine/Fixtures/` with its look and two samples.

| Widget | Tables | Queries | Actions | Automations | What the look does |
|---|---|---|---|---|---|
| To-do list | `items { title: text, done: bool }` | `open`: `list items`, `where: { done: false }`, `window: all`, `sort: oldest`, `limit: 20`. `done`: the same with `where: { done: true }` and `sort: newest`. `left` and `finished`: `count items` with the same two `where`s. | `toggle`: `toggle items.done` (tapped row). `add`: `form items`, `fields: ["title"]`, `prompt: "New to-do"` (a link that opens the app). `remove`: `delete items` (tapped row) | none | Open items first, then done ones, one row each with a checkbox button carrying `rowId: item.id`, and a remove button on done items. A plus button for `add`. The header reads `finished / (left + finished)`, which stays right past the list limit. |
| Habit tracker | `checkins { }` | `streak`: `streak checkins`. `today`: `latest checkins`, `window: today`. `days`: `daily checkins`, `days: 35` | `check`: `insert checkins`. `uncheck`: `delete checkins` (tapped row) | none | One big button: `today ? uncheck with rowId today.id : check`. A grid of the last 28 or 35 days from `days`, filled where `count > 0`, with today outlined. Streak counts distinct days, so a double tap never inflates it. |
| Dog fed | `feeds { }` | `last`: `latest feeds`, `window: { days: 2 }`. `today`: `count feeds`, `window: today` | `feed`: `insert feeds`. `undo`: `delete feeds` (tapped row) | none | Shows `last.minutesAgo` as "1 h 35 min ago" and who fed ("You" for `by.me`, else `by.name`) with `at`. Turns red after 12 hours or with no feed. Undo shows for the person's own feed in its first hour. The quarter-hour entries keep "ago" current. |
| Thinking of you | `hearts { }`, asset `photo` | `sent`: `count hearts`, `where: { by: me }`, `window: today`. `received`: the same with `where: { by: others }`. `lastIn`: `latest hearts`, `where: { by: others }`, `window: { days: 7 }` | `send`: `insert hearts` | none | The couple's photo, fading out toward the bottom with a mask so text stays readable in tinted mode, with sent and received counts, who sent the last heart and when, and a heart button. |
| Word of the day | `words { word: text, kind: text, definition: text, example: text }` | `word`: `latest words`, `window: all` | none | `daily`: prompt "Pick an interesting, real English word...", `every: day`, `at: "06:00"`, `writes: words` | Shows `word`, or a "your first word arrives at 6:00" face when it is null. `reloadAt` is never later than 06:05, so a dropped push is caught by the timeline. |
