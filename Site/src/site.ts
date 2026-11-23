// The early access site. Static pages come from public/; the Worker runs first only for the routes below.
//
//   POST /api/signup   {email, segment?, source?, turnstile} -> {ok: true}, the same answer whether the email is
//                      new, pending or confirmed, so the form never reveals who is on the list.
//   GET  /confirm      ?id&t -> marks the row confirmed and redirects to /confirmed.
//   POST /api/leave    ?id&t -> deletes the row. The leave page posts here, and so do mail clients (List-Unsubscribe).
//
// Logs are one line per API request with the route, status and time. Never an email address.

import { alreadyInMail, confirmMail, type Leave, type Segment, send } from "./email";
import { sign, verify } from "./links";

export type Env = Cloudflare.Env;

export interface Dependencies {
    fetch: typeof fetch;
    now: () => Date;
}

/// A second confirmation email for the same address waits this long, so the form cannot be used to flood an inbox.
export const RESEND_AFTER_MS = 10 * 60 * 1000;
const MAX_SOURCE = 40;
const MAX_BODY = 4096;
const EMAIL = /^[^\s@]+@[^\s@.]+(\.[^\s@.]+)+$/;

export async function handle(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const url = new URL(request.url);
    const { pathname } = url;
    const method = request.method;

    if (pathname === "/confirm" && method === "GET") return logged("confirm", () => confirm(url, env, deps));
    if (pathname === "/api/signup" && method === "POST") return logged("signup", () => signup(request, env, deps));
    if (pathname === "/api/leave" && method === "POST") return logged("leave", () => leave(url, env));
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

function refuse(status: number, error: string) {
    return Response.json({ error }, { status });
}

interface SignupBody {
    email: string;
    segment: Segment;
    source: string | null;
    turnstile: string;
}

/// Checks shape and size only; returns the cleaned body or the one line to show the person.
export function parseSignup(raw: unknown): SignupBody | string {
    if (typeof raw !== "object" || raw === null) return "send a JSON object";
    const body = raw as Record<string, unknown>;
    const email = typeof body.email === "string" ? body.email.trim().toLowerCase() : "";
    if (email.length > 254 || !EMAIL.test(email)) return "that email doesn't look right";
    // An audience page names its segment; the home page sends none, and that signup is for anyone.
    const segment = body.segment === undefined || body.segment === "" ? "any" : body.segment;
    if (segment !== "partners" && segment !== "growth" && segment !== "any") return "pick partners or growth";
    const source = typeof body.source === "string" ? body.source.trim().toLowerCase().slice(0, MAX_SOURCE) : "";
    if (typeof body.turnstile !== "string" || body.turnstile === "") return "the check didn't load, reload the page";
    return {
        email,
        segment,
        source: source || null,
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

    const inserted = await env.DB.prepare(
        `INSERT INTO signups (email, segment, source, created_at, sent_at)
         VALUES (?, ?, ?, ?, ?) ON CONFLICT (email) DO NOTHING RETURNING id`,
    )
        .bind(body.email, body.segment, body.source, stamp, stamp)
        .first<{ id: number }>();

    if (inserted) {
        const mail = confirmMail(
            body.email,
            await confirmUrl(env, inserted.id, body.email),
            await leaveLinks(env, inserted.id, body.email),
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

    // Already on the list. Remind them, at most once per RESEND_AFTER_MS, and answer exactly as for a new email. The
    // send time moves only if it is still the one read here, and moves back if the email fails, so a failed reminder
    // never locks the person out until the next window.
    const existing = await env.DB.prepare("SELECT id, sent_at, confirmed_at FROM signups WHERE email = ?")
        .bind(body.email)
        .first<{ id: number; sent_at: string; confirmed_at: string | null }>();
    const cutoff = new Date(now.getTime() - RESEND_AFTER_MS).toISOString();
    if (existing && existing.sent_at < cutoff) {
        const claimed = await env.DB.prepare("UPDATE signups SET sent_at = ? WHERE id = ? AND sent_at = ? RETURNING id")
            .bind(stamp, existing.id, existing.sent_at)
            .first();
        if (claimed) {
            const leave = await leaveLinks(env, existing.id, body.email);
            const mail = existing.confirmed_at
                ? alreadyInMail(body.email, leave)
                : confirmMail(body.email, await confirmUrl(env, existing.id, body.email), leave);
            try {
                await send(env, deps.fetch, mail);
            } catch (error) {
                await env.DB.prepare("UPDATE signups SET sent_at = ? WHERE id = ? AND sent_at = ?")
                    .bind(existing.sent_at, existing.id, stamp)
                    .run();
                throw error;
            }
        }
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

async function confirmUrl(env: Env, id: number, email: string) {
    return `${env.SITE_URL}/confirm?id=${id}&t=${await sign(env.LINK_SECRET, "confirm", id, email)}`;
}

async function leaveLinks(env: Env, id: number, email: string): Promise<Leave> {
    const query = `id=${id}&t=${await sign(env.LINK_SECRET, "leave", id, email)}`;
    return { page: `${env.SITE_URL}/leave?${query}`, oneClick: `${env.SITE_URL}/api/leave?${query}` };
}

/// What a signed link points at: the row when it exists and the signature matches its id and email, "gone" when no
/// row has that id, and null when the link is malformed or the signature does not match.
async function signedRow(url: URL, env: Env, purpose: "confirm" | "leave"): Promise<number | "gone" | null> {
    const id = Number(url.searchParams.get("id"));
    const signature = url.searchParams.get("t") ?? "";
    if (!Number.isSafeInteger(id) || id <= 0) return null;
    const row = await env.DB.prepare("SELECT email FROM signups WHERE id = ?").bind(id).first<{ email: string }>();
    if (!row) return "gone";
    return (await verify(env.LINK_SECRET, purpose, id, row.email, signature)) ? id : null;
}

/// Idempotent, because mail scanners often open links before the person does.
async function confirm(url: URL, env: Env, deps: Dependencies): Promise<Response> {
    const id = await signedRow(url, env, "confirm");
    if (typeof id !== "number") return Response.redirect(`${env.SITE_URL}/link-expired`, 303);
    await env.DB.prepare("UPDATE signups SET confirmed_at = COALESCE(confirmed_at, ?) WHERE id = ?")
        .bind(deps.now().toISOString(), id)
        .run();
    return Response.redirect(`${env.SITE_URL}/confirmed`, 303);
}

/// A link whose row is already gone answers ok, so pressing leave twice, or unsubscribing after leaving, is not an error.
async function leave(url: URL, env: Env): Promise<Response> {
    const id = await signedRow(url, env, "leave");
    if (id === null) return refuse(403, "that link is not valid");
    if (id !== "gone") await env.DB.prepare("DELETE FROM signups WHERE id = ?").bind(id).run();
    return Response.json({ ok: true });
}
