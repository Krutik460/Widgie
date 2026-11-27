import { beforeAll, describe, expect, it } from "vitest";
import { APPLE_ROOT } from "../src/apple-root";
import {
    type AttestationCheck,
    type AttestationContext,
    aaguid,
    environmentOf,
    LEAF_CLOCK_SKEW_MS,
    verifyAssertion,
    verifyAttestation,
} from "../src/attestation";
import { concat, sha256, toHex } from "../src/bytes";
import { CborError, decodeCbor } from "../src/cbor";
import { DerError, parseCertificate, rawSignature } from "../src/der";
import {
    APP_ID,
    type AttestationOptions,
    attestation,
    type Chain,
    certificate,
    chain,
    clientDataHash,
    DAY,
    derSignature,
    party,
    Signer,
    seq,
    tlv,
} from "./helpers/appattest";

const NOW = new Date("2026-11-23T12:00:00Z");
let trusted: Chain;

beforeAll(async () => {
    trusted = await chain(NOW);
});

function context(overrides: Partial<AttestationContext> = {}): AttestationContext {
    return { root: trusted.rootDer, now: NOW, appId: APP_ID, environment: "production", ...overrides };
}

async function verify(options: Partial<AttestationOptions> = {}, overrides: Partial<AttestationContext> = {}) {
    const made = await attestation({ now: NOW, chain: trusted, ...options });
    return verifyAttestation(made.keyIdBytes, made.clientDataHash, made.attestation, context(overrides));
}

async function failed(check: AttestationCheck, options: Partial<AttestationOptions>) {
    expect(await verify(options)).toEqual({ ok: false, failed: check });
}

describe("the pinned root", () => {
    it("is Apple's App Attest root, by its SHA-256 fingerprint", async () => {
        expect(toHex(await sha256(APPLE_ROOT))).toBe(
            "1cb9823ba28ba6ad2d33a006941de2ae4f513ef1d4e831b9f7e0fa7b6242c932",
        );
        const root = parseCertificate(APPLE_ROOT);
        expect(root.curve).toBe("P-384");
        expect(root.notAfter.toISOString()).toBe("2045-03-15T00:00:00.000Z");
    });
});

describe("verifyAttestation", () => {
    it("passes a well-formed attestation and answers the leaf's public key", async () => {
        const made = await attestation({ now: NOW, chain: trusted });
        const result = await verifyAttestation(made.keyIdBytes, made.clientDataHash, made.attestation, context());
        expect(result).toEqual({ ok: true, publicKey: made.publicKey });
    });

    it("passes the development AAGUID on development and refuses it on production", async () => {
        expect(await verify({ environment: "development" }, { environment: "development" })).toMatchObject({
            ok: true,
        });
        expect(await verify({ environment: "development" })).toEqual({ ok: false, failed: "environment" });
        expect(await verify({}, { environment: "development" })).toEqual({ ok: false, failed: "environment" });
    });

    it("names the AAGUIDs as Apple does", () => {
        expect(new TextDecoder().decode(aaguid("development"))).toBe("appattestdevelop");
        expect([...aaguid("production")]).toEqual([...new TextEncoder().encode("appattest"), 0, 0, 0, 0, 0, 0, 0]);
        expect(() => environmentOf("staging")).toThrow("ATTEST_ENV");
    });

    describe("1. the format", () => {
        it("refuses another fmt", () => failed("format", { fmt: "packed" }));

        it("refuses one certificate or three", async () => {
            await failed("format", { certificates: (leaf) => [leaf] });
            await failed("format", { certificates: (leaf, intermediate) => [leaf, intermediate, intermediate] });
        });

        it("refuses bytes that are not a CBOR map, and authData too short for its credential id", async () => {
            const made = await attestation({ now: NOW, chain: trusted });
            for (const bytes of [new Uint8Array([0x80]), new Uint8Array([0xff]), made.attestation.subarray(0, 50)]) {
                expect(await verifyAttestation(made.keyIdBytes, made.clientDataHash, bytes, context())).toEqual({
                    ok: false,
                    failed: "format",
                });
            }
            await failed("format", { authData: (authData) => authData.subarray(0, 60) });
        });
    });

    describe("2. the chain", () => {
        it("refuses a chain that does not lead to the pinned root", async () => {
            expect(await verify({}, { root: APPLE_ROOT })).toEqual({ ok: false, failed: "chain" });
            const other = await chain(NOW);
            await failed("chain", { intermediateDer: other.intermediateDer });
        });

        it("refuses a leaf the intermediate did not sign", async () => {
            const stranger = await party("P-384", "stranger");
            await failed("chain", { leafSigner: stranger.keys.privateKey });
        });

        it("refuses an expired leaf, a leaf not yet valid, and an expired intermediate", async () => {
            await failed("chain", {
                leafValidity: { notBefore: new Date(NOW.getTime() - 3 * DAY), notAfter: new Date(NOW.getTime() - 1) },
            });
            await failed("chain", {
                leafValidity: {
                    notBefore: new Date(NOW.getTime() + LEAF_CLOCK_SKEW_MS + 1000),
                    notAfter: new Date(NOW.getTime() + DAY),
                },
            });
            const expired = await certificate({
                subject: trusted.intermediate,
                issuer: trusted.root,
                notBefore: new Date(NOW.getTime() - 10 * DAY),
                notAfter: new Date(NOW.getTime() - DAY),
                authority: true,
            });
            await failed("chain", { intermediateDer: expired });
        });

        it("allows a leaf issued up to five minutes ahead of the Worker's clock, and only the leaf", async () => {
            expect(LEAF_CLOCK_SKEW_MS).toBe(5 * 60 * 1000);
            const ahead = (ms: number) => ({
                notBefore: new Date(NOW.getTime() + ms),
                notAfter: new Date(NOW.getTime() + DAY),
            });
            expect(await verify({ leafValidity: ahead(LEAF_CLOCK_SKEW_MS - 1000) })).toMatchObject({ ok: true });
            await failed("chain", { leafValidity: ahead(LEAF_CLOCK_SKEW_MS + 1000) });
            const early = await certificate({
                subject: trusted.intermediate,
                issuer: trusted.root,
                ...ahead(60 * 1000),
                authority: true,
            });
            await failed("chain", { intermediateDer: early });
        });

        it("refuses a root outside its validity, though it signed the intermediate", async () => {
            const root = (notBefore: Date, notAfter: Date) =>
                certificate({ subject: trusted.root, issuer: trusted.root, notBefore, notAfter, authority: true });
            const valid = await root(new Date(NOW.getTime() - 10 * DAY), new Date(NOW.getTime() + 10 * DAY));
            expect(await verify({}, { root: valid })).toMatchObject({ ok: true });
            const expired = await root(new Date(NOW.getTime() - 10 * DAY), new Date(NOW.getTime() - DAY));
            expect(await verify({}, { root: expired })).toEqual({ ok: false, failed: "chain" });
            const early = await root(new Date(NOW.getTime() + DAY), new Date(NOW.getTime() + 10 * DAY));
            expect(await verify({}, { root: early })).toEqual({ ok: false, failed: "chain" });
        });

        it("refuses a leaf naming another issuer, though the intermediate's key signed it", async () => {
            expect(await verify({ leafIssuer: { ...trusted.intermediate } })).toMatchObject({ ok: true });
            await failed("chain", { leafIssuer: { ...trusted.intermediate, commonName: "Another CA" } });
        });

        it("refuses an intermediate naming another issuer, though the root's key signed it", async () => {
            const intermediate = (commonName: string) =>
                certificate({
                    subject: trusted.intermediate,
                    issuer: { ...trusted.root, commonName },
                    notBefore: new Date(NOW.getTime() - DAY),
                    notAfter: new Date(NOW.getTime() + DAY),
                    authority: true,
                });
            const same = await intermediate(trusted.root.commonName);
            expect(await verify({ intermediateDer: same })).toMatchObject({ ok: true });
            await failed("chain", { intermediateDer: await intermediate("Another Root") });
        });

        it("refuses a certificate whose signed algorithm differs from its outer one", async () => {
            const options = {
                subject: trusted.intermediate,
                issuer: trusted.root,
                notBefore: new Date(NOW.getTime() - DAY),
                notAfter: new Date(NOW.getTime() + DAY),
                authority: true,
            };
            expect(await verify({ intermediateDer: await certificate(options) })).toMatchObject({ ok: true });
            const mixed = await certificate({ ...options, tbsHash: "SHA-256" });
            expect(() => parseCertificate(mixed)).toThrow(new DerError("signature algorithms differ"));
            await failed("chain", { intermediateDer: mixed });
        });

        it("refuses a valid chain checked at a time after it expired", async () => {
            expect(await verify({}, { now: new Date(NOW.getTime() + 3 * DAY) })).toEqual({
                ok: false,
                failed: "chain",
            });
        });

        it("refuses an intermediate that is not a CA", async () => {
            const notCa = await certificate({
                subject: trusted.intermediate,
                issuer: trusted.root,
                notBefore: new Date(NOW.getTime() - DAY),
                notAfter: new Date(NOW.getTime() + DAY),
            });
            await failed("chain", { intermediateDer: notCa });
        });
    });

    describe("3. the nonce", () => {
        it("refuses a nonce over another challenge", () =>
            failed("nonce", { nonce: async (authData) => sha256(authData, new Uint8Array(32)) }));

        it("refuses a leaf without the nonce extension", () => failed("nonce", { nonce: async () => null }));

        it("refuses a nonce extension under another tag, or with a second element", async () => {
            const tagged = (tag: number, nonce: Uint8Array) => tlv(tag, tlv(0x04, nonce));
            expect(await verify({ nonceValue: (nonce) => seq(tagged(0xa1, nonce)) })).toMatchObject({ ok: true });
            await failed("nonce", { nonceValue: (nonce) => seq(tagged(0xa2, nonce)) });
            await failed("nonce", { nonceValue: (nonce) => seq(tagged(0xa1, nonce), tagged(0xa1, nonce)) });
        });
    });

    describe("4. the key id", () => {
        it("refuses a leaf key on another curve, even when the key id is its hash", async () => {
            await failed("key-id", { leaf: await party("P-384", "leaf") });
        });

        it("refuses a key id that is not the leaf key's hash", async () => {
            const made = await attestation({ now: NOW, chain: trusted });
            const other = crypto.getRandomValues(new Uint8Array(32));
            expect(await verifyAttestation(other, made.clientDataHash, made.attestation, context())).toEqual({
                ok: false,
                failed: "key-id",
            });
        });
    });

    describe("5. the rpIdHash", () => {
        it("refuses another app's id", () => failed("rp-id", { appId: "Z23KXVBB26.dev.krutikpatel.other" }));
    });

    describe("6. the counter", () => {
        it("refuses a counter other than 0", () => failed("counter", { counter: 1 }));
    });

    describe("7. the environment", () => {
        it("refuses an AAGUID that is neither environment's", () =>
            failed("environment", { aaguid: new Uint8Array(16) }));
    });

    describe("8. the credential id", () => {
        it("refuses a credential id that is not the key id", async () => {
            await failed("credential-id", { credentialId: (keyId) => keyId.map((byte) => byte ^ 1) });
            await failed("credential-id", { credentialId: (keyId) => keyId.subarray(0, 31) });
        });
    });
});

describe("verifyAssertion", () => {
    it("passes a signed assertion and answers its counter", async () => {
        const signer = await Signer.create();
        const hash = await clientDataHash("{}");
        const assertion = await signer.assertion(hash, { counter: 7 });
        expect(
            await verifyAssertion({ publicKey: signer.publicKey, appId: APP_ID, clientDataHash: hash, assertion }),
        ).toBe(7);
    });

    it("refuses another body, another path, another app id, or another key", async () => {
        const signer = await Signer.create();
        const hash = await clientDataHash("{}");
        const check = (assertion: Uint8Array, publicKey = signer.publicKey) =>
            verifyAssertion({ publicKey, appId: APP_ID, clientDataHash: hash, assertion });
        expect(await check(await signer.assertion(await clientDataHash("{ }")))).toBeNull();
        expect(await check(await signer.assertion(await clientDataHash("{}", { path: "/v1/attest" })))).toBeNull();
        expect(await check(await signer.assertion(hash, { appId: "other" }))).toBeNull();
        expect(await check(await signer.assertion(hash), (await Signer.create()).publicKey)).toBeNull();
        expect(await check(new Uint8Array([0xa0]))).toBeNull();
    });

    it("refuses authenticator data shorter than 37 bytes, though signed", async () => {
        const signer = await Signer.create();
        const hash = await clientDataHash("{}");
        const verifyWith = (data: (bytes: Uint8Array) => Uint8Array) =>
            signer
                .assertion(hash, { authenticatorData: data })
                .then((assertion) =>
                    verifyAssertion({ publicKey: signer.publicKey, appId: APP_ID, clientDataHash: hash, assertion }),
                );
        expect(await verifyWith((bytes) => concat(bytes, new Uint8Array([9])))).not.toBeNull();
        expect(await verifyWith((bytes) => bytes.subarray(0, 36))).toBeNull();
    });

    it("refuses a client data hash that is not 32 bytes, though signed over it", async () => {
        const signer = await Signer.create();
        const hash = await clientDataHash("{}");
        for (const other of [concat(hash, new Uint8Array([0])), hash.subarray(0, 31)]) {
            const assertion = await signer.assertion(other);
            expect(
                await verifyAssertion({ publicKey: signer.publicKey, appId: APP_ID, clientDataHash: other, assertion }),
            ).toBeNull();
        }
    });
});

describe("the decoders", () => {
    it("CBOR refuses trailing bytes, indefinite lengths, tags, and duplicate keys", () => {
        expect(decodeCbor(new Uint8Array([0xa1, 0x61, 0x61, 0x20]))).toEqual(new Map([["a", -1]]));
        for (const bytes of [[0x00, 0x00], [0x5f], [0xc0, 0x00], [0xa2, 0x00, 0x00, 0x00, 0x01], [0x62, 0x61]]) {
            expect(() => decodeCbor(new Uint8Array(bytes)), JSON.stringify(bytes)).toThrow(CborError);
        }
        let deep = new Uint8Array([0x80]);
        for (let i = 0; i < 20; i++) deep = new Uint8Array([0x81, ...deep]);
        expect(() => decodeCbor(deep)).toThrow("nested too deep");
    });

    it("converts DER ECDSA signatures to fixed-width r ‖ s and back", () => {
        const raw = new Uint8Array(64).map((_, i) => (i === 0 || i === 32 ? 0x80 : i));
        expect(rawSignature(derSignature(raw), 32)).toEqual(raw);
        const small = new Uint8Array(64);
        small[31] = 1;
        small[63] = 2;
        expect(rawSignature(derSignature(small), 32)).toEqual(small);
        expect(rawSignature(derSignature(new Uint8Array(96).fill(0x7f)), 32)).toBeNull();
        expect(rawSignature(new Uint8Array([0x30, 0x00]), 32)).toBeNull();
    });
});
