// The Worker's bindings, merged into the runtime's `Cloudflare.Env` so `env` from cloudflare:workers is typed.
declare namespace Cloudflare {
    interface Env {
        /// The chat completions URL of the model service: Bedrock Mantle or OpenRouter.
        MODEL_URL: string;
        MODEL_API_KEY: string;
        MODEL: string;
        /// OpenRouter only: the provider every call is pinned to. Empty for Bedrock Mantle.
        PROVIDER: string;
        /// "off", "low", "medium", "high", or empty to send no reasoning setting.
        REASONING: string;
        /// `<team id>.<bundle id>`: an attestation's and an assertion's rpIdHash is its SHA-256.
        APP_ID: string;
        /// "development" or "production": the App Attest environment whose AAGUID an attestation must carry.
        ATTEST_ENV: string;
        /// One object per App Attest key, named by the key id.
        ATTESTED_KEY: DurableObjectNamespace<import("./attested-key").AttestedKey>;
        /// "dev" or "production". Only "dev" takes DEV_REGISTRATION_SECRET.
        ENVIRONMENT: string;
        /// A secret on `dev` only: the simulator registers an account with it, since it cannot attest.
        DEV_REGISTRATION_SECRET?: string;
        /// The environment's accounts, automations, tasks, and changes (migrations/).
        DB: D1Database;
    }
}
