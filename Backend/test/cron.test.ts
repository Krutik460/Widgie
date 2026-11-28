import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { CLAIM_CRON, CLAIM_MS, CLAIM_PAGE, claimDue, scheduled, UPKEEP_CRON } from "../src/cron";
import type { RunMessage } from "../src/runner";
import { MINUTE } from "../src/schedule";
import { automation, NOW, newAccount, payload, send, upload, WIDGET } from "./helpers/accounts";
import { claim, fakeQueue } from "./helpers/runs";

beforeEach(async () => {
    await env.DB.prepare("DELETE FROM accounts").run();
});

/// An account with `count` automations on as many widgets, each with its run now due at NOW.
async function withAutomations(count: number) {
    const account = await newAccount();
    const entries = [...Array(count).keys()].map((i) =>
        automation({ widget: `${WIDGET.slice(0, 24)}${String(i).padStart(12, "0")}`, automation: "daily" }),
    );
    expect((await send(upload(account.token, payload(entries)))).status).toBe(200);
    return account;
}

async function tasks() {
    const { results } = await env.DB.prepare(
        "SELECT id, once, due_at, claimed_until, attempts FROM tasks ORDER BY id",
    ).all<{ id: number; once: number; due_at: number; claimed_until: number | null; attempts: number }>();
    return results;
}

describe("the claim", () => {
    it("claims every due task once, sends each with its row key and attempts, and counts no attempt", async () => {
        await withAutomations(2);
        const runNows = (await tasks()).filter((task) => task.once === 1);
        const sent = await claim(NOW);
        expect(sent.map((message) => message.task).sort()).toEqual(runNows.map((task) => task.id).sort());
        for (const message of sent) {
            const row = await env.DB.prepare("SELECT row_key, attempts FROM tasks WHERE id = ?")
                .bind(message.task)
                .first<{ row_key: string; attempts: number }>();
            expect(message).toEqual({ task: message.task, rowKey: row?.row_key, attempts: 0 });
        }
        for (const task of await tasks()) {
            if (task.once === 1) expect(task).toMatchObject({ claimed_until: NOW + CLAIM_MS, attempts: 0 });
            else expect(task).toMatchObject({ claimed_until: null, attempts: 0 });
        }
        // A live claim is not claimed again.
        expect(await claim(NOW + MINUTE)).toEqual([]);
    });

    // A new automation's run now and schedule are both due at once (the schedule's lead is longer than its period,
    // so the next row is written now). Run together, they would read the same recent rows and could write one row
    // twice; the schedule waits for the run now, and the run now for a schedule that holds a claim.
    it("claims one task of an automation at a time, the run now first", async () => {
        await withAutomations(1);
        const [schedule, runNow] = [...(await tasks())].sort((a, b) => a.once - b.once);
        expect([schedule?.due_at, runNow?.due_at].every((due) => (due ?? Infinity) <= NOW)).toBe(true);
        expect((await claim(NOW)).map((message) => message.task)).toEqual([runNow?.id]);
        // Neither while the run now holds its claim, nor once it expired: the run now is still due, so it goes again.
        expect(await claim(NOW + MINUTE)).toEqual([]);
        expect((await claim(NOW + CLAIM_MS + 1)).map((message) => message.task)).toEqual([runNow?.id]);

        // A run now that failed gives its claim back and is due later; the schedule may run in the meantime.
        const later = NOW + CLAIM_MS + 2;
        await env.DB.prepare("UPDATE tasks SET claimed_until = NULL, due_at = ? WHERE id = ?")
            .bind(later + MINUTE, runNow?.id)
            .run();
        expect((await claim(later)).map((message) => message.task)).toEqual([schedule?.id]);
        // The run now, due again, waits for the schedule's claim, and then goes before the schedule.
        expect(await claim(later + MINUTE)).toEqual([]);
        expect((await claim(later + CLAIM_MS + 1)).map((message) => message.task)).toEqual([runNow?.id]);
    });

    it("leaves tasks that are not due yet", async () => {
        await withAutomations(1);
        await env.DB.prepare("DELETE FROM tasks WHERE once = 1").run();
        await env.DB.prepare("UPDATE tasks SET due_at = ?")
            .bind(NOW + MINUTE)
            .run();
        const [schedule] = await tasks();
        expect(await claim(NOW)).toEqual([]);
        expect((await claim(NOW + MINUTE)).map((message) => message.task)).toEqual([schedule?.id]);
    });

    it("claims a task again once its claim has expired, still with no attempt counted", async () => {
        await withAutomations(1);
        const first = await claim(NOW);
        expect(first.length).toBe(1);
        expect(await claim(NOW + CLAIM_MS)).toEqual([]);
        const again = await claim(NOW + CLAIM_MS + 1);
        expect(again).toEqual(first);
        for (const task of await tasks()) expect(task.attempts).toBe(0);
    });

    it("never claims one task for two crons at once", async () => {
        await withAutomations(120);
        const due = (await tasks()).filter((task) => task.once === 1).length;
        expect(due).toBeGreaterThan(CLAIM_PAGE);
        const [a, b] = [fakeQueue(), fakeQueue()];
        const counts = await Promise.all([claimDue(env.DB, a, NOW), claimDue(env.DB, b, NOW)]);
        const ids = [...a.sent, ...b.sent].map((message) => message.task);
        expect(new Set(ids).size).toBe(ids.length);
        expect(ids.length).toBe(due);
        expect(counts[0] + counts[1]).toBe(due);
        for (const task of await tasks()) {
            expect(task.claimed_until).toBe(task.once === 1 ? NOW + CLAIM_MS : null);
        }
    });

    it("sends at most a page per batch", async () => {
        await withAutomations(120);
        const batches: number[] = [];
        await claimDue(
            env.DB,
            {
                async sendBatch(messages) {
                    batches.push([...messages].length);
                },
            },
            NOW,
        );
        expect(Math.max(...batches)).toBeLessThanOrEqual(CLAIM_PAGE);
        expect(batches.length).toBeGreaterThan(1);
    });

    it("gives a page back when the queue refuses it, so the next minute claims it again", async () => {
        await withAutomations(120);
        const sent: RunMessage[] = [];
        let calls = 0;
        const refusing = {
            async sendBatch(messages: MessageSendRequest<RunMessage>[]) {
                if (++calls === 2) throw new Error("the queue is unavailable");
                for (const message of messages) sent.push(message.body);
            },
        };
        await expect(claimDue(env.DB, refusing, NOW)).rejects.toThrow("the queue is unavailable");
        expect(sent).toHaveLength(CLAIM_PAGE);
        const claimed = (await tasks()).filter((task) => task.claimed_until !== null);
        expect(claimed.map((task) => task.id).sort()).toEqual(sent.map((message) => message.task).sort());
        const next = await claim(NOW + MINUTE);
        expect(next).toHaveLength(120 - CLAIM_PAGE);
        expect(next.every((message) => message.attempts === 0)).toBe(true);
    });
});

describe("the crons", () => {
    it("claim every minute into RUNS, run the upkeep daily, and refuse any other", async () => {
        await withAutomations(1);
        const queue = fakeQueue();
        const environment = { ...env, RUNS: queue as unknown as Queue };
        await scheduled(CLAIM_CRON, environment, NOW);
        expect(queue.sent.length).toBeGreaterThan(0);
        await expect(scheduled(UPKEEP_CRON, environment, NOW)).resolves.toBeUndefined();
        await expect(scheduled("0 * * * *", environment, NOW)).rejects.toThrow('no cron is "0 * * * *"');
    });
});
