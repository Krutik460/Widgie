import path from "node:path";
import { cloudflareTest, readD1Migrations } from "@cloudflare/vitest-plugin";
import { defineConfig } from "vitest/config";

export default defineConfig(async () => {
    // Read here in Node, applied to the local D1 by test/setup.ts inside workerd.
    const migrations = await readD1Migrations(path.join(import.meta.dirname, "migrations"));
    return {
        plugins: [
            cloudflareTest({
                wrangler: { configPath: "./wrangler.jsonc" },
                // The dev registration secret is set on this production configuration so a test can prove production
                // refuses it.
                miniflare: {
                    bindings: {
                        MODEL_API_KEY: "test-key",
                        DEV_REGISTRATION_SECRET: "dev-secret",
                        TEST_MIGRATIONS: migrations,
                    },
                },
            }),
        ],
        test: { setupFiles: ["./test/setup.ts"] },
    };
});
