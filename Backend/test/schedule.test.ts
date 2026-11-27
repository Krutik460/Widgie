// nextRun against the vectors the engine exports (Engine/Vectors/schedule.json, written by
// Engine/Tests/SpecTests/ScheduleTests.swift from `Schedule.nextRun(after:in:)`), so the phone and the server agree on
// every run. Below them, the cases first printed from Foundation's `Calendar.nextDate(... .nextTime)`, which the engine
// called until P3, except the three marked where the server's rule differs from Foundation and the engine now follows
// the server: two where Foundation skips a run, and a repeated time asked from between its two instants, where
// Foundation takes the second and the server has already run.

import { describe, expect, it } from "vitest";
import vectors from "../../Engine/Vectors/schedule.json";
import { cadenceOf } from "../src/automations";
import {
    type Cadence,
    canonicalZone,
    DAY,
    dayOf,
    HOUR,
    LEADS,
    leadMs,
    MINUTE,
    nextRun,
    type Weekday,
} from "../src/schedule";

describe("the engine's vectors", () => {
    it("are format 1 and cover two changes in three zones that change their clocks, in both hemispheres", () => {
        expect(vectors.format).toBe(1);
        const zones = new Set(vectors.cases.map((item) => item.zone));
        for (const zone of ["America/New_York", "America/Santiago", "Australia/Lord_Howe"])
            expect(zones).toContain(zone);
    });

    it.each(vectors.cases)("$name", (item) => {
        const on = "on" in item ? (item.on as Weekday) : null;
        const cadence = cadenceOf({ every: item.every as Cadence["every"], at: item.at, weekday: on });
        let after = Date.parse(item.after);
        const found: string[] = [];
        for (const _ of item.runs) {
            after = nextRun(cadence, item.zone, after);
            found.push(new Date(after).toISOString().replace(".000Z", "Z"));
        }
        expect(found).toEqual(item.runs);
    });
});

const at = (iso: string) => Date.parse(iso);
const iso = (ms: number) => new Date(ms).toISOString().replace(".000Z", "Z");

const daily = (hour: number, minute: number): Cadence => ({ every: "day", hour, minute });
const hourly = (minute: number): Cadence => ({ every: "hour", minute });

/// The next `count` runs, each after the one before, starting after `from`.
function runs(cadence: Cadence, zone: string, from: string, count: number): string[] {
    const out: string[] = [];
    let after = at(from);
    for (let i = 0; i < count; i++) {
        after = nextRun(cadence, zone, after);
        out.push(iso(after));
    }
    return out;
}

describe("a daily run", () => {
    it("runs at its wall-clock time in its zone, as DocumentTests checks in Swift", () => {
        const zone = "America/Los_Angeles";
        expect(iso(nextRun(daily(6, 0), zone, at("2026-11-18T13:00:00Z")))).toBe("2026-11-18T14:00:00Z");
        expect(iso(nextRun(daily(6, 0), zone, at("2026-11-18T14:00:00Z")))).toBe("2026-11-19T14:00:00Z");
        expect(iso(nextRun(daily(6, 0), zone, at("2026-03-08T12:00:00Z")))).toBe("2026-03-08T13:00:00Z");
    });

    it("runs at the moment the clocks spring forward when they skip its time", () => {
        expect(runs(daily(2, 30), "America/New_York", "2026-03-07T12:00:00Z", 3)).toEqual([
            "2026-03-08T07:00:00Z",
            "2026-03-09T06:30:00Z",
            "2026-03-10T06:30:00Z",
        ]);
        expect(runs(daily(1, 0), "Europe/London", "2026-03-28T12:00:00Z", 3)).toEqual([
            "2026-03-29T01:00:00Z",
            "2026-03-30T00:00:00Z",
            "2026-03-31T00:00:00Z",
        ]);
        // Midnight skipped: Santiago and Havana change their clocks at 00:00.
        expect(runs(daily(0, 0), "America/Santiago", "2026-09-05T12:00:00Z", 3)).toEqual([
            "2026-09-06T04:00:00Z",
            "2026-09-07T03:00:00Z",
            "2026-09-08T03:00:00Z",
        ]);
        expect(runs(daily(0, 30), "America/Havana", "2026-03-07T12:00:00Z", 3)).toEqual([
            "2026-03-08T05:00:00Z",
            "2026-03-09T04:30:00Z",
            "2026-03-10T04:30:00Z",
        ]);
    });

    it("runs once, at the first, when the clocks fall back and its time happens twice", () => {
        expect(runs(daily(1, 30), "America/New_York", "2026-10-31T12:00:00Z", 3)).toEqual([
            "2026-11-01T05:30:00Z",
            "2026-11-02T06:30:00Z",
            "2026-11-03T06:30:00Z",
        ]);
        expect(runs(daily(1, 0), "Europe/London", "2026-10-24T12:00:00Z", 3)).toEqual([
            "2026-10-25T00:00:00Z",
            "2026-10-26T01:00:00Z",
            "2026-10-27T01:00:00Z",
        ]);
        // Lord Howe moves its clocks by half an hour.
        expect(runs(daily(1, 45), "Australia/Lord_Howe", "2026-04-04T00:00:00Z", 3)).toEqual([
            "2026-04-04T14:45:00Z",
            "2026-04-05T15:15:00Z",
            "2026-04-06T15:15:00Z",
        ]);
    });

    // Foundation answers the second instant (06:30Z) when asked from between the two. The server's rule: a day whose
    // first instant is at or before `after` has had its run, so the next is the following day and the time runs once.
    it("never takes the second of a repeated time, even asked from between the two (Foundation does)", () => {
        const zone = "America/New_York";
        expect(iso(nextRun(daily(1, 30), zone, at("2026-11-01T05:29:00Z")))).toBe("2026-11-01T05:30:00Z");
        expect(iso(nextRun(daily(1, 30), zone, at("2026-11-01T05:30:00Z")))).toBe("2026-11-02T06:30:00Z");
        expect(iso(nextRun(daily(1, 30), zone, at("2026-11-01T05:31:00Z")))).toBe("2026-11-02T06:30:00Z");
        expect(iso(nextRun(daily(1, 30), zone, at("2026-11-01T06:00:00Z")))).toBe("2026-11-02T06:30:00Z");
        expect(iso(nextRun(daily(1, 30), zone, at("2026-11-01T06:30:00Z")))).toBe("2026-11-02T06:30:00Z");
        const sunday: Cadence = { every: "week", on: "sunday", hour: 1, minute: 30 };
        expect(iso(nextRun(sunday, zone, at("2026-11-01T06:00:00Z")))).toBe("2026-11-08T06:30:00Z");
        expect(iso(nextRun(daily(2, 30), zone, at("2026-03-08T06:59:00Z")))).toBe("2026-03-08T07:00:00Z");
        expect(iso(nextRun(daily(2, 30), zone, at("2026-03-08T07:00:00Z")))).toBe("2026-03-09T06:30:00Z");
    });

    it("keeps half-hour zones", () => {
        expect(runs(daily(6, 0), "Asia/Kolkata", "2026-03-07T12:00:00Z", 2)).toEqual([
            "2026-03-08T00:30:00Z",
            "2026-03-09T00:30:00Z",
        ]);
    });

    it("runs at 06:00 local on every day of a year, in zones that change their clocks and zones that do not", () => {
        for (const zone of ["America/New_York", "Europe/London", "Australia/Sydney", "Asia/Tokyo", "UTC"]) {
            let after = at("2026-01-01T00:00:00Z");
            for (let i = 0; i < 365; i++) {
                const run = nextRun(daily(6, 0), zone, after);
                const local = new Intl.DateTimeFormat("en-GB", {
                    timeZone: zone,
                    hour: "2-digit",
                    minute: "2-digit",
                    hourCycle: "h23",
                }).format(run);
                expect(local, `${zone} after ${iso(after)}`).toBe("06:00");
                expect(run - after).toBeGreaterThan(0);
                expect(run - after).toBeLessThanOrEqual(DAY + HOUR);
                after = run;
            }
        }
    });

    // Foundation skips the day here: Lord Howe's clocks jump from 02:00 to 02:30, the hour itself exists, and
    // `.nextTime` moves on to 02:15 the next day. The server keeps the plan's rule, the next time that exists.
    it("runs at the end of a half-hour gap (Foundation skips the day)", () => {
        expect(iso(nextRun(daily(2, 15), "Australia/Lord_Howe", at("2026-10-03T00:00:00Z")))).toBe(
            "2026-10-03T15:30:00Z",
        );
    });
});

describe("a weekly run", () => {
    it("runs on its weekday, as DocumentTests checks in Swift", () => {
        const weekly: Cadence = { every: "week", on: "monday", hour: 9, minute: 0 };
        expect(iso(nextRun(weekly, "UTC", at("2026-11-18T10:00:00Z")))).toBe("2026-11-23T09:00:00Z");
        expect(iso(nextRun(weekly, "UTC", at("2026-11-23T09:00:00Z")))).toBe("2026-11-30T09:00:00Z");
    });

    it("runs once when the clocks fall back on its day", () => {
        const sunday: Cadence = { every: "week", on: "sunday", hour: 1, minute: 30 };
        expect(runs(sunday, "America/New_York", "2026-10-25T12:00:00Z", 2)).toEqual([
            "2026-11-01T05:30:00Z",
            "2026-11-08T06:30:00Z",
        ]);
    });

    // Foundation skips the whole week when a weekday's time is skipped (it answers 2026-03-15). A weekly automation
    // missing a week is worse than running at 03:00, so the server keeps the plan's rule.
    it("runs at the moment the clocks spring forward on its day (Foundation skips the week)", () => {
        const sunday: Cadence = { every: "week", on: "sunday", hour: 2, minute: 30 };
        expect(runs(sunday, "America/New_York", "2026-03-01T12:00:00Z", 2)).toEqual([
            "2026-03-08T07:00:00Z",
            "2026-03-15T06:30:00Z",
        ]);
    });
});

describe("an hourly run", () => {
    it("runs at its minute, as DocumentTests checks in Swift", () => {
        expect(iso(nextRun(hourly(15), "UTC", at("2026-11-18T10:20:00Z")))).toBe("2026-11-18T11:15:00Z");
        expect(iso(nextRun(hourly(15), "UTC", at("2026-11-18T11:15:00Z")))).toBe("2026-11-18T12:15:00Z");
    });

    it("runs at every instant that shows its minute: the skipped hour not at all, the repeated hour twice", () => {
        expect(runs(hourly(15), "America/New_York", "2026-03-08T05:00:00Z", 4)).toEqual([
            "2026-03-08T05:15:00Z",
            "2026-03-08T06:15:00Z",
            "2026-03-08T07:15:00Z",
            "2026-03-08T08:15:00Z",
        ]);
        expect(runs(hourly(15), "America/New_York", "2026-11-01T04:00:00Z", 4)).toEqual([
            "2026-11-01T04:15:00Z",
            "2026-11-01T05:15:00Z",
            "2026-11-01T06:15:00Z",
            "2026-11-01T07:15:00Z",
        ]);
        expect(runs(hourly(15), "Australia/Lord_Howe", "2026-10-03T13:00:00Z", 4)).toEqual([
            "2026-10-03T13:45:00Z",
            "2026-10-03T14:45:00Z",
            "2026-10-03T16:15:00Z",
            "2026-10-03T17:15:00Z",
        ]);
        expect(runs(hourly(45), "Australia/Lord_Howe", "2026-04-04T13:00:00Z", 4)).toEqual([
            "2026-04-04T13:45:00Z",
            "2026-04-04T14:45:00Z",
            "2026-04-04T15:15:00Z",
            "2026-04-04T16:15:00Z",
        ]);
    });
});

describe("leads", () => {
    it("stay in their windows and are stable per automation", () => {
        for (const every of ["hour", "day", "week"] as const) {
            const seen = new Set<number>();
            for (let i = 0; i < 200; i++) {
                const lead = leadMs(every, `account/widget/automation${i}`);
                expect(lead).toBeGreaterThanOrEqual(LEADS[every].min);
                expect(lead).toBeLessThan(LEADS[every].max);
                expect(leadMs(every, `account/widget/automation${i}`)).toBe(lead);
                seen.add(Math.floor((lead - LEADS[every].min) / ((LEADS[every].max - LEADS[every].min) / 4)));
            }
            // Spread over the window, not bunched at one end.
            expect(seen.size).toBe(4);
        }
        expect(LEADS.day).toEqual({ min: 26 * HOUR, max: 38 * HOUR });
        expect(LEADS.week).toEqual({ min: 7 * DAY, max: 8 * DAY });
        expect(LEADS.hour).toEqual({ min: 65 * MINUTE, max: 90 * MINUTE });
    });
});

it("knows IANA time zone names and nothing else", () => {
    for (const zone of ["America/New_York", "UTC", "Asia/Kolkata", "Etc/GMT+5", "America/Argentina/Buenos_Aires"]) {
        expect(canonicalZone(zone), zone).not.toBeNull();
    }
    for (const zone of ["+05:30", "-08:00", "Mars/Olympus_Mons", "", "America/New York", "UTC ", 5, null]) {
        expect(canonicalZone(zone), String(zone)).toBeNull();
    }
});

it("answers one canonical name for every spelling of a zone", () => {
    expect(canonicalZone("America/New_York")).toBe("America/New_York");
    expect(canonicalZone("america/new_york")).toBe("America/New_York");
    expect(canonicalZone("AMERICA/NEW_YORK")).toBe("America/New_York");
    expect(canonicalZone("utc")).toBe("UTC");
    // Links resolve too: the phone sends "Asia/Kolkata", so its spelling cannot be the one required.
    const kolkata = canonicalZone("Asia/Kolkata");
    expect(kolkata).not.toBeNull();
    expect(canonicalZone("asia/kolkata")).toBe(kolkata);
    expect(canonicalZone(kolkata)).toBe(kolkata);
    expect(canonicalZone("US/Eastern")).toBe("America/New_York");
});

it("reads the day of an instant in a zone", () => {
    expect(dayOf(at("2026-11-19T04:59:59.999Z"), "America/New_York")).toBe(20_775);
    expect(dayOf(at("2026-11-19T05:00:00Z"), "America/New_York")).toBe(20_776);
});
