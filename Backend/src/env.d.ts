// The Worker's bindings, merged into the runtime's `Cloudflare.Env` so `env` from cloudflare:workers is typed.
declare namespace Cloudflare {
    interface Env {
        OPENROUTER_API_KEY: string;
        /// Set only on the dev Worker during B1, for Mac tools. Unset means /v1/reply refuses every request.
        OPERATOR_TOKEN?: string;
        MODEL: string;
        PROVIDER: string;
    }
}
