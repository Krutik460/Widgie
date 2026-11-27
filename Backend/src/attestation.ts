// App Attest verification, as Apple's "Validating apps that connect to your server" lays it out. Pure functions: the
// time, the pinned root, the app id, and the environment are passed in, so tests can use a synthetic chain and a
// captured attestation can be checked at its capture time.

import { equal, sha256 } from "./bytes";
import { type CborValue, decodeCbor } from "./cbor";
import {
    type Certificate,
    isAuthority,
    OID,
    parseCertificate,
    rawSignature,
    readAll,
    readOne,
    signedBy,
    TAG,
} from "./der";

export type Environment = "development" | "production";

export interface AttestationContext {
    /// The DER of the pinned root: Apple's App Attest root in production, a synthetic one in tests.
    root: Uint8Array;
    now: Date;
    /// `<team id>.<bundle id>`, whose SHA-256 is the rpIdHash.
    appId: string;
    environment: Environment;
}

/// Apple's numbered checks, in order. `format` is check 1; the rest follow the plan's numbering.
export type AttestationCheck =
    | "format"
    | "chain"
    | "nonce"
    | "key-id"
    | "rp-id"
    | "counter"
    | "environment"
    | "credential-id";

/// How far ahead of this Worker's clock a leaf's notBefore may be. Apple issues the leaf the moment the phone
/// attests, so a Worker clock a little behind Apple's would otherwise refuse a fresh attestation.
export const LEAF_CLOCK_SKEW_MS = 5 * 60 * 1000;

export type AttestationResult = { ok: true; publicKey: Uint8Array } | { ok: false; failed: AttestationCheck };

/// The AAGUID in authData: `appattestdevelop`, or `appattest` and seven zero bytes.
export function aaguid(environment: Environment): Uint8Array {
    const text = environment === "development" ? "appattestdevelop" : "appattest";
    const out = new Uint8Array(16);
    out.set(new TextEncoder().encode(text));
    return out;
}

export function environmentOf(value: string): Environment {
    if (value === "development" || value === "production") return value;
    throw new Error(`ATTEST_ENV must be "development" or "production", not "${value}"`);
}

/// Checks an attestation object for `keyId` (the 32 bytes the key id encodes) made over `clientDataHash`, and
/// answers the key's X9.62 public point, or the first check that failed.
export async function verifyAttestation(
    keyId: Uint8Array,
    clientDataHash: Uint8Array,
    attestation: Uint8Array,
    context: AttestationContext,
): Promise<AttestationResult> {
    const fail = (failed: AttestationCheck): AttestationResult => ({ ok: false, failed });

    // 1. The format, with two certificates, and authData long enough to hold the attested credential data.
    const object = cborMap(attestation);
    const statement = object?.get("attStmt");
    const x5c = statement instanceof Map ? statement.get("x5c") : undefined;
    const authData = object?.get("authData");
    if (
        object?.get("fmt") !== "apple-appattest" ||
        !Array.isArray(x5c) ||
        x5c.length !== 2 ||
        !x5c.every((der) => der instanceof Uint8Array) ||
        !(authData instanceof Uint8Array)
    ) {
        return fail("format");
    }
    const credential = attestedCredential(authData);
    if (!credential) return fail("format");

    // 2. The chain: leaf, then intermediate, then the pinned root, each valid now (the leaf allowing for clock skew).
    const leaf = await chainedLeaf(x5c[0] as Uint8Array, x5c[1] as Uint8Array, context);
    if (!leaf) return fail("chain");

    // 3. The nonce extension holds SHA256(authData ‖ clientDataHash).
    const nonce = nonceExtension(leaf);
    if (!nonce || !equal(nonce, await sha256(authData, clientDataHash))) return fail("nonce");

    // 4. The key id is the SHA-256 of the leaf's public point.
    if (leaf.curve !== "P-256" || !equal(await sha256(leaf.point), keyId)) return fail("key-id");

    // 5. The rpIdHash is the SHA-256 of the app id.
    if (!equal(authData.subarray(0, 32), await sha256(context.appId))) return fail("rp-id");

    // 6. The counter is 0.
    if (counterOf(authData) !== 0) return fail("counter");

    // 7. The AAGUID names this Worker's environment.
    if (!equal(credential.aaguid, aaguid(context.environment))) return fail("environment");

    // 8. The credential id is the key id.
    if (!equal(credential.id, keyId)) return fail("credential-id");

    return { ok: true, publicKey: leaf.point.slice() };
}

export interface AssertionCheck {
    /// The key's X9.62 public point, as stored at attestation.
    publicKey: Uint8Array;
    appId: string;
    clientDataHash: Uint8Array;
    assertion: Uint8Array;
}

/// Checks an assertion's signature and rpIdHash, and answers its counter, or null. The caller compares the counter
/// with the stored one. The signature is ECDSA P-256 with SHA-256 over `nonce = SHA256(authenticatorData ‖
/// clientDataHash)` as the message, so WebCrypto gets the nonce as its data and hashes it once more.
export async function verifyAssertion(check: AssertionCheck): Promise<number | null> {
    const map = cborMap(check.assertion);
    const signature = map?.get("signature");
    const authenticatorData = map?.get("authenticatorData");
    if (
        !(signature instanceof Uint8Array) ||
        !(authenticatorData instanceof Uint8Array) ||
        authenticatorData.byteLength < 37 ||
        check.clientDataHash.byteLength !== 32
    ) {
        return null;
    }
    if (!equal(authenticatorData.subarray(0, 32), await sha256(check.appId))) return null;
    const raw = rawSignature(signature, 32);
    if (!raw) return null;
    let key: CryptoKey;
    try {
        key = await crypto.subtle.importKey("raw", check.publicKey, { name: "ECDSA", namedCurve: "P-256" }, false, [
            "verify",
        ]);
    } catch {
        return null;
    }
    const nonce = await sha256(authenticatorData, check.clientDataHash);
    const valid = await crypto.subtle.verify({ name: "ECDSA", hash: "SHA-256" }, key, raw, nonce);
    return valid ? counterOf(authenticatorData) : null;
}

function cborMap(bytes: Uint8Array): Map<string | number, CborValue> | null {
    try {
        const value = decodeCbor(bytes);
        return value instanceof Map ? value : null;
    } catch {
        return null;
    }
}

/// authData: rpIdHash (32) ‖ flags (1) ‖ counter (4) ‖ AAGUID (16) ‖ credential id length (2) ‖ credential id ‖ the
/// COSE key, which is not read: the leaf certificate carries the key that check 4 ties to the key id.
function attestedCredential(authData: Uint8Array): { aaguid: Uint8Array; id: Uint8Array } | null {
    if (authData.byteLength < 55) return null;
    const length = ((authData[53] ?? 0) << 8) | (authData[54] ?? 0);
    if (55 + length > authData.byteLength) return null;
    return { aaguid: authData.subarray(37, 53), id: authData.subarray(55, 55 + length) };
}

function counterOf(authData: Uint8Array): number {
    return new DataView(authData.buffer, authData.byteOffset + 33, 4).getUint32(0);
}

async function chainedLeaf(
    leafDer: Uint8Array,
    intermediateDer: Uint8Array,
    context: AttestationContext,
): Promise<Certificate | null> {
    let leaf: Certificate;
    let intermediate: Certificate;
    let root: Certificate;
    try {
        leaf = parseCertificate(leafDer);
        intermediate = parseCertificate(intermediateDer);
        root = parseCertificate(context.root);
    } catch {
        return null;
    }
    const now = context.now.getTime();
    const current = (certificate: Certificate, skew = 0) =>
        certificate.notBefore.getTime() - skew <= now && now <= certificate.notAfter.getTime();
    if (
        !current(leaf, LEAF_CLOCK_SKEW_MS) ||
        !current(intermediate) ||
        !current(root) ||
        !equal(leaf.issuer, intermediate.subject) ||
        !equal(intermediate.issuer, root.subject) ||
        !safely(() => isAuthority(intermediate))
    ) {
        return null;
    }
    if (!(await signedBy(leaf, intermediate)) || !(await signedBy(intermediate, root))) return null;
    return leaf;
}

/// The nonce in the leaf's Apple extension: SEQUENCE { [1] EXPLICIT OCTET STRING }.
function nonceExtension(leaf: Certificate): Uint8Array | null {
    const value = leaf.extensions.get(OID.APPLE_NONCE);
    if (!value) return null;
    try {
        const [tagged, ...rest] = readAll(readOne(value, TAG.SEQUENCE).value);
        if (rest.length > 0 || tagged?.tag !== 0xa1) return null;
        return readOne(tagged.value, TAG.OCTET_STRING).value;
    } catch {
        return null;
    }
}

function safely(check: () => boolean): boolean {
    try {
        return check();
    } catch {
        return false;
    }
}
