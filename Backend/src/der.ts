// A minimal DER reader and X.509 certificate parser for App Attest's chain: enough to take a certificate's signed
// bytes, signature, and algorithm, its issuer and subject, its validity, its EC public key, and its extensions, and
// to check one certificate's signature with another's key through WebCrypto. Single-byte tags and definite lengths
// only, as DER requires.

export class DerError extends Error {}

export const TAG = {
    BOOLEAN: 0x01,
    INTEGER: 0x02,
    BIT_STRING: 0x03,
    OCTET_STRING: 0x04,
    OID: 0x06,
    UTC_TIME: 0x17,
    GENERALIZED_TIME: 0x18,
    SEQUENCE: 0x30,
} as const;

export interface Tlv {
    tag: number;
    /// The whole element, tag and length included.
    raw: Uint8Array;
    value: Uint8Array;
}

/// The elements one after another in `bytes`, which they must fill exactly.
export function readAll(bytes: Uint8Array): Tlv[] {
    const out: Tlv[] = [];
    let offset = 0;
    while (offset < bytes.byteLength) {
        const element = readAt(bytes, offset);
        out.push(element);
        offset += element.raw.byteLength;
    }
    return out;
}

/// The single element that fills `bytes`, which must carry `tag`.
export function readOne(bytes: Uint8Array, tag: number): Tlv {
    const element = readAt(bytes, 0);
    if (element.raw.byteLength !== bytes.byteLength) throw new DerError("trailing bytes");
    return expect(element, tag);
}

export function expect(element: Tlv | undefined, tag: number): Tlv {
    if (element?.tag !== tag) throw new DerError(`expected tag ${tag}`);
    return element;
}

function readAt(bytes: Uint8Array, start: number): Tlv {
    const tag = bytes[start];
    const first = bytes[start + 1];
    if (tag === undefined || first === undefined) throw new DerError("truncated");
    if ((tag & 0x1f) === 0x1f) throw new DerError("multi-byte tags are not supported");
    let length = first;
    let header = 2;
    if (first & 0x80) {
        const count = first & 0x7f;
        if (count === 0 || count > 3) throw new DerError("unsupported length");
        length = 0;
        for (let i = 0; i < count; i++) {
            const byte = bytes[start + 2 + i];
            if (byte === undefined) throw new DerError("truncated");
            length = length * 256 + byte;
        }
        if (length < 0x80) throw new DerError("length is not minimal");
        header += count;
    }
    const end = start + header + length;
    if (end > bytes.byteLength) throw new DerError("truncated");
    return { tag, raw: bytes.subarray(start, end), value: bytes.subarray(start + header, end) };
}

export function oid(value: Uint8Array): string {
    if (value.byteLength === 0) throw new DerError("empty OID");
    const parts: number[] = [];
    let current = 0;
    for (const byte of value) {
        current = current * 128 + (byte & 0x7f);
        if (current > Number.MAX_SAFE_INTEGER / 128) throw new DerError("OID arc too large");
        if (!(byte & 0x80)) {
            parts.push(current);
            current = 0;
        }
    }
    if ((value[value.byteLength - 1] ?? 0) & 0x80) throw new DerError("truncated OID");
    const head = parts.shift() ?? 0;
    const first = head < 40 ? 0 : head < 80 ? 1 : 2;
    return [first, head - first * 40, ...parts].join(".");
}

export const OID = {
    EC_PUBLIC_KEY: "1.2.840.10045.2.1",
    P256: "1.2.840.10045.3.1.7",
    P384: "1.3.132.0.34",
    ECDSA_SHA256: "1.2.840.10045.4.3.2",
    ECDSA_SHA384: "1.2.840.10045.4.3.3",
    BASIC_CONSTRAINTS: "2.5.29.19",
    /// Apple's App Attest nonce extension.
    APPLE_NONCE: "1.2.840.113635.100.8.2",
} as const;

const CURVES: Record<string, { name: "P-256" | "P-384"; size: number }> = {
    [OID.P256]: { name: "P-256", size: 32 },
    [OID.P384]: { name: "P-384", size: 48 },
};

const HASHES: Record<string, "SHA-256" | "SHA-384"> = {
    [OID.ECDSA_SHA256]: "SHA-256",
    [OID.ECDSA_SHA384]: "SHA-384",
};

export interface Certificate {
    /// The signed bytes: the whole tbsCertificate element.
    tbs: Uint8Array;
    /// The signature algorithm's OID, the same inside and outside the signed bytes.
    algorithm: string;
    /// The DER ECDSA signature.
    signature: Uint8Array;
    issuer: Uint8Array;
    subject: Uint8Array;
    notBefore: Date;
    notAfter: Date;
    /// The whole SubjectPublicKeyInfo element, which WebCrypto imports as "spki".
    spki: Uint8Array;
    curve: "P-256" | "P-384";
    /// The X9.62 point from the SubjectPublicKeyInfo.
    point: Uint8Array;
    /// Extension values (the contents of each extnValue OCTET STRING) by OID.
    extensions: Map<string, Uint8Array>;
}

export function parseCertificate(der: Uint8Array): Certificate {
    const [tbsElement, algorithmElement, signatureElement, ...rest] = readAll(readOne(der, TAG.SEQUENCE).value);
    if (rest.length > 0) throw new DerError("extra certificate fields");
    const tbsSequence = expect(tbsElement, TAG.SEQUENCE);
    const algorithm = algorithmOid(expect(algorithmElement, TAG.SEQUENCE));
    const signature = bitString(expect(signatureElement, TAG.BIT_STRING));

    const fields = readAll(tbsSequence.value);
    let index = 0;
    if (fields[0]?.tag === 0xa0) index++; // [0] EXPLICIT version
    expect(fields[index++], TAG.INTEGER); // serial number
    if (algorithmOid(expect(fields[index++], TAG.SEQUENCE)) !== algorithm) {
        throw new DerError("signature algorithms differ");
    }
    const issuer = expect(fields[index++], TAG.SEQUENCE).raw;
    const [notBefore, notAfter, ...extraTimes] = readAll(expect(fields[index++], TAG.SEQUENCE).value);
    if (extraTimes.length > 0) throw new DerError("extra validity fields");
    const subject = expect(fields[index++], TAG.SEQUENCE).raw;
    const spkiElement = expect(fields[index++], TAG.SEQUENCE);
    const [keyAlgorithm, keyBits, ...extraKey] = readAll(spkiElement.value);
    if (extraKey.length > 0) throw new DerError("extra key fields");
    const [keyType, curveOid, ...extraParams] = readAll(expect(keyAlgorithm, TAG.SEQUENCE).value);
    if (extraParams.length > 0 || oid(expect(keyType, TAG.OID).value) !== OID.EC_PUBLIC_KEY) {
        throw new DerError("not an EC key");
    }
    const curve = CURVES[oid(expect(curveOid, TAG.OID).value)];
    if (!curve) throw new DerError("unsupported curve");
    const point = bitString(expect(keyBits, TAG.BIT_STRING));
    if (point.byteLength !== 1 + 2 * curve.size || point[0] !== 0x04) {
        throw new DerError("not an uncompressed point");
    }

    const extensions = new Map<string, Uint8Array>();
    for (const field of fields.slice(index)) {
        if (field.tag !== 0xa3) continue; // only [3] EXPLICIT extensions; unique IDs are skipped
        for (const extension of readAll(readOne(field.value, TAG.SEQUENCE).value)) {
            const parts = readAll(expect(extension, TAG.SEQUENCE).value);
            if (parts.length < 2 || parts.length > 3) throw new DerError("bad extension");
            const id = oid(expect(parts[0], TAG.OID).value);
            const value = expect(parts[parts.length - 1], TAG.OCTET_STRING).value;
            if (extensions.has(id)) throw new DerError("duplicate extension");
            extensions.set(id, value);
        }
    }

    return {
        tbs: tbsSequence.raw,
        algorithm,
        signature,
        issuer,
        subject,
        notBefore: time(notBefore),
        notAfter: time(notAfter),
        spki: spkiElement.raw,
        curve: curve.name,
        point,
        extensions,
    };
}

/// Whether `issuer`'s key signed `certificate`.
export async function signedBy(certificate: Certificate, issuer: Certificate): Promise<boolean> {
    const hash = HASHES[certificate.algorithm];
    const size = issuer.curve === "P-256" ? 32 : 48;
    const raw = hash && rawSignature(certificate.signature, size);
    if (!raw) return false;
    let key: CryptoKey;
    try {
        key = await crypto.subtle.importKey("spki", issuer.spki, { name: "ECDSA", namedCurve: issuer.curve }, false, [
            "verify",
        ]);
    } catch {
        return false; // a point that is not on the curve
    }
    return crypto.subtle.verify({ name: "ECDSA", hash }, key, raw, certificate.tbs);
}

/// Whether the certificate's basic constraints say it is a CA.
export function isAuthority(certificate: Certificate): boolean {
    const value = certificate.extensions.get(OID.BASIC_CONSTRAINTS);
    if (!value) return false;
    const first = readAll(readOne(value, TAG.SEQUENCE).value)[0];
    return first?.tag === TAG.BOOLEAN && first.value.byteLength === 1 && first.value[0] === 0xff;
}

/// A DER ECDSA-Sig-Value as the fixed-width `r ‖ s` WebCrypto takes, or null if it is not one for this size.
export function rawSignature(der: Uint8Array, size: number): Uint8Array | null {
    try {
        const parts = readAll(readOne(der, TAG.SEQUENCE).value);
        if (parts.length !== 2) return null;
        const out = new Uint8Array(2 * size);
        for (const [i, part] of parts.entries()) {
            let integer = expect(part, TAG.INTEGER).value;
            if (integer.byteLength === 0 || (integer[0] ?? 0) & 0x80) return null; // empty or negative
            while (integer.byteLength > 1 && integer[0] === 0) integer = integer.subarray(1);
            if (integer.byteLength > size) return null;
            out.set(integer, (i + 1) * size - integer.byteLength);
        }
        return out;
    } catch (error) {
        if (error instanceof DerError) return null;
        throw error;
    }
}

function algorithmOid(element: Tlv): string {
    const [id, ...parameters] = readAll(element.value);
    if (parameters.length > 0) throw new DerError("ECDSA algorithms carry no parameters");
    return oid(expect(id, TAG.OID).value);
}

function bitString(element: Tlv): Uint8Array {
    if (element.value[0] !== 0) throw new DerError("bit string with unused bits");
    return element.value.subarray(1);
}

/// UTCTime `YYMMDDHHMMSSZ` or GeneralizedTime `YYYYMMDDHHMMSSZ`, the only forms RFC 5280 allows.
function time(element: Tlv | undefined): Date {
    if (!element || (element.tag !== TAG.UTC_TIME && element.tag !== TAG.GENERALIZED_TIME)) {
        throw new DerError("expected a time");
    }
    const text = String.fromCharCode(...element.value);
    const yearDigits = element.tag === TAG.UTC_TIME ? 2 : 4;
    if (text.length !== yearDigits + 11 || !text.endsWith("Z")) throw new DerError("unsupported time form");
    const digits = text.slice(0, -1);
    for (const char of digits) if (char < "0" || char > "9") throw new DerError("bad time");
    let year = Number(digits.slice(0, yearDigits));
    if (yearDigits === 2) year += year >= 50 ? 1900 : 2000;
    const [month, day, hour, minute, second] = [0, 2, 4, 6, 8].map((at) =>
        Number(digits.slice(yearDigits + at, yearDigits + at + 2)),
    ) as [number, number, number, number, number];
    const date = new Date(Date.UTC(year, month - 1, day, hour, minute, second));
    if (date.getUTCMonth() !== month - 1 || date.getUTCDate() !== day || hour > 23 || minute > 59 || second > 59) {
        throw new DerError("bad time");
    }
    return date;
}
