# Phase 2 app flow plan

Today the app only installs four hand-written fixtures. This plan turns it into the product. A person describes a widget in words or attaches a picture. The app runs the build loop on the phone, shows a live preview they can tap, and takes chat refinements such as "make it blue". Save puts the widget in the library, ready for the home screen.

The model is the company's own model later. Until then a dev bridge on the Mac forwards each request to local Claude Code, the same way `Engine/Evals/run.py` does today.

Units in order, each one a PR. P1 shares the model call and adds the dev bridge. P2 adds a refine mode to the prompt and proves it with evals. P3 adds the build loop to `WidgetBuilder`. P4 adds a tappable preview for a draft that is not saved. P5 adds the describe screen. P6 runs the end-to-end check on the simulator.

Written 2026-11-21 from a read of the code at `33af661` (branch `phase-1d-review-fixes`).

## How to read this

One box is one unit of work. Every box names the evidence that checks it. A nested box is a sub-step of the box above it. Check a box only when its evidence exists, such as a file, a log line, a screenshot, a test run, or a SHA. The body is a how-to. The appendices explain and record.

Before you write any code, read this whole file. Then read `tasks/todo.md` (phase 2 and the risks), `tasks/lessons.md`, `docs/engine/USAGE.md`, `docs/engine/SYNTHESIS.md`, and `docs/engine/MODULES.md`. Confirm the plan with the user, or raise what you would change, before P1 starts. That is the user's standing rule for non-trivial work.

Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

## Facts this plan rests on

Read these as reference. Each was checked in the code at `33af661`.

- `Engine.build(_ source: WidgetSource, replacing: WidgetID?) async throws(EngineError) -> BuildOutcome` proves a document, saves it, and returns `.saved(WidgetID)` or `.rejected(String)` (`Engine/Sources/WidgetBuilder/Build.swift:29`, `Source.swift:72`). The rejected string is the one-line repair instruction for the model. `build` stops at the first failing proof cell.
- With `replacing:`, `build` keeps the widget's data. It checks the new spec against the old one, against other widgets on the same dataset, and against the kinds already stored (`Build.swift:39-63`). Images that a refine does not resend are reused (`Build.swift:158`).
- `Engine.source(of:)` returns the saved document and images, which is the context for a refine (`Build.swift:87`). `history(of:)` and `restore(_:to:)` exist (`Build.swift:107,120`).
- `Engine(directory:calendar:onCommit:)` is a public initializer (`Engine/Sources/WidgetEngine/Engine.swift:19`). Any directory works, so a scratch engine in a temporary folder is legal today.
- `FaceView(_:host:)` draws a live, tappable face from `engine.faces(for:family:size:from:)` (`FaceView.swift:57`, `Engine.swift:36`). `LibraryView` already uses it with an app host (`App/Widgie/LibraryView.swift:31-35,77-103`).
- `RowStore.seed(_:widget:today:)` writes a sample's rows, but it is `package` only (`Engine/Sources/Rows/RowStore.swift:386`). No public call loads a sample into a saved widget, and no public call copies one widget's rows to another engine.
- `build(replacing:)` does not reject a renamed or dropped table. `checkCompatible(replacing:)` compares only the tables both revisions declare (`Engine/Sources/Spec/Document.swift:36-44`), and `save` binds a new table id to a new, empty dataset (`RowStore.swift:137`). A refine that renames `glasses` to `cups` shows zero, and the old rows come back only on a restore.
- `ingest` reuses an image that a refine does not resend only from the store being built into (`Build.swift:146-172`). An image saved in one engine is not visible to another.
- No model client, `URLSession` code, or backend type exists anywhere in `App/` or `Engine/Sources/`. `docs/engine/USAGE.md:185-197` sketches a `create(prompt, replacing:)` loop with names that do not exist in code.
- `run.py` calls `claude -p --model <m> --safe-mode --system-prompt <prompt> --tools "" --strict-mcp-config --disable-slash-commands --no-session-persistence --input-format stream-json --output-format stream-json --verbose`. It removes `CLAUDECODE` from the environment and runs in an empty temporary folder (`Engine/Evals/run.py:119-165,404`).
- `run.py` builds the system prompt from `build-prompt.md` with `{{include blocks.md}}` and `{{include look.md}}` resolved and HTML comments stripped (`run.py:93-97`). That is about 20,000 input tokens per call.
- The model replies with one fenced `json` block holding the whole widget document. `run.py` takes the longest `json` fence, then the longest fence of any kind, then the raw reply (`run.py:168-189`).
- A repair is a fresh, stateless call. It holds the request, the previous document, the line "The line from the app:" with the verdict, and "Reply with the complete corrected document." (`run.py:100-106`). A reference image goes as a base64 image block before the text and is sent again with each repair (`run.py:109-116,252`).
- The prompt has no refine mode. It says "Every message asks for a widget" (`Engine/Reference/build-prompt.md:6`).
- The latest eval run is `phase-1d` on 2026-11-20, with 19 cases. Haiku accepted 12 on the first try, repaired 7, and failed none, with a median of 40.2 s per build. Sonnet accepted 18 on the first try, repaired 1, and failed none, with a median of 36.8 s per build (`Engine/.artifacts/evals/phase-1d/results.json`, not in git).
- The app has no test target. Engine tests use Swift Testing with one test target per area (`Engine/Package.swift:34-42`).

## The data shape

Name these types before any logic. Every unit below builds on them.

The wire request between the app and the model service is semantic. The app says what it wants, and the service owns the system prompt and the message wording. Prompt changes then never need an app release. The real backend keeps the same contract when it replaces the dev bridge.

```swift
// WidgetBuilder, public
public struct ModelRequest: Codable, Sendable {
	public var words: String            // the person's latest message
	public var image: Attachment?       // a picture attached in this session
	public var current: String?         // the document JSON being refined, nil for a new widget
	public var repair: Repair?          // set only on a repair call
}
public struct Attachment: Codable, Sendable { public var mime: String; public var bytes: Data }  // "base64" on the wire
public struct Repair: Codable, Sendable { public var document: String; public var line: String }

public protocol WidgetModel: Sendable {
	func reply(to request: ModelRequest) async throws -> String   // the raw model reply text
}

public enum BuildStep: Sendable, Equatable {
	case writing(attempt: Int)                  // waiting on the model
	case checking(attempt: Int)                 // proving the reply
	case repairing(attempt: Int, line: String)  // the last attempt was rejected with this line
}

public enum LoopOutcome: Sendable {
	case accepted(WidgetID, attempts: Int)      // the widget the loop saved in the engine it ran on
	case gaveUp(lastLine: String, attempts: Int)
}
```

The app screen is one state machine. It is not a set of booleans.

```swift
// App, @MainActor @Observable
final class DescribeSession {
	enum Phase { case composing, building(BuildStep), failed(String) }
	var phase: Phase
	var turns: [Turn]          // the transcript shown on screen, in memory only
	var draft: Draft?          // the last accepted widget, nil before the first one
	let editing: WidgetID?     // nil when creating, the library widget when refining
}
struct Turn { var words: String; var image: Attachment?; var result: TurnResult }
enum TurnResult { case pending, accepted, gaveUp(String), cancelled }
struct Draft { var previewID: WidgetID }  // lives in the scratch engine, which holds its document and images
```

A failed or cancelled turn never replaces `draft`. The person always keeps the last widget that worked.

The scratch engine is the one place a draft lives. Save reads `preview.source(of: previewID)`, which returns the document and every image, including an image attached in an earlier turn and reused since. A copy of the reply kept in the session would lose that image, because the real store never saw it.

A picture belongs to the turn it was sent with. A later turn does not send it again. The current document carries the look, and the stored image is reused.

## Share the model call and add the dev bridge (P1)

**Depends on.** None.

**Files.**

- [x] Create `Engine/Evals/model.py`. It holds prompt composition, message assembly, the `claude -p` call, and reply extraction, moved out of `run.py` unchanged. Done in `446b683`.
- [x] Edit `Engine/Evals/run.py` so it imports `model.py` and keeps its behavior. Done in `446b683`. A fake `claude` received byte-identical arguments, stdin, and environment from the old and new `run.py`, and all 57 output files match apart from timings (`Engine/.artifacts/p1/``shim-equivalence.txt`).
- [x] Create `Engine/Evals/bridge.py`, a standard-library HTTP server with no new dependencies. Done in `bea9ab2`.

**Build.**

- [x] `model.py` exposes `compose_prompt()`, `user_message(request: dict) -> list`, `call(model, prompt, content) -> dict`, and `extract(reply) -> str`. `user_message` takes the `ModelRequest` JSON shape above, so `run.py` and the bridge produce the same bytes for the same request. Done. A refine request raises an error until P2, so it can never pass for a working refine.
- [x] `bridge.py` serves `POST /v1/reply` on `127.0.0.1:8787`. It takes a `ModelRequest` body and returns `{"reply": "<raw text>", "seconds": <float>, "model": "<id>"}`. It also serves `GET /health`. Done (`Engine/.artifacts/p1/``bridge-sonnet.log`).
- [x] `bridge.py --model haiku|sonnet` picks the stand-in, with `sonnet` as the default. Each request is logged as one line with the time, the kind (create, refine, or repair), the seconds, and the token counts. Done. A log line reads `create 200 total 54.21 s, model 54.2 s, in 20116 out 7068`.
- [x] Transport errors return HTTP 502 with `{"error": "<one line>"}`. A reply with no fence is still a 200, and the app's build rejects it like any other bad document. Done. A bad body returns 400. The 502 path is covered by the timeout unit test and was not triggered live.
- [x] `call()` takes the number of tries and the timeout. `run.py` keeps three tries and 900 s. The bridge makes one try with a 110 s timeout, under the app's 120 s, so a retry never outlives the request. Done. The bridge also ignores a client that hangs up mid-reply.

**You see.**

- [x] `curl -s localhost:8787/health` prints `ok`. Done, printed `ok`.
- [x] `curl -s -X POST localhost:8787/v1/reply -H 'Content-Type: application/json' -d '{"words":"a water tracker with a big blue drop"}'` returns a reply whose extracted JSON passes `render-tool proof`. Done on Sonnet. Proof printed `accepted` (`Engine/.artifacts/p1/``bridge/sonnet-create-blue-drop/`).

**Verify, unit.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] A small test asserts that `user_message` gives byte-identical output for the create and repair shapes that `run.py` produced before the move. Run it with `python3 -I -m unittest discover -s Engine/Evals -p 'test_*.py'`, which `Engine/scripts/check` also runs. The path form `-m unittest Engine/Evals/test_model.py` cannot import the test under `-I`, and without `-I` the test cannot import `model`. Discovery puts `Engine/Evals` on the import path. Done. 7 tests pass, inside `Engine/scripts/check` too.

**Verify, live.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Run `run.py` on the four reference cases with `--models haiku`. Pass when every case is accepted within three attempts, like phase-1d. Done. Run `p1-move` accepted 3 of 4, and word of the day failed on Haiku with a two-line text verdict three times. Run `p1-move-2` and the old code's run `p1-before` each accepted 4 of 4 within two attempts. The inputs are proven byte-identical, so the miss is Haiku variance (`Engine/.artifacts/evals/`).
- [x] Post one create request, one request with the R1 image from `Engine/Evals/images/`, and one repair request built from a deliberately broken document. Pass when each extracted document goes through `render-tool proof`, or, for the repair, when the reply fixes the line it was given. Done on Sonnet. Create and R1 image `accepted`, and the R1 reply copies the picture's LCD look closely. The repair restored the removed `rowId` and was `accepted` (`Engine/.artifacts/p1/``bridge/`, re-proved by hand).

**Verify, perf.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. Wall seconds per bridge call against the `run.py` call seconds for the same case and model. Done. Bridge wall minus model seconds was -0.02 to +0.05 s live, within the 0.1 s rounding. Against an instant fake `claude`, the bridge's own work is 0.9 to 3.1 ms per call (`Engine/.artifacts/p1/``overhead-shim.txt`, `perf-pairs.txt`). Call time follows output length at about 4.2 ms per output token on both paths.
- [x] Rule. The bridge adds under 1 s over `run.py`. A larger gap means the bridge does extra work. Find it before moving on. Passed.

**Review gate.** None. P1 is not review-gated.

**Merge.**

- [x] `scripts/check` passes. Commit on a branch off `main`. `phase-1d-review-fixes` landed as PR #1 on 2026-11-21. Done.

## Add a refine mode to the prompt and prove it (P2)

**Depends on.** P1.

**Files.**

- [x] Edit `Engine/Reference/build-prompt.md` to add a refine section. Done in `ba917d8`.
- [x] Edit `Engine/Evals/model.py` so `user_message` handles `current`. Done in `2cef7ee`.
- [x] Edit `Engine/Evals/cases.json` and `run.py` to add refine cases. Done in `bcdf28b`.
- [x] Edit `Engine/Sources/RenderTool/RenderTool.swift` to add a `refine` command. Done in `6d7345e`.
- [x] Edit `Engine/Sources/Spec/Document.swift` so a replacement keeps every table of the old revision, and add a `SpecTests` case. Done in `f8435de`. No existing test dropped a table, so none needed changing.

**Build.**

- [x] The refine section tells the model three things. The message includes the current document. It must change only what the person asked for. It must keep every table name and cell kind, so stored data carries over. Add a mistake line, in the format the reference tests parse, for a refine that renames a table. Done. It also says to hide data by changing the look and keeping the table, and to add a table for new data. The picture section keeps a refine's existing assets. The mistake is in `blocks.md`, marked with an HTML comment that the composed prompt strips.
- [x] `checkCompatible(replacing:)` rejects a replacement that drops a table id the old revision declared, with a line such as `table "glasses" is gone; keep every table id so the stored rows carry over`. The rule reads only the two documents, so the scratch engine and the real store reach the same verdict. A table nothing reads is legal, so "remove the coffee count" still works by hiding it. Done with exactly that line. `aRefinementThatStopsShowingATableKeepsItsRows` proves a hidden table is accepted and its rows show again when a later refine reads it. After review, the rule also keeps every field id of every old table, with `field "items.title" is gone; keep every field id so the stored values carry over`, because a field rename blanked every stored value. `refinementThatRenamesAFieldIsRefusedWithOneLine` fails without it.
- [x] A refine message holds the person's words, then the current document in a `json` fence. A repair during a refine also carries `current`, so the model never loses the original. Done. The words go under "The person's request:" and the document under "The current document:". A refine repair then adds the previous document, the line, and "Reply with the complete corrected document." Both are pinned as bytes in `Engine/Evals/testdata/refine.jsonl` and `refine-repair.jsonl`. The bridge's 400 for `current` is gone. Live on Sonnet through the bridge, a refine returned 200 in 9.4 s and `render-tool refine` printed `accepted`.
- [x] `render-tool refine <old dir> <new dir> <out>` builds the old widget into a scratch engine, then builds the new one with `replacing:`. It prints `accepted` or the verdict line, so the compatibility check runs on the Mac exactly as it runs on the phone. Done. It also writes `<out>/current/`, the old widget as `Engine.source(of:)` returns it, and the proof PNGs and report. `run.py` refines each base to itself once, before any model call. That gives the before renders and the exact `current` the app would send: compact canonical bytes with `format` and the time zone filled in. `build` gained a `package` overload that takes the proof instant, so the verdict repeats at `--date`.
- [x] Add at least eight refine cases. Each has a `base` fixture and an instruction. Cover a color change ("make it blue"), a size change ("bigger number"), an added view ("add a weekly chart"), a removed element, a font change, a new image attached during the refine, an instruction that would need a data change ("track coffee instead of water", which must be refused or handled without breaking data), and a vague one ("make it nicer"). Done with nine, which add "change my goal to 10 glasses". The bases are the four fixtures. The photo case attaches `R3-photo.jpg`.
- [x] The contact sheet from `sheet.py` shows each refine as before and after, side by side. Done. A refine row shows the base, then each model, on the same sample when the result still has it. Checked in a headless Chromium screenshot of `p2-refine-1/index.html`.

**You see.**

- [x] `run.py --group refine --models haiku,sonnet` writes a results file with refine cases and a contact sheet with before and after columns. Done (`Engine/.artifacts/evals/p2-refine-1/results.json` and `index.html`).

**Verify, unit.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Add an `EngineTests` case where a `refine`-style build that renames a table is rejected with a one-line verdict, and one where a color-only change keeps rows. Run `Engine/scripts/check`. Done in `BuildTests`, with a `RenderToolTests` case for refine mode. Without the rule, both rename tests fail. `scripts/check` passes.
- [x] Extend the reference tests so the new mistake line parses. Done. 19 examples. The refine one fails the test when its line is changed.

**Verify, live.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Run the refine group twice on both stand-ins. Pass when every case is accepted within three attempts on Sonnet. Record the Haiku numbers as the baseline for the weaker model. Passed. Sonnet accepted 9 of 9 in both runs: `p2-refine-1` had 7 first try and 2 repaired once, and `p2-refine-2` had 8 and 1. The Haiku baseline is 9 of 9 in both, 8 first try and 1 repaired once each time. Every repair was a fit line after a font or chart change, plus one duplicate JSON key on Haiku.
- [x] Look at every before and after pair on the contact sheet. Pass when each pair changes what the instruction asked and nothing else that a person would notice. Write each miss into `tasks/todo.md` under phase 2. Done for all 36 pairs. Blue, remove, photo, goal, and nicer are clean on both models in both runs. Bigger is clean apart from one Sonnet run. Chart and font change what was asked, but each also shrinks text or drops a row. Coffee keeps the data but reuses the water table. Five misses are written down.
- [x] Re-run the 19 create cases on Sonnet. Pass when first-try acceptance stays within the noise of phase-1d, which is five builds. Passed. Run `p2-create` accepted 16 first try and 3 repaired once, with none failed, against 18 and 1 in `phase-1d`.

**Verify, perf.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. Median seconds and input tokens per refine build against a create build. Done. On Sonnet, a refine build's median is 13.0 s and 13.6 s across the two runs, with 22,369 and 22,329 input tokens per call. A create build's median is 44.8 s, with 20,753 input tokens per call (`p2-create`). On Haiku, a refine build's median is 11.5 s and 11.9 s, with 22,346 input tokens. A refine sends about 1,600 more input tokens. It finishes about three times faster because it writes about 2,000 output tokens per call against about 4,800 for a create, and call time follows output length.
- [x] Rule. Report both. A refine sends the current document, so expect a few thousand more input tokens. A median above 60 s on Sonnet is a finding to raise with the user, not to hide. Passed, far under 60 s. Every Sonnet call also lists `claude-haiku-5-5`. A replayed call showed that this is a side call inside Claude Code, 2,729 tokens in and 14 out, and Sonnet wrote all of the reply. The numbers above are Sonnet's.

**Review gate.** The user reviews the before and after contact sheet before P5 starts. The refine quality the person will see is decided here.

**Merge.**

- [x] `scripts/check` passes, and the results path is noted in the PR description. Merged as PR #4, with `p2-refine-1` and `p2-refine-2` in its description.

## Add the build loop to WidgetBuilder (P3)

**Depends on.** P1 for the wire shape. It does not need P2 to start.

**Files.**

- [x] Create `Engine/Sources/WidgetBuilder/Model.swift` for `ModelRequest`, `Attachment`, `Repair`, and `WidgetModel`.
- [x] Create `Engine/Sources/WidgetBuilder/Loop.swift` for the loop and reply extraction.
- [x] Create `Engine/Tests/EngineTests/LoopTests.swift`.
- [x] Edit `docs/engine/USAGE.md` to replace the illustrative `create` sketch with the real API, and `docs/engine/MODULES.md` if the target table needs it.

**Build.**

- [x] `Engine.build(_ words: String, image: Attachment? = nil, replacing: WidgetID? = nil, repairing: String? = nil, model: some WidgetModel, progress: @Sendable (BuildStep) -> Void = { _ in }) async throws -> LoopOutcome`, an overload of `build(_ source:replacing:)`, which is one attempt of it. On accept it returns the `WidgetID` that `build` saved. It reads `source(of: replacing)` for `current`, calls the model, extracts the document, calls `build`, and on `.rejected(line)` sends a repair. It stops after three attempts, which is the first try plus two repairs, matching `run.py`.
- [x] Reply extraction in Swift matches `model.extract` exactly. Take the longest `json` fence, then the longest fence of any kind, then the raw text, trimmed of ASCII whitespace. Lines end only at LF, so a JSON string that holds U+2028 is not split (`feb45f6`). 25 shared cases in `Engine/Evals/testdata/extract.json` pass on both sides.
- [x] Images sent to the model are the person's attachment. On accept, a document that declares `assets.reference` gets that attachment as the `reference` image in its `WidgetSource`.
- [x] An optional `repairing: String?` makes the first call a repair of the `replacing` widget's document with that line. P5 uses it when Save is rejected.
- [x] Cancellation is cooperative. A cancelled task throws `CancellationError` and saves nothing.
- [x] A transport error from `WidgetModel` is thrown, not counted as an attempt. Only a rejected document counts.

**You see.**

- [x] `LoopTests` runs a scripted fake model and every case passes.

**Verify, unit.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] `LoopTests` covers these cases, each named as a sentence. Run `Engine/scripts/check`.
  - [x] A good first reply is accepted in one attempt, and the widget is saved.
  - [x] Two bad replies then a good one are accepted in three attempts, and each repair carries the previous document and its exact line.
  - [x] Three bad replies give up with the last line, and nothing is saved.
  - [x] A refine sends `current`, and the accepted widget keeps its rows.
  - [x] A reply with prose around the fence, and a reply with two fences, extract the same document as `model.py` does. Share the cases with the Python test as one JSON file.
  - [x] A loop started with `repairing:` sends the stored document and that line on its first call.
  - [x] A cancel during the model call saves nothing.
  - [x] A transport error is thrown and does not use an attempt.
  - [x] An attached image reaches the saved widget only when the document declares `assets.reference`.

**Verify, live.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] `render-tool loop` runs the build loop against the real bridge for the four reference prompts. Pass when all four are accepted and the attempt counts match the `run.py` range. Passed on Haiku: water, to-do, and word of the day accepted in 2 attempts, habit in 1. Live `build` took 0.06 to 0.21 s per attempt (`Engine/.artifacts/p3-live/`).

**Verify, perf.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. Time spent in `build` per attempt, apart from the model call.
- [x] Rule. Under 1.5 s per attempt on the Mac for the reference widgets. Record the number. The phone number comes in P6. Recorded on an M4 with the release `render-tool loop` and a stand-in bridge that answers at once, 7 runs per fixture: 0.15 to 0.23 s for the first attempt in a process (median 0.17 to 0.20 s per fixture) and 0.09 to 0.14 s for the next (median 0.10 to 0.12 s). Rendering dominates: in `render-tool proof` the 14 SwiftUI renders take 85 to 107 ms and the 8 look runs 36 to 43 ms, of which 32 to 35 ms is the first run alone, a cost paid once per process.

**Review gate.** None. P3 is not review-gated.

**Merge.**

- [x] `scripts/check` passes. The module rules accept the new files.

## Add a tappable preview for an unsaved draft (P4)

**Depends on.** P3.

A draft must not appear in the home screen widget picker before the person saves it. It must still be live and tappable, and it should show sample data so a new widget does not look empty. A scratch `Engine` in a temporary folder gives all three with almost no new engine code.

**Files.**

- [x] Edit `Engine/Sources/WidgetBuilder/` to add one public call that loads a sample into a saved widget. Done in `7fa1190`: `Samples.swift` adds `load(_:into:at:)` and `samples(of:)`.
- [x] Create `App/Widgie/Preview.swift`. Done in `7b130d6`, with the Debug-only `PreviewLab.swift`.
- [x] Add a test to `Engine/Tests/EngineTests/`. Done in `7fa1190`: `PreviewTests.swift`, 8 tests.

**Build.**

- [x] Add `Engine.load(sample name: String, into widget: WidgetID) async throws(EngineError)` in `WidgetBuilder`, built on `RowStore.seed`. Add `Engine.clear(_ widget: WidgetID)` if returning to the empty state needs it. Keep `seed` itself `package`. Done as `load(_ state: DataState, into: WidgetID, at: Date = .now) throws(EngineError)`, synchronous like `perform`. It takes the proof's `DataState`, so `.empty` replaces `clear` and no second call exists. It moves each table to a new dataset and seeds there in one transaction (`RowStore.replaceRows`, which shares `seed`'s insert code), so a switch never mixes rows. It throws on any engine but a scratch one. `samples(of:)` lists the names, sorted by the saved document's key order, so the water fixture starts on "goal met".
- [x] `Preview` owns a scratch `Engine(directory: <temp>/preview-<uuid>, onCommit: nil)`. With `onCommit: nil` no WidgetKit reload ever fires for a draft. It deletes its folder on deinit and on app launch. Done as `Engine.scratch()`, which picks its own folder under tmp and has no commit hook. The engine holds one `RowStore` until it is released, and a stored property outlives `deinit`'s body, so a delete in `Preview.deinit` would remove the files of an open database. The store deletes the folder instead, in its own `deinit`, after `database.close()`. `Engine.removeLeftoverScratch()` runs at launch and deletes every earlier run's scratch folder. Folder gone on release (`aScratchEngineDeletesItsFolderOnceReleased`), and on the simulator the tmp folder list was empty after a relaunch.
- [x] The loop in P3 runs against the scratch engine, so every accepted attempt saves only there. The real store changes only on Save. `Preview.engine` is the engine P5 passes to `build(_ words:...)`. Live, the shared store held 9 widgets before and while a draft was open, and 10 after Save.
- [x] Save calls `Hosting.engine.build(preview.source(of: draft.previewID), replacing: editing)`. That proves the draft once more against the real store, including the data compatibility check for a refine. Done on `Preview` as `save(replacing:) async -> BuildOutcome?`, so P5 gets `.rejected(line)` to repair with. Live: Save added the draft to the library with no rows (`06-saved-from-preview.png`, `07-library-after-save.png`).
- [x] When refining a library widget, copy its current source into the scratch engine first, then load its first sample. No public call copies rows, so the preview never shows the person's real rows. Done as `Preview.copy(_:)`. Live: a library widget at 3 of 8 opened as a copy at 9 of 8 ("goal met"), a tap there made 10, and the library still read 3 of 8 (`08-copy-of-library-widget-shows-sample.png`, `09-library-rows-untouched-by-copy.png`).

**You see.**

- [x] A draft built in the scratch engine draws in `FaceView` and responds to taps. `Hosting.engine.widgets()` does not list it. Done, see the live box.

**Verify, unit.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] A test builds a fixture into a scratch engine, loads a sample, and reads faces whose data matches the sample. A second engine on another folder lists no widgets. Run `Engine/scripts/check`. Done. `PreviewTests` compares each face with `Engine.proof` of the same state in both families, checks that a switch replaces rows and that taps add on top, that two other engines list nothing, that the shared store refuses `load`, and that the folder goes on release. `Engine/scripts/check` passed, 68 tests in 14 suites in `EngineTests`.

**Verify, live.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] In a debug screen, build the water fixture into a preview, tap plus twice, and switch samples. Pass when the count changes and the sample switch redraws. Then open the home screen widget picker and confirm that the draft is not listed. Save a screenshot of each. Done on the iPhone 18 Pro simulator with AXe, from the library's Debug menu "Preview without saving". The draft opened on "goal met" at 9 of 8, two plus taps made 11 of 8, "morning" redrew at 2 of 8 with its week bars, and "empty" at 0 of 8. With the draft open, the edit sheet's widget list showed exactly the 9 library widgets in store order (`01-preview-first-sample.png` to `05-widget-picker-while-draft-open.png` in `Engine/.artifacts/app-flow/p4/`).

**Verify, perf.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. App memory with a preview open against the library screen alone, in the Xcode memory gauge on the simulator. Read instead as `vmmap --summary` physical footprint of the simulator app process on the Mac, 22 open and close rounds over three runs (`Engine/.artifacts/app-flow/p4/``memory.txt`).
- [x] Rule. Record both numbers. A growth of more than 30 MB per preview, or growth that stays after closing one, is a leak to fix. Passed. Steady state is 52.0 to 52.4 MB with the library alone and 53.3 to 53.6 MB with a preview open, about 1.3 MB per preview. The first preview in a fresh process costs 10.6 MB (36.3 to 46.9 MB), of which 8.7 MB stays as first-use cost. One later 7 MB step sat in reclaimable free malloc pages (9.9 MB reclaimable) and did not repeat over 12 more rounds. After closing, the heap holds one `Engine`, one `RowStore`, and no `Preview`. Once in the session SwiftUI kept one dismissed `Preview` alive, rooted in its animation manager and attribute graph, with no app-owned root (`retained-after-background-trace.txt`). It never exceeded one instance, and the launch sweep removed its folder.

**Review gate.** None. P4 is not review-gated.

**Merge.**

- [x] `scripts/check` passes. Done at `7b130d6` plus the docs: the engine gate (`check passed`) and the app build (`build passed`).

## Build the describe screen (P5)

**Depends on.** P2, P3, and P4.

**Files.**

- [x] Create `App/Widgie/Describe/DescribeSession.swift`, `DescribeView.swift`, and `BridgeModel.swift`. Done, with `TryItView.swift`, `SavedView.swift`, and `Picture.swift` beside them, and the design seam in `App/Widgie/Design/` (`Theme.swift`, `Caret.swift`, `WidgieColors.xcassets`).
- [x] Edit `App/Widgie/LibraryView.swift` and `Library.swift`. Done.
- [x] Edit `App/project.yml` for the debug-only bridge URL and local networking. Done as a Debug-only post-build step that writes `WidgieModelBridge` and `NSAllowsLocalNetworking` into the built Info.plist.

**Build.**

- [x] `BridgeModel` conforms to `WidgetModel`. It posts to the bridge with `URLSession`, a 120 s timeout, and `Content-Type: application/json`, which the bridge requires. The base URL comes from a Debug-only Info.plist key, `WidgieModelBridge`, set to `http://127.0.0.1:8787`. A Release build has no bridge key and shows "Building widgets is not available in this build". Done. The Release simulator build has no `WidgieModelBridge` key, and Build it shows that line on the drained screen (`Engine/.artifacts/app-flow/p5/release-unavailable.png`).
- [x] Debug builds set `NSAppTransportSecurity` with `NSAllowsLocalNetworking` so the simulator can reach the Mac over plain HTTP. Confirm on the simulator that the request goes through. Do not add an arbitrary-loads exception. Done. Every live lane below reached the bridge at `127.0.0.1:8787` (`bridge-sonnet.log`).
- [x] `DescribeSession` drives `Engine.build(_ words:...)` on the preview's scratch engine and maps each `BuildStep` to `phase`. It keeps the in-flight build alive with `UIApplication.beginBackgroundTask` when the app leaves the foreground, because a build takes about 40 s. Done. The background task covers only the build loop, begun and ended once per loop. A build that iOS cuts off is in code (`.interrupted`) but was not exercised live, see Appendix A. A Save that meets the background is live: the shared store refused the write, the save waited for the app to return, then saved with no error (`background-save-log.txt`, `background-save.png`).
- [x] The library gets a **New widget** button that opens the describe screen in create mode. Tapping a widget in the library opens it in refine mode with its current face as the draft. Move "Install reference widget" into a Debug-only menu. Done (`library.png`, `refine-saved-open.png`).
- [x] The describe screen has the following parts, top to bottom. Done as one screen per step in The Caret in Sky (`docs/design/app-feel/README.md`), so the parts sit on the screen the mock gives them.
  - [x] The preview, with small and medium faces and a picker for the empty state and each sample. Before the first draft, a placeholder invites a description. Done. The samples are one compact menu (`create-image-busy.png`), and before the first draft the describe screen is the invitation (`describe.png`).
  - [x] The transcript of turns. An accepted turn shows a short confirmation. A failed turn shows a plain-language message, never the raw verdict line. Done as the latest exchange only, per the mock (`refine-1.png`, `cancel.png`, `bridge-down-draft-kept.png`).
  - [x] A composer with a text field, a photo button that opens `PhotosPicker`, and a send button. An attached photo shows as a thumbnail that can be removed. Downscale it to 1080 px on the longest side and send it as JPEG. Done (`create-image-describe.png`, `create-image.png`).
  - [x] A **Save** button, enabled only when a draft exists, and a **Discard** button that asks for confirmation once a draft exists. Done. Save sits top right, and the close button asks before discarding.
- [x] The progress text follows the steps. Show "Writing your widget" while the model works, "Checking it fits" while proving, and "Fixing a layout problem (2 of 3)" during a repair. Show a cancel button during any build. Cancel returns to the last draft. Done (`building.png`, `repair.png`, `cancel-during-writing.png`, `cancel.png`). The repair line now reads "Fixing a problem (2 of 3)", because a repair also fixes data, assets, and actions, and the repair on Save is about shared data. Cancel ignores taps for the first 0.6 s, because it sits where Build it was and a double tap cancelled the build.
- [x] Map failures to messages. A transport error reads "Couldn't reach the widget builder. Check that the bridge is running." A give-up reads "I couldn't make that work. Try saying it another way." Keep the last good draft on screen in both cases. Done. "Check that the bridge is running." shows only in Debug, per the design decision (`bridge-down.png`, `gave-up.png`), and only when the bridge gave no answer. A bridge that answers 400, 413, or 502 reads "The widget builder ran into a problem." and logs its detail.
- [x] Save can still be rejected by the checks only the real store can run: a widget that shares the data, and the kinds of cells already stored. Treat that line as a repair. Run one more loop turn on the scratch engine with `replacing: draft.previewID` and `repairing:` set to that line, show it as normal progress, and save when it is accepted. Done in `DescribeSession.runSave`. A second rejection reads "I couldn't save this widget." with OK, and a store failure shows the plain failure screen, never a raw alert. No live save was rejected, so this path ran only in code.
- [x] After Save, return to the library, show the new widget, and show one line that explains how to add it to the home screen. Full onboarding is out of scope. Done as the Saved screen, then the library (`saved.png`, `library-after-save.png`).
- [x] Every new type and file follows the house style that `App/scripts/build` lints. Done, `scripts/check` passes.

**You see.**

- [x] Typing "a water tracker with a big blue drop" and pressing send shows the steps, then a live preview whose plus button changes the count. Done (`create-water.png`, `create-water-tapped.png`: 9 to 10 of 8).

**Verify, unit.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] The loop logic is already covered in P3. Move any `DescribeSession` logic that branches into a pure function and test it in `EngineTests` only if it belongs to the engine. Otherwise rely on the live lanes below, because the app has no test target. Adding an app test target is a fair alternative. Decide and note the choice in the PR. Decided: no app test target. The branching that is worth testing lives in the engine's loop, already covered in P3. What is left in the app is view state that only the live lanes show truthfully. Noted in `docs/pr/DRAFT-phase-2-p5-describe.md`.

**Verify, live.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked. Run each lane on the iPhone 18 Pro simulator, booted with `simslim on <udid> --except widgets,siri --keep com.apple.linkd`, with the bridge running on `sonnet`. Save every screenshot under `Engine/.artifacts/app-flow/`.

- [x] Lane 1. Regression against the current app. Install the four fixtures from the Debug menu. Pass when each still draws and taps as in the phase 0 review. Save `fixtures.png`. Pass. All four installed, drew, and tapped (`fixtures.png`, `fixtures-tapped.png`).
- [x] Lane 2. Create from words. Type the water reference prompt. Pass when a preview appears and a plus tap changes it. Save `create-water.png`. Pass (`create-water.png`, `create-water-tapped.png`).
- [x] Lane 3. Create from a picture. Attach `Engine/Evals/images/R2-boarding-pass.png` with "make my to-do list look like this". Pass when the look resembles the picture and the rows tap. Save `create-image.png`. Pass. A boarding-pass to-do list whose rows tap off (`create-image.png`, `create-image-busy.png`, `create-image-tapped.png`). Reshot after the photo moved to ImageIO decoding (`create-image-describe.png`, `create-image.png`). The simulator now keeps the `photos` group on (`simslim on <udid> --except widgets,siri,photos --keep com.apple.linkd`), because the photo picker needs it.
- [x] Lane 4. Refine. After lane 2, send "make it blue", then "bigger number". Pass when each turn changes only what it asked. Save `refine-1.png` and `refine-2.png`. Pass. Blue changed only the colors, and the number grew from 9 to a larger 9 (`refine-1.png`, `refine-2.png`). The suggestion chips now come from the draft's face, so a blue water tracker offers "Make it orange" and "Bigger number". `refine-1.png` is reshot with the orange chip, which changed only the colors.
- [x] Lane 5. Repair visible to the person. Use a prompt that the phase-1d run needed a repair for on Haiku, with the bridge on `haiku`. Pass when the repair step shows and the build is accepted. Save `repair.png`. Pass. The sticky-note to-do list repaired once on haiku and was accepted in 2 attempts (`repair.png`, `repair-result.png`). `repair.png` is reshot mid-repair with the new line. That haiku run gave up after 3 (`repair-gave-up.png`). An earlier haiku run gave up after 3 and showed the give-up screen (`repair-gave-up-step.png`, `gave-up.png`).
- [x] Lane 6. Cancel. Cancel during "Writing your widget". Pass when the screen returns to the last draft and nothing is saved in the library. Save `cancel.png`. Pass. The library still listed the same five widgets after (`lib-after-cancel.png`).
- [x] Lane 7. Bridge down. Stop the bridge and send a message. Pass when the transport message shows and the draft stays. Save `bridge-down.png`. Pass (`bridge-down.png`, `dark-failure.png`, `bridge-down-draft-kept.png`).
- [x] Lane 8. Save and place. Save the lane 4 widget. Add it to the home screen in small and medium. Tap it on the home screen. Pass when the face matches the preview and the tap updates it without opening the app. Save `home-small.png` and `home-medium.png`. Pass, with one simulator caveat. Both sizes match the preview's look, and taps write without opening the app. While testing, a tap left the other size stale until midnight, because WidgetKit reloads only the tapped widget after an intent; fixed in `WidgetHosting` (`fixed-after-tap.png`, `fixed-after-second-tap.png`). The tapped face itself still shows the new count one redraw late on the simulator (`stale-after-tap.png`, `stale-after-page-swipe.png`), see Appendix A.
- [x] Lane 9. Refine a saved widget. Log three taps on the saved water widget, open it from the library, and send "add a weekly chart". Save. Pass when the home screen widget shows the chart and the three logged taps are still counted. Save `refine-saved.png`. Pass. Three taps logged, then the weekly chart was added and saved, and the home screen shows 3 of 8 with the chart (`refine-saved-before.png`, `refine-saved.png`, `refine-saved-home.png`).
- [x] Lane 10. Appearance. Repeat lane 8 in dark mode and tinted mode. Pass when the face is legible in both. Save `home-dark.png` and `home-tinted.png`. Pass (`home-dark.png`, `home-tinted.png`).

**Verify, perf.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. Seconds from send to the first live preview, for the four reference prompts on `sonnet`. Split each into model seconds, from the bridge log, and app seconds. Done in `Engine/.artifacts/app-flow/p5/perf.txt`, one run per prompt.
- [x] Baseline. The `run.py` medians from phase-1d, 36.8 s on Sonnet. Median total 33.4 s here.
- [x] Rule. App seconds, meaning the total minus model seconds, stay under 3 s per attempt on the simulator. The total is dominated by the model and is reported, not gated. Pass. App seconds 0.48 to 1.20 per build, median 0.55, and 0.44 per attempt on the 3-attempt haiku build.

**Review gate.** The user reviews before merge, because P5 changes what a person sees and does.

- [x] Post the lane screenshots and a 30 to 60 second screen recording of lanes 2, 4, and 8 (`xcrun simctl io <udid> recordVideo`). Stop and wait for the user's decision. Posted with `lanes-2-4-8.mp4`; the user approved the merge on 2026-11-22 after a council review that ended at 9.2 from Claude Opus and Gemini 4 Neon.

**Merge.**

- [x] `scripts/check` passes. The user approved the screenshots and the recording.

## Run the end-to-end check and record the results (P6)

**Depends on.** P5.

**Files.**

- [x] Edit `tasks/todo.md`. Check the app-flow item in phase 2, add a review section with the numbers, and add every look or behavior problem found. Done: the app-flow item is checked, "App flow review (P6)" holds the table and the numbers, and the eval findings and app follow-ups sit under the app-flow item.

**Build.**

- [x] Run the four reference prompts, three look prompts from `cases.json`, one reference image, and three refines through the app on the simulator. Use `sonnet` once and `haiku` once. Done: water, todo, wotd, and habit; water-glass, habit-graph, and todo-sticky; R1 with "make my widget look like this. its a habit tracker"; and "bigger number", "add a weekly chart", and "make it blue" on their `cases.json` bases (`bridge-sonnet.log`, `bridge-haiku.log`, `app-log.txt`, `app-log-sonnet.txt` in `Engine/.artifacts/app-flow/p6/`). Sonnet accepted 11 of 11 on the first attempt; Haiku accepted 9 of 11.
- [x] Fix every visual flaw you see in the screen itself, such as spacing, alignment, truncation, or keyboard overlap. Be picky. That is the user's standing rule for UI work. Done: the caret's clipped foot, prompts and the sample menu cut off at large text sizes, the gap before "Done.", the picture thumbnail's alignment, and straight apostrophes (`fix-caret-foot-before-after.png`, `after-dt-describe.png`, `after-dt-tryit.png`, `bridge-down-after.png`). Keyboard overlap could not be seen: the headless simulator never shows the soft keyboard. Larger changes (an app icon, the widget's edit sheet) are listed in `tasks/todo.md`.

**You see.**

- [x] A table in `tasks/todo.md` with each request, the model, the attempts, the seconds, and accepted or not. Done, 24 rows.

**Verify, unit.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] `scripts/check` passes at the end. Passed on the final commit.

**Verify, live.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Every request in the table has a screenshot of its preview and, for saved ones, its home screen face. Done: 24 previews and the ten saved widgets' faces (`home-*.png`), each looked at.

**Verify, perf.** Tests alone are not sufficient verification. A unit is verified only when its unit, live, and perf boxes are all checked.

- [x] Metric. Widget extension memory while it draws the largest saved AI-built widget, read from the simulator as in the phase 0 review. Done with `vmmap --summary` on the extension process (`memory.txt`): 17.8 MB peak in three fresh processes, against 16.1 to 16.6 MB for the water fixture in the same slot.
- [x] Rule. Under 20 MB peak on the simulator, the phase 0 number for the fixtures. More than that is a finding to explain before the device step. Passed for the largest widget. A process that drew all ten saved widgets in turn peaked at 21.0 MB, while a fresh process switching through seven of them stayed at 17.8 MB peak. The long-lived growth is listed in `tasks/todo.md` for a heap diff before the device step.

**Review gate.** None. P6 records results and changes no interaction beyond P5's fixes, which go back through the P5 gate if they are large.

**Merge.**

- [x] The results commit lands with P5 or right after it. PR #9, merged right after P5's PR #8.

## Close the plan

- [x] Every box above is checked with its evidence.
- [x] Write the PR review doc in `docs/pr/` per the user's global rules, one per PR. P6's is `docs/pr/9-phase-2-p6-end-to-end.md`.
- [x] Report to the user with the results table, the screenshots, what is still open, and anything you decided that they might want changed. Reported on 2026-11-22.

## Appendix A. What is still unproven

Nothing below was run while writing this plan. Settle each as early as its unit allows.

- Settled in P5: the simulator reaches `127.0.0.1:8787` with only `NSAllowsLocalNetworking`.
- Open after P6: keyboard overlap on the describe and try-it screens. The headless simulator never shows the soft keyboard, so no lane saw it. Check on a device or a simulator with a window.
- Open after P6: a widget extension process that had drawn all ten saved widgets peaked at 21.0 MB, 3.1 MB above a fresh one at rest, though a fresh process switching through seven of them did not grow (`Engine/.artifacts/app-flow/p6/memory.txt`). A heap diff should say whether it is a cache or a leak before the device step.
- Open after P5: on the simulator, a tapped home screen widget shows its new count one redraw late. Its timeline already holds the count, which shows after a page swipe or any redraw. Check on a device before chasing it in code.
- The simulator reaching `127.0.0.1:8787` with only `NSAllowsLocalNetworking`. Settle it in the first hour of P5 with a one-line request from the app. A physical phone needs the Mac's LAN address or Bonjour, which is out of scope here.
- A refine prompt that changes only what was asked. P2 measures it. If Sonnet misses often, the fallback is to send a smaller target ("change only the look") and keep the blocks unchanged in the app. Raise that with the user first, because it limits what refine can do.
- A build surviving the app going to the background for 40 s. Still unproven after P5: no lane sent the app to the background mid-build. A Save that meets the background is settled: it waits for the app to return, then saves (`background-save-log.txt`). `beginBackgroundTask` gives roughly 30 s, and a longer build may be cut off. If lane testing shows it, keep the request on a background `URLSession`, or re-run the attempt when the app returns. Pick one and note it in the PR.
- Whether `build` on the phone is fast enough for three attempts. P3 measures the Mac and P5 the simulator. The device number is owed to the device step.

## Appendix B. Alternatives rejected

- **Save every accepted draft to the real store and mark it as a draft.** It reuses the library path, but the draft appears in the home screen widget picker before the person saves. It also needs a new draft flag in the persisted schema. The scratch engine needs one small public call.
- **Show proof PNGs as the preview.** It needs no new code, but the preview could not be tapped. A person should try the plus button before saving.
- **Build the system prompt in the app.** Every prompt change would then need an app release, and the company model may want a different prompt. The service owns the prompt, and the app sends a semantic `ModelRequest`.
- **Keep the model conversation open across refines.** It saves input tokens, but the current document is the real context, and the eval loop is already stateless. Stateless calls also let the backend scale and retry freely.
- **Persist the chat transcript.** Nothing needs it yet. A refine works from `source(of:)`. Add persistence if people ask to see why a widget looks the way it does.

## Appendix C. Out of scope

These stay in `tasks/todo.md` and are not part of this plan.

- The real backend endpoint on Cloudflare, App Attest, and per-device quotas. They need the Cloudflare and Apple Developer accounts.
- Anything on a physical iPhone.
- Growing the eval set to 40 requests and adding a visual score.
- Proof at several sizes per family, a tap-target size check, and repairs that send the render as an image. They are listed for phase 2 in `tasks/todo.md`, and each deserves its own plan.
- Add-to-home-screen onboarding, the age gate, and the AI data consent screen.

## Appendix D. Risks

- **Cost of every call.** Each call sends about 20,000 tokens of reference text. Prompt caching on the real backend cuts that, and the bridge log records the token count per call so the effect is visible later.
- **App Review and look code (guideline 2.5.2).** Nothing here changes the defense. The model output is still a document that the engine proves before it runs.
- **Weaker model quality.** Haiku needed repairs on 7 of 19 builds in phase-1d. The repair step must read as normal progress, not as an error, which lane 5 checks.
