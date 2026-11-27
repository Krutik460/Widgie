// The model service for the app. POST /v1/reply takes a ModelRequest signed with an App Attest assertion and answers
// {reply, seconds, model, usage}, the same contract as Engine/Evals/bridge.py plus the optional usage. A key is
// attested once per install through POST /v1/attest/challenge and POST /v1/attest. The wire protocol is in
// tasks/phase-2b-backend.md under "B2 wire protocol". Errors are {error: "<one line>"}, plus a `code` for the App
// Attest and payload limit refusals the app acts on. There are no usage limits for now (removed 2026-11-27, they come
// back later): only the body caps and the signature stand between a caller and the model.
//
// Phase 3 (tasks/phase-3-ai-block.md): POST /v1/account registers with an App Attest assertion and answers {token};
// PUT /v1/automations replaces the account's automations (the payload in docs/engine/WIRE.md) and answers {digest};
// GET /v1/changes?after=<id> answers a page in the wire format. Those two take `Authorization: Bearer <token>`.

import { authenticate, pull, register } from "./accounts";
import { APPLE_ROOT } from "./apple-root";
import { environmentOf, verifyAttestation } from "./attestation";
import { Conflict, OverLimit, parsePayload, replaceAutomations } from "./automations";
import { readCapped, TooLarge } from "./body";
import prompt from "./build-prompt.txt";
import { fromBase64, sha256, toBase64, toHex } from "./bytes";
import { callModel, ModelFailure } from "./model";
import { BadRequest, kindOf, userTurn } from "./request";
import { LARGEST_ID } from "./wire";

export { AttestedKey } from "./attested-key";

export type Env = Cloudflare.Env;

export interface Dependencies {
    fetch: typeof fetch;
    deadlineMs?: number;
    /// The pinned root and the clock an attestation is checked against: Apple's root and the real time by default.
    attestRoot?: Uint8Array;
    now?: () => Date;
}

/// Comfortably above a 1080 px JPEG in base64 plus a document, and well inside a Worker's memory.
export const MAX_BODY = 8 * 1024 * 1024;
/// Far above an attestation object in base64 (two certificates and a receipt, under 10 KB).
export const MAX_ATTEST_BODY = 32 * 1024;
/// Far above an assertion in base64 (a DER signature and 37 bytes of authenticator data, under 200 characters).
const MAX_ASSERTION = 1024;
/// Far above what a phone's automations take (16 with 2,000-character prompts and 16 fields each is under 64 KB): a
/// guard on the Worker's memory, not a usage limit.
export const MAX_AUTOMATIONS_BODY = 256 * 1024;

export type Code = keyof typeof REFUSALS;

const REFUSALS = {
    "unknown-key": [401, "this key is not attested"],
    "bad-assertion": [401, "the request's signature is not valid"],
    "bad-attestation": [401, "the attestation is not valid"],
    attested: [409, "this key is already attested"],
    "bad-token": [401, "the account token is not valid"],
    "bad-dev-secret": [401, "dev registration is not accepted here"],
    conflict: [409, "the automations changed during this upload, send them again"],
} as const satisfies Record<string, readonly [number, string]>;

export default {
    fetch(request, env) {
        return handle(request, env, { fetch });
    },
} satisfies ExportedHandler<Env>;

type Route = (request: Request, env: Env, deps: Dependencies) => Promise<Response>;

const ROUTES = new Map<string, { method: string; route: Route }>([
    ["/v1/reply", { method: "POST", route: reply }],
    ["/v1/attest/challenge", { method: "POST", route: challenge }],
    ["/v1/attest", { method: "POST", route: attest }],
    ["/v1/account", { method: "POST", route: account }],
    ["/v1/automations", { method: "PUT", route: automations }],
    ["/v1/changes", { method: "GET", route: changes }],
]);

export async function handle(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const { pathname } = new URL(request.url);
    if (pathname === "/health" && request.method === "GET") return new Response("ok\n");
    const found = ROUTES.get(pathname);
    if (!found) return new Response("not found\n", { status: 404 });
    if (request.method !== found.method) return new Response("method not allowed\n", { status: 405 });
    return found.route(request, env, deps);
}

/// Answers and logs one line per request: the route, its status and time, and what `fields` adds. Never the words,
/// the document, the picture, a key id, or an attestation.
function responder(route: string, fields: () => Record<string, unknown> = () => ({})) {
    const started = Date.now();
    const log = (status: number, extra: Record<string, unknown>) =>
        console.log(JSON.stringify({ route, ...fields(), status, ms: Date.now() - started, ...extra }));
    return {
        json(status: number, body: object, extra: Record<string, unknown> = {}) {
            log(status, extra);
            return Response.json(body, { status });
        },
        /// JSON already encoded, such as a page of changes.
        encoded(body: string, extra: Record<string, unknown> = {}) {
            log(200, extra);
            return new Response(body, { headers: { "Content-Type": "application/json" } });
        },
        refuse(code: Code, extra: Record<string, unknown> = {}) {
            const [status, line] = REFUSALS[code];
            log(status, { code, ...extra });
            return Response.json({ error: line, code }, { status });
        },
        empty(status: number) {
            log(status, {});
            return new Response(null, { status });
        },
    };
}

type Responder = ReturnType<typeof responder>;

async function reply(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    let parsed: unknown;
    const out = responder("reply", () => ({ kind: kindOf(parsed) }));

    // The signature's shape is checked before the body is read, so an unsigned caller costs nothing.
    const keyId = request.headers.get("X-Widgie-Key") ?? "";
    const assertionText = request.headers.get("X-Widgie-Assertion") ?? "";
    const assertion = assertionText.length <= MAX_ASSERTION ? fromBase64(assertionText) : null;
    if (!keyIdBytes(keyId) || !assertion) return out.refuse("bad-assertion", { reason: "unsigned" });
    if (!isJson(request)) return out.json(415, { error: "send the body as application/json" });
    let bytes: Uint8Array;
    try {
        bytes = await readCapped(request, MAX_BODY);
    } catch (error) {
        if (error instanceof TooLarge) return out.json(413, { error: `the body is over ${MAX_BODY} bytes` });
        throw error;
    }

    // Only the client data hash and the assertion go to the key's object, never the body.
    const clientData = `${request.method}\n/v1/reply\n${toHex(await sha256(bytes))}`;
    const refused = await env.ATTESTED_KEY.getByName(keyId).verifyAndAdvance(await sha256(clientData), assertion);
    if (refused) return out.refuse(refused);

    let turn: ReturnType<typeof userTurn>;
    try {
        try {
            parsed = JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes));
        } catch {
            throw new BadRequest("the body must be a ModelRequest JSON object");
        }
        turn = userTurn(parsed);
    } catch (error) {
        if (error instanceof BadRequest) return out.json(400, { error: oneLine(`bad request: ${error.message}`) });
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
        return out.json(
            200,
            { reply: result.text, seconds, model: result.model, usage: result.usage },
            { model: result.model, provider: result.provider, seconds, ...result.usage },
        );
    } catch (error) {
        if (!(error instanceof ModelFailure)) throw error;
        return out.json(502, { error: "the model gave no answer" }, { reason: oneLine(error.reason) });
    }
}

/// POST /v1/attest/challenge {keyId} answers {challenge}: 32 random bytes as unpadded base64url, for one use within
/// five minutes.
async function challenge(request: Request, env: Env): Promise<Response> {
    const out = responder("challenge");
    const body = await attestBody(request, out, ["keyId"]);
    if (body instanceof Response) return body;
    const keyId = body.keyId;
    if (typeof keyId !== "string" || !keyIdBytes(keyId)) return badRequest(out, '"keyId" must be an App Attest key id');
    const result = await env.ATTESTED_KEY.getByName(keyId).issueChallenge();
    if ("code" in result) return out.refuse(result.code);
    return out.json(200, { challenge: result.challenge });
}

/// POST /v1/attest {keyId, challenge, attestation} answers 204 once the key is stored.
async function attest(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const out = responder("attest");
    const body = await attestBody(request, out, ["keyId", "challenge", "attestation"]);
    if (body instanceof Response) return body;
    const { keyId, challenge, attestation } = body;
    const keyIdBinary = typeof keyId === "string" ? keyIdBytes(keyId) : null;
    if (typeof keyId !== "string" || !keyIdBinary) return badRequest(out, '"keyId" must be an App Attest key id');
    if (!isChallenge(challenge)) return badRequest(out, '"challenge" must be a challenge from /v1/attest/challenge');
    const attestationBinary = typeof attestation === "string" ? fromBase64(attestation) : null;
    if (!attestationBinary) return badRequest(out, '"attestation" must be base64');
    const context = {
        root: deps.attestRoot ?? APPLE_ROOT,
        now: deps.now?.() ?? new Date(),
        appId: env.APP_ID,
        environment: environmentOf(env.ATTEST_ENV),
    };

    // The challenge is taken and deleted before the checks, so a failed attestation cannot try it again.
    const key = env.ATTESTED_KEY.getByName(keyId);
    const taken = await key.takeChallenge(challenge);
    if (taken) return out.refuse(taken, taken === "bad-attestation" ? { reason: "challenge" } : {});
    const result = await verifyAttestation(keyIdBinary, await sha256(challenge), attestationBinary, context);
    if (!result.ok) return out.refuse("bad-attestation", { reason: result.failed });
    const stored = await key.storeKey(result.publicKey);
    if (stored) return out.refuse(stored);
    return out.empty(204);
}

/// POST /v1/account answers {token}, a new token for the account of the App Attest key that signed the request, with
/// an empty body signed as /v1/reply's is, and checked by the same `verifyAndAdvance`, which stores its counter.
/// In `dev` only, an `X-Widgie-Dev-Secret` header carrying DEV_REGISTRATION_SECRET registers a new account instead, for
/// the simulator, which cannot attest; `production` refuses it whatever its secrets hold.
async function account(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    let via = "-";
    const out = responder("account", () => ({ via }));
    const now = (deps.now?.() ?? new Date()).getTime();
    const devSecret = request.headers.get("X-Widgie-Dev-Secret");
    if (devSecret !== null) {
        via = "dev";
        if (!(await devRegistration(env, devSecret))) return out.refuse("bad-dev-secret");
        if (!(await isEmpty(request))) return out.json(413, { error: "the body must be empty" });
        return out.json(200, { token: await register(env.DB, null, now) });
    }

    via = "attest";
    const keyId = request.headers.get("X-Widgie-Key") ?? "";
    const assertionText = request.headers.get("X-Widgie-Assertion") ?? "";
    const assertion = assertionText.length <= MAX_ASSERTION ? fromBase64(assertionText) : null;
    if (!keyIdBytes(keyId) || !assertion) return out.refuse("bad-assertion", { reason: "unsigned" });
    if (!(await isEmpty(request))) return out.json(413, { error: "the body must be empty" });
    const clientData = `POST\n/v1/account\n${toHex(await sha256(new Uint8Array()))}`;
    const refused = await env.ATTESTED_KEY.getByName(keyId).verifyAndAdvance(await sha256(clientData), assertion);
    if (refused) return out.refuse(refused);
    return out.json(200, { token: await register(env.DB, keyId, now) });
}

/// Whether this environment takes dev registrations and `given` is its secret, compared in constant time.
async function devRegistration(env: Env, given: string): Promise<boolean> {
    const secret = env.DEV_REGISTRATION_SECRET ?? "";
    if (env.ENVIRONMENT !== "dev" || secret === "") return false;
    return crypto.subtle.timingSafeEqual(await sha256(given), await sha256(secret));
}

async function isEmpty(request: Request): Promise<boolean> {
    try {
        await readCapped(request, 0);
        return true;
    } catch (error) {
        if (error instanceof TooLarge) return false;
        throw error;
    }
}

/// PUT /v1/automations replaces the account's automations with the payload's and answers {digest}, the payload's
/// SHA-256 as lowercase hex, which the phone keeps as the last one the server acknowledged. A payload over one of the
/// document's limits is refused with 422, its code, and a sentence the app shows. There are no usage limits for now
/// (runs a day, automations an account): tasks/phase-3-ai-block.md records why.
async function automations(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    let count = 0;
    const out = responder("automations", () => ({ count }));
    const account = await authenticate(env.DB, request.headers.get("Authorization"));
    if (!account) return out.refuse("bad-token");
    const body = await jsonBody(request, out, MAX_AUTOMATIONS_BODY);
    if (body instanceof Response) return body;
    try {
        const payload = parsePayload(body.value);
        count = payload.automations.length;
        await replaceAutomations(env.DB, account, payload, (deps.now?.() ?? new Date()).getTime());
    } catch (error) {
        if (error instanceof BadRequest) return badRequest(out, error.message);
        if (error instanceof OverLimit) {
            return out.json(422, { error: error.message, code: error.code }, { code: error.code, found: error.found });
        }
        if (error instanceof Conflict) return out.refuse("conflict");
        throw error;
    }
    return out.json(200, { digest: toHex(await sha256(body.bytes)) });
}

/// GET /v1/changes?after=<id> answers the account's changes with ids above `after`, at most PAGE_SIZE, as a page in
/// the wire format.
async function changes(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const out = responder("changes");
    const account = await authenticate(env.DB, request.headers.get("Authorization"));
    if (!account) return out.refuse("bad-token");
    const after = new URL(request.url).searchParams.get("after") ?? "";
    const id = /^(0|[1-9][0-9]{0,15})$/.test(after) ? Number(after) : -1;
    if (id < 0 || id > LARGEST_ID) return badRequest(out, '"after" must be a change id, 0 or more');
    const page = await pull(env.DB, account, id, (deps.now?.() ?? new Date()).getTime());
    return out.encoded(page.body, { count: page.count });
}

/// A JSON body of at most `limit` bytes, with its bytes, or the refusal.
async function jsonBody(
    request: Request,
    out: Responder,
    limit: number,
): Promise<{ value: unknown; bytes: Uint8Array } | Response> {
    if (!isJson(request)) return out.json(415, { error: "send the body as application/json" });
    let bytes: Uint8Array;
    try {
        bytes = await readCapped(request, limit);
    } catch (error) {
        if (error instanceof TooLarge) return out.json(413, { error: `the body is over ${limit} bytes` });
        throw error;
    }
    try {
        return { value: JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)), bytes };
    } catch {
        return badRequest(out, "the body must be a JSON object");
    }
}

/// The attest routes' JSON body with exactly `fields`, or the refusal.
async function attestBody(
    request: Request,
    out: Responder,
    fields: string[],
): Promise<Record<string, unknown> | Response> {
    const parsed = await jsonBody(request, out, MAX_ATTEST_BODY);
    if (parsed instanceof Response) return parsed;
    const body = parsed.value;
    if (typeof body !== "object" || body === null || Array.isArray(body)) {
        return badRequest(out, "the body must be a JSON object");
    }
    const unknown = Object.keys(body)
        .filter((key) => !fields.includes(key))
        .sort();
    if (unknown.length > 0) return badRequest(out, `unknown fields: ${unknown.join(", ")}`);
    return body as Record<string, unknown>;
}

function badRequest(out: Responder, message: string): Response {
    return out.json(400, { error: oneLine(`bad request: ${message}`) });
}

/// The 32 bytes a key id names, if it is exactly the 44-character standard base64 `generateKey()` returns. Only the
/// canonical spelling passes, so one key never has two objects.
export function keyIdBytes(value: string): Uint8Array | null {
    if (value.length !== 44) return null;
    const bytes = fromBase64(value);
    return bytes?.byteLength === 32 && toBase64(bytes) === value ? bytes : null;
}

/// 43 base64url characters: 32 bytes, unpadded.
function isChallenge(value: unknown): value is string {
    if (typeof value !== "string" || value.length !== 43) return false;
    for (const char of value) {
        const ok =
            (char >= "A" && char <= "Z") ||
            (char >= "a" && char <= "z") ||
            (char >= "0" && char <= "9") ||
            char === "-" ||
            char === "_";
        if (!ok) return false;
    }
    return true;
}

function isJson(request: Request): boolean {
    return (request.headers.get("Content-Type") ?? "").split(";")[0]?.trim() === "application/json";
}

/// One line of at most 300 characters, as bridge.py's `one_line` makes it, so an echoed key name or a provider's
/// message can neither break the line nor carry much of a request.
function oneLine(text: string): string {
    const line = text.split(/\s+/).filter(Boolean).join(" ");
    return line.length > 300 ? `${line.slice(0, 299)}…` : line;
}
