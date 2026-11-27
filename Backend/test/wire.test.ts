// Every case in Engine/Vectors/wire.json, the file the Swift engine's WireTests also checks.

import { describe, expect, it } from "vitest";
import vectors from "../../Engine/Vectors/wire.json";
import { dayOf } from "../src/schedule";
import {
    decodeChange,
    decodePage,
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
        expect(parseStamp(stamp).toString()).toBe(stamp);
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
    });

    it("spans 0001-01-01 through 9999-12-31", () => {
        expect(isoDay(-719_162)).toBe("0001-01-01");
        expect(isoDay(2_932_896)).toBe("9999-12-31");
        expect(isoDay(0)).toBe("1970-01-01");
    });
});

describe("row keys", () => {
    it.each(vectors.keys)("$name", ({ key, ms }) => {
        expect(isRowKey(key)).toBe(true);
        expect(rowKeyMs(key)).toBe(ms);
    });

    it.each(vectors.badKeys)("refuses $name", ({ key }) => {
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
    it.each(vectors.changes)("$name", ({ wire, means }) => {
        const change = decodeChange(wire);
        const { ms, counter } = stampParts(change.stamp);
        const read: Record<string, unknown> = {
            op: change.op,
            row: change.row,
            dataset: change.dataset,
            replica: change.replica,
            ms,
            counter,
        };
        if (change.op === "insertRow") {
            read.day = isoDay(change.day);
            read.at = new Date(change.at).toISOString();
        }
        if (change.op === "setCell") {
            read.field = change.field;
            read[change.kind] = change.kind === "date" ? isoDay(change.value) : change.value;
        }
        expect(read).toEqual(means);
        expect(encodeChange(change)).toBe(JSON.stringify(wire));
    });

    it.each(vectors.badChanges)("refuses $name", ({ wire }) => {
        expect(() => decodeChange(wire)).toThrow(WireError);
    });
});

describe("pages", () => {
    it.each(vectors.pages)("$name", ({ wire }) => {
        const page = decodePage(wire);
        const entries = page.changes.map(({ id, change }) => ({ id, change: encodeChange(change) }));
        expect(encodePage(page.replica, entries, page.nextWrite)).toBe(JSON.stringify(wire));
    });

    it.each(vectors.badPages)("refuses $name", ({ wire }) => {
        expect(() => decodePage(wire)).toThrow(WireError);
    });

    // The receive scenarios merge on the phone; every page they send must decode here too.
    it.each(vectors.receive)("decodes every page of: $name", ({ steps }) => {
        for (const step of steps) expect(() => decodePage(step.page)).not.toThrow();
    });
});
