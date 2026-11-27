// The wire format of docs/engine/WIRE.md as the Worker writes it: stamps, row keys, days, one row change, and the page
// a pull returns. In phase 3 the Worker only writes changes and pages, so there is no reader here: the phone's reader
// (Engine/Sources/Rows/Wire.swift) is the strict one, and phase 4, which sends the phone's changes to the server, adds
// a TypeScript reader with the refusal vectors. The tests check every good vector in Engine/Vectors/wire.json against
// this writer byte for byte.

export class WireError extends Error {}

/// The largest integer a JSON number holds exactly in JavaScript, 2^53 - 1: the largest change id.
export const LARGEST_ID = Number.MAX_SAFE_INTEGER;

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

// --- Stamps ---

/// The stamp for a millisecond and a counter: `ms << 16 | counter`, in decimal digits.
export function stampOf(ms: number, counter: number): string {
    return ((BigInt(ms) << 16n) | BigInt(counter)).toString();
}

/// The stamp's value, if it is decimal digits of a non-negative 64-bit integer with no sign and no leading zero.
export function parseStamp(value: unknown): bigint {
    const ok = typeof value === "string" && /^(0|[1-9][0-9]{0,18})$/.test(value) && BigInt(value) <= LARGEST_STAMP;
    if (!ok) throw new WireError(`a stamp must be a 64-bit integer in decimal digits with no leading zero`);
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

// --- Changes and pages ---

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

/// A page's bytes, from changes already encoded as the `changes` table stores them, so a pull never re-encodes.
export function encodePage(replica: string, entries: { id: number; change: string }[], nextWrite: number | null) {
    const changes = entries.map((entry) => `{"id":${entry.id},"change":${entry.change}}`).join(",");
    return `{"replica":${JSON.stringify(replica)},"changes":[${changes}],"nextWrite":${nextWrite ?? "null"}}`;
}

export function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
