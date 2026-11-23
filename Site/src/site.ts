// The early access site. Static pages come from public/; the Worker runs first only for the routes below.
//
//   POST /api/signup   {email, segment, idea?, source?, pair?, turnstile} -> {ok: true}, the same answer whether the
//                      email is new, pending or confirmed, so the form never reveals who is on the list.
//   GET  /api/pair/:c  -> {segment, members}: confirmed people in that pair, for the join and share pages.
//   GET  /confirm      ?id&t -> marks the row confirmed and redirects to its share page.
//   POST /api/leave    ?id&t -> deletes the row. The leave page posts here, and so do mail clients (List-Unsubscribe).
//   GET  /p/:code      -> the join page for a pair, served from public/p.html.
//
// Logs are one line per API request with the route, status and time. Never an email address or an idea.

import { alreadyInMail, confirmMail, type Leave, type Segment, send } from "./email";
import { PAIR_CODE, pairCode, sign, verify } from "./links";

export type Env = Cloudflare.Env;

export interface Dependencies {
    fetch: typeof fetch;
    now: () => Date;
}

/// A home can be a big family; a couple plus a close friend or two still fits. Joins past this start their own pair.
export const MAX_PAIR = 8;
/// A second confirmation email for the same address waits this long, so the form cannot be used to flood an inbox.
export const RESEND_AFTER_MS = 10 * 60 * 1000;
const MAX_IDEA = 500;
const MAX_SOURCE = 40;
const MAX_BODY = 4096;
const EMAIL = /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/;

export async function handle(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const url = new URL(request.url);
    const { pathname } = url;
    const method = request.method;

    if (pathname.startsWith("/p/") && method === "GET") {
        return PAIR_CODE.test(pathname.slice(3)) ? env.ASSETS.fetch(new URL("/p", url)) : notFound(env, url);
    }
    if (pathname === "/confirm" && method === "GET") return logged("confirm", () => confirm(url, env, deps));
    if (pathname === "/api/signup" && method === "POST") return logged("signup", () => signup(request, env, deps));
    if (pathname === "/api/leave" && method === "POST") return logged("leave", () => leave(url, env));
    if (pathname.startsWith("/api/pair/") && method === "GET")
        return logged("pair", () => pair(pathname.slice(10), env));
    if (pathname.startsWith("/api/")) return Response.json({ error: "not found" }, { status: 404 });
    return env.ASSETS.fetch(request);
}

async function logged(route: string, run: () => Promise<Response>): Promise<Response> {
    const started = Date.now();
    let response: Response;
    let failure: string | undefined;
    try {
        response = await run();
    } catch (error) {
        failure = error instanceof Error ? error.message.split("\n")[0] : "unknown";
        response = Response.json({ error: "something went wrong, try again" }, { status: 500 });
    }
    console.log(JSON.stringify({ route, status: response.status, ms: Date.now() - started, failure }));
    return response;
}

async function notFound(env: Env, url: URL) {
    const page = await env.ASSETS.fetch(new URL("/404", url));
    return new Response(page.body, { status: 404, headers: page.headers });
}

function refuse(status: number, error: string) {
    return Response.json({ error }, { status });
}

interface SignupBody {
    email: string;
    segment: Segment;
    idea: string | null;
    source: string | null;
    pair: string | null;
    turnstile: string;
}

/// Checks shape and size only; returns the cleaned body or the one line to show the person.
export function parseSignup(raw: unknown): SignupBody | string {
    if (typeof raw !== "object" || raw === null) return "send a JSON object";
    const body = raw as Record<string, unknown>;
    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    if (email.length > 254 || !EMAIL.test(email)) return "that email doesn't look right";
    if (body.segment !== "partners" && body.segment !== "growth") return "pick partners or growth";
    const idea = typeof body.idea === "string" ? body.idea.trim() : "";
    if (idea.length > MAX_IDEA) return `keep the idea under ${MAX_IDEA} characters`;
    const source = typeof body.source === "string" ? body.source.trim().toLowerCase().slice(0, MAX_SOURCE) : "";
    const pair = typeof body.pair === "string" && body.pair !== "" ? body.pair : null;
    if (pair !== null && !PAIR_CODE.test(pair)) return "that invite link is not valid";
    if (typeof body.turnstile !== "string" || body.turnstile === "") return "the check didn't load, reload the page";
    return {
        email,
        segment: body.segment,
        idea: idea || null,
        source: source || null,
        pair,
        turnstile: body.turnstile,
    };
}

async function signup(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const address = request.headers.get("CF-Connecting-IP") ?? "unknown";
    if (!(await env.SIGNUP_LIMIT.limit({ key: address })).success) {
        return refuse(429, "too many tries, wait a minute");
    }
    const text = await request.text();
    if (text.length > MAX_BODY) return refuse(413, "that's too long");
    let raw: unknown;
    try {
        raw = JSON.parse(text);
    } catch {
        return refuse(400, "send a JSON object");
    }
    const body = parseSignup(raw);
    if (typeof body === "string") return refuse(400, body);
    if (!(await humanCheck(body.turnstile, address, env, deps)))
        return refuse(403, "the check failed, reload the page");

    const now = deps.now();
    const stamp = now.toISOString();

    // Joining a pair takes its segment and code. A pair that does not exist yet, or is full, starts a new one.
    let segment = body.segment;
    let code = pairCode();
    let viaLink = 0;
    if (body.pair) {
        const found = await pairInfo(body.pair, env);
        if (found && found.members < MAX_PAIR) {
            segment = found.segment;
            code = body.pair;
            viaLink = 1;
        }
    }

    const inserted = await env.DB.prepare(
        `INSERT INTO signups (email, segment, pair_code, joined_via_link, idea, source, created_at, sent_at)
         VALUES (?, ?, ?, ?, ?, ?, ?, ?) ON CONFLICT (email) DO NOTHING RETURNING id`,
    )
        .bind(body.email, segment, code, viaLink, body.idea, body.source, stamp, stamp)
        .first<{ id: number }>();

    if (inserted) {
        const mail = confirmMail(
            body.email,
            segment,
            viaLink === 1,
            await confirmUrl(env, inserted.id),
            await leaveLinks(env, inserted.id),
        );
        try {
            await send(env, deps.fetch, mail);
        } catch (error) {
            // Without the email the row can never be confirmed, so take it back and let the person try again.
            await env.DB.prepare("DELETE FROM signups WHERE id = ?").bind(inserted.id).run();
            throw error;
        }
        return Response.json({ ok: true });
    }

    // Already on the list. Remind them, at most once per RESEND_AFTER_MS, and answer exactly as for a new email.
    const cutoff = new Date(now.getTime() - RESEND_AFTER_MS).toISOString();
    const existing = await env.DB.prepare(
        "UPDATE signups SET sent_at = ? WHERE email = ? AND sent_at < ? RETURNING id, segment, pair_code, joined_via_link, confirmed_at",
    )
        .bind(stamp, body.email, cutoff)
        .first<{
            id: number;
            segment: Segment;
            pair_code: string;
            joined_via_link: number;
            confirmed_at: string | null;
        }>();
    if (existing) {
        const leave = await leaveLinks(env, existing.id);
        const mail = existing.confirmed_at
            ? alreadyInMail(body.email, existing.segment, `${env.SITE_URL}/p/${existing.pair_code}?joined=1`, leave)
            : confirmMail(
                  body.email,
                  existing.segment,
                  existing.joined_via_link === 1,
                  await confirmUrl(env, existing.id),
                  leave,
              );
        await send(env, deps.fetch, mail);
    }
    return Response.json({ ok: true });
}

async function humanCheck(token: string, address: string, env: Env, deps: Dependencies): Promise<boolean> {
    const form = new FormData();
    form.append("secret", env.TURNSTILE_SECRET);
    form.append("response", token);
    if (address !== "unknown") form.append("remoteip", address);
    const response = await deps.fetch("https://challenges.cloudflare.com/turnstile/v0/siteverify", {
        method: "POST",
        body: form,
    });
    if (!response.ok) throw new Error(`turnstile answered ${response.status}`);
    const outcome = await response.json<{ success: boolean }>();
    return outcome.success === true;
}

async function confirmUrl(env: Env, id: number) {
    return `${env.SITE_URL}/confirm?id=${id}&t=${await sign(env.LINK_SECRET, "confirm", id)}`;
}

async function leaveLinks(env: Env, id: number): Promise<Leave> {
    const query = `id=${id}&t=${await sign(env.LINK_SECRET, "leave", id)}`;
    return { page: `${env.SITE_URL}/leave?${query}`, oneClick: `${env.SITE_URL}/api/leave?${query}` };
}

/// The id and signature from a link, or null when either is missing or the signature does not match.
async function signedId(url: URL, env: Env, purpose: "confirm" | "leave"): Promise<number | null> {
    const id = Number(url.searchParams.get("id"));
    const signature = url.searchParams.get("t") ?? "";
    if (!Number.isSafeInteger(id) || id <= 0) return null;
    return (await verify(env.LINK_SECRET, purpose, id, signature)) ? id : null;
}

/// Idempotent, because mail scanners often open links before the person does.
async function confirm(url: URL, env: Env, deps: Dependencies): Promise<Response> {
    const id = await signedId(url, env, "confirm");
    const row =
        id === null
            ? null
            : await env.DB.prepare(
                  "UPDATE signups SET confirmed_at = COALESCE(confirmed_at, ?) WHERE id = ? RETURNING pair_code",
              )
                  .bind(deps.now().toISOString(), id)
                  .first<{ pair_code: string }>();
    if (!row) return Response.redirect(`${env.SITE_URL}/link-expired`, 303);
    return Response.redirect(`${env.SITE_URL}/p/${row.pair_code}?joined=1`, 303);
}

async function leave(url: URL, env: Env): Promise<Response> {
    const id = await signedId(url, env, "leave");
    if (id === null) return refuse(403, "that link is not valid");
    await env.DB.prepare("DELETE FROM signups WHERE id = ?").bind(id).run();
    return Response.json({ ok: true });
}

async function pairInfo(code: string, env: Env): Promise<{ segment: Segment; members: number } | null> {
    const row = await env.DB.prepare(
        "SELECT MIN(segment) AS segment, COUNT(confirmed_at) AS members FROM signups WHERE pair_code = ?",
    )
        .bind(code)
        .first<{ segment: Segment | null; members: number }>();
    return row?.segment && row.members > 0 ? { segment: row.segment, members: row.members } : null;
}

async function pair(code: string, env: Env): Promise<Response> {
    if (!PAIR_CODE.test(code)) return refuse(404, "no such invite");
    const found = await pairInfo(code, env);
    if (!found) return refuse(404, "no such invite");
    return Response.json(found, { headers: { "Cache-Control": "no-store" } });
}
