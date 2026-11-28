// The cron's claims and the runner's model calls without a queue or a network: a queue that keeps what it is sent,
// and a model service that answers rows from a script.

import { env } from "cloudflare:workers";
import { vi } from "vitest";
import { claimDue } from "../../src/cron";
import type { ModelSettings } from "../../src/model";
import { type Outcome, type RunMessage, runTask } from "../../src/runner";

export const SETTINGS: ModelSettings = {
    url: "https://openrouter.test/v1/chat/completions",
    apiKey: "k",
    model: "deepseek/deepseek-v4.1-flash-1017",
    provider: "together",
    reasoning: "low",
    structured: true,
};

/// A queue that keeps every message sent to it.
export function fakeQueue() {
    const sent: RunMessage[] = [];
    return {
        sent,
        async sendBatch(messages: MessageSendRequest<RunMessage>[]) {
            for (const message of messages) sent.push(message.body);
        },
    };
}

/// Claims what is due at `now` and answers the messages the cron sent.
export async function claim(now: number): Promise<RunMessage[]> {
    const queue = fakeQueue();
    await claimDue(env.DB, queue, now);
    return queue.sent;
}

/// One OpenRouter answer whose content is `content`, a row as JSON unless it is a string already, and why it stopped.
export function answer(content: unknown, cost = 0.0001, finish = "stop") {
    return new Response(
        JSON.stringify({
            model: SETTINGS.model,
            provider: "Together",
            choices: [
                {
                    message: { content: typeof content === "string" ? content : JSON.stringify(content) },
                    finish_reason: finish,
                },
            ],
            usage: { prompt_tokens: 400, completion_tokens: 60, cost },
        }),
    );
}

/// A model service that answers each call with the next of `replies` (the last one again once they run out): a row,
/// a raw string, or a Response such as a failure.
export function model(...replies: unknown[]) {
    let call = 0;
    return vi.fn<typeof fetch>(async () => {
        const reply = replies[Math.min(call++, replies.length - 1)];
        return reply instanceof Response ? reply.clone() : answer(reply);
    });
}

/// The user turn and the whole request body of each call a fake model service got.
export function sentBodies(fetcher: ReturnType<typeof model>): Record<string, unknown>[] {
    return fetcher.mock.calls.map(([, init]) => JSON.parse(String(init?.body)));
}

export function userTurnOf(body: Record<string, unknown>): string {
    const messages = body.messages as { content: { text: string }[] }[];
    return messages[1]?.content[0]?.text ?? "";
}

/// Runs one message at `now` against `fetcher`.
export function run(message: RunMessage, fetcher: typeof fetch, now: number): Promise<Outcome> {
    return runTask(env.DB, SETTINGS, message, { fetch: fetcher, now: () => now });
}
