import { describe, expect, it } from "vitest";
import invalid from "../../Engine/Evals/testdata/invalid-requests.json";
import requests from "../../Engine/Evals/testdata/requests.json";
import turns from "../../Engine/Evals/testdata/user-turns.json";
import { requestBody } from "../src/model";
import { BadRequest, kindOf, LIMITS, userTurn } from "../src/request";

const openrouter = {
    url: "https://openrouter.test/v1/chat/completions",
    apiKey: "k",
    model: "anthropic/claude-sonnet-5.5",
    provider: "amazon-bedrock",
    reasoning: "",
};
const mantle = { ...openrouter, model: "moonshotai.kimi-k2.5", provider: "" };

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

    it("sends the model the same user turn as model.py", () => {
        for (const [name, request] of Object.entries(requests)) {
            expect(userTurn(request).text, name).toBe(turns[name as keyof typeof turns]);
        }
    });

    it("judges an empty field by Python's whitespace, not JavaScript's", () => {
        expect(() => userTurn({ words: "\u0085\u001c" })).toThrow('"words" must be a non-empty string');
        expect(() => userTurn({ words: "\ufeff" })).not.toThrow();
    });

    it("names each request's kind", () => {
        expect(kindOf(requests.create)).toBe("create");
        expect(kindOf(requests["create-image"])).toBe("create");
        expect(kindOf(requests.refine)).toBe("refine");
        expect(kindOf(requests.repair)).toBe("repair");
        expect(kindOf(requests["refine-repair"])).toBe("repair");
        expect(kindOf([])).toBe("-");
    });

    it("takes base64 as strictly as Python's decoder", () => {
        const picture = (base64: string) => () => userTurn({ words: "a", image: { mime: "image/png", base64 } });
        for (const good of ["AAAA", "AA==", "AAA=", "ab+/"]) expect(picture(good), good).not.toThrow();
        for (const bad of ["AAA", "A===", "AA AA", "AAAA\n", "AA=A", "AA-_"]) {
            expect(picture(bad), bad).toThrow('"image" must hold "base64" image data');
        }
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
    it("caches the system prompt, and on OpenRouter pins one provider and asks for usage", () => {
        const body = requestBody(openrouter, "SYSTEM", userTurn(requests.create));
        expect(body.messages[0]).toEqual({
            role: "system",
            content: [{ type: "text", text: "SYSTEM", cache_control: { type: "ephemeral" } }],
        });
        expect(body.provider).toEqual({ order: ["amazon-bedrock"], allow_fallbacks: false });
        expect(body.usage).toEqual({ include: true });
        expect(body.max_tokens).toBe(16_000);
        expect(body).not.toHaveProperty("reasoning");
    });

    it("sends no OpenRouter fields to an endpoint that serves the model itself", () => {
        const body = requestBody(mantle, "SYSTEM", userTurn(requests.create));
        expect(body.model).toBe("moonshotai.kimi-k2.5");
        expect(body).not.toHaveProperty("provider");
        expect(body).not.toHaveProperty("usage");
    });

    it("turns thinking off, sets its effort, or leaves it to the model", () => {
        const turn = userTurn(requests.create);
        expect(requestBody({ ...openrouter, reasoning: "off" }, "S", turn).reasoning).toEqual({ enabled: false });
        expect(requestBody({ ...openrouter, reasoning: "low" }, "S", turn).reasoning).toEqual({ effort: "low" });
        expect(requestBody(openrouter, "S", turn)).not.toHaveProperty("reasoning");
    });

    it("sends a picture as a data URL before the words", () => {
        const request = requests["create-image"];
        const body = requestBody(mantle, "SYSTEM", userTurn(request));
        expect(body.messages[1]?.content).toEqual([
            { type: "image_url", image_url: { url: `data:${request.image.mime};base64,${request.image.base64}` } },
            { type: "text", text: request.words },
        ]);
    });
});
