# Early access and build in public: partners and personal growth

Written 2026-11-23. Status: W1 built and live at https://widgie.krutikpatel.dev (2026-11-23). Signups wait on a Resend API key.

## Goal

Have real people waiting for Widgie on the day the first TestFlight build opens, from the two segments v1 is built around (see `docs/research/icp-and-widgets.md`):

- **ICP 1, shared households.** Parents, roommates, multi-caregiver homes. Core widget: dog fed / baby feed, "who did it, how long ago".
- **ICP 2, couples and close friends.** Often long distance. Core widget: thinking of you, with their own photo.

Targets for the first 8 weeks (to revise once we see real numbers):

- 300 signups per ICP.
- 40 percent of signups bring their partner or household (pair rate).
- 100 answers to "what would you build?" per ICP, which become eval prompts and settle the ICP choice with real words instead of research.
- 10 short calls per ICP before TestFlight.

## The one idea that ties it together

Both ICPs are multi-person. The product grows through the invite link. So the waitlist uses the same loop: **you sign up as a pair or a household, not alone.** After signing up you get a link for your partner or housemates, and a pair that is complete gets in first. This tests the real growth loop before the app exists, and the pair rate is the earliest signal that the shared widget is the hook.

## Two tracks, two audiences

The build-in-public audience (builders on X, LinkedIn, Indie Hackers) is not the ICP. Parents and couples do not read build logs. So there are two tracks with different content, and only one of them is expected to bring signups.

| | Builder track | ICP track |
|---|---|---|
| Audience | Indie devs, iOS devs, AI builders | Parents, roommates, couples |
| Channels | X, LinkedIn, Indie Hackers, Hacker News (once, at TestFlight) | TikTok, Instagram Reels, chosen subreddits |
| Content | The real build: engine, look code, App Attest, cost per widget, numbers | The widget doing its job on a home screen. Never code. |
| Purpose | Credibility, feedback, a few early adopters, accountability | Signups |
| Cadence | 3 posts a week | 3 short videos a week, 1 Reddit thread a week where rules allow |

Source material already exists: 179 commits and 10 PR review guides in `docs/pr/`. Each builder post comes from something real that shipped that week.

## Workstreams

### W1. Landing page with a pair waitlist

- One site, two entry pages with their own copy and their own demo clip: `/home` for households, `/us` for couples. The root page lets the visitor pick.
- Hosted on Cloudflare (static assets on a Worker), same account as the backend, separate Worker so a site deploy can never touch the API.
- Signup form: email, segment (set by the page), optional "what would you build?" text, Turnstile against bots. No other fields.
- Storage: D1, one `signups` table (`id, email, segment, idea, referred_by, pair_code, created_at, confirmed_at`).
- Double opt-in email with the pair link. Confirmed rows only count.
- Pair page: "Alex invited you to Widgie" with the same widget clip, one tap to join their pair.
- Analytics: Cloudflare Web Analytics, no cookies, so no consent banner. UTM tag per channel so we know which track brings signups.
- Privacy page: what we store, why, delete on request by replying to any email.
- Look: The Caret in Sky identity from `docs/design/app-feel/`. None of the banned defaults (cream background, italic accent words, numbered sections, monospace labels, pill buttons).
- Tests: Worker unit tests for signup, confirm, pair join, duplicate email, bad token. One Playwright run of the full flow against `wrangler dev`.

### W2. Proof clips

Real recordings, no AI-generated footage, since the promise is "this is your widget".

- Dog fed on two simulators side by side: tap on one, both widgets show who fed and how long ago.
- Thinking of you with a real couple photo: tap, heart count rises on both.
- A "describe it" clip: typing a prompt, the widget appearing.
- Recorded with `xcrun simctl io recordVideo`, framed in an iPhone mockup, 9:16 for TikTok and Reels, 16:9 trim for X.
- Depends on the dog fed and thinking of you reference widgets rendering in the simulator. Shared sync across two phones is phase 3/4, so the first clips stage the second phone's state; they are labeled as a preview until sync is real.

### W3. Builder track content system

- `docs/marketing/` holds a content bank: one line per post idea with the commit or PR it comes from.
- A weekly template: what shipped, one number, one problem we hit, what is next, link to the waitlist.
- Launch thread for week 1: what Widgie is, why one app beats twelve single-purpose widget apps, the waitlist link.
- Drafts go through the LinkedIn skills (post writer, humanizer) and get approved before anything is posted. Nothing posts automatically.

### W4. ICP track content and community

- Video formats per ICP:
  - ICP 1: "we stopped double-feeding the dog", "3 am feed without texting my partner", "one widget replaced four apps".
  - ICP 2: "my girlfriend's widget lights up when I tap mine", "countdown to when I see her, in our photo".
- Reddit: first read r/LongDistance, r/Parenting, r/beyondthebump, r/NewParents, r/roommates, r/iOSsetups, r/widgetsmith by hand (this also closes the research gap the ICP doc calls out). Post only where self-promotion is allowed, as a person asking what they would build, not an ad.
- Each channel link carries its own UTM so W1 analytics shows which works.

### W5. Founding cohort and the path to TestFlight

- First 100 confirmed pairs per ICP are the founding cohort: TestFlight first, a say in which widgets come next, and a founding price when paid tiers exist.
- Monthly update email to all signups with one clip and one question.
- 10 calls per ICP from people who wrote a "what would you build" answer. Notes go in `docs/research/interviews/`.
- TestFlight external beta opens after the device step in phase 2b and Beta App Review. Invites go pair by pair so every tester has someone to share with on day one.

## Order

1. W1 landing page and waitlist (blocks everything else, since posts need a link).
2. W2 first clip for each ICP.
3. Launch week: builder thread plus first ICP video per segment.
4. W3 and W4 weekly from then on, W5 calls once signups pass 50 per ICP.

## Checklist

- [x] Decide domain, posting accounts, and email sender (answers below)
- [x] W1: site Worker, D1 schema, signup and confirm routes, pair join, Turnstile
- [x] W1: `/home`, `/us`, root, pair page, privacy page in the Caret in Sky look
- [x] W1: unit tests, full flow clicked through in a browser, deployed to the domain
- [ ] W1: Resend account, sending domain DNS, `RESEND_API_KEY` secret, one live signup end to end
- [ ] W1: Email Routing for hello@widgie.krutikpatel.dev to your inbox, Web Analytics on in the dashboard
- [ ] W2: dog fed clip, thinking of you clip, describe clip, cut per channel
- [ ] W3: content bank, weekly template, launch thread draft
- [ ] W4: subreddit read and rules notes, first 3 video scripts per ICP
- [ ] W5: confirmation and monthly email copy, interview guide

## Decisions (2026-11-23)

1. Domain: `widgie.krutikpatel.dev` to start.
2. Posting: your personal accounts, screen-only ICP videos (captions or voiceover, no face).
3. Email: Resend. Cloudflare Email Service sends to arbitrary recipients only on Workers Paid, and the account is on Workers Free.
4. Name: Widgie (assumed; say if not).
5. Heroes show no widgets the sections repeat. Home: the caret draws each widget at an easel beside it (words type in, pencil outline, color wipe) and sends it to a greyed group around it, on a loop. /partners: two carets on a couch with hearts and the dog. /growth: the caret curls a dumbbell and counts reps. Concepts in `docs/design/hero-concepts/`.

## Review

W1 is in `Site/`, a Worker separate from `Backend/`.

- **Pages.** `/` (both audiences), `/home` (ICP 1), `/us` (ICP 2), `/p/<code>` (join or share a pair), `/privacy`, `/leave`, `/link-expired`, `404`. Static HTML in `Site/public/`, one ES module (`app.js`) plus the widget definitions (`scenes.js`), no build step.
- **Character.** Each hero is a real-size iPhone home screen. The caret peeks over the phone, types each ICP prompt in a speech bubble, leans in while the slot is drawn in the app's dashed building style, then the widget lands and works when tapped: baby feeds turn red after 3 hours, Luna's check, bins rota, grocery list, a countdown with real date math, hearts, moods, a daily question. The chips rebuild any widget. A second section shows two phones sharing one widget. The caret's eyes follow the pointer, and joining ends in caret confetti.
- **Waitlist.** D1 `signups`, one row per email, a pair code shared by a home or a couple. Confirm and leave links are HMAC-signed over the row id, so no token is stored. The form answers the same whether an email is new or known, reminders wait 10 minutes, a failed send rolls the row back, Turnstile and a per-address rate limit guard the form, and every email carries one-click unsubscribe.
- **Verified.** 24 Worker tests. The full flow was clicked through locally: sign up, confirm, share page, partner joins through the link, pair complete. Live pages return 200 with the CSP header and no console errors. Not verified live: a real signup, because Resend is not set up yet.
- **Second redesign (same day).** The site became "Widgie's world": the pointer is the caret (desktop), every headline is typed with the caret as its cursor, a type-a-widget field builds known ideas live on the pinned phone and saves any idea into the sign-up, the story scrolls through a sky that changes with the day (with the partner's phone sliding in for "shared"), then a marquee of prompts and a night-sky sign-up. Display face: Bricolage Grotesque (OFL), self-hosted. Pages come from `Site/pages/build.mjs` (`npm run pages`).
- **Third direction, chosen (same day): the toy box.** Three directions were mocked up in `docs/design/site-directions/` (home screen, night glass, toy box; compared in `compare.png`). The user picked the toy box: full-bleed color fields (sky, coral, sun, grape), widgets as chunky blocks with a solid edge, and a big caret acting in each scene. `/` has every section, `/home` opens on the coral house scene, `/us` on the yellow couples scene, and each ends in the grape sign-up ("What would yours say?"), whose first field is the visitor's widget idea. Motion: blocks drop in with a bounce, headline letters pop up, blocks drift with scroll and lean toward the pointer, mouse users can pick up and throw blocks, carets sway, blink and watch the pointer, and joining ends in confetti. `Site/public/widgets.js` is now the one widget source and `Site/public/caret.js` the one caret drawing, shared with the icon renderer.
- **Two audiences, a page each (same day).** After a one-page partners pass, the user settled on two lead audiences. The home page (`/`) has the hero and a door to each: **For partners** and **For personal growth**. `/partners` (ICP 1 and 2 merged) has a couple hero ("Made for two.", two carets and a heart), a home section (Luna with a drawn puppy, groceries, baby feeds, chores, the plant) and a couple section (countdown, hearts, moods, the daily question, days together). `/growth` (ICP 3) has "Track anything." and sections for daily habits (habit grid, meditation streak, water bottle, pushups) and goals over time (savings jar, days alcohol-free, word of the day). Each page's sign-up records its segment ("partners" or "growth", migration `0002_audiences.sql`); the home page asks which. /home and /us redirect into `/partners`.
- **App icon (same day).** B3, "Peek, closer", in light, dark and tinted, in `App/Widgie/AppIcon.xcassets`; drawn by `docs/design/app-icon/`.
- **Found by the browser run, not the tests.** The global `fetch` called as `deps.fetch` throws "Illegal invocation" in workerd (now bound in `index.ts`). The Turnstile script defines `window.turnstile` before `render` exists, which used to stop the rest of the page script.

## Plan: an email-only list, no invites (2026-11-23)

The app will have shared widgets built in, so the waitlist stops tracking invite links per person. The list keeps one row per email: email, audience (`partners`, `growth`, or `any` from the home page), source, confirmed or not. This builds on the email-only form change, which is not committed yet and whose migration has not run on the live database.

- [x] **Database.** Fold the column drop into the unreleased migration, now `0003_email_only.sql`: rebuild `signups` without `pair_code` and `joined_via_link`, with `any` allowed. One rebuild, run once with `npm run migrate`. Existing rows keep email, audience, idea, source and confirmation, and lose their pair codes.
- [x] **API.** Signup stops reading `pair` and stops making codes. Remove `GET /api/pair/:code`, `MAX_PAIR`, `pairInfo`, and `pairCode`/`PAIR_CODE` in `links.ts`. Signing and checking confirm/leave links stay.
- [x] **Confirm.** The confirm link lands on a new small page, `/confirmed` ("You're on the list."), instead of the share page.
- [x] **Emails.** The confirm email drops the "link to share with..." line. Re-signing up with a confirmed address sends a plain "you're already on the list" note with no link, so the form still answers the same for new and known emails.
- [x] **Pages.** Delete `p.html` and its script (copy tables, share box, native share). Old `/p/<code>` links redirect to `/`. The fine print under the form loses "you'll get a link for...", and the success message loses "then you'll get a link to bring your person along". The privacy page drops "which group you joined" and "your invite". Unused styles go (`.card`, `.share-box`, `#native-share`, `.tally`).
- [x] **Tests.** Remove the pair tests; add a test that confirm lands on `/confirmed`, and one that a known address gets the plain note.
- [x] **Verify.** Lint, types and tests; then sign up and confirm through the real form on a phone-sized WebKit, and check that an old `/p/<code>` link lands on the home page.

**Result.** Done as planned. 23 Worker tests (pair tests removed; new ones cover email-only signups landing on `/confirmed`, the plain note for a confirmed address, and the pair API being gone). Checked in phone-sized WebKit against the local dev server: sign-up through the /partners form, the confirmation email text, confirm redirecting to `/confirmed`, and an old `/p/<code>` link landing on `/`. Before the next deploy, run `npm run migrate` so the live table matches.
