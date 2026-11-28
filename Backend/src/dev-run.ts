// POST /v1/dev/run: one automation run's model calls on `dev`, for the evals in Engine/Evals/automations.py, which
// run them against the real run prompt, schema, and model while the model key stays on the server. `handle` routes it
// only where ENVIRONMENT is "dev" and the caller sends DEV_REGISTRATION_SECRET in `X-Widgie-Dev-Secret` (index.ts,
// `devRoute`); anywhere else, or with another secret, every method on the path answers 404 as an unknown path does.
//
// The body is {prompt, fields: {id: kind}, timeZone, runAt, recent: [rows]}: the owner's prompt, the table's fields,
// the zone and time (milliseconds) the row appears at, and the dataset's recent rows' text values, newest first, as
// a run reads them back. The prompt and fields pass the upload's own checks (automations.ts), and each recent row
// maps text fields of the table to at most TEXT_LIMIT UTF-16 units, as the consumer's rows do. It runs the consumer's `askRow` (runner.ts), the same turn, reply checks, repeat rule, and
// repair, so at most two model calls and no D1, which keeps it inside Workers Free's CPU and subrequest limits. It
// writes nothing and answers {row, outcome, reason, calls, model, provider, finish, usage, seconds}: `row` holds the
// cells the consumer would write (a date as "YYYY-MM-DD"), or null; `outcome` is "written" or "retry"; `calls` counts
// every call made, and `usage` sums every answer, one cut off with no text included (runner.ts, `Asked`).

import { fieldKinds, OverLimit, promptOf } from "./automations";
import { readCapped, TooLarge } from "./body";
import { sha256 } from "./bytes";
import type { Dependencies, Env } from "./index";
import { modelSettings } from "./model";
import { BadRequest } from "./request";
import { RECENT_ROWS, type RecentRow, TEXT_LIMIT } from "./run";
import { askRow, spending } from "./runner";
import { canonicalZone, dayOf } from "./schedule";
import { type Cell, isObject, isoDay, type Kind, LARGEST_ID } from "./wire";

/// Far above 60 rows of 16 fields at 300 characters with a 2,000-character prompt.
const MAX_DEV_RUN_BODY = 1024 * 1024;
/// The name the upload's checks give the automation in a refusal.
const NAME = "eval";

/// Whether this environment takes the dev secret and `given` is it, compared in constant time. Only `dev` has one;
/// `production` refuses it whatever its secrets hold.
export async function isDevSecret(env: Env, given: string): Promise<boolean> {
    const secret = env.DEV_REGISTRATION_SECRET ?? "";
    if (env.ENVIRONMENT !== "dev" || secret === "") return false;
    return crypto.subtle.timingSafeEqual(await sha256(given), await sha256(secret));
}

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
    let run: DevRun;
    try {
        const bytes = await readCapped(request, MAX_DEV_RUN_BODY);
        run = parse(JSON.parse(new TextDecoder("utf-8", { fatal: true, ignoreBOM: false }).decode(bytes)));
    } catch (error) {
        if (error instanceof TooLarge) return answer(413, { error: `the body is over ${MAX_DEV_RUN_BODY} bytes` });
        if (error instanceof BadRequest || error instanceof OverLimit) {
            return answer(400, { error: `bad request: ${error.message}` });
        }
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
    const { calls, model, provider, finish, input_tokens, cached_tokens, output_tokens, cost_usd } = spending(asked);
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

/// The body, with the prompt and fields checked as an upload checks them, so the eval cannot run what the app could
/// never upload. The fields come back in id order, as the runner reads a task's fields.
function parse(body: unknown): DevRun {
    if (!isObject(body)) throw new BadRequest("the body must be a JSON object");
    const { timeZone, runAt, recent } = body;
    const prompt = promptOf(body.prompt, NAME);
    const fields = fieldKinds(body.fields, NAME);
    const zone = canonicalZone(timeZone);
    if (zone === null) throw new BadRequest('"timeZone" must be an IANA time zone');
    if (typeof runAt !== "number" || !Number.isInteger(runAt) || runAt < 0 || runAt > LARGEST_ID) {
        throw new BadRequest('"runAt" must be a time in milliseconds');
    }
    if (!Array.isArray(recent) || recent.length > RECENT_ROWS) {
        throw new BadRequest(`"recent" must be a list of at most ${RECENT_ROWS} rows`);
    }
    return { prompt, fields, zone, runAt, recent: recent.map((row) => recentRow(row, fields)) };
}

/// A recent row as the consumer reads one back: text fields of the table, each at most TEXT_LIMIT UTF-16 units.
function recentRow(row: unknown, fields: Record<string, Kind>): RecentRow {
    if (!isObject(row)) throw new BadRequest('each of "recent" must map field ids to text');
    for (const [id, value] of Object.entries(row)) {
        if (fields[id] !== "text") throw new BadRequest(`a recent row's "${id}" is not a text field of the table`);
        if (typeof value !== "string") throw new BadRequest(`a recent row's "${id}" must be text`);
        if (value.length > TEXT_LIMIT) {
            throw new BadRequest(`a recent row's "${id}" is over ${TEXT_LIMIT} UTF-16 units`);
        }
    }
    return row as RecentRow;
}

/// The cells as JSON values: a date as its day.
function plain(cells: Record<string, Cell>): Record<string, string | number | boolean> {
    return Object.fromEntries(
        Object.entries(cells).map(([id, cell]) => [id, cell.kind === "date" ? isoDay(cell.value) : cell.value]),
    );
}
