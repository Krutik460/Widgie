// Reads a request body as a stream and stops at a byte limit, so a body with no Content-Length, or one that lies,
// never gets past the limit into memory.

// The body caps live here, not in index.ts: workerd takes every export of the entry module as an entrypoint and
// refuses to start on one that is not a handler or a class.

/// Comfortably above a 1080 px JPEG in base64 plus a document, and well inside a Worker's memory.
export const MAX_BODY = 8 * 1024 * 1024;
/// Far above an attestation object in base64 (two certificates and a receipt, under 10 KB).
export const MAX_ATTEST_BODY = 32 * 1024;
/// Far above what a phone's automations take (16 with 2,000-character prompts and 16 fields each is under 64 KB): a
/// guard on the Worker's memory, not a usage limit.
export const MAX_AUTOMATIONS_BODY = 256 * 1024;

export class TooLarge extends Error {}

export async function readCapped(request: Request, limit: number): Promise<Uint8Array> {
    const declared = Number(request.headers.get("Content-Length"));
    if (Number.isFinite(declared) && declared > limit) throw new TooLarge();
    if (!request.body) return new Uint8Array();

    const reader = request.body.getReader();
    const chunks: Uint8Array[] = [];
    let total = 0;
    for (;;) {
        const { done, value } = await reader.read();
        if (done) break;
        total += value.byteLength;
        if (total > limit) {
            await reader.cancel();
            throw new TooLarge();
        }
        chunks.push(value);
    }
    const body = new Uint8Array(total);
    let offset = 0;
    for (const chunk of chunks) {
        body.set(chunk, offset);
        offset += chunk.byteLength;
    }
    return body;
}
