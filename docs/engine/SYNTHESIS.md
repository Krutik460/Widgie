# Engine design: synthesis

Two independent designs were produced for the engine package on 2026-11-18. This note records which one is the base, what was taken from the other, and the decisions that override both. Where this note and the other files in this folder disagree, this note wins until those files are updated to match.

## Base

Candidate one. Its `USAGE.md`, `MODULES.md`, and `RATIONALE.md` are in this folder, and its type sketch is the starting point of the package in `Engine/`.

Why it is the base:

- **Smallest interface.** One `Engine` object. Each of the four entry points is one call. The builder methods exist only for code that imports `WidgetBuilder`, and the widget extension does not link it.
- **Stored local day.** A row records the calendar day it was written on, in the writer's local calendar. "Today" is an integer comparison in SQL, and travel never breaks a streak.
- **Proof equals build.** The render tool and the builder share one code path, so an eval and a real build cannot disagree about what passes.
- **Concrete JavaScript boundary.** Text in, text out, one file to swap if the engine changes. No protocol until a second engine exists. The engine is QuickJS-ng (see below).

## Convergence

Both designs arrived at the same answers on these points without seeing each other, which is the strongest evidence in this exercise:

- One stored value per (row, field), each with a clock stamp, and one merge function used by taps today and by sync later.
- No operation log.
- Block types that only the parser can construct, with typed field handles, so a dangling reference or a type mismatch cannot exist after parsing.
- The JavaScript engine behind a strings-only boundary.
- One tree validator, separate from a renderer that cannot fail.
- A host closure that turns a button into an App Intent in the widget and into nothing in the render tool.
- A builder target the widget extension never links.
- The need for day-bucketed history that a pure look cannot compute without a clock.
- The need for a field filter on queries (the to-do "open items" case).

## Taken from candidate two

1. **`daily` query kind.** `daily(table, days)` returns one entry per day, oldest first and today last, each `{ date, weekday, count }`. History views (water bars, habit grids) read it directly. Looks do no date arithmetic. Candidate one's `ctx.today` stays as well, because users will ask for the date on a widget.
2. **Content-addressed document revisions.** A saved document is immutable and named by its hash. The widget record points at its head revision. A refinement adds a revision and moves the head. This gives "undo that change" and makes sharing a matter of fetching a revision by hash.
3. **Forms open the app through a link.** A button whose action opens an input form becomes a `Link` to a URL the app handles. This replaces candidate one's foreground-continuing intent, which is unverified on a device.
4. **Synthesized data states in the proof.** Besides the empty state and the model's samples, the builder generates a `full` state: every list at its limit with long text, three-digit counts, long values in every text field. It catches spills the model's own samples miss.
5. **Row ids are checked against the rows the look was given.** A button that names a row id the look never received is a validation error.
6. **A commit hook on the app's engine.** Reloading WidgetKit after an app write is wired once, not at every call site. Both processes can run migrations, because the extension may open the database first after an update.

## Decisions that override both

- **Field filter.** `count`, `sum`, `latest`, and `list` take an optional `where` with one field compared for equality against a literal. Nothing more expressive. This is what makes "open to-dos" and "done to-dos" correct past the list limit.
- **The build loop runs on the phone.** Fit can only be measured where SwiftUI runs. The app sends the description to the backend, the backend returns the model's document, and the app validates, proves, and sends back any error line. The backend does not measure fit.
- **A shared widget is re-proved on arrival.** A document received from another user goes through `build` before it is saved. A revision that arrives by sync draws only once `Engine.proveReceived` has proved it on this phone.
- **No seed rows in the document.** The empty state is a state every look must handle, and the proof checks it.
- **Data reaches a closed app by one bounded pull in the widget (2026-11-20).** The timeline provider makes one request for this account's changes since its watermark before it renders, with a 4 second hard timeout, merges them in one short transaction, and on any failure renders what the store has. A widget push from the server triggers the reload. The server writes AI block rows ahead of their day, and every query window ends today, so a pre-written word appears at midnight with no network. Rejected: a WidgetKit push carries no data; a silent push to the app is throttled and never arrives after the user force-quits the app, so neither meets "a new word the next day without opening the app". Apple's advice against sync in the extension is a forum answer about full sync; Apple documents network requests in timeline providers. The client code waits for the backend (phase 3).
- **Runaway looks.** Looks run on QuickJS-ng, vendored, with a step budget and a memory budget instead of a time limit (2026-11-20). The builder rejects a look that exceeds the proof's budget. A look that runs away after it shipped stops at the widget's budget on every reload, its thread ends, and the widget shows a fallback face, so there is no quarantine table. A device must still confirm the time per step and the memory peak inside the extension.

## Rejected

- **Pure fact table with no row record** (candidate two). Uniform, but day windows then need per-read bucketing in Swift and row existence becomes a convention.
- **Days computed at read time in the viewer's time zone** (candidate two). Travel would move rows between days.
- **A `ScriptEngine` protocol with two implementations now** (candidate two). Add it when the second engine is written for the device comparison.
- **Foreground-continuing intent for forms** (candidate one). Unverified, and a link is the long-standing mechanism.

## Judge

The arena calls for a judge from a different model family. None is available in this session, and the user asked for Opus subagents, so the base was picked without one.

## Open questions carried forward

- QuickJS-ng's speed and memory on a device. Decided: QuickJS-ng replaced JavaScriptCore. Open: the time per step and the memory peak in the 30 MB extension, on an iPhone.
- Tinted mode. Decided: the look is never told the mode, so one tree works in every mode; the renderer emulates tinted mode (`accent: true`, image `tint`, `{ light, dark }` colors) and the proof draws tinted and dark cells. Clear mode on the simulator draws accent nodes in the same color as the rest, unlike the emulation, so a mark on an accent disc vanishes there; `look.md` teaches a cutout instead. Open: whether a device matches the emulation in tinted mode.
- How lock screen families reach the look. Only `small` and `medium` exist today.
- Whether an automation should see its table's recent rows, so word of the day does not repeat. Decided in phase 3: each run reads its dataset's last 60 rows and must not repeat them.
- Whether the backend should check the block grammar against a schema generated from the Swift types.
