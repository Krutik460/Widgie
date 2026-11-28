import { env } from "cloudflare:workers";
import { beforeEach, describe, expect, it } from "vitest";
import { DAY } from "../src/schedule";
import { DELETE_AFTER, deleteIdle, KEEP_CHANGES, PARK_AFTER, parkIdle, pruneChanges, upkeep } from "../src/upkeep";
import { automation, changes, DATASET, NOW, newAccount, payload, send, upload } from "./helpers/accounts";

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

describe("old changes", () => {
    const OLD = NOW - KEEP_CHANGES - DAY;
    const OTHER = "9a8b7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d";
    const ALL = 70 * 2 + 2 + 5 * 2 + 2;

    beforeEach(async () => {
        await env.DB.prepare("DELETE FROM accounts").run();
        await env.DB.prepare("UPDATE upkeep SET prune_from = 0").run();
    });

    async function place() {
        return (await env.DB.prepare("SELECT prune_from FROM upkeep").first<{ prune_from: number }>())?.prune_from;
    }

    /// Seventy old rows of one dataset (the first with its tombstone right after it, the second with one written
    /// last), five old rows of another, and one new row of the first. Every change pulled when `pulled` is true.
    async function history(pulled: boolean) {
        const account = await newAccount();
        const changes: [string, string, string, number][] = [];
        for (let i = 0; i < 70; i++) {
            changes.push(["insertRow", DATASET, `r${i}`, OLD], ["setCell", DATASET, `r${i}`, OLD]);
            if (i === 0) changes.push(["deleteRow", DATASET, "r0", OLD]);
        }
        changes.push(["deleteRow", DATASET, "r1", OLD]);
        for (let i = 0; i < 5; i++) changes.push(["insertRow", OTHER, `o${i}`, OLD], ["setCell", OTHER, `o${i}`, OLD]);
        changes.push(["insertRow", DATASET, "r70", NOW], ["setCell", DATASET, "r70", NOW]);
        await env.DB.batch(
            changes.map(([op, dataset, row, at]) =>
                env.DB.prepare(
                    "INSERT INTO changes (account, op, dataset, row_key, change, written_at) VALUES (?, ?, ?, ?, '{}', ?)",
                ).bind(account.id, op, dataset, row, at),
            ),
        );
        if (pulled) {
            await env.DB.prepare(
                "UPDATE accounts SET pulled_after = (SELECT max(id) FROM changes WHERE account = ?1) WHERE id = ?1",
            )
                .bind(account.id)
                .run();
        }
        return account;
    }

    async function left(account: string) {
        const { results } = await env.DB.prepare("SELECT op, row_key FROM changes WHERE account = ? ORDER BY id")
            .bind(account)
            .all<{ op: string; row_key: string }>();
        return results;
    }

    it("go once the account's pull has passed them, keeping each dataset's last 60 rows whole", async () => {
        expect(KEEP_CHANGES).toBe(120 * DAY);
        const account = await history(true);
        const unpulled = await history(false);
        expect(await pruneChanges(env.DB, NOW)).toBe(23);
        const rows = await left(account.id);
        // r0 to r10 go with every change, r0's tombstone included; the last 60 rows (r11 to r70) stay whole.
        const kept = new Set(rows.filter((row) => row.op === "insertRow").map((row) => row.row_key));
        expect(kept.size).toBe(65);
        for (let i = 0; i <= 10; i++) expect(kept.has(`r${i}`)).toBe(false);
        for (let i = 11; i <= 70; i++) expect(kept.has(`r${i}`)).toBe(true);
        for (let i = 0; i < 5; i++) expect(kept.has(`o${i}`)).toBe(true);
        expect(rows.filter((row) => row.op === "setCell")).toHaveLength(65);
        // A tombstone written after its row may outlive it, which still hides the row; never the other way round.
        expect(rows.filter((row) => row.op === "deleteRow").map((row) => row.row_key)).toEqual(["r1"]);
        // Nothing goes that a pull has not passed.
        expect(await left(unpulled.id)).toHaveLength(ALL);
        expect(await pruneChanges(env.DB, NOW)).toBe(0);
    });

    it("stay while they are newer than 120 days", async () => {
        const account = await history(true);
        expect(await pruneChanges(env.DB, OLD + KEEP_CHANGES)).toBe(0);
        expect(await left(account.id)).toHaveLength(ALL);
    });

    it("go in the daily upkeep, after parking and deleting", async () => {
        await history(true);
        expect(await upkeep(env.DB, NOW)).toEqual({ parked: 0, deleted: 0, pruned: 23 });
    });

    // At scale one upkeep cannot read every old change within Workers Free's 50 queries; it reads a few slices and
    // the next one goes on from there.
    it("go a few slices a day, each upkeep going on where the last stopped, the same as all at once", async () => {
        const account = await history(true);
        const unpulled = await history(false);
        const { results } = await env.DB.prepare("SELECT id FROM changes ORDER BY id").all<{ id: number }>();
        const ids = results.map((row) => row.id);
        // Ten changes a run, in two slices of five.
        const small = { rows: 5, slices: 2 };
        const pruned: number[] = [];
        const places: (number | undefined)[] = [];
        for (let day = 0; places.at(-1) !== 0 && day < 40; day++) {
            pruned.push(await pruneChanges(env.DB, NOW + day * DAY, small));
            places.push(await place());
        }
        // The pass goes ten changes a run through both histories (308 changes) and ends at the end of the table.
        expect(places).toEqual([...[...Array(30).keys()].map((i) => ids[10 * (i + 1)]), 0]);
        // r0 to r10 and r0's tombstone are the first 23 changes.
        expect(pruned.slice(0, 4)).toEqual([10, 10, 3, 0]);
        expect(pruned.reduce((total, n) => total + n, 0)).toBe(23);
        expect(await left(account.id)).toHaveLength(ALL - 23);
        expect(await left(unpulled.id)).toHaveLength(ALL);
        // The next pass starts from the first change again and finds nothing more.
        expect(await pruneChanges(env.DB, NOW + 40 * DAY, small)).toBe(0);
        expect(await place()).toBe(ids[33]);
    });

    it("ends a pass at the first change too new to go, and starts the next from the first change", async () => {
        const account = await history(true);
        // A pass that starts past the old changes ends at once.
        const { results } = await env.DB.prepare("SELECT id FROM changes WHERE written_at = ? ORDER BY id")
            .bind(NOW)
            .all<{ id: number }>();
        await env.DB.prepare("UPDATE upkeep SET prune_from = ?")
            .bind(results[0]?.id ?? 0)
            .run();
        expect(await pruneChanges(env.DB, NOW)).toBe(0);
        expect(await place()).toBe(0);
        expect(await pruneChanges(env.DB, NOW)).toBe(23);
        expect(await left(account.id)).toHaveLength(ALL - 23);
    });
});
