# App shell: Widgets, Make, Templates

Written 2026-11-26 from a read of the app at `c3be5d1`. The approved design is the prototype: `docs/design/app-shell/prototype.html` (built from `prototype.src.html` by `build-prototype.py`).

## Goal

Turn the one-screen app into a modern, clean three-tab app that still feels like Widgie (The Caret in Sky, dark mode is Sky turned dark).

- **Widgets.** Your widgets as a Pinterest-style feed of live faces. Tap one to open it, change it or delete it.
- **Make.** A chat with the caret. You describe a widget, watch it build inline, try it inline, ask for changes, and save it.
- **Templates.** Ready-made widgets taken from the landing page's ideas. You can try one live, fill in a name, and add it at once, or change it in chat.

## Decisions (2026-11-26, from the user)

- Feed layout B: wide (medium) widgets span the full width, and square widgets sit in pairs between them, so every face stays readable and live.
- Templates are real bundled widgets, added at once, with blanks for names. Change it in chat refines them.
- The plan is approved, one PR per unit. Order after U1: U3, U1b, U2, U4, U5 (see U1b's decisions).

## Direction update (2026-11-26, second message)

The user asked for three things: smooth animation everywhere so it feels like a polished product, templates that look like the landing page, and Widgie as the character the app is built around, the way Brainrot (Smolworks) builds around its brain, so the app is not generic.

What Brainrot does that we take, as ideas and not as a look: the character is the hero of every main screen, standing in its own world. Its mood and the scene follow your data. It talks to you in speech bubbles, and it acts out each preset card.

How Widgie does it (prototype: `docs/design/app-shell/prototype.html`, built from the site's own code by `build-prototype.py`):

- **The landing page's world comes into the app, with soft surfaces.** The same sky (`#9cc3f5`), the same widgets, and Bricolage Grotesque (OFL, bundled) for titles and big numbers. The user rejected the site's ink outlines, lips and hard offset shadows in the app ("college project"). Every surface is soft instead: no outlines, soft lifted shadows, glass on the tab bar, and a springy scale on press. Dark mode is Widgie's night: the dusk ground `#2B4E82`, stars, and a moon-white Widgie, as the site's `data-moon` caret already draws.
- **Widgie is the hero.** On Widgets it stands on your first widget and talks: a greeting, and how many widgets are on your home screen. It hops when you tap a widget. On Make it is the one you chat with, and it draws the widget. On Templates it acts out each category: two carets and a heart for For two, a flexed arm for Habits, a jump for Goals.
- **A tab bar of our own,** frosted glass floating over the field: Widgets, Make, Templates. Make is a sun key in the middle with Widgie peeking out of it, as on the app icon. The system tab bar cannot hold a character, so this replaces it.
- **Templates are the landing page's widgets,** drawn the same way and tilted in a pile like the site, by category, with a banner per category. A tap opens a sheet with the tile live, the blank to fill, Add widget, and Change it in chat.
- **Motion everywhere, spring-based, with Reduce Motion respected:** tiles rise in staggered on appear, keys and tiles squish with a spring when pressed, Widgie hops, sways, blinks, leans and changes pose with a spring, bubbles pop in, chat messages slide in, the sketch traces itself and becomes the tile, Save bursts confetti and flies the tile into the Widgets tab, category switches scatter the pile out and back in, the tab highlight slides, and the sky drifts.

What changes in the units: U1 merges as the working shell (tabs, feed, placements, detail). A new unit, U1b, restyles it to the prototype: soft tiles, Widgie's hero on the feed, and the custom tab bar. U2 and U3 follow the prototype. U4 recreates the site's widgets as real widgets. U5 includes a motion pass on device.

## Design sign-off (2026-11-26)

A council (Claude Opus, Gemini Neon, and GPT Sol as a non-blocking voice) reviewed the prototype over nine rounds until both blocking members scored it 9 or above: Opus 9.0, Gemini 9.2. The user approved it ("I like it"). The prototype is now the spec for every unit below. Behaviour to carry over as written, beyond the look:

- Make: the reply, Save and the change chips land on the same frame; chips ride above the composer; a draft stays put while a change lands; a replaced draft asks first ("Keep editing" / "Replace draft"); a new widget starts empty (pet "Not fed", hearts at 0).
- Widgets: Widgie greets the widget it stands on, says what a tap did, and hops between perches; one New tag; an unseen count on the tab; nothing badges when you are already on Widgets.
- Templates: each card is one control with an inert sample face; the sheet starts with the tile's words, says a preview tap is practice, and closes by reversing its opening; drag to dismiss.
- Accessibility: focus moves into sheets and back to the opener, focus survives a widget's redraw, categories use arrow keys, and the tab bar exposes the current page.

## What is wrong today (seen on the simulator)

- One screen does everything. A fixed 60 pt "New widget" slab covers the bottom of the list, and a debug ladybug sits in the header.
- The describe screen is a big field over empty space. Its only examples are three hard-coded chips.
- The flow is four separate full screens (describe, building, try it, saved). Each change hides the last exchange, so it never feels like a conversation.
- There is no way to start from something that already works. Every widget costs a 40 s build.

## Design (first pass, superseded by the prototype where they differ)

- **Tab bar.** U1 uses the native iOS 26 `TabView`. U1b replaces it with the prototype's own glass tab bar, since the system bar cannot hold Widgie.
- **Ground.** Keep the Sky ground and the home-screen dot grid. Cards get softer, bigger shadows and 24 pt corners. Glass material goes only on floating controls (composer, tab bar, chat cards).
- **Type.** Large 34 pt heavy titles with the caret bar after "widgie". 15 to 17 pt body text. No new fonts.
- **Color touches stay as they are:** soft chip fills, caret cheeks, and caret confetti on save.
- **The standing bans still hold:** no cream ground, no italic accents, no 01/02 labels, no monospace labels, no pill buttons of our own. The system tab bar is the one exception, because the system draws it.

## Units (one PR each, in order)

### U1. Shell and the Widgets feed

- [x] `RootView` holds a `TabView` with Widgets and Make (Templates arrives with U3). `WidgieApp` shows it instead of `LibraryView`. The selected tab is `RootView` state; the feed's empty state and a save switch tabs through it. The Make tab hosts the describe flow without its close button, and a save refreshes the feed at once.
- [x] `WidgetsFeed` replaces `LibraryView`. The layout is B: wide widgets fill a row, smalls pair up. Each card shows a live face with a caption: its name and a phone mark when it is on the home screen.
- [x] "On your home screen" comes from `WidgetCenter.shared.currentConfigurations()`, mapping each `PickWidget` configuration to its widget id. It is refreshed when the app becomes active.
- [x] The feed's empty state: the caret and one line, with "Make one" (switches to Make). "Browse templates" comes with U3.
- [x] `WidgetDetail` sheet: live faces in both sizes, three steps for adding it to the home screen, Change it (opens the describe flow as a full screen cover with `DescribeSession(editing:)`), and Delete with a confirmation, the same one the feed's long press asks.
- [x] The debug fixture menu moves off the header into a long press on the title, still DEBUG only.
- [x] **Check:** simulator screenshots of the feed, the empty state and the detail sheet, light and dark. The Dynamic Type and placed-dot checks move to U5's pass.

### U1b. Restyle to the prototype

The Widgets tab and the tab bar as drawn in the prototype, on the current app's data. Make keeps today's describe flow (U2 restyles it) but sits on the new sky and in the new tab bar. Branch `app-shell-u1b`, one PR.

**Ground and type**

- [ ] `Sky`: the ground for every screen, replacing the flat color and the dot grid. Day is the prototype's gradient (`#B4D4FB` to `#9CC3F5` to `#8AB6F0`) with two soft clouds drifting high up; night (dark mode) is the dusk gradient (`#14284F` to `#223F72` to `#2B4E82`) with 26 twinkling stars and a crescent moon top right. The moon fades out when the page scrolls past 24 pt. Clouds drift and stars twinkle only without Reduce Motion. Tokens go in `WidgieColors.xcassets` so day and night stay one edit each.
- [ ] Bricolage Grotesque (OFL) for titles and big numbers. The site ships a 268-glyph Latin subset as woff2, which iOS cannot load and which lacks accented letters. Bundle static TTF instances cut from the full variable font (google/fonts), at the prototype's settings: 96 pt optical size, 92 percent width, Bold and ExtraBold. A `display(size:)` font helper scales with Dynamic Type like `font(size:weight:)`. Its OFL license goes next to it.

**The Widgets header and Widgie**

- [ ] Header: the date as an eyebrow, "Good morning / afternoon / evening" from the clock in Bricolage, and the count line "9 widgets · [phone mark] 6 on Home Screen" with the prototype's phone-with-two-widgets mark.
- [ ] Widgie stands on the first row: on the right card of a pair (leaning left, toward its bubble), or on a wide card clear of the count line. Its foot plants 2 pt into the face with a small contact shadow. The bubble sits to its left and fits its words.
- [ ] What Widgie says. The app does not know what an AI-made widget means, so lines are about the widget, never invented data:
  - greeting by day: "Morning! Here's Water." style lines naming the widget under it, or "Tell me a widget." with none; at night, "I'll keep an eye on Water tonight."
  - after a tap on a live face: a hop and a short line naming the widget ("Water, updated."), then back to the greeting after 2.4 s;
  - when a new widget lands: "Here's Biscuit. Give it a tap." if it has buttons, "Here's Biscuit, ready to go." if not.
- [ ] Motion: Widgie hops from the old perch to the new one when the first row changes (lift 40 pt, squash on touchdown, shadow out and back, bubble after touchdown, 560 ms); idle life every 8 to 11 s (double blink, glance, small hop) only while the page is at the top and untouched for 4 s; all of it off with Reduce Motion.

**The feed**

- [ ] Cards: soft lifted shadows (no outlines), a springy press, and captions in 15 pt semibold with the phone mark when placed. The newest widget wears a yellow New tag until the next one arrives.
- [ ] A new small widget joins the first row on the right, under Widgie, paired with the next small one (`FeedRow.rows` gains `fresh:`; tests extended).
- [ ] Arrival: the feed scrolls to the top, the new card settles in from 94 percent over 260 ms, and Widgie reacts on contact.
- [ ] Empty state on the sky: the big Widgie with its bubble "Tell me a widget." and Make one.
- [ ] The detail sheet in the prototype's sheet style: rounded 36 pt top, the light sheet gradient by day and dusk by night, a 34 pt soft square close button, and the same keys. Behaviour unchanged.

**The tab bar**

- [ ] A custom tab container replaces `TabView`: both pages stay alive, the outgoing page fades in 120 ms and the incoming one fades and slides 14 pt after 40 ms.
- [ ] The bar: frosted glass floating over the sky with a white pill that springs to the chosen tab, glyphs at 2.4 pt stroke when chosen, and 60 percent ink when not. Widgets, Make in the middle, and Templates (built in U3 first).
- [ ] The Make key: Widgie in a small rounded key, quiet when unchosen and sun yellow when chosen, hopping as you switch to it.
- [ ] The badge: a coral count of widgets saved while you were not on Widgets, cleared when you open it, with "Widgets, 2 new" as its accessibility label. A save while you are on Widgets badges nothing.
- [ ] Accessibility: the bar exposes the chosen tab as selected, decorative glyphs are hidden, Widgie's bubble is announced politely, and every control keeps a 44 pt target.

**Checks**

- [ ] App tests: `FeedRow.rows` with `fresh`, the greeting and tap lines, the unseen count, and the moon's scroll rule.
- [ ] Simulator screenshots side by side with the prototype, light and dark: the feed at the top and scrolled, the empty state, a new widget landing, the detail sheet, and the Make tab.
- [ ] Largest Dynamic Type size and Reduce Motion pass on the feed and the bar.
- [ ] `scripts/check` green, a review guide in `docs/pr/`, a fresh review, then merge.

Decisions (2026-11-26, from the user):

- Widgie's lines are about the widget's name and what just happened, not its data, because the app cannot read meaning from an AI-made widget. The prototype's "12 days until Lisbon!" style needs widgets to declare a glance line, which belongs to a later phase.
- Templates comes first: U3 (and the content it needs) lands before U1b, so the new tab bar ships with all three tabs and Make in the middle. The order is U3, U1b, U2, U4, U5.

### U2. Make as a chat

- [ ] `DescribeSession` keeps every turn (`turns: [Turn]`) instead of only `latest`. The state machine, the scratch engine, and the rule that a failed turn never replaces the draft all stay. Its tests are updated and extended.
- [ ] `ChatView` replaces the describe, building, and try-it screens, as drawn in the prototype. It shows the person's words as ink bubbles. Each accepted turn shows a card with the live draft face (tappable), a one-line note, and the samples menu. While a turn builds, a caret line shows the step title. A smaller version of the outline sketch is in scope if it reads well at that size.
- [ ] The empty state: the big caret, "What should we make?", one line, and three suggestion chips drawn from the template catalog, so they change.
- [ ] The composer is pinned above the tab bar: photo button, a growing field with the caret bar, and a send button. Return sends.
- [ ] Save goes in the top bar. Saving keeps today's Saved moment (caret jump and confetti) as an overlay, then "See it in Widgets" switches tabs and starts a fresh session.
- [ ] Failures show inline as a slumped grey caret message with the one-line title and the action button (Try again, Say it another way). The full grey failure screen goes away, except `.unopened`, which keeps a full screen because there is nothing to chat about.
- [ ] Editing a library widget uses the same `ChatView` in a sheet, opening on the current widget's card.
- [ ] Leaving with an unsaved draft: the Make tab keeps its session when you switch tabs. Discarding is an explicit "Start over" in the top bar menu, with confirmation.
- [ ] **Check:** a full create flow on the simulator against the dev bridge. Then a refine, a cancel mid-build, a give-up, a bridge that is down, and a save, with screenshots of each in light and dark. `log stream` timings match the current flow.

### U3. Templates tab

- [x] `Template` data: one folder per template under `App/Templates/<id>/` with `widget.json` (the same format as the fixtures, samples included) and `template.json` (`name`, `line`, `category`, `order`, `family` for its size in the pile, `hint` for Widgie's first line in the sheet, and `blanks: [{key, label, placeholder}]`). Templates ship in release builds, unlike the debug fixtures. The `suggestion` for the chat chips comes with U2, which uses it.
- [x] Blanks: substitution runs on the decoded document, never on raw text. In `name` and other plain strings, `{{key}}` becomes the value. In `look`, `{{key}}` becomes a complete JSON string literal, quotes included, which is also a valid JS string literal, so templates write `const PET = {{pet}};`. The result then goes through `engine.build`, the same path every widget takes. An empty blank uses its placeholder ("Luna").
- [x] The six fixtures moved over as the first templates, named as in the prototype: For two "Thinking of you" (blank: who gets the hearts), Home "Pet fed" (blank: the pet's name) and "To-do list", Habits "Habit squares" (blank: the habit) and "Water", Goals "Word of the day". `Engine/Fixtures/` stays as it is, because engine tests read it.
- [x] `TemplatesView`, as drawn in the prototype: the eyebrow and title, the category chips (For two, Home, Habits, Goals: no All and no Learning, as in the prototype, with word of the day in Goals), a banner per category where Widgie acts it out, and the pile: the feed's layout with each card tilted, one button with an inert sample face. Faces render from the first sample in the gallery's own scratch engine, at the column size, lazily, once per template.
- [x] `TemplateSheet`, the native sheet fitted to its content: the live face (taps work on scratch data and Widgie calls them practice), Widgie's bubble starting with the template's hint, the blank fields (a typed name rebuilds the face), Add widget (builds into the library, then switches to Widgets with the new card highlighted), and Change in chat (opens Make with the filled template as the draft, so the first message is a refine; a draft already in Make asks first).
- [x] The feed's empty state gains Browse templates. The display face is `display(size:)`, the system font at heavy weight until U1b bundles Bricolage.
- [x] **Check:** every template builds through `engine.build` in an app test, with and without blank values, including a value with quotes and emoji. On the simulator: browse, filter, try, add with a name, and change in chat. Screenshots in light and dark, and at the largest text size.

### U4. Template content

Taken from the landing page (`Site/public/widgets.js`), grouped by the prototype's four categories. U3 moved the six fixtures over (thinking of you, pet fed, to-do list, habit squares, water, word of the day); these are the rest.

- [ ] For two: our moods, today's question, days together, trip countdown.
- [ ] Home: bins rota, shared groceries, plant care, chores scoreboard, dinner tonight, baby feeds.
- [ ] Habits: meditate streak, pushups this week.
- [ ] Goals: savings jar, alcohol-free days.
- [ ] Each one is written with the dev bridge, checked with `render-tool proof`, and looked at as small and medium PNGs in full color and tinted mode before it is committed. Shared widgets (groceries, hearts) work on one phone until phase 4 sync. Their line says so only if it would otherwise mislead.

### U5. Polish and the end-to-end check

- [ ] One pass on the simulator over every screen, light and dark, at default and the largest Dynamic Type size, with VoiceOver labels on every control. Fix anything that looks off.
- [ ] `scripts/check` is green, with no new warnings.
- [ ] A review guide in `docs/pr/` for each PR.

## Risks

- **Live faces in a scrolling feed.** Each card is a `FaceView`. Twenty templates means twenty QuickJS renders when the tab opens. Render faces lazily as cards appear, cache them per template, and measure on the simulator.
- **Small widgets at column width.** A 158 pt face shown at 179 pt is scaled up by 1.13. The engine can render at the column size instead, which keeps it sharp. Use the size parameter, not `scaleEffect`.
- **Blanks inside look code.** In `look` a blank is always a whole quoted literal, so no value can break out of a string or inject code. A test covers quotes, backslashes, `</script>`, and emoji.
