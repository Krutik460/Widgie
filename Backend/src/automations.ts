// The account's automations: the payload `PUT /v1/automations` takes (docs/engine/WIRE.md), checked against the
// limits of Engine/Sources/Spec/Automations.swift and Spec.swift, and the replace-all that turns it into tasks and
// tombstones in one D1 batch.
//
// An automation's version is the SHA-256 of its prompt, cadence, time zone, dataset, and fields. On replace-all:
// - new, or a changed prompt or table: a run now (so a new widget is never empty and a refine shows at once) and its
//   schedule at the next run;
// - a changed cadence or time zone: only the schedule moves to the new next run, and a pending run now takes the new
//   version;
// - any change or removal: a `deleteRow` for each of its rows whose `at` is still ahead, all under one stamp of the
//   account's automation replica, since a tombstone wins the merge. The version guard in the runner drops any run of
//   the old version still in flight.
// The tombstones are selected inside the batch's transaction, so a runner's write either lands before them and is
// deleted, or after them and finds its version gone.

import { sha256, toHex } from "./bytes";
import { BadRequest } from "./request";
import { type Cadence, isTimeZone, leadMs, nextRun, runsPerDay, WEEKDAYS, type Weekday } from "./schedule";
import { isName, isObject, isUuid, KINDS, type Kind, mintRowKey } from "./wire";

/// The caps of Spec.Limits that an upload carries, and the account's.
export const LIMITS = {
    /// Per account: four automations on each of four widgets.
    automations: 16,
    /// Spec.Limits.automations: per widget, since each widget's document has its own.
    perWidget: 4,
    /// Spec.Limits.promptLength, in characters as Swift counts them (grapheme clusters).
    prompt: 2000,
    /// Spec.Limits.fieldsPerTable.
    fields: 16,
    /// The schedules' runs in one day, over every automation of the account.
    runsPerDay: 60,
} as const;

/// Spec.reservedFieldIDs: a table never declares these, so a payload never carries them.
const RESERVED_FIELDS = [
    "at",
    "by",
    "day",
    "daysAgo",
    "id",
    "minutesAgo",
    "newest",
    "now",
    "oldest",
    "repeat",
    "staysToday",
];

export interface Automation {
    widget: string;
    automation: string;
    prompt: string;
    cadence: Cadence;
    dataset: string;
    /// The writes table's field ids and kinds, sorted by id.
    fields: Record<string, Kind>;
}

export interface Payload {
    timeZone: string;
    automations: Automation[];
}

// --- The payload ---

const ENTRY_KEYS = ["at", "automation", "dataset", "every", "fields", "on", "prompt", "widget"];

/// The payload, or a BadRequest naming the first thing wrong with it.
export function parsePayload(value: unknown): Payload {
    if (!isObject(value)) throw new BadRequest("the body must be a JSON object");
    only(value, ["automations", "timeZone"], "the body");
    if (!isTimeZone(value.timeZone)) {
        throw new BadRequest(`"timeZone" must be a time zone name like "America/Los_Angeles"`);
    }
    if (!Array.isArray(value.automations)) throw new BadRequest('"automations" must be a list');
    if (value.automations.length > LIMITS.automations) {
        throw new BadRequest(`at most ${LIMITS.automations} automations, found ${value.automations.length}`);
    }
    const automations = value.automations.map((entry, index) => {
        try {
            return automation(entry);
        } catch (error) {
            if (error instanceof BadRequest) throw new BadRequest(`automations[${index}]: ${error.message}`);
            throw error;
        }
    });
    const seen = new Set<string>();
    const perWidget = new Map<string, number>();
    for (const { widget, automation } of automations) {
        const key = `${widget}/${automation}`;
        if (seen.has(key)) throw new BadRequest(`automation "${automation}" of widget ${widget} appears twice`);
        seen.add(key);
        const count = (perWidget.get(widget) ?? 0) + 1;
        if (count > LIMITS.perWidget) {
            throw new BadRequest(`at most ${LIMITS.perWidget} automations per widget, found more for ${widget}`);
        }
        perWidget.set(widget, count);
    }
    return { timeZone: value.timeZone, automations };
}

/// The runs the payload's schedules make in a day at most.
export function dailyRuns(payload: Payload): number {
    return payload.automations.reduce((total, automation) => total + runsPerDay(automation.cadence), 0);
}

function automation(value: unknown): Automation {
    if (!isObject(value)) throw new BadRequest("an automation must be an object");
    only(value, ENTRY_KEYS, "an automation");
    for (const key of ["widget", "automation", "prompt", "every", "dataset", "fields"]) {
        if (!Object.hasOwn(value, key)) throw new BadRequest(`needs "${key}"`);
    }
    const { widget, prompt, dataset, fields } = value;
    if (!isUuid(widget)) throw new BadRequest('"widget" must be a widget key, a lowercase UUID');
    if (!isName(value.automation)) {
        throw new BadRequest('"automation" must be an id: a lowercase letter, then letters and digits, at most 32');
    }
    if (typeof prompt !== "string" || prompt === "") throw new BadRequest('"prompt" must be a non-empty string');
    // A string of n UTF-16 units has at most n characters, so only a long one needs counting.
    const length = prompt.length > LIMITS.prompt ? characters(prompt) : 0;
    if (length > LIMITS.prompt) {
        throw new BadRequest(`"prompt" is ${length} characters; keep it to ${LIMITS.prompt} or fewer`);
    }
    if (!isUuid(dataset)) throw new BadRequest('"dataset" must be a lowercase UUID');
    return {
        widget,
        automation: value.automation,
        prompt,
        cadence: cadence(value),
        dataset,
        fields: fieldKinds(fields),
    };
}

/// The cadence as Automations.swift reads it, in the canonical spelling the engine writes: "06:00" and ":15".
function cadence(value: Record<string, unknown>): Cadence {
    const { every, at, on } = value;
    if (every !== "hour" && every !== "day" && every !== "week") {
        throw new BadRequest('"every" must be hour, day, or week');
    }
    if (every !== "week" && Object.hasOwn(value, "on")) {
        throw new BadRequest('"on" names a weekday and works only with "every": "week"');
    }
    if (every === "hour") {
        if (!Object.hasOwn(value, "at")) return { every, minute: 0 };
        if (typeof at !== "string" || !/^:[0-5][0-9]$/.test(at)) {
            throw new BadRequest('"at" for every hour must be the minute, like ":15"');
        }
        return { every, minute: Number(at.slice(1)) };
    }
    if (typeof at !== "string" || !/^([01][0-9]|2[0-3]):[0-5][0-9]$/.test(at)) {
        throw new BadRequest('"at" must be a time of day like "06:00" (24-hour)');
    }
    const hour = Number(at.slice(0, 2));
    const minute = Number(at.slice(3));
    if (every === "day") return { every, hour, minute };
    if (!WEEKDAYS.includes(on as Weekday)) throw new BadRequest(`"on" must be a weekday (${WEEKDAYS.join(", ")})`);
    return { every, on: on as Weekday, hour, minute };
}

function fieldKinds(value: unknown): Record<string, Kind> {
    if (!isObject(value)) throw new BadRequest('"fields" must map field ids to kinds, like {"word": "text"}');
    const ids = Object.keys(value).sort();
    if (ids.length > LIMITS.fields) throw new BadRequest(`at most ${LIMITS.fields} fields, found ${ids.length}`);
    const fields: Record<string, Kind> = {};
    for (const id of ids) {
        if (RESERVED_FIELDS.includes(id)) throw new BadRequest(`field id "${id}" is reserved`);
        if (!isName(id)) {
            throw new BadRequest(
                `field id ${JSON.stringify(id)} must start with a lowercase letter and have only letters and digits, at most 32`,
            );
        }
        const kind = value[id];
        if (!KINDS.includes(kind as Kind)) throw new BadRequest(`field "${id}" must be text, number, bool, or date`);
        fields[id] = kind as Kind;
    }
    return fields;
}

function only(value: Record<string, unknown>, keys: string[], what: string) {
    const unknown = Object.keys(value)
        .filter((key) => !keys.includes(key))
        .sort();
    if (unknown.length > 0) throw new BadRequest(`unknown keys in ${what}: ${unknown.join(", ")}`);
}

const graphemes = new Intl.Segmenter("en", { granularity: "grapheme" });

/// The length Swift's `String.count` gives: grapheme clusters.
function characters(text: string): number {
    let count = 0;
    for (const _ of graphemes.segment(text)) count++;
    return count;
}

// --- Stored automations ---

/// An automation as the `automations` table holds it.
export interface Stored {
    widget: string;
    automation: string;
    version: string;
    prompt: string;
    every: Cadence["every"];
    at: string;
    weekday: Weekday | null;
    dataset: string;
    fields: string;
}

function stored(automation: Automation, version: string): Stored {
    const { cadence } = automation;
    const two = (n: number) => String(n).padStart(2, "0");
    return {
        widget: automation.widget,
        automation: automation.automation,
        version,
        prompt: automation.prompt,
        every: cadence.every,
        at: cadence.every === "hour" ? `:${two(cadence.minute)}` : `${two(cadence.hour)}:${two(cadence.minute)}`,
        weekday: cadence.every === "week" ? cadence.on : null,
        dataset: automation.dataset,
        fields: JSON.stringify(automation.fields),
    };
}

/// The cadence a stored automation runs on.
export function cadenceOf(row: Pick<Stored, "every" | "at" | "weekday">): Cadence {
    if (row.every === "hour") return { every: "hour", minute: Number(row.at.slice(1)) };
    const hour = Number(row.at.slice(0, 2));
    const minute = Number(row.at.slice(3));
    if (row.every === "day") return { every: "day", hour, minute };
    return { every: "week", on: row.weekday as Weekday, hour, minute };
}

/// The version: SHA-256 over everything that changes what a run writes or when.
export async function versionOf(automation: Automation, timeZone: string): Promise<string> {
    const row = stored(automation, "");
    const parts = [row.prompt, row.every, row.at, row.weekday, timeZone, row.dataset, row.fields];
    return toHex(await sha256(JSON.stringify(parts)));
}

// --- Tasks ---

/// The seed of an automation's stable lead.
export function leadSeed(account: string, widget: string, automation: string): string {
    return `${account}/${widget}/${automation}`;
}

/// The schedule task for the run after `now`: its run time, and due a lead ahead of it.
export function scheduleTask(
    account: string,
    row: Pick<Stored, "widget" | "automation" | "every" | "at" | "weekday">,
    timeZone: string,
    now: number,
) {
    const cadence = cadenceOf(row);
    const runAt = nextRun(cadence, timeZone, now);
    const dueAt = runAt - leadMs(cadence.every, leadSeed(account, row.widget, row.automation));
    return { once: 0, runAt, dueAt, rowKey: mintRowKey(now) };
}

/// The statement that adds a task; `ifAbsent` keeps a task of that kind the automation already has.
export function insertTask(
    db: D1Database,
    account: string,
    row: Pick<Stored, "widget" | "automation" | "version">,
    task: { once: number; runAt: number; dueAt: number; rowKey: string },
    ifAbsent = false,
): D1PreparedStatement {
    return db
        .prepare(
            `INSERT ${ifAbsent ? "OR IGNORE " : ""}INTO tasks
                 (account, widget, automation, version, once, run_at, row_key, due_at) VALUES (?, ?, ?, ?, ?, ?, ?, ?)`,
        )
        .bind(account, row.widget, row.automation, row.version, task.once, task.runAt, task.rowKey, task.dueAt);
}

// --- Replace-all ---

type Plan = "new" | "content" | "schedule" | "same";

/// Replaces the account's automations with the payload's, in one batch.
export async function replaceAutomations(
    db: D1Database,
    account: { id: string; replica: string },
    payload: Payload,
    now: number,
): Promise<void> {
    const { results: before } = await db
        .prepare(
            "SELECT widget, automation, version, prompt, every, at, weekday, dataset, fields FROM automations WHERE account = ?",
        )
        .bind(account.id)
        .all<Stored>();
    const old = new Map(before.map((row) => [`${row.widget}/${row.automation}`, row]));

    const plans: { row: Stored; plan: Plan }[] = [];
    for (const automation of payload.automations) {
        const row = stored(automation, await versionOf(automation, payload.timeZone));
        const was = old.get(`${row.widget}/${row.automation}`);
        old.delete(`${row.widget}/${row.automation}`);
        let plan: Plan = "new";
        if (was?.version === row.version) plan = "same";
        else if (was) {
            const content = was.prompt !== row.prompt || was.dataset !== row.dataset || was.fields !== row.fields;
            plan = content ? "content" : "schedule";
        }
        plans.push({ row, plan });
    }
    const removed = [...old.values()];
    const tombstoned = [
        ...plans.filter((p) => p.plan === "content" || p.plan === "schedule").map((p) => p.row),
        ...removed,
    ];

    const id = account.id;
    const statements: D1PreparedStatement[] = [];
    // One stamp for this write, taken only when it writes changes, in SQL so two writers never take the same one.
    statements.push(
        tombstoned.length > 0
            ? db
                  .prepare(
                      "UPDATE accounts SET time_zone = ?1, last_stamp = max(last_stamp + 1, CAST(?2 AS INTEGER) * 65536) WHERE id = ?3",
                  )
                  .bind(payload.timeZone, now, id)
            : db.prepare("UPDATE accounts SET time_zone = ? WHERE id = ?").bind(payload.timeZone, id),
    );
    for (const row of tombstoned) {
        statements.push(
            db
                .prepare(
                    `INSERT INTO changes (account, op, dataset, row_key, widget, automation, at, change, written_at)
                     SELECT account, 'deleteRow', dataset, row_key, widget, automation, NULL,
                         json_object('op', 'deleteRow', 'row', row_key, 'dataset', dataset,
                             'stamp', (SELECT CAST(last_stamp AS TEXT) FROM accounts WHERE id = ?1), 'replica', ?2),
                         ?3
                     FROM changes AS inserted
                     WHERE account = ?1 AND widget = ?4 AND automation = ?5 AND op = 'insertRow' AND at > ?3
                         AND NOT EXISTS (SELECT 1 FROM changes
                             WHERE account = ?1 AND op = 'deleteRow' AND row_key = inserted.row_key)
                     ORDER BY id`,
                )
                .bind(id, account.replica, now, row.widget, row.automation),
        );
    }
    for (const row of removed) {
        statements.push(
            db
                .prepare("DELETE FROM automations WHERE account = ? AND widget = ? AND automation = ?")
                .bind(id, row.widget, row.automation),
        );
    }
    for (const { row, plan } of plans) {
        if (plan === "same") continue;
        statements.push(
            db
                .prepare(
                    `INSERT INTO automations (account, widget, automation, version, prompt, every, at, weekday, dataset, fields)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                     ON CONFLICT (account, widget, automation) DO UPDATE SET version = excluded.version,
                         prompt = excluded.prompt, every = excluded.every, at = excluded.at,
                         weekday = excluded.weekday, dataset = excluded.dataset, fields = excluded.fields`,
                )
                .bind(
                    id,
                    row.widget,
                    row.automation,
                    row.version,
                    row.prompt,
                    row.every,
                    row.at,
                    row.weekday,
                    row.dataset,
                    row.fields,
                ),
        );
        const tasks = "DELETE FROM tasks WHERE account = ? AND widget = ? AND automation = ?";
        if (plan === "schedule") {
            statements.push(db.prepare(`${tasks} AND once = 0`).bind(id, row.widget, row.automation));
            statements.push(
                db
                    .prepare(
                        "UPDATE tasks SET version = ? WHERE account = ? AND widget = ? AND automation = ? AND once = 1",
                    )
                    .bind(row.version, id, row.widget, row.automation),
            );
        } else {
            statements.push(db.prepare(tasks).bind(id, row.widget, row.automation));
            statements.push(insertTask(db, id, row, { once: 1, runAt: now, dueAt: now, rowKey: mintRowKey(now) }));
        }
        statements.push(insertTask(db, id, row, scheduleTask(id, row, payload.timeZone, now)));
    }
    await db.batch(statements);
}
