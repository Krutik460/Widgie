// PostHog, reached only through this Worker, for two jobs:
//
//   1. Forward the browser SDK's requests under /hop, so blockers that know PostHog's own hosts still let visits through.
//   2. Send the list's own events (joined, confirmed, left) from the server, which no blocker can hide.
//
// Never send an email address to PostHog.

export const PROXY_PREFIX = "/hop";
const API_HOST = "https://us.i.posthog.com";
const ASSET_HOST = "https://us-assets.i.posthog.com";

/// Forwards one SDK request. Scripts and remote config come from the assets host, everything else from the API host.
/// Cookies and credentials are dropped both ways (the browser SDK sends none, so PostHog's private API stays out of
/// reach), the body streams through untouched, and PostHog sees the visitor's address rather than this Worker's, so
/// location and bot filtering still work.
export async function forward(request: Request, fetcher: typeof fetch): Promise<Response> {
    const url = new URL(request.url);
    const path = url.pathname.slice(PROXY_PREFIX.length) || "/";
    const host = path.startsWith("/static/") || path.startsWith("/array/") ? ASSET_HOST : API_HOST;
    const headers = new Headers(request.headers);
    headers.delete("cookie");
    headers.delete("authorization");
    headers.set("X-Forwarded-For", request.headers.get("CF-Connecting-IP") ?? "");
    const hasBody = request.method !== "GET" && request.method !== "HEAD";
    const response = await fetcher(`${host}${path}${url.search}`, {
        method: request.method,
        headers,
        body: hasBody ? request.body : null,
        redirect: "manual",
    });
    const answer = new Response(response.body, response);
    answer.headers.delete("set-cookie");
    return answer;
}

export interface ServerEvent {
    event: "waitlist_joined" | "waitlist_confirmed" | "waitlist_left";
    /// The visitor's PostHog id when the form sent one, so the event joins that visitor's own funnel.
    distinctId: string;
    properties: Record<string, string | number | boolean | null>;
}

/// Sends one event to PostHog's capture API. No person profile is made: the visitor stays anonymous.
export async function capture(key: string, fetcher: typeof fetch, now: Date, event: ServerEvent): Promise<void> {
    const response = await fetcher(`${API_HOST}/i/v0/e/`, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
            api_key: key,
            event: event.event,
            distinct_id: event.distinctId,
            timestamp: now.toISOString(),
            // No GeoIP: the only address PostHog would see is this Worker's.
            properties: {
                ...event.properties,
                $process_person_profile: false,
                $geoip_disable: true,
                $lib: "widgie-site",
            },
        }),
    });
    if (!response.ok) throw new Error(`posthog answered ${response.status}`);
}
