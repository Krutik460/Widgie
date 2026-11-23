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

const HEADER = `<header class="top">
<a class="mark" href="/" aria-label="Widgie home">widgie<i></i></a>
<nav><a href="/home">For the house</a><a href="/us">For two</a><a class="key" href="#join">Get early access</a></nav>
</header>
`;

const cta = (first) => (first ? `<div class="cta"><a class="key" href="#join">Get early access</a></div>` : "");

// ---------- Sections ----------

const hero = () => `<section class="field sky hero">
<h1 class="display"><span>Words <span class="anchor">ı<span class="dot-tile"><b>${HEART}</b></span></span>n.</span><span class="l2">Widgets <span class="anchor" id="out">out.<span class="caret" data-pose="lean" data-mirror="1" data-halo="#9cc3f5"></span></span></span></h1>
<p class="lede">Tell Widgie what you need on your home screen. It builds the widget, then shares it with your house, or just the two of you.</p>
<div class="cta"><a class="key" href="#join">Get early access</a><small>For iPhone.<br>Free while it's early.</small></div>
<div class="pile" data-scene="hero"></div>
</section>`;

const house = (first) => `<section class="field coral house" id="house">
<h2 class="display"><span>Did anyone</span><span>feed Luna<span class="anchor" id="q">?<span class="blk luna lean-q" data-widget="luna"></span></span></span></h2>
<p class="copy">One widget for the whole house. <b>Anyone taps it, everyone's home screen knows.</b> No group chat required.</p>
${cta(first)}
<div class="scene" data-scene="house" data-first="${first ? 1 : 0}"></div>
</section>`;

const two = (first) => `<section class="field sun two" id="two">
<h2 class="display"><span>Just</span><span>for two.</span></h2>
<p class="copy">A heart button for Jo. Days until you see Alex. Both your moods, side by side. Small things, right where you look.</p>
${cta(first)}
<div class="scene" data-scene="two" data-first="${first ? 1 : 0}"></div>
</section>`;

function signupForm({ segment, placeholder, pair = false }) {
    const id = pair ? "pair" : segment || "any";
    const picker =
        segment || pair
            ? ""
            : `<fieldset class="pick"><legend>It's for</legend><label><input type="radio" name="segment" value="home" checked><span>Our home</span></label><label><input type="radio" name="segment" value="us"><span>The two of us</span></label></fieldset>`;
    return `<form class="signup"${segment ? ` data-segment="${segment}"` : ""}${pair ? " data-pair" : ""} novalidate>
${picker}
<label class="sr" for="idea-${id}">Your first widget, in your words (optional)</label>
<input class="say" id="idea-${id}" name="idea" maxlength="500" autocomplete="off" placeholder="${esc(placeholder)}">
<div class="row"><label class="sr" for="email-${id}">Your email</label><input id="email-${id}" name="email" type="email" autocomplete="email" placeholder="you@home.com" required><button class="key" type="submit">Get early access</button></div>
<div class="turnstile"></div>
<p class="error" role="alert"></p>
<p class="fine">Say your first widget if you like. Free while it's early: one short email a month about what shipped, and your invite. Leave any time.</p>
</form>
<div class="done" hidden><span class="caret" data-pose="jump" data-eyes="happy" data-moon="1"></span><h3>Check your inbox.</h3><p>Tap the link we sent to hold your spot. Then you'll get a link to bring your people.</p></div>`;
}

const join = (page) => `<section class="field grape join" id="join">
<div class="join-col">
<h2 class="display"><span>What would</span><span>yours say?</span></h2>
${signupForm(page)}
</div>
<div class="scene" data-scene="join"></div>
<div class="foot"><span>Widgie, built in public by Krutik. Made for the people you live with.</span><span><a href="/privacy">Privacy</a><a href="mailto:hello@widgie.krutikpatel.dev">Contact</a></span></div>
</section>`;

// ---------- Story pages ----------

const PAGES = [
    {
        file: "index.html",
        path: "/",
        title: "Widgie: words in, widgets out",
        description:
            "Tell Widgie what you need on your home screen. It builds the widget, then shares it with your house, or just the two of you.",
        sections: () => [hero(), house(false), two(false)],
        segment: "",
        placeholder: "Tell me when the plants need water",
    },
    {
        file: "home.html",
        path: "/home",
        title: "Widgie for the house: did anyone feed Luna?",
        description:
            "One widget for the whole house. Anyone taps it, everyone's home screen knows who fed the dog and when. Join the early list with your household.",
        sections: () => [house(true)],
        segment: "home",
        placeholder: "Tell us when the plants need water",
    },
    {
        file: "us.html",
        path: "/us",
        title: "Widgie for two: a widget only you share",
        description:
            "A heart button for Jo. Days until you see Alex. Both your moods, side by side. Widgets only the two of you share.",
        sections: () => [two(true)],
        segment: "us",
        placeholder: "A countdown to when I see Alex",
    },
];

for (const page of PAGES) {
    writeFileSync(
        OUT + page.file,
        `${head({ title: page.title, description: page.description, path: page.path, turnstile: true })}<body>
${HEADER}<main>
${page.sections().join("\n")}
${join(page)}
</main>
</body>
</html>
`,
    );
}

// ---------- Small pages ----------

const PAGE_FOOT = `<div class="page-foot"><span>Widgie, built in public by Krutik.</span><a href="/privacy">Privacy</a></div>`;

function smallPage({ file, title, description, path = "/", body, turnstile = false }) {
    writeFileSync(
        OUT + file,
        `${head({ title, description, path, turnstile })}<body>
${HEADER}<main class="field sky page">
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
    body: `<div id="join-root" class="center">
<section id="join-state" hidden>
${bigCaret()}
<h1 data-hide-on-done>You're invited.</h1>
<p class="invite-copy" data-hide-on-done></p>
<p class="count" data-hide-on-done></p>
<div class="card">${signupForm({ segment: "", placeholder: "Tell me when it's my turn", pair: true })}</div>
</section>
<section id="share" hidden>
${bigCaret()}
<h1>You're on the list.</h1>
<p class="share-copy"></p>
<div class="share-box"><input aria-label="Your invite link" readonly><button class="key" id="copy" type="button">Copy</button></div>
<button class="key" id="native-share" type="button" hidden>Share link</button>
<p class="count"></p>
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
