# App shell: Widgets, Make, Templates

Written 2026-11-26 from a read of the app at `c3be5d1`. Mocks: `docs/design/app-shell/mocks.html`.

## Goal

Turn the one-screen app into a modern, clean three-tab app that still feels like Widgie (The Caret in Sky, dark mode is Sky turned dark).

- **Widgets.** Your widgets as a Pinterest-style feed of live faces. Tap one to open it, change it or delete it.
- **Make.** A chat with the caret. You describe a widget, watch it build inline, try it inline, ask for changes, and save it.
- **Templates.** Ready-made widgets taken from the landing page's ideas. You can try one live, fill in a name, and add it at once, or change it in chat.

## Decisions (2026-11-26, from the user)

- Feed layout B: wide (medium) widgets span the full width, and square widgets sit in pairs between them, so every face stays readable and live.
- Templates are real bundled widgets, added at once, with blanks for names. Change it in chat refines them.
- The plan is approved, to run U1 to U5 in order, one PR each.

## Direction update (2026-11-26, second message)

The user asked for three things: smooth animation everywhere so it feels like a polished product, templates that look like the landing page, and Widgie as the character the app is built around, the way Brainrot (Smolworks) builds around its brain, so the app is not generic.

What Brainrot does that we take, as ideas and not as a look: the character is the hero of every main screen, standing in its own world. Its mood and the scene follow your data. It talks to you in speech bubbles, and it acts out each preset card.

How Widgie does it (prototype: `docs/design/app-shell/prototype.html`, built from the site's own code by `build-prototype.py`):

- **The landing page's toy box comes into the app.** Same sky (`#9cc3f5`), ink outlines, tiles with a solid lip and a hard shadow, keys that press down, and Bricolage Grotesque (OFL, bundled) for titles and big numbers. Dark mode is Widgie's night: the dusk ground `#2B4E82`, stars, and a moon-white Widgie, as the site's `data-moon` caret already draws.
- **Widgie is the hero.** On Widgets it stands on your first widget and talks: a greeting, and how many widgets are on your home screen. It hops when you tap a widget. On Make it is the one you chat with, and it draws the widget. On Templates it acts out each category: two carets and a heart for For two, a flexed arm for Habits, a jump for Goals.
- **A tab bar of our own,** a toy tile floating over the field: Widgets, Make, Templates. Make is a sun key in the middle with Widgie peeking out of it, as on the app icon. The system tab bar cannot hold a character, so this replaces it.
- **Templates are the landing page's widgets,** drawn the same way and tilted in a pile like the site, by category, with a banner per category. A tap opens a sheet with the tile live, the blank to fill, Add widget, and Change it in chat.
- **Motion everywhere, spring-based, with Reduce Motion respected:** tiles rise in staggered on appear, keys and tiles press down onto their lip, Widgie hops, sways, blinks, leans and changes pose with a spring, bubbles pop in, chat messages slide in, the sketch traces itself and becomes the tile, Save bursts confetti and flies the tile into the Widgets tab, category switches scatter the pile out and back in, the tab highlight slides, and the sky drifts.

What changes in the units: U1 gains the toy box tiles, Widgie's hero, and the custom tab bar (before PR 15 merges). U2 and U3 follow the prototype. U4 recreates the site's widgets as real widgets. U5 includes a motion pass on device.

## What is wrong today (seen on the simulator)

- One screen does everything. A fixed 60 pt "New widget" slab covers the bottom of the list, and a debug ladybug sits in the header.
- The describe screen is a big field over empty space. Its only examples are three hard-coded chips.
- The flow is four separate full screens (describe, building, try it, saved). Each change hides the last exchange, so it never feels like a conversation.
- There is no way to start from something that already works. Every widget costs a 40 s build.

## Design (see the mocks)

- **Tab bar.** The native iOS 26 `TabView` (Liquid Glass): Widgets, Make, Templates. The system draws it, so it stays current with iOS and needs no custom code.
- **Ground.** Keep the Sky ground and the home-screen dot grid. Cards get softer, bigger shadows and 24 pt corners. Glass material goes only on floating controls (composer, tab bar, chat cards).
- **Type.** Large 34 pt heavy titles with the caret bar after "widgie". 15 to 17 pt body text. No new fonts.
- **Color touches stay as they are:** soft chip fills, caret cheeks, and caret confetti on save.
- **The standing bans still hold:** no cream ground, no italic accents, no 01/02 labels, no monospace labels, no pill buttons of our own. The system tab bar is the one exception, because the system draws it.

## Units (one PR each, in order)

### U1. Shell and the Widgets feed

- [x] `RootView` holds a `TabView` with the three tabs. `WidgieApp` shows it instead of `LibraryView`. A selected-tab binding lets other screens switch tabs, for example "See it in Widgets" after a save.
- [x] `WidgetsFeed` replaces `LibraryView`. The layout is B from the mocks. Each card shows a live face with a caption: name, a "placed" dot, and a relative time.
- [x] "On your home screen" comes from `WidgetCenter.shared.currentConfigurations()`, mapping each `PickWidget` configuration to its widget id. It is refreshed when the app becomes active.
- [x] The feed's empty state: the caret and one line, with "Make one" (switches to Make). "Browse templates" comes with U3.
- [x] `WidgetDetail` sheet: live faces in both sizes, three steps for adding it to the home screen, Change it (opens the chat as a sheet with `DescribeSession(editing:)`), and Delete with a confirmation.
- [x] The debug fixture menu moves off the header into a long press on the title, still DEBUG only.
- [ ] **Check:** simulator screenshots, light and dark, with 0, 1, and 7 widgets. Taps on a live face change the data. The placed dot is right after adding and removing a home screen widget. Largest Dynamic Type size reflows without clipping.

### U2. Make as a chat

- [ ] `DescribeSession` keeps every turn (`turns: [Turn]`) instead of only `latest`. The state machine, the scratch engine, and the rule that a failed turn never replaces the draft all stay. Its tests are updated and extended.
- [ ] `ChatView` replaces the describe, building, and try-it screens. It shows the person's words as ink bubbles. Each accepted turn shows a card with the live draft face (tappable), a one-line note, and the samples menu. While a turn builds, a caret line shows the step title. A smaller version of the outline sketch is in scope if it reads well at that size.
- [ ] The empty state: the big caret, "What should we make?", one line, and three suggestion chips drawn from the template catalog, so they change.
- [ ] The composer is pinned above the tab bar: photo button, a growing field with the caret bar, and a send button. Return sends.
- [ ] Save goes in the top bar. Saving keeps today's Saved moment (caret jump and confetti) as an overlay, then "See it in Widgets" switches tabs and starts a fresh session.
- [ ] Failures show inline as a slumped grey caret message with the one-line title and the action button (Try again, Say it another way). The full grey failure screen goes away, except `.unopened`, which keeps a full screen because there is nothing to chat about.
- [ ] Editing a library widget uses the same `ChatView` in a sheet, opening on the current widget's card.
- [ ] Leaving with an unsaved draft: the Make tab keeps its session when you switch tabs. Discarding is an explicit "Start over" in the top bar menu, with confirmation.
- [ ] **Check:** a full create flow on the simulator against the dev bridge. Then a refine, a cancel mid-build, a give-up, a bridge that is down, and a save, with screenshots of each in light and dark. `log stream` timings match the current flow.

### U3. Templates tab

- [ ] `Template` data: one folder per template under `App/Templates/<id>/` with `widget.json` (the same format as the fixtures, samples included) and `template.json` (`name`, `line`, `category`, `blanks: [{key, label, placeholder}]`, `suggestion` for the chat chips). Templates ship in release builds, unlike the debug fixtures.
- [ ] Blanks: substitution runs on the decoded document, never on raw text. In `name` and other plain strings, `{{key}}` becomes the value. In `look`, `{{key}}` becomes a complete JSON string literal, quotes included, which is also a valid JS string literal, so templates write `const PET = {{pet}};`. The result then goes through `engine.build`, the same path every widget takes. An empty blank uses its placeholder ("Luna").
- [ ] `TemplatesView`: a title, category chips (All, For two, Home, Habits, Goals, Learning), and the same feed layout as Widgets, with name and line under each face. Faces render from a sample in a scratch engine, so they look alive.
- [ ] `TemplateDetail` sheet: a live try-it face (taps work on scratch data), the blank fields, Add widget (builds into the library, then switches to Widgets with the new card highlighted), and Change it in chat (opens Make with the filled template as the draft, so the first message is a refine).
- [ ] **Check:** every template builds through `engine.build` in an app test, with and without blank values, including a value with quotes and emoji. On the simulator: browse, filter, try, add with a name, and change in chat. Screenshots in light and dark.

### U4. Template content

Taken from the landing page (`Site/public/widgets.js`), grouped by the categories above. Six already exist as fixtures (dog fed, hearts, water, habit, to-do, word of the day) and move over.

- [ ] For two: thinking of you, our moods, today's question, days together, trip countdown.
- [ ] Home: pet fed, bins rota, shared groceries, plant care, chores scoreboard, dinner tonight, baby feeds.
- [ ] Habits: water, meditate streak, habit squares, pushups this week.
- [ ] Goals: savings jar, alcohol-free days.
- [ ] Learning: word of the day.
- [ ] Each one is written with the dev bridge, checked with `render-tool proof`, and looked at as small and medium PNGs in full color and tinted mode before it is committed. Shared widgets (groceries, hearts) work on one phone until phase 4 sync. Their line says so only if it would otherwise mislead.

### U5. Polish and the end-to-end check

- [ ] One pass on the simulator over every screen, light and dark, at default and the largest Dynamic Type size, with VoiceOver labels on every control. Fix anything that looks off.
- [ ] `scripts/check` is green, with no new warnings.
- [ ] A review guide in `docs/pr/` for each PR.

## Risks

- **Live faces in a scrolling feed.** Each card is a `FaceView`. Twenty templates means twenty QuickJS renders when the tab opens. Render faces lazily as cards appear, cache them per template, and measure on the simulator.
- **Small widgets at column width.** A 158 pt face shown at 179 pt is scaled up by 1.13. The engine can render at the column size instead, which keeps it sharp. Use the size parameter, not `scaleEffect`.
- **Blanks inside look code.** In `look` a blank is always a whole quoted literal, so no value can break out of a string or inject code. A test covers quotes, backslashes, `</script>`, and emoji.
