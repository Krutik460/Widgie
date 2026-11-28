import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import requests from "../../Engine/Evals/testdata/requests.json";
import { MAX_BODY } from "../src/body";
import prompt from "../src/build-prompt.txt";
import { toBase64 } from "../src/bytes";
import { type Env, handle } from "../src/index";
import { Signer } from "./helpers/appattest";

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

/// A request signed by a newly attested key, or by `signer`. A body that is not a string or bytes (a stream) is
/// sent with headers signed over an empty body: it is refused before the signature is checked.
async function post(body: BodyInit | null, headers: Record<string, string> = {}, signer?: Signer) {
    const key = signer ?? (await Signer.attested());
    const signed = typeof body === "string" || body instanceof Uint8Array ? body : "";
    return new Request("https://widgie.test/v1/reply", {
        method: "POST",
        headers: { "Content-Type": "application/json", ...(await key.headers(signed)), ...headers },
        body,
    });
}

async function send(request: Request, fetcher = upstream(), deadlineMs?: number, environment: Env = env) {
    const response = await handle(request, environment, { fetch: fetcher, deadlineMs });
    return { status: response.status, body: (await response.json()) as Record<string, unknown>, fetcher };
}

/// A namespace that throws if the route reaches a Durable Object.
const untouchable = {
    ...env,
    ATTESTED_KEY: {
        getByName: () => {
            throw new Error("a Durable Object was touched");
        },
    } as unknown as Env["ATTESTED_KEY"],
};

const create = JSON.stringify(requests.create);

/// A body stream that records whether anything read it. A high-water mark of 0, so only a read pulls.
function unreadStream(text: string) {
    let pulled = false;
    const stream = new ReadableStream<Uint8Array>(
        {
            pull(controller) {
                pulled = true;
                controller.enqueue(new TextEncoder().encode(text));
                controller.close();
            },
        },
        { highWaterMark: 0 },
    );
    return { stream, pulled: () => pulled };
}

describe("the signature", () => {
    it("is required before the body is read or a Durable Object touched", async () => {
        const signer = await Signer.create();
        const good = await signer.headers(create);
        // The control: a signed request reads the same kind of stream.
        const control = await Signer.attested();
        const controlBody = unreadStream(create);
        const signed = new Request("https://widgie.test/v1/reply", {
            method: "POST",
            headers: { "Content-Type": "application/json", ...(await control.headers(create)) },
            body: controlBody.stream,
        });
        expect((await send(signed)).status).toBe(200);
        expect(controlBody.pulled()).toBe(true);

        const cases: Record<string, string>[] = [
            {},
            { "X-Widgie-Key": good["X-Widgie-Key"] as string },
            { "X-Widgie-Assertion": good["X-Widgie-Assertion"] as string },
            { ...good, "X-Widgie-Key": "abc" },
            { ...good, "X-Widgie-Key": `${toBase64(new Uint8Array(32)).slice(0, 42)}B=` },
            { ...good, "X-Widgie-Assertion": "not base64" },
            { ...good, "X-Widgie-Assertion": "A".repeat(2048) },
        ];
        for (const headers of cases) {
            const body = unreadStream(create);
            const request = new Request("https://widgie.test/v1/reply", {
                method: "POST",
                headers: { "Content-Type": "application/json", ...headers },
                body: body.stream,
            });
            const { status, body: answer, fetcher } = await send(request, upstream(), undefined, untouchable);
            expect([status, answer], JSON.stringify(headers)).toEqual([
                401,
                { error: "the request's signature is not valid", code: "bad-assertion" },
            ]);
            expect(body.pulled()).toBe(false);
            expect(fetcher).not.toHaveBeenCalled();
        }
    });

    it("comes before the size check: an oversized unsigned body is a 401, not a 413", async () => {
        const request = new Request("https://widgie.test/v1/reply", {
            method: "POST",
            headers: { "Content-Type": "application/json" },
            body: "x".repeat(MAX_BODY + 1),
        });
        expect((await send(request, upstream(), undefined, untouchable)).status).toBe(401);
    });

    it("from a key that was never attested is unknown-key", async () => {
        const signer = await Signer.create();
        const { status, body, fetcher } = await send(await post(create, {}, signer));
        expect([status, body]).toEqual([401, { error: "this key is not attested", code: "unknown-key" }]);
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("refuses a replayed request, another body, and another path, and calls no model", async () => {
        const signer = await Signer.attested();
        const headers = await signer.headers(create);
        const sent = () =>
            new Request("https://widgie.test/v1/reply", {
                method: "POST",
                headers: { "Content-Type": "application/json", ...headers },
                body: create,
            });
        expect((await send(sent())).status).toBe(200);
        const replayed = await send(sent());
        expect([replayed.status, replayed.body.code]).toEqual([401, "bad-assertion"]);
        expect(replayed.fetcher).not.toHaveBeenCalled();

        const other = await send(await post(JSON.stringify(requests.refine), await signer.headers(create), signer));
        expect([other.status, other.body.code]).toEqual([401, "bad-assertion"]);
        const elsewhere = await signer.headers(create, { path: "/v1/attest" });
        const wrongPath = await send(await post(create, elsewhere, signer));
        expect([wrongPath.status, wrongPath.body.code]).toEqual([401, "bad-assertion"]);
        expect(other.fetcher).not.toHaveBeenCalled();
        expect(wrongPath.fetcher).not.toHaveBeenCalled();
    });

    it("has no daily limit for now: one key's calls all reach the model", async () => {
        const signer = await Signer.attested();
        const fetcher = upstream();
        for (let i = 0; i < 5; i++) expect((await send(await post(create, {}, signer), fetcher)).status).toBe(200);
        expect(fetcher).toHaveBeenCalledTimes(5);
    });

    it("is checked before the request is validated, so a malformed request uses up its counter", async () => {
        const signer = await Signer.attested();
        const malformed = JSON.stringify({ words: "" });
        const headers = await signer.headers(malformed);
        const sent = () => post(malformed, headers, signer);
        const { status, fetcher } = await send(await sent());
        expect(status).toBe(400);
        expect(fetcher).not.toHaveBeenCalled();
        expect((await send(await sent())).body.code).toBe("bad-assertion");
        expect((await send(await post(create, {}, signer))).status).toBe(200);
    });
});

describe("the body", () => {
    it("must be JSON", async () => {
        const { status } = await send(await post("{}", { "Content-Type": "text/plain" }));
        expect(status).toBe(415);
    });

    it("is refused over the limit by its declared length", async () => {
        const { status, body } = await send(await post("{}", { "Content-Length": String(MAX_BODY + 1) }));
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
        const { status, fetcher } = await send(await post(stream));
        expect(status).toBe(413);
        expect(fetcher).not.toHaveBeenCalled();
    });

    it("refuses a body that is not UTF-8", async () => {
        const { status } = await send(await post(new Uint8Array([0x7b, 0x22, 0xff, 0x22, 0x7d])));
        expect(status).toBe(400);
    });

    it("answers with one short line even when a key holds newlines", async () => {
        const { body } = await send(await post(JSON.stringify({ words: "a", [`x\n${"y".repeat(5000)}`]: 1 })));
        expect(String(body.error).length).toBeLessThanOrEqual(300);
        expect(String(body.error)).not.toContain("\n");
    });

    it("answers a malformed request with the bridge's bad-request line", async () => {
        expect((await send(await post("not json"))).body.error).toBe(
            "bad request: the body must be a ModelRequest JSON object",
        );
        const { status, body, fetcher } = await send(await post(JSON.stringify({ words: "a", colour: "blue" })));
        expect([status, body.error]).toEqual([400, "bad request: unknown request fields: colour"]);
        expect(fetcher).not.toHaveBeenCalled();
    });
});

describe("the log", () => {
    it("never holds the words, the document, the picture, or the reply", async () => {
        const log = vi.spyOn(console, "log").mockImplementation(() => {});
        const request = requests["refine-repair"];
        const picture = requests["create-image"];
        const signer = await Signer.attested();
        const signed = await post(JSON.stringify(request), {}, signer);
        const assertion = signed.headers.get("X-Widgie-Assertion") ?? "";
        await send(signed);
        await send(await post(JSON.stringify(picture)));
        await send(await post(JSON.stringify({ ...request, colour: "blue" })));
        await send(await post(create, {}, await Signer.create()));
        const lines = log.mock.calls.flat().join("\n");
        log.mockRestore();
        expect(lines).toContain('"route":"reply"');
        expect(lines).toContain('"status":401,"ms"');
        expect(lines).toContain('"code":"unknown-key"');
        const secrets = [request.words, request.current, request.repair.line, picture.image.base64.slice(0, 40)];
        for (const secret of [...secrets, signer.keyId, assertion.slice(0, 40)]) {
            expect(lines).not.toContain(secret);
        }
        expect(lines).not.toContain(ANSWER.choices[0]?.message.content);
    });

    it("keeps a failure's reason to one short line", async () => {
        const log = vi.spyOn(console, "log").mockImplementation(() => {});
        const long = `quoted input\n${"x".repeat(5000)}`;
        await send(await post(JSON.stringify(requests.create)), upstream(400, { error: { code: 400, message: long } }));
        const line = JSON.parse(String(log.mock.calls[0]?.[0]));
        log.mockRestore();
        expect(line.reason.length).toBeLessThanOrEqual(300);
        expect(line.reason).not.toContain("\n");
    });
});

describe("the model call", () => {
    it("sends the build prompt and the request, and answers the reply with its usage", async () => {
        const { status, body, fetcher } = await send(await post(JSON.stringify(requests["create-image"])));
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
            const { status, body } = await send(await post(JSON.stringify(requests.create)), fetcher);
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
        const { status, body } = await send(await post(JSON.stringify(requests.create)), slow, 50);
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
