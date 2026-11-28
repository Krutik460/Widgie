import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { ATTEMPTS, leadSeed, TOMBSTONES } from "../src/automations";
import { sha256, toHex } from "../src/bytes";
import { type Env, MAX_AUTOMATIONS_BODY } from "../src/index";
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

describe("an upload of every kind of change at once", () => {
    it("plans each automation as it would alone, adds tasks in the payload's order, and tombstones in the list's", async () => {
        const { id, token } = await newAccount();
        const names = ["kept", "edited", "moved", "dropped", "lost"];
        // At most four a widget: the fifth on another.
        const widgetOf = (name: string) => (name === "lost" ? WIDGETS[1] : WIDGET);
        const first = names.map((name, i) =>
            automation({ automation: name, at: `0${i + 1}:00`, widget: widgetOf(name) }),
        );
        await send(upload(token, payload(first)));
        const before = await tasks(id);
        // Parking took the kept automation's schedule; an unchanged automation gets it back.
        await env.DB.prepare("DELETE FROM tasks WHERE account = ? AND automation = 'kept'").bind(id).run();
        // The pending run now of the moved automation takes its new version.
        const rows = {
            edited: [await writeRow(id, NOW + HOUR, "edited"), await writeRow(id, NOW + DAY, "edited")],
            moved: [await writeRow(id, NOW + DAY, "moved")],
            dropped: [await writeRow(id, NOW + 2 * HOUR, "dropped"), await writeRow(id, NOW + DAY, "dropped")],
            lost: [await writeRow(id, NOW + DAY, "lost", WIDGETS[1])],
            kept: [await writeRow(id, NOW + DAY, "kept")],
        };

        const later = NOW + 5 * MINUTE;
        const second = [
            automation({ automation: "fresh", at: "09:00" }),
            automation({ automation: "moved", at: "08:00" }),
            automation({ automation: "kept", at: "01:00" }),
            automation({ automation: "edited", at: "02:00", prompt: "Other words." }),
        ];
        expect((await send(upload(token, payload(second)), { now: later })).status).toBe(200);

        const after = await tasks(id);
        const of = (name: string) => after.filter((task) => task.automation === name);
        const was = (name: string) => before.filter((task) => task.automation === name);
        expect(after.map((task) => task.automation).sort()).toEqual(
            ["edited", "edited", "fresh", "fresh", "kept", "moved", "moved"].sort(),
        );
        // New and edited: a run now and a schedule, both new.
        for (const name of ["fresh", "edited"]) {
            const version = await versionOf(id, name);
            expect(of(name)[0]).toMatchObject({ once: 1, version, run_at: later, due_at: later, attempts: 0 });
            expect(of(name)[1]).toMatchObject({ once: 0, version });
            for (const task of of(name)) expect(was(name).map((b) => b.row_key)).not.toContain(task.row_key);
        }
        // Moved: the pending run now kept with the new version, and a new schedule at 08:00 New York.
        const moved = await versionOf(id, "moved");
        expect(of("moved")[0]).toEqual({ ...was("moved")[0], version: moved });
        expect(of("moved")[1]).toMatchObject({ once: 0, version: moved, run_at: Date.parse("2026-11-27T13:00:00Z") });
        // Kept: its schedule back, at its own next run.
        expect(of("kept")).toEqual([
            expect.objectContaining({ once: 0, version: await versionOf(id, "kept"), run_at: was("kept")[1]?.run_at }),
        ]);
        // Removed: the automations and their tasks gone.
        expect(await versionOf(id, "dropped")).toBeUndefined();
        expect(await versionOf(id, "lost", WIDGETS[1])).toBeUndefined();
        // Tasks were added in the payload's order, each run now before its schedule.
        const added = after.filter((task) => !before.some((b) => b.id === task.id && b.row_key === task.row_key));
        const order = [...added].sort((a, b) => a.id - b.id).map((task) => `${task.automation}/${task.once}`);
        expect(order).toEqual(["fresh/1", "fresh/0", "moved/0", "kept/0", "edited/1", "edited/0"]);
        // Tombstones: the changed automations in the payload's order, then the removed ones in the stored order, each
        // one's rows ahead in id order; never the unchanged automation's.
        const stored = (await tombstones(id)).map((t) => t.row_key);
        const removed = ["dropped", "lost"].flatMap((name) => rows[name as "dropped" | "lost"]);
        expect(stored.slice(0, 3)).toEqual([...rows.moved, ...rows.edited]);
        expect(stored.slice(3).sort()).toEqual(removed.sort());
        expect(stored).not.toContain(rows.kept[0]);
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
        ["a null at", payload([{ ...automation(), at: null }])],
        ["an automation twice", payload([automation(), automation({ prompt: "again" })])],
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

    const limits: [string, unknown, string, string][] = [
        [
            "a prompt of 2001 characters",
            payload([automation({ prompt: "a".repeat(2001) })]),
            "prompt-too-long",
            'The prompt of "daily" is 2001 characters, and the limit is 2000.',
        ],
        [
            "a prompt of 2001 emoji, counted as Swift counts them",
            payload([automation({ prompt: longEmoji(2001) })]),
            "prompt-too-long",
            'The prompt of "daily" is 2001 characters, and the limit is 2000.',
        ],
        [
            "17 fields",
            payload([automation({ fields: Object.fromEntries([...Array(17).keys()].map((i) => [`f${i}`, "text"])) })]),
            "too-many-fields",
            '"daily" writes 17 fields, and the limit is 16.',
        ],
        [
            "five automations on one widget",
            payload([...Array(5).keys()].map((i) => automation({ automation: `a${i}` }))),
            "too-many-on-widget",
            "A widget has 5 automations, and the limit is 4 a widget.",
        ],
    ];

    it.each(limits)(
        "refuses %s with a code and a sentence, and keeps what the account had",
        async (_, body, code, error) => {
            const { id, token } = await newAccount();
            await send(upload(token, payload([automation()])));
            const before = await tasks(id);
            const answer = await send(upload(token, body), { now: NOW + MINUTE });
            expect(answer).toMatchObject({ status: 422, body: { error, code } });
            expect(await tasks(id)).toEqual(before);
        },
    );

    it("takes the limits themselves: 4 automations a widget, 2000 characters, 16 fields", async () => {
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

    // The usage limits (automations an account, runs a day) were removed for now; tasks/phase-3-ai-block.md says why.
    it("has no usage limits: any number of widgets, and hourly schedules past 60 runs a day", async () => {
        const { id, token } = await newAccount();
        const widgets = [...WIDGETS, "41111111-2222-4333-8444-555555555555"];
        const twenty = [...Array(20).keys()].map((i) =>
            automation({ automation: `h${i}`, widget: widgets[i % 5], every: "hour", at: ":00" }),
        );
        expect((await send(upload(token, payload(twenty)))).status).toBe(200);
        expect(await tasks(id)).toHaveLength(40);
    });

    it("keeps the time zone's canonical name, so every spelling of one zone is one version", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation()], "america/new_york")));
        expect((await accountRow(id))?.time_zone).toBe("America/New_York");
        const before = { version: await versionOf(id), tasks: await tasks(id) };
        await send(upload(token, payload([automation()])), { now: NOW + MINUTE });
        expect({ version: await versionOf(id), tasks: await tasks(id) }).toEqual(before);
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

/// The database with `between` run before every `nth` batch it is given. An upload reads in one batch and writes in
/// the next, so with `nth` 2, `between` commits another upload after this one's read and before its write.
function overtaken(between: () => Promise<unknown>, times = 1): { db: D1Database; batches: () => number } {
    let batches = 0;
    let left = times;
    const db = new Proxy(env.DB, {
        get(target, key) {
            if (key === "batch") {
                return async (statements: D1PreparedStatement[]) => {
                    batches++;
                    if (batches % 2 === 0 && left > 0) {
                        left--;
                        await between();
                    }
                    return target.batch(statements);
                };
            }
            const value = Reflect.get(target, key);
            return typeof value === "function" ? value.bind(target) : value;
        },
    });
    return { db, batches: () => batches };
}

describe("concurrent uploads", () => {
    it("never acknowledge a payload the server does not hold: one overtaken between its read and write plans again", async () => {
        const { id, token } = await newAccount();
        const s0 = JSON.stringify(payload([automation()]));
        const s1 = JSON.stringify(payload([automation({ prompt: "Overtaking words." })]));
        await send(upload(token, s0));
        // B sends S0 again and reads S0; A commits S1; B's write, planned from S0, must not land as a no-op.
        const { db, batches } = overtaken(async () => {
            expect((await send(upload(token, s1), { now: NOW + MINUTE })).body).toEqual({
                digest: toHex(await sha256(s1)),
            });
        });
        const b = await send(upload(token, s0), { now: NOW + 2 * MINUTE, environment: { ...env, DB: db } as Env });
        expect(batches()).toBe(4);
        expect(b.body).toEqual({ digest: toHex(await sha256(s0)) });
        const stored = await env.DB.prepare("SELECT prompt FROM automations WHERE account = ?").bind(id).first();
        expect(stored).toEqual({ prompt: "Pick an interesting, real English word." });
        // B planned again from S1, so S0's prompt came back as a content change with a fresh run now.
        expect((await tasks(id)).find((task) => task.once === 1)).toMatchObject({ run_at: NOW + 2 * MINUTE });
    });

    it("give up with 409 conflict when overtaken on every attempt, and the failed batches write nothing", async () => {
        const { id, token } = await newAccount();
        await send(upload(token, payload([automation()])));
        let round = 0;
        const { db, batches } = overtaken(async () => {
            round++;
            await send(upload(token, payload([automation({ prompt: `Round ${round}.` })])), { now: NOW + MINUTE });
        }, ATTEMPTS);
        const extra = automation({ automation: "extra", at: "08:00" });
        const b = await send(upload(token, payload([automation(), extra])), {
            now: NOW + 2 * MINUTE,
            environment: { ...env, DB: db } as Env,
        });
        expect(batches()).toBe(2 * ATTEMPTS);
        expect(b).toMatchObject({
            status: 409,
            body: { error: "the automations changed during this upload, send them again", code: "conflict" },
        });
        // Each batch's later statements rolled back with its failed revision check: nothing of B's is stored.
        expect(await versionOf(id, "extra")).toBeUndefined();
        expect((await tasks(id)).map((task) => task.automation)).toEqual(["daily", "daily"]);
        const stored = await env.DB.prepare("SELECT prompt FROM automations WHERE account = ?").bind(id).first();
        expect(stored).toEqual({ prompt: `Round ${ATTEMPTS}.` });
        const revision = await env.DB.prepare("SELECT revision FROM accounts WHERE id = ?").bind(id).first();
        expect(revision).toEqual({ revision: 1 + ATTEMPTS });
    });
});

describe("the changes indexes", () => {
    async function plan(sql: string, ...values: unknown[]): Promise<string> {
        const { results } = await env.DB.prepare(`EXPLAIN QUERY PLAN ${sql}`)
            .bind(...values)
            .all<{ detail: string }>();
        return results.map((row) => row.detail).join("\n");
    }

    it("serve the tombstones: an automation's rows ahead, and the check for a row already deleted", async () => {
        const listed = JSON.stringify([{ widget: WIDGET, automation: "daily" }]);
        const detail = await plan(TOMBSTONES, "account", "replica", NOW, listed);
        expect(detail).toMatch(
            /SEARCH inserted USING INDEX changes_inserted \(account=\? AND widget=\? AND automation=\? AND at>\?\)/,
        );
        expect(detail).toMatch(/SEARCH changes USING (COVERING )?INDEX changes_deleted \(account=\? AND row_key=\?\)/);
        expect(detail).not.toMatch(/SCAN changes|SCAN inserted/);
    });

    it("serve P3's read-back of a dataset's recent rows", async () => {
        const detail = await plan(
            "SELECT change FROM changes WHERE account = ? AND dataset = ? ORDER BY id DESC LIMIT 60",
            "account",
            DATASET,
        );
        expect(detail).toMatch(/SEARCH changes USING INDEX changes_dataset \(account=\? AND dataset=\?\)/);
        expect(detail).not.toMatch(/TEMP B-TREE/);
    });
});
