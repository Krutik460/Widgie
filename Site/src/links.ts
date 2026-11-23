// Confirm and leave links carry a signature instead of a stored token: HMAC-SHA256 under LINK_SECRET over the purpose,
// the row id and the row's email. The purpose means a leave link can never confirm and a confirm link can never delete.
// The email means a link stops working when its row is gone, even though SQLite hands a deleted row's id to the next
// signup.

export type Purpose = "confirm" | "leave";

async function key(secret: string, usage: "sign" | "verify") {
    return crypto.subtle.importKey("raw", new TextEncoder().encode(secret), { name: "HMAC", hash: "SHA-256" }, false, [
        usage,
    ]);
}

function message(purpose: Purpose, id: number, email: string) {
    return new TextEncoder().encode(`${purpose}:${id}:${email}`);
}

export async function sign(secret: string, purpose: Purpose, id: number, email: string): Promise<string> {
    const signature = await crypto.subtle.sign("HMAC", await key(secret, "sign"), message(purpose, id, email));
    return Array.from(new Uint8Array(signature), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

/// Signatures are 64 lowercase hex characters. Constant time, through `crypto.subtle.verify`; anything malformed is
/// simply not valid.
export async function verify(
    secret: string,
    purpose: Purpose,
    id: number,
    email: string,
    signature: string,
): Promise<boolean> {
    if (!/^[0-9a-f]{64}$/.test(signature)) return false;
    const bytes = Uint8Array.from(signature.match(/../g) ?? [], (pair) => Number.parseInt(pair, 16));
    return crypto.subtle.verify("HMAC", await key(secret, "verify"), bytes, message(purpose, id, email));
}
