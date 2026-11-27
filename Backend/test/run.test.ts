import { describe, expect, it } from "vitest";
import { checkRepeats, Refused, readReply, replySchema, runTurn, TEXT_LIMIT } from "../src/run";
import { dayIndex, type Kind } from "../src/wire";

const WORDS: Record<string, Kind> = { definition: "text", kind: "text", word: "text" };
const ALL: Record<string, Kind> = { done: "bool", due: "date", score: "number", title: "text" };

/// The code and line `run` is refused with.
function refusal(run: () => unknown): [string, string] | null {
    try {
        run();
        return null;
    } catch (error) {
        if (error instanceof Refused) return [error.code, error.line];
        throw error;
    }
}

describe("a reply", () => {
    it("is read as the table's cells, each of its kind, text trimmed, and keys the table lacks left out", () => {
        const reply = JSON.stringify({ done: false, due: "2028-02-29", score: -3, title: " Pay rent ", extra: "x" });
        expect(readReply(reply, ALL)).toEqual({
            done: { kind: "bool", value: false },
            due: { kind: "date", value: dayIndex(2028, 2, 29) },
            score: { kind: "number", value: -3 },
            title: { kind: "text", value: "Pay rent" },
        });
    });

    it("may come in a code fence, for a model that adds one without structured output", () => {
        expect(readReply('```json\n{"title": "a", "done": true, "due": "2026-01-01", "score": 1}\n```', ALL)).toEqual(
            readReply('{"title": "a", "done": true, "due": "2026-01-01", "score": 1}', ALL),
        );
    });

    it("is refused, with a line for the model and a code for the log, when it is not the table's row", () => {
        const good = { done: true, due: "2026-01-01", score: 1, title: "a" };
        const cases: [string, [string, string]][] = [
            ["not json", ["json", "the reply must be one JSON object with the table's fields, and nothing else"]],
            ["[1, 2]", ["json", "the reply must be one JSON object with the table's fields, and nothing else"]],
            ["null", ["json", "the reply must be one JSON object with the table's fields, and nothing else"]],
            [JSON.stringify({ ...good, title: undefined }), ["missing", 'the reply has no "title"']],
            [JSON.stringify({ ...good, title: 5 }), ["kind", '"title" must be text']],
            [JSON.stringify({ ...good, score: "12" }), ["kind", '"score" must be a number']],
            [JSON.stringify({ ...good, done: "yes" }), ["kind", '"done" must be true or false']],
            [JSON.stringify({ ...good, due: "2026-02-30" }), ["date", '"due" must be a day like "2026-11-30"']],
            [JSON.stringify({ ...good, due: "0000-01-01" }), ["date", '"due" must be a day like "2026-11-30"']],
            [JSON.stringify({ ...good, due: 20_000 }), ["date", '"due" must be a day like "2026-11-30"']],
            [
                JSON.stringify({ ...good, title: "x".repeat(301) }),
                ["long", '"title" is 301 characters long, and the limit is 300'],
            ],
            // A number past a 64-bit float parses as Infinity, which a cell never holds.
            ['{"done": true, "due": "2026-01-01", "score": 1e400, "title": "a"}', ["kind", '"score" must be a number']],
        ];
        for (const [text, expected] of cases)
            expect(
                refusal(() => readReply(text, ALL)),
                text,
            ).toEqual(expected);
    });

    it("holds text up to 300 UTF-16 units, an emoji counting as 2", () => {
        const fields: Record<string, Kind> = { title: "text" };
        expect(TEXT_LIMIT).toBe(300);
        expect(readReply(JSON.stringify({ title: "x".repeat(300) }), fields).title?.value).toHaveLength(300);
        expect(readReply(JSON.stringify({ title: "😀".repeat(150) }), fields).title?.value).toHaveLength(300);
        expect(refusal(() => readReply(JSON.stringify({ title: `${"😀".repeat(150)}x` }), fields))?.[0]).toBe("long");
    });
});

describe("the repeat check", () => {
    const recent = [
        { word: "Petrichor", kind: "noun", definition: "The smell after rain." },
        { word: "Laconic", kind: "adjective", definition: "Using few words." },
    ];
    const cells = (row: Record<string, string>) => readReply(JSON.stringify(row), WORDS);

    it("refuses the item again: the same text in two fields, ignoring case and space", () => {
        expect(
            refusal(() =>
                checkRepeats(cells({ word: " petrichor", kind: "Noun", definition: "Earthy scent of rain." }), recent),
            ),
        ).toEqual(["repeat", 'it repeats a recent row ("kind": "noun", "word": "Petrichor"); write a different one']);
    });

    it("lets one field repeat when the row has more, so a category can", () => {
        expect(() =>
            checkRepeats(cells({ word: "Sonder", kind: "noun", definition: "A feeling." }), recent),
        ).not.toThrow();
        expect(() =>
            checkRepeats(cells({ word: "Wistful", kind: "adjective", definition: "Full of longing." }), recent),
        ).not.toThrow();
    });

    it("refuses a table's only text when it repeats, and ignores empty text and other kinds", () => {
        const question: Record<string, Kind> = { question: "text" };
        const asked = [{ question: "What made you smile today?" }];
        expect(
            refusal(() => checkRepeats(readReply('{"question": "what made you smile today?"}', question), asked))?.[0],
        ).toBe("repeat");
        // An empty text is not an item: verdict, which the person sets, is left empty in every row.
        const verdict: Record<string, Kind> = { verdict: "text", word: "text" };
        expect(
            refusal(() =>
                checkRepeats(readReply('{"verdict": "", "word": "Sonder"}', verdict), [
                    { verdict: "", word: "Sonder" },
                ]),
            )?.[0],
        ).toBe("repeat");
        expect(() =>
            checkRepeats(readReply('{"verdict": "", "word": "Dulcet"}', verdict), [{ verdict: "", word: "Sonder" }]),
        ).not.toThrow();
        expect(() => checkRepeats(readReply('{"done": true}', { done: "bool" }), [{}])).not.toThrow();
    });
});

describe("the turn", () => {
    it("names the fields and kinds, the owner's prompt, the day, and the recent rows newest first", () => {
        const turn = runTurn(WORDS, "A rare word.", dayIndex(2026, 11, 30), [{ word: "B" }, { word: "A" }]);
        expect(turn.text).toBe(
            [
                "The table's fields:",
                "- definition: text",
                "- kind: text",
                "- word: text",
                "",
                "The owner's prompt:",
                "A rare word.",
                "",
                "The row appears on Monday, 2026-11-30.",
                "",
                "The 2 rows written most recently, newest first. Never repeat one of them:",
                '{"word":"B"}',
                '{"word":"A"}',
            ].join("\n"),
        );
        expect(runTurn(WORDS, "p", 0, [], 'the reply has no "word"').text).toMatch(
            /The row appears on Thursday, 1970-01-01\.\n\nNo rows were written before this one\.\n\nYour last reply was refused: the reply has no "word"\. Reply again with one new row\.$/,
        );
    });

    it("asks for exactly the table's fields in the schema", () => {
        expect(replySchema(ALL)).toEqual({
            name: "row",
            schema: {
                type: "object",
                properties: {
                    done: { type: "boolean" },
                    due: { type: "string", description: "A day, like 2026-11-30" },
                    score: { type: "number" },
                    title: { type: "string" },
                },
                required: ["done", "due", "score", "title"],
                additionalProperties: false,
            },
        });
    });
});
