import { runDurableObjectAlarm, runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it } from "vitest";
import { type AssertionCheck, verifyAssertion } from "../src/attestation";
import { type AttestedKey, CHALLENGE_LIFE_MS } from "../src/attested-key";
import { clientDataHash, Signer } from "./helpers/appattest";

const stubFor = (keyId: string) => env.ATTESTED_KEY.getByName(keyId);
const randomKeyId = () => btoa(String.fromCharCode(...crypto.getRandomValues(new Uint8Array(32))));

/// Everything the object holds: its tables (SQLite's own and Cloudflare's internal ones aside), its row, and alarm.
async function contents(keyId: string) {
    return runInDurableObject<AttestedKey, unknown>(stubFor(keyId), async (_, state) => {
        const tables = state.storage.sql
            .exec<{ name: string }>("SELECT name FROM sqlite_master WHERE type = 'table'")
            .toArray()
            .map((row) => row.name)
            .filter((name) => !name.startsWith("_cf_") && !name.startsWith("sqlite_"));
        const rows = tables.includes("attested_key")
            ? state.storage.sql.exec("SELECT * FROM attested_key").toArray()
            : [];
        return { tables, rows, alarm: await state.storage.getAlarm() };
    });
}

const EMPTY = { tables: [], rows: [], alarm: null };

async function advance(signer: Signer, options: { counter?: number; body?: string } = {}) {
    const hash = await clientDataHash(options.body ?? "{}");
    return stubFor(signer.keyId).verifyAndAdvance(hash, await signer.assertion(hash, options));
}

describe("an object for a key it does not hold", () => {
    it("answers unknown-key and leaves no storage behind", async () => {
        const keyId = randomKeyId();
        const signer = await Signer.create();
        const hash = await clientDataHash("{}");
        expect(await stubFor(keyId).verifyAndAdvance(hash, await signer.assertion(hash))).toBe("unknown-key");
        expect(await stubFor(keyId).takeChallenge("x".repeat(43))).toBe("bad-attestation");
        expect(await contents(keyId)).toEqual(EMPTY);
    });
});

describe("the challenge", () => {
    it("is one use", async () => {
        const keyId = randomKeyId();
        const issued = await stubFor(keyId).issueChallenge();
        if (!("challenge" in issued)) throw new Error("expected a challenge");
        expect(issued.challenge).toMatch(/^[A-Za-z0-9_-]{43}$/);
        expect(await stubFor(keyId).takeChallenge(issued.challenge)).toBeNull();
        expect(await stubFor(keyId).takeChallenge(issued.challenge)).toBe("bad-attestation");
    });

    it("is refused when it is not the pending one, and that refusal writes nothing", async () => {
        const keyId = randomKeyId();
        await stubFor(keyId).issueChallenge();
        const before = await contents(keyId);
        expect(await stubFor(keyId).takeChallenge("A".repeat(43))).toBe("bad-attestation");
        expect(await contents(keyId)).toEqual(before);
    });

    it("expires after five minutes, and its alarm deletes the unattested object", async () => {
        const keyId = randomKeyId();
        const started = Date.now();
        const issued = await stubFor(keyId).issueChallenge();
        if (!("challenge" in issued)) throw new Error("expected a challenge");
        const { alarm } = (await contents(keyId)) as { alarm: number };
        expect(alarm).toBeGreaterThanOrEqual(started + CHALLENGE_LIFE_MS);
        expect(alarm).toBeLessThanOrEqual(Date.now() + CHALLENGE_LIFE_MS);

        await runInDurableObject(stubFor(keyId), (_, state) => {
            state.storage.sql.exec("UPDATE attested_key SET challenge_expires = ?", Date.now() - 1);
        });
        expect(await stubFor(keyId).takeChallenge(issued.challenge)).toBe("bad-attestation");
        expect(await runDurableObjectAlarm(stubFor(keyId))).toBe(true);
        expect(await contents(keyId)).toEqual(EMPTY);
    });

    it("is not issued to an attested key", async () => {
        const signer = await Signer.attested();
        const before = await contents(signer.keyId);
        expect(await stubFor(signer.keyId).issueChallenge()).toEqual({ code: "attested" });
        expect(await stubFor(signer.keyId).takeChallenge("A".repeat(43))).toBe("attested");
        expect(await contents(signer.keyId)).toEqual(before);
    });
});

describe("storing a key", () => {
    it("stores it with counter 0 and cancels the alarm", async () => {
        const signer = await Signer.create();
        await stubFor(signer.keyId).issueChallenge();
        expect(await stubFor(signer.keyId).storeKey(signer.publicKey)).toBeNull();
        const { rows, alarm } = (await contents(signer.keyId)) as { rows: Record<string, unknown>[]; alarm: unknown };
        expect(rows).toHaveLength(1);
        expect(rows[0]).toMatchObject({ counter: 0, challenge: null });
        expect(new Uint8Array(rows[0]?.public_key as ArrayBuffer)).toEqual(signer.publicKey);
        expect(alarm).toBeNull();
    });

    it("refuses a second key: an attested key is 409", async () => {
        const signer = await Signer.attested();
        expect(await stubFor(signer.keyId).storeKey((await Signer.create()).publicKey)).toBe("attested");
    });

    it("still works after the alarm cleared the object mid-attestation", async () => {
        const signer = await Signer.create();
        const issued = await stubFor(signer.keyId).issueChallenge();
        if (!("challenge" in issued)) throw new Error("expected a challenge");
        expect(await stubFor(signer.keyId).takeChallenge(issued.challenge)).toBeNull();
        expect(await runDurableObjectAlarm(stubFor(signer.keyId))).toBe(true);
        expect(await contents(signer.keyId)).toEqual(EMPTY);
        expect(await stubFor(signer.keyId).storeKey(signer.publicKey)).toBeNull();
        expect(await advance(signer)).toBeNull();
    });

    it("survives an alarm that fires after attestation, with its counter", async () => {
        const signer = await Signer.attested();
        expect(await advance(signer, { counter: 5 })).toBeNull();
        expect(await runDurableObjectAlarm(stubFor(signer.keyId))).toBe(false);
        await runInDurableObject<AttestedKey, void>(stubFor(signer.keyId), (instance) => instance.alarm());
        const { rows } = (await contents(signer.keyId)) as { rows: Record<string, unknown>[] };
        expect(rows[0]).toMatchObject({ counter: 5 });
        expect(await advance(signer, { counter: 5 })).toBe("bad-assertion");
    });
});

describe("verifyAndAdvance", () => {
    it("passes a signed request and advances the counter", async () => {
        const signer = await Signer.attested();
        expect(await advance(signer, { counter: 3 })).toBeNull();
        const { rows } = (await contents(signer.keyId)) as { rows: Record<string, unknown>[] };
        expect(rows[0]).toMatchObject({ counter: 3 });
    });

    it("refuses a replayed or older counter", async () => {
        const signer = await Signer.attested();
        expect(await advance(signer, { counter: 2 })).toBeNull();
        expect(await advance(signer, { counter: 2 })).toBe("bad-assertion");
        expect(await advance(signer, { counter: 1 })).toBe("bad-assertion");
    });

    it("refuses an assertion for another body or path", async () => {
        const signer = await Signer.attested();
        const hash = await clientDataHash("{}");
        const stub = stubFor(signer.keyId);
        expect(await stub.verifyAndAdvance(hash, await signer.assertion(await clientDataHash("{ }")))).toBe(
            "bad-assertion",
        );
        const otherPath = await signer.assertion(await clientDataHash("{}", { path: "/v1/attest" }));
        expect(await stub.verifyAndAdvance(hash, otherPath)).toBe("bad-assertion");
        expect(await stub.verifyAndAdvance(hash, new Uint8Array([1, 2, 3]))).toBe("bad-assertion");
    });

    it("lets exactly one of two concurrent requests with the same counter through", async () => {
        const signer = await Signer.attested();
        const hash = await clientDataHash("{}");
        const [a, b] = [await signer.assertion(hash, { counter: 1 }), await signer.assertion(hash, { counter: 1 })];
        // Both requests finish their signature check before either reads the counter, which is the order that would
        // let both through if the counter were read before the check's await.
        let waiting = 0;
        let release = () => {};
        const bothChecked = new Promise<void>((resolve) => {
            release = resolve;
        });
        await runInDurableObject(stubFor(signer.keyId), (instance) => {
            (instance as unknown as { verify: (check: AssertionCheck) => Promise<number | null> }).verify = async (
                check,
            ) => {
                const counter = await verifyAssertion(check);
                if (++waiting === 2) release();
                await bothChecked;
                return counter;
            };
        });
        const results = await Promise.all([
            stubFor(signer.keyId).verifyAndAdvance(hash, a),
            stubFor(signer.keyId).verifyAndAdvance(hash, b),
        ]);
        expect(waiting).toBe(2);
        expect(results.sort()).toEqual(["bad-assertion", null]);
    });

    it("has no daily limit: many calls in a row all pass", async () => {
        const signer = await Signer.attested();
        for (let i = 0; i < 50; i++) expect(await advance(signer)).toBeNull();
    });

    it("works in an object made while the daily quota existed, which still has its columns", async () => {
        const signer = await Signer.create();
        await runInDurableObject(stubFor(signer.keyId), (_, state) => {
            state.storage.sql.exec(
                `CREATE TABLE attested_key (id INTEGER PRIMARY KEY CHECK (id = 1), public_key BLOB,
                 counter INTEGER NOT NULL DEFAULT 0, quota_day TEXT, quota_count INTEGER NOT NULL DEFAULT 0,
                 challenge TEXT, challenge_expires INTEGER)`,
            );
        });
        const issued = await stubFor(signer.keyId).issueChallenge();
        if (!("challenge" in issued)) throw new Error("expected a challenge");
        expect(await stubFor(signer.keyId).takeChallenge(issued.challenge)).toBeNull();
        expect(await stubFor(signer.keyId).storeKey(signer.publicKey)).toBeNull();
        expect(await advance(signer, { counter: 3 })).toBeNull();
        expect(await advance(signer, { counter: 3 })).toBe("bad-assertion");
        const { rows } = (await contents(signer.keyId)) as { rows: Record<string, unknown>[] };
        expect(rows[0]).toMatchObject({ counter: 3, quota_count: 0, challenge: null });
    });

    it("changes nothing when it refuses", async () => {
        const signer = await Signer.attested();
        expect(await advance(signer, { counter: 4 })).toBeNull();
        expect(await advance(signer, { counter: 9 })).toBeNull();
        const before = await contents(signer.keyId);
        expect(await advance(signer, { counter: 4 })).toBe("bad-assertion");
        expect(await advance(signer, { counter: 9 })).toBe("bad-assertion");
        const hash = await clientDataHash("{}");
        expect(
            await stubFor(signer.keyId).verifyAndAdvance(hash, await signer.assertion(await clientDataHash("x"))),
        ).toBe("bad-assertion");
        expect(await contents(signer.keyId)).toEqual(before);
    });
});
