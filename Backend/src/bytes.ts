// Byte helpers shared by the routes and the App Attest checks: strict base64, hex, SHA-256, and comparison.

/// The set Python's strict `b64decode(validate=True)` accepts. `atob` is native: a regex over a picture's 170 KB
/// runs in V8's regex interpreter on a fresh isolate and costs about 5 ms of the free plan's 10 ms of CPU.
export function isBase64(data: string): boolean {
    if (data === "" || data.length % 4 !== 0) return false;
    // atob skips ASCII whitespace; the strict decode refuses it.
    if ([" ", "\t", "\n", "\f", "\r"].some((space) => data.includes(space))) return false;
    try {
        atob(data);
        return true;
    } catch {
        return false;
    }
}

/// Standard base64 by the same rules as `isBase64`, or null.
export function fromBase64(data: string): Uint8Array | null {
    if (!isBase64(data)) return null;
    const binary = atob(data);
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return bytes;
}

export function toBase64(bytes: Uint8Array): string {
    let binary = "";
    for (const byte of bytes) binary += String.fromCharCode(byte);
    return btoa(binary);
}

/// Unpadded base64url, as the challenge travels.
export function toBase64Url(bytes: Uint8Array): string {
    return toBase64(bytes).replaceAll("+", "-").replaceAll("/", "_").replaceAll("=", "");
}

export function toHex(bytes: Uint8Array): string {
    let hex = "";
    for (const byte of bytes) hex += byte.toString(16).padStart(2, "0");
    return hex;
}

export async function sha256(...parts: (Uint8Array | string)[]): Promise<Uint8Array> {
    const data = concat(...parts.map((part) => (typeof part === "string" ? new TextEncoder().encode(part) : part)));
    return new Uint8Array(await crypto.subtle.digest("SHA-256", data));
}

export function concat(...parts: Uint8Array[]): Uint8Array {
    const out = new Uint8Array(parts.reduce((total, part) => total + part.byteLength, 0));
    let offset = 0;
    for (const part of parts) {
        out.set(part, offset);
        offset += part.byteLength;
    }
    return out;
}

export function equal(a: Uint8Array, b: Uint8Array): boolean {
    if (a.byteLength !== b.byteLength) return false;
    for (let i = 0; i < a.byteLength; i++) if (a[i] !== b[i]) return false;
    return true;
}
