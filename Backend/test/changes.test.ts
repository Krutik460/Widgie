import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { NEXT_WRITE_GAP, PAGE_SIZE } from "../src/accounts";
import { HOUR, MINUTE } from "../src/schedule";
import { encodeChange, encodePage, mintRowKey, stampOf } from "../src/wire";
import { automation, changes, DATASET, NOW, newAccount, payload, send, upload } from "./helpers/accounts";

async function replicaOf(account: string): Promise<string> {
    const row = await env.DB.prepare("SELECT replica FROM accounts WHERE id = ?")
        .bind(account)
        .first<{ replica: string }>();
    return row?.replica ?? "";
}

interface Page {
    replica: string;
    changes: { id: number; change: Record<string, unknown> }[];
    nextWrite: number | null;
}

/// A page the route wrote, checked for WIRE.md's shape: exactly its keys, ids that rise, and the stored change bytes.
/// The strict reader is the phone's (Wire.swift); the Worker writes pages and reads none until phase 4.
function readPage(text: string): Page {
    const page = JSON.parse(text) as Page;
    expect(Object.keys(page)).toEqual(["replica", "changes", "nextWrite"]);
    expect(page.nextWrite === null || Number.isInteger(page.nextWrite)).toBe(true);
    let last = 0;
    for (const entry of page.changes) {
        expect(Object.keys(entry)).toEqual(["id", "change"]);
        expect(entry.id).toBeGreaterThan(last);
        last = entry.id;
    }
    return page;
}

/// `count` setCell changes for the account, each a different word.
async function writeChanges(account: string, count: number): Promise<void> {
    const replica = await replicaOf(account);
    const row = mintRowKey(NOW);
    const statements = [...Array(count).keys()].map((i) =>
        env.DB.prepare(
            `INSERT INTO changes (account, op, dataset, row_key, widget, automation, at, change, written_at)
             VALUES (?, 'setCell', ?, ?, NULL, NULL, NULL, ?, ?)`,
        ).bind(
            account,
            DATASET,
            row,
            encodeChange({
                op: "setCell",
                row,
                dataset: DATASET,
                field: "word",
                kind: "text",
                value: `word ${i}`,
                stamp: stampOf(NOW, i),
                replica,
            }),
            NOW,
        ),
    );
    await env.DB.batch(statements);
}

describe("a pull", () => {
    it("answers the account's replica, no changes, and no next write before anything is set up", async () => {
        const { id, token } = await newAccount();
        const { status, text } = await send(changes(token));
        expect(status).toBe(200);
        expect(JSON.parse(text)).toEqual({ replica: await replicaOf(id), changes: [], nextWrite: null });
    });

    it("pages through the account's changes, oldest first, at most 500 at a time, in the wire format", async () => {
        const { id, token } = await newAccount();
        const other = await newAccount();
        await writeChanges(id, 600);
        await writeChanges(other.id, 3);
        await writeChanges(id, 603);

        const words: string[] = [];
        const sizes: number[] = [];
        let after = 0;
        for (;;) {
            const { text } = await send(changes(token, after));
            const page = readPage(text);
            expect(page.replica).toBe(await replicaOf(id));
            sizes.push(page.changes.length);
            if (page.changes.length === 0) break;
            for (const { change } of page.changes) words.push(String(change.value));
            after = page.changes.at(-1)?.id ?? after;
        }
        expect(PAGE_SIZE).toBe(500);
        expect(sizes).toEqual([500, 500, 203, 0]);
        const expected = [...Array(600).keys(), ...Array(603).keys()].map((i) => `word ${i}`);
        expect(words).toEqual(expected);
    });

    it("writes the page SQL joins byte for byte as encodePage writes it from the stored rows", async () => {
        const { id, token } = await newAccount();
        const replica = await replicaOf(id);
        const row = mintRowKey(NOW);
        const values = ['a "quote" and \\ a backslash', "emoji 👍🏽 and é", "line\nbreak\ttab", "日本語", ""];
        await env.DB.batch(
            values.map((value, i) =>
                env.DB.prepare(
                    `INSERT INTO changes (account, op, dataset, row_key, widget, automation, at, change, written_at)
                     VALUES (?, 'setCell', ?, ?, NULL, NULL, NULL, ?, ?)`,
                ).bind(
                    id,
                    DATASET,
                    row,
                    encodeChange({
                        ...{ op: "setCell", row, dataset: DATASET, field: "word", kind: "text", value },
                        ...{ stamp: stampOf(NOW, i), replica },
                    }),
                    NOW,
                ),
            ),
        );
        const { results } = await env.DB.prepare("SELECT id, change FROM changes WHERE account = ? ORDER BY id")
            .bind(id)
            .all<{ id: number; change: string }>();
        expect(results).toHaveLength(values.length);
        expect((await send(changes(token))).text).toBe(encodePage(replica, results, null));
        expect(readPage((await send(changes(token))).text).changes.map(({ change }) => change.value)).toEqual(values);
    });

    it("starts after the id it is given, skipping ids that are not the account's", async () => {
        const { id, token } = await newAccount();
        await writeChanges(id, 2);
        await writeChanges((await newAccount()).id, 2);
        await writeChanges(id, 2);
        const all = readPage((await send(changes(token))).text).changes.map((entry) => entry.id);
        expect(all).toHaveLength(4);
        expect(all[2]).toBeGreaterThan((all[1] ?? 0) + 1);
        const rest = readPage((await send(changes(token, all[1] ?? 0))).text).changes;
        expect(rest.map((entry) => entry.id)).toEqual(all.slice(2));
        const none = readPage((await send(changes(token, all[3] ?? 0))).text).changes;
        expect(none).toEqual([]);
    });

    it("names the next write: the earliest time a task is due, and never sooner than five minutes ahead", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation()])));
        const nextWrite = async () => readPage((await send(changes(token))).text).nextWrite;
        // The run now is due now, and the schedule for tomorrow morning is due a lead before it, already past: a task
        // waiting for the cron names five minutes from now, so the extension does not pull at every render.
        const due = await env.DB.prepare("SELECT min(due_at) AS due FROM tasks WHERE account = ?")
            .bind(id)
            .first<{ due: number }>();
        expect(due?.due).toBeLessThan(NOW);
        expect(NEXT_WRITE_GAP).toBe(5 * MINUTE);
        expect(await nextWrite()).toBe(NOW + 5 * MINUTE);
        await env.DB.prepare("UPDATE tasks SET due_at = ? WHERE account = ?")
            .bind(NOW + 4 * MINUTE, id)
            .run();
        expect(await nextWrite()).toBe(NOW + 5 * MINUTE);
        await env.DB.batch([
            env.DB.prepare("UPDATE tasks SET due_at = ? WHERE account = ? AND once = 1").bind(NOW + 2 * HOUR, id),
            env.DB.prepare("UPDATE tasks SET due_at = ? WHERE account = ? AND once = 0").bind(NOW + 5 * HOUR, id),
        ]);
        expect(await nextWrite()).toBe(NOW + 2 * HOUR);
        await env.DB.prepare("DELETE FROM tasks WHERE account = ? AND once = 1").bind(id).run();
        expect(await nextWrite()).toBe(NOW + 5 * HOUR);
        await env.DB.prepare("DELETE FROM tasks WHERE account = ?").bind(id).run();
        expect(await nextWrite()).toBeNull();
    });

    it("refuses an after that is not a change id", async () => {
        const { token } = await newAccount();
        for (const after of ["", "-1", "01", "1.5", "abc", "1e3", "9007199254740992", "99999999999999999"]) {
            const { status, body } = await send(changes(token, after));
            expect(status, after).toBe(400);
            expect(body).toEqual({ error: 'bad request: "after" must be a change id, 0 or more' });
        }
        const missing = new Request("https://widgie.test/v1/changes", {
            headers: { Authorization: `Bearer ${token}` },
        });
        expect((await send(missing)).status).toBe(400);
        expect((await send(changes(token, "9007199254740991"))).status).toBe(200);
    });

    it("records that the phone is alive, at most once an hour", async () => {
        const { id, token } = await newAccount();
        const pulledAt = async () =>
            (
                await env.DB.prepare("SELECT pulled_at FROM accounts WHERE id = ?")
                    .bind(id)
                    .first<{ pulled_at: number }>()
            )?.pulled_at;
        await send(changes(token), { now: NOW + 30 * MINUTE });
        expect(await pulledAt()).toBe(NOW);
        await send(changes(token), { now: NOW + HOUR });
        expect(await pulledAt()).toBe(NOW + HOUR);
    });

    it("records the watermark of each pull, writing only when it changes", async () => {
        const { id, token } = await newAccount();
        const pulledAfter = async () =>
            (
                await env.DB.prepare("SELECT pulled_after FROM accounts WHERE id = ?")
                    .bind(id)
                    .first<{ pulled_after: number }>()
            )?.pulled_after;
        expect(await pulledAfter()).toBe(0);
        await writeChanges(id, 3);
        const ids = readPage((await send(changes(token))).text).changes.map((entry) => entry.id);
        expect(await pulledAfter()).toBe(0);
        await send(changes(token, ids[2] ?? 0), { now: NOW + MINUTE });
        expect(await pulledAfter()).toBe(ids[2]);
        // The last pull's, not the largest: a phone set up again starts from 0, and the cleanup must wait for it.
        await send(changes(token, 0), { now: NOW + 2 * MINUTE });
        expect(await pulledAfter()).toBe(0);
    });

    it("re-arms a parked account: every automation gets its schedule from now", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation(), automation({ automation: "evening", at: "20:00" })])));
        const later = NOW + 40 * 24 * HOUR;
        await env.DB.batch([
            env.DB.prepare("UPDATE accounts SET parked_at = ? WHERE id = ?").bind(later, id),
            env.DB.prepare("DELETE FROM tasks WHERE account = ?").bind(id),
        ]);
        const { text } = await send(changes(token), { now: later });
        const { results } = await env.DB.prepare(
            "SELECT automation, once, run_at FROM tasks WHERE account = ? ORDER BY automation",
        )
            .bind(id)
            .all();
        // 2027-01-06: 06:00 and 20:00 in New York, after 07:00 there.
        expect(results).toEqual([
            { automation: "daily", once: 0, run_at: Date.parse("2027-01-07T11:00:00Z") },
            { automation: "evening", once: 0, run_at: Date.parse("2027-01-07T01:00:00Z") },
        ]);
        const account = await env.DB.prepare("SELECT parked_at, pulled_at FROM accounts WHERE id = ?").bind(id).first();
        expect(account).toEqual({ parked_at: null, pulled_at: later });
        expect(readPage(text).nextWrite).not.toBeNull();
    });

    it("keeps the schedule an upload made, which unparked the account", async () => {
        const { id, token } = await newAccount();
        await env.DB.prepare("UPDATE accounts SET parked_at = ? WHERE id = ?").bind(NOW, id).run();
        await send(upload(token, payload([automation()])));
        const before = await env.DB.prepare("SELECT id, row_key FROM tasks WHERE account = ? AND once = 0")
            .bind(id)
            .first();
        await send(changes(token), { now: NOW + MINUTE });
        const after = await env.DB.prepare("SELECT id, row_key FROM tasks WHERE account = ? AND once = 0")
            .bind(id)
            .first();
        expect(after).toEqual(before);
    });
});
