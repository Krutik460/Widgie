// The Worker's bindings, merged into the runtime's `Cloudflare.Env` so `env` from cloudflare:workers is typed.
declare namespace Cloudflare {
    interface Env {
        ASSETS: Fetcher;
        DB: D1Database;
        SIGNUP_LIMIT: RateLimit;
        /// The public origin, with no trailing slash. Every link in an email starts with it.
        SITE_URL: string;
        EMAIL_FROM: string;
        REPLY_TO: string;
        TURNSTILE_SECRET: string;
        RESEND_API_KEY: string;
        LINK_SECRET: string;
    }
}
