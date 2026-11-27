// The queue consumer: one automation run per message, which names a task the cron claimed (cron.ts) and the row key
// it held then. A run reads the task with its automation, reads back the dataset's recent rows, asks the model for
// one row, checks it (run.ts), and writes it in one D1 batch with the task moved to its next run.
//
// - The write is guarded by the task's version and row key, read with the task: its first statement takes the
//   account's stamp only while the task still holds both, and otherwise sets the stamp to NULL, which the NOT NULL
//   constraint refuses, so D1 rolls the whole batch back. An upload that changed the automation while the model was
//   answering therefore leaves nothing behind, and two deliveries of one message write the row once.
// - A message names its task by id and row key. When no task holds both, the run was written already (a replay: the
//   task moved on to a new row key, or a run now was deleted) or an upload replaced or removed the task (SQLite may
//   give the replacement the same id, never the same row key): the message is skipped.
// - A failed run (the model gave no answer, or two replies refused) leaves the claim to expire and pushes `due_at`
//   back by a gap that doubles with each attempt, so the cron claims it again later. A run that fails its
//   MAX_ATTEMPTS-th attempt moves the task on to its next run (a run now is deleted), and so does a task claimed more
//   than MAX_ATTEMPTS times, whatever made its runs stop short.
// - Each run logs one line: the task, its outcome, the model, seconds, usage and cost, never the prompt or the row.

import { scheduleTask } from "./automations";
import { callModel, ModelFailure, type ModelReply, type ModelSettings, modelSettings } from "./model";
import { oneLine } from "./request";
import {
    checkRepeats,
    RECENT_ROWS,
    type RecentRow,
    Refused,
    RUN_MAX_TOKENS,
    readReply,
    replySchema,
    runTurn,
} from "./run";
import prompt from "./run-prompt.txt";
import { dayOf, MINUTE, type Weekday } from "./schedule";
import { type Cell, type Change, encodeAroundStamp, type Kind } from "./wire";

/// What the cron sends for each claimed task.
export interface RunMessage {
    task: number;
    /// The row key the task held when it was claimed: once the task has moved on, the message is a replay.
    rowKey: string;
}

export interface RunDependencies {
    fetch: typeof fetch;
    now?: () => number;
    deadlineMs?: number;
}

/// After this many failed attempts a task moves on to its next run.
export const MAX_ATTEMPTS = 5;
/// The gap before a failed run is due again, doubling with each attempt: 15, 30, 60, then 120 minutes. The first is
/// the claim's own length, so the claim and the gap end together.
export const BACKOFF = 15 * MINUTE;

export type Outcome = "written" | "stale" | "skipped" | "retry" | "moved on";

/// A task with its automation and account, as one run reads it.
interface Task {
    id: number;
    account: string;
    widget: string;
    automation: string;
    version: string;
    once: number;
    run_at: number;
    row_key: string;
    attempts: number;
    prompt: string;
    every: "hour" | "day" | "week";
    at: string;
    weekday: Weekday | null;
    dataset: string;
    fields: string;
    time_zone: string | null;
    replica: string;
}

/// Runs each message of a batch at once, so `max_batch_size` and `max_concurrency` together bound the calls to the
/// model service. A run that throws (D1 failing, a bug) is retried by the queue and lands in the dead-letter queue
/// after `max_retries`; its claim expires either way, so the cron claims the task again.
export async function consume(batch: MessageBatch<RunMessage>, env: Cloudflare.Env, deps: RunDependencies) {
    const settings = modelSettings(env);
    await Promise.all(
        batch.messages.map(async (message) => {
            try {
                await runTask(env.DB, settings, message.body, deps);
                message.ack();
            } catch (error) {
                console.error(
                    JSON.stringify({
                        run: "automation",
                        task: message.body.task,
                        outcome: "error",
                        reason: oneLine(String(error)),
                    }),
                );
                message.retry();
            }
        }),
    );
}

/// One run of the task a message names, and what came of it.
export async function runTask(
    db: D1Database,
    settings: ModelSettings,
    message: RunMessage,
    deps: RunDependencies,
): Promise<Outcome> {
    const started = Date.now();
    // The clock is read where it is used: a write is stamped when it is written, after the model has answered.
    const clock = () => deps.now?.() ?? Date.now();
    const log = (outcome: Outcome, extra: Record<string, unknown> = {}) => {
        console.log(
            JSON.stringify({ run: "automation", task: message.task, outcome, ...extra, ms: Date.now() - started }),
        );
        return outcome;
    };

    const task = await db
        .prepare(
            `SELECT t.id, t.account, t.widget, t.automation, t.version, t.once, t.run_at, t.row_key, t.attempts,
                 a.prompt, a.every, a.at, a.weekday, a.dataset, a.fields, acc.time_zone, acc.replica
             FROM tasks AS t
             JOIN automations AS a ON a.account = t.account AND a.widget = t.widget AND a.automation = t.automation
             JOIN accounts AS acc ON acc.id = t.account
             WHERE t.id = ?`,
        )
        .bind(message.task)
        .first<Task>();
    if (task?.row_key !== message.rowKey) return log("skipped");
    const zone = task.time_zone;
    // An account has a zone from its first upload, which is what makes automations and tasks.
    if (zone === null) throw new Error("the task's account has no time zone");
    if (task.attempts > MAX_ATTEMPTS) {
        await moveOn(db, task, zone, clock());
        return log("moved on", { attempts: task.attempts, reason: "claimed too often" });
    }

    const fields = JSON.parse(task.fields) as Record<string, Kind>;
    const day = dayOf(task.run_at, zone);
    const recent = await recentRows(db, task.account, task.dataset);
    const replies: ModelReply[] = [];
    const called = Date.now();
    let cells: Record<string, Cell> | undefined;
    let refused: Refused | undefined;
    let failure: string | undefined;
    // The first call, and one repair that names what was wrong with the first reply.
    for (let call = 0; call < 2 && !cells && !failure; call++) {
        const turn = runTurn(fields, task.prompt, day, recent, refused?.line);
        try {
            const reply = await callModel(settings, prompt, turn, deps.fetch, deps.deadlineMs, {
                maxTokens: RUN_MAX_TOKENS,
                schema: replySchema(fields),
            });
            replies.push(reply);
            const read = readReply(reply.text, fields);
            checkRepeats(read, recent);
            cells = read;
        } catch (error) {
            if (error instanceof Refused) refused = error;
            else if (error instanceof ModelFailure) failure = oneLine(error.reason);
            else throw error;
        }
    }
    const spent = {
        attempts: task.attempts,
        ...spending(replies),
        seconds: Math.round((Date.now() - called) / 100) / 10,
    };

    if (cells) return log((await write(db, task, zone, cells, day, clock())) ? "written" : "stale", spent);
    const reason = failure ?? refused?.code;
    if (task.attempts >= MAX_ATTEMPTS) {
        await moveOn(db, task, zone, clock());
        return log("moved on", { ...spent, reason });
    }
    await db
        .prepare("UPDATE tasks SET due_at = ? WHERE id = ? AND row_key = ?")
        .bind(clock() + BACKOFF * 2 ** (task.attempts - 1), task.id, task.row_key)
        .run();
    return log("retry", { ...spent, reason });
}

/// The model, provider, and why it stopped from the last reply, and the usage and cost of all of them.
function spending(replies: ModelReply[]) {
    const last = replies.at(-1);
    const sum = (pick: (reply: ModelReply) => number) => replies.reduce((total, reply) => total + pick(reply), 0);
    const costs = replies.map((reply) => reply.usage.cost_usd);
    return {
        calls: replies.length,
        model: last?.model ?? null,
        provider: last?.provider ?? null,
        finish: last?.finish ?? null,
        input_tokens: sum((reply) => reply.usage.input_tokens),
        cached_tokens: sum((reply) => reply.usage.cached_tokens),
        output_tokens: sum((reply) => reply.usage.output_tokens),
        cost_usd:
            costs.length > 0 && costs.every((cost) => cost !== null) ? sum((reply) => reply.usage.cost_usd ?? 0) : null,
    };
}

/// The row keys of a dataset's newest rows, newest first, read through `changes_dataset`.
export const LATEST_ROWS = `SELECT row_key FROM changes WHERE account = ?1 AND dataset = ?2 AND op = 'insertRow'
    ORDER BY id DESC LIMIT ?3`;
/// The cells of those rows, oldest change first, so a later one of a field wins.
export const LATEST_CELLS = `SELECT row_key, change FROM changes
    WHERE account = ?1 AND dataset = ?2 AND op = 'setCell' AND row_key IN (${LATEST_ROWS})
    ORDER BY id`;

/// The text values of the dataset's last RECENT_ROWS rows, newest first, read by dataset so a refine that renames the
/// automation keeps its history. Rows with no text are left out.
async function recentRows(db: D1Database, account: string, dataset: string): Promise<RecentRow[]> {
    const [keys, cells] = await db.batch<{ row_key: string; change?: string }>([
        db.prepare(LATEST_ROWS).bind(account, dataset, RECENT_ROWS),
        db.prepare(LATEST_CELLS).bind(account, dataset, RECENT_ROWS),
    ]);
    const rows = new Map<string, RecentRow>((keys?.results ?? []).map((row) => [row.row_key, {}]));
    for (const { row_key, change } of cells?.results ?? []) {
        const parsed = JSON.parse(change ?? "{}") as { field?: string; kind?: string; value?: unknown };
        const row = rows.get(row_key);
        if (row && parsed.kind === "text" && parsed.field && typeof parsed.value === "string") {
            row[parsed.field] = parsed.value;
        }
    }
    return [...rows.values()].filter((row) => Object.keys(row).length > 0);
}

/// Each change of the row, written with the stamp the batch's first statement takes.
const INSERT_CHANGE = `INSERT INTO changes (account, op, dataset, row_key, widget, automation, at, change, written_at)
    VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8 || (SELECT CAST(last_stamp AS TEXT) FROM accounts WHERE id = ?1) || ?9, ?10)`;

/// Writes the row and moves the task on, in one batch that writes only while the task still holds the version and
/// row key it was read with. Answers whether it wrote.
async function write(
    db: D1Database,
    task: Task,
    zone: string,
    cells: Record<string, Cell>,
    day: number,
    now: number,
): Promise<boolean> {
    const common = { row: task.row_key, dataset: task.dataset, stamp: "0", replica: task.replica };
    const changes: Change[] = [
        { ...common, op: "insertRow", day, at: task.run_at },
        ...Object.entries(cells).map(([field, cell]): Change => ({ ...common, op: "setCell", field, ...cell })),
    ];
    const statements = [
        db
            .prepare(
                `UPDATE accounts SET last_stamp = CASE
                     WHEN EXISTS (SELECT 1 FROM tasks WHERE id = ?1 AND row_key = ?2 AND version = ?3)
                     THEN max(last_stamp + 1, CAST(?4 AS INTEGER) * 65536) END
                 WHERE id = ?5`,
            )
            .bind(task.id, task.row_key, task.version, now, task.account),
        ...changes.map((change) => {
            const { head, tail } = encodeAroundStamp(change);
            // widget, automation, and at repeat what an insertRow holds, for the tombstones (automations.ts).
            const insert = change.op === "insertRow";
            return db
                .prepare(INSERT_CHANGE)
                .bind(
                    task.account,
                    change.op,
                    task.dataset,
                    task.row_key,
                    insert ? task.widget : null,
                    insert ? task.automation : null,
                    insert ? task.run_at : null,
                    head,
                    tail,
                    now,
                );
        }),
        nextRun(db, task, zone, now),
    ];
    try {
        await db.batch(statements);
        return true;
    } catch (error) {
        const held = await db
            .prepare("SELECT 1 AS held FROM tasks WHERE id = ? AND row_key = ? AND version = ?")
            .bind(task.id, task.row_key, task.version)
            .first();
        if (held) throw error;
        return false;
    }
}

/// Moves the task on without writing: after its last attempt, or when it was claimed too often.
async function moveOn(db: D1Database, task: Task, zone: string, now: number) {
    await nextRun(db, task, zone, now).run();
}

/// The statement that moves a task to its next run, if it still holds the row key it was read with: a run now is
/// deleted, and the schedule moves to the first run after its own run time, or after now when that has passed, so a
/// late task skips the runs it missed.
function nextRun(db: D1Database, task: Task, zone: string, now: number): D1PreparedStatement {
    if (task.once === 1) {
        return db.prepare("DELETE FROM tasks WHERE id = ? AND row_key = ?").bind(task.id, task.row_key);
    }
    const next = scheduleTask(task.account, task, zone, now, Math.max(task.run_at, now));
    return db
        .prepare(
            `UPDATE tasks SET run_at = ?, row_key = ?, due_at = ?, claimed_until = NULL, attempts = 0
             WHERE id = ? AND row_key = ?`,
        )
        .bind(next.runAt, next.rowKey, next.dueAt, task.id, task.row_key);
}
