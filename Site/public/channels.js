// Which channel a visit came from: UTM tags (or Product Hunt's ?ref) when the link has them, else the referring site
// or app. Pure, so the Worker tests can check it (test/channels.test.ts).

// Referrers that arrive without tags (a copied link, an app's in-app browser) still get a channel name. Android apps
// send their package name as the referrer host. Mail comes first: Gmail and Outlook are not search or social.
const CHANNELS = [
    [
        /^(mail\.google\.com|com\.google\.android\.gm|outlook\.(live|office|office365)\.com|com\.microsoft\.office\.outlook|(.+\.)?mail\.yahoo\.com|mail\.proton\.me|app\.fastmail\.com)$/,
        "email",
    ],
    [/(^|\.)(x|twitter)\.com$|^t\.co$|^com\.twitter\.android$/, "x"],
    [/(^|\.)reddit\.com$|^redd\.it$|^com\.reddit\.frontpage$/, "reddit"],
    [/(^|\.)producthunt\.com$/, "producthunt"],
    [/^news\.ycombinator\.com$/, "hn"],
    [/(^|\.)indiehackers\.com$/, "indiehackers"],
    [/(^|\.)linkedin\.com$|^lnkd\.in$|^com\.linkedin\.android$/, "linkedin"],
    [/(^|\.)threads\.(net|com)$/, "threads"],
    [/(^|\.)bsky\.app$/, "bluesky"],
    [/(^|\.)(tiktok|instagram|youtube|facebook)\.com$/, (host) => host.replace(/^(www|m|l|lm)\./, "").split(".")[0]],
    // Search only: www.google.* and the Google app. Gmail on the web also routes clicks through www.google.com/url,
    // which no referrer can tell apart from search.
    [/^(www\.)?google(\.[a-z]{2,3}){1,2}$|^com\.google\.android\.googlequicksearchbox$/, "google"],
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

export function channelOf(host) {
    for (const [pattern, name] of CHANNELS) {
        if (pattern.test(host)) return typeof name === "function" ? name(host) : name;
    }
    return host.replace(/^www\./, "");
}

/// A visit's own touch, as PostHog properties. Null for a direct visit or a move between our own pages.
/// `search` is the page's query string, `referrer` the full referrer URL, `ownHost` this site's host.
export function touchOf(search, referrer, ownHost) {
    const params = new URLSearchParams(search);
    let host = "";
    try {
        host = referrer ? new URL(referrer).hostname : "";
    } catch {}
    if (host === ownHost) host = "";
    const source = (params.get("utm_source") || params.get("ref") || "").trim().toLowerCase();
    if (!source && !host) return null;
    const channel = source || channelOf(host);
    return {
        first_source: channel,
        first_medium: (params.get("utm_medium") || MEDIUMS[channel] || "referral").toLowerCase(),
        first_campaign: params.get("utm_campaign")?.toLowerCase() || null,
        first_content: params.get("utm_content")?.toLowerCase() || null,
        first_referrer: host || null,
    };
}
