// One model call to an OpenAI-compatible chat completions endpoint: Bedrock Mantle on the user's AWS account, or
// OpenRouter. The build prompt goes as a cached system message, then one user turn. Phase 3's scheduler calls this
// too, so it knows nothing about HTTP routes.

import type { UserTurn } from "./request";

export interface ModelSettings {
    /// The chat completions URL.
    url: string;
    apiKey: string;
    model: string;
    /// OpenRouter only: the one provider every call goes to. Empty for an endpoint that serves the model itself.
    provider: string;
    /// "off" turns the model's thinking off, "low", "medium", or "high" sets its effort, and empty sends nothing,
    /// for a model that does not think unless asked.
    reasoning: string;
}

export interface Usage {
    input_tokens: number;
    cached_tokens: number;
    output_tokens: number;
    cost_usd: number | null;
}

export interface ModelReply {
    text: string;
    model: string;
    provider: string;
    usage: Usage;
}

/// A failed call. `reason` is for the log only; the app gets a fixed line.
export class ModelFailure extends Error {
    constructor(readonly reason: string) {
        super(reason);
    }
}

export const MAX_TOKENS = 16_000;
/// Under the app's 120 s request timeout, so the app always gets the Worker's answer instead of its own timeout.
export const DEADLINE_MS = 95_000;

export function requestBody(settings: ModelSettings, system: string, turn: UserTurn) {
    const content: object[] = [];
    if (turn.image) {
        content.push({ type: "image_url", image_url: { url: `data:${turn.image.mime};base64,${turn.image.base64}` } });
    }
    content.push({ type: "text", text: turn.text });
    return {
        model: settings.model,
        max_tokens: MAX_TOKENS,
        // Array form, because cache_control only works on a content part.
        messages: [
            { role: "system", content: [{ type: "text", text: system, cache_control: { type: "ephemeral" } }] },
            { role: "user", content },
        ],
        ...(settings.reasoning && {
            reasoning: settings.reasoning === "off" ? { enabled: false } : { effort: settings.reasoning },
        }),
        // On OpenRouter: one provider and no fallbacks, so every call reads the same prompt cache, and the cost.
        ...(settings.provider && {
            provider: { order: [settings.provider], allow_fallbacks: false },
            usage: { include: true },
        }),
    };
}

export async function callModel(
    settings: ModelSettings,
    system: string,
    turn: UserTurn,
    fetcher: typeof fetch = fetch,
    deadlineMs: number = DEADLINE_MS,
): Promise<ModelReply> {
    const abort = new AbortController();
    const timer = setTimeout(() => abort.abort(), deadlineMs);
    let raw: string;
    let status: number;
    try {
        const response = await fetcher(settings.url, {
            method: "POST",
            headers: { Authorization: `Bearer ${settings.apiKey}`, "Content-Type": "application/json" },
            body: JSON.stringify(requestBody(settings, system, turn)),
            signal: abort.signal,
        });
        status = response.status;
        // The deadline covers the body too: OpenRouter can send its 200 before the model has finished.
        raw = await response.text();
    } catch (error) {
        throw new ModelFailure(
            abort.signal.aborted ? `timed out after ${deadlineMs / 1000} s` : `fetch failed: ${error}`,
        );
    } finally {
        clearTimeout(timer);
    }

    let body: OpenRouterBody;
    try {
        body = JSON.parse(raw);
    } catch {
        throw new ModelFailure(`HTTP ${status} with a body that is not JSON`);
    }
    if (status !== 200 || body.error) {
        throw new ModelFailure(`HTTP ${status}: ${body.error?.code ?? "no code"} ${body.error?.message ?? ""}`.trim());
    }
    const text = body.choices?.[0]?.message?.content;
    if (typeof text !== "string" || text.trim() === "") throw new ModelFailure("the reply held no text");
    const usage = body.usage;
    return {
        text,
        model: body.model ?? settings.model,
        provider: body.provider ?? "unknown",
        usage: {
            input_tokens: usage?.prompt_tokens ?? 0,
            cached_tokens: usage?.prompt_tokens_details?.cached_tokens ?? 0,
            output_tokens: usage?.completion_tokens ?? 0,
            cost_usd: usage?.cost ?? null,
        },
    };
}

interface OpenRouterBody {
    model?: string;
    provider?: string;
    error?: { code?: number | string; message?: string };
    choices?: { message?: { content?: unknown } }[];
    usage?: {
        prompt_tokens?: number;
        completion_tokens?: number;
        cost?: number;
        prompt_tokens_details?: { cached_tokens?: number };
    };
}
