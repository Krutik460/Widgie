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

function request(secret: string | null, payload: unknown = body()) {
    return new Request("https://widgie.test/v1/dev/run", {
        method: "POST",
        headers: {
            "Content-Type": "application/json",
            ...(secret === null ? {} : { "X-Widgie-Dev-Secret": secret }),
        },
        body: typeof payload === "string" ? payload : JSON.stringify(payload),
    });
}

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

describe("POST /v1/dev/run", () => {
    it("is not found in production, even with the secret production's test config holds", async () => {
        const fetcher = model(NEW);
        const { status, text } = await send(request("dev-secret"), fetcher, env);
        expect(status).toBe(404);
        expect(text).toBe("not found\n");
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("is not found on dev with a wrong secret, no secret, or no secret configured", async () => {
        const fetcher = model(NEW);
        for (const [secret, environment] of [
            ["dev-secreT", devEnv],
            ["", devEnv],
            [null, devEnv],
            ["dev-secret", { ...devEnv, DEV_REGISTRATION_SECRET: undefined } as Env],
            ["", { ...devEnv, DEV_REGISTRATION_SECRET: "" } as Env],
        ] as const) {
            const { status } = await send(request(secret), fetcher, environment);
            expect(status, String(secret)).toBe(404);
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

    it("answers retry with the failure when the model service fails, with no repair", async () => {
        const fetcher = model(new Response(JSON.stringify({ error: { code: 500, message: "down" } }), { status: 500 }));
        const { body: reply } = await send(request("dev-secret"), fetcher);
        expect(reply).toMatchObject({ row: null, outcome: "retry", calls: 0 });
        expect(String(reply?.reason)).toContain("HTTP 500");
        expect(fetcher).toHaveBeenCalledTimes(1);
    });

    it("refuses a malformed body with 400 and calls no model", async () => {
        const fetcher = vi.fn<typeof fetch>(async () => answer(NEW));
        for (const bad of [
            "{",
            "[]",
            body({ prompt: " " }),
            body({ fields: {} }),
            body({ fields: { word: "words" } }),
            body({ fields: { "not an id": "text" } }),
            body({ timeZone: "Mars/Olympus" }),
            body({ runAt: "tomorrow" }),
            body({ recent: [{ word: 3 }] }),
            body({ recent: Array.from({ length: 61 }, (_, i) => ({ word: `w${i}` })) }),
        ]) {
            const { status, body: reply } = await send(request("dev-secret", bad), fetcher);
            expect(status, JSON.stringify(bad).slice(0, 80)).toBe(400);
            expect(String(reply?.error)).toMatch(/^bad request: /);
        }
        expect(fetcher).not.toHaveBeenCalled();
    });
});
