/// <reference types="vite/client" />
// Captured App Attest traffic from a real iPhone, checked with Apple's real root at its capture time. Each JSON file
// in test/fixtures/ is one capture from the Debug build's hidden action:
//
//   {
//     "environment": "development",                 // the AAGUID the device used
//     "appId": "Z23KXVBB26.dev.krutikpatel.widgie",
//     "capturedAt": "2026-11-24T10:00:00Z",          // inside the leaf certificate's validity
//     "keyId": "<44 characters: the key id generateKey() returned>",
//     "challenge": "<43 characters: the challenge /v1/attest/challenge answered>",
//     "attestation": "<standard base64 of the attestation object>",
//     "requests": [                                  // in the order they were signed
//       { "method": "POST", "path": "/v1/reply", "body": "<standard base64 of the exact body bytes>",
//         "assertion": "<the X-Widgie-Assertion header>" }
//     ]
//   }

import { runInDurableObject } from "cloudflare:test";
import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { APPLE_ROOT } from "../src/apple-root";
import { type Environment, verifyAssertion, verifyAttestation } from "../src/attestation";
import { fromBase64, sha256, toBase64 } from "../src/bytes";
import { handle } from "../src/index";
import { clientDataHash } from "./helpers/appattest";

interface Fixture {
    environment: Environment;
    appId: string;
    capturedAt: string;
    keyId: string;
    challenge: string;
    attestation: string;
    requests: { method: string; path: string; body: string; assertion: string }[];
}

const fixtures = Object.entries(import.meta.glob<Fixture>("./fixtures/*.json", { eager: true, import: "default" }));

const bytes = (base64: string) => {
    const decoded = fromBase64(base64);
    if (!decoded) throw new Error("the fixture holds bad base64");
    return decoded;
};

if (fixtures.length === 0) it.skip("checks each capture in test/fixtures (none yet)", () => {});

for (const [file, fixture] of fixtures) {
    describe(file, () => {
        const context = {
            root: APPLE_ROOT,
            now: new Date(fixture.capturedAt),
            appId: fixture.appId,
            environment: fixture.environment,
        };
        const keyId = bytes(fixture.keyId);
        const attestation = bytes(fixture.attestation);

        it("is for this app", () => {
            expect(fixture.appId).toBe(env.APP_ID);
        });

        it("passes the verifier at its capture time, and fails once the chain has expired", async () => {
            const result = await verifyAttestation(keyId, await sha256(fixture.challenge), attestation, context);
            if (!result.ok) throw new Error(`failed ${result.failed}`);
            expect(toBase64(await sha256(result.publicKey))).toBe(fixture.keyId);
            const later = { ...context, now: new Date(context.now.getTime() + 400 * 24 * 60 * 60 * 1000) };
            expect(await verifyAttestation(keyId, await sha256(fixture.challenge), attestation, later)).toEqual({
                ok: false,
                failed: "chain",
            });
            const other = fixture.environment === "development" ? "production" : "development";
            expect(
                await verifyAttestation(keyId, await sha256(fixture.challenge), attestation, {
                    ...context,
                    environment: other,
                }),
            ).toEqual({ ok: false, failed: "environment" });
        });

        it("signs its requests as the protocol says, with rising counters", async () => {
            const result = await verifyAttestation(keyId, await sha256(fixture.challenge), attestation, context);
            if (!result.ok) throw new Error(`failed ${result.failed}`);
            let last = 0;
            for (const request of fixture.requests) {
                const counter = await verifyAssertion({
                    publicKey: result.publicKey,
                    appId: fixture.appId,
                    clientDataHash: await clientDataHash(bytes(request.body), request),
                    assertion: bytes(request.assertion),
                });
                expect(counter).not.toBeNull();
                expect(counter).toBeGreaterThan(last);
                last = counter ?? last;
            }
        });

        it("attests and builds through the Worker, and a replayed request is refused", async () => {
            const fixtureEnv = { ...env, ATTEST_ENV: fixture.environment };
            const deps = {
                fetch: vi.fn<typeof fetch>(
                    async () =>
                        new Response(JSON.stringify({ model: "m", choices: [{ message: { content: "ok" } }] }), {
                            status: 200,
                        }),
                ),
                attestRoot: APPLE_ROOT,
                now: () => context.now,
            };
            const key = env.ATTESTED_KEY.getByName(fixture.keyId);
            // The challenge the dev Worker issued, placed in this object as if this Worker had issued it.
            await key.issueChallenge();
            await runInDurableObject(key, (_, state) => {
                state.storage.sql.exec("UPDATE attested_key SET challenge = ?", fixture.challenge);
            });
            const attested = await handle(
                new Request("https://widgie.test/v1/attest", {
                    method: "POST",
                    headers: { "Content-Type": "application/json", "CF-Connecting-IP": `fixture-${file}` },
                    body: JSON.stringify({
                        keyId: fixture.keyId,
                        challenge: fixture.challenge,
                        attestation: fixture.attestation,
                    }),
                }),
                fixtureEnv,
                deps,
            );
            expect(attested.status).toBe(204);

            const send = (request: Fixture["requests"][number]) =>
                handle(
                    new Request(`https://widgie.test${request.path}`, {
                        method: request.method,
                        headers: {
                            "Content-Type": "application/json",
                            "X-Widgie-Key": fixture.keyId,
                            "X-Widgie-Assertion": request.assertion,
                        },
                        body: bytes(request.body),
                    }),
                    fixtureEnv,
                    deps,
                );
            for (const request of fixture.requests) {
                // The quota is 2 in tests; a capture may hold more requests than that.
                await runInDurableObject(key, (_, state) => {
                    state.storage.sql.exec("UPDATE attested_key SET quota_count = 0");
                });
                expect((await send(request)).status).toBe(200);
            }
            const first = fixture.requests[0];
            if (first) expect(await (await send(first)).json()).toMatchObject({ code: "bad-assertion" });
        });
    });
}
