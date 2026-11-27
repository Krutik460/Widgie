// The two crons (wrangler.jsonc's `triggers.crons`, the same in every environment). Every minute: claim the tasks
// that are due and send them to the RUNS queue, whose consumer (runner.ts) makes the model calls, since a cron run can
// wait on only 6 connections at once. Once a day: the upkeep (upkeep.ts).
//
// A claim is one statement, so two cron runs that overlap never claim one task: D1 runs one write at a time, and the
// second finds the task's claim live. A claim that ends with no write (a run that failed or never ran) lets the task
// be claimed again when it expires, so a skipped minute or a lost message costs a delay, never a row.

import type { RunMessage } from "./runner";
import { MINUTE } from "./schedule";
import { upkeep } from "./upkeep";

export const CLAIM_CRON = "* * * * *";
/// 03:17 UTC, away from the top of the hour.
export const UPKEEP_CRON = "17 3 * * *";

/// How long a claimed task is left to its run before the cron may claim it again.
export const CLAIM_MS = 15 * MINUTE;
/// Tasks per claim statement: the most messages one `sendBatch` takes.
export const CLAIM_PAGE = 100;
/// Claim statements per cron run. More due tasks than this wait for the next minute.
export const CLAIM_PAGES = 20;

/// One page of claims: the due tasks with no live claim, earliest first, read through `tasks_due`.
export const CLAIM = `UPDATE tasks SET claimed_until = ?1, attempts = attempts + 1
    WHERE id IN (SELECT id FROM tasks
            WHERE due_at <= ?2 AND (claimed_until IS NULL OR claimed_until < ?2)
            ORDER BY due_at LIMIT ?3)
    RETURNING id, row_key`;

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

/// Claims the due tasks a page at a time and sends each page to the queue. Answers how many it claimed. A claim adds
/// an attempt, which the runner reads to grow the gap after a failure and to move a task on after the last one.
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
            .all<{ id: number; row_key: string }>();
        if (results.length === 0) break;
        await queue.sendBatch(results.map((task) => ({ body: { task: task.id, rowKey: task.row_key } })));
        claimed += results.length;
        if (results.length < CLAIM_PAGE) break;
    }
    return claimed;
}
