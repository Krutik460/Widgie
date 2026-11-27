import { runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { toBase64 } from "../src/bytes";
import type { Env } from "../src/index";
import { changes, NOW, newAccount, send } from "./helpers/accounts";
import { Signer } from "./helpers/appattest";

const TOKEN = /^([0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12})\.([A-Za-z0-9_-]{43})$/;

/// POST /v1/account signed by `signer` over an empty body, as the app sends it.
async function signed(signer: Signer, options: { path?: string; counter?: number; body?: string } = {}) {
    const headers = await signer.headers("", { path: options.path ?? "/v1/account", counter: options.counter });
    return new Request("https://widgie.test/v1/account", { method: "POST", headers, body: options.body });
}

function dev(secret: string | null, body?: string) {
    return new Request("https://widgie.test/v1/account", {
        method: "POST",
        headers: secret === null ? {} : { "X-Widgie-Dev-Secret": secret },
        body,
    });
}

const devEnv = { ...env, ENVIRONMENT: "dev", DEV_REGISTRATION_SECRET: "dev-secret" } as Env;

async function accountCount(): Promise<number> {
    const row = await env.DB.prepare("SELECT count(*) AS n FROM accounts").first<{ n: number }>();
    return row?.n ?? 0;
}

async function accountOf(attestKey: string) {
    return env.DB.prepare("SELECT id, token_hash, replica, pulled_at FROM accounts WHERE attest_key = ?")
        .bind(attestKey)
        .first<{ id: string; token_hash: string; replica: string; pulled_at: number }>();
}

describe("registering with App Attest", () => {
    it("answers a token for a new account of the key", async () => {
        const signer = await Signer.attested();
        const { status, body } = await send(await signed(signer));
        expect(status).toBe(200);
        expect(Object.keys(body ?? {})).toEqual(["token"]);
        const token = String(body?.token);
        const [, id] = TOKEN.exec(token) ?? [];
        const row = await accountOf(signer.keyId);
        expect(row?.id).toBe(id);
        expect(row?.pulled_at).toBe(NOW);
        // The secret itself is never stored.
        expect(row?.token_hash).toMatch(/^[0-9a-f]{64}$/);
        expect(row?.token_hash).not.toContain(token.slice(37));
        expect((await send(changes(token))).status).toBe(200);
    });

    it("returns the same account with a new token when the key registers again, and the old token stops working", async () => {
        const signer = await Signer.attested();
        const first = String((await send(await signed(signer))).body?.token);
        const before = await accountOf(signer.keyId);
        const second = String((await send(await signed(signer))).body?.token);
        expect(second).not.toBe(first);
        expect(second.slice(0, 36)).toBe(first.slice(0, 36));
        expect((await accountOf(signer.keyId))?.replica).toBe(before?.replica);
        expect((await send(changes(first))).body).toMatchObject({ code: "bad-token" });
        expect((await send(changes(second))).status).toBe(200);
    });

    it("advances the key's one counter, the same one /v1/reply checks", async () => {
        const signer = await Signer.attested();
        for (let i = 0; i < 3; i++) expect((await send(await signed(signer))).status).toBe(200);
        const row = await runInDurableObject(env.ATTESTED_KEY.getByName(signer.keyId), (_, state) =>
            state.storage.sql.exec("SELECT counter FROM attested_key").one(),
        );
        expect(row).toEqual({ counter: 3 });
        expect((await send(await signed(signer, { counter: 3 }))).body).toMatchObject({ code: "bad-assertion" });
    });

    it("refuses a key it has not attested, an unsigned request, and a replayed or misdirected assertion", async () => {
        const before = await accountCount();
        expect((await send(await signed(await Signer.create()))).body).toMatchObject({ code: "unknown-key" });
        const unsigned = new Request("https://widgie.test/v1/account", { method: "POST" });
        expect((await send(unsigned)).body).toMatchObject({ code: "bad-assertion" });

        const signer = await Signer.attested();
        const request = await signed(signer);
        const replay = new Request(request.url, { method: "POST", headers: request.headers });
        expect((await send(request)).status).toBe(200);
        expect((await send(replay)).body).toMatchObject({ code: "bad-assertion" });
        // An assertion over /v1/reply's client data never registers.
        expect((await send(await signed(signer, { path: "/v1/reply" }))).body).toMatchObject({
            code: "bad-assertion",
        });
        expect(await accountCount()).toBe(before + 1);
    });

    it("refuses a body, since the assertion covers an empty one", async () => {
        const signer = await Signer.attested();
        const { status } = await send(await signed(signer, { body: "{}" }));
        expect(status).toBe(413);
        expect(await accountOf(signer.keyId)).toBeNull();
    });
});

describe("registering with the dev secret", () => {
    it("is refused by production even when the secret is right", async () => {
        // The test configuration is production's, with DEV_REGISTRATION_SECRET set to prove it does not matter.
        expect(env.ENVIRONMENT).toBe("production");
        expect(env.DEV_REGISTRATION_SECRET).toBe("dev-secret");
        const before = await accountCount();
        const { status, body } = await send(dev("dev-secret"));
        expect(status).toBe(401);
        expect(body).toMatchObject({ code: "bad-dev-secret" });
        expect(await accountCount()).toBe(before);
    });

    it("registers a new account on dev with the right secret", async () => {
        const first = await send(dev("dev-secret"), { environment: devEnv });
        const second = await send(dev("dev-secret"), { environment: devEnv });
        expect(first.status).toBe(200);
        expect(String(first.body?.token)).toMatch(TOKEN);
        expect(String(second.body?.token).slice(0, 36)).not.toBe(String(first.body?.token).slice(0, 36));
        expect((await send(changes(String(first.body?.token)))).status).toBe(200);
    });

    it("is refused on dev with a wrong secret, an empty one, or none configured", async () => {
        const before = await accountCount();
        expect((await send(dev("dev-secreT"), { environment: devEnv })).body).toMatchObject({ code: "bad-dev-secret" });
        expect((await send(dev(""), { environment: devEnv })).body).toMatchObject({ code: "bad-dev-secret" });
        const unset = { ...devEnv, DEV_REGISTRATION_SECRET: undefined } as Env;
        expect((await send(dev(""), { environment: unset })).body).toMatchObject({ code: "bad-dev-secret" });
        expect((await send(dev("dev-secret", "{}"), { environment: devEnv })).status).toBe(413);
        expect(await accountCount()).toBe(before);
    });
});

describe("the token", () => {
    it("is refused when missing, malformed, wrong, or not the canonical spelling", async () => {
        const { id, token } = await newAccount();
        const secret = token.slice(37);
        const other = await newAccount();
        const flipped = `${secret.slice(0, 42)}${secret[42] === "A" ? "B" : "A"}`;
        const headers = [
            null,
            `Bearer ${id}`,
            `Bearer ${id}.`,
            `bearer ${token}`,
            `Bearer  ${token}`,
            `Bearer ${id.toUpperCase()}.${secret}`,
            `Bearer ${id}.${toBase64(new Uint8Array(32))}`,
            `Bearer ${id}.${flipped}`,
            `Bearer ${other.id}.${secret}`,
            `Bearer ${id}.${other.token.slice(37)}`,
        ];
        for (const header of headers) {
            const request = new Request("https://widgie.test/v1/changes?after=0", {
                headers: header === null ? {} : { Authorization: header },
            });
            const { status, body } = await send(request);
            expect(status, String(header)).toBe(401);
            expect(body).toEqual({ error: "the account token is not valid", code: "bad-token" });
        }
        expect((await send(changes(token))).status).toBe(200);
    });
});
