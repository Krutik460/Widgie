// The good cases in Engine/Vectors/wire.json, the file the Swift engine's WireTests also checks: the Worker writes
// each change and page byte for byte from what the vector means. The refusal cases (badChanges, badPages) test a
// reader, and in phase 3 the Worker reads no changes or pages, so they wait for phase 4, when the phone's changes
// reach the server and the Worker gets a reader of its own.

import { describe, expect, it } from "vitest";
import vectors from "../../Engine/Vectors/wire.json";
import { dayOf } from "../src/schedule";
import {
    type Change,
    dayIndex,
    encodeAroundStamp,
    encodeChange,
    encodePage,
    isoDay,
    isRowKey,
    mintRowKey,
    nextStamp,
    parseStamp,
    rowKeyMs,
    stampOf,
    stampParts,
    WireError,
} from "../src/wire";

it("reads format 1", () => {
    expect(vectors.format).toBe(1);
});

describe("stamps", () => {
    it.each(vectors.stamps)("$name", ({ ms, counter, stamp }) => {
        expect(stampOf(ms, counter)).toBe(stamp);
        expect(stampParts(stamp)).toEqual({ ms, counter });
    });

    it.each(vectors.badStamps)("refuses $name", ({ stamp }) => {
        expect(() => parseStamp(stamp)).toThrow(WireError);
    });

    it("moves past the last stamp, and to the clock when the clock is ahead", () => {
        const ms = 1_794_978_000_000;
        const clock = BigInt(stampOf(ms, 0));
        expect(nextStamp(0n, ms)).toBe(clock);
        expect(nextStamp(clock, ms)).toBe(clock + 1n);
        expect(nextStamp(clock + 5n, ms - 1000)).toBe(clock + 6n);
    });
});

describe("days", () => {
    it.each(vectors.days)("$name", ({ at, timeZone, day, date }) => {
        expect(dayOf(at, timeZone)).toBe(day);
        expect(isoDay(day)).toBe(date);
        expect(dayIndexOf(date)).toBe(day);
    });

    it("spans 0001-01-01 through 9999-12-31", () => {
        expect(isoDay(-719_162)).toBe("0001-01-01");
        expect(isoDay(2_932_896)).toBe("9999-12-31");
        expect(dayIndexOf("1970-01-01")).toBe(0);
    });
});

describe("row keys", () => {
    it.each(vectors.keys)("$name", ({ key, ms }) => {
        expect(isRowKey(key)).toBe(true);
        expect(rowKeyMs(key)).toBe(ms);
    });

    it.each(vectors.badKeys)("is not $name", ({ key }) => {
        expect(isRowKey(key)).toBe(false);
    });

    it("mints a UUIDv7 carrying its milliseconds, different every time", () => {
        for (const ms of [0, 1_794_891_600_000, 281_474_976_710_655]) {
            const key = mintRowKey(ms);
            expect(isRowKey(key)).toBe(true);
            expect(rowKeyMs(key)).toBe(ms);
        }
        expect(mintRowKey(1)).not.toBe(mintRowKey(1));
    });
});

describe("changes", () => {
    it.each(vectors.changes)("writes $name", ({ wire, means }) => {
        expect(encodeChange(changeMeaning(means))).toBe(JSON.stringify(wire));
    });

    // The runner writes a change whose stamp SQL takes in the same batch, as the bytes on either side of it.
    it.each(vectors.changes)("writes $name around its stamp", ({ wire, means }) => {
        const change = changeMeaning(means);
        const { head, tail } = encodeAroundStamp(change);
        expect(`${head}${change.stamp}${tail}`).toBe(JSON.stringify(wire));
    });

    // JSON.stringify would write a lone surrogate as "\ud83d", which the phone's reader refuses with its whole page.
    it("refuses a string that is not well-formed UTF-16, in a text cell or anywhere else", () => {
        const common = {
            row: "019a1f2e-8c3b-7d4e-9f50-6a7b8c9d0e1f",
            dataset: "4f6c2a1e-3b5d-4e7f-8a9b-0c1d2e3f4a5b",
            stamp: "1",
            replica: "7d9e1f2a-3b4c-4d5e-8f6a-7b8c9d0e1f2a",
        };
        const cell = { ...common, op: "setCell", field: "word", kind: "text" } as const;
        expect(encodeChange({ ...cell, value: "a😀b" })).toContain('"value":"a😀b"');
        for (const change of [
            { ...cell, value: "a\ud83db" },
            { ...cell, value: "\udc00" },
            { ...common, op: "deleteRow", dataset: "\ud800" },
            { ...common, op: "insertRow", day: 1, at: 1, replica: "x\udfff" },
        ] as Change[]) {
            expect(() => encodeChange(change)).toThrow(WireError);
            expect(() => encodeAroundStamp(change)).toThrow(WireError);
        }
    });
});

describe("pages", () => {
    // A pull writes the change bytes the `changes` table stores, so the page writer takes them already encoded.
    it.each(vectors.pages)("writes $name", ({ wire }) => {
        const entries = wire.changes.map(({ id, change }) => ({ id, change: JSON.stringify(change) }));
        expect(encodePage(wire.replica, entries, wire.nextWrite)).toBe(JSON.stringify(wire));
    });
});

function dayIndexOf(date: string): number {
    const [year, month, day] = date.split("-").map(Number);
    return dayIndex(year ?? 0, month ?? 0, day ?? 0);
}

/// The change a vector's `means` describes, built without reading its wire form.
function changeMeaning(means: Record<string, unknown>): Change {
    const common = {
        row: String(means.row),
        dataset: String(means.dataset),
        stamp: stampOf(Number(means.ms), Number(means.counter)),
        replica: String(means.replica),
    };
    if (means.op === "insertRow") {
        return { op: "insertRow", ...common, day: dayIndexOf(String(means.day)), at: Date.parse(String(means.at)) };
    }
    if (means.op === "deleteRow") return { op: "deleteRow", ...common };
    const field = String(means.field);
    if ("text" in means) return { op: "setCell", ...common, field, kind: "text", value: String(means.text) };
    if ("number" in means) return { op: "setCell", ...common, field, kind: "number", value: Number(means.number) };
    if ("bool" in means) return { op: "setCell", ...common, field, kind: "bool", value: Boolean(means.bool) };
    return { op: "setCell", ...common, field, kind: "date", value: dayIndexOf(String(means.date)) };
}
