// When an automation runs, in the phone's time zone, by the rules of `Schedule.nextRun(after:)` in
// Engine/Sources/Spec/Automations.swift: the Gregorian calendar, Foundation's `.nextTime` matching. A daily or weekly
// time that a daylight saving change skips runs at the moment the clocks change (02:30 runs at 03:00), a time that
// happens twice runs at the first one, and once a run is at one of them the next is the following day. An hourly run
// is at every instant whose wall clock shows its minute, so the repeated hour runs twice and a skipped hour not at all.
// Time zones come from Intl, which carries the same tz database Foundation reads.

import { dayIndex } from "./wire";

export const MINUTE = 60_000;
export const HOUR = 60 * MINUTE;
export const DAY = 24 * HOUR;

export const WEEKDAYS = ["monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday"] as const;
export type Weekday = (typeof WEEKDAYS)[number];

export type Cadence =
    | { every: "hour"; minute: number }
    | { every: "day"; hour: number; minute: number }
    | { every: "week"; on: Weekday; hour: number; minute: number };

/// The most runs a cadence makes in one calendar day, the figure the 60-a-day limit adds up.
export function runsPerDay(cadence: Cadence): number {
    return cadence.every === "hour" ? 24 : 1;
}

/// How far ahead of its run a task is due: one period plus room, so the row is on the phone a full period early.
export const LEADS = {
    hour: { min: 65 * MINUTE, max: 90 * MINUTE },
    day: { min: 26 * HOUR, max: 38 * HOUR },
    week: { min: 7 * DAY, max: 8 * DAY },
} as const;

/// The lead for a cadence at the automation's own stable place in its window, so one time zone's morning does not
/// reach the model service at once. `seed` names the automation (account, widget, automation id).
export function leadMs(every: Cadence["every"], seed: string): number {
    const { min, max } = LEADS[every];
    return min + Math.floor(fraction(seed) * (max - min));
}

/// FNV-1a over the seed's UTF-16 units, as a fraction in [0, 1).
function fraction(seed: string): number {
    let hash = 0x811c9dc5;
    for (let i = 0; i < seed.length; i++) {
        hash ^= seed.charCodeAt(i);
        hash = Math.imul(hash, 0x01000193) >>> 0;
    }
    return hash / 2 ** 32;
}

// --- Time zones ---

const formatters = new Map<string, Intl.DateTimeFormat>();

function formatter(zone: string): Intl.DateTimeFormat {
    let found = formatters.get(zone);
    if (!found) {
        found = new Intl.DateTimeFormat("en-US", {
            timeZone: zone,
            hourCycle: "h23",
            era: "short",
            year: "numeric",
            month: "numeric",
            day: "numeric",
            hour: "numeric",
            minute: "numeric",
            second: "numeric",
        });
        formatters.set(zone, found);
    }
    return found;
}

/// Whether `name` is an IANA time zone name this runtime knows, like "America/New_York" or "UTC". Offsets such as
/// "+05:30", which Intl also takes, are refused: the phone sends `TimeZone.current.identifier`.
export function isTimeZone(name: unknown): name is string {
    if (typeof name !== "string" || name.length > 64 || !/^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/.test(name)) {
        return false;
    }
    try {
        formatter(name);
        return true;
    } catch {
        return false;
    }
}

interface Wall {
    day: number;
    hour: number;
    minute: number;
    second: number;
}

/// The wall clock in `zone` at an instant: the day index and the time of day.
function wall(ms: number, zone: string): Wall {
    const parts: Record<string, string> = {};
    for (const part of formatter(zone).formatToParts(ms)) parts[part.type] = part.value;
    const year = parts.era === "BC" ? 1 - Number(parts.year) : Number(parts.year);
    return {
        day: dayIndex(year, Number(parts.month), Number(parts.day)),
        hour: Number(parts.hour),
        minute: Number(parts.minute),
        second: Number(parts.second),
    };
}

/// The day index of an instant in `zone`: a row's `day` is the day of its `at` in the automation's time zone.
export function dayOf(ms: number, zone: string): number {
    return wall(ms, zone).day;
}

/// The zone's offset from UTC at an instant, in whole minutes.
function offset(ms: number, zone: string): number {
    const local = wall(ms, zone);
    const asUtc = local.day * DAY + local.hour * HOUR + local.minute * MINUTE + local.second * 1000;
    return Math.round((asUtc - Math.floor(ms / 1000) * 1000) / MINUTE);
}

// --- The next run ---

/// The first run strictly after `after`, as milliseconds since 1970.
export function nextRun(cadence: Cadence, zone: string, after: number): number {
    if (cadence.every === "hour") return nextHourly(cadence.minute, zone, after);
    const weekday = cadence.every === "week" ? WEEKDAYS.indexOf(cadence.on) : null;
    // A day earlier than the wall clock's, since a repeated hour can start on the day before.
    const first = wall(after, zone).day - 1;
    for (let day = first; day <= first + 9; day++) {
        if (weekday !== null && weekdayOf(day) !== weekday) continue;
        const runs = instantsAt(zone, day, cadence.hour, cadence.minute);
        // A run at one of a repeated time's instants is that day's run: the next is another day.
        if (runs.includes(after)) continue;
        const later = runs.find((run) => run > after);
        if (later !== undefined) return later;
    }
    throw new Error("no run within ten days");
}

/// Monday is 0. Day 0, 1970-01-01, was a Thursday.
function weekdayOf(day: number): number {
    return (((day + 3) % 7) + 7) % 7;
}

/// The instants whose wall clock in `zone` reads `hour:minute` on `day`, earliest first: one, two where the clocks go
/// back, or, where they skip it, the moment they change.
function instantsAt(zone: string, day: number, hour: number, minute: number): number[] {
    const local = day * DAY + hour * HOUR + minute * MINUTE;
    const offsets = [...new Set([offset(local - DAY, zone), offset(local, zone), offset(local + DAY, zone)])];
    const runs = offsets
        .map((minutes) => local - minutes * MINUTE)
        .filter((run) => offset(run, zone) * MINUTE === local - run)
        .sort((a, b) => a - b);
    if (runs.length > 0) return [...new Set(runs)];

    // Skipped: before the change the zone is behind this wall time, after it ahead. Find the change to the minute.
    const after = Math.max(...offsets);
    let skipped = local - after * MINUTE;
    let changed = local - Math.min(...offsets) * MINUTE;
    while (changed - skipped > MINUTE) {
        const middle = skipped + Math.floor((changed - skipped) / 2 / MINUTE) * MINUTE;
        if (offset(middle, zone) === after) changed = middle;
        else skipped = middle;
    }
    return [changed];
}

/// The first instant after `after` whose wall clock in `zone` shows `minute` and second 0.
function nextHourly(minute: number, zone: string, after: number): number {
    for (let from = after; from < after + 4 * HOUR; from += HOUR) {
        // At most one change within two hours, so the candidate for each offset in effect covers the next hour.
        const offsets = new Set([offset(from, zone), offset(from + 2 * HOUR, zone)]);
        const runs = [...offsets]
            .map((minutes) => nextUtcMinute(from, (((minute - minutes) % 60) + 60) % 60))
            .filter((run) => (((Math.floor(run / MINUTE) + offset(run, zone)) % 60) + 60) % 60 === minute);
        if (runs.length > 0) return Math.min(...runs);
    }
    throw new Error("no hourly run within four hours");
}

/// The first whole minute after `from` whose UTC minute is `utcMinute`.
function nextUtcMinute(from: number, utcMinute: number): number {
    const run = Math.floor(from / HOUR) * HOUR + utcMinute * MINUTE;
    return run > from ? run : run + HOUR;
}
