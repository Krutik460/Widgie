// The two crons (wrangler.jsonc's `triggers.crons`, the same in every environment). Every minute: claim the tasks
// that are due and send them to the RUNS queue, whose consumer (runner.ts) makes the model calls, since a cron run can
// wait on only 6 connections at once. Once a day: the upkeep (upkeep.ts).
//
// A claim is one statement, so two cron runs that overlap never claim one task: D1 runs one write at a time, and the
// second finds the task's claim live. A claim only keeps the task out of the next claims while its message waits or
// runs; it is not an attempt, which the runner counts when a run starts. A claim that ends with no run (a lost
// message, or one that waited past the claim) lets the task be claimed again when it expires, so a skipped minute or
// a lost message costs a delay, never a row or an attempt. A page the queue refused is released at once.
//
// The tasks of one automation run one at a time: a task is not claimed while another of its automation holds a live
// claim, and a schedule is not claimed while its automation's run now is due. A new or refined automation's run now
// and schedule are both due at once, and this way the schedule runs after the run now has written, with its row among
// the recent rows, instead of beside it with the same ones.

import type { RunMessage } from "./runner";
import { MINUTE } from "./schedule";
import { upkeep } from "./upkeep";

export const CLAIM_CRON = "* * * * *";
/// 03:17 UTC, away from the top of the hour.
export const UPKEEP_CRON = "17 3 * * *";

/// How long a claim keeps a task from being claimed again: for its message to wait in the queue, and once the run
/// starts, for the run (runner.ts renews it then).
export const CLAIM_MS = 15 * MINUTE;
/// Tasks per claim statement: the most messages one `sendBatch` takes.
export const CLAIM_PAGE = 100;
/// Claim statements per cron run. More due tasks than this wait for the next minute.
export const CLAIM_PAGES = 20;

/// Whether another task of the automation of `tasks AS t` holds a live claim at the time `now` names (a parameter),
/// the claim's guard and the run's (runner.ts). Read through the tasks' unique (account, widget, automation, once).
export function siblingClaimed(now: string): string {
    return `EXISTS (SELECT 1 FROM tasks AS other
        WHERE other.account = t.account AND other.widget = t.widget AND other.automation = t.automation
            AND other.id <> t.id AND other.claimed_until >= ${now})`;
}

/// One page of claims: the due tasks with no live claim, earliest first, read through `tasks_due`, leaving a task
/// whose automation has another task claimed, and a schedule whose automation's run now is due.
export const CLAIM = `UPDATE tasks SET claimed_until = ?1
    WHERE id IN (SELECT t.id FROM tasks AS t
            WHERE t.due_at <= ?2 AND (t.claimed_until IS NULL OR t.claimed_until < ?2) AND NOT ${siblingClaimed("?2")}
                AND NOT (t.once = 0 AND EXISTS (SELECT 1 FROM tasks AS other
                    WHERE other.account = t.account AND other.widget = t.widget AND other.automation = t.automation
                        AND other.once = 1 AND other.due_at <= ?2))
            ORDER BY t.due_at LIMIT ?3)
    RETURNING id, row_key, attempts`;

/// Gives a page's claims back after the queue refused it, unless a later claim took a task since.
const RELEASE =
    "UPDATE tasks SET claimed_until = NULL WHERE claimed_until = ? AND id IN (SELECT value FROM json_each(?))";

/// Runs the cron `cron` names at `now`.
export async function scheduled(cron: string, env: Cloudflare.Env, now: number): Promise<void> {
    const started = Date.now();
    if (cron === CLAIM_CRON) {
        const claimed = await claimDue(env.DB, env.RUNS, now);
        console.log(JSON.stringify({ cron: "claim", claimed, ms: Date.now() - started }));
    } else if (cron === UPKEEP_CRON) {
        const done = await upkeep(env.DB, now);
        console.log(JSON.stringify({ cron: "upkeep", ...done, ms: Date.now() - started }));
    } else {
        throw new Error(`no cron is "${cron}"`);
    }
}

/// Claims the due tasks a page at a time and sends each page to the queue. Answers how many it claimed. A page the
/// queue refuses is released and the error thrown, so those tasks and the pages after them wait for the next minute.
export async function claimDue(
    db: D1Database,
    queue: { sendBatch(messages: MessageSendRequest<RunMessage>[]): Promise<unknown> },
    now: number,
) {
    let claimed = 0;
    for (let page = 0; page < CLAIM_PAGES; page++) {
        const { results } = await db
            .prepare(CLAIM)
            .bind(now + CLAIM_MS, now, CLAIM_PAGE)
            .all<{ id: number; row_key: string; attempts: number }>();
        if (results.length === 0) break;
        try {
            await queue.sendBatch(
                results.map((task) => ({ body: { task: task.id, rowKey: task.row_key, attempts: task.attempts } })),
            );
        } catch (error) {
            const ids = JSON.stringify(results.map((task) => task.id));
            await db
                .prepare(RELEASE)
                .bind(now + CLAIM_MS, ids)
                .run();
            throw error;
        }
        claimed += results.length;
        if (results.length < CLAIM_PAGE) break;
    }
    return claimed;
}
