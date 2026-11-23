// PostHog on every page: visits, how far people read, what they play with and each signup step, so every post on X,
// Reddit or Product Hunt can be judged by the signups it brings. All requests go through PostHog's managed proxy on our
// own subdomain, so blockers that know PostHog's hosts let most of them through, and none of it costs Worker requests.
// A local dev server sends nothing unless the URL has ?tally.

import { touchOf } from "/channels.js";

const KEY = "phc_Aj3Mbof3qJ2N455cGitXopyyY9dY3B2hbnrTLjJvszKF";
const HOST = "https://hop.widgie.krutikpatel.dev";
const FIRST_TOUCH = "widgie.first";
// Pages reached only from our own emails. They carry signed links (a leave token must never reach analytics), and an
// email client's referrer would credit the wrong channel, so they record nothing. The server counts confirm and leave.
const EMAIL_PAGES = ["/confirmed", "/leave", "/link-expired"];

const emailPage = EMAIL_PAGES.includes(location.pathname);
const local = ["localhost", "127.0.0.1"].includes(location.hostname);
const enabled = (!local || new URLSearchParams(location.search).has("tally")) && !emailPage;

// ---------- Where the visitor came from ----------

/// The first touch that brought this visitor, kept so a signup days later still credits that post. (Safari clears
/// storage a script set after 7 days without a visit, so on iPhones "kept" means about a week.)
function firstTouch() {
    let kept = null;
    try {
        kept = JSON.parse(localStorage.getItem(FIRST_TOUCH) || "null");
    } catch {}
    if (kept) return kept;
    const touch = touchOf(location.search, document.referrer, location.hostname);
    if (touch) {
        try {
            localStorage.setItem(FIRST_TOUCH, JSON.stringify(touch));
        } catch {}
    }
    return touch;
}

const first = emailPage ? null : firstTouch();

// ---------- PostHog ----------

// The SDK script, once loaded, leaves an uninitialized PostHog on window. Events from before that wait here, with the
// time they happened.
let posthog = null;
const waiting = [];

if (enabled) {
    const script = document.createElement("script");
    script.src = `${HOST}/static/array.js`;
    script.async = true;
    script.addEventListener("load", () => {
        posthog = window.posthog;
        posthog.init(KEY, {
            api_host: HOST,
            ui_host: "https://us.posthog.com",
            defaults: "2026-08-30",
            // Visitors stay anonymous: no person profiles, and nothing typed is ever recorded.
            person_profiles: "identified_only",
            session_recording: { maskAllInputs: true },
            // The cookie belongs to this site alone, not every krutikpatel.dev site.
            cross_subdomain_cookie: false,
            // Never let an email or a signed link's parts into a recorded URL.
            mask_personal_data_properties: true,
            custom_personal_data_properties: ["email", "id", "t"],
        });
        // Every event carries the first touch, so any step of the funnel can be split by channel and by post.
        if (first) posthog.register(first);
        for (const [event, properties, timestamp] of waiting.splice(0))
            posthog.capture(event, properties, { timestamp });
    });
    document.head.append(script);
}

/// Sends one named event; a no-op when analytics is off.
export function track(event, properties = {}) {
    if (!enabled) return;
    if (posthog) posthog.capture(event, properties);
    else waiting.push([event, properties, new Date()]);
}

/// What the signup form sends along, so the server's events join this visitor's funnel and credit the right post.
/// Works without PostHog too (blocked or local): the first touch is kept here, not in PostHog.
export function attribution() {
    return {
        source: first?.first_source ?? "",
        medium: first?.first_medium ?? "",
        campaign: first?.first_campaign ?? "",
        content: first?.first_content ?? "",
        referrer: first?.first_referrer ?? "",
        visitor: posthog?.get_distinct_id() ?? "",
    };
}
