import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { CLAIM_CRON, CLAIM_MS, CLAIM_PAGE, claimDue, scheduled, UPKEEP_CRON } from "../src/cron";
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
    it("claims every due task once, adds an attempt, and sends each with its row key", async () => {
        await withAutomations(2);
        const due = (await tasks()).filter((task) => task.due_at <= NOW);
        const sent = await claim(NOW);
        expect(sent.map((message) => message.task).sort()).toEqual(due.map((task) => task.id).sort());
        for (const message of sent) {
            const row = await env.DB.prepare("SELECT row_key FROM tasks WHERE id = ?")
                .bind(message.task)
                .first<{ row_key: string }>();
            expect(message.rowKey).toBe(row?.row_key);
        }
        for (const task of await tasks()) {
            if (task.due_at <= NOW) expect(task).toMatchObject({ claimed_until: NOW + CLAIM_MS, attempts: 1 });
            else expect(task).toMatchObject({ claimed_until: null, attempts: 0 });
        }
        // A live claim is not claimed again.
        expect(await claim(NOW + MINUTE)).toEqual([]);
    });

    // A new schedule is due at once (its lead is longer than its period, so the next row is written now); the task
    // that runs after it is due a period later, as this one is made to be.
    it("leaves tasks that are not due yet", async () => {
        await withAutomations(1);
        await env.DB.prepare("UPDATE tasks SET due_at = ? WHERE once = 0")
            .bind(NOW + MINUTE)
            .run();
        const sent = await claim(NOW);
        const later = (await tasks()).filter((task) => task.due_at > NOW);
        expect(later).toHaveLength(1);
        expect(sent.map((message) => message.task)).not.toContain(later[0]?.id);
        expect(sent).toHaveLength(1);
        expect((await claim(NOW + MINUTE)).map((message) => message.task)).toEqual([later[0]?.id]);
    });

    it("claims a task again once its claim has expired", async () => {
        await withAutomations(1);
        const first = await claim(NOW);
        expect(first.length).toBeGreaterThan(0);
        expect(await claim(NOW + CLAIM_MS)).toEqual([]);
        const again = await claim(NOW + CLAIM_MS + 1);
        expect(again).toEqual(first);
        for (const task of await tasks()) if (task.due_at <= NOW) expect(task.attempts).toBe(2);
    });

    it("never claims one task for two crons at once", async () => {
        await withAutomations(120);
        const due = (await tasks()).filter((task) => task.due_at <= NOW).length;
        expect(due).toBeGreaterThan(CLAIM_PAGE);
        const [a, b] = [fakeQueue(), fakeQueue()];
        const counts = await Promise.all([claimDue(env.DB, a, NOW), claimDue(env.DB, b, NOW)]);
        const ids = [...a.sent, ...b.sent].map((message) => message.task);
        expect(new Set(ids).size).toBe(ids.length);
        expect(ids.length).toBe(due);
        expect(counts[0] + counts[1]).toBe(due);
        for (const task of await tasks()) if (task.due_at <= NOW) expect(task.attempts).toBe(1);
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
