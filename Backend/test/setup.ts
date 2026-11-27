// Brings the local D1 database to the checked-in schema before each test file. Applying is idempotent.

import { applyD1Migrations } from "cloudflare:test";
import { env } from "cloudflare:workers";

declare global {
    namespace Cloudflare {
        interface Env {
            /// The migrations vitest.config.ts read from migrations/.
            TEST_MIGRATIONS: import("cloudflare:test").D1Migration[];
        }
    }
}

await applyD1Migrations(env.DB, env.TEST_MIGRATIONS);
