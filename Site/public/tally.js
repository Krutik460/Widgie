// PostHog on every page: visits, how far people read, what they play with and each signup step, so every post on X,
// Reddit or Product Hunt can be judged by the signups it brings. All requests go through /hop on this domain
// (src/posthog.ts), so blockers that know PostHog's hosts let them through. A local dev server sends nothing unless
// the URL has ?tally.

const KEY = "phc_Aj3Mbof3qJ2N455cGitXopyyY9dY3B2hbnrTLjJvszKF";
const FIRST_TOUCH = "widgie.first";

const params = new URLSearchParams(location.search);
const local = ["localhost", "127.0.0.1"].includes(location.hostname);
const enabled = !local || params.has("tally");

// ---------- Where the visitor came from ----------

// Referrers that arrive without UTM tags (a copied link, an app's in-app browser) still get a channel name.
const CHANNELS = [
    [/(^|\.)(x|twitter)\.com$|^t\.co$/, "x"],
    [/(^|\.)reddit\.com$|^redd\.it$/, "reddit"],
    [/(^|\.)producthunt\.com$/, "producthunt"],
    [/^news\.ycombinator\.com$/, "hn"],
    [/(^|\.)indiehackers\.com$/, "indiehackers"],
    [/(^|\.)linkedin\.com$|^lnkd\.in$/, "linkedin"],
    [/(^|\.)threads\.(net|com)$/, "threads"],
    [/(^|\.)bsky\.app$/, "bluesky"],
    [/(^|\.)(tiktok|instagram|youtube|facebook)\.com$/, (host) => host.replace(/^(www|m|l|lm)\./, "").split(".")[0]],
    [/(^|\.)google\./, "google"],
];
const MEDIUMS = {
    x: "social",
    linkedin: "social",
    threads: "social",
    bluesky: "social",
    facebook: "social",
    reddit: "community",
    hn: "community",
    indiehackers: "community",
    producthunt: "launch",
    tiktok: "video",
    instagram: "video",
    youtube: "video",
    google: "search",
    email: "email",
};

function channelOf(host) {
    for (const [pattern, name] of CHANNELS) {
        if (pattern.test(host)) return typeof name === "function" ? name(host) : name;
    }
    return host.replace(/^www\./, "");
}

/// This visit's own touch: UTM tags (or Product Hunt's ?ref), else the referring site. Null for a direct visit or a
/// move between our own pages.
function thisTouch() {
    let referrer = "";
    try {
        const host = document.referrer ? new URL(document.referrer).hostname : "";
        if (host && host !== location.hostname) referrer = host;
    } catch {}
    const source = (params.get("utm_source") || params.get("ref") || "").toLowerCase();
    if (!source && !referrer) return null;
    const channel = source || channelOf(referrer);
    return {
        first_source: channel,
        first_medium: (params.get("utm_medium") || MEDIUMS[channel] || "referral").toLowerCase(),
        first_campaign: params.get("utm_campaign")?.toLowerCase() || null,
        first_content: params.get("utm_content")?.toLowerCase() || null,
        first_referrer: referrer || null,
    };
}

/// The first touch that brought this visitor, kept for good, so a signup days later still credits that post.
function firstTouch() {
    let kept = null;
    try {
        kept = JSON.parse(localStorage.getItem(FIRST_TOUCH) || "null");
    } catch {}
    if (kept) return kept;
    const touch = thisTouch();
    if (touch) {
        try {
            localStorage.setItem(FIRST_TOUCH, JSON.stringify(touch));
        } catch {}
    }
    return touch;
}

const first = firstTouch();

// ---------- PostHog ----------

// The SDK script, once loaded, leaves an uninitialized PostHog on window. Events from before that wait here, with the
// time they happened.
let posthog = null;
const waiting = [];

if (enabled) {
    const script = document.createElement("script");
    script.src = "/hop/static/array.js";
    script.async = true;
    script.addEventListener("load", () => {
        posthog = window.posthog;
        posthog.init(KEY, {
            api_host: `${location.origin}/hop`,
            ui_host: "https://us.posthog.com",
            defaults: "2026-08-30",
            // Visitors stay anonymous: no person profiles, and nothing typed is ever recorded.
            person_profiles: "identified_only",
            session_recording: { maskAllInputs: true },
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
