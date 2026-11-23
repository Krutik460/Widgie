import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
    const migrations = await readD1Migrations("./migrations");
    return {
        plugins: [
            cloudflareTest({
                wrangler: { configPath: "./wrangler.jsonc" },
                miniflare: {
                    bindings: {
                        TEST_MIGRATIONS: migrations,
                        SITE_URL: "https://widgie.krutikpatel.dev",
                        LINK_SECRET: "test-link-secret",
                        TURNSTILE_SECRET: "test-turnstile",
                        RESEND_API_KEY: "re_test",
                    },
                },
            }),
        ],
        test: { setupFiles: ["./test/setup.ts"] },
    };
});
