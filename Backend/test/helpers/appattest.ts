// Builds what an iPhone and Apple would send, signed with WebCrypto keys instead of Apple's: a synthetic chain (P-384
// root and intermediate, P-256 leaf), attestation objects with any one field changed, and signed assertions.

import { env } from "cloudflare:workers";
import { aaguid, type Environment } from "../../src/attestation";
import { concat, sha256, toBase64, toHex } from "../../src/bytes";

// --- DER ---

function length(n: number): Uint8Array {
    if (n < 0x80) return new Uint8Array([n]);
    const bytes: number[] = [];
    for (let rest = n; rest > 0; rest = Math.floor(rest / 256)) bytes.unshift(rest % 256);
    return new Uint8Array([0x80 | bytes.length, ...bytes]);
}

export function tlv(tag: number, ...parts: Uint8Array[]): Uint8Array {
    const value = concat(...parts);
    return concat(new Uint8Array([tag]), length(value.byteLength), value);
}

export const seq = (...parts: Uint8Array[]) => tlv(0x30, ...parts);
const set = (...parts: Uint8Array[]) => tlv(0x31, ...parts);
const octets = (bytes: Uint8Array) => tlv(0x04, bytes);
const bits = (bytes: Uint8Array) => tlv(0x03, new Uint8Array([0]), bytes);
const bool = (value: boolean) => tlv(0x01, new Uint8Array([value ? 0xff : 0]));
const explicit = (n: number, ...parts: Uint8Array[]) => tlv(0xa0 + n, ...parts);

function integer(bytes: Uint8Array): Uint8Array {
    let start = 0;
    while (start < bytes.length - 1 && bytes[start] === 0) start++;
    const trimmed = bytes.subarray(start);
    return tlv(0x02, (trimmed[0] ?? 0) & 0x80 ? concat(new Uint8Array([0]), trimmed) : trimmed);
}

export function oid(dotted: string): Uint8Array {
    const [a = 0, b = 0, ...rest] = dotted.split(".").map(Number);
    const out = [40 * a + b];
    for (const arc of rest) {
        const chunk = [arc & 0x7f];
        for (let n = Math.floor(arc / 128); n > 0; n = Math.floor(n / 128)) chunk.unshift(0x80 | (n & 0x7f));
        out.push(...chunk);
    }
    return tlv(0x06, new Uint8Array(out));
}

function time(date: Date): Uint8Array {
    const iso = date.toISOString();
    const digits = iso.slice(0, 19).replaceAll("-", "").replaceAll("T", "").replaceAll(":", "");
    const year = date.getUTCFullYear();
    return year < 2050 ? tlv(0x17, ascii(`${digits.slice(2)}Z`)) : tlv(0x18, ascii(`${digits}Z`));
}

const ascii = (text: string) => new TextEncoder().encode(text);

function name(commonName: string): Uint8Array {
    return seq(set(seq(oid("2.5.4.3"), tlv(0x0c, ascii(commonName)))));
}

/// WebCrypto's `r ‖ s` as a DER ECDSA-Sig-Value.
export function derSignature(raw: Uint8Array): Uint8Array {
    const half = raw.byteLength / 2;
    return seq(integer(raw.subarray(0, half)), integer(raw.subarray(half)));
}

// --- CBOR ---

export type Encodable = number | string | Uint8Array | Encodable[] | Map<string | number, Encodable>;

function head(major: number, n: number): Uint8Array {
    if (n < 24) return new Uint8Array([(major << 5) | n]);
    if (n < 0x100) return new Uint8Array([(major << 5) | 24, n]);
    if (n < 0x10000) return new Uint8Array([(major << 5) | 25, n >> 8, n & 0xff]);
    return new Uint8Array([(major << 5) | 26, n >>> 24, (n >> 16) & 0xff, (n >> 8) & 0xff, n & 0xff]);
}

export function cbor(value: Encodable): Uint8Array {
    if (typeof value === "number") return value >= 0 ? head(0, value) : head(1, -1 - value);
    if (typeof value === "string") {
        const bytes = ascii(value);
        return concat(head(3, bytes.byteLength), bytes);
    }
    if (value instanceof Uint8Array) return concat(head(2, value.byteLength), value);
    if (Array.isArray(value)) return concat(head(4, value.length), ...value.map(cbor));
    return concat(head(5, value.size), ...[...value].flatMap(([k, v]) => [cbor(k), cbor(v)]));
}

// --- Keys and certificates ---

const OIDS = {
    ecPublicKey: "1.2.840.10045.2.1",
    "P-256": "1.2.840.10045.3.1.7",
    "P-384": "1.3.132.0.34",
    "SHA-256": "1.2.840.10045.4.3.2",
    "SHA-384": "1.2.840.10045.4.3.3",
    basicConstraints: "2.5.29.19",
    nonce: "1.2.840.113635.100.8.2",
};

type Curve = "P-256" | "P-384";

export interface Party {
    curve: Curve;
    keys: CryptoKeyPair;
    commonName: string;
}

export async function party(curve: Curve, commonName: string): Promise<Party> {
    const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: curve }, true, [
        "sign",
        "verify",
    ])) as CryptoKeyPair;
    return { curve, keys, commonName };
}

export async function publicPoint(keys: CryptoKeyPair): Promise<Uint8Array> {
    return new Uint8Array((await crypto.subtle.exportKey("raw", keys.publicKey)) as ArrayBuffer);
}

export interface CertificateOptions {
    subject: Party;
    issuer: Party;
    notBefore: Date;
    notAfter: Date;
    authority?: boolean;
    extensions?: Uint8Array[];
    hash?: "SHA-256" | "SHA-384";
    /// Signs with this key instead of the issuer's, for a certificate the issuer never signed.
    signer?: CryptoKey;
}

export async function certificate(options: CertificateOptions): Promise<Uint8Array> {
    const hash = options.hash ?? (options.issuer.curve === "P-384" ? "SHA-384" : "SHA-256");
    const algorithm = seq(oid(OIDS[hash]));
    const spki = seq(
        seq(oid(OIDS.ecPublicKey), oid(OIDS[options.subject.curve])),
        bits(await publicPoint(options.subject.keys)),
    );
    const extensions = [
        seq(oid(OIDS.basicConstraints), bool(true), octets(seq(...(options.authority ? [bool(true)] : [])))),
        ...(options.extensions ?? []),
    ];
    const tbs = seq(
        explicit(0, integer(new Uint8Array([2]))),
        integer(crypto.getRandomValues(new Uint8Array(8))),
        algorithm,
        name(options.issuer.commonName),
        seq(time(options.notBefore), time(options.notAfter)),
        name(options.subject.commonName),
        spki,
        explicit(3, seq(...extensions)),
    );
    const raw = new Uint8Array(
        await crypto.subtle.sign({ name: "ECDSA", hash }, options.signer ?? options.issuer.keys.privateKey, tbs),
    );
    return seq(tbs, algorithm, bits(derSignature(raw)));
}

/// The nonce extension: SEQUENCE { [1] EXPLICIT OCTET STRING nonce }.
export function nonceExtension(nonce: Uint8Array): Uint8Array {
    return seq(oid(OIDS.nonce), octets(seq(explicit(1, octets(nonce)))));
}

export const DAY = 24 * 60 * 60 * 1000;

export interface Chain {
    root: Party;
    intermediate: Party;
    rootDer: Uint8Array;
    intermediateDer: Uint8Array;
}

/// A root and intermediate valid for a year around `now`.
export async function chain(now: Date): Promise<Chain> {
    const root = await party("P-384", "Test App Attestation Root CA");
    const intermediate = await party("P-384", "Test App Attestation CA 1");
    const notBefore = new Date(now.getTime() - 180 * DAY);
    const notAfter = new Date(now.getTime() + 180 * DAY);
    return {
        root,
        intermediate,
        rootDer: await certificate({ subject: root, issuer: root, notBefore, notAfter, authority: true }),
        intermediateDer: await certificate({
            subject: intermediate,
            issuer: root,
            notBefore,
            notAfter,
            authority: true,
        }),
    };
}

// --- Attestation objects ---

export const APP_ID = "Z23KXVBB26.dev.krutikpatel.widgie";

export interface AttestationOptions {
    now: Date;
    chain: Chain;
    environment?: Environment;
    challenge?: string;
    /// The key to attest; a new one by default.
    leaf?: Party;
    /// Each changes one field from what a real device sends.
    fmt?: string;
    certificates?: (leaf: Uint8Array, intermediate: Uint8Array) => Uint8Array[];
    leafValidity?: { notBefore: Date; notAfter: Date };
    leafSigner?: CryptoKey;
    intermediateDer?: Uint8Array;
    nonce?: (authData: Uint8Array, clientDataHash: Uint8Array) => Promise<Uint8Array | null>;
    appId?: string;
    counter?: number;
    aaguid?: Uint8Array;
    credentialId?: (keyId: Uint8Array) => Uint8Array;
    authData?: (authData: Uint8Array) => Uint8Array;
}

export interface Attestation {
    keyId: string;
    keyIdBytes: Uint8Array;
    challenge: string;
    clientDataHash: Uint8Array;
    attestation: Uint8Array;
    leaf: Party;
    publicKey: Uint8Array;
}

/// A new P-256 key and the key id generateKey() would answer for it.
export async function newKey(): Promise<{ leaf: Party; keyId: string }> {
    const leaf = await party("P-256", "leaf");
    return { leaf, keyId: toBase64(await sha256(await publicPoint(leaf.keys))) };
}

export function randomChallenge(): string {
    return toBase64(crypto.getRandomValues(new Uint8Array(32)))
        .replaceAll("+", "-")
        .replaceAll("/", "_")
        .replaceAll("=", "");
}

export async function attestation(options: AttestationOptions): Promise<Attestation> {
    const leaf = options.leaf ?? (await party("P-256", "leaf"));
    const publicKey = await publicPoint(leaf.keys);
    const keyIdBytes = await sha256(publicKey);
    const challenge = options.challenge ?? randomChallenge();
    const clientDataHash = await sha256(challenge);

    const credentialId = options.credentialId?.(keyIdBytes) ?? keyIdBytes;
    const counter = new Uint8Array(4);
    new DataView(counter.buffer).setUint32(0, options.counter ?? 0);
    const cose = cbor(
        new Map<number, Encodable>([
            [1, 2],
            [3, -7],
            [-1, 1],
            [-2, publicKey.subarray(1, 33)],
            [-3, publicKey.subarray(33)],
        ]),
    );
    let authData = concat(
        await sha256(options.appId ?? APP_ID),
        new Uint8Array([0x40]),
        counter,
        options.aaguid ?? aaguid(options.environment ?? "production"),
        new Uint8Array([credentialId.byteLength >> 8, credentialId.byteLength & 0xff]),
        credentialId,
        cose,
    );
    if (options.authData) authData = options.authData(authData);

    const nonce = options.nonce
        ? await options.nonce(authData, clientDataHash)
        : await sha256(authData, clientDataHash);
    const leafDer = await certificate({
        subject: leaf,
        issuer: options.chain.intermediate,
        notBefore: options.leafValidity?.notBefore ?? new Date(options.now.getTime() - DAY),
        notAfter: options.leafValidity?.notAfter ?? new Date(options.now.getTime() + 2 * DAY),
        extensions: nonce ? [nonceExtension(nonce)] : [],
        hash: "SHA-256",
        signer: options.leafSigner,
    });
    const intermediateDer = options.intermediateDer ?? options.chain.intermediateDer;
    const x5c = options.certificates?.(leafDer, intermediateDer) ?? [leafDer, intermediateDer];
    const object = cbor(
        new Map<string, Encodable>([
            ["fmt", options.fmt ?? "apple-appattest"],
            [
                "attStmt",
                new Map<string, Encodable>([
                    ["x5c", x5c],
                    ["receipt", new Uint8Array([1, 2, 3])],
                ]),
            ],
            ["authData", authData],
        ]),
    );
    return {
        keyId: toBase64(keyIdBytes),
        keyIdBytes,
        challenge,
        clientDataHash,
        attestation: object,
        leaf,
        publicKey,
    };
}

// --- Assertions ---

export interface AssertionOptions {
    method?: string;
    path?: string;
    appId?: string;
    /// The counter to sign; the next one by default.
    counter?: number;
}

/// An App Attest key that signs requests as the app does.
export class Signer {
    counter = 0;

    private constructor(
        readonly keyId: string,
        readonly publicKey: Uint8Array,
        private readonly privateKey: CryptoKey,
    ) {}

    static async create(): Promise<Signer> {
        const keys = (await crypto.subtle.generateKey({ name: "ECDSA", namedCurve: "P-256" }, false, [
            "sign",
            "verify",
        ])) as CryptoKeyPair;
        return Signer.from(keys);
    }

    /// The signer for an existing key pair, such as an attestation's leaf.
    static async from(keys: CryptoKeyPair): Promise<Signer> {
        const publicKey = await publicPoint(keys);
        return new Signer(toBase64(await sha256(publicKey)), publicKey, keys.privateKey);
    }

    /// A key already stored in its object, as after a passing attestation.
    static async attested(): Promise<Signer> {
        const signer = await Signer.create();
        expectNull(await env.ATTESTED_KEY.getByName(signer.keyId).storeKey(signer.publicKey));
        return signer;
    }

    /// The assertion over `clientDataHash`: a CBOR map of the DER signature and the authenticator data.
    async assertion(clientDataHash: Uint8Array, options: AssertionOptions = {}): Promise<Uint8Array> {
        const counter = options.counter ?? this.counter + 1;
        this.counter = Math.max(this.counter, counter);
        const count = new Uint8Array(4);
        new DataView(count.buffer).setUint32(0, counter);
        const authenticatorData = concat(await sha256(options.appId ?? APP_ID), new Uint8Array([0]), count);
        const nonce = await sha256(authenticatorData, clientDataHash);
        const raw = new Uint8Array(
            await crypto.subtle.sign({ name: "ECDSA", hash: "SHA-256" }, this.privateKey, nonce),
        );
        return cbor(
            new Map<string, Encodable>([
                ["signature", derSignature(raw)],
                ["authenticatorData", authenticatorData],
            ]),
        );
    }

    /// The headers for a request with `body`, signed over `METHOD \n PATH \n hex SHA256(body)`.
    async headers(body: string | Uint8Array, options: AssertionOptions = {}): Promise<Record<string, string>> {
        const assertion = await this.assertion(await clientDataHash(body, options), options);
        return { "X-Widgie-Key": this.keyId, "X-Widgie-Assertion": toBase64(assertion) };
    }
}

export async function clientDataHash(body: string | Uint8Array, options: AssertionOptions = {}): Promise<Uint8Array> {
    const bytes = typeof body === "string" ? ascii(body) : body;
    return sha256(`${options.method ?? "POST"}\n${options.path ?? "/v1/reply"}\n${toHex(await sha256(bytes))}`);
}

function expectNull(value: unknown) {
    if (value !== null) throw new Error(`expected null, got ${JSON.stringify(value)}`);
}
