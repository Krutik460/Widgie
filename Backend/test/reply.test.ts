import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import requests from "../../Engine/Evals/testdata/requests.json";
import prompt from "../src/build-prompt.txt";
import { handle, MAX_BODY } from "../src/index";

const ANSWER = {
    model: "anthropic/claude-sonnet-5.5",
    provider: "Amazon Bedrock",
    choices: [{ message: { content: "```json\n{}\n```" } }],
    usage: {
        prompt_tokens: 14_000,
        completion_tokens: 900,
        cost: 0.02,
        prompt_tokens_details: { cached_tokens: 13_900 },
    },
};

function upstream(status = 200, body: unknown = ANSWER) {
    return vi.fn<typeof fetch>(async () => new Response(JSON.stringify(body), { status }));
}

function post(body: BodyInit | null, headers: Record<string, string> = {}) {
    return new Request("https://widgie.test/v1/reply", {
        method: "POST",
        headers: { Authorization: "Bearer test-operator", "Content-Type": "application/json", ...headers },
        body,
    });
}

async function send(request: Request, fetcher = upstream(), deadlineMs?: number) {
    const response = await handle(request, env, { fetch: fetcher, deadlineMs });
    return { status: response.status, body: (await response.json()) as Record<string, unknown>, fetcher };
}

describe("the gate", () => {
    it("refuses a request without the operator token and makes no upstream call", async () => {
        for (const headers of [
            { Authorization: "" },
            { Authorization: "Bearer wrong" },
            { Authorization: "test-operator" },
        ]) {
            const { status, fetcher } = await send(post(JSON.stringify(requests.create), headers));
            expect(status).toBe(401);
            expect(fetcher).not.toHaveBeenCalled();
        }
    });

    it("refuses before reading the body, so an oversized body without the token is a 401", async () => {
        const { status } = await send(post("x".repeat(MAX_BODY + 1), { Authorization: "" }));
        expect(status).toBe(401);
    });

    it("refuses everything when no operator token is set", async () => {
        const response = await handle(
            post(JSON.stringify(requests.create)),
            { ...env, OPERATOR_TOKEN: undefined },
            {
                fetch: upstream(),
            },
        );
        expect(response.status).toBe(401);
    });
});

describe("the body", () => {
    it("must be JSON", async () => {
        const { status } = await send(post("{}", { "Content-Type": "text/plain" }));
        expect(status).toBe(415);
    });

    it("is refused over the limit by its declared length", async () => {
        const { status, body } = await send(post("{}", { "Content-Length": String(MAX_BODY + 1) }));
        expect(status).toBe(413);
        expect(body.error).toBe(`the body is over ${MAX_BODY} bytes`);
    });

    it("is refused over the limit while streaming when no length is declared", async () => {
        const chunk = new Uint8Array(1024 * 1024);
        let sent = 0;
        const stream = new ReadableStream<Uint8Array>({
            pull(controller) {
                if (sent++ > 9) controller.close();
                else controller.enqueue(chunk);
            },
        });
        const { status, fetcher } = await send(post(stream));
        expect(status).toBe(413);
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("answers a malformed request with the bridge's bad-request line", async () => {
        expect((await send(post("not json"))).body.error).toBe(
            "bad request: the body must be a ModelRequest JSON object",
        );
        const { status, body, fetcher } = await send(post(JSON.stringify({ words: "a", colour: "blue" })));
        expect([status, body.error]).toEqual([400, "bad request: unknown request fields: colour"]);
        expect(fetcher).not.toHaveBeenCalled();
    });
});

describe("the model call", () => {
    it("sends the build prompt and the request, and answers the reply with its usage", async () => {
        const { status, body, fetcher } = await send(post(JSON.stringify(requests["create-image"])));
        expect(status).toBe(200);
        expect(body).toMatchObject({
            reply: "```json\n{}\n```",
            model: "anthropic/claude-sonnet-5.5",
            usage: { input_tokens: 14_000, cached_tokens: 13_900, output_tokens: 900, cost_usd: 0.02 },
        });
        expect(typeof body.seconds).toBe("number");

        const [url, init] = fetcher.mock.calls[0] ?? [];
        expect(url).toBe(env.MODEL_URL);
        expect(new Headers(init?.headers).get("Authorization")).toBe("Bearer test-key");
        const sent = JSON.parse(String(init?.body));
        expect(sent.model).toBe(env.MODEL);
        // Whatever wrangler.jsonc names; requestBody's own tests cover each shape.
        expect(sent.provider).toEqual(env.PROVIDER ? { order: [env.PROVIDER], allow_fallbacks: false } : undefined);
        expect(sent.messages[0].content[0].text).toBe(prompt);
    });

    it("answers 502 with a fixed line when OpenRouter fails, whatever it said", async () => {
        const failures = [
            upstream(429, { error: { code: 429, message: "rate limited upstream secret detail" } }),
            upstream(200, { error: { code: 502, message: "provider error" } }),
            upstream(200, { choices: [{ message: { content: "" } }] }),
            vi.fn<typeof fetch>(async () => new Response("<html>", { status: 500 })),
            vi.fn<typeof fetch>(async () => {
                throw new TypeError("network down");
            }),
        ];
        for (const fetcher of failures) {
            const { status, body } = await send(post(JSON.stringify(requests.create)), fetcher);
            expect([status, body]).toEqual([502, { error: "the model gave no answer" }]);
        }
    });

    it("gives up at the deadline, including while the body is still arriving", async () => {
        const slow = vi.fn<typeof fetch>(async (_url, init) => {
            const body = new ReadableStream({
                start(controller) {
                    init?.signal?.addEventListener("abort", () => controller.error(new Error("aborted")));
                },
            });
            return new Response(body, { status: 200 });
        });
        const { status, body } = await send(post(JSON.stringify(requests.create)), slow, 50);
        expect([status, body]).toEqual([502, { error: "the model gave no answer" }]);
    });
});

describe("other routes", () => {
    it("answers health and nothing else", async () => {
        expect(await (await handle(new Request("https://widgie.test/health"), env, { fetch: upstream() })).text()).toBe(
            "ok\n",
        );
        expect((await handle(new Request("https://widgie.test/v2"), env, { fetch: upstream() })).status).toBe(404);
        expect((await handle(new Request("https://widgie.test/v1/reply"), env, { fetch: upstream() })).status).toBe(
            405,
        );
    });
});
