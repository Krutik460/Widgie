// When an automation runs, in the phone's time zone, on the Gregorian calendar. The engine's
// `Schedule.nextRun(after:in:)` (Engine/Sources/Spec/Automations.swift) is a port of this file, and the vectors it
// exports (Engine/Vectors/schedule.json) are checked here too. A daily or weekly time that a daylight saving change
// skips runs at the moment the clocks change (02:30 runs at 03:00). A time that happens twice runs once, at the
// first: a day whose first instant is at or before `after` has had its run. An hourly run is at every instant whose
// wall clock shows its minute, so the repeated hour runs twice and a skipped hour not at all. Time zones come from
// Intl, whose tz database can differ from the one Foundation reads on a phone until both carry the same release.

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

/// Formatters by zone name. The Worker passes only names `canonicalZone` answered, so the cache holds at most one per
/// zone the runtime knows, however many spellings uploads use.
const formatters = new Map<string, Intl.DateTimeFormat>();

function newFormatter(zone: string): Intl.DateTimeFormat {
    return new Intl.DateTimeFormat("en-US", {
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
}

/// The formatter of a zone name, as `canonicalZone` answers it.
function formatter(zone: string): Intl.DateTimeFormat {
    let found = formatters.get(zone);
    if (!found) {
        found = newFormatter(zone);
        formatters.set(zone, found);
    }
    return found;
}

/// The canonical name of an IANA time zone this runtime knows, like "America/New_York" or "UTC", or null. Intl reads a
/// name in any case and resolves links, so every spelling of one zone comes back as one name: "america/new_york" as
/// "America/New_York", and with this runtime's tz data "Asia/Kolkata" as "Asia/Calcutta" and "GMT" as "UTC". The
/// phone's own spelling cannot be required, since `TimeZone.current.identifier` sends "Asia/Kolkata". Offsets such as
/// "+05:30", which Intl also takes, are refused. A runtime whose Intl stops resolving links changes the canonical name
/// of a linked zone, and so the version of its automations, once.
export function canonicalZone(name: unknown): string | null {
    if (typeof name !== "string" || name.length > 64 || !/^[A-Za-z][A-Za-z0-9_+-]*(\/[A-Za-z0-9_+-]+)*$/.test(name)) {
        return null;
    }
    try {
        // A spelling's formatter formats as its canonical zone's does, so it is kept as that one's if there is none.
        const found = newFormatter(name);
        const canonical = found.resolvedOptions().timeZone;
        if (!formatters.has(canonical)) formatters.set(canonical, found);
        return canonical;
    } catch {
        return null;
    }
}

interface Wall {
    day: number;
    hour: number;
    minute: number;
    second: number;
}

/// Wall clocks by zone and instant. A run and an upload ask for some instants more than once (a run's day and the
/// start of its next run's search, the days either side of a daily run's, the upload time for each of its
/// automations), and each one read costs an Intl call, the dearest thing in a run or an upload on the Worker's CPU.
/// Cleared when it holds WALLS.
const walls = new Map<string, Wall>();
const WALLS = 1_024;

/// The wall clock in `zone` at an instant: the day index and the time of day.
function wall(ms: number, zone: string): Wall {
    const key = `${ms} ${zone}`;
    let found = walls.get(key);
    if (!found) {
        found = readWall(ms, zone);
        if (walls.size >= WALLS) walls.clear();
        walls.set(key, found);
    }
    return found;
}

function readWall(ms: number, zone: string): Wall {
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
        // A day whose first instant is not after `after` has had its run, even when a repeated time's second is ahead.
        const run = firstInstant(zone, day, cadence.hour, cadence.minute);
        if (run > after) return run;
    }
    throw new Error("no run within ten days");
}

/// Monday is 0. Day 0, 1970-01-01, was a Thursday.
function weekdayOf(day: number): number {
    return (((day + 3) % 7) + 7) % 7;
}

/// The first instant whose wall clock in `zone` reads `hour:minute` on `day`: the earlier of two where the clocks go
/// back, or, where they skip it, the moment they change.
function firstInstant(zone: string, day: number, hour: number, minute: number): number {
    const local = day * DAY + hour * HOUR + minute * MINUTE;
    const offsets = [...new Set([offset(local - DAY, zone), offset(local, zone), offset(local + DAY, zone)])];
    const runs = offsets
        .map((minutes) => local - minutes * MINUTE)
        .filter((run) => offset(run, zone) * MINUTE === local - run);
    if (runs.length > 0) return Math.min(...runs);

    // Skipped: before the change the zone is behind this wall time, after it ahead. Find the change to the minute.
    const after = Math.max(...offsets);
    let skipped = local - after * MINUTE;
    let changed = local - Math.min(...offsets) * MINUTE;
    while (changed - skipped > MINUTE) {
        const middle = skipped + Math.floor((changed - skipped) / 2 / MINUTE) * MINUTE;
        if (offset(middle, zone) === after) changed = middle;
        else skipped = middle;
    }
    return changed;
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
