import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { sign } from "../src/links";
import { handle, MAX_PAIR, parseSignup, RESEND_AFTER_MS } from "../src/site";

const SITE = "https://widgie.krutikpatel.dev";
let counter = 0;

/// A unique email and client address per call, so tests never share a row or a rate limit bucket.
function fresh() {
    counter += 1;
    return {
        email: `person${counter}-${crypto.randomUUID().slice(0, 8)}@example.com`,
        ip: `10.0.${counter >> 8}.${counter & 255}`,
    };
}

interface Sent {
    to: string[];
    subject: string;
    text: string;
    headers: Record<string, string>;
}

function services(options: { human?: boolean; mailStatus?: number } = {}) {
    const sent: Sent[] = [];
    const fetcher = vi.fn<typeof fetch>(async (input, init) => {
        const url = String(input);
        if (url.startsWith("https://challenges.cloudflare.com/")) {
            return Response.json({ success: options.human ?? true });
        }
        if (url === "https://api.resend.com/emails") {
            sent.push(JSON.parse(String(init?.body)));
            return new Response("{}", { status: options.mailStatus ?? 200 });
        }
        throw new Error(`unexpected fetch ${url}`);
    });
    let clock = new Date("2026-11-23T12:00:00Z");
    return {
        sent,
        fetcher,
        deps: { fetch: fetcher, now: () => clock },
        advance(ms: number) {
            clock = new Date(clock.getTime() + ms);
        },
    };
}

type Services = ReturnType<typeof services>;

function signupRequest(body: Record<string, unknown>, ip: string) {
    return new Request(`${SITE}/api/signup`, {
        method: "POST",
        headers: { "Content-Type": "application/json", "CF-Connecting-IP": ip },
        body: JSON.stringify({ turnstile: "token", ...body }),
    });
}

async function signUp(s: Services, body: Record<string, unknown>, ip = fresh().ip) {
    return handle(signupRequest(body, ip), env, s.deps);
}

function linkIn(mail: Sent | undefined, path: string): string {
    const match = mail?.text.match(new RegExp(`${SITE}${path}[^\\s]*`));
    if (!match) throw new Error(`no ${path} link in mail`);
    return match[0];
}

async function row(email: string) {
    return env.DB.prepare("SELECT * FROM signups WHERE email = ?").bind(email).first<{
        id: number;
        segment: string;
        pair_code: string;
        joined_via_link: number;
        idea: string | null;
        source: string | null;
        confirmed_at: string | null;
    }>();
}

/// Signs up and follows the confirmation link; returns the person's pair code.
async function confirmed(s: Services, body: Record<string, unknown>) {
    const response = await signUp(s, body);
    expect(response.status).toBe(200);
    const confirm = await handle(new Request(linkIn(s.sent.at(-1), "/confirm")), env, s.deps);
    expect(confirm.status).toBe(303);
    const code = new URL(confirm.headers.get("Location") ?? "").pathname.slice(3);
    return code;
}

describe("parseSignup", () => {
    const valid = { email: " Me@Example.com ", segment: "home", turnstile: "t" };

    it("cleans a valid body", () => {
        expect(parseSignup({ ...valid, idea: "  dog fed  ", source: "TikTok" })).toEqual({
            email: "me@example.com",
            segment: "home",
            idea: "dog fed",
            source: "tiktok",
            pair: null,
            turnstile: "t",
        });
    });

    it.each([
        [{ ...valid, email: "nope" }, "that email doesn't look right"],
        [{ ...valid, email: "a@b" }, "that email doesn't look right"],
        [{ ...valid, segment: "aesthetic" }, "pick home or us"],
        [{ ...valid, idea: "x".repeat(501) }, "keep the idea under 500 characters"],
        [{ ...valid, pair: "../../etc" }, "that invite link is not valid"],
        [{ ...valid, turnstile: "" }, "the check didn't load, reload the page"],
        [null, "send a JSON object"],
    ])("refuses %j", (body, line) => {
        expect(parseSignup(body)).toBe(line);
    });
});

describe("POST /api/signup", () => {
    it("stores the row and sends one confirmation email", async () => {
        const s = services();
        const { email } = fresh();
        const response = await signUp(s, { email, segment: "us", idea: "hearts for Alex", source: "tiktok" });

        expect(await response.json()).toEqual({ ok: true });
        expect(s.sent).toHaveLength(1);
        expect(s.sent[0]?.to).toEqual([email]);
        expect(s.sent[0]?.subject).toBe("Confirm your spot on the Widgie list");
        expect(s.sent[0]?.headers["List-Unsubscribe"]).toMatch(/^<https:\/\/widgie\.krutikpatel\.dev\/api\/leave\?/);
        expect(await row(email)).toMatchObject({
            segment: "us",
            idea: "hearts for Alex",
            source: "tiktok",
            confirmed_at: null,
        });
    });

    it("refuses when Turnstile says no, and stores nothing", async () => {
        const s = services({ human: false });
        const { email } = fresh();
        const response = await signUp(s, { email, segment: "home" });
        expect(response.status).toBe(403);
        expect(s.sent).toHaveLength(0);
        expect(await row(email)).toBeNull();
    });

    it("takes the row back when the email cannot be sent, so a retry works", async () => {
        const failing = services({ mailStatus: 500 });
        const { email } = fresh();
        expect((await signUp(failing, { email, segment: "home" })).status).toBe(500);
        expect(await row(email)).toBeNull();

        const working = services();
        expect((await signUp(working, { email, segment: "home" })).status).toBe(200);
        expect(working.sent).toHaveLength(1);
    });

    it("answers the same for a repeat, and sends a reminder only after the wait", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "home" });

        expect(await (await signUp(s, { email, segment: "home" })).json()).toEqual({ ok: true });
        expect(s.sent).toHaveLength(1);

        s.advance(RESEND_AFTER_MS + 1000);
        await signUp(s, { email, segment: "home" });
        expect(s.sent).toHaveLength(2);
        expect(s.sent[1]?.subject).toBe("Confirm your spot on the Widgie list");
    });

    it("sends a confirmed person their share link instead of a second confirmation", async () => {
        const s = services();
        const { email } = fresh();
        const code = await confirmed(s, { email, segment: "home" });

        s.advance(RESEND_AFTER_MS + 1000);
        await signUp(s, { email, segment: "home" });
        expect(s.sent.at(-1)?.subject).toBe("Your Widgie link");
        expect(linkIn(s.sent.at(-1), "/p/")).toBe(`${SITE}/p/${code}?joined=1`);
    });

    it("rate-limits one address", async () => {
        const s = services();
        const { ip } = fresh();
        const statuses = [];
        for (let i = 0; i < 6; i++)
            statuses.push((await signUp(s, { email: fresh().email, segment: "home" }, ip)).status);
        expect(statuses).toEqual([200, 200, 200, 200, 200, 429]);
    });

    it("refuses a body that is not JSON", async () => {
        const request = new Request(`${SITE}/api/signup`, {
            method: "POST",
            headers: { "CF-Connecting-IP": fresh().ip },
            body: "email=x",
        });
        expect((await handle(request, env, services().deps)).status).toBe(400);
    });
});

describe("pairs", () => {
    it("lets a partner join, taking the pair's segment and code", async () => {
        const s = services();
        const founder = fresh();
        const code = await confirmed(s, { email: founder.email, segment: "home" });

        let info = await handle(new Request(`${SITE}/api/pair/${code}`), env, s.deps);
        expect(await info.json()).toEqual({ segment: "home", members: 1 });

        const partner = fresh();
        const joined = await confirmed(s, { email: partner.email, segment: "us", pair: code });
        expect(s.sent.at(-1)?.text).toContain("same group as the person who invited you");
        expect(joined).toBe(code);
        expect(await row(partner.email)).toMatchObject({ segment: "home", pair_code: code, joined_via_link: 1 });

        info = await handle(new Request(`${SITE}/api/pair/${code}`), env, s.deps);
        expect(await info.json()).toEqual({ segment: "home", members: 2 });
    });

    it("does not count a member until they confirm", async () => {
        const s = services();
        const code = await confirmed(s, { email: fresh().email, segment: "us" });
        await signUp(s, { email: fresh().email, segment: "us", pair: code });
        const info = await handle(new Request(`${SITE}/api/pair/${code}`), env, s.deps);
        expect(await info.json()).toEqual({ segment: "us", members: 1 });
    });

    it("starts a new pair when the invite is unknown or the pair is full", async () => {
        const s = services();
        const stranger = fresh();
        await signUp(s, { email: stranger.email, segment: "us", pair: "abcdefghjk" });
        expect(await row(stranger.email)).toMatchObject({ segment: "us", joined_via_link: 0 });
        expect((await row(stranger.email))?.pair_code).not.toBe("abcdefghjk");

        const code = await confirmed(s, { email: fresh().email, segment: "home" });
        for (let i = 1; i < MAX_PAIR; i++) await confirmed(s, { email: fresh().email, segment: "home", pair: code });
        const late = fresh();
        await signUp(s, { email: late.email, segment: "home", pair: code });
        expect((await row(late.email))?.pair_code).not.toBe(code);
    });

    it("answers 404 for a pair nobody confirmed", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "home" });
        const code = (await row(email))?.pair_code;
        expect((await handle(new Request(`${SITE}/api/pair/${code}`), env, s.deps)).status).toBe(404);
        expect((await handle(new Request(`${SITE}/api/pair/nope`), env, s.deps)).status).toBe(404);
    });
});

describe("GET /confirm", () => {
    it("is idempotent", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "home" });
        const link = linkIn(s.sent[0], "/confirm");
        const first = await handle(new Request(link), env, s.deps);
        const stamp = (await row(email))?.confirmed_at;
        s.advance(60_000);
        const second = await handle(new Request(link), env, s.deps);
        expect(second.headers.get("Location")).toBe(first.headers.get("Location"));
        expect((await row(email))?.confirmed_at).toBe(stamp);
    });

    it("refuses a tampered link and a leave signature", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "home" });
        const id = (await row(email))?.id ?? 0;
        for (const t of ["0".repeat(64), await sign("test-link-secret", "leave", id), "zz"]) {
            const response = await handle(new Request(`${SITE}/confirm?id=${id}&t=${t}`), env, s.deps);
            expect(response.headers.get("Location")).toBe(`${SITE}/link-expired`);
        }
        expect((await row(email))?.confirmed_at).toBeNull();
    });
});

describe("POST /api/leave", () => {
    it("deletes the row with a valid link and refuses anything else", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "us" });
        const oneClick = s.sent[0]?.headers["List-Unsubscribe"]?.slice(1, -1) ?? "";
        const id = (await row(email))?.id ?? 0;

        const forged = `${SITE}/api/leave?id=${id}&t=${await sign("test-link-secret", "confirm", id)}`;
        expect((await handle(new Request(forged, { method: "POST" }), env, s.deps)).status).toBe(403);
        expect(await row(email)).not.toBeNull();

        expect((await handle(new Request(oneClick, { method: "POST" }), env, s.deps)).status).toBe(200);
        expect(await row(email)).toBeNull();
    });
});

describe("pages", () => {
    it("serves the join page for any well-formed pair code and 404 otherwise", async () => {
        const s = services();
        const good = await handle(new Request(`${SITE}/p/abcdefghjk`), env, s.deps);
        expect(good.status).toBe(200);
        expect(await good.text()).toContain('id="join-root"');
        expect((await handle(new Request(`${SITE}/p/NOPE`), env, s.deps)).status).toBe(404);
    });

    it("answers unknown API routes with JSON 404", async () => {
        const response = await handle(new Request(`${SITE}/api/nothing`), env, services().deps);
        expect(response.status).toBe(404);
        expect(await response.json()).toEqual({ error: "not found" });
    });
});
