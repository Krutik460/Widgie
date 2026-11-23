// Writes every page in public/ from one template: the toy box story pages (/, /home, /us) and the small pages share
// one head, header and footer. Run `npm run pages` after editing; the output is committed and served as is.

import { writeFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const OUT = fileURLToPath(new URL("../public/", import.meta.url));
const ORIGIN = "https://widgie.krutikpatel.dev";

const esc = (text) => text.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/"/g, "&quot;");

const HEART =
    '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21s-7.5-4.6-9.6-9.3C.9 8.2 3 4.5 6.6 4.5c2.1 0 3.6 1.2 5.4 3.2 1.8-2 3.3-3.2 5.4-3.2 3.6 0 5.7 3.7 4.2 7.2C19.5 16.4 12 21 12 21z"/></svg>';

function head({ title, description, path, turnstile = false }) {
    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
<title>${esc(title)}</title>
<meta name="description" content="${esc(description)}">
<meta name="theme-color" content="#9cc3f5">
<link rel="icon" href="/icon.svg" type="image/svg+xml">
<link rel="apple-touch-icon" href="/apple-touch-icon.png">
<link rel="preload" href="/fonts/bricolage.woff2" as="font" type="font/woff2" crossorigin>
<link rel="stylesheet" href="/styles.css">
<meta property="og:type" content="website">
<meta property="og:title" content="${esc(title)}">
<meta property="og:description" content="${esc(description)}">
<meta property="og:url" content="${ORIGIN}${path}">
<meta property="og:image" content="${ORIGIN}/og.png">
<meta name="twitter:card" content="summary_large_image">
<script src="/caret.js" defer></script>
<script type="module" src="/app.js"></script>
${turnstile ? '<script src="https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit&onload=onTurnstileLoad" defer></script>' : ""}
</head>
`;
}

/// The header. Its key jumps to the sign-up on this page, or to the home page sign-up from pages that have none.
const header = (join = "#join") => `<header class="top">
<a class="mark" href="/" aria-label="Widgie home"><span class="app"><img src="/mark.svg" alt="" width="46" height="46"></span><span class="name">widgie</span></a>
<nav><a href="/partners">For partners</a><a href="/growth">For personal growth</a><a class="key" href="${join}">Get early access</a></nav>
</header>
`;

// ---------- Sections ----------

/// The home page hero, with its heart-dotted i.
const mainHero = () => `<section class="field sky hero">
<h1 class="display"><span>Words <span class="anchor">ı<span class="dot-tile"><b>${HEART}</b></span></span>n.</span><span class="l2">Widgets <span class="brk">out.</span></span></h1>
<p class="lede">Say what you want on your home screen, in plain words. Widgie builds a widget that works, for the two of you or for the person you're becoming.</p>
<div class="cta"><a class="key" href="#join">Get early access</a><small>For iPhone.<br>Free while it's early.</small></div>
<div class="pile" data-scene="hero"></div>
</section>`;

/// An audience page hero: two lines of headline, and the caret acting out the page beside them.
const audienceHero = ({ color, first, last, lede, scene }) => `<section class="field ${color} hero">
<h1 class="display"><span>${first}</span><span class="l2">${last}</span></h1>
<p class="lede">${lede}</p>
<div class="cta"><a class="key" href="#join">Get early access</a><small>For iPhone.<br>Free while it's early.</small></div>
<div class="pile" data-scene="${scene}"></div>
</section>`;

/// A story section: kicker, headline and copy on one side, its scene on the other, and an optional door to a page.
const story = ({
    id,
    color,
    side,
    kicker,
    lines,
    copy,
    scene,
    door,
}) => `<section class="field ${color} story ${side}" id="${id}">
<p class="kicker">${kicker}</p>
<h2 class="display">${lines.map((line) => `<span>${line}</span>`).join("")}</h2>
<p class="copy">${copy}</p>
${door ? `<a class="key go" href="${door.href}">${door.label}</a>` : ""}
<div class="scene" data-scene="${scene}"></div>
</section>`;

/// The partners home section: Luna leans on the question mark.
const home = () => `<section class="field coral house" id="home">
<p class="kicker">Your home</p>
<h2 class="display"><span>Did anyone</span><span>feed Luna<span class="anchor" id="q">?<span class="blk luna lean-q" data-widget="luna"></span></span></span></h2>
<p class="copy">The chores and check-ins you share, on both your home screens. One of you taps, the other just knows. <b>No more "did you...?" texts.</b></p>
<div class="scene" data-scene="home"></div>
</section>`;

/// The partners couple section.
const couple = () => `<section class="field pink two" id="us">
<p class="kicker">The two of you</p>
<h2 class="display"><span>Just</span><span>for two.</span></h2>
<p class="copy">And the little things between you. A heart when you're thinking of them, days until your trip, how you both feel today.</p>
<div class="scene" data-scene="couple"></div>
</section>`;

const INVITES = {
    partners: "You'll get a link for your partner, and couples who join together get in first.",
    growth: "You'll get a link for a friend who keeps you going, and friends who join together get in first.",
    "": "You'll get a link to bring someone along, and people who join together get in first.",
};

function signupForm({ segment, placeholder, pair = false }) {
    const invite = `${INVITES[segment] ?? INVITES[""]} Free while it's early: one short email a month and your invite. Leave any time.`;
    const id = pair ? "pair" : segment || "any";
    const picker =
        segment || pair
            ? ""
            : `<fieldset class="pick"><legend>It's for</legend><label><input type="radio" name="segment" value="partners" checked><span>The two of us</span></label><label><input type="radio" name="segment" value="growth"><span>My own goals</span></label></fieldset>`;
    return `<form class="signup"${segment ? ` data-segment="${segment}"` : ""}${pair ? " data-pair" : ""} novalidate>
${picker}
<label class="sr" for="idea-${id}">Your first widget, in your words (optional)</label>
<input class="say" id="idea-${id}" name="idea" maxlength="500" autocomplete="off" placeholder="${esc(placeholder)}">
<div class="row"><label class="sr" for="email-${id}">Your email</label><input id="email-${id}" name="email" type="email" autocomplete="email" placeholder="you@home.com" required><button class="key" type="submit">Get early access</button></div>
<div class="turnstile"></div>
<p class="error" role="alert"></p>
<p class="fine">${invite}</p>
</form>
<div class="done" hidden><span class="caret" data-pose="jump" data-eyes="happy" data-moon="1"></span><h3>Check your inbox.</h3><p>Tap the link we sent to hold your spot. Then you'll get a link to bring your person along.</p></div>`;
}

const join = (page) => `<section class="field grape join" id="join">
<div class="join-col">
<h2 class="display"><span>What would</span><span>yours say?</span></h2>
${signupForm(page)}
</div>
<div class="scene" data-scene="${page.scene}"></div>
<div class="foot"><span>Widgie, built in public by Krutik.</span><span><a href="/privacy">Privacy</a><a href="mailto:hello@widgie.krutikpatel.dev">Contact</a></span></div>
</section>`;

// ---------- Pages ----------

// Two first audiences, each with its own page: partners (a couple sharing a home and a relationship) and personal
// growth (people tracking their own habits and goals). The home page opens a door to each.
const PAGES = [
    {
        file: "index.html",
        path: "/",
        title: "Widgie: words in, widgets out",
        description:
            "Say what you want on your home screen. Widgie builds a widget that works, for the two of you or for your own goals.",
        sections: () => [
            mainHero(),
            story({
                id: "partners",
                color: "coral",
                side: "left",
                kicker: "For partners",
                lines: ["The home you", "share, and", "each other."],
                copy: "Who fed the dog, whose turn for the bins, a heart when you're thinking of them. On both your phones.",
                scene: "partnersDoor",
                door: { href: "/partners", label: "See it for partners" },
            }),
            story({
                id: "growth",
                color: "mint",
                side: "right",
                kicker: "For personal growth",
                lines: ["Your habits,", "your way."],
                copy: "Water, workouts, streaks, days alcohol-free, a savings goal. Tracked exactly how you want, one glance away.",
                scene: "growthDoor",
                door: { href: "/growth", label: "See it for growth" },
            }),
        ],
        join: { segment: "", placeholder: "Tell me when the plants need water", scene: "joinAny" },
    },
    {
        file: "partners.html",
        path: "/partners",
        title: "Widgie for partners: the home you share, and each other",
        description:
            "Who fed the dog, whose turn for the bins, a heart when you're thinking of them. Widgets for the two of you, on both your phones.",
        sections: () => [
            audienceHero({
                color: "sun",
                first: "Made",
                last: "for two.",
                lede: "Who fed the dog, whose turn for the bins, a heart when you're thinking of them. Say it, Widgie builds the widget, and it's on both your phones.",
                scene: "partnersHero",
            }),
            home(),
            couple(),
        ],
        join: { segment: "partners", placeholder: "Tell us when the plants need water", scene: "joinPartners" },
    },
    {
        file: "growth.html",
        path: "/growth",
        title: "Widgie for personal growth: track anything, your way",
        description:
            "Water, workouts, streaks, days alcohol-free, a savings goal. Say how you want to track it and Widgie builds the widget.",
        sections: () => [
            audienceHero({
                color: "mint",
                first: "Track",
                last: "anything.",
                lede: "Water, workouts, days alcohol-free, a savings goal. Say how you want to track it, Widgie builds the widget, and today's progress is one glance away.",
                scene: "growthHero",
            }),
            story({
                id: "habits",
                color: "sky",
                side: "left",
                kicker: "Every day",
                lines: ["Habits that", "stick."],
                copy: "Streaks, grids and counters built around your definition of a habit. Tap the widget, not an app. No paywall on widgets.",
                scene: "habits",
            }),
            story({
                id: "goals",
                color: "lilac",
                side: "right",
                kicker: "Over time",
                lines: ["Goals you", "can see."],
                copy: "Days alcohol-free, a savings jar for Japan, a new word every morning. Progress where you look a hundred times a day.",
                scene: "goals",
            }),
        ],
        join: { segment: "growth", placeholder: "Remind me to stretch every evening", scene: "joinGrowth" },
    },
];

for (const page of PAGES) {
    writeFileSync(
        OUT + page.file,
        `${head({ title: page.title, description: page.description, path: page.path, turnstile: true })}<body>
${header()}<main>
${page.sections().join("\n")}
${join(page.join)}
</main>
</body>
</html>
`,
    );
}

// ---------- Small pages ----------

const PAGE_FOOT = `<div class="page-foot"><span>Widgie, built in public by Krutik.</span><a href="/privacy">Privacy</a></div>`;

function smallPage({ file, title, description, path = "/", body, turnstile = false, join = "/#join" }) {
    writeFileSync(
        OUT + file,
        `${head({ title, description, path, turnstile })}<body>
${header(join)}<main class="field sky page">
${body}
${PAGE_FOOT}
</main>
</body>
</html>
`,
    );
}

const bigCaret = () => `<span class="caret" data-pose="idle" data-shadow="1"></span>`;

smallPage({
    file: "p.html",
    title: "Join me on Widgie",
    description: "You've been invited to share widgets on Widgie. Join the early list together.",
    turnstile: true,
    join: "#join-root",
    body: `<div id="join-root" class="center">
<section id="join-state" hidden>
${bigCaret()}
<h1 data-hide-on-done>You're invited.</h1>
<p class="invite-copy" data-hide-on-done></p>
<p class="tally" data-hide-on-done></p>
<div class="card">${signupForm({ segment: "", placeholder: "Tell us when it's my turn", pair: true })}</div>
</section>
<section id="share" hidden>
${bigCaret()}
<h1>You're on the list.</h1>
<p class="share-copy"></p>
<div class="share-box"><input aria-label="Your invite link" readonly><button class="key" id="copy" type="button">Copy</button></div>
<button class="key" id="native-share" type="button" hidden>Share link</button>
<p class="tally"></p>
</section>
<section id="unknown" hidden>
${bigCaret()}
<h1>This invite isn't ready.</h1>
<p>Whoever sent it may not have confirmed their email yet. You can still get on the list yourself.</p>
<a class="key" href="/">Go to Widgie</a>
</section>
</div>`,
});

const simple = (file, title, h1, inner) =>
    smallPage({
        file,
        title: `${title} · Widgie`,
        description: title,
        body: `<div class="center">${bigCaret()}<h1>${h1}</h1>${inner}</div>`,
    });

simple(
    "leave.html",
    "Leave the list",
    "Leave the list?",
    `<p>This removes your email and anything you wrote from the Widgie list. You won't hear from us again.</p>
<button class="key" id="leave" type="button">Remove me</button>
<p id="left" hidden>Done. You're off the list.</p>
<p id="leave-failed" hidden>That link didn't work. Reply to any Widgie email and we'll remove you by hand.</p>`,
);
simple(
    "link-expired.html",
    "Link not valid",
    "That link didn't work.",
    `<p>It may be incomplete, or you may have left the list. Sign up again and we'll send a fresh one.</p><a class="key" href="/">Go to Widgie</a>`,
);
simple(
    "404.html",
    "Not found",
    "Nothing here.",
    `<p>That page doesn't exist. The caret looked everywhere.</p><a class="key" href="/">Go to Widgie</a>`,
);

smallPage({
    file: "privacy.html",
    title: "Privacy · Widgie",
    description: "What the Widgie early list stores and why.",
    path: "/privacy",
    body: `<article class="prose">
<h1>Privacy</h1>
<p>Last updated November 23, 2026.</p>
<h2>What we store</h2>
<ul>
<li>Your email address, so we can confirm your spot and invite you when Widgie is ready.</li>
<li>Whether you signed up for a home or for two people, and which group you joined.</li>
<li>Your widget idea, if you wrote one. It helps decide what Widgie should build well first.</li>
<li>The site or channel that sent you, if the link said so.</li>
</ul>
<h2>What we don't do</h2>
<ul>
<li>No ad trackers and no cookies. Visit counts come from Cloudflare Web Analytics, which does not identify you.</li>
<li>We never sell or share your email. It is used only for Widgie updates and your invite.</li>
</ul>
<h2>Who handles it</h2>
<p>The list lives in a Cloudflare database. Emails are sent through Resend. Bot checks use Cloudflare Turnstile.</p>
<h2>Leaving</h2>
<p>Every email has a link to remove yourself, which deletes your row. You can also reply to any Widgie email and ask.</p>
</article>`,
});

console.log("pages written");
