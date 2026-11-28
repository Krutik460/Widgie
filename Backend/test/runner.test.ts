import { createExecutionContext, createMessageBatch, getQueueResult } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import { cadenceOf } from "../src/automations";
import { CLAIM_MS } from "../src/cron";
import { RECENT_ROWS, RUN_TOKENS } from "../src/run";
import { BACKOFF, consume, MAX_ATTEMPTS, RETRY_DELAY_S, type RunMessage } from "../src/runner";
import { type Cadence, DAY, dayOf, LEADS, leadMs, MINUTE, nextRun } from "../src/schedule";
import {
    type Cell,
    dayIndex,
    encodeChange,
    isName,
    isRowKey,
    isUuid,
    mintRowKey,
    parseStamp,
    stampOf,
} from "../src/wire";
import { automation, changes, DATASET, type Entry, NOW, newAccount, payload, send, upload } from "./helpers/accounts";
import { answer, claim, model, run, SETTINGS, sentBodies, userTurnOf } from "./helpers/runs";

const ROW = { definition: "The pleasant, earthy smell after rain.", word: "Petrichor" };
const NEXT = { definition: "Finding good things by chance.", word: "Serendipity" };

beforeEach(async () => {
    await env.DB.prepare("DELETE FROM accounts").run();
});

afterEach(() => {
    vi.restoreAllMocks();
});

interface Task {
    id: number;
    once: number;
    run_at: number;
    row_key: string;
    due_at: number;
    claimed_until: number | null;
    attempts: number;
}

/// An account with one automation uploaded at `now`, and the message a claim of each of its tasks would send. The
/// claims themselves are the cron's (cron.test.ts); a run needs only the message.
async function setUp(entry: Entry = {}, zone = "America/New_York", now = NOW) {
    const account = await newAccount(now);
    expect((await send(upload(account.token, payload([automation(entry)], zone)), { now })).status).toBe(200);
    return { account, now, runNow: await messageOf(account.id, 1), schedule: await messageOf(account.id, 0) };
}

/// The message a claim of the account's task with `once` would send now.
async function messageOf(account: string, once: number): Promise<RunMessage> {
    const task = await taskOf(account, once);
    if (!task) throw new Error(`no task with once = ${once}`);
    return { task: task.id, rowKey: task.row_key, attempts: task.attempts };
}

/// The log lines of the automation runs while `body` runs.
async function runLogs(body: () => Promise<unknown>): Promise<Record<string, unknown>[]> {
    const lines: string[] = [];
    const spy = vi.spyOn(console, "log").mockImplementation((line: string) => lines.push(line));
    try {
        await body();
    } finally {
        spy.mockRestore();
    }
    return lines.map((line) => JSON.parse(line)).filter((line) => line.run === "automation");
}

async function taskOf(account: string, once: number): Promise<Task | null> {
    return env.DB.prepare(
        "SELECT id, once, run_at, row_key, due_at, claimed_until, attempts FROM tasks WHERE account = ? AND once = ?",
    )
        .bind(account, once)
        .first<Task>();
}

async function stored(account: string) {
    const { results } = await env.DB.prepare(
        "SELECT id, op, row_key, widget, automation, at, change FROM changes WHERE account = ? ORDER BY id",
    )
        .bind(account)
        .all<{
            id: number;
            op: string;
            row_key: string;
            widget: string | null;
            automation: string | null;
            at: number | null;
            change: string;
        }>();
    return results;
}

async function accountRow(account: string) {
    return env.DB.prepare("SELECT replica, last_stamp FROM accounts WHERE id = ?")
        .bind(account)
        .first<{ replica: string; last_stamp: number }>();
}

/// A change as WIRE.md defines it: exactly its keys, in their order, each of its type and within its range.
function checkWire(change: Record<string, unknown>) {
    const keys = {
        insertRow: ["op", "row", "dataset", "day", "at", "stamp", "replica"],
        setCell: ["op", "row", "dataset", "field", "kind", "value", "stamp", "replica"],
        deleteRow: ["op", "row", "dataset", "stamp", "replica"],
    }[change.op as string];
    expect(keys, String(change.op)).toBeDefined();
    expect(Object.keys(change)).toEqual(keys);
    expect(isRowKey(change.row)).toBe(true);
    expect(isUuid(change.dataset)).toBe(true);
    expect(isUuid(change.replica)).toBe(true);
    expect(() => parseStamp(change.stamp)).not.toThrow();
    if (change.op === "insertRow") {
        expect(
            Number.isInteger(change.day) && (change.day as number) >= -719_162 && (change.day as number) <= 2_932_896,
        ).toBe(true);
        expect(Number.isInteger(change.at) && (change.at as number) >= 0).toBe(true);
    }
    if (change.op === "setCell") {
        expect(isName(change.field)).toBe(true);
        if (change.kind === "text") expect(typeof change.value === "string" && change.value.length <= 300).toBe(true);
        else if (change.kind === "number") expect(Number.isFinite(change.value)).toBe(true);
        else if (change.kind === "bool") expect(typeof change.value).toBe("boolean");
        else expect([change.kind, Number.isInteger(change.value)]).toEqual(["date", true]);
    }
}

describe("a run", () => {
    it("writes every kind of cell, with text carried through SQL byte for byte as the wire encoder writes it", async () => {
        const fields = { done: "bool", level: "number", note: "text", on: "date", word: "text" };
        const { account, runNow } = await setUp({ fields });
        const note =
            'a "quote", a \\ backslash, \u{1F44D}\u{1F3FD}, e\u0301, \u65E5\u672C\u8A9E,\na new line, \u2028 a line separator';
        const reply = { on: "2026-11-30", done: true, level: -1.5e-7, note, word: "Petrichor" };
        expect(await run(runNow, model(reply), NOW + MINUTE)).toBe("written");
        const { replica } = (await accountRow(account.id)) ?? { replica: "" };
        const common = { row: runNow.rowKey, dataset: DATASET, stamp: stampOf(NOW + MINUTE, 0), replica };
        const day = dayOf(NOW, "America/New_York");
        expect((await stored(account.id)).map((row) => row.change)).toEqual([
            encodeChange({ ...common, op: "insertRow", day, at: NOW }),
            encodeChange({ ...common, op: "setCell", field: "done", kind: "bool", value: true }),
            encodeChange({ ...common, op: "setCell", field: "level", kind: "number", value: -1.5e-7 }),
            encodeChange({ ...common, op: "setCell", field: "note", kind: "text", value: note }),
            encodeChange({ ...common, op: "setCell", field: "on", kind: "date", value: dayIndex(2026, 11, 30) }),
            encodeChange({ ...common, op: "setCell", field: "word", kind: "text", value: "Petrichor" }),
        ]);
    });

    it("writes the row under the account's replica with one stamp, and the pull returns it in the wire format", async () => {
        const { account, runNow } = await setUp();
        const fetcher = model(ROW);
        expect(await run(runNow, fetcher, NOW + MINUTE)).toBe("written");

        const { replica, last_stamp } = (await accountRow(account.id)) ?? { replica: "", last_stamp: 0 };
        const stamp = stampOf(NOW + MINUTE, 0);
        expect(String(BigInt(last_stamp))).toBe(stamp);
        const common = { row: runNow.rowKey, dataset: DATASET, stamp, replica };
        const day = dayOf(NOW, "America/New_York");
        const rows = await stored(account.id);
        expect(rows.map((row) => row.change)).toEqual([
            encodeChange({ ...common, op: "insertRow", day, at: NOW }),
            encodeChange({ ...common, op: "setCell", field: "definition", kind: "text", value: ROW.definition }),
            encodeChange({ ...common, op: "setCell", field: "word", kind: "text", value: ROW.word }),
        ]);
        // The tombstones find a row by what its insertRow repeats.
        expect(rows.map((row) => [row.op, row.widget !== null, row.at])).toEqual([
            ["insertRow", true, NOW],
            ["setCell", false, null],
            ["setCell", false, null],
        ]);
        // A run now is done once it has run.
        expect(await taskOf(account.id, 1)).toBeNull();

        const page = await send(changes(account.token), { now: NOW + MINUTE });
        const body = page.body as { replica: string; changes: { id: number; change: Record<string, unknown> }[] };
        expect(body.replica).toBe(replica);
        expect(body.changes.map((entry) => JSON.stringify(entry.change))).toEqual(rows.map((row) => row.change));
        for (const entry of body.changes) checkWire(entry.change);
    });

    it("writes every kind a table holds", async () => {
        const fields = { done: "bool", due: "date", score: "number", title: "text" };
        const { account, runNow } = await setUp({ fields });
        const reply = { done: true, due: "2026-12-24", score: 7.5, title: "  Wrap the gifts  " };
        expect(await run(runNow, model(reply), NOW)).toBe("written");
        const cells = (await stored(account.id)).slice(1).map((row) => JSON.parse(row.change));
        expect(cells.map((cell) => [cell.field, cell.kind, cell.value])).toEqual([
            ["done", "bool", true],
            ["due", "date", dayIndex(2026, 12, 24)],
            ["score", "number", 7.5],
            ["title", "text", "Wrap the gifts"],
        ]);
        for (const cell of cells) checkWire(cell);
    });

    it("moves the schedule to its next run, due a lead ahead of it within its window", async () => {
        const cadences: [Entry, Cadence["every"]][] = [
            [{ every: "day", at: "06:00" }, "day"],
            [{ every: "week", at: "09:30", on: "monday" }, "week"],
            [{ every: "hour", at: ":15" }, "hour"],
        ];
        for (const [entry, every] of cadences) {
            const { account, schedule } = await setUp(entry);
            const before = await taskOf(account.id, 0);
            expect(await run(schedule, model(ROW), NOW)).toBe("written");
            const after = await taskOf(account.id, 0);
            const cadence = cadenceOf({
                every,
                at: entry.at ?? "",
                weekday: (entry.on as "monday" | undefined) ?? null,
            });
            const runAt = nextRun(cadence, "America/New_York", before?.run_at ?? 0);
            expect(after).toMatchObject({ run_at: runAt, claimed_until: null, attempts: 0 });
            expect(after?.row_key).not.toBe(before?.row_key);
            const lead = runAt - (after?.due_at ?? 0);
            expect(lead).toBeGreaterThanOrEqual(LEADS[every].min);
            expect(lead).toBeLessThan(LEADS[every].max);
            expect(lead).toBe(leadMs(every, `${account.id}/${automation().widget}/daily`));
            // The row it wrote is the one the task held, at its run time.
            const insert = (await stored(account.id)).find((row) => row.op === "insertRow");
            expect([insert?.row_key, insert?.at]).toEqual([before?.row_key, before?.run_at]);
        }
    });

    it("moves a late schedule to the first run after now, skipping the runs it missed", async () => {
        const { account, schedule } = await setUp();
        const late = NOW + 3 * DAY;
        expect(await run(schedule, model(ROW), late)).toBe("written");
        const after = await taskOf(account.id, 0);
        expect(after?.run_at).toBe(nextRun({ every: "day", hour: 6, minute: 0 }, "America/New_York", late));
    });

    it("lands on the day of its run time in the automation's zone, across daylight saving changes", async () => {
        // Santiago skips midnight on 2026-09-06, so 00:30 runs at 01:00 local, 04:00 UTC, on the 6th.
        const santiago = await setUp({ at: "00:30" }, "America/Santiago", Date.parse("2026-09-05T12:00:00Z"));
        expect(await run(santiago.schedule, model(ROW), santiago.now)).toBe("written");
        const first = (await stored(santiago.account.id)).find((row) => row.op === "insertRow");
        expect(JSON.parse(first?.change ?? "{}")).toMatchObject({
            day: dayIndex(2026, 9, 6),
            at: Date.parse("2026-09-06T04:00:00Z"),
        });

        // New York at 23:30 is the next day in UTC, before and after the clocks go back on 2026-11-01.
        const york = await setUp({ at: "23:30" }, "America/New_York", Date.parse("2026-10-31T12:00:00Z"));
        expect(await run(york.schedule, model(ROW), york.now)).toBe("written");
        const next = await taskOf(york.account.id, 0);
        expect(await run(await messageOf(york.account.id, 0), model(NEXT), next?.due_at ?? 0)).toBe("written");
        const days = (await stored(york.account.id))
            .filter((row) => row.op === "insertRow")
            .map((row) => JSON.parse(row.change) as { day: number; at: number });
        expect(days).toEqual([
            { ...days[0], day: dayIndex(2026, 10, 31), at: Date.parse("2026-11-01T03:30:00Z") },
            { ...days[1], day: dayIndex(2026, 11, 1), at: Date.parse("2026-11-02T04:30:00Z") },
        ]);
    });

    it("writes nothing when the automation changes while the model answers", async () => {
        const { account, runNow } = await setUp();
        const fetcher = vi.fn<typeof fetch>(async () => {
            const refined = payload([automation({ prompt: "Pick a Spanish cooking word." })]);
            expect((await send(upload(account.token, refined), { now: NOW + MINUTE })).status).toBe(200);
            return answer(ROW);
        });
        expect(await run(runNow, fetcher, NOW + MINUTE)).toBe("stale");
        expect((await stored(account.id)).filter((row) => row.op !== "deleteRow")).toEqual([]);
        // The refine made a run now of its own, which the next cron claims.
        const fresh = await taskOf(account.id, 1);
        expect(fresh?.row_key).not.toBe(runNow.rowKey);
        expect(fresh?.claimed_until).toBeNull();
    });

    it("does nothing for a task an upload replaced or removed", async () => {
        const { account, runNow, schedule } = await setUp();
        await send(upload(account.token, payload([automation({ prompt: "Pick a Spanish cooking word." })])));
        const fetcher = model(ROW);
        expect(await run(runNow, fetcher, NOW)).toBe("skipped");
        await send(upload(account.token, payload([])));
        expect(await run(schedule, fetcher, NOW)).toBe("skipped");
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("writes a replayed message once, and runs one of two deliveries at once, without calling the model twice", async () => {
        const first = await setUp();
        const fetcher = model(ROW);
        expect(await run(first.runNow, fetcher, NOW)).toBe("written");
        expect(await run(first.runNow, fetcher, NOW)).toBe("skipped");
        expect(fetcher).toHaveBeenCalledTimes(1);

        const second = await setUp();
        const [a, b] = [model(ROW), model(NEXT)];
        const outcomes = await Promise.all([run(second.runNow, a, NOW), run(second.runNow, b, NOW)]);
        expect([...outcomes].sort()).toEqual(["skipped", "written"]);
        expect(a.mock.calls.length + b.mock.calls.length).toBe(1);
        const inserts = (await stored(second.account.id)).filter((row) => row.op === "insertRow");
        expect(inserts).toHaveLength(1);
        expect(await stored(second.account.id)).toHaveLength(3);
    });

    it("ends a delivery of a run that has already started without calling the model", async () => {
        const { account, runNow } = await setUp();
        const duplicate = model(NEXT);
        let during: string | undefined;
        const fetcher = vi.fn<typeof fetch>(async () => {
            during = await run(runNow, duplicate, NOW);
            return answer(ROW);
        });
        const logs = await runLogs(async () => expect(await run(runNow, fetcher, NOW)).toBe("written"));
        expect(during).toBe("skipped");
        expect(duplicate).not.toHaveBeenCalled();
        expect(logs.map((line) => [line.outcome, line.reason])).toEqual([
            ["skipped", "busy"],
            ["written", undefined],
        ]);
        // And so does a late delivery of a run that failed, whose task now counts that attempt.
        const failing = await setUp();
        expect(await run(failing.runNow, model(new Response("{}", { status: 500 })), NOW)).toBe("retry");
        const late = model(ROW);
        expect(await run(failing.runNow, late, NOW)).toBe("skipped");
        expect(late).not.toHaveBeenCalled();
        expect((await stored(account.id)).filter((row) => row.op === "insertRow")).toHaveLength(1);
    });

    it("counts an attempt when a run starts, not when it is claimed, so a message that waited too long costs none", async () => {
        const account = await newAccount();
        expect((await send(upload(account.token, payload([automation()])))).status).toBe(200);
        // The first message waits past its claim, and the cron claims the task again, twice.
        const [late] = await claim(NOW);
        const [again] = await claim(NOW + CLAIM_MS + 1);
        expect(await claim(NOW + 2 * CLAIM_MS + 2)).toEqual([again]);
        expect(again).toEqual(late);
        expect((await taskOf(account.id, 1))?.attempts).toBe(0);
        // One of them runs; the other then finds the task gone, and never calls the model.
        const logs = await runLogs(async () => {
            expect(await run(again as RunMessage, model(ROW), NOW + 2 * CLAIM_MS + 3)).toBe("written");
            const unused = model(NEXT);
            expect(await run(late as RunMessage, unused, NOW + 2 * CLAIM_MS + 4)).toBe("skipped");
            expect(unused).not.toHaveBeenCalled();
        });
        expect(logs[0]).toMatchObject({ outcome: "written", attempts: 1 });
        expect(logs[1]).toMatchObject({ outcome: "skipped", reason: "gone" });
    });

    // A new or refined automation has a run now and a schedule, both due at once. The cron hands out the run now
    // first (cron.test.ts); a run checks the same, so the schedule reads the run now's row and does not repeat it.
    it("runs a new automation's schedule after its run now, with the run now's row among the recent rows", async () => {
        const account = await newAccount();
        expect((await send(upload(account.token, payload([automation()])))).status).toBe(200);
        const first = await claim(NOW);
        expect(first.map((message) => message.task)).toEqual([(await taskOf(account.id, 1))?.id]);
        // The schedule does not run beside the run now's live claim, even from a stray message.
        const stray = model(NEXT);
        expect(await run(await messageOf(account.id, 0), stray, NOW)).toBe("skipped");
        expect(stray).not.toHaveBeenCalled();

        expect(await run(first[0] as RunMessage, model(ROW), NOW)).toBe("written");
        const second = await claim(NOW + MINUTE);
        expect(second.map((message) => message.task)).toEqual([(await taskOf(account.id, 0))?.id]);
        const fetcher = model(NEXT);
        expect(await run(second[0] as RunMessage, fetcher, NOW + MINUTE)).toBe("written");
        expect(userTurnOf(sentBodies(fetcher)[0] ?? {})).toContain(
            `The 1 rows written most recently, newest first. Never repeat one of them:\n${JSON.stringify(ROW)}`,
        );
    });
});

describe("the reply", () => {
    it("is asked for with the table's schema, structured output required of the provider, and its token cap", async () => {
        const { runNow } = await setUp();
        const fetcher = model(ROW);
        await run(runNow, fetcher, NOW);
        const [body] = sentBodies(fetcher);
        // 1,000 and 250 for each of the two text fields.
        expect(body?.max_tokens).toBe(1_500);
        expect(body?.response_format).toEqual({
            type: "json_schema",
            json_schema: {
                name: "row",
                strict: true,
                schema: {
                    type: "object",
                    properties: { definition: { type: "string" }, word: { type: "string" } },
                    required: ["definition", "word"],
                    additionalProperties: false,
                },
            },
        });
        expect(body?.provider).toEqual({ order: ["together"], allow_fallbacks: false, require_parameters: true });
        const turn = userTurnOf(body ?? {});
        expect(turn).toContain("- definition: text\n- word: text");
        expect(turn).toContain(automation().prompt as string);
        expect(turn).toContain("The row appears on Friday, 2026-11-27.");
        expect(turn).toContain("No rows were written before this one.");
    });

    it("lists the recent rows newest first, refuses a repeat, and asks once more with the line it was refused with", async () => {
        const { account, runNow, schedule } = await setUp();
        expect(await run(runNow, model(ROW), NOW)).toBe("written");
        // The same row again, in other case and spacing, then a new one.
        const repeat = model({ definition: " the pleasant, earthy smell after rain. ", word: "PETRICHOR" }, NEXT);
        expect(await run(schedule, repeat, NOW)).toBe("written");
        const [first, second] = sentBodies(repeat).map(userTurnOf);
        expect(first).toContain(
            `The 1 rows written most recently, newest first. Never repeat one of them:\n${JSON.stringify(ROW)}`,
        );
        expect(second).toContain(
            `Your last reply was refused: it repeats a recent row ("definition": ${JSON.stringify(ROW.definition)}, "word": "Petrichor"); write a different one. Reply again with one new row.`,
        );
        const words = (await stored(account.id))
            .map((row) => JSON.parse(row.change))
            .filter((change) => change.field === "word")
            .map((change) => change.value);
        expect(words).toEqual(["Petrichor", "Serendipity"]);

        // The next run sees both, newest first.
        const next = await taskOf(account.id, 0);
        const [message] = (await claim(next?.due_at ?? 0)).filter((m) => m.task === next?.id);
        const third = model({ definition: "Gentle and soothing.", word: "Dulcet" });
        expect(await run(message as RunMessage, third, next?.due_at ?? 0)).toBe("written");
        expect(userTurnOf(sentBodies(third)[0] ?? {})).toContain(
            `The 2 rows written most recently, newest first. Never repeat one of them:\n${JSON.stringify(NEXT)}\n${JSON.stringify(ROW)}`,
        );
    });

    it("reads back the newest rows' text only, newest first, leaving out rows with none, a later value winning", async () => {
        const { account, runNow } = await setUp({ fields: { definition: "text", level: "number", word: "text" } });
        const replica = "7d9e1f2a-3b4c-4d5e-8f6a-7b8c9d0e1f2a";
        const insert = (op: string, row: string, change: string) =>
            env.DB.prepare(
                `INSERT INTO changes (account, op, dataset, row_key, widget, automation, at, change, written_at)
                 VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?, ?)`,
            ).bind(account.id, op, DATASET, row, change, NOW);
        const statements: D1PreparedStatement[] = [];
        const expected: Record<string, string>[] = [];
        const total = RECENT_ROWS + 4;
        for (let i = 0; i < total; i++) {
            const row = mintRowKey(NOW - DAY + i);
            const common = { row, dataset: DATASET, stamp: stampOf(NOW - DAY, i), replica };
            statements.push(
                insert("insertRow", row, encodeChange({ ...common, op: "insertRow", day: 20_000, at: NOW })),
            );
            const cell = (field: string, cell: Cell) =>
                insert("setCell", row, encodeChange({ ...common, op: "setCell", field, ...cell }));
            statements.push(cell("level", { kind: "number", value: i }));
            // A row with no text is left out.
            if (i % 5 === 0) continue;
            const word = `word ${i} "quoted" \\ 👍🏽 é`;
            // A later value of a field wins.
            if (i % 7 === 0) statements.push(cell("word", { kind: "text", value: "an earlier word" }));
            statements.push(cell("word", { kind: "text", value: word }));
            statements.push(cell("definition", { kind: "text", value: `definition ${i}` }));
            if (i >= total - RECENT_ROWS) expected.unshift({ word, definition: `definition ${i}` });
        }
        await env.DB.batch(statements);
        const fetcher = model({ ...ROW, level: 1 });
        expect(await run(runNow, fetcher, NOW)).toBe("written");
        const list = expected.map((row) => JSON.stringify(row)).join("\n");
        const turn = userTurnOf(sentBodies(fetcher)[0] ?? {});
        expect(turn).toContain(`\nThe ${expected.length} rows written most recently, newest first.`);
        expect(turn.endsWith(`Never repeat one of them:\n${list}`)).toBe(true);
    });

    it("reads the recent rows by dataset, so a renamed automation keeps its history", async () => {
        const { account, runNow } = await setUp();
        expect(await run(runNow, model(ROW), NOW)).toBe("written");
        await send(upload(account.token, payload([automation({ automation: "morning" })])), { now: NOW + MINUTE });
        const sent = await claim(NOW + MINUTE);
        const task = await taskOf(account.id, 1);
        const message = sent.find((m) => m.task === task?.id);
        const fetcher = model(ROW, NEXT);
        expect(await run(message as RunMessage, fetcher, NOW + MINUTE)).toBe("written");
        expect(fetcher).toHaveBeenCalledTimes(2);
        expect(userTurnOf(sentBodies(fetcher)[0] ?? {})).toContain(JSON.stringify(ROW));
    });

    it("lets a field that names a category repeat, as long as the item does not", async () => {
        const fields = { definition: "text", kind: "text", word: "text" };
        const { runNow, schedule } = await setUp({ fields });
        expect(await run(runNow, model({ ...ROW, kind: "noun" }), NOW)).toBe("written");
        const fetcher = model({ ...NEXT, kind: "noun" });
        expect(await run(schedule, fetcher, NOW)).toBe("written");
        expect(fetcher).toHaveBeenCalledTimes(1);
        // The word with its part of speech is the item: a repeat of both is refused, and the repair asked for.
        const repeat = await setUp({ fields });
        await run(repeat.runNow, model({ ...ROW, kind: "noun" }), NOW);
        const again = model({ word: "petrichor", kind: "Noun", definition: "Rain smell." }, { ...NEXT, kind: "noun" });
        expect(await run(repeat.schedule, again, NOW)).toBe("written");
        expect(again).toHaveBeenCalledTimes(2);
        expect(userTurnOf(sentBodies(again)[1] ?? {})).toContain(
            "Your last reply was refused: it repeats a recent row",
        );
    });

    // A table whose only text is a category (a mood of the day) runs out of new values, and the repeat rule would
    // then refuse every reply; so would a two-text table whose other text is always empty, when its one text repeats.
    it("writes a repair that repeats, and logs the repeat, so a widget never stops getting rows", async () => {
        const cases: [Entry, Record<string, unknown>, Record<string, unknown>][] = [
            [{ fields: { level: "number", mood: "text" } }, { level: 3, mood: "Calm" }, { level: 5, mood: " calm" }],
            [
                { fields: { verdict: "text", word: "text" } },
                { verdict: "", word: "Sonder" },
                { verdict: "", word: "SONDER" },
            ],
        ];
        for (const [entry, first, repeat] of cases) {
            const { account, runNow, schedule } = await setUp(entry);
            expect(await run(runNow, model(first), NOW)).toBe("written");
            const fetcher = model(repeat);
            const logs = await runLogs(async () => expect(await run(schedule, fetcher, NOW)).toBe("written"));
            expect(fetcher).toHaveBeenCalledTimes(2);
            expect(logs).toEqual([expect.objectContaining({ outcome: "written", calls: 2, reason: "repeat" })]);
            expect((await stored(account.id)).filter((row) => row.op === "insertRow")).toHaveLength(2);
        }
    });

    it("refuses text with half of a surrogate pair, which the phone's reader would refuse with the whole page", async () => {
        const { account, runNow } = await setUp();
        // The model's JSON escapes a lone high surrogate; JSON.parse makes it a string the wire must never carry.
        const broken = '{"definition": "The smell after rain \\ud83d.", "word": "Petrichor"}';
        const fetcher = model(broken, ROW);
        expect(await run(runNow, fetcher, NOW)).toBe("written");
        expect(userTurnOf(sentBodies(fetcher)[1] ?? {})).toContain(
            'Your last reply was refused: "definition" holds half of a surrogate pair, which is not a character.',
        );
        for (const row of await stored(account.id)) {
            expect(row.change.isWellFormed()).toBe(true);
            expect(row.change).not.toMatch(/\\ud8/i);
        }
        // Twice, and the run is retried, writing nothing.
        const twice = await setUp();
        const logs = await runLogs(async () => expect(await run(twice.runNow, model(broken), NOW)).toBe("retry"));
        expect(logs[0]).toMatchObject({ reason: "unicode" });
        expect(await stored(twice.account.id)).toEqual([]);
        // The pull's page stays readable.
        const page = await send(changes(account.token), { now: NOW });
        expect(page.text.isWellFormed()).toBe(true);
        expect(page.text).not.toMatch(/\\ud8/i);
    });

    it("leaves a run that is refused twice to be claimed again later, giving its claim back", async () => {
        const { account, runNow } = await setUp();
        const fetcher = model({ word: "Petrichor" });
        expect(await run(runNow, fetcher, NOW)).toBe("retry");
        expect(fetcher).toHaveBeenCalledTimes(2);
        expect(userTurnOf(sentBodies(fetcher)[1] ?? {})).toContain(
            'Your last reply was refused: the reply has no "definition"',
        );
        expect(await taskOf(account.id, 1)).toMatchObject({
            due_at: NOW + BACKOFF,
            claimed_until: null,
            attempts: 1,
            row_key: runNow.rowKey,
        });
        expect(await stored(account.id)).toEqual([]);
    });

    it("is not asked again when the model gave no answer", async () => {
        const { runNow } = await setUp();
        const fetcher = model(new Response("{}", { status: 503 }));
        expect(await run(runNow, fetcher, NOW)).toBe("retry");
        expect(fetcher).toHaveBeenCalledTimes(1);
    });

    it("gets a cap that grows with the table's text fields, up to RUN_TOKENS.most", async () => {
        const capOf = async (fields: Record<string, string>) => {
            const { runNow } = await setUp({ fields });
            const fetcher = model(Object.fromEntries(Object.keys(fields).map((id) => [id, sampleOf(fields[id])])));
            expect(await run(runNow, fetcher, NOW)).toBe("written");
            return sentBodies(fetcher)[0]?.max_tokens;
        };
        expect(await capOf({ done: "bool", score: "number" })).toBe(RUN_TOKENS.base);
        expect(await capOf({ score: "number", title: "text" })).toBe(RUN_TOKENS.base + RUN_TOKENS.perText);
        expect(await capOf(textFields(16))).toBe(RUN_TOKENS.most);
    });

    // A reply cut off at its cap (thinking took it, or the row was long) is asked again with twice the cap; with no
    // larger cap to give, the repair would be cut off too, so it is not asked.
    it("is asked again with a larger cap when the model was cut off, and only then", async () => {
        const { runNow } = await setUp();
        const cut = model(answer('{"definition": "The pleasant, ea', 0.0001, "length"), ROW);
        expect(await run(runNow, cut, NOW)).toBe("written");
        expect(sentBodies(cut).map((body) => body.max_tokens)).toEqual([1_500, 3_000]);
        expect(userTurnOf(sentBodies(cut)[1] ?? {})).toContain(
            "Your last reply was refused: it was cut off before it ended; think briefly and reply with the row only.",
        );
        // Thinking that took the whole cap leaves no text at all, which is a cut reply too.
        const empty = await setUp();
        const thought = model(answer("", 0.0003, "length"), ROW);
        const thoughtLogs = await runLogs(async () => expect(await run(empty.runNow, thought, NOW)).toBe("written"));
        expect(sentBodies(thought).map((body) => body.max_tokens)).toEqual([1_500, 3_000]);
        // It is billed, so the log counts it and its usage.
        expect(thoughtLogs[0]).toMatchObject({ calls: 2, input_tokens: 800, output_tokens: 120, finish: "stop" });
        expect(thoughtLogs[0]?.cost_usd).toBeCloseTo(0.0004, 12);

        const wide = await setUp({ fields: textFields(16) });
        const capped = model(answer('{"t0": "a', 0.0001, "length"));
        const logs = await runLogs(async () => expect(await run(wide.runNow, capped, NOW)).toBe("retry"));
        expect(capped).toHaveBeenCalledTimes(1);
        expect(logs[0]).toMatchObject({ reason: "cut", finish: "length", calls: 1, output_tokens: 60 });
    });
});

/// `count` text fields, t0 to t<count - 1>.
function textFields(count: number): Record<string, string> {
    return Object.fromEntries([...Array(count).keys()].map((i) => [`t${i}`, "text"]));
}

/// A value of the kind a field names.
function sampleOf(kind: string | undefined): unknown {
    return { text: "A line.", number: 1, bool: true, date: "2026-12-01" }[kind ?? "text"];
}

describe("failures", () => {
    /// Runs the claimed `first` message at `now`, then claims and runs its task again as soon as the cron would, until
    /// it has run MAX_ATTEMPTS times or is gone. Each run's time, outcome, and the task's `due_at` after it.
    async function failEveryTime(account: string, once: number, first: RunMessage, now: number) {
        const failing = model(new Response("{}", { status: 500 }));
        const runs: { at: number; outcome: string; due: number | null }[] = [];
        let message = first;
        let at = now;
        for (let i = 0; i < MAX_ATTEMPTS; i++) {
            const outcome = await run(message, failing, at);
            const task = await taskOf(account, once);
            runs.push({ at, outcome, due: task?.due_at ?? null });
            if (!task || outcome !== "retry") break;
            at = Math.max(task.due_at, (task.claimed_until ?? 0) + 1);
            [message] = (await claim(at)).filter((m) => m.task === task.id) as [RunMessage];
        }
        return runs;
    }

    it("push the task back by a gap that doubles, and five move the schedule to its next run", async () => {
        const { account, schedule, now } = await setUp();
        // Without its run now, which the cron would hand out before the schedule.
        await env.DB.prepare("DELETE FROM tasks WHERE account = ? AND once = 1").bind(account.id).run();
        const before = await taskOf(account.id, 0);
        const runs = await failEveryTime(account.id, 0, schedule, now);
        expect(runs.map((r) => r.outcome)).toEqual(["retry", "retry", "retry", "retry", "moved on"]);
        // Due again 15, 30, 60, then 120 minutes after each failed run.
        expect(runs.slice(0, 4).map((r) => (r.due ?? 0) - r.at)).toEqual([
            BACKOFF,
            2 * BACKOFF,
            4 * BACKOFF,
            8 * BACKOFF,
        ]);
        const after = await taskOf(account.id, 0);
        expect(after).toMatchObject({ claimed_until: null, attempts: 0 });
        expect(after?.run_at).toBe(
            nextRun({ every: "day", hour: 6, minute: 0 }, "America/New_York", before?.run_at ?? 0),
        );
        expect(after?.row_key).not.toBe(before?.row_key);
        expect(await stored(account.id)).toEqual([]);
    });

    it("five delete a run now, which the schedule follows", async () => {
        const { account, runNow, now } = await setUp();
        const runs = await failEveryTime(account.id, 1, runNow, now);
        expect(runs.map((r) => r.outcome)).toEqual(["retry", "retry", "retry", "retry", "moved on"]);
        expect(await taskOf(account.id, 1)).toBeNull();
        expect(await taskOf(account.id, 0)).not.toBeNull();
    });

    it("move on a task whose last five runs never finished, without asking the model", async () => {
        const { account, runNow } = await setUp();
        await env.DB.prepare("UPDATE tasks SET attempts = ? WHERE id = ?").bind(MAX_ATTEMPTS, runNow.task).run();
        const fetcher = model(ROW);
        expect(await run({ ...runNow, attempts: MAX_ATTEMPTS }, fetcher, NOW)).toBe("moved on");
        expect(fetcher).not.toHaveBeenCalled();
        expect(await taskOf(account.id, 1)).toBeNull();
    });

    // An account always has a zone once it has tasks; if one did not, each run would throw. The attempts are checked
    // first, so the task moves on (with no zone, a schedule cannot be placed, so it goes) instead of looping.
    it("move on a task whose account has no zone once its runs keep throwing", async () => {
        const { account, schedule } = await setUp();
        await env.DB.prepare("UPDATE accounts SET time_zone = NULL WHERE id = ?").bind(account.id).run();
        await expect(run(schedule, model(ROW), NOW)).rejects.toThrow("the task's account has no time zone");
        expect((await taskOf(account.id, 0))?.attempts).toBe(1);
        await env.DB.prepare("UPDATE tasks SET attempts = ? WHERE id = ?").bind(MAX_ATTEMPTS, schedule.task).run();
        const fetcher = model(ROW);
        expect(await run({ ...schedule, attempts: MAX_ATTEMPTS }, fetcher, NOW)).toBe("moved on");
        expect(fetcher).not.toHaveBeenCalled();
        expect(await taskOf(account.id, 0)).toBeNull();
    });
});

describe("the log", () => {
    it("has one line a run with the model, seconds, usage, and cost, and never the prompt or the row", async () => {
        const lines: string[] = [];
        vi.spyOn(console, "log").mockImplementation((line: string) => lines.push(line));
        const { runNow } = await setUp();
        await run(runNow, model({ word: "Petrichor" }, ROW), NOW);
        const runs = lines.map((line) => JSON.parse(line)).filter((line) => line.run === "automation");
        expect(runs).toHaveLength(1);
        expect(runs[0]).toMatchObject({
            task: runNow.task,
            outcome: "written",
            attempts: 1,
            calls: 2,
            model: SETTINGS.model,
            provider: "Together",
            finish: "stop",
            input_tokens: 800,
            output_tokens: 120,
            cost_usd: 0.0002,
        });
        expect(typeof runs[0].seconds).toBe("number");
        const all = lines.join("\n");
        for (const secret of [automation().prompt as string, "Petrichor", ROW.definition])
            expect(all).not.toContain(secret);
    });
});

describe("the consumer", () => {
    it("acks each message it ran, and leaves one that threw to the queue's retries", async () => {
        const { account, runNow, schedule } = await setUp();
        const ctx = createExecutionContext();
        const ok = createMessageBatch<RunMessage>("widgie-runs", [
            { id: "a", timestamp: new Date(NOW), attempts: 1, body: runNow },
            {
                id: "b",
                timestamp: new Date(NOW),
                attempts: 1,
                body: { task: 999_999, rowKey: runNow.rowKey, attempts: 0 },
            },
        ]);
        await consume(ok, env, { fetch: model(ROW), now: () => NOW });
        expect(await getQueueResult(ok, ctx)).toMatchObject({ explicitAcks: ["a", "b"], retryMessages: [] });

        await env.DB.prepare("UPDATE accounts SET time_zone = NULL WHERE id = ?").bind(account.id).run();
        const broken = createMessageBatch<RunMessage>("widgie-runs", [
            { id: "c", timestamp: new Date(NOW), attempts: 1, body: schedule },
        ]);
        vi.spyOn(console, "error").mockImplementation(() => {});
        const retry = vi.spyOn(broken.messages[0] as Message<RunMessage>, "retry");
        await consume(broken, env, { fetch: model(ROW), now: () => NOW });
        expect(await getQueueResult(broken, ctx)).toMatchObject({ explicitAcks: [], retryMessages: [{ msgId: "c" }] });
        // A minute later, not at once.
        expect(retry).toHaveBeenCalledWith({ delaySeconds: RETRY_DELAY_S });
    });
});
