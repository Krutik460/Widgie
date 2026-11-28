import { env } from "cloudflare:workers";
import { beforeAll, describe, expect, it, vi } from "vitest";
import { MAX_ATTEST_BODY } from "../src/body";
import { toBase64 } from "../src/bytes";
import { type Dependencies, type Env, handle } from "../src/index";
import { attestation, type Chain, chain, newKey, type Party, randomChallenge, Signer } from "./helpers/appattest";

const NOW = new Date("2026-11-23T12:00:00Z");
let trusted: Chain;
let deps: Dependencies & { fetch: ReturnType<typeof vi.fn<typeof fetch>> };

beforeAll(async () => {
    trusted = await chain(NOW);
    deps = {
        fetch: vi.fn<typeof fetch>(
            async () => new Response(JSON.stringify({ model: "m", choices: [{ message: { content: "ok" } }] })),
        ),
        attestRoot: trusted.rootDer,
        now: () => NOW,
    };
});

function post(path: string, body: BodyInit | object, headers: Record<string, string> = {}) {
    const encoded = typeof body === "string" || body instanceof ReadableStream ? body : JSON.stringify(body);
    return new Request(`https://widgie.test${path}`, {
        method: "POST",
        headers: { "Content-Type": "application/json", ...headers },
        body: encoded,
    });
}

async function send(request: Request, environment: Env = env) {
    const response = await handle(request, environment, deps);
    const text = await response.text();
    return { status: response.status, body: (text ? JSON.parse(text) : null) as Record<string, unknown> | null };
}

async function issue(keyId: string): Promise<string> {
    const { status, body } = await send(post("/v1/attest/challenge", { keyId }));
    expect(status).toBe(200);
    return String(body?.challenge);
}

/// The attestation object for `leaf` over `challenge`, as standard base64.
async function attestationOver(leaf: Party, challenge: string): Promise<string> {
    return toBase64((await attestation({ now: NOW, chain: trusted, leaf, challenge })).attestation);
}

/// A namespace that throws if a route reaches a Durable Object.
const untouchable = {
    ...env,
    ATTESTED_KEY: {
        getByName: () => {
            throw new Error("a Durable Object was touched");
        },
    } as unknown as Env["ATTESTED_KEY"],
};

describe("attesting a key", () => {
    it("issues a challenge, stores the attested key, and then accepts its signed requests", async () => {
        const { leaf, keyId } = await newKey();
        const challenge = await issue(keyId);
        expect(challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
        const attested = await send(
            post("/v1/attest", { keyId, challenge, attestation: await attestationOver(leaf, challenge) }),
        );
        expect(attested).toEqual({ status: 204, body: null });

        const signer = await Signer.from(leaf.keys);
        const words = JSON.stringify({ words: "a water tracker" });
        expect((await send(post("/v1/reply", words, await signer.headers(words)))).status).toBe(200);
    });

    it("refuses a challenge for an attested key, and a second attestation, with 409", async () => {
        const signer = await Signer.attested();
        expect(await send(post("/v1/attest/challenge", { keyId: signer.keyId }))).toEqual({
            status: 409,
            body: { error: "this key is already attested", code: "attested" },
        });
        const again = await send(
            post("/v1/attest", { keyId: signer.keyId, challenge: randomChallenge(), attestation: "AAAA" }),
        );
        expect([again.status, again.body?.code]).toEqual([409, "attested"]);
    });

    it("refuses a challenge it never issued, and takes each challenge once even when the attestation fails", async () => {
        const { leaf, keyId } = await newKey();
        const never = await send(post("/v1/attest", { keyId, challenge: randomChallenge(), attestation: "AAAA" }));
        expect(never).toEqual({
            status: 401,
            body: { error: "the attestation is not valid", code: "bad-attestation" },
        });

        const challenge = await issue(keyId);
        const failing = await send(post("/v1/attest", { keyId, challenge, attestation: "AAAA" }));
        expect(failing.body?.code).toBe("bad-attestation");
        const good = await attestationOver(leaf, challenge);
        const retried = await send(post("/v1/attest", { keyId, challenge, attestation: good }));
        expect(retried.body?.code).toBe("bad-attestation");
    });

    it("refuses an attestation that fails a check, logs which, and stores nothing", async () => {
        const { leaf, keyId } = await newKey();
        const challenge = await issue(keyId);
        const log = vi.spyOn(console, "log").mockImplementation(() => {});
        // Made over another challenge, so its nonce is wrong for this one.
        const { status, body } = await send(
            post("/v1/attest", { keyId, challenge, attestation: await attestationOver(leaf, randomChallenge()) }),
        );
        const line = JSON.parse(String(log.mock.calls.at(-1)?.[0]));
        log.mockRestore();
        expect([status, body?.code]).toEqual([401, "bad-attestation"]);
        expect(line).toMatchObject({ route: "attest", status: 401, code: "bad-attestation", reason: "nonce" });
        const signer = await Signer.from(leaf.keys);
        expect((await send(post("/v1/reply", "{}", await signer.headers("{}")))).body?.code).toBe("unknown-key");
    });

    it("never logs the key id, the challenge, or the attestation", async () => {
        const { leaf, keyId } = await newKey();
        const log = vi.spyOn(console, "log").mockImplementation(() => {});
        const challenge = await issue(keyId);
        const encoded = await attestationOver(leaf, challenge);
        await send(post("/v1/attest", { keyId, challenge, attestation: encoded }));
        const lines = log.mock.calls.flat().join("\n");
        log.mockRestore();
        expect(lines).toContain('"route":"challenge","status":200');
        expect(lines).toContain('"route":"attest","status":204');
        for (const secret of [keyId, challenge, encoded.slice(0, 40)]) expect(lines).not.toContain(secret);
    });
});

describe("the attest routes' requests", () => {
    it("refuse a malformed key id before touching a Durable Object", async () => {
        const zero = toBase64(new Uint8Array(32));
        const nonCanonical = `${zero.slice(0, 42)}B=`;
        expect(atob(nonCanonical)).toBe(atob(zero));
        for (const keyId of ["", "abc", zero.slice(0, 43), `${zero.slice(0, 42)}==`, nonCanonical, 42, null]) {
            for (const path of ["/v1/attest/challenge", "/v1/attest"]) {
                const body =
                    path === "/v1/attest" ? { keyId, challenge: randomChallenge(), attestation: "AAAA" } : { keyId };
                const answer = await send(post(path, body), untouchable);
                expect([answer.status, answer.body?.error], `${path} ${keyId}`).toEqual([
                    400,
                    'bad request: "keyId" must be an App Attest key id',
                ]);
            }
        }
    });

    it("refuse a malformed challenge or attestation, or unknown fields, before touching a Durable Object", async () => {
        const keyId = toBase64(new Uint8Array(32));
        const cases: [object, string][] = [
            [{ keyId, challenge: "short", attestation: "AAAA" }, '"challenge" must be a challenge'],
            [{ keyId, challenge: `${"A".repeat(42)}=`, attestation: "AAAA" }, '"challenge" must be a challenge'],
            [{ keyId, challenge: randomChallenge(), attestation: "AA A" }, '"attestation" must be base64'],
            [{ keyId, challenge: randomChallenge() }, '"attestation" must be base64'],
            [{ keyId, challenge: randomChallenge(), attestation: "AAAA", extra: 1 }, "unknown fields: extra"],
            [[keyId], "the body must be a JSON object"],
        ];
        for (const [body, error] of cases) {
            const answer = await send(post("/v1/attest", body), untouchable);
            expect(answer.status, error).toBe(400);
            expect(String(answer.body?.error)).toContain(error);
        }
        expect((await send(post("/v1/attest/challenge", "{"), untouchable)).status).toBe(400);
    });

    it("refuse a body that is not JSON, or over 32 KB by its length or while streaming", async () => {
        expect((await send(post("/v1/attest", "{}", { "Content-Type": "text/plain" }), untouchable)).status).toBe(415);
        const declared = post("/v1/attest", "{}", { "Content-Length": String(MAX_ATTEST_BODY + 1) });
        expect(await send(declared, untouchable)).toEqual({
            status: 413,
            body: { error: `the body is over ${MAX_ATTEST_BODY} bytes` },
        });
        const padded = new TextEncoder().encode(JSON.stringify({ keyId: "x", pad: "x".repeat(MAX_ATTEST_BODY) }));
        const stream = new ReadableStream<Uint8Array>({
            start(controller) {
                controller.enqueue(padded);
                controller.close();
            },
        });
        expect((await send(post("/v1/attest/challenge", stream), untouchable)).status).toBe(413);
    });

    it("have no rate limit for now: many requests from one address are all answered", async () => {
        const address = { "CF-Connecting-IP": "203.0.113.7" };
        for (let i = 0; i < 20; i++) {
            expect((await send(post("/v1/attest/challenge", { keyId: "bad" }, address), untouchable)).status).toBe(400);
        }
        const { keyId } = await newKey();
        for (let i = 0; i < 20; i++) {
            expect((await send(post("/v1/attest/challenge", { keyId }, address))).status).toBe(200);
        }
    });
});
