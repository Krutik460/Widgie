import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
    plugins: [
        cloudflareTest({
            wrangler: { configPath: "./wrangler.jsonc" },
            // A quota of 2 so the tests reach it in three calls; quotaPerDay's own test covers the default of 40.
            miniflare: { bindings: { MODEL_API_KEY: "test-key", QUOTA_PER_DAY: "2" } },
        }),
    ],
});
