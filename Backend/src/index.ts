// The model service for the app: POST /v1/reply takes a ModelRequest and answers {reply, seconds, model, usage},
// the same contract as Engine/Evals/bridge.py plus the optional usage. Errors are {error: "<one line>"}.

import { readCapped, TooLarge } from "./body";
import prompt from "./build-prompt.txt";
import { callModel, ModelFailure } from "./model";
import { BadRequest, kindOf, userTurn } from "./request";

export type Env = Cloudflare.Env;

export interface Dependencies {
    fetch: typeof fetch;
    deadlineMs?: number;
}

/// Comfortably above a 1080 px JPEG in base64 plus a document, and well inside a Worker's memory.
export const MAX_BODY = 8 * 1024 * 1024;

export default {
    fetch(request, env) {
        return handle(request, env, { fetch });
    },
} satisfies ExportedHandler<Env>;

export async function handle(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/health" && request.method === "GET") return new Response("ok\n");
    if (pathname !== "/v1/reply") return new Response("not found\n", { status: 404 });
    if (request.method !== "POST") return new Response("method not allowed\n", { status: 405 });
    return reply(request, env, deps);
}

async function reply(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const started = Date.now();
    let parsed: unknown;
    const answer = (status: number, body: object, extra: Record<string, unknown> = {}) => {
        // Never the words, the document, or the picture.
        console.log(
            JSON.stringify({ route: "reply", kind: kindOf(parsed), status, ms: Date.now() - started, ...extra }),
        );
        return Response.json(body, { status });
    };

    // The gate comes before the body is read, so a caller without the token costs nothing.
    if (!(await authorized(request, env))) return answer(401, { error: "not authorized" });
    if ((request.headers.get("Content-Type") ?? "").split(";")[0]?.trim() !== "application/json") {
        return answer(415, { error: "send the body as application/json" });
    }
    let bytes: Uint8Array;
    try {
        bytes = await readCapped(request, MAX_BODY);
    } catch (error) {
        if (error instanceof TooLarge) return answer(413, { error: `the body is over ${MAX_BODY} bytes` });
        throw error;
    }
    let turn: ReturnType<typeof userTurn>;
    try {
        try {
            parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
        } catch {
            throw new BadRequest("the body must be a ModelRequest JSON object");
        }
        turn = userTurn(parsed);
    } catch (error) {
        if (error instanceof BadRequest) return answer(400, { error: oneLine(`bad request: ${error.message}`) });
        throw error;
    }

    const settings = {
        url: env.MODEL_URL,
        apiKey: env.MODEL_API_KEY,
        model: env.MODEL,
        provider: env.PROVIDER,
        reasoning: env.REASONING,
    };
    const called = Date.now();
    try {
        const result = await callModel(settings, prompt, turn, deps.fetch, deps.deadlineMs);
        const seconds = Math.round((Date.now() - called) / 100) / 10;
        return answer(
            200,
            { reply: result.text, seconds, model: result.model, usage: result.usage },
            { model: result.model, provider: result.provider, seconds, ...result.usage },
        );
    } catch (error) {
        if (!(error instanceof ModelFailure)) throw error;
        return answer(502, { error: "the model gave no answer" }, { reason: oneLine(error.reason) });
    }
}

/// One line of at most 300 characters, as bridge.py's `one_line` makes it, so an echoed key name or a provider's
/// message can neither break the line nor carry much of a request.
function oneLine(text: string): string {
    const line = text.split(/\s+/).filter(Boolean).join(" ");
    return line.length > 300 ? `${line.slice(0, 299)}…` : line;
}

async function authorized(request: Request, env: Env): Promise<boolean> {
    const token = env.OPERATOR_TOKEN;
    const header = request.headers.get("Authorization") ?? "";
    if (!token || !header.startsWith("Bearer ")) return false;
    // Digests have equal length, which timingSafeEqual needs, and hide the token's length.
    const digest = (value: string) => crypto.subtle.digest("SHA-256", new TextEncoder().encode(value));
    return crypto.subtle.timingSafeEqual(await digest(header.slice("Bearer ".length)), await digest(token));
}
