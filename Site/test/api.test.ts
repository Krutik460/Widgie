import { env } from "cloudflare:workers";
import { describe, expect, it, vi } from "vitest";
import { sign } from "../src/links";
import { handle, parseSignup, RESEND_AFTER_MS } from "../src/site";

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

function services(options: { human?: boolean; mailStatus?: number; mailThrows?: boolean } = {}) {
    const sent: Sent[] = [];
    const fetcher = vi.fn<typeof fetch>(async (input, init) => {
        const url = String(input);
        if (url.startsWith("https://challenges.cloudflare.com/")) {
            return Response.json({ success: options.human ?? true });
        }
        if (url === "https://api.resend.com/emails") {
            if (options.mailThrows) throw new TypeError("network connection lost");
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
        idea: string | null;
        source: string | null;
        sent_at: string;
        confirmed_at: string | null;
    }>();
}

/// Signs up and follows the confirmation link; returns where the link sent the person.
async function confirmed(s: Services, body: Record<string, unknown>) {
    const response = await signUp(s, body);
    expect(response.status).toBe(200);
    const confirm = await handle(new Request(linkIn(s.sent.at(-1), "/confirm")), env, s.deps);
    expect(confirm.status).toBe(303);
    return confirm.headers.get("Location");
}

describe("parseSignup", () => {
    const valid = { email: " Me@Example.com ", segment: "partners", turnstile: "t" };

    it("cleans a valid body and ignores anything else, such as an old idea field", () => {
        expect(parseSignup({ ...valid, idea: "  dog fed  ", source: "TikTok" })).toEqual({
            email: "me@example.com",
            segment: "partners",
            source: "tiktok",
            turnstile: "t",
        });
    });

    it("treats a body without a segment as a signup for anyone", () => {
        expect(parseSignup({ email: "me@example.com", turnstile: "t" })).toMatchObject({ segment: "any" });
        expect(parseSignup({ ...valid, segment: "" })).toMatchObject({ segment: "any" });
    });

    it.each([
        [{ ...valid, email: "nope" }, "that email doesn't look right"],
        [{ ...valid, email: "a@b" }, "that email doesn't look right"],
        [{ ...valid, segment: "aesthetic" }, "pick partners or growth"],
        [{ ...valid, segment: "home" }, "pick partners or growth"],
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
        const response = await signUp(s, { email, segment: "growth", idea: "not stored", source: "tiktok" });

        expect(await response.json()).toEqual({ ok: true });
        expect(s.sent).toHaveLength(1);
        expect(s.sent[0]?.to).toEqual([email]);
        expect(s.sent[0]?.subject).toBe("Confirm your spot on the Widgie list");
        expect(s.sent[0]?.headers["List-Unsubscribe"]).toMatch(/^<https:\/\/widgie\.krutikpatel\.dev\/api\/leave\?/);
        expect(await row(email)).toMatchObject({
            segment: "growth",
            idea: null,
            source: "tiktok",
            confirmed_at: null,
        });
    });

    it("takes an email alone from the home page, and the confirm link lands on /confirmed", async () => {
        const s = services();
        const { email } = fresh();
        expect(await confirmed(s, { email })).toBe(`${SITE}/confirmed`);
        expect(await row(email)).toMatchObject({ segment: "any", idea: null });
        expect(s.sent[0]?.text).not.toMatch(/invite|share/i);
    });

    it("refuses when Turnstile says no, and stores nothing", async () => {
        const s = services({ human: false });
        const { email } = fresh();
        const response = await signUp(s, { email, segment: "partners" });
        expect(response.status).toBe(403);
        expect(s.sent).toHaveLength(0);
        expect(await row(email)).toBeNull();
    });

    it("takes the row back when the email cannot be sent, so a retry works", async () => {
        const failing = services({ mailStatus: 500 });
        const { email } = fresh();
        expect((await signUp(failing, { email, segment: "partners" })).status).toBe(500);
        expect(await row(email)).toBeNull();

        const working = services();
        expect((await signUp(working, { email, segment: "partners" })).status).toBe(200);
        expect(working.sent).toHaveLength(1);
    });

    it("answers the same for a repeat, and sends a reminder only after the wait", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "partners" });

        expect(await (await signUp(s, { email, segment: "partners" })).json()).toEqual({ ok: true });
        expect(s.sent).toHaveLength(1);

        s.advance(RESEND_AFTER_MS + 1000);
        await signUp(s, { email, segment: "partners" });
        expect(s.sent).toHaveLength(2);
        expect(s.sent[1]?.subject).toBe("Confirm your spot on the Widgie list");
    });

    it("sends a confirmed person a plain note instead of a second confirmation", async () => {
        const s = services();
        const { email } = fresh();
        await confirmed(s, { email, segment: "partners" });

        s.advance(RESEND_AFTER_MS + 1000);
        expect(await (await signUp(s, { email, segment: "partners" })).json()).toEqual({ ok: true });
        const note = s.sent.at(-1);
        expect(note?.subject).toBe("You're on the Widgie list");
        expect(note?.text).toContain("already on the Widgie early list");
        expect(note?.text).not.toContain("/confirm");
    });

    it("takes the row back when sending throws, not only when Resend refuses", async () => {
        const { email } = fresh();
        expect((await signUp(services({ mailThrows: true }), { email, segment: "growth" })).status).toBe(500);
        expect(await row(email)).toBeNull();
    });

    it("keeps the reminder window open when a reminder fails to send", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "partners" });

        const failing = services({ mailStatus: 500 });
        failing.advance(RESEND_AFTER_MS + 1000);
        expect((await signUp(failing, { email, segment: "partners" })).status).toBe(500);
        expect((await row(email))?.sent_at).toBe("2026-11-23T12:00:00.000Z");

        s.advance(RESEND_AFTER_MS + 2000);
        await signUp(s, { email, segment: "partners" });
        expect(s.sent).toHaveLength(2);
    });

    it("rate-limits one address", async () => {
        const s = services();
        const { ip } = fresh();
        const statuses = [];
        for (let i = 0; i < 6; i++)
            statuses.push((await signUp(s, { email: fresh().email, segment: "partners" }, ip)).status);
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

describe("GET /confirm", () => {
    it("is idempotent", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "partners" });
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
        await signUp(s, { email, segment: "partners" });
        const id = (await row(email))?.id ?? 0;
        for (const t of ["0".repeat(64), await sign("test-link-secret", "leave", id, email), "zz"]) {
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
        await signUp(s, { email, segment: "growth" });
        const oneClick = s.sent[0]?.headers["List-Unsubscribe"]?.slice(1, -1) ?? "";
        const id = (await row(email))?.id ?? 0;

        const forged = `${SITE}/api/leave?id=${id}&t=${await sign("test-link-secret", "confirm", id, email)}`;
        expect((await handle(new Request(forged, { method: "POST" }), env, s.deps)).status).toBe(403);
        expect(await row(email)).not.toBeNull();

        expect((await handle(new Request(oneClick, { method: "POST" }), env, s.deps)).status).toBe(200);
        expect(await row(email)).toBeNull();
    });
});

describe("signed links after a row is gone", () => {
    it("never confirm or delete the next person who gets the same id", async () => {
        const s = services();
        const first = fresh();
        await signUp(s, { email: first.email, segment: "partners" });
        const oldConfirm = linkIn(s.sent.at(-1), "/confirm");
        const oldLeave = s.sent.at(-1)?.headers["List-Unsubscribe"]?.slice(1, -1) ?? "";
        const firstId = (await row(first.email))?.id;
        expect((await handle(new Request(oldLeave, { method: "POST" }), env, s.deps)).status).toBe(200);

        const second = fresh();
        await signUp(s, { email: second.email, segment: "growth" });
        expect((await row(second.email))?.id).toBe(firstId);

        const confirm = await handle(new Request(oldConfirm), env, s.deps);
        expect(confirm.headers.get("Location")).toBe(`${SITE}/link-expired`);
        expect((await row(second.email))?.confirmed_at).toBeNull();
        expect((await handle(new Request(oldLeave, { method: "POST" }), env, s.deps)).status).toBe(403);
        expect(await row(second.email)).not.toBeNull();
    });

    it("lets leave be pressed twice", async () => {
        const s = services();
        const { email } = fresh();
        await signUp(s, { email, segment: "growth" });
        const oneClick = s.sent[0]?.headers["List-Unsubscribe"]?.slice(1, -1) ?? "";
        expect((await handle(new Request(oneClick, { method: "POST" }), env, s.deps)).status).toBe(200);
        expect((await handle(new Request(oneClick, { method: "POST" }), env, s.deps)).status).toBe(200);
    });
});

describe("pages", () => {
    it("serves the confirmed page", async () => {
        const page = await handle(new Request(`${SITE}/confirmed`), env, services().deps);
        expect(page.status).toBe(200);
        expect(await page.text()).toContain("You're on the list.");
    });

    it("no longer answers the pair API", async () => {
        const response = await handle(new Request(`${SITE}/api/pair/abcdefghjk`), env, services().deps);
        expect(response.status).toBe(404);
    });

    it("answers unknown API routes with JSON 404", async () => {
        const response = await handle(new Request(`${SITE}/api/nothing`), env, services().deps);
        expect(response.status).toBe(404);
        expect(await response.json()).toEqual({ error: "not found" });
    });
});
