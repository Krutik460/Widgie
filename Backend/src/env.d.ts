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
        /// Model calls per key per UTC day, as a whole number. Unset or empty means 40.
        QUOTA_PER_DAY?: string;
        /// One object per App Attest key, named by the key id.
        ATTESTED_KEY: DurableObjectNamespace<import("./attested-key").AttestedKey>;
        /// Requests per client address on the attest routes.
        ATTEST_LIMIT: RateLimit;
    }
}
