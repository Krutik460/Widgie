// Accounts, uploads, and pulls as the phone makes them, against `handle` with the local D1.

import { env } from "cloudflare:workers";
import { register } from "../../src/accounts";
import { type Dependencies, type Env, handle } from "../../src/index";

export const NOW = Date.parse("2026-11-27T12:00:00Z");
export const DATASET = "3f6c1d2e-8b4a-4c9e-9d7f-2a1b3c4d5e6f";
export const WIDGET = "6d1f1d8e-2b3f-4a5d-8e6f-1c2d3e4f5a6b";

export function dependencies(now = NOW): Dependencies {
    return {
        fetch: () => {
            throw new Error("no route here calls the model");
        },
        now: () => new Date(now),
    };
}

export async function send(request: Request, options: { now?: number; environment?: Env } = {}) {
    const response = await handle(request, options.environment ?? env, dependencies(options.now));
    const text = await response.text();
    const json = response.headers.get("Content-Type")?.startsWith("application/json");
    return { status: response.status, text, body: (json ? JSON.parse(text) : null) as Record<string, unknown> | null };
}

/// A new account and its token, registered as a dev registration would be.
export async function newAccount(now = NOW): Promise<{ id: string; token: string }> {
    const token = await register(env.DB, null, now);
    return { id: token.slice(0, 36), token };
}

export function upload(token: string, body: unknown): Request {
    return new Request("https://widgie.test/v1/automations", {
        method: "PUT",
        headers: { "Content-Type": "application/json", Authorization: `Bearer ${token}` },
        body: typeof body === "string" ? body : JSON.stringify(body),
    });
}

export function changes(token: string, after: number | string = 0): Request {
    return new Request(`https://widgie.test/v1/changes?after=${after}`, {
        headers: { Authorization: `Bearer ${token}` },
    });
}

export interface Entry {
    widget?: string;
    automation?: string;
    prompt?: string;
    every?: string;
    at?: string;
    on?: string;
    dataset?: string;
    fields?: Record<string, string>;
}

/// One automation as the engine's payload writes it: word of the day at 06:00 unless `entry` says otherwise.
export function automation(entry: Entry = {}): Record<string, unknown> {
    return {
        at: "06:00",
        automation: "daily",
        dataset: DATASET,
        every: "day",
        fields: { definition: "text", word: "text" },
        prompt: "Pick an interesting, real English word.",
        widget: WIDGET,
        ...entry,
    };
}

export function payload(automations: Record<string, unknown>[], timeZone = "America/New_York") {
    return { automations, timeZone };
}
