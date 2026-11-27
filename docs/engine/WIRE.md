# Wire format

How a row change travels between the server and a phone, and the page a pull returns. Phase 3 sends changes from the server to the phone only: an automation's rows, written ahead of their time. Phase 4 sends the phone's own changes the other way on the same format.

Format 1. The route carries the version (`/v1/changes`), so a server never sends a phone a change its format cannot read.

The shared vectors are in [`Engine/Vectors/wire.json`](../../Engine/Vectors/wire.json). `Engine/Tests/RowsTests/WireTests.swift` decodes every case and merges the `receive` scenarios into a store, and the Worker's tests check the same file. A change to this format changes this page, the vectors, and both readers together. A `receive` scenario ends with the rows a list shows after its pages, each with `mine`: whether it counts as the person's, which a row does when a page named the replica that wrote it.

The bad cases (`badStamps`, `badKeys`, `badChanges`, `badPages`) bind every reader of the format: each must be refused. A case's `error` is a fragment of the line the Swift reader refuses it with, so a case cannot pass by failing for another reason; another reader checks that it refuses, in its own words. A bad page given as `text` is raw bytes, for a case a parsed JSON value cannot hold. In phase 3 the Worker only writes pages, and its tests check that what it writes decodes like the good cases. Phase 4 adds a server reader of the phone's changes, which must then refuse every bad case too, including the two that `JSON.parse` lets through: a key twice in one object, which it resolves to the last value, and a number too large for a 64-bit float, which it reads as `Infinity`.

## Values

| Value | On the wire | Rule |
|---|---|---|
| Stamp | A string of decimal digits | The 64-bit hybrid logical clock value, `ms << 16 \| counter`: milliseconds since 1970-01-01T00:00:00Z in the high 48 bits, a counter in the low 16. Between `"0"` and `"9223372036854775807"`, with no sign, no leading zero, and nothing but digits. A string because the value passes 2^53, the largest integer a JSON number holds exactly in JavaScript. Changes merge by `(stamp, replica)`: the larger stamp wins, and on equal stamps the larger replica, compared as text. |
| Replica | A lowercase UUID string | Who wrote the change: a phone's install, or the account's automation replica. Any UUID version, always lowercase and hyphenated, so equal replicas are equal strings. |
| Row key | A lowercase UUIDv7 string | Version nibble `7`, variant bits `10`. The first 48 bits are the milliseconds the key was minted at; a reader checks the layout, never the time. |
| Dataset | A lowercase UUID string | The rows of one table, which every widget bound to it reads. |
| `at` | An integer | Milliseconds since 1970-01-01T00:00:00Z, from 0 through 253402300799999 (the end of 9999). |
| Day | An integer | `Day`'s index: days since 1970-01-01 in the proleptic Gregorian calendar, from -719162 (0001-01-01) through 2932896 (9999-12-31). A row's `day` and a date cell both use it. |
| Field | A string | A field id as the document writes it: a lowercase letter, then letters and digits, at most 32 in all. |

Numbers that must be integers (`at`, `day`, a date value, a page id, `nextWrite`) have no fraction. Every object has exactly the keys listed for it: a reader refuses a missing key, an unknown key, a key that appears twice, or a value of the wrong type. A `null` is a value of the wrong type everywhere except `nextWrite`. Every number is a finite 64-bit float: a reader refuses one too large for it, like `1e400`, as JSON it cannot read.

## A change

One JSON object for each `Stamped` (`Engine/Sources/Rows/Merge.swift`). `op` names the change, and every change carries `row`, `dataset`, `stamp`, and `replica`.

```json
{ "op": "insertRow", "row": "01a1e7e0-5080-7005-a17c-3e9d2b04f6a8", "dataset": "3f6c1d2e-8b4a-4c9e-9d7f-2a1b3c4d5e6f",
  "day": 20776, "at": 1795086000000, "stamp": "117635678208000000", "replica": "7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b" }

{ "op": "setCell", "row": "01a1e7e0-5080-7005-a17c-3e9d2b04f6a8", "dataset": "3f6c1d2e-8b4a-4c9e-9d7f-2a1b3c4d5e6f",
  "field": "word", "kind": "text", "value": "serendipity",
  "stamp": "117635678208000000", "replica": "7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b" }

{ "op": "deleteRow", "row": "01a1e7e0-5080-7005-a17c-3e9d2b04f6a8", "dataset": "3f6c1d2e-8b4a-4c9e-9d7f-2a1b3c4d5e6f",
  "stamp": "117635914137600000", "replica": "7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b" }
```

| `op` | Its other keys | Merge |
|---|---|---|
| `insertRow` | `day`, `at` | A (row, dataset) keeps the first day and `at` it gets. An insert fills in a tombstone of the same dataset that arrived first, which stays deleted. |
| `setCell` | `field`, `kind`, `value` | Per-field last writer wins by `(stamp, replica)`. The cell keeps its kind beside its value, and a read takes it only as a field of that kind. |
| `deleteRow` | none | A tombstone. Nothing brings the row back, a later `setCell` included. |

A cell's `kind` and `value`:

| `kind` | `value` |
|---|---|
| `text` | A string. A reader decodes any length; merging refuses one over 300 UTF-16 units (an emoji counts as 2), the limit a tap obeys. |
| `number` | A JSON number, always finite (see Values). |
| `bool` | `true` or `false`. |
| `date` | A day index, as above. |

A change that decodes can still be refused or held when it is merged, and neither stops it decoding:

- **Refused** for good: a text over the limit. The watermark passes it. (No decoded number can be refused here, since a number that is not finite never decodes: it refuses its whole page, as below.)
- **Held**: stamped more than 10 minutes ahead of the phone's clock (`RowStore.clockSkew`). It is neither merged nor clamped, and the phone's clock does not advance past it.

## A page

What `GET /v1/changes?after=<watermark>` returns: the account's changes with a server id above `after`, oldest first.

```json
{ "replica": "7d9e4c1a-2b3f-4a5d-8e6f-1c2d3e4f5a6b",
  "changes": [ { "id": 41, "change": { "op": "insertRow", "...": "..." } },
               { "id": 42, "change": { "op": "setCell", "...": "..." } } ],
  "nextWrite": 1795064400000 }
```

| Key | Holds |
|---|---|
| `replica` | The account's automation replica. The phone adds it to its local `mine` set, so rows the account's automations write count as the person's own. |
| `changes` | Entries of `{ "id", "change" }`: `id` is the change's row id in the server's `changes` table, an integer from 1 through 2^53 - 1, strictly increasing through the page (ids may skip). `change` is one change as above. |
| `nextWrite` | When the server next expects to write a change for this account, as milliseconds since 1970, or `null` when it expects none. Never sooner than five minutes after the pull, so a write that waits does not make every render pull. The extension pulls before a render once this has passed. |

A page decodes whole or not at all: one entry that does not decode refuses the page, so nothing of it merges and the watermark stays. That includes bytes that are not JSON the reader accepts, such as a number too large for a 64-bit float or a key twice in one object, anywhere in the page.

The phone merges a page in one transaction (`Engine.receive`). It walks the changes in id order and stops at the first held change, merging nothing past it. The watermark becomes `max(old, the id of the last change before the stop)`, so neither the app nor the extension can move it backwards, and the next pull asks again from there. Refused changes count as passed. The replica goes into `mine` in the same transaction. The commit hook runs only when the page changed a row, a cell, or `mine`, so replaying a page reloads nothing.

## What the server writes

- **One stamp per write.** All the changes of one run share a stamp: the server's clock at write time, laid out as a stamp, and strictly above the last stamp the account's automation replica issued (`max(last + 1, ms << 16)`, as `Stamp.next`).
- **The replica** of every change is the account's automation replica, the same one each page names. Writing under a phone's replica would break the stamp's uniqueness.
- **`at` is the run time**, not the write time: the row is written a period ahead and the phone shows it from `at` on (the reveal rule in `RATIONALE.md`).
- **`day` is the day of `at`** in the automation's time zone, which is the time zone the phone last uploaded, as a day index.
- **The row key is a UUIDv7** minted once per (widget, automation, run time) and kept on the task, so a replayed write reuses the key and lands on the same row.
- **A changed or removed automation** writes a `deleteRow` for each of its rows whose `at` is still in the future.

## The automation payload

What the phone uploads with `PUT /v1/automations`: every automation of the account, replacing what the server held. `Engine.automationPayload()` returns the bytes and their digest.

```json
{ "automations": [ { "at": "06:00", "automation": "daily", "dataset": "3f6c1d2e-8b4a-4c9e-9d7f-2a1b3c4d5e6f",
                     "every": "day", "fields": { "definition": "text", "word": "text" },
                     "prompt": "Pick an interesting, real English word...", "widget": "6d1f1d8e-..." } ],
  "timeZone": "America/New_York" }
```

| Key | Holds |
|---|---|
| `timeZone` | The phone's current time zone, as an IANA name. Every automation runs in it. |
| `automations` | One entry per automation of each live widget, as the revision the widget draws defines it, sorted by widget and then automation id. `widget` is the widget key, `automation` the automation id, `prompt` its prompt, `every`, `at`, and `on` its cadence as the document writes it, `dataset` the dataset its `writes` table is bound to, and `fields` that table's field ids and kinds. |

Keys are sorted and there is no whitespace, so equal payloads are equal bytes. The digest is the SHA-256 of those bytes as lowercase hex. The phone uploads after any change that can move it and whenever the digest differs from the last one the server acknowledged.
