import { cloudflareTest } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig({
    plugins: [
        cloudflareTest({
            wrangler: { configPath: "./wrangler.jsonc" },
            miniflare: { bindings: { MODEL_API_KEY: "test-key", OPERATOR_TOKEN: "test-operator" } },
        }),
    ],
});
