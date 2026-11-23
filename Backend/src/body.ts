// Reads a request body as a stream and stops at a byte limit, so a body with no Content-Length, or one that lies,
// never gets past the limit into memory.

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
