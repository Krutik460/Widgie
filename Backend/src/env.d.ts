// The Worker's bindings, merged into the runtime's `Cloudflare.Env` so `env` from cloudflare:workers is typed.
declare namespace Cloudflare {
    interface Env {
        /// The chat completions URL of the model service: Bedrock Mantle or OpenRouter.
        MODEL_URL: string;
        MODEL_API_KEY: string;
        /// Set only on the dev Worker during B1, for Mac tools. Unset means /v1/reply refuses every request.
        OPERATOR_TOKEN?: string;
        MODEL: string;
        /// OpenRouter only: the provider every call is pinned to. Empty for Bedrock Mantle.
        PROVIDER: string;
        /// "off", "low", "medium", "high", or empty to send no reasoning setting.
        REASONING: string;
    }
}
