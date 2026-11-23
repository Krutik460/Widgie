# Widgie ICPs and the widgets they would build

Written 2026-11-22. Based on two web research passes covering competitors, Apple platform changes, and user segments. Sources are inline. Tracker numbers (Sensor Tower, Appfigures, Adapty) are modelled estimates that often disagree by 10x. Numbers a company published itself are marked "company".

**Gap in the evidence.** Reddit could not be read because the research tools block it. User voice here comes from App Store listings and reviews, TechCrunch, MacRumors forums, Hacker News and Lemon8. Before we lock the ICPs, someone should read r/iOSsetups, r/widgetsmith, r/ADHD, r/LongDistance and r/Scriptable by hand.

## What the market says, in five lines

1. **Downloads come from looks, money comes from people and routines.**
   - Widgetsmith has about 131M lifetime downloads (company, [source](https://www.david-smith.org/blog/2025/09/18/widgetsmith-at-five/)), but tracker estimates put it at only about $1-2.5M a year.
   - Locket, a friends' photo widget, earns about $13.5M a year with 9M+ daily active users (company, [TechCrunch](https://techcrunch.com/2025/11/03/lockets-social-app-is-picking-up-steam-with-gen-alpha/)).
   - Health and fitness apps have the highest revenue per install (RevenueCat 2025: $0.63 against a $0.31 median).
2. **Single-purpose widget apps keep multiplying.** The App Store has dozens of apps launched in 2025-26 for one job each: baby feeds, pet feeding, plant watering, chores, "days since", exam countdowns, couples. Each has its own paywall, and many put sharing behind it. This fragmentation is the strongest case for one app that builds any tracker.
3. **Non-coders building small apps for themselves is now a real trend.** TechCrunch, 2026-01-16 ([link](https://techcrunch.com/2026/01/16/the-rise-of-micro-apps-non-developers-are-writing-apps-instead-of-buying-them/)), profiles people building a vice tracker, a palpitations log, an allergy tracker and a chores app. Almost all are a table, a count and a tap to log, which is exactly Widgie's block set. The article names mobile distribution as the hard part, and Widgie removes that problem.
4. **The AI widget builders that exist go after data dashboards, not people.** WidgetAI, Tilekit and AI Vibe Widget connect to weather, stocks, Health and RSS. None offers shared widgets, user-owned data tables or scheduled AI content. None shows visible traction.
5. **The top complaints across widget apps are reliability and pricing.** Users report widgets that don't refresh, go blank or disappear, plus rewarded ads and pay-to-play paywalls (Locket, Widgy, Widgetable reviews). Getting these right is a differentiator in its own right.

## Risks the research surfaced for the current plan

- **App Store Guideline 2.5.2.** In March 2026 Apple blocked updates to Replit and Vibecode and briefly pulled Anything, citing downloaded code that changes app behavior ([MacRumors](https://www.macrumors.com/2026/03/18/apple-blocks-updates-for-vibe-coding-apps/), [MacRumors](https://macrumors.com/2026/03/30/apple-pulls-vibe-coding-app/)). `tasks/todo.md` relies on section 3.3.1(B) and the Scriptable precedent. We need to plan for App Review explicitly:
  - frame look code as presentation data,
  - keep it a pure function with no capabilities,
  - prepare the review notes.
- **Widget push refresh is budgeted, and a forum report says pushes can be silently dropped** ([forum](https://developer.apple.com/forums/thread/839182)). Shared widgets are the ICP-1 and ICP-2 value, so they need a timeline-refresh fallback and an honest "last synced" signal in the look.
- **Clear and tinted modes in iOS 26 recolor content and replace the widget's background.** Photo and gradient looks get flattened unless the render code handles these modes on purpose. The aesthetic ICP will notice.
- **iOS 27 adds an extra-large 4x6 widget size.** Few apps support it yet, which is a chance to be early.

## The ICPs

Ranked by fit with what v1 can do, multiplied by willingness to pay.

**Decision (2026-11-23).** The early access site leads with two audiences, each with its own page. **Partners** (`/partners`) merges ICP 1 and ICP 2: a couple who share a home and a relationship, wanting both the household widgets (who fed the dog, baby feeds, bins, groceries, chores) and the relationship widgets (hearts, countdowns, moods, a daily question). **Personal growth** (`/growth`) is ICP 3, the multi-tracker self-improver (habit streaks and grids, water, pushups, days alcohol-free, a savings jar, a word of the day). The home page opens a door to each.

**Decision (2026-11-22).** The target ICPs are 1, 2, 3, 4 and 6. ICP 5, the aesthetic customizer, is not a target: we don't design features, onboarding or pricing for them. Their section stays as research. Free-form looks still matter, because every target ICP wants the widget in their own style.

### ICP 1. The shared-household coordinator

**Who.** Parents of young kids, roommates and multi-caregiver homes, usually 25-45. One person sets things up and invites the others.

**Use cases**
- Stop double-feeding the baby or the dog.
- Answer "did anyone water the plants?"
- Split chores visibly.
- Coordinate night feeds at 3 am without texting.

**Today.** Group texts and whiteboards, or a separate app for each job: Feedr for the baby, PawClock for the dog, Potally for plants, Tasky for chores. Free tiers gate sharing. For example, Fed? allows only one family member on its free tier.

**Why Widgie wins.**
- The shared widget, tap-to-log, and the "latest row" and "time since" queries are the whole product for this group.
- One app replaces four.
- The invite link is a built-in growth loop.

**Willingness to pay.** Medium to high. They already pay for single-purpose apps. Gate the number of members, not the core feature.

**Discovery.** Parent TikTok and Instagram, word of mouth through the invite itself.

### ICP 2. Couples and close friends

**Who.** Gen Z and young millennial couples, often long distance, and best-friend pairs. Locket says Gen Alpha is now its core user.

**Use cases**
- Ambient "thinking of you" contact without texting.
- Countdowns to the next visit.
- Shared rituals, like a date jar or a "whose turn to call" tracker.
- Seeing the partner's latest photo or note on every unlock.

**Today.** Locket for photos, Widgetable for virtual pets and "miss you" taps, plus many new copycat apps. Each does one trick in a fixed design. Reviews complain about back-to-back rewarded ads and pet food you need ads or money for.

**Why Widgie wins.** The shared ritual can be anything the couple invents, in a look they choose, often built from their own photos. No current app lets a couple design their own shared logic.

**Willingness to pay.** Proven. Widgetable charges $4.99 a month or $19.99 a year, and Locket Gold costs $3.99 a month.

**Discovery.** TikTok and the invite link.

**Not in v1.** Live distance between partners needs location, and live photo drops need richer media sync.

### ICP 3. The multi-tracker self-improver

**Who.** Adults 22-40 who track several things: water, workouts, mood, sobriety, savings, symptoms. Often they have tried and dropped 3-4 tracker apps.

**Use cases**
- One glance to see today's progress across their own mix of habits.
- Days-since counters.
- A symptom log to show a doctor.

**Today.**
- HabitKit, Streaks, Waterllama and Habitify each do one thing in a fixed design, and their widgets sit behind Pro.
- Power users build Scriptable or Notion plus Shortcuts setups that lag or lose data.

**Why Widgie wins.**
- Counts, sums, streaks and week windows are exactly what this group needs.
- The widget tracks their own definition of a habit, with no template forcing.
- AI can restyle the widget to fight "widget blindness".

**Willingness to pay.** Highest of any segment. Health and fitness converts trials to paid subscriptions at a median 39.9% (RevenueCat 2025).

**Discovery.** Productivity YouTube, App Store search, "my setup" posts.

### ICP 4. The ADHD adult who needs it visible

**Who.** Adults with ADHD or executive-function struggles. 15.5M US adults had a current diagnosis in 2023, and over half were diagnosed as adults (CDC MMWR, Oct 2024). Tiimo, a visual planner for ADHD and autism, was Apple's 2025 iPhone App of the Year.

**Use cases**
- "Out of sight, out of mind": keep the top three tasks, the medication check and the next appointment on the home screen.
- Fight time blindness with visual countdowns.
- Get an answer to "did I already take it?"

**Today.** Rigid planners, wallpapers with reminders baked in, and guides that tell people to move their widgets every week so they don't stop seeing them.

**Why Widgie wins.**
- The widget is built the way their brain works, in their own words.
- Restyling on demand ("make it loud and red") keeps it from going invisible.
- Taps work without opening an app, which removes the friction that kills the habit.

**Willingness to pay.** Medium to high. Tiimo charges about $54 a year. Keep the price predictable; surprise paywalls hurt trust with this group.

**Discovery.** ADHD TikTok and YouTube, App Store editorial.

### ICP 5. The aesthetic customizer (not a target)

**Who.** Teens and Gen Z, likely skewing female (anecdotal, unverified). They chase a vibe and swap setups with each iOS release or trend: the iOS 14 boom, the 2024 bookshelf screens, iOS 26 Liquid Glass and clear setups.

**Use cases**
- Make the phone match a vibe.
- Recreate a setup seen on TikTok or Pinterest.
- Mix cute with useful.

**Today.**
- Widgetsmith, Color Widgets, WidgetClub and theme packs.
- Template-based and static, so everyone's screen looks the same.
- Heavy paywalls, at $12.99-49.99 for packs.
- Widgy is powerful but hard to learn.

**Why Widgie wins.**
- "Make my widget look like this" from a screenshot.
- The user's own photos and AI art, plus a working function underneath the look.

**Willingness to pay.** Low per user, huge in volume. About 4% of downloads pay.

**Discovery.** TikTok tutorials (one video put Widgetsmith at number 1), Pinterest and Lemon8. Downloads spike at each iOS launch, so time marketing pushes to iOS 27 and the 4x6 size.

**Role.** Not a target. They may still arrive through iOS release spikes and TikTok, and some become ICP 2 or ICP 3 users once they have a widget that does something.

### ICP 6. The learner

**Who.** Students and language learners.

**Use cases**
- Days until the exam.
- Study streaks.
- Passive exposure to vocabulary at their level.

**Today.** Exam Countdown, Study Rainbow, and generic word-of-the-day apps that aren't tied to the person's own syllabus or language level.

**Why Widgie wins.** Scheduled AI automations write fresh content shaped to this person: "Spanish B1 words about food", "one physics formula from my syllabus a day".

**Willingness to pay.** Low to moderate. Students are price sensitive. This group is a strong showcase for automations, more than a revenue pillar.

## Widgets each ICP would build

In the tables, "Blocks" names the v1 building blocks each widget uses.

- **Query types:** count, sum, streak, latest, list.
- **Action types:** insert, toggle, set, delete, open form.
- **Other blocks:** AI automation, shared (invite link), photo or AI image asset, reference image.

"Simple" means one table, one query and one action. "Complex" means multiple tables, sharing, automations, conditional looks, or several queries combined. A widget marked **not v1** needs something outside v1, such as live network data, location, or scrolling.

### ICP 1. Shared-household coordinator

| | Widget | Prompt the user might type | Blocks |
|---|---|---|---|
| Simple | Dog fed? | "One button for 'fed the dog', show how long ago and who did it" | insert, latest, shared |
| Simple | Plant watered | "Tap when I water the monstera, turn red after 7 days" | insert, latest, conditional look |
| Simple | Grocery list | "Shared grocery list, tap an item to cross it off" | list, toggle, open form, shared |
| Simple | Trash night | "Whose turn is it to take out the bins, tap to pass it on" | set, latest, shared |
| Complex | Baby feed tracker | "Log feeds with left, right or bottle, show time since last feed and today's count, red after 3 hours, my partner and I both use it" | insert with fields, latest, count today, conditional look, shared |
| Complex | Chore scoreboard | "Chores for me, Sam and Priya, tap to claim one, weekly points per person, a crown on the leader" | 2 tables, insert, sum per person this week, shared |
| Complex | Pet care hub | "Feed, walk and meds for Luna, show what's done today and what's overdue, plus her photo" | 3 actions, latest per type, toggle today, photo asset, shared |
| Complex | House supplies | "Mark when we run out of something, show the 3 most recent, tap to mark bought" | list sorted by latest, toggle, delete, shared |

### ICP 2. Couples and close friends

| | Widget | Prompt | Blocks |
|---|---|---|---|
| Simple | Days together | "How many days since we met, with our photo" | date math in look, photo asset |
| Simple | Visit countdown | "Countdown to when I see Alex on March 3, cute hearts" | look-only, AI image |
| Simple | Thinking of you | "Button that sends a heart to my girlfriend's widget, show how many today" | insert, count today, shared |
| Simple | Mood check-in | "Pick my mood from 5 emojis, show both of our latest moods" | insert, latest per person, shared |
| Complex | Date jar | "Our date ideas list, tap to pull a random one, mark it done, count dates this month" | list, toggle, count month, shared, AI picks an idea daily |
| Complex | Daily question for us | "A new couples question every morning, both of us tap when we've answered" | AI automation daily, toggle per person, shared |
| Complex | Whose turn | "Track who paid for dinner and who called last, show whose turn it is for each" | 2 tables, latest per category, shared |
| Complex | Look from our photo | (attaches a photo) "Make a widget in this style that shows our streak of good-morning taps" | reference image, AI art, streak, shared |
| Not v1 | Distance apart | "How far apart we are right now" | needs live location |

### ICP 3. Multi-tracker self-improver

| | Widget | Prompt | Blocks |
|---|---|---|---|
| Simple | Water | "8 glasses a day, tap to add one, fill a bottle shape" | insert, count today |
| Simple | Days sober | "Days since my last drink, reset button" | latest, set, date math |
| Simple | Pushups | "Add 10 pushups per tap, total this week" | insert with number, sum week |
| Simple | Habit check | "Did I meditate today, show my streak" | toggle, streak |
| Complex | Habit grid | "Gym, reading and no sugar as a GitHub-style grid for the last 4 weeks, tap today's square" | 3 tables, streak each, per-day history, toggle |
| Complex | Symptom log | "Log a migraine with a 1-5 severity and a trigger, show this month's count and average severity" | open form, count month, sum or average, latest |
| Complex | Savings jar | "Add money toward a $2,000 trip, show percent and how much I need per week to hit June" | insert number, sum all, date math in look |
| Complex | Morning dashboard | "Water, steps I type in, mood and sleep hours, all in one large widget" | 4 tables, multiple queries, multiple actions |
| Complex | Weekly coach | "Every Sunday write me one line about my week from my habit data" | AI automation reading query results (needs the automation to see rows: check this against the block design) |
| Not v1 | Auto steps | "Pull steps from Apple Health" | needs HealthKit data source |

### ICP 4. ADHD adult

| | Widget | Prompt | Blocks |
|---|---|---|---|
| Simple | Meds taken? | "Big button: did I take my meds today, shows the time I tapped" | toggle today, latest |
| Simple | Top 3 | "My three tasks for today, tap to check off" | list limit 3, toggle |
| Simple | One thing | "Just show the one thing I'm doing now, loud colors" | set, latest |
| Simple | Countdown bar | "Bar that shrinks until my 3pm appointment" | look-only time math |
| Complex | Brain dump to top 3 | "Inbox I can add to from the widget, and the top 3 oldest unchecked items show first" | open form, list sorted oldest, toggle, delete |
| Complex | Routine runner | "Morning routine steps, tap through them in order, resets every day, show how many mornings I finished this week" | list, toggle, today window reset, count week |
| Complex | Restyle every week | "Change the look of my task widget every Monday so I keep noticing it" | AI automation that changes the look (needs automations to write looks, not only rows) |
| Complex | Medication with backup | "Meds taken check that my partner can see, so they can nudge me" | toggle, latest, shared |

### ICP 5. Aesthetic customizer (not a target, kept for reference)

| | Widget | Prompt | Blocks |
|---|---|---|---|
| Simple | Clone a setup | (attaches a TikTok screenshot) "Make my date widget look like this" | reference image, look-only |
| Simple | Photo plus quote | "My cat photo with a soft serif quote that changes daily" | photo asset, AI automation |
| Simple | Bookshelf | "A bookshelf widget, tap a book to mark it read" | AI art, list, toggle |
| Simple | Matching set | "Make the small and medium sizes match my pink and cream setup" | look in both sizes |
| Complex | Aesthetic habit tracker | "Coquette-style water tracker with little bows that fill up" | AI art assets, count today, conditional look |
| Complex | Daily affirmation | "Every morning a new affirmation in my vibe, tap a heart to save favorites, show the saved count" | AI automation, insert, count |
| Complex | Glass-proof look | "Make this still look good in clear mode" | tinted and clear look handling |
| Complex | 4x6 home screen piece | "One extra-large widget with my calendar, mood and a photo" | multiple tables, new size (iOS 27) |
| Not v1 | Weather in my style | "Weather that matches my theme" | needs a weather data source |

### ICP 6. Learner

| | Widget | Prompt | Blocks |
|---|---|---|---|
| Simple | Exam countdown | "Days until my bio final on Dec 12" | look-only |
| Simple | Study streak | "Tap when I study 25 minutes, show my streak" | insert, streak |
| Simple | Word of the day | "Word of the day in Spanish, B1 level" | AI automation |
| Complex | Vocab with review | "New Japanese word daily, tap 'know it' or 'again', show how many I've learned" | AI automation, insert with field, count |
| Complex | Exam board | "My next 4 exams with days left and how many hours I've studied for each" | 2 tables, list, sum per subject |
| Complex | Syllabus quiz | "One question from my notes every day" (pastes notes) | AI automation with user context |
| Complex | Study group race | "Me and 3 friends log study hours, leaderboard this week" | insert number, sum per person week, shared |

## What this means for the reference set

How the six v1 reference widgets cover the target ICPs:

| Target ICP | Reference widget | What it proves |
|---|---|---|
| 1. Shared household | Dog fed | Shared tap-to-log, who did it and how long ago |
| 2. Couples and friends | Thinking of you | Shared counts split by person, the couple's own photo |
| 3. Multi-tracker | Water logger, habit tracker | Counts toward a daily goal, streaks |
| 4. ADHD adult | To-do list, habit tracker | Check off from the home screen, visible streak |
| 6. Learner | Word of the day | Scheduled AI content |

Every target ICP has at least one reference widget, so the set does not need to grow for this decision.


The v1 reference widgets are water logger, to-do list, habit tracker and word of the day. They cover ICPs 3, 4 and 6 well. Neither of the two highest-revenue patterns is in the set:

1. **A shared tap-to-log widget with "who did it, how long ago"** (dog fed, baby feed). This is ICP 1's core widget. It exercises `latest`, the person who wrote a row, and the push refresh.
2. **A couples widget built from the user's own photo** (thinking-of-you counter with a photo look). This is ICP 2's core widget. It exercises shared counts, photo assets and the reference image.

Both were added to the v1 reference set and definition of done on 2026-11-22 (`tasks/todo.md`, phase 1e), because they are the widgets most likely to make money and spread through invites.

Three block capabilities came up repeatedly in the complex widgets and should be checked against the spec:

- **Who wrote a row.** Users ask for "who fed the dog" and "whose turn it is". This needs the person who wrote each row, plus a "latest per person" or "sum per person" grouping.
- **Automations that read rows** (weekly coach) and **automations that change the look** (restyle every week). Today automations write rows only.
- **Conditional looks based on time since the latest row** (red after 3 hours). This probably already works, because the look gets the latest row and the current time. Confirm it.
