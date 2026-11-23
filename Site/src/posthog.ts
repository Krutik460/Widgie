// The list's own PostHog events (joined, confirmed, left), sent from the server, which no blocker can hide. The browser
// SDK reaches PostHog through its managed proxy at hop.widgie.krutikpatel.dev instead (public/tally.js), so its
// traffic never counts against this Worker's requests.
//
// Never send an email address to PostHog.

const API_HOST = "https://us.i.posthog.com";

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
