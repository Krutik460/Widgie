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
// deleted, or after them and finds its version gone. The batch's first statement checks the account's revision, so an
// upload that another one overtook between its read and its write writes nothing, reads again, and plans again.

import { sha256, toHex } from "./bytes";
import { BadRequest } from "./request";
import { type Cadence, canonicalZone, leadMs, nextRun, WEEKDAYS, type Weekday } from "./schedule";
import { isName, isObject, isUuid, KINDS, type Kind, mintRowKey } from "./wire";

/// The caps of Spec.Limits that an upload carries: the document's own rules, which the engine enforces too. There are no
/// usage limits for now (runs a day, automations an account); tasks/phase-3-ai-block.md records why.
export const LIMITS = {
    /// Spec.Limits.automations: per widget, since each widget's document has its own.
    perWidget: 4,
    /// Spec.Limits.promptLength, in characters as Swift counts them (grapheme clusters).
    prompt: 2000,
    /// Spec.Limits.fieldsPerTable.
    fields: 16,
} as const;

/// The limit refusals, each a stable code the app acts on.
export type LimitCode = "too-many-on-widget" | "prompt-too-long" | "too-many-fields";

/// A payload over one of LIMITS: its code, a sentence the app can show, and the number that went over.
export class OverLimit extends Error {
    constructor(
        readonly code: LimitCode,
        sentence: string,
        readonly found: number,
    ) {
        super(sentence);
    }
}

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

/// The payload with its time zone's canonical name, or a BadRequest naming the first thing wrong with it, or the
/// first limit it goes over as an OverLimit.
export function parsePayload(value: unknown): Payload {
    if (!isObject(value)) throw new BadRequest("the body must be a JSON object");
    only(value, ["automations", "timeZone"], "the body");
    const timeZone = canonicalZone(value.timeZone);
    if (timeZone === null) throw new BadRequest(`"timeZone" must be a time zone name like "America/Los_Angeles"`);
    if (!Array.isArray(value.automations)) throw new BadRequest('"automations" must be a list');
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
        perWidget.set(widget, (perWidget.get(widget) ?? 0) + 1);
    }
    const crowded = Math.max(0, ...perWidget.values());
    if (crowded > LIMITS.perWidget) {
        throw new OverLimit(
            "too-many-on-widget",
            `A widget has ${crowded} automations, and the limit is ${LIMITS.perWidget} a widget.`,
            crowded,
        );
    }
    return { timeZone, automations };
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
        throw new OverLimit(
            "prompt-too-long",
            `The prompt of "${value.automation}" is ${length} characters, and the limit is ${LIMITS.prompt}.`,
            length,
        );
    }
    if (!isUuid(dataset)) throw new BadRequest('"dataset" must be a lowercase UUID');
    return {
        widget,
        automation: value.automation,
        prompt,
        cadence: cadence(value),
        dataset,
        fields: fieldKinds(fields, value.automation),
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

function fieldKinds(value: unknown, automation: string): Record<string, Kind> {
    if (!isObject(value)) throw new BadRequest('"fields" must map field ids to kinds, like {"word": "text"}');
    const ids = Object.keys(value).sort();
    if (ids.length > LIMITS.fields) {
        throw new OverLimit(
            "too-many-fields",
            `"${automation}" writes ${ids.length} fields, and the limit is ${LIMITS.fields}.`,
            ids.length,
        );
    }
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

/// How many times an upload reads and plans when other uploads of the account keep committing in between.
export const ATTEMPTS = 3;

/// Other uploads of the account committed between this one's read and its write on every attempt.
export class Conflict extends Error {}

/// What an upload plans from: the account's revision and its automations, read in one batch.
interface State {
    revision: number;
    automations: Stored[];
}

/// The deleteRow for each row of one automation still ahead with no deleteRow yet, under the stamp the batch took.
/// The partial indexes `changes_inserted` and `changes_deleted` serve it, so it reads only that automation's rows.
export const TOMBSTONES = `INSERT INTO changes (account, op, dataset, row_key, widget, automation, at, change, written_at)
    SELECT account, 'deleteRow', dataset, row_key, widget, automation, NULL,
        json_object('op', 'deleteRow', 'row', row_key, 'dataset', dataset,
            'stamp', (SELECT CAST(last_stamp AS TEXT) FROM accounts WHERE id = ?1), 'replica', ?2),
        ?3
    FROM changes AS inserted
    WHERE account = ?1 AND widget = ?4 AND automation = ?5 AND op = 'insertRow' AND at > ?3
        AND NOT EXISTS (SELECT 1 FROM changes
            WHERE account = ?1 AND op = 'deleteRow' AND row_key = inserted.row_key)
    ORDER BY id`;

/// Replaces the account's automations with the payload's, in one batch that writes only if the account's revision is
/// still the one it planned from; otherwise it reads and plans again, up to ATTEMPTS times, then throws Conflict. An
/// upload counts as the phone being alive and re-arms a parked account.
export async function replaceAutomations(
    db: D1Database,
    account: { id: string; replica: string },
    payload: Payload,
    now: number,
): Promise<void> {
    const rows = await Promise.all(
        payload.automations.map(async (automation) =>
            stored(automation, await versionOf(automation, payload.timeZone)),
        ),
    );
    for (let attempt = 1; ; attempt++) {
        const state = await readState(db, account.id);
        try {
            await db.batch(replaceStatements(db, account, payload.timeZone, rows, state, now));
            return;
        } catch (error) {
            // A revision that moved is another upload's commit; anything else is this batch's own failure.
            const revision = await db
                .prepare("SELECT revision FROM accounts WHERE id = ?")
                .bind(account.id)
                .first<number>("revision");
            if (revision === state.revision) throw error;
            if (attempt === ATTEMPTS) throw new Conflict();
        }
    }
}

async function readState(db: D1Database, id: string): Promise<State> {
    const [account, automations] = await db.batch([
        db.prepare("SELECT revision FROM accounts WHERE id = ?").bind(id),
        db
            .prepare(
                "SELECT widget, automation, version, prompt, every, at, weekday, dataset, fields FROM automations WHERE account = ?",
            )
            .bind(id),
    ]);
    const row = account?.results[0] as { revision: number } | undefined;
    if (!row) throw new Error("the account is gone");
    return { revision: row.revision, automations: (automations?.results ?? []) as Stored[] };
}

/// The batch that turns `state` into `rows`. Its first statement is the revision check: on a mismatch it sets revision
/// to NULL, which the NOT NULL constraint refuses, and D1 rolls the whole batch back.
function replaceStatements(
    db: D1Database,
    account: { id: string; replica: string },
    timeZone: string,
    rows: Stored[],
    state: State,
    now: number,
): D1PreparedStatement[] {
    const old = new Map(state.automations.map((row) => [`${row.widget}/${row.automation}`, row]));
    const plans: { row: Stored; plan: Plan }[] = [];
    for (const row of rows) {
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
    const statements: D1PreparedStatement[] = [
        // The revision check, and one stamp taken only when it writes changes, in SQL so two writers never share one.
        db
            .prepare(
                `UPDATE accounts SET revision = CASE WHEN revision = ?1 THEN revision + 1 END, time_zone = ?2,
                     last_stamp = CASE WHEN ?3 THEN max(last_stamp + 1, CAST(?4 AS INTEGER) * 65536) ELSE last_stamp END,
                     pulled_at = max(pulled_at, ?4), parked_at = NULL
                 WHERE id = ?5`,
            )
            .bind(state.revision, timeZone, tombstoned.length > 0 ? 1 : 0, now, id),
    ];
    for (const row of tombstoned) {
        statements.push(db.prepare(TOMBSTONES).bind(id, account.replica, now, row.widget, row.automation));
    }
    for (const row of removed) {
        statements.push(
            db
                .prepare("DELETE FROM automations WHERE account = ? AND widget = ? AND automation = ?")
                .bind(id, row.widget, row.automation),
        );
    }
    for (const { row, plan } of plans) {
        // An unchanged automation keeps its tasks, or gets its schedule back if parking took it.
        if (plan === "same") {
            statements.push(insertTask(db, id, row, scheduleTask(id, row, timeZone, now), true));
            continue;
        }
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
        statements.push(insertTask(db, id, row, scheduleTask(id, row, timeZone, now)));
    }
    return statements;
}
