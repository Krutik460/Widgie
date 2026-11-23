// The app's ModelRequest, checked and turned into the model's user turn. A port of `user_message` in
// Engine/Evals/model.py: both read Engine/Evals/testdata/invalid-requests.json, so they refuse a request with the
// same line.

export interface ModelRequest {
    words: string;
    image?: { mime: string; base64: string };
    current?: string;
    repair?: { document: string; line: string };
}

export interface UserTurn {
    text: string;
    image?: { mime: string; base64: string };
}

export class BadRequest extends Error {}

const FIELDS = new Set(["words", "image", "current", "repair"]);
const MEDIA_TYPES = ["image/jpeg", "image/png"];
const BASE64 = /^(?:[A-Za-z0-9+/]{4})*(?:[A-Za-z0-9+/]{2}==|[A-Za-z0-9+/]{3}=)?$/;

// Far above anything the app sends: a person's words, or a stored document of a few kilobytes. They keep one
// request from filling the model's context. The Python bridge has none, so only Vitest covers them.
export const LIMITS = { words: 20_000, document: 400_000, line: 20_000 } as const;

export function kindOf(request: unknown): "create" | "refine" | "repair" | "-" {
    if (!isObject(request)) return "-";
    if (request.repair !== undefined && request.repair !== null) return "repair";
    return request.current !== undefined && request.current !== null ? "refine" : "create";
}

export function userTurn(request: unknown): UserTurn {
    if (!isObject(request)) throw new BadRequest("the request must be a JSON object");
    const unknown = Object.keys(request)
        .filter((key) => !FIELDS.has(key))
        .sort();
    if (unknown.length > 0) throw new BadRequest(`unknown request fields: ${unknown.join(", ")}`);

    const { words, current, repair, image } = request;
    if (typeof words !== "string" || words.trim() === "") {
        throw new BadRequest('"words" must be a non-empty string');
    }
    capped("words", words, LIMITS.words);
    if (current != null && (typeof current !== "string" || current.trim() === "")) {
        throw new BadRequest('"current" must be the document being refined, as a non-empty string');
    }
    if (typeof current === "string") capped("current", current, LIMITS.document);
    if (
        repair != null &&
        !(isObject(repair) && typeof repair.document === "string" && typeof repair.line === "string")
    ) {
        throw new BadRequest('"repair" must hold "document" and "line" strings');
    }
    if (isObject(repair)) {
        capped("repair.document", repair.document as string, LIMITS.document);
        capped("repair.line", repair.line as string, LIMITS.line);
    }

    // A create is the person's words alone. A refine adds the document being changed, and a repair adds the
    // rejected attempt and its line, keeping the refine's document so the model never loses the original.
    const sections = [`The person's request:\n\n${words}`];
    if (typeof current === "string") sections.push(`The current document:\n\n\`\`\`json\n${current}\n\`\`\``);
    if (isObject(repair)) {
        sections.push(
            `Your previous document:\n\n\`\`\`json\n${repair.document}\n\`\`\``,
            `The line from the app:\n\n${repair.line}`,
            "Reply with the complete corrected document.",
        );
    }
    const text = sections.length > 1 ? sections.join("\n\n") : words;

    if (image == null) return { text };
    if (!isObject(image) || typeof image.mime !== "string" || !MEDIA_TYPES.includes(image.mime)) {
        throw new BadRequest(`"image" must hold a "mime" of ${MEDIA_TYPES.join(" or ")}`);
    }
    // Checked by shape, not decoded, so a picture costs no decode CPU. Python's strict decode accepts the same set.
    const data = image.base64;
    if (typeof data !== "string" || data === "" || !BASE64.test(data)) {
        throw new BadRequest('"image" must hold "base64" image data');
    }
    return { text, image: { mime: image.mime, base64: data } };
}

function capped(name: string, value: string, limit: number) {
    if (value.length > limit) throw new BadRequest(`"${name}" is longer than ${limit} characters`);
}

function isObject(value: unknown): value is Record<string, unknown> {
    return typeof value === "object" && value !== null && !Array.isArray(value);
}
