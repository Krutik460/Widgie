# Links for posts

Every link we post says which channel and which post it came from, so the PostHog dashboard "Widgie distribution" can rank posts by the confirmed signups they bring, not by likes.

## The short form

```
widgie.krutikpatel.dev/<page>/<source>/<post>
```

- `<page>`: `go` for the home page, `partners`, or `growth`. Point partner content at `partners` and habit content at `growth`.
- `<source>`: the channel, from the list below. Always lowercase.
- `<post>`: a short slug for this one post, such as the subreddit, the date or the topic. Leave it out for a bio link.

The short link redirects to the page with `utm_source` and `utm_content` set (see `Site/public/_redirects`). It reads like a normal link, which matters on Reddit, where a long UTM string looks like an ad.

## Sources

| Source | Channel | Medium (set automatically) |
|---|---|---|
| `x` | X posts, replies, threads | social |
| `linkedin` | LinkedIn | social |
| `threads` | Threads | social |
| `bluesky` | Bluesky | social |
| `reddit` | Reddit; put the subreddit in `<post>` | community |
| `indiehackers` | Indie Hackers | community |
| `hn` | Hacker News (Show HN at TestFlight) | community |
| `producthunt` | Product Hunt; their own `?ref=producthunt` already counts, so the plain URL works | launch |
| `tiktok`, `instagram`, `youtube` | Short videos; put the video's slug in `<post>` | video |
| `email` | The monthly update email | email |

Visitors who arrive without a tag (a copied link, an in-app browser) are still credited from the referring site: `t.co` and `x.com` count as `x`, `reddit.com` as `reddit`, and so on (`Site/public/tally.js`).

## Ready links

| Where | Link |
|---|---|
| X bio | `widgie.krutikpatel.dev/go/x` |
| LinkedIn profile | `widgie.krutikpatel.dev/go/linkedin` |
| Indie Hackers profile | `widgie.krutikpatel.dev/go/indiehackers` |
| Build in public post on X | `widgie.krutikpatel.dev/go/x/<yyyy-mm-dd>-<topic>` |
| r/LongDistance | `widgie.krutikpatel.dev/partners/reddit/longdistance` |
| r/Parenting, r/NewParents, r/beyondthebump | `widgie.krutikpatel.dev/partners/reddit/<subreddit>` |
| r/roommates | `widgie.krutikpatel.dev/partners/reddit/roommates` |
| r/getdisciplined, r/habits, r/productivity | `widgie.krutikpatel.dev/growth/reddit/<subreddit>` |
| r/iOSsetups, r/widgetsmith | `widgie.krutikpatel.dev/go/reddit/<subreddit>` |
| Product Hunt | `widgie.krutikpatel.dev` |
| Partner video on TikTok | `widgie.krutikpatel.dev/partners/tiktok/<video-slug>` |

## Campaigns

For a launch or a push across channels, use the full form with `utm_campaign`, for example `widgie.krutikpatel.dev/?utm_source=x&utm_campaign=launch-week&utm_content=thread-1`. Add a PostHog annotation on launch days so the dashboard shows what caused a spike.

## How credit works

- The first tagged or referred visit is kept for good, so someone who comes back days later and signs up still credits the post that first brought them.
- Signups and confirmations are counted by the server, so ad blockers cannot hide them. Visits are counted in the browser through our own domain, which most blockers let through.

## Checking the live site

Add `?utm_source=test` to any page you open yourself, for example `widgie.krutikpatel.dev/partners?utm_source=test`. PostHog's internal-traffic filter drops every event from a browser whose first touch is `test`, and from localhost, so the dashboard counts real visitors only. The first touch is kept, so open your first visit in each browser this way.
