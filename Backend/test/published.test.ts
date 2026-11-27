// Real App Attest traffic from iPhones on iOS 14.2 to 14.4, published by the open-source devicecheck-appattest
// project under the Apache License 2.0 (test/published/LICENSE; source, licence, and changes are named at the top of
// test/published/devicecheck-appattest.json). They are another app's captures, so each runs with its own app id,
// environment, and client data hash, at its own capture time, against Apple's real root. They prove the verifier
// reads what Apple really sends; the Widgie captures in test/fixtures, read by fixtures.test.ts, stay the final gate.

import { describe, expect, it } from "vitest";
import { APPLE_ROOT } from "../src/apple-root";
import { type AttestationContext, type Environment, verifyAssertion, verifyAttestation } from "../src/attestation";
import { fromBase64, sha256, toBase64 } from "../src/bytes";
import { APP_ID } from "./helpers/appattest";
import published from "./published/devicecheck-appattest.json";

interface Capture {
    sample: string;
    appId: string;
    environment: Environment;
    capturedAt: string;
    keyId: string;
    clientDataHash: string;
    attestation: string;
    assertions: { capturedAt: string; clientDataHash: string; counter: number; assertion: string }[];
}

const captures = published.captures as Capture[];

const bytes = (base64: string) => {
    const decoded = fromBase64(base64);
    if (!decoded) throw new Error("the capture holds bad base64");
    return decoded;
};

const DAY = 24 * 60 * 60 * 1000;

describe("the published captures", () => {
    it("are all seven samples, with their source and licence", () => {
        expect(captures).toHaveLength(7);
        expect(published.source).toContain("github.com/veehaitch/devicecheck-appattest");
        expect(published.license).toContain("Apache License 2.0");
    });
});

for (const capture of captures) {
    describe(capture.sample, () => {
        const context: AttestationContext = {
            root: APPLE_ROOT,
            now: new Date(capture.capturedAt),
            appId: capture.appId,
            environment: capture.environment,
        };
        const keyId = bytes(capture.keyId);
        const clientDataHash = bytes(capture.clientDataHash);
        const attestation = bytes(capture.attestation);
        const verify = (overrides: Partial<AttestationContext> = {}) =>
            verifyAttestation(keyId, clientDataHash, attestation, { ...context, ...overrides });

        it("passes the verifier at its capture time and answers the key the key id names", async () => {
            const result = await verify();
            if (!result.ok) throw new Error(`failed ${result.failed}`);
            expect(toBase64(await sha256(result.publicKey))).toBe(capture.keyId);
        });

        it("fails for Widgie's app id, in the other environment, over other client data, and once expired", async () => {
            expect(await verify({ appId: APP_ID })).toEqual({ ok: false, failed: "rp-id" });
            const other = capture.environment === "development" ? "production" : "development";
            expect(await verify({ environment: other })).toEqual({ ok: false, failed: "environment" });
            expect(await verifyAttestation(keyId, new Uint8Array(32), attestation, context)).toEqual({
                ok: false,
                failed: "nonce",
            });
            const later = new Date(context.now.getTime() + 400 * DAY);
            expect(await verify({ now: later })).toEqual({ ok: false, failed: "chain" });
        });

        it("verifies its assertions with the nonce as WebCrypto's data, and refuses them changed", async () => {
            const result = await verify();
            if (!result.ok) throw new Error(`failed ${result.failed}`);
            expect(capture.assertions.length).toBeGreaterThan(0);
            for (const signed of capture.assertions) {
                const check = { publicKey: result.publicKey, appId: capture.appId, assertion: bytes(signed.assertion) };
                const hash = bytes(signed.clientDataHash);
                expect(await verifyAssertion({ ...check, clientDataHash: hash })).toBe(signed.counter);
                expect(await verifyAssertion({ ...check, clientDataHash: hash.map((b) => b ^ 1) })).toBeNull();
                expect(await verifyAssertion({ ...check, appId: APP_ID, clientDataHash: hash })).toBeNull();
            }
        });
    });
}
