# Engine design: synthesis

Two independent designs were produced for the engine package on 2026-11-18. This note records which one is the base, what was taken from the other, and the decisions that override both. Where this note and the other files in this folder disagree, this note wins until those files are updated to match.

## Base

Candidate one. Its `USAGE.md`, `MODULES.md`, and `RATIONALE.md` are in this folder, and its type sketch is the starting point of the package in `Engine/`.

Why it is the base:

- **Smallest interface.** One `Engine` object. Each of the four entry points is one call. The builder methods exist only for code that imports `WidgetBuilder`, and the widget extension does not link it.
- **Stored local day.** A row records the calendar day it was written on, in the writer's local calendar. "Today" is an integer comparison in SQL, and travel never breaks a streak.
- **Proof equals build.** The render tool and the builder share one code path, so an eval and a real build cannot disagree about what passes.
- **Concrete JavaScript boundary.** Text in, text out, one file to swap when the engine is chosen. No protocol until a second engine exists.

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
- **A shared widget is re-proved on arrival.** A document received from another user goes through `build` before it is saved.
- **No seed rows in the document.** The empty state is a state every look must handle, and the proof checks it.
- **Runaway looks.** The builder rejects a look that exceeds its time budget. What the widget does about a look that runs away after it shipped depends on the engine choice, which needs a device. No quarantine table until then.

## Rejected

- **Pure fact table with no row record** (candidate two). Uniform, but day windows then need per-read bucketing in Swift and row existence becomes a convention.
- **Days computed at read time in the viewer's time zone** (candidate two). Travel would move rows between days.
- **A `ScriptEngine` protocol with two implementations now** (candidate two). Add it when the second engine is written for the device comparison.
- **Foreground-continuing intent for forms** (candidate one). Unverified, and a link is the long-standing mechanism.

## Judge

The arena calls for a judge from a different model family. None is available in this session, and the user asked for Opus subagents, so the base was picked without one.

## Open questions carried forward

- JavaScriptCore against an embedded engine. Needs a device.
- How tinted and lock screen modes reach the look. Needs a device.
- Whether an automation should see its table's recent rows, so word of the day does not repeat.
- Whether the backend should check the block grammar against a schema generated from the Swift types.
