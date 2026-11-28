// POST /v1/dev/run: one automation run's model calls on `dev`, for the evals in Engine/Evals/automations.py, which
// run them against the real run prompt, schema, and model while the model key stays on the server. It exists only
// where ENVIRONMENT is "dev" and the caller sends DEV_REGISTRATION_SECRET in `X-Widgie-Dev-Secret`; anywhere else, or
// with another secret, it answers 404 as an unknown path does.
//
// The body is {prompt, fields: {id: kind}, timeZone, runAt, recent: [rows]}: the owner's prompt, the table's fields,
// the zone and time (milliseconds) the row appears at, and the dataset's recent rows' text values, newest first, as
// a run reads them back. It runs the consumer's `askRow` (runner.ts), the same turn, reply checks, repeat rule, and
// repair, so at most two model calls and no D1, which keeps it inside Workers Free's CPU and subrequest limits. It
// writes nothing and answers {row, outcome, reason, calls, model, provider, finish, usage, seconds}: `row` holds the
// cells the consumer would write (a date as "YYYY-MM-DD"), or null; `outcome` is "written" or "retry".

import { readCapped, TooLarge } from "./body";
import { sha256 } from "./bytes";
import type { Dependencies, Env } from "./index";
import { modelSettings } from "./model";
import { RECENT_ROWS, type RecentRow } from "./run";
import { askRow, spending } from "./runner";
import { canonicalZone, dayOf } from "./schedule";
import { type Cell, isName, isObject, isoDay, KINDS, type Kind, LARGEST_ID } from "./wire";

/// Far above 60 rows of 16 fields at 300 characters with a 2,000-character prompt.
const MAX_DEV_RUN_BODY = 1024 * 1024;
/// The engine's limit on a table's fields (Spec.swift), which every automation the server runs keeps to.
const MAX_FIELDS = 16;

/// Whether this environment takes the dev secret and `given` is it, compared in constant time. Only `dev` has one;
/// `production` refuses it whatever its secrets hold.
export async function isDevSecret(env: Env, given: string): Promise<boolean> {
    const secret = env.DEV_REGISTRATION_SECRET ?? "";
    if (env.ENVIRONMENT !== "dev" || secret === "") return false;
    return crypto.subtle.timingSafeEqual(await sha256(given), await sha256(secret));
}

class Invalid extends Error {}

interface DevRun {
    prompt: string;
    fields: Record<string, Kind>;
    zone: string;
    runAt: number;
    recent: RecentRow[];
}

export async function devRun(request: Request, env: Env, deps: Dependencies): Promise<Response> {
    const started = Date.now();
    const answer = (status: number, body: object, extra: Record<string, unknown> = {}) => {
        console.log(JSON.stringify({ route: "dev-run", status, ...extra, ms: Date.now() - started }));
        return Response.json(body, { status });
    };
    if (!(await isDevSecret(env, request.headers.get("X-Widgie-Dev-Secret") ?? ""))) {
        return new Response("not found\n", { status: 404 });
    }

    let run: DevRun;
    try {
        const bytes = await readCapped(request, MAX_DEV_RUN_BODY);
        run = parse(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)));
    } catch (error) {
        if (error instanceof TooLarge) return answer(413, { error: `the body is over ${MAX_DEV_RUN_BODY} bytes` });
        if (error instanceof Invalid) return answer(400, { error: `bad request: ${error.message}` });
        if (error instanceof SyntaxError || error instanceof TypeError) {
            return answer(400, { error: "bad request: the body must be a JSON object" });
        }
        throw error;
    }

    const called = Date.now();
    const asked = await askRow(
        modelSettings(env),
        run.fields,
        run.prompt,
        dayOf(run.runAt, run.zone),
        run.recent,
        deps,
    );
    const { calls, model, provider, finish, input_tokens, cached_tokens, output_tokens, cost_usd } = spending(
        asked.replies,
    );
    const outcome = asked.cells ? "written" : "retry";
    const seconds = Math.round((Date.now() - called) / 100) / 10;
    return answer(
        200,
        {
            row: asked.cells ? plain(asked.cells) : null,
            outcome,
            reason: asked.reason ?? null,
            calls,
            model,
            provider,
            finish,
            usage: { input_tokens, cached_tokens, output_tokens, cost_usd },
            seconds,
        },
        { outcome, reason: asked.reason, calls, cost_usd, seconds },
    );
}

function parse(body: unknown): DevRun {
    if (!isObject(body)) throw new Invalid("the body must be a JSON object");
    const { prompt, fields, timeZone, runAt, recent } = body;
    if (typeof prompt !== "string" || prompt.trim() === "") throw new Invalid('"prompt" must be text');
    if (!isObject(fields)) throw new Invalid('"fields" must map field ids to kinds');
    const entries = Object.entries(fields);
    if (entries.length === 0 || entries.length > MAX_FIELDS) {
        throw new Invalid(`"fields" must hold 1 to ${MAX_FIELDS} fields`);
    }
    for (const [id, kind] of entries) {
        if (!isName(id)) throw new Invalid(`field id "${id}" is not an id`);
        if (!KINDS.includes(kind as Kind)) throw new Invalid(`field "${id}" must be one of ${KINDS.join(", ")}`);
    }
    const zone = canonicalZone(timeZone);
    if (zone === null) throw new Invalid('"timeZone" must be an IANA time zone');
    if (typeof runAt !== "number" || !Number.isInteger(runAt) || runAt < 0 || runAt > LARGEST_ID) {
        throw new Invalid('"runAt" must be a time in milliseconds');
    }
    if (!Array.isArray(recent) || recent.length > RECENT_ROWS) {
        throw new Invalid(`"recent" must be a list of at most ${RECENT_ROWS} rows`);
    }
    for (const row of recent) {
        if (!isObject(row) || !Object.values(row).every((value) => typeof value === "string")) {
            throw new Invalid('each of "recent" must map field ids to text');
        }
    }
    return { prompt, fields: fields as Record<string, Kind>, zone, runAt, recent: recent as RecentRow[] };
}

/// The cells as JSON values: a date as its day.
function plain(cells: Record<string, Cell>): Record<string, string | number | boolean> {
    return Object.fromEntries(
        Object.entries(cells).map(([id, cell]) => [id, cell.kind === "date" ? isoDay(cell.value) : cell.value]),
    );
}
