import { describe, expect, it } from "vitest";
import invalid from "../../Engine/Evals/testdata/invalid-requests.json";
import requests from "../../Engine/Evals/testdata/requests.json";
import { requestBody } from "../src/openrouter";
import { BadRequest, kindOf, LIMITS, userTurn } from "../src/request";

const settings = { apiKey: "k", model: "anthropic/claude-sonnet-5.5", provider: "amazon-bedrock" };

describe("userTurn", () => {
    it("refuses each malformed request with the same line as model.py", () => {
        for (const { request, error } of invalid) {
            expect(() => userTurn(request), JSON.stringify(request)).toThrow(new BadRequest(error));
        }
    });

    it("accepts every request shape the app sends", () => {
        for (const [name, request] of Object.entries(requests)) {
            expect(() => userTurn(request), name).not.toThrow();
        }
    });

    it("sends a create's words alone and a repair's sections in model.py's order", () => {
        expect(userTurn(requests.create).text).toBe(requests.create.words);
        const { text } = userTurn(requests["refine-repair"]);
        const order = [
            "The person's request:",
            "The current document:",
            "Your previous document:",
            "The line from the app:",
            "Reply with the complete corrected document.",
        ].map((heading) => text.indexOf(heading));
        expect(order.every((at, i) => at >= 0 && (i === 0 || at > (order[i - 1] ?? 0)))).toBe(true);
    });

    it("names each request's kind", () => {
        expect(kindOf(requests.create)).toBe("create");
        expect(kindOf(requests["create-image"])).toBe("create");
        expect(kindOf(requests.refine)).toBe("refine");
        expect(kindOf(requests.repair)).toBe("repair");
        expect(kindOf(requests["refine-repair"])).toBe("repair");
        expect(kindOf([])).toBe("-");
    });

    it("refuses a field longer than its limit", () => {
        const long = (n: number) => "a".repeat(n + 1);
        expect(() => userTurn({ words: long(LIMITS.words) })).toThrow(`"words" is longer than ${LIMITS.words}`);
        expect(() => userTurn({ words: "a", current: long(LIMITS.document) })).toThrow('"current" is longer');
        expect(() => userTurn({ words: "a", repair: { document: long(LIMITS.document), line: "x" } })).toThrow(
            '"repair.document" is longer',
        );
        expect(() => userTurn({ words: "a", repair: { document: "{}", line: long(LIMITS.line) } })).toThrow(
            '"repair.line" is longer',
        );
    });
});

describe("requestBody", () => {
    it("caches the system prompt, pins one provider, and asks for usage", () => {
        const body = requestBody(settings, "SYSTEM", userTurn(requests.create));
        expect(body.messages[0]).toEqual({
            role: "system",
            content: [{ type: "text", text: "SYSTEM", cache_control: { type: "ephemeral" } }],
        });
        expect(body.provider).toEqual({ order: ["amazon-bedrock"], allow_fallbacks: false });
        expect(body.usage).toEqual({ include: true });
        expect(body.max_tokens).toBe(16_000);
        expect(body).not.toHaveProperty("reasoning");
    });

    it("sends a picture as a data URL before the words", () => {
        const request = requests["create-image"];
        const body = requestBody(settings, "SYSTEM", userTurn(request));
        expect(body.messages[1]?.content).toEqual([
            { type: "image_url", image_url: { url: `data:${request.image.mime};base64,${request.image.base64}` } },
            { type: "text", text: request.words },
        ]);
    });
});
