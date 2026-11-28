import { env } from "cloudflare:workers";
import { afterEach, describe, expect, it, vi } from "vitest";
import { type Env, handle } from "../src/index";
import { answer, model, sentBodies, userTurnOf } from "./helpers/runs";

const devEnv = { ...env, ENVIRONMENT: "dev", DEV_REGISTRATION_SECRET: "dev-secret" } as Env;

const WORDS = { word: "text", kind: "text", definition: "text" };
const RECENT = [
    { word: "Petrichor", kind: "noun", definition: "the smell after rain" },
    { word: "Ebullient", kind: "adjective", definition: "full of energy" },
];
const NEW = { word: "Serendipity", kind: "noun", definition: "finding good things by chance" };
const SIXTEEN = Object.fromEntries(Array.from({ length: 16 }, (_, i) => [`f${i}`, "text"]));

function body(overrides: Record<string, unknown> = {}) {
    return {
        prompt: "Pick an interesting English word.",
        fields: WORDS,
        timeZone: "America/New_York",
        runAt: Date.parse("2026-11-30T11:00:00Z"),
        recent: RECENT,
        ...overrides,
    };
}

function request(secret: string | null, payload: unknown = body(), method = "POST", path = "/v1/dev/run") {
    const sent = typeof payload === "string" ? payload : JSON.stringify(payload);
    return new Request(`https://widgie.test${path}`, {
        method,
        headers: {
            "Content-Type": "application/json",
            ...(secret === null ? {} : { "X-Widgie-Dev-Secret": secret }),
        },
        body: method === "GET" || method === "HEAD" ? null : sent,
    });
}

const METHODS = ["GET", "POST", "PUT", "DELETE", "PATCH", "HEAD", "OPTIONS"];

async function send(req: Request, fetcher: typeof fetch, environment: Env = devEnv) {
    const response = await handle(req, environment, { fetch: fetcher });
    const text = await response.text();
    const json = response.headers.get("Content-Type")?.startsWith("application/json");
    return { status: response.status, text, body: (json ? JSON.parse(text) : null) as Record<string, unknown> | null };
}

async function stored(): Promise<number> {
    const row = await env.DB.prepare(
        "SELECT (SELECT count(*) FROM accounts) + (SELECT count(*) FROM tasks) + (SELECT count(*) FROM changes) AS n",
    ).first<{ n: number }>();
    return row?.n ?? 0;
}

afterEach(() => {
    vi.restoreAllMocks();
});

/// What `handle` answers by `method` on a path no route has: what every refused dev run must look like.
async function unknownPath(method: string, environment: Env) {
    const { status, text } = await send(request(null, body(), method, "/v1/dev/nothing"), model(NEW), environment);
    return { status, text };
}

describe("POST /v1/dev/run", () => {
    // Production does not route the path, so no method tells it apart from an unknown path (a 405 would).
    it("is an unknown path in production for every method, even with the secret its test config holds", async () => {
        expect(env.ENVIRONMENT).toBe("production");
        const fetcher = model(NEW);
        for (const method of METHODS) {
            for (const secret of ["dev-secret", null]) {
                const answered = await send(request(secret, body(), method), fetcher, env);
                const label = `${method} ${String(secret)}`;
                expect({ status: answered.status, text: answered.text }, label).toEqual(await unknownPath(method, env));
                expect(answered.status, label).toBe(404);
            }
        }
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("is an unknown path on dev for every method with a wrong secret, no secret, or no secret configured", async () => {
        const fetcher = model(NEW);
        for (const [secret, environment] of [
            ["dev-secreT", devEnv],
            ["", devEnv],
            [null, devEnv],
            ["dev-secret", { ...devEnv, DEV_REGISTRATION_SECRET: undefined } as Env],
            ["", { ...devEnv, DEV_REGISTRATION_SECRET: "" } as Env],
        ] as const) {
            for (const method of METHODS) {
                const answered = await send(request(secret, body(), method), fetcher, environment);
                const label = `${method} ${String(secret)}`;
                expect({ status: answered.status, text: answered.text }, label).toEqual(
                    await unknownPath(method, environment),
                );
                expect(answered.status, label).toBe(404);
            }
        }
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("answers 405 to another method only once the secret is right", async () => {
        const fetcher = model(NEW);
        for (const method of ["GET", "PUT"]) {
            expect((await send(request("dev-secret", body(), method), fetcher)).status, method).toBe(405);
        }
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("runs one turn with the recent rows and answers the row it would write, writing nothing", async () => {
        const before = await stored();
        const fetcher = model(NEW);
        const { status, body: reply } = await send(request("dev-secret"), fetcher);
        expect(status).toBe(200);
        expect(reply).toEqual({
            row: NEW,
            outcome: "written",
            reason: null,
            calls: 1,
            model: "deepseek/deepseek-v4.1-flash-1017",
            provider: "Together",
            finish: "stop",
            usage: { input_tokens: 400, cached_tokens: 0, output_tokens: 60, cost_usd: 0.0001 },
            seconds: expect.any(Number),
        });
        const [sent] = sentBodies(fetcher);
        const turn = userTurnOf(sent ?? {});
        // The day is the run time's in the zone, and the recent rows are listed newest first as the consumer lists them.
        expect(turn).toContain("The row appears on Monday, 2026-11-30.");
        expect(turn).toContain(`Never repeat one of them:\n${JSON.stringify(RECENT[0])}\n${JSON.stringify(RECENT[1])}`);
        expect(sent?.response_format).toMatchObject({ type: "json_schema" });
        expect(await stored()).toBe(before);
    });

    it("refuses a repeat and asks once more, as the consumer does", async () => {
        const fetcher = model(RECENT[1], NEW);
        const { body: reply } = await send(request("dev-secret"), fetcher);
        expect(reply).toMatchObject({ row: NEW, outcome: "written", reason: null, calls: 2 });
        expect(userTurnOf(sentBodies(fetcher)[1] ?? {})).toContain("Your last reply was refused: it repeats");
    });

    it("answers retry with the refusal when the repair is refused too, and a date as its day", async () => {
        const refused = await send(request("dev-secret"), model("not json"));
        expect(refused.body).toMatchObject({ row: null, outcome: "retry", reason: "json", calls: 2 });

        const dated = await send(
            request("dev-secret", body({ fields: { due: "date", left: "number", done: "bool" }, recent: [] })),
            model({ due: "2026-12-24", left: 3, done: false }),
        );
        expect(dated.body).toMatchObject({ row: { due: "2026-12-24", left: 3, done: false }, outcome: "written" });
    });

    it("answers retry with the failure when the model service fails, with no repair, counting the call", async () => {
        const fetcher = model(new Response(JSON.stringify({ error: { code: 500, message: "down" } }), { status: 500 }));
        const { body: reply } = await send(request("dev-secret"), fetcher);
        expect(reply).toMatchObject({
            row: null,
            outcome: "retry",
            calls: 1,
            usage: { input_tokens: 0, cached_tokens: 0, output_tokens: 0, cost_usd: null },
        });
        expect(String(reply?.reason)).toContain("HTTP 500");
        expect(fetcher).toHaveBeenCalledTimes(1);
    });

    // Thinking that took the whole cap leaves no text, and is billed all the same.
    it("counts a call cut off with no text, and its usage", async () => {
        const fetcher = model(answer("", 0.0003, "length"), NEW);
        const { body: reply } = await send(request("dev-secret"), fetcher);
        expect(reply).toMatchObject({
            row: NEW,
            outcome: "written",
            calls: 2,
            finish: "stop",
            usage: { input_tokens: 800, output_tokens: 120, cost_usd: expect.closeTo(0.0004, 12) },
        });

        const twice = await send(request("dev-secret"), model(answer("", 0.0003, "length")));
        expect(twice.body).toMatchObject({
            row: null,
            outcome: "retry",
            reason: "cut",
            calls: 2,
            finish: "length",
            usage: { input_tokens: 800, output_tokens: 120, cost_usd: expect.closeTo(0.0006, 12) },
        });
    });

    it("refuses a malformed body with 400 and calls no model", async () => {
        const fetcher = vi.fn<typeof fetch>(async () => answer(NEW));
        for (const bad of [
            "{",
            "[]",
            body({ prompt: "" }),
            body({ prompt: 3 }),
            // The upload's limits: 2,000 characters (an emoji is one), 16 fields, no reserved id.
            body({ prompt: "👋".repeat(2001) }),
            body({ fields: { ...SIXTEEN, f16: "text" } }),
            body({ fields: { word: "text", day: "text" } }),
            body({ fields: { word: "words" } }),
            body({ fields: { "not an id": "text" } }),
            body({ timeZone: "Mars/Olympus" }),
            body({ runAt: "tomorrow" }),
            body({ recent: [{ word: 3 }] }),
            body({ recent: ["Petrichor"] }),
            // A recent row holds text fields of the table, each at most 300 UTF-16 units, as the consumer's do.
            body({ recent: [{ word: "Petrichor", rank: "noun" }] }),
            body({ fields: { word: "text", rank: "number" }, recent: [{ word: "Petrichor", rank: "3" }] }),
            body({ recent: [{ word: "x".repeat(301) }] }),
            body({ recent: [{ word: "😀".repeat(151) }] }),
            body({ recent: Array.from({ length: 61 }, (_, i) => ({ word: `w${i}` })) }),
        ]) {
            const { status, body: reply } = await send(request("dev-secret", bad), fetcher);
            expect(status, JSON.stringify(bad).slice(0, 80)).toBe(400);
            expect(String(reply?.error)).toMatch(/^bad request: /);
        }
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("takes what an upload takes: 2,000 emoji of prompt, 16 fields, and recent text of 300 units", async () => {
        const row = Object.fromEntries(Object.keys(SIXTEEN).map((id) => [id, id]));
        const recent = [{ f0: "x".repeat(300) }, { f1: "😀".repeat(150) }];
        const fetcher = model(row);
        const sent = body({ prompt: "👋".repeat(2000), fields: SIXTEEN, recent });
        const { status, body: reply } = await send(request("dev-secret", sent), fetcher);
        expect(status).toBe(200);
        expect(reply).toMatchObject({ row, outcome: "written" });
    });

    it("lists the fields to the model in id order, as the runner reads a task's fields back", async () => {
        const fetcher = model(NEW);
        await send(request("dev-secret", body({ recent: [] })), fetcher);
        expect(userTurnOf(sentBodies(fetcher)[0] ?? {})).toContain(
            "The table's fields:\n- definition: text\n- kind: text\n- word: text\n",
        );
    });
});
