// A minimal CBOR decoder (RFC 8949) for App Attest's attestation object and assertion: unsigned and negative
// integers, byte and text strings, arrays, maps with text or integer keys, and false, true, and null. Only definite
// lengths, which is all Apple sends. Anything else, trailing bytes, or nesting past a small depth is refused.

export type CborValue = number | string | boolean | null | Uint8Array | CborValue[] | Map<string | number, CborValue>;

export class CborError extends Error {}

const MAX_DEPTH = 8;

export function decodeCbor(bytes: Uint8Array): CborValue {
    const reader = new Reader(bytes);
    const value = reader.item(0);
    if (reader.offset !== bytes.byteLength) throw new CborError("trailing bytes");
    return value;
}

class Reader {
    offset = 0;
    constructor(private readonly bytes: Uint8Array) {}

    item(depth: number): CborValue {
        if (depth > MAX_DEPTH) throw new CborError("nested too deep");
        const initial = this.byte();
        const major = initial >> 5;
        const info = initial & 0x1f;
        if (major === 7) {
            if (info === 20) return false;
            if (info === 21) return true;
            if (info === 22) return null;
            throw new CborError("unsupported simple value");
        }
        const argument = this.argument(info);
        switch (major) {
            case 0:
                return argument;
            case 1:
                return -1 - argument;
            case 2:
                return this.take(argument);
            case 3:
                try {
                    return new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(this.take(argument));
                } catch {
                    throw new CborError("text is not UTF-8");
                }
            case 4: {
                const items: CborValue[] = [];
                for (let i = 0; i < argument; i++) items.push(this.item(depth + 1));
                return items;
            }
            case 5: {
                const map = new Map<string | number, CborValue>();
                for (let i = 0; i < argument; i++) {
                    const key = this.item(depth + 1);
                    if (typeof key !== "string" && typeof key !== "number") throw new CborError("unsupported map key");
                    if (map.has(key)) throw new CborError("duplicate map key");
                    map.set(key, this.item(depth + 1));
                }
                return map;
            }
            default:
                throw new CborError("tags are not supported");
        }
    }

    private argument(info: number): number {
        if (info < 24) return info;
        if (info === 24) return this.byte();
        if (info === 25) return (this.byte() << 8) | this.byte();
        if (info === 26) return this.byte() * 0x1000000 + ((this.byte() << 16) | (this.byte() << 8) | this.byte());
        throw new CborError("unsupported length");
    }

    private byte(): number {
        const byte = this.bytes[this.offset];
        if (byte === undefined) throw new CborError("truncated");
        this.offset++;
        return byte;
    }

    private take(length: number): Uint8Array {
        if (length > this.bytes.byteLength - this.offset) throw new CborError("truncated");
        const out = this.bytes.subarray(this.offset, this.offset + length);
        this.offset += length;
        return out;
    }
}
