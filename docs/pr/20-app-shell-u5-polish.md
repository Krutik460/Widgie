# PR 20: the polish and end-to-end pass, and VoiceOver labels for face buttons

Branch `app-shell-u5-polish` into `main`. This is U5 of [tasks/app-shell.md](../../tasks/app-shell.md), the last unit: a walk over every screen of the app shell against the approved [prototype](../design/app-shell/prototype.src.html), light and dark, at the largest text size and with Reduce Motion, with every screen's accessibility tree read, and the fixes the walk found.

## Core changes

- **A face's buttons speak.** The look vocabulary's `button` takes a `label` ([Vocabulary.swift](../../Engine/Sources/WidgetEngine/Vocabulary.swift)). `Kind.button` carries the resolved label, never empty: the look's label, else the words the button shows, joined with commas, else its action's id as words ("markFed" reads "Mark fed"). [NodeView.swift](../../Engine/Sources/WidgetEngine/NodeView.swift) puts it on the button, so the app, the sheets, Make's draft and the home screen widget all read it. `Face.buttonLabels` exposes what VoiceOver reads, for tests. [look.md](../../Engine/Reference/look.md) teaches it and its examples use it; the Worker prompt is regenerated ([build-prompt.txt](../../Backend/src/build-prompt.txt)).
- **Every icon-only key in the 19 templates says which one it is**: "Fed Luna", "Send Sam a heart", "Read, today, done", "Your mood, okay", "Remove Basil", "Undo". The whole-tile buttons read their number and what a tap does ("Lisbon, 12 days until our trip, change the date"). The edits are plain look changes in `App/Templates/*/widget.json`.
- **A button's whole frame is its target.** The renderer puts the button node's own frame, padding and layers inside the button and gives them a rectangular content shape, so a 13 point plus padded to 30 points takes taps, and VoiceOver's outline, across 30 points instead of the 13 the glyph covers.
- **Display type sits on the prototype's line.** The display style trims Bricolage's 1.2 line to the prototype's CSS line height (0.98, 1.02 on the banner), so page titles and everything under them line up with the prototype ([Theme.swift](../../App/Widgie/Design/Theme.swift)).
- **No pull to refresh on the feed.** The prototype has none, the feed already draws again when it needs to, and its control stayed in the accessibility tree while the page was hidden ([WidgetsFeed.swift](../../App/Widgie/Widgets/WidgetsFeed.swift)).
- **Practice survives a typed name.** `Preview.adopt(_:replacing:)` shows a new revision of the draft on show without reloading its sample ([Preview.swift](../../App/Widgie/Preview.swift)), so a tap tried in a template sheet stays when the person then types a name.
- **Confetti leaves with its page.** `Flights.settle()` fades out the confetti in the air when the tab changes ([Flight.swift](../../App/Widgie/Flight.swift), [RootView.swift](../../App/Widgie/RootView.swift)); a tile in flight still lands.
- **What the walk fixed**: the template sheet's blank fields and a form's fields had no VoiceOver label; the detail sheet read two identical "Fed Luna" keys with nothing to tell them apart; a form's question trailed off in the bar ("When do you fly, and..."); opening a widget or a template in chat scrolled Widgie's first line under the title; the Templates title sat 8 points lower than the other pages' titles.

## 1. A face button, from the look to VoiceOver

```mermaid
flowchart TD
  LOOK["look: { type: 'button', action, rowId, label?, children }"] --> PARSE["Vocabulary button: press, children, label read as a string up to 1000"]
  PARSE --> SPOKEN["spokenLabel: label, else the shown words that are not blank, joined with ', ', else readable(action)"]
  SPOKEN --> KIND["Kind.button(Press, label: String, children:)"]
  KIND --> RENDER["NodeView: host.button or host.form around the children and the node's own frame, padding and layers, contentShape(Rectangle()) before effects and transforms, accessibilityLabel(label)"]
  RENDER --> APP["FaceHost.app: Button in the feed, the sheets, Make's draft"]
  RENDER --> WIDGET["FaceHost.widget: Button(intent: RunAction) on the home screen"]
  KIND --> READ["Face.buttonLabels: what VoiceOver reads, in tree order"]
```

Files: [Vocabulary.swift](../../Engine/Sources/WidgetEngine/Vocabulary.swift), [Drawing.swift](../../Engine/Sources/WidgetEngine/Drawing.swift), [NodeView.swift](../../Engine/Sources/WidgetEngine/NodeView.swift), [Engine.swift](../../Engine/Sources/WidgetEngine/Engine.swift), [Public.swift](../../Engine/Sources/WidgetEngine/Public.swift), [look.md](../../Engine/Reference/look.md), [LabelTests.swift](../../Engine/Tests/LookTests/LabelTests.swift), [RendererTests.swift](../../Engine/Tests/LookTests/RendererTests.swift), [MistakeTests.swift](../../Engine/Tests/LookTests/MistakeTests.swift), [TemplateTests.swift](../../App/WidgieTests/TemplateTests.swift), [FeedCard.swift](../../App/Widgie/Widgets/FeedCard.swift).

Key decisions:

- **Both an optional label and a fallback.** A label the look writes says what the key means ("Fed Luna"); the fallback means a model that forgets one still gets a usable button, never a blank one. A model on Sonnet wrote labels on its own after the prompt change ("Mark the dog fed", "Log a feeding").
- **Shown words win over the action's name**, so "Know it" reads "Know it", not "Know". The label wins over both, so "+10" can read "Add 10 pushups".
- **The label is resolved once, in validation**, so the renderer stays total and every host gets the same words. It is not part of `Tap`, which is Codable for the App Intent and the form link.
- **A label may be as long as a text** (1000 characters). The first limit, 100, failed the proof for groceries in the full state, whose rows carry 1000-character titles: a label built from a row must never reject a widget.
- **An empty or blank label falls back** rather than failing the look, since a look often writes `label: done ? 'Done' : ''`. Blank shown words are left out of the fallback too.
- **One way to read an id.** The fallback and a form's titles and field labels share `readable(_:)`.
- **The button wraps the whole node.** A button's own frame, padding and layers are inside the host's `Button`, so `{ type: 'button', padding: 8, background, children: [13 pt symbol] }` is a 29 point target, as `look.md` asks. The content shape comes after the layers and before the effects and transforms, so a scaled or offset button takes taps where it is drawn. A test clicks a real window: inside the padding the button runs, past the frame it does not. The fit probe still measures the children, as for every other node.
- **A whole-tile button says what a tap does.** On the trip, days together and days free tiles the face is one button that sets the date, so only the caption opens the detail sheet there; their labels end with "change the date" or "change the day you started".
- **The app test reads every template in every proved state**, both sizes: no two labels read the same (except in the synthesized full state, which repeats one title in every row), and a table pins the icon-only keys' and the whole tiles' words.

## 2. Practice in a template sheet, then a typed name

```mermaid
flowchart TD
  OPEN["TemplateSheet opens: TemplateTrial.fill, adopt(source) loads the first sample"] --> TAP["tap on the live face: Preview.perform on scratch rows; Just practice. Yours starts fresh."]
  TAP --> TYPE["a name typed into a blank"]
  TYPE --> REBUILD["buildLatest: adopt(filled source, replacing: draft)"]
  REBUILD --> KEEP["show(draft, keepingRows: true): the rows stay, the tap included"]
  KEEP --> FACE["the face shows the new name and the practice tap; Widgie: Alex it is."]
```

Files: [Preview.swift](../../App/Widgie/Preview.swift), [TemplateTrial.swift](../../App/Widgie/Templates/TemplateTrial.swift), [TemplateTests.swift](../../App/WidgieTests/TemplateTests.swift).

Key decisions:

- **Kept, not replayed.** Filling a blank changes only the widget's name and the look's constants, which a test holds every bundled template to. No template's samples use a blank, and the tables stay the same, so the rows the draft has are exactly what a reload would give plus the person's taps. On the simulator, Thinking of you went from "you sent 3" to 4 on a practice tap and stayed at 4 as "Sam" became "Alex".
- **Only `adopt(_:replacing:)` keeps rows.** A first adopt and every Make turn still load afresh, since a change in chat may change the tables.

## 3. A tab switch during Add widget or Save

```mermaid
flowchart TD
  ADD["Add widget or Save widget"] --> BURST["Flights.burst: confetti in the flight window, 1.15 s"]
  BURST --> FLY["Flights.fly: the tile arcs into the Widgets glyph, 0.48 s"]
  BURST -->|"the person switches tabs"| SETTLE["RootView onChange(tabs.page): flights.settle()"]
  SETTLE --> FADE["bursts removed in a 0.12 s fade, as the page fades out"]
  FLY --> LAND["the tile still lands; the glyph squishes; the badge or the landing"]
```

Files: [Flight.swift](../../App/Widgie/Flight.swift), [RootView.swift](../../App/Widgie/RootView.swift), [ShellTests.swift](../../App/WidgieTests/ShellTests.swift).

Key decisions:

- **The tile keeps flying.** It lands in the tab bar, which every page shares, and its landing drives the badge and the count.
- **The window still goes when nothing flies**, through the burst's own timer, so `settle` adds no lifecycle of its own.

## 4. The end-to-end pass

```mermaid
flowchart TD
  SEED["test simulator: ten templates added through the sheets, then tapped and filled through forms to look like the prototype's feed"] --> WALK["each screen, day and night: Widgets, the detail sheet, Make empty, building, draft, change, replace, save, Templates x4, a sheet"]
  WALK --> AX["axe describe-ui on each: labels, duplicates, the selected tab"]
  WALK --> SIZES["largest accessibility text size and Reduce Motion on the feed"]
  AX --> FIX["fixes, each rebuilt and checked again on the simulator"]
  SIZES --> FIX
  FIX --> SHOTS["final montages: prototype left, app right, day then night"]
```

Files: [TemplateSheet.swift](../../App/Widgie/Templates/TemplateSheet.swift), [FormSheet.swift](../../App/Widgie/FormSheet.swift), [WidgetDetail.swift](../../App/Widgie/Widgets/WidgetDetail.swift), [ChatView.swift](../../App/Widgie/Describe/ChatView.swift), [TemplatesView.swift](../../App/Widgie/Templates/TemplatesView.swift).

Key decisions:

- **The opening line is not held.** `hold(draftAt:)` scrolls by as much as new messages pushed the draft down; on opening an edit, Widgie's first line went in above the card and the hold hid it under the title. It now skips the one move the opening line makes, and still holds the draft through anything else, a redraw before the first turn included.
- **The detail sheet's faces are groups named "Medium size" and "Small size"**, so VoiceOver says which of the two "Fed Luna" keys it is on.
- **A form's question wraps to two lines** in the bar instead of trailing off. It needs a fixed vertical size, since the bar offers its title one line.
- **A form's field keeps its label.** Without `accessibilityLabel`, a filled field read only its value ("SFO"), with no "From".
- **The feed in the screenshots holds ten widgets.** The size rhythm counts from the oldest, and ten (the prototype's nine plus Word of the day under them) put Lisbon, Groceries and Japan fund wide as the prototype does. Nothing is on the simulator's home screen, so no card wears the phone mark.

Open, not fixed here:

- In the template pile, the inert faces' text carries the button's label under the card's own label. VoiceOver reads only the card, which is one control, but `axe` shows the inner words.

## 5. A page's head, from the display style to the first card

```mermaid
flowchart TD
  STYLE["display(size:lineHeight:): Bricolage at the scaled size, padding of (lineHeight x size - the font's line) / 2 at the top and the bottom"] --> TITLE["page titles: 40 pt on a 39.2 pt line, as the prototype's .display"]
  STYLE --> OTHER["the bar's 28, the sheets' 34, the banner's 27 on 1.02"]
  TITLE --> FEED["Widgets head: date, 7.75, title, 10.8, count line: the prototype's absolute 6, 30 and 80"]
  TITLE --> HEADS["Make and Templates heads: eyebrow, 6, title, as the prototype's .head"]
  FEED --> STAGE["Widgie, its bubble and the first card follow the head"]
  HEADS --> CHIPS["Templates chips, Make's stage"]
```

Files: [Theme.swift](../../App/Widgie/Design/Theme.swift), [WidgetsFeed.swift](../../App/Widgie/Widgets/WidgetsFeed.swift), [TemplateBanner.swift](../../App/Widgie/Templates/TemplateBanner.swift), [ChatView.swift](../../App/Widgie/Describe/ChatView.swift).

Key decisions:

- **Fixed in the style, not per page.** Every display title is set on the prototype's line, so the pages and the sheets need no offsets of their own. Measured by the ink in day screenshots of both, against the prototype (before, then after): on Widgets the title +3.2 to +0.6, the count line +6.3 to -0.1, Widgie +6.3 to +0.6, the bubble +6.1 to -0.2, the first card +7.7 to +1.4; on Make and Templates the title +5.8 to +1.5 and the chips +10.2 to +1.5. What is left is SF's line under the eyebrow, 17.5 points to the browser's 16.25.
- **Make's chat bar and thread start where the prototype's do.** The bar's row sat 6 points low (4 under the safe area where the prototype starts it 2 above) and the first message 18 points high (20 under the row where the prototype has 38: its bar's 10, the 8 under it and the thread's 20). Both now match within 1 point.
- **Padding, not `lineHeight(.exact)`.** iOS 26's exact line height sets the box but moves the glyphs down by an amount that does not follow the font's metrics, so it would need a measured correction. Padding is exact for one line. A wrapped title keeps iOS's 1.2 between lines, since negative line spacing is ignored; the banner's second line sits 3.6 points low.
- **Dynamic Type** scales the size and the trim together, so the largest text sizes keep the same rhythm.

## 6. Pull to refresh, removed

Files: [WidgetsFeed.swift](../../App/Widgie/Widgets/WidgetsFeed.swift).

Key decisions:

- **Removed rather than hidden.** A hidden page's UIKit scroll view still lists its refresh control ("Refreshing content") in the accessibility tree, and neither `accessibilityHidden`, `accessibilityElement(children: .ignore)`, `disabled` nor `scrollDisabled` on the page removes it; taking `.refreshable` off only while hidden would rebuild the feed's scroll view and lose its place. The prototype has no pull to refresh, and the feed already draws again on coming to the foreground, at each face's next change, and after every add and save, so nothing is lost. `axe describe-ui` on Make and Templates no longer lists it.

## Side-by-sides

Twenty montages, each one state with the prototype on the left and the app on the right, day then night, were made with the prototype tooling and handed over with this PR: the feed at the top and scrolled, a tap on a live face, the empty feed (app only, the prototype has none), a widget landing with the New tag, the detail sheet beside the prototype's sheet style, Make empty, building, with a draft and chips, with a change landed, and asking to replace a draft, Add widget's flight and its toast, the four Templates categories, a template sheet, and the feed at the largest text size and with Reduce Motion.
