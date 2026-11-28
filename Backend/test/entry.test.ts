import { describe, expect, it } from "vitest";
import * as entry from "../src/index";

describe("the entry module", () => {
    // workerd takes every export of the main module as an entrypoint and refuses to start (wrangler dev 4.166 does)
    // on one that is not a handler, a function, or a class, such as a constant.
    it("exports only the handlers, functions, and classes workerd can start with", () => {
        for (const [name, value] of Object.entries(entry)) {
            const startable = typeof value === "function" || (name === "default" && typeof value === "object");
            expect(startable, name).toBe(true);
        }
    });
});
