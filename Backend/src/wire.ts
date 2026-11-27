// The wire format of docs/engine/WIRE.md: stamps, row keys, days, one row change, and the page a pull returns.
// Decoding is as strict as Engine/Sources/Rows/Wire.swift, so both readers of Engine/Vectors/wire.json agree on every
// case: each object has exactly its keys, ids are lowercase, integers have no fraction, and a page decodes whole or
// not at all. Limits that merging enforces (text length, finite numbers, clock skew) are not decoding errors.

export class WireError extends Error {}

/// The largest integer a JSON number holds exactly in JavaScript, 2^53 - 1: the largest change id.
export const LARGEST_ID = Number.MAX_SAFE_INTEGER;
/// Milliseconds from 1970-01-01T00:00:00Z through the end of 9999.
export const INSTANTS = { min: 0, max: 253_402_300_799_999 } as const;
/// Day indexes from 0001-01-01 through 9999-12-31.
export const DAYS = { min: -719_162, max: 2_932_896 } as const;

const LARGEST_STAMP = (1n << 63n) - 1n;

export type Kind = "text" | "number" | "bool" | "date";
export const KINDS: readonly Kind[] = ["text", "number", "bool", "date"];

export type Cell =
    | { kind: "text"; value: string }
    | { kind: "number"; value: number }
    | { kind: "bool"; value: boolean }
    | { kind: "date"; value: number };

interface Common {
    row: string;
    dataset: string;
    /// The stamp in canonical decimal digits.
    stamp: string;
    replica: string;
}

export type Change =
    | (Common & { op: "insertRow"; day: number; at: number })
    | (Common & { op: "setCell"; field: string } & Cell)
    | (Common & { op: "deleteRow" });

export interface Page {
    replica: string;
    changes: { id: number; change: Change }[];
    nextWrite: number | null;
}

// --- Stamps ---

/// The stamp for a millisecond and a counter: `ms << 16 | counter`, in decimal digits.
export function stampOf(ms: number, counter: number): string {
    return ((BigInt(ms) << 16n) | BigInt(counter)).toString();
}

/// The stamp's value, if it is decimal digits of a non-negative 64-bit integer with no sign and no leading zero.
export function parseStamp(value: unknown): bigint {
    const ok = typeof value === "string" && /^(0|[1-9][0-9]{0,18})$/.test(value) && BigInt(value) <= LARGEST_STAMP;
    if (!ok) {
        throw new WireError(
            `a stamp must be a 64-bit integer in decimal digits with no leading zero, not ${shown(value)}`,
        );
    }
    return BigInt(value);
}

/// The millisecond and counter a stamp carries.
export function stampParts(stamp: string): { ms: number; counter: number } {
    const raw = parseStamp(stamp);
    return { ms: Number(raw >> 16n), counter: Number(raw & 0xffffn) };
}

/// The stamp a write takes after `last`: the clock laid out as a stamp, and strictly above `last`, as `Stamp.next`.
/// The accounts table computes the same thing in SQL so two writers never take one stamp.
export function nextStamp(last: bigint, ms: number): bigint {
    const clock = BigInt(ms) << 16n;
    return clock > last ? clock : last + 1n;
}

// --- Ids ---

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
const ROW_KEY = /^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/;
const NAME = /^[a-z][a-zA-Z0-9]{0,31}$/;

/// Any UUID, lowercase and hyphenated.
export function isUuid(value: unknown): value is string {
    return typeof value === "string" && UUID.test(value);
}

/// A UUIDv7: version nibble 7 and variant bits 10.
export function isRowKey(value: unknown): value is string {
    return typeof value === "string" && ROW_KEY.test(value);
}

/// A field, automation, or table id as a document writes it: a lowercase letter, then letters and digits, at most 32.
export function isName(value: unknown): value is string {
    return typeof value === "string" && NAME.test(value);
}

/// The milliseconds in a row key's first 48 bits.
export function rowKeyMs(key: string): number {
    return Number.parseInt(key.slice(0, 8) + key.slice(9, 13), 16);
}

/// A new UUIDv7 for `ms`: 48 bits of milliseconds, the version, 74 random bits, and the variant.
export function mintRowKey(ms: number): string {
    const bytes = crypto.getRandomValues(new Uint8Array(16));
    let time = ms;
    for (let i = 5; i >= 0; i--) {
        bytes[i] = time % 256;
        time = Math.floor(time / 256);
    }
    bytes[6] = 0x70 | ((bytes[6] ?? 0) & 0x0f);
    bytes[8] = 0x80 | ((bytes[8] ?? 0) & 0x3f);
    const hex = [...bytes].map((byte) => byte.toString(16).padStart(2, "0")).join("");
    return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}

/// A random UUIDv4, lowercase: an account id or an automation replica.
export function mintUuid(): string {
    return crypto.randomUUID();
}

// --- Days ---

/// `Day`'s index of a proleptic Gregorian date: days since 1970-01-01. Howard Hinnant's days_from_civil.
export function dayIndex(year: number, month: number, day: number): number {
    const y = month <= 2 ? year - 1 : year;
    const era = Math.floor(y / 400);
    const yoe = y - era * 400;
    const doy = Math.floor((153 * (month + (month > 2 ? -3 : 9)) + 2) / 5) + day - 1;
    const doe = yoe * 365 + Math.floor(yoe / 4) - Math.floor(yoe / 100) + doy;
    return era * 146_097 + doe - 719_468;
}

/// The date of a day index as `YYYY-MM-DD`. Howard Hinnant's civil_from_days.
export function isoDay(index: number): string {
    const z = index + 719_468;
    const era = Math.floor(z / 146_097);
    const doe = z - era * 146_097;
    const yoe = Math.floor((doe - Math.floor(doe / 1460) + Math.floor(doe / 36_524) - Math.floor(doe / 146_096)) / 365);
    const doy = doe - (365 * yoe + Math.floor(yoe / 4) - Math.floor(yoe / 100));
    const mp = Math.floor((5 * doy + 2) / 153);
    const day = doy - Math.floor((153 * mp + 2) / 5) + 1;
    const month = mp < 10 ? mp + 3 : mp - 9;
    const year = yoe + era * 400 + (month <= 2 ? 1 : 0);
    return `${String(year).padStart(4, "0")}-${String(month).padStart(2, "0")}-${String(day).padStart(2, "0")}`;
}

// --- Changes ---

const COMMON = ["dataset", "op", "replica", "row", "stamp"];
const KEYS: Record<Change["op"], string[]> = {
    insertRow: [...COMMON, "at", "day"],
    setCell: [...COMMON, "field", "kind", "value"],
    deleteRow: COMMON,
};

/// One change, decoded strictly.
export function decodeChange(value: unknown): Change {
    if (!isObject(value) || typeof value.op !== "string") {
        throw new WireError(`a change must be an object with an "op", not ${shown(value)}`);
    }
    const op = value.op;
    if (op !== "insertRow" && op !== "setCell" && op !== "deleteRow") {
        throw new WireError(`"op" must be insertRow, setCell, or deleteRow, not ${shown(op)}`);
    }
    exactKeys(value, KEYS[op]);
    if (!isRowKey(value.row)) throw new WireError(`"row" must be a UUIDv7, not ${shown(value.row)}`);
    const common = {
        row: value.row,
        dataset: uuid(value, "dataset"),
        stamp: parseStamp(value.stamp).toString(),
        replica: uuid(value, "replica"),
    };
    if (op === "insertRow") {
        return { op, ...common, day: integer(value, "day", DAYS), at: integer(value, "at", INSTANTS) };
    }
    if (op === "deleteRow") return { op, ...common };
    if (!isName(value.field)) {
        throw new WireError(`"field" must be a field id (a lowercase letter, then letters and digits, at most 32)`);
    }
    return { op, ...common, field: value.field, ...cell(value) };
}

/// One change as the wire writes it, keys in the order WIRE.md lists them.
export function encodeChange(change: Change): string {
    const { op, row, dataset, stamp, replica } = change;
    switch (change.op) {
        case "insertRow":
            return JSON.stringify({ op, row, dataset, day: change.day, at: change.at, stamp, replica });
        case "setCell":
            return JSON.stringify({
                op,
                row,
                dataset,
                field: change.field,
                kind: change.kind,
                value: change.value,
                stamp,
                replica,
            });
        case "deleteRow":
            return JSON.stringify({ op, row, dataset, stamp, replica });
    }
}

// --- Pages ---

/// A page, decoded whole or not at all.
export function decodePage(value: unknown): Page {
    if (!isObject(value)) throw new WireError(`a page must be an object, not ${shown(value)}`);
    exactKeys(value, ["changes", "nextWrite", "replica"]);
    const replica = uuid(value, "replica");
    const nextWrite = value.nextWrite === null ? null : integer(value, "nextWrite", INSTANTS);
    if (!Array.isArray(value.changes)) throw new WireError(`"changes" must be a list`);
    const changes: Page["changes"] = [];
    for (const [index, item] of value.changes.entries()) {
        try {
            if (!isObject(item)) throw new WireError(`an entry must be an object, not ${shown(item)}`);
            exactKeys(item, ["change", "id"]);
            const id = integer(item, "id", { min: 1, max: LARGEST_ID });
            const last = changes.at(-1);
            if (last && id <= last.id) throw new WireError(`id ${id} does not follow id ${last.id}`);
            changes.push({ id, change: decodeChange(item.change) });
        } catch (error) {
            if (error instanceof WireError) throw new WireError(`changes[${index}]: ${error.message}`);
            throw error;
        }
    }
    return { replica, changes, nextWrite };
}

/// A page's bytes, from changes already encoded as the `changes` table stores them, so a pull never re-encodes.
export function encodePage(replica: string, entries: { id: number; change: string }[], nextWrite: number | null) {
    const changes = entries.map((entry) => `{"id":${entry.id},"change":${entry.change}}`).join(",");
    return `{"replica":${JSON.stringify(replica)},"changes":[${changes}],"nextWrite":${nextWrite ?? "null"}}`;
}

// --- Readers ---

function exactKeys(value: Record<string, unknown>, keys: string[]) {
    const missing = keys.find((key) => !Object.hasOwn(value, key));
    if (missing) throw new WireError(`needs "${missing}"`);
    const extra = Object.keys(value)
        .sort()
        .find((key) => !keys.includes(key));
    if (extra) throw new WireError(`unknown key ${shown(extra)} (keys: ${keys.join(", ")})`);
}

function uuid(value: Record<string, unknown>, key: string): string {
    const text = value[key];
    if (!isUuid(text)) throw new WireError(`"${key}" must be a lowercase UUID, not ${shown(text)}`);
    return text;
}

function integer(value: Record<string, unknown>, key: string, range: { min: number; max: number }): number {
    const number = value[key];
    if (typeof number !== "number" || !Number.isInteger(number) || number < range.min || number > range.max) {
        throw new WireError(
            `"${key}" must be a whole number from ${range.min} through ${range.max}, not ${shown(number)}`,
        );
    }
    return number;
}

function cell(value: Record<string, unknown>): Cell {
    const { kind } = value;
    const data = value.value;
    switch (kind) {
        case "text":
            if (typeof data !== "string") throw new WireError(`a text cell's "value" must be a string`);
            return { kind, value: data };
        case "number":
            if (typeof data !== "number") throw new WireError(`a number cell's "value" must be a number`);
            return { kind, value: data };
        case "bool":
            if (typeof data !== "boolean") throw new WireError(`a bool cell's "value" must be true or false`);
            return { kind, value: data };
        case "date":
            return { kind, value: integer(value, "value", DAYS) };
        default:
            throw new WireError(`"kind" must be text, number, bool, or date, not ${shown(kind)}`);
    }
}

export function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}

function shown(value: unknown): string {
    const text = JSON.stringify(value) ?? String(value);
    return text.length > 60 ? `${text.slice(0, 59)}…` : text;
}
