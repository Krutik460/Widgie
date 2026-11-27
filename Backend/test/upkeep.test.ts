import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { DAY } from "../src/schedule";
import { DELETE_AFTER, deleteIdle, PARK_AFTER, parkIdle } from "../src/upkeep";
import { automation, changes, NOW, newAccount, payload, send, upload } from "./helpers/accounts";

/// An account with an automation, its tasks, and a change, last pulled `idle` before NOW.
async function idleAccount(idle: number) {
    const account = await newAccount();
    await send(upload(account.token, payload([automation()])));
    await env.DB.prepare(
        `INSERT INTO changes (account, op, dataset, row_key, change, written_at)
         VALUES (?, 'deleteRow', 'd', 'r', '{}', ?)`,
    )
        .bind(account.id, NOW)
        .run();
    await env.DB.prepare("UPDATE accounts SET pulled_at = ? WHERE id = ?")
        .bind(NOW - idle, account.id)
        .run();
    return account;
}

async function counts(account: string) {
    const count = async (table: string, column = "account") =>
        (
            await env.DB.prepare(`SELECT count(*) AS n FROM ${table} WHERE ${column} = ?`)
                .bind(account)
                .first<{ n: number }>()
        )?.n;
    return {
        accounts: await count("accounts", "id"),
        automations: await count("automations"),
        tasks: await count("tasks"),
        changes: await count("changes"),
    };
}

describe("idle accounts", () => {
    it("are parked after 30 days without a pull: their tasks go, and a pull brings them back", async () => {
        expect(PARK_AFTER).toBe(30 * DAY);
        const idle = await idleAccount(PARK_AFTER + 1);
        const active = await idleAccount(PARK_AFTER - DAY);
        expect(await parkIdle(env.DB, NOW)).toBeGreaterThanOrEqual(1);
        expect(await counts(idle.id)).toEqual({ accounts: 1, automations: 1, tasks: 0, changes: 1 });
        expect(await counts(active.id)).toEqual({ accounts: 1, automations: 1, tasks: 2, changes: 1 });
        const parked = await env.DB.prepare("SELECT parked_at FROM accounts WHERE id = ?").bind(idle.id).first();
        expect(parked).toEqual({ parked_at: NOW });
        // Parking again leaves the date it was parked.
        await parkIdle(env.DB, NOW + DAY);
        expect(await env.DB.prepare("SELECT parked_at FROM accounts WHERE id = ?").bind(idle.id).first()).toEqual(
            parked,
        );

        await send(changes(idle.token), { now: NOW + DAY });
        expect((await counts(idle.id)).tasks).toBe(1);
    });

    it("are unparked by an upload, which gives every automation its tasks back and keeps the next parking off", async () => {
        const idle = await idleAccount(PARK_AFTER + 1);
        await parkIdle(env.DB, NOW);
        expect((await counts(idle.id)).tasks).toBe(0);
        // The same automation, which gets its schedule back, and a new one, with its run now and schedule.
        const later = NOW + DAY;
        const both = payload([automation(), automation({ automation: "evening", at: "20:00" })]);
        expect((await send(upload(idle.token, both), { now: later })).status).toBe(200);
        const { results } = await env.DB.prepare(
            "SELECT automation, once FROM tasks WHERE account = ? ORDER BY automation, once",
        )
            .bind(idle.id)
            .all();
        expect(results).toEqual([
            { automation: "daily", once: 0 },
            { automation: "evening", once: 0 },
            { automation: "evening", once: 1 },
        ]);
        const row = await env.DB.prepare("SELECT parked_at, pulled_at FROM accounts WHERE id = ?")
            .bind(idle.id)
            .first();
        expect(row).toEqual({ parked_at: null, pulled_at: later });
        // The upload counts as the phone being alive, so the next parking leaves the run now it just made.
        await parkIdle(env.DB, later + DAY);
        expect((await counts(idle.id)).tasks).toBe(3);
    });

    it("are deleted after 90 days without a pull, with their automations, tasks, and changes", async () => {
        expect(DELETE_AFTER).toBe(90 * DAY);
        const gone = await idleAccount(DELETE_AFTER + 1);
        const kept = await idleAccount(DELETE_AFTER - DAY);
        expect(await deleteIdle(env.DB, NOW)).toBeGreaterThanOrEqual(1);
        expect(await counts(gone.id)).toEqual({ accounts: 0, automations: 0, tasks: 0, changes: 0 });
        expect(await counts(kept.id)).toEqual({ accounts: 1, automations: 1, tasks: 2, changes: 1 });
        expect((await send(changes(gone.token))).body).toMatchObject({ code: "bad-token" });
    });
});
