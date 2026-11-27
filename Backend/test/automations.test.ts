import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { leadSeed } from "../src/automations";
import { sha256, toHex } from "../src/bytes";
import { MAX_AUTOMATIONS_BODY } from "../src/index";
import { DAY, HOUR, LEADS, leadMs, MINUTE } from "../src/schedule";
import { encodeChange, isRowKey, mintRowKey, rowKeyMs, stampOf, stampParts } from "../src/wire";
import { automation, DATASET, NOW, newAccount, payload, send, upload, WIDGET } from "./helpers/accounts";

interface Task {
    id: number;
    widget: string;
    automation: string;
    version: string;
    once: number;
    run_at: number;
    row_key: string;
    due_at: number;
    claimed_until: number | null;
    attempts: number;
}

async function tasks(account: string): Promise<Task[]> {
    const { results } = await env.DB.prepare(
        "SELECT * FROM tasks WHERE account = ? ORDER BY widget, automation, once DESC",
    )
        .bind(account)
        .all<Task & { account: string }>();
    return results.map(({ account: _, ...task }) => task);
}

async function versionOf(account: string, name = "daily", widget = WIDGET): Promise<string | undefined> {
    const row = await env.DB.prepare(
        "SELECT version FROM automations WHERE account = ? AND widget = ? AND automation = ?",
    )
        .bind(account, widget, name)
        .first<{ version: string }>();
    return row?.version;
}

async function accountRow(account: string) {
    return env.DB.prepare("SELECT replica, CAST(last_stamp AS TEXT) AS stamp, time_zone FROM accounts WHERE id = ?")
        .bind(account)
        .first<{ replica: string; stamp: string; time_zone: string | null }>();
}

async function tombstones(account: string) {
    const { results } = await env.DB.prepare(
        "SELECT id, dataset, row_key, widget, automation, at, change, written_at FROM changes WHERE account = ? AND op = 'deleteRow' ORDER BY id",
    )
        .bind(account)
        .all<{
            id: number;
            dataset: string;
            row_key: string;
            widget: string;
            automation: string;
            at: number | null;
            change: string;
            written_at: number;
        }>();
    return results;
}

/// An automation's row as the runner writes it: the insert, at `at`, under the account's replica.
async function writeRow(account: string, at: number, name = "daily", widget = WIDGET): Promise<string> {
    const replica = (await accountRow(account))?.replica ?? "";
    const row = mintRowKey(NOW - DAY);
    const change = encodeChange({
        op: "insertRow",
        row,
        dataset: DATASET,
        day: 20_784,
        at,
        stamp: stampOf(NOW - DAY, 0),
        replica,
    });
    await env.DB.prepare(
        `INSERT INTO changes (account, op, dataset, row_key, widget, automation, at, change, written_at)
         VALUES (?, 'insertRow', ?, ?, ?, ?, ?, ?, ?)`,
    )
        .bind(account, DATASET, row, widget, name, at, change, NOW - DAY)
        .run();
    return row;
}

const WIDGETS = [
    WIDGET,
    "11111111-2222-4333-8444-555555555555",
    "21111111-2222-4333-8444-555555555555",
    "31111111-2222-4333-8444-555555555555",
];

describe("a new automation", () => {
    it("is stored with a run now and its schedule, and the answer is the payload's digest", async () => {
        const { id, token } = await newAccount();
        const body = JSON.stringify(payload([automation()]));
        const { status, body: answer } = await send(upload(token, body));
        expect(status).toBe(200);
        expect(answer).toEqual({ digest: toHex(await sha256(body)) });

        const stored = await env.DB.prepare("SELECT * FROM automations WHERE account = ?").bind(id).first();
        expect(stored).toMatchObject({
            widget: WIDGET,
            automation: "daily",
            prompt: "Pick an interesting, real English word.",
            every: "day",
            at: "06:00",
            weekday: null,
            dataset: DATASET,
            fields: '{"definition":"text","word":"text"}',
        });
        expect((await accountRow(id))?.time_zone).toBe("America/New_York");

        const [now, schedule] = await tasks(id);
        const version = await versionOf(id);
        expect(version).toMatch(/^[0-9a-f]{64}$/);
        expect(now).toMatchObject({ once: 1, version, run_at: NOW, due_at: NOW, claimed_until: null, attempts: 0 });
        // 06:00 in New York the next morning: it is 07:00 there now.
        const runAt = Date.parse("2026-11-28T11:00:00Z");
        const lead = leadMs("day", leadSeed(id, WIDGET, "daily"));
        expect(schedule).toMatchObject({ once: 0, version, run_at: runAt, due_at: runAt - lead, attempts: 0 });
        expect(runAt - (schedule?.due_at ?? 0)).toBeGreaterThanOrEqual(LEADS.day.min);
        expect(runAt - (schedule?.due_at ?? 0)).toBeLessThan(LEADS.day.max);
        for (const task of [now, schedule]) {
            expect(isRowKey(task?.row_key)).toBe(true);
            expect(rowKeyMs(task?.row_key ?? "")).toBe(NOW);
        }
        expect(now?.row_key).not.toBe(schedule?.row_key);
    });

    it("schedules hourly and weekly runs with their own leads", async () => {
        const { id, token } = await newAccount();
        const hourly = automation({ automation: "hourly", every: "hour", at: ":15" });
        const weekly = automation({ automation: "weekly", every: "week", on: "monday", at: "09:00" });
        expect((await send(upload(token, payload([hourly, weekly], "UTC")))).status).toBe(200);
        const schedules = (await tasks(id)).filter((task) => task.once === 0);
        expect(schedules.map((task) => [task.automation, task.run_at])).toEqual([
            ["hourly", Date.parse("2026-11-27T12:15:00Z")],
            ["weekly", Date.parse("2026-11-30T09:00:00Z")],
        ]);
        const [h, w] = schedules;
        expect((h?.run_at ?? 0) - (h?.due_at ?? 0)).toBe(leadMs("hour", leadSeed(id, WIDGET, "hourly")));
        expect((w?.run_at ?? 0) - (w?.due_at ?? 0)).toBe(leadMs("week", leadSeed(id, WIDGET, "weekly")));
    });
});

describe("replacing all", () => {
    it("changes nothing when the payload is the same, and an hourly without at is the same as at :00", async () => {
        const { id, token } = await newAccount();
        const plain = automation({ every: "hour", at: undefined });
        expect((await send(upload(token, payload([plain])))).status).toBe(200);
        const before = { tasks: await tasks(id), account: await accountRow(id) };
        const spelled = automation({ every: "hour", at: ":00" });
        expect((await send(upload(token, payload([spelled])), { now: NOW + 5 * MINUTE })).status).toBe(200);
        expect(await tasks(id)).toEqual(before.tasks);
        expect(await accountRow(id)).toEqual(before.account);
        expect(await tombstones(id)).toEqual([]);
    });

    it("gives a changed prompt or table a run now and a new schedule, with new row keys", async () => {
        for (const change of [
            { prompt: "Spanish cooking words." },
            { fields: { definition: "text", word: "text", level: "number" } },
            { dataset: "4f6c1d2e-8b4a-4c9e-9d7f-2a1b3c4d5e6f" },
        ]) {
            const { id, token } = await newAccount();
            await send(upload(token, payload([automation()])));
            const before = await tasks(id);
            const later = NOW + 10 * MINUTE;
            expect((await send(upload(token, payload([automation(change)])), { now: later })).status).toBe(200);
            const after = await tasks(id);
            const version = await versionOf(id);
            expect(version).not.toBe(before[0]?.version);
            expect(after).toHaveLength(2);
            expect(after[0]).toMatchObject({ once: 1, version, run_at: later, due_at: later });
            expect(after[1]).toMatchObject({ once: 0, version, run_at: before[1]?.run_at });
            for (const task of after) expect(before.map((b) => b.row_key)).not.toContain(task.row_key);
        }
    });

    it("moves only the schedule when the cadence changes, and a pending run now takes the new version", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation()])));
        const [now] = await tasks(id);
        await send(upload(token, payload([automation({ at: "07:30" })])), { now: NOW + MINUTE });
        const after = await tasks(id);
        const version = await versionOf(id);
        expect(after[0]).toEqual({ ...now, version });
        expect(after[1]).toMatchObject({ once: 0, version, run_at: Date.parse("2026-11-27T12:30:00Z") });
    });

    it("moves every schedule when the time zone changes", async () => {
        const { id, token } = await newAccount();
        const two = [automation(), automation({ automation: "evening", at: "20:00" })];
        await send(upload(token, payload(two)));
        const versions = [await versionOf(id), await versionOf(id, "evening")];
        await send(upload(token, payload(two, "America/Los_Angeles")), { now: NOW + MINUTE });
        expect((await accountRow(id))?.time_zone).toBe("America/Los_Angeles");
        expect([await versionOf(id), await versionOf(id, "evening")]).not.toContain(versions[0]);
        const schedules = (await tasks(id)).filter((task) => task.once === 0);
        expect(schedules.map((task) => [task.automation, task.run_at])).toEqual([
            ["daily", Date.parse("2026-11-27T14:00:00Z")],
            ["evening", Date.parse("2026-11-28T04:00:00Z")],
        ]);
    });

    it("deletes a removed automation and its tasks, and keeps the others", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation(), automation({ automation: "evening", at: "20:00" })])));
        const evening = (await tasks(id)).filter((task) => task.automation === "evening");
        await send(upload(token, payload([automation({ automation: "evening", at: "20:00" })])), {
            now: NOW + MINUTE,
        });
        expect(await versionOf(id)).toBeUndefined();
        expect(await tasks(id)).toEqual(evening);
        await send(upload(token, payload([])), { now: NOW + 2 * MINUTE });
        expect(await tasks(id)).toEqual([]);
        const count = await env.DB.prepare("SELECT count(*) AS n FROM automations WHERE account = ?")
            .bind(id)
            .first<{ n: number }>();
        expect(count?.n).toBe(0);
    });
});

describe("tombstones", () => {
    it("delete the changed automation's rows still ahead, under one new stamp of the account's replica", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation(), automation({ automation: "evening", at: "20:00" })])));
        const shown = await writeRow(id, NOW - HOUR);
        const ahead = [await writeRow(id, NOW + HOUR), await writeRow(id, NOW + DAY)];
        const otherAhead = await writeRow(id, NOW + DAY, "evening");
        const { replica, stamp: before } = (await accountRow(id)) ?? { replica: "", stamp: "" };

        const later = NOW + 5 * MINUTE;
        await send(
            upload(
                token,
                payload([automation({ prompt: "Nursing terms." }), automation({ automation: "evening", at: "20:00" })]),
            ),
            {
                now: later,
            },
        );
        const written = await tombstones(id);
        expect(written.map((t) => t.row_key)).toEqual(ahead);
        expect(written.map((t) => t.row_key)).not.toContain(shown);
        expect(written.map((t) => t.row_key)).not.toContain(otherAhead);
        const stamp = (await accountRow(id))?.stamp ?? "";
        expect(BigInt(stamp)).toBeGreaterThan(BigInt(before));
        expect(stampParts(stamp)).toEqual({ ms: later, counter: 0 });
        for (const tombstone of written) {
            const change = { op: "deleteRow", row: tombstone.row_key, dataset: DATASET, stamp, replica } as const;
            // SQL wrote exactly the bytes the wire encoder writes.
            expect(tombstone.change).toBe(encodeChange(change));
            expect(tombstone).toMatchObject({ dataset: DATASET, widget: WIDGET, automation: "daily", at: null });
            expect(tombstone.written_at).toBe(later);
        }
    });

    it("are written once per row, with a stamp that rises even when the clock goes back", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation()])));
        const ahead = await writeRow(id, NOW + DAY);
        await send(upload(token, payload([automation({ prompt: "one" })])));
        const first = (await accountRow(id))?.stamp ?? "";
        await send(upload(token, payload([automation({ prompt: "two" })])), { now: NOW - HOUR });
        const second = (await accountRow(id))?.stamp ?? "";
        expect(BigInt(second)).toBe(BigInt(first) + 1n);
        expect((await tombstones(id)).map((t) => t.row_key)).toEqual([ahead]);
    });

    it("are written for a cadence change and for a removal, and never for an unchanged automation", async () => {
        const { id, token } = await newAccount();
        const evening = automation({ automation: "evening", at: "20:00" });
        await send(upload(token, payload([automation(), evening])));
        const daily = await writeRow(id, NOW + DAY);
        const late = await writeRow(id, NOW + DAY, "evening");
        await send(upload(token, payload([automation({ at: "05:00" }), evening])), { now: NOW + MINUTE });
        expect((await tombstones(id)).map((t) => t.row_key)).toEqual([daily]);
        await send(upload(token, payload([automation({ at: "05:00" })])), { now: NOW + 2 * MINUTE });
        expect((await tombstones(id)).map((t) => t.row_key)).toEqual([daily, late]);
    });
});

describe("the payload", () => {
    const longEmoji = (n: number) => "😀".repeat(n);
    const cases: [string, unknown][] = [
        ["not an object", []],
        ["an unknown key", { ...payload([automation()]), version: 1 }],
        ["no time zone", { automations: [automation()] }],
        ["an offset for a time zone", payload([automation()], "+05:30")],
        ["an unknown time zone", payload([automation()], "Mars/Olympus_Mons")],
        ["automations not a list", { automations: {}, timeZone: "UTC" }],
        ["an automation with an unknown key", payload([{ ...automation(), timeZone: "UTC" }])],
        ["a missing prompt", payload([{ ...automation(), prompt: undefined }])],
        ["an empty prompt", payload([automation({ prompt: "" })])],
        ["a prompt of 2001 characters", payload([automation({ prompt: "a".repeat(2001) })])],
        ["a prompt of 2001 emoji", payload([automation({ prompt: longEmoji(2001) })])],
        ["an uppercase widget key", payload([automation({ widget: WIDGET.toUpperCase() })])],
        ["a widget key that is not a UUID", payload([automation({ widget: "widget" })])],
        ["an automation id with a capital first", payload([automation({ automation: "Daily" })])],
        ["an automation id longer than 32", payload([automation({ automation: `a${"b".repeat(32)}` })])],
        ["an automation id with a dash", payload([automation({ automation: "daily-word" })])],
        ["every month", payload([automation({ every: "month" })])],
        ["at 24:00", payload([automation({ at: "24:00" })])],
        ["at 6:00", payload([automation({ at: "6:00" })])],
        ["at +6:00", payload([automation({ at: "+6:00" })])],
        ["a daily run without at", payload([{ ...automation(), at: undefined }])],
        ["an hourly at of 15", payload([automation({ every: "hour", at: "15" })])],
        ["an hourly at of :60", payload([automation({ every: "hour", at: ":60" })])],
        ["on with every day", payload([automation({ on: "monday" })])],
        ["a weekly run without on", payload([automation({ every: "week" })])],
        ["a weekly run on Monday", payload([automation({ every: "week", on: "Monday" })])],
        ["a dataset that is not a UUID", payload([automation({ dataset: "words" })])],
        ["fields as a list", payload([{ ...automation(), fields: ["word"] }])],
        ["a field of an unknown kind", payload([automation({ fields: { word: "string" } })])],
        ["a reserved field id", payload([automation({ fields: { day: "date" } })])],
        ["a field id with a capital first", payload([automation({ fields: { Word: "text" } })])],
        [
            "17 fields",
            payload([automation({ fields: Object.fromEntries([...Array(17).keys()].map((i) => [`f${i}`, "text"])) })]),
        ],
        ["a null at", payload([{ ...automation(), at: null }])],
        ["an automation twice", payload([automation(), automation({ prompt: "again" })])],
        [
            "five automations on one widget",
            payload([...Array(5).keys()].map((i) => automation({ automation: `a${i}` }))),
        ],
        [
            "17 automations",
            payload(
                [...Array(17).keys()].map((i) =>
                    automation({ automation: `a${i}`, widget: WIDGETS[i % 4], every: "week", on: "monday" }),
                ),
            ),
        ],
    ];

    it.each(cases)("refuses %s, and keeps what the account had", async (_, body) => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation()])));
        const before = await tasks(id);
        const { status, body: answer } = await send(upload(token, body), { now: NOW + MINUTE });
        expect(status).toBe(400);
        expect(String(answer?.error)).toMatch(/^bad request: /);
        expect(await tasks(id)).toEqual(before);
    });

    it("takes the limits themselves: 16 automations, 2000 characters, 16 fields", async () => {
        const { id, token } = await newAccount();
        const sixteen = [...Array(16).keys()].map((i) =>
            automation({
                automation: `a${i}`,
                widget: WIDGETS[i % 4],
                prompt: i === 0 ? longEmoji(2000) : "a".repeat(2000),
                fields: Object.fromEntries([...Array(16).keys()].map((f) => [`f${f}`, "text"])),
            }),
        );
        const { status } = await send(upload(token, payload(sixteen)));
        expect(status).toBe(200);
        expect(await tasks(id)).toHaveLength(32);
    });

    it("names the length in characters as Swift counts them", async () => {
        const { token } = await newAccount();
        const { body } = await send(upload(token, payload([automation({ prompt: longEmoji(2001) })])));
        expect(body?.error).toBe('bad request: automations[0]: "prompt" is 2001 characters; keep it to 2000 or fewer');
    });

    it("refuses schedules over 60 runs a day with a line the app shows, and takes exactly 60", async () => {
        const { id, token } = await newAccount();
        const hourly = (i: number) => automation({ automation: `h${i}`, widget: WIDGETS[i], every: "hour", at: ":00" });
        const { status, body } = await send(upload(token, payload([hourly(0), hourly(1), hourly(2)])));
        expect(status).toBe(422);
        expect(body).toEqual({
            error: "These automations would run 72 times a day, and the limit is 60.",
            code: "daily-runs",
        });
        expect(await tasks(id)).toEqual([]);

        // Two hourly and twelve daily, at most four on a widget: 2 * 24 + 12 = 60.
        const daily = [...Array(12).keys()].map((i) => automation({ automation: `d${i}`, widget: WIDGETS[i % 4] }));
        expect((await send(upload(token, payload([hourly(0), hourly(1), ...daily])))).status).toBe(200);
        expect(await tasks(id)).toHaveLength(28);
    });

    it("refuses a body that is not JSON, too large, or without a token", async () => {
        const { token } = await newAccount();
        expect((await send(upload(token, "{"))).status).toBe(400);
        const big = JSON.stringify(payload([automation({ prompt: "a".repeat(MAX_AUTOMATIONS_BODY) })]));
        expect((await send(upload(token, big))).status).toBe(413);
        const plain = new Request("https://widgie.test/v1/automations", {
            method: "PUT",
            headers: { Authorization: `Bearer ${token}` },
            body: JSON.stringify(payload([])),
        });
        expect((await send(plain)).status).toBe(415);
        const anonymous = new Request("https://widgie.test/v1/automations", {
            method: "PUT",
            headers: { "Content-Type": "application/json" },
            body: JSON.stringify(payload([])),
        });
        expect((await send(anonymous)).body).toMatchObject({ code: "bad-token" });
        const post = new Request("https://widgie.test/v1/automations", { method: "POST" });
        expect((await send(post)).status).toBe(405);
    });
});
