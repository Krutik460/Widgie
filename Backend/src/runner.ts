// The queue consumer: one automation run per message, which names a task the cron claimed (cron.ts), the row key it
// held then, and the runs it had started. A run starts, reads the task with its automation, reads back the dataset's
// recent rows, asks the model for one row, checks it (run.ts), and writes it in one D1 batch with the task moved to
// its next run.
//
// - A run starts with one statement that counts the attempt and renews the task's claim for the run, only while the
//   task still holds the message's row key and attempt count and no other task of its automation holds a live claim.
//   So of two deliveries of one message, or the messages of two claims (one waited past its claim and the cron claimed
//   the task again), one runs and the others find the count moved and end without calling the model, and a run now
//   and a schedule never run side by side. Claims are not attempts: a lost or late message costs none.
// - The write is guarded by the task's version and row key, read with the task: its first statement takes the
//   account's stamp only while the task still holds both, and otherwise sets the stamp to NULL, which the NOT NULL
//   constraint refuses, so D1 rolls the whole batch back. An upload that changed the automation while the model was
//   answering therefore leaves nothing behind, and a run that outlived its claim writes the row at most once with the
//   run the cron started after it.
// - When no task holds the message's id and row key, the run was written already (the task moved on to a new row key,
//   or a run now was deleted) or an upload replaced or removed the task (SQLite may give the replacement the same id,
//   never the same row key): the message is skipped.
// - A failed run (the model gave no answer, or the replies were refused) gives its claim back and pushes `due_at` back
//   by a gap that doubles with each attempt, so the cron claims it again later. A run that fails its MAX_ATTEMPTS-th
//   attempt moves the task on to its next run (a run now is deleted), and so does a run that starts after
//   MAX_ATTEMPTS runs that never finished (each threw), without calling the model.
// - Each run logs one line: the task, its outcome, the model, seconds, usage and cost, never the prompt or the row.

import { scheduleTask } from "./automations";
import { CLAIM_MS, siblingClaimed } from "./cron";
import { callModel, ModelFailure, type ModelReply, type ModelSettings, modelSettings } from "./model";
import { oneLine } from "./request";
import {
    checkRepeats,
    RECENT_ROWS,
    type RecentRow,
    Refused,
    RUN_TOKENS,
    readReply,
    replySchema,
    runMaxTokens,
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
    /// The runs the task had started when it was claimed: once one more has started, the message is a duplicate.
    attempts: number;
}

export interface RunDependencies {
    fetch: typeof fetch;
    now?: () => number;
    deadlineMs?: number;
}

/// After this many failed attempts a task moves on to its next run.
export const MAX_ATTEMPTS = 5;
/// The gap from a failed run to its task's next attempt, doubling with each attempt: 15, 30, 60, then 120 minutes.
export const BACKOFF = 15 * MINUTE;
/// How long a queue delivery that threw waits before the queue delivers it again.
export const RETRY_DELAY_S = 60;

/// Starts a run of the task ?3 with row key ?4 and attempt count ?5 at ?2: counts the attempt and claims the task
/// until ?1 for the run.
export const START = `UPDATE tasks AS t SET attempts = attempts + 1, claimed_until = ?1
    WHERE id = ?3 AND row_key = ?4 AND attempts = ?5 AND NOT ${siblingClaimed("?2")}`;

/// The line a repair turn gives for a reply the model was cut off in.
const CUT = new Refused("cut", "it was cut off before it ended; think briefly and reply with the row only");

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
/// model service. A run that throws (D1 failing, a bug) is retried by the queue a minute later and lands in the
/// dead-letter queue after `max_retries`; a retry of a run that had started is a no-op, and its claim expires either
/// way, so the cron claims the task again.
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
                message.retry({ delaySeconds: RETRY_DELAY_S });
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

    const startedAt = clock();
    const [start, read] = await db.batch<Task>([
        db.prepare(START).bind(startedAt + CLAIM_MS, startedAt, message.task, message.rowKey, message.attempts),
        db
            .prepare(
                `SELECT t.id, t.account, t.widget, t.automation, t.version, t.once, t.run_at, t.row_key, t.attempts,
                     a.prompt, a.every, a.at, a.weekday, a.dataset, a.fields, acc.time_zone, acc.replica
                 FROM tasks AS t
                 JOIN automations AS a ON a.account = t.account AND a.widget = t.widget AND a.automation = t.automation
                 JOIN accounts AS acc ON acc.id = t.account
                 WHERE t.id = ? AND t.row_key = ?`,
            )
            .bind(message.task, message.rowKey),
    ]);
    const task = read?.results[0];
    if (!task) return log("skipped", { reason: "gone" });
    // Another delivery of this claim started first, or another task of the automation is running.
    if (start?.meta.changes !== 1) return log("skipped", { reason: "busy" });
    if (task.attempts > MAX_ATTEMPTS) {
        await moveOn(db, task, task.time_zone, clock());
        return log("moved on", { attempts: task.attempts, reason: "unfinished runs" });
    }
    const zone = task.time_zone;
    // An account has a zone from its first upload, which is what makes automations and tasks. Without one the run
    // throws, which counts as an attempt, so the task moves on (above) instead of being claimed forever.
    if (zone === null) throw new Error("the task's account has no time zone");

    const fields = JSON.parse(task.fields) as Record<string, Kind>;
    const day = dayOf(task.run_at, zone);
    const recent = await recentRows(db, task.account, task.dataset);
    const schema = replySchema(fields);
    const replies: ModelReply[] = [];
    const called = Date.now();
    let maxTokens = runMaxTokens(fields);
    let cells: Record<string, Cell> | undefined;
    let refused: Refused | undefined;
    let failure: string | undefined;
    let repeated = false;
    // The first call, and one repair that names what was wrong with the first reply.
    for (let call = 0; call < 2 && !cells && !failure; call++) {
        const turn = runTurn(fields, task.prompt, day, recent, refused?.line);
        try {
            const reply = await callModel(settings, prompt, turn, deps.fetch, deps.deadlineMs, { maxTokens, schema });
            replies.push(reply);
            let row: Record<string, Cell>;
            try {
                row = readReply(reply.text, fields);
            } catch (error) {
                throw error instanceof Refused && reply.finish === "length" ? CUT : error;
            }
            // A repair is written even when it repeats: the repeat rule can refuse every reply of some tables (one
            // whose only text is a category), and a repeated row beats a widget that stops getting rows.
            try {
                checkRepeats(row, recent);
            } catch (error) {
                if (!(error instanceof Refused) || call === 0) throw error;
                repeated = true;
            }
            cells = row;
        } catch (error) {
            if (error instanceof Refused) refused = error;
            else if (error instanceof ModelFailure && error.finish === "length") refused = CUT;
            else if (error instanceof ModelFailure) failure = oneLine(error.reason);
            else throw error;
            if (refused === CUT) {
                // A cut reply is asked again only with a larger cap, without which the repair would be cut too.
                const larger = Math.min(RUN_TOKENS.most, maxTokens * 2);
                if (larger === maxTokens) break;
                maxTokens = larger;
            }
        }
    }
    const spent = {
        attempts: task.attempts,
        ...spending(replies),
        seconds: Math.round((Date.now() - called) / 100) / 10,
    };

    if (cells) {
        const written = await write(db, task, zone, cells, day, clock());
        return log(written ? "written" : "stale", { ...spent, ...(repeated ? { reason: "repeat" } : {}) });
    }
    const reason = failure ?? refused?.code;
    if (task.attempts >= MAX_ATTEMPTS) {
        await moveOn(db, task, zone, clock());
        return log("moved on", { ...spent, reason });
    }
    await db
        .prepare("UPDATE tasks SET due_at = ?, claimed_until = NULL WHERE id = ? AND row_key = ? AND attempts = ?")
        .bind(clock() + BACKOFF * 2 ** (task.attempts - 1), task.id, task.row_key, task.attempts)
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

/// Moves the task on without writing: after its last attempt, or after too many runs that never finished.
async function moveOn(db: D1Database, task: Task, zone: string | null, now: number) {
    await nextRun(db, task, zone, now).run();
}

/// The statement that moves a task to its next run, if it still holds the row key it was read with: a run now is
/// deleted, and the schedule moves to the first run after its own run time, or after now when that has passed, so a
/// late task skips the runs it missed. A schedule whose account has no zone has no next run, so it is deleted too;
/// the account's next upload makes it again.
function nextRun(db: D1Database, task: Task, zone: string | null, now: number): D1PreparedStatement {
    if (task.once === 1 || zone === null) {
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
