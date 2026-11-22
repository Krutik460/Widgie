<!-- Every json block below is parsed by Tests/SpecTests/ReferenceTests.swift after it adds "name" and "look"
when they are missing. A json block followed by a text block must fail with exactly the line in the text block.
A json block right after the comment "replaces the json block above" is a change to the json block before it,
checked as a refinement of that block, so a text block after it is the line the change gets. -->

# Widget blocks

A widget is one JSON document. It has two halves. The blocks say what data the widget keeps and what a tap does. The look is JavaScript that draws the data, and the look language reference describes it. This reference covers the blocks.

The examples leave out `name` and `look` to stay short. A real document needs both.

## The document

The document is one JSON object with these keys. Every key except `name` and `look` may be left out, and then it is empty.

| Key | Holds |
|---|---|
| `name` | What the widget picker shows, 1 to 40 characters. |
| `look` | The JavaScript source as one string. It defines `function render(ctx)`. |
| `tables` | The data the widget keeps, keyed by table id. |
| `queries` | What the look receives, keyed by query id. Each query id becomes a key of `ctx.data`. |
| `actions` | What a tap does, keyed by action id. A button in the look names one. |
| `automations` | AI writers that add a row on a schedule, keyed by id. |
| `assets` | Images the look may place, keyed by asset id. |
| `samples` | Example data for checking the look, keyed by a name you choose. |
| `format` | Leave it out. The app fills it in. |

An id starts with a lowercase letter and has only letters and digits, at most 32 characters: `glasses`, `doneToday`, `item2`.

A key whose value is `null` counts as absent, as in the look.

## Tables

A table is a list of rows. Each field has one kind.

| Kind | Holds | A row with no value reads as |
|---|---|---|
| `text` | a string | `null` |
| `number` | a number | `null` |
| `bool` | `true` or `false` | `false` |
| `date` | a date such as `"2026-11-18"` | `null` |

Every row also belongs to a day: the day it was written on, or the day an `insertOn` button gave. That day decides which windows the row falls in, so a table with no fields still counts things: one row per glass of water, one row per check-in.

These field ids are reserved: `day`, `daysAgo`, `id`, `newest`, `oldest`, `repeat`.

```json
{
  "tables": {
    "glasses": { "fields": {} },
    "items": { "fields": { "title": "text", "done": "bool", "due": "date", "minutes": "number" } }
  }
}
```

## Queries

A query reads one table. Each query has exactly one of these keys, which names its shape.

| Shape | Target | Other keys | The look receives |
|---|---|---|---|
| `count` | a table | `window`, optional `where` | a number |
| `sum` | a number field, as `"table.field"` | `window`, optional `where` | a number. A row with no value adds nothing. |
| `latest` | a table | `window`, optional `where` | the newest row, or `null` |
| `list` | a table | `window`, `limit`, optional `sort`, optional `where` | a list of rows |
| `streak` | a table, or a number field as `"table.field"` | `goal` (optional for a table), optional `where` | the number of days in a row that reach the goal, ending today, or ending yesterday until today reaches it |
| `daily` | a table, or a number field as `"table.field"` | `days`, optional `where` | a list with one entry per day, oldest first and today last |

`window` is one of:

- `today`: rows written today.
- `week`: rows written in the current week, which starts on the user's first day of the week.
- `month`: rows written in the current calendar month.
- `{ "days": 7 }`: rows written in the last 7 days, today included. Any whole number from 1 to 366.
- `all`: every row.

Every window ends today, so a row on a later day counts from its day on.

`streak` and `daily` measure each day. With a table they count the day's rows. With a number field they add up that field over the day's rows, so `{ "daily": "drinks.ml", "days": 7 }` charts millilitres per day.

`goal` is what a day must reach to keep a `streak` going. With a table it is a number of rows, a whole number from 1 to 100, and it may be left out, and then one row keeps the day. With a number field it is the day's total, a number above 0 and at most 1000000, and it is required.

`where` keeps only rows whose field equals a value. It names one field of the query's table and a value of that field's kind. A `bool` field with no value counts as `false`, so `{ "done": false }` includes new rows nobody has touched. `where` cannot compare a `date` field.

`limit` is the most rows a `list` returns, from 1 to 100. `sort` is `newest` (the default), `oldest`, or a field id. Put `-` before a field id to sort it descending. A row with no value for a text, number, or date sort field comes last, and a `bool` field with no value sorts as `false`.

`days` is how many days a `daily` covers, from 1 to 366.

With `where`, a `streak` or `daily` measures only the rows that match.

```json
{
  "tables": {
    "glasses": { "fields": {} },
    "items": { "fields": { "title": "text", "done": "bool", "minutes": "number" } }
  },
  "queries": {
    "today": { "count": "glasses", "window": "today" },
    "last": { "latest": "glasses", "window": "today" },
    "week": { "daily": "glasses", "days": 7 },
    "open": { "list": "items", "where": { "done": false }, "window": "all", "sort": "oldest", "limit": 20 },
    "left": { "count": "items", "where": { "done": false }, "window": "all" },
    "longest": { "list": "items", "window": "week", "sort": "-minutes", "limit": 3 },
    "minutes": { "sum": "items.minutes", "where": { "done": true }, "window": "today" }
  }
}
```

A habit streak:

```json
{
  "tables": { "checkins": { "fields": {} } },
  "queries": {
    "streak": { "streak": "checkins" },
    "today": { "latest": "checkins", "window": "today" },
    "days": { "daily": "checkins", "days": 35 }
  }
}
```

Day tracking: amounts per day, a goal streak, filtered history, and longer windows.

```json
{
  "tables": {
    "glasses": { "fields": {} },
    "drinks": { "fields": { "ml": "number" } },
    "moods": { "fields": { "mood": "text" } },
    "tasks": { "fields": { "title": "text", "done": "bool", "minutes": "number" } }
  },
  "queries": {
    "mlWeek": { "daily": "drinks.ml", "days": 7 },
    "hydrated": { "streak": "drinks.ml", "goal": 2000 },
    "eightGlasses": { "streak": "glasses", "goal": 8 },
    "happyDays": { "daily": "moods", "where": { "mood": "happy" }, "days": 30 },
    "doneWeek": { "daily": "tasks", "where": { "done": true }, "days": 7 },
    "focus": { "daily": "tasks.minutes", "where": { "done": true }, "days": 14 },
    "lastSeven": { "count": "glasses", "window": { "days": 7 } },
    "mlMonth": { "sum": "drinks.ml", "window": "month" }
  }
}
```

## What the look receives

`ctx.data` has one key per query id, holding the value from the table above.

A row is an object with `id`, `day`, `daysAgo`, and every field of its table:

```js
{ id: "0193f4c2-7d1e-7a3b-9c4e-5f6a7b8c9d0e", day: "2026-11-18", daysAgo: 0, title: "Buy oat milk", done: false }
```

A `daily` entry has the date, the three-letter weekday, and the number of rows that day. A `daily` over a number field also has `sum`, the day's total of that field:

```js
{ date: "2026-11-18", weekday: "Wed", count: 3 }
{ date: "2026-11-18", weekday: "Wed", count: 3, sum: 750 }
```

`ctx.today` is `{ date: "2026-11-18", weekday: "Wed", week: [seven dates of the current week, first day first] }`. The look never reads a clock, so it gets the date from here.

## Actions

An action is what a tap does. Each action has exactly one of these keys, which names its effect.

| Effect | Target | Other keys | The button needs `rowId` |
|---|---|---|---|
| `insert` | a table | optional `values`: field values for the new row | no |
| `insertOn` | a table | optional `values`: field values for the new row | no, but it needs `day` |
| `set` | a field, as `"table.field"` | `to`: the value to store | yes |
| `toggle` | a `bool` field, as `"table.field"` | none | yes |
| `delete` | a table | none | yes |
| `form` | a table | `fields`: a list of field ids to ask for, optional `prompt`: the form's title | optional |

An `insert` row lands on today. An `insertOn` row lands on the date its button gives as `day`, today or one of the 365 days before it, so a person can log a day they forgot. A button whose action needs `rowId` must give the `id` of a row the look received from a query on the action's table. A `form` opens the app, where the user types the values. With a `rowId` the form edits that row. Without one it adds a row.

```json
{
  "tables": { "items": { "fields": { "title": "text", "done": "bool" } } },
  "actions": {
    "add": { "form": "items", "fields": ["title"], "prompt": "New to-do" },
    "toggle": { "toggle": "items.done" },
    "finish": { "set": "items.done", "to": true },
    "remove": { "delete": "items" },
    "quick": { "insert": "items", "values": { "title": "Stretch", "done": false } },
    "late": { "insertOn": "items", "values": { "title": "Stretch", "done": true } }
  }
}
```

## Automations

An automation runs on the server, never on the phone. Each run asks a model the `prompt` and adds one row to the `writes` table. The model fills that table's fields, so give the table the fields the widget shows.

| Key | Holds |
|---|---|
| `prompt` | What to write each time, in plain words. |
| `every` | `hour`, `day`, or `week`. |
| `at` | For `day` and `week`, the time as `"HH:MM"` on a 24-hour clock. For `hour`, the minute as `":MM"`, `":00"` when left out. |
| `on` | For `week` only, the weekday: `monday` through `sunday`. |
| `writes` | The table each run adds a row to. |

The app fills in the user's time zone.

```json
{
  "tables": { "words": { "fields": { "word": "text", "kind": "text", "definition": "text" } } },
  "automations": {
    "daily": {
      "prompt": "Pick an interesting, real English word. Give its part of speech and a one-sentence definition.",
      "every": "day",
      "at": "06:00",
      "writes": "words"
    }
  }
}
```

## Assets

An asset is an image the look may place by id. `about` says what the picture shows. The image bytes travel beside the document, never inside it.

```json
{ "assets": { "reference": { "about": "the picture the user attached" } } }
```

## Samples

A sample is example data. The app draws the look with no rows, with each sample, and with a stress state of its own, in both sizes. Write at least two samples that look like real use: a light day and a busy one.

A sample maps table ids to lists of rows. In a row, `daysAgo` says which day it was written on (0 is today, 1 is yesterday) and `repeat` makes that many identical rows, from 1 to 100. Both may be left out, and then they are 0 and 1. A day with no rows needs no entry. Every other key is a field value. Leave out `id` and `day`, because the app makes them.

The app makes the no-rows state and the stress state itself, named `empty` and `full`. Write neither as a sample, and give no sample those names.

```json
{
  "tables": {
    "glasses": { "fields": {} },
    "items": { "fields": { "title": "text", "done": "bool" } }
  },
  "samples": {
    "morning": {
      "glasses": [{ "daysAgo": 0, "repeat": 2 }, { "daysAgo": 1, "repeat": 6 }],
      "items": [{ "title": "Buy oat milk" }, { "daysAgo": 1, "title": "Call the dentist", "done": true }]
    },
    "goal met": { "glasses": [{ "repeat": 9 }] }
  }
}
```

## Limits

| What | Most |
|---|---|
| tables | 8 |
| fields in a table | 16 |
| queries | 24 |
| actions | 16 |
| automations | 4 |
| assets | 8 |
| an asset's `about` | 200 characters |
| samples | 6 |
| a sample name | 40 characters, on one line |
| rows in one sample, after `repeat` | 1000 |
| `repeat` | 100 |
| `daysAgo` | 400 |
| a text value | 300 characters as JavaScript counts them (an emoji counts as 2) |
| field values `list` and `latest` queries return together (rows times their table's fields, a `latest` is one row) | 1000 |
| a `prompt` | 2000 characters |
| a form `prompt` | 80 characters |
| the look | 65,536 bytes |

## Mistakes and the lines they produce

When a document is wrong, the app answers with one line that says where the problem is and what would be valid. These are the common ones.

A query names a table that does not exist:

```json
{
  "tables": { "glasses": { "fields": {} } },
  "queries": { "today": { "count": "glass", "window": "today" } }
}
```

```text
query "today": no table "glass" (tables: glasses)
```

A `sum` over a field that is not a number:

```json
{
  "tables": { "items": { "fields": { "title": "text", "minutes": "number" } } },
  "queries": { "total": { "sum": "items.title", "window": "all" } }
}
```

```text
query "total": sum needs a number field; "items.title" is text (number fields: items.minutes)
```

A `where` that compares a `bool` field to a string:

```json
{
  "tables": { "items": { "fields": { "title": "text", "done": "bool" } } },
  "queries": { "open": { "count": "items", "where": { "done": "no" }, "window": "all" } }
}
```

```text
query "open", where: "items.done" is a bool field; give true or false, not the string "no"
```

A `streak` with a window:

```json
{
  "tables": { "checkins": { "fields": {} } },
  "queries": { "streak": { "streak": "checkins", "window": "week" } }
}
```

```text
query "streak": streak takes no "window"; it always counts back from today
```

A query without a window:

```json
{
  "tables": { "glasses": { "fields": {} } },
  "queries": { "today": { "count": "glasses" } }
}
```

```text
query "today": count needs "window": today, week, month, all, or {"days": 7} for the last 7 days with today last
```

A `streak` of a number field without a `goal`:

```json
{
  "tables": { "drinks": { "fields": { "ml": "number" } } },
  "queries": { "hydrated": { "streak": "drinks.ml" } }
}
```

```text
query "hydrated": a streak of "drinks.ml" needs "goal": the day's total that keeps the streak, like {"streak": "drinks.ml", "goal": 2000}
```

A `toggle` on a field that is not a `bool`:

```json
{
  "tables": { "items": { "fields": { "title": "text", "done": "bool" } } },
  "actions": { "flip": { "toggle": "items.title" } }
}
```

```text
action "flip": toggle needs a bool field; "items.title" is text (bool fields: items.done)
```

A sample row with a field its table does not have:

```json
{
  "tables": { "glasses": { "fields": {} } },
  "samples": { "busy": { "glasses": [{ "daysAgo": 0, "ml": 250 }] } }
}
```

```text
sample "busy", glasses[0]: no field "ml" in glasses (glasses has no fields)
```

An automation time on a 12-hour clock:

```json
{
  "tables": { "words": { "fields": { "word": "text" } } },
  "automations": { "daily": { "prompt": "Pick a word.", "every": "day", "at": "6am", "writes": "words" } }
}
```

```text
automation "daily": "at" must be a time of day like "06:00" (24-hour), not the string "6am"
```

A change that renames a table. The widget's rows are stored under its table ids, so a change keeps every table id. The widget counted glasses:

```json
{
  "tables": { "glasses": { "fields": {} } },
  "queries": { "today": { "count": "glasses", "window": "today" } },
  "actions": { "drink": { "insert": "glasses" } }
}
```

The change renames the table to count cups:

<!-- replaces the json block above -->
```json
{
  "tables": { "cups": { "fields": {} } },
  "queries": { "today": { "count": "cups", "window": "today" } },
  "actions": { "drink": { "insert": "cups" } }
}
```

```text
table "glasses" is gone; keep every table id so the stored rows carry over
```
