// What one automation run asks the model and how its reply is checked: the user turn (the table, the owner's prompt,
// the day the row appears, and the recent rows), the JSON schema built from the table's fields, the reader that
// checks kinds, finite numbers, the text limit, and that every field is there, and the repeat check. Plain functions,
// so the runner (runner.ts) only moves data between D1, the model, and these.

import type { UserTurn } from "./request";
import { WEEKDAYS } from "./schedule";
import { type Cell, dayIndex, isoDay, type Kind } from "./wire";

/// How many of a dataset's rows a run reads back: the model is told not to repeat them, and a reply that does is
/// refused. The daily cleanup keeps at least this many rows of each dataset.
export const RECENT_ROWS = 60;
/// A run's output cap: room for low-effort thinking and the JSON around the row, and more for each text field, whose
/// 300 UTF-16 units can take as many tokens in a script with few letters per token. A reply cut off at its cap is
/// asked again with twice the cap, up to `most`.
export const RUN_TOKENS = { base: 1_000, perText: 250, most: 4_000 } as const;
/// The longest text a cell holds, in UTF-16 units, as WIRE.md and a tap's limit say (an emoji counts as 2).
export const TEXT_LIMIT = 300;

/// A recent row's text values by field id, which is what the repeat check and the model see.
export type RecentRow = Record<string, string>;

/// The output cap of a run's first call: `RUN_TOKENS.base` and `perText` for each text field, at most `most`.
export function runMaxTokens(fields: Record<string, Kind>): number {
    const texts = Object.values(fields).filter((kind) => kind === "text").length;
    return Math.min(RUN_TOKENS.most, RUN_TOKENS.base + RUN_TOKENS.perText * texts);
}

/// A reply the reader or the repeat check refused, or one the model was cut off in (`cut`): `line` goes back to the
/// model in the repair turn, and `code`, which names no content, goes to the log.
export class Refused extends Error {
    constructor(
        readonly code: "json" | "missing" | "kind" | "long" | "unicode" | "date" | "repeat" | "cut",
        readonly line: string,
    ) {
        super(line);
    }
}

// --- What the model is asked ---

/// The user turn of a run: the table's fields and kinds, the owner's prompt, the day the row appears, and the recent
/// rows, newest first. A repair adds the line the last reply was refused with.
export function runTurn(
    fields: Record<string, Kind>,
    prompt: string,
    day: number,
    recent: RecentRow[],
    refused?: string,
): UserTurn {
    const lines = ["The table's fields:"];
    for (const [id, kind] of Object.entries(fields)) lines.push(`- ${id}: ${kind}`);
    lines.push("", "The owner's prompt:", prompt, "", `The row appears on ${weekdayName(day)}, ${isoDay(day)}.`, "");
    if (recent.length === 0) lines.push("No rows were written before this one.");
    else {
        lines.push(`The ${recent.length} rows written most recently, newest first. Never repeat one of them:`);
        for (const row of recent) lines.push(JSON.stringify(row));
    }
    if (refused) lines.push("", `Your last reply was refused: ${refused}. Reply again with one new row.`);
    return { text: lines.join("\n") };
}

function weekdayName(day: number): string {
    const name = WEEKDAYS[(((day + 3) % 7) + 7) % 7] ?? "monday";
    return name.charAt(0).toUpperCase() + name.slice(1);
}

const KIND_SCHEMAS: Record<Kind, object> = {
    text: { type: "string" },
    number: { type: "number" },
    bool: { type: "boolean" },
    date: { type: "string", description: "A day, like 2026-11-30" },
};

/// The JSON schema of a reply: an object with exactly the table's fields, each of its kind. Lengths and dates are
/// checked by `readReply`, since providers differ in which schema keywords they enforce.
export function replySchema(fields: Record<string, Kind>): { name: string; schema: object } {
    const ids = Object.keys(fields);
    return {
        name: "row",
        schema: {
            type: "object",
            properties: Object.fromEntries(ids.map((id) => [id, KIND_SCHEMAS[fields[id] as Kind]])),
            required: ids,
            additionalProperties: false,
        },
    };
}

// --- What the model answers ---

/// The cells a reply holds, by field id, in the table's field order. Refused when it is not one JSON object (a code
/// fence around it is read past, for a model that adds one without structured output), when a field is missing, of
/// another kind, a number that is not finite, a text over TEXT_LIMIT or with a lone surrogate (JSON's `\ud83d`
/// escape parses to one, and the phone's reader refuses it), or a date that is not a real day. Text is trimmed. Keys
/// the table does not have are left out.
export function readReply(text: string, fields: Record<string, Kind>): Record<string, Cell> {
    const fenced = /^\s*```(?:json)?\s*\n([\s\S]*?)\n\s*```\s*$/.exec(text);
    let value: unknown;
    try {
        value = JSON.parse(fenced?.[1] ?? text);
    } catch {
        throw new Refused("json", "the reply must be one JSON object with the table's fields, and nothing else");
    }
    if (typeof value !== "object" || value === null || Array.isArray(value)) {
        throw new Refused("json", "the reply must be one JSON object with the table's fields, and nothing else");
    }
    const reply = value as Record<string, unknown>;
    const cells: Record<string, Cell> = {};
    for (const [id, kind] of Object.entries(fields)) {
        if (!Object.hasOwn(reply, id)) throw new Refused("missing", `the reply has no "${id}"`);
        cells[id] = cell(id, kind, reply[id]);
    }
    return cells;
}

function cell(id: string, kind: Kind, value: unknown): Cell {
    switch (kind) {
        case "text": {
            if (typeof value !== "string") throw new Refused("kind", `"${id}" must be text`);
            const text = value.trim();
            if (!text.isWellFormed()) {
                throw new Refused("unicode", `"${id}" holds half of a surrogate pair, which is not a character`);
            }
            if (text.length > TEXT_LIMIT) {
                throw new Refused("long", `"${id}" is ${text.length} characters long, and the limit is ${TEXT_LIMIT}`);
            }
            return { kind, value: text };
        }
        case "number":
            if (typeof value !== "number" || !Number.isFinite(value))
                throw new Refused("kind", `"${id}" must be a number`);
            return { kind, value };
        case "bool":
            if (typeof value !== "boolean") throw new Refused("kind", `"${id}" must be true or false`);
            return { kind, value };
        case "date": {
            const day = typeof value === "string" ? dayOfIso(value) : null;
            if (day === null) throw new Refused("date", `"${id}" must be a day like "2026-11-30"`);
            return { kind, value: day };
        }
    }
}

/// The day index of `YYYY-MM-DD` when it names a real day from 0001-01-01 through 9999-12-31, as `Day(iso:)` reads it.
function dayOfIso(text: string): number | null {
    const match = /^(\d{4})-(\d{2})-(\d{2})$/.exec(text);
    if (!match) return null;
    const [year, month, day] = [Number(match[1]), Number(match[2]), Number(match[3])];
    if (year < 1 || month < 1 || month > 12 || day < 1) return null;
    const index = dayIndex(year, month, day);
    return isoDay(index) === text ? index : null;
}

// --- Repeats ---

/// Refuses cells that repeat one of the recent rows: the same text, ignoring case and surrounding space, as that row
/// in two of the reply's non-empty text fields, or in its only one. One field alone is not enough when there are
/// more, because a field that names a category (word of the day's part of speech, a quote's author) repeats on
/// purpose: refusing it would refuse every word that is a noun, and once each category was used, every reply. The
/// item itself (the word with its part of speech, the question, the quote with its author) repeating matches two.
/// The rule can still refuse every reply of a table whose only non-empty text is a category, so the runner checks a
/// repair's repeats only to log them, and writes it (runner.ts).
export function checkRepeats(cells: Record<string, Cell>, recent: RecentRow[]) {
    const texts = Object.entries(cells).flatMap(([id, cell]) =>
        cell.kind === "text" && cell.value !== "" ? [[id, comparable(cell.value)] as const] : [],
    );
    const needed = Math.min(2, texts.length);
    if (needed === 0) return;
    for (const row of recent) {
        const same = texts.filter(([id, value]) => row[id] !== undefined && comparable(row[id]) === value);
        if (same.length >= needed) {
            const shown = same.map(([id]) => `"${id}": ${JSON.stringify(row[id])}`).join(", ");
            throw new Refused("repeat", `it repeats a recent row (${shown}); write a different one`);
        }
    }
}

function comparable(text: string): string {
    return text.trim().normalize("NFC").toLowerCase();
}
