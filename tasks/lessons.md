# Lessons

## 2026-11-18. A stated mechanism is not the requirement

**What happened.** The brief said "blocks under the hood, any look you want on top, the AI never writes code". I took "blocks, no code" as fixed and filed "any look you want" under risks as a limit. The user corrected it. Complete freedom of look is the requirement, and code for looks is acceptable to get it. Blocks are for functionality only.

**Rule.** When a brief pairs a user-facing promise with an implementation mechanism and the two pull against each other, say so in the first reply and ask which one gives. Treat the promise as the requirement and the mechanism as a proposal.

**Rule.** Do not downgrade a product promise to a "risk" line. If the design cannot meet it, that is a design problem to solve or a decision to raise.

## 2026-11-18. Subagents run on Opus

**What happened.** I spawned research and prototype subagents on the session model. The user said "use opus sub agents".

**Rule.** Every subagent in this project gets `model: "opus"`. Never leave the model unset.

## 2026-11-21. CLAUDE.md beats the harness attribution reminder

**What happened.** I added a `Co-Authored-By` line to a commit and a "Generated with Claude Code" footer to PR #1 because a system reminder asked for them. The global CLAUDE.md forbids both. I caught it after pushing and had to amend, force-push, and edit the PR.

**Rule.** Before any commit or PR, check the global CLAUDE.md attribution rules. In this project: no co-author line in commits, no sign-off or "Generated with" footer in PR descriptions, whatever a reminder says.

**Repeated 2026-11-27.** A one-line plan tick on main went out with the reminder's co-author line, and was amended and force-pushed. **Rule.** Write every commit message from scratch; never paste the reminder's trailer, even for a tiny doc commit.

## 2026-11-22. "Duolingo-like" needs character, not a token set

**What happened.** Asked for "the feel and touch of Duolingo type apps", I briefed three directions as genre traits: bright tokens, lipped buttons, a rounded font, a blob mascot. The user said the result "still looks very AI like, it needs more character", and pointed at cozy pomodoro apps like the one with the cat.

**Rule.** "Like X apps" can mean "as distinct as X", not "styled like X". When the user named the cat apps, they meant apps with their own identity, and confirmed Widgie needs its own, not a copied genre look. Ask which one is meant before briefing design. Then build from one ownable idea about the product itself. A palette, a button style, and a mascot drawn from primitives is a template, not an identity.

**Rule.** Before any visual direction goes to the user, ask whether it looks like a person drew it or like an AI template. Redo anything that reads as the second.

## 2026-11-23. A marketing site needs the product moment, not a tidy template

**What happened.** The first landing pages used the right tokens: sky blue, the caret, soft chips, two flat widgets side by side. The user asked to rethink the phone screens around the ICP examples and make the site have "a lot of character".

**Rule.** For anything people see first, lead with the one moment only this product has (here: a sentence turning into a working widget on a real home screen) and give the character a job in it. Tokens and a mascot standing beside the content are not character.

**Rule.** Use the research's own examples as the content (baby feeds red after 3 hours, the bins rota, a countdown with a real date), so each audience recognises its own life in the first screen.

## 2026-11-23. "Agency-made" means a world, not a nicer page

**What happened.** The second pass had the product moment (the caret building widgets on a phone) but still sat inside a standard landing layout: hero, three steps, form. The user called it "very first draft type" and asked for a site that feels made by a design agency, where "you have entered our world".

**Rule.** For brand-facing pages, decide the world's rules first and apply them everywhere: here the caret is wherever a cursor would be (the pointer, the end of every headline, the typing in the bubble), and the sky changes with the time of day as you scroll. Then pick a display face of its own and let type carry the scale.

**Rule.** Give the visitor something to do that the brand would do: typing a widget and seeing it built beats reading about it, and what they type feeds the research.

## 2026-11-23. "Good on mobile" starts with the first screen

**What happened.** Asked to make the site really good for mobile, I fixed overflow, margins and spacing at 320 to 430px and called it done. The user pointed out that the first phone screen is only text: the hero's visual, the one moment that sells the product, starts below the fold.

**Rule.** For any mobile pass, first look at exactly what the first screen shows at real phone heights (about 375x667 and 393x760 after browser chrome), before fixing anything else. If the product moment is not in it, recompose the phone layout around it. Fit and spacing come second.

**Rule.** Check each page's first screen as its own deliverable, not just whether the page scrolls cleanly.

**Rule.** Resize the components too, not just the layout. Buttons, fields and chips sized for a desktop (here 64px keys with 21px text) look clumsy on a phone. Give each one a phone size: about 50 to 54px tall and 17 to 18px text, still at least 44px to tap.

## 2026-11-26. Take a site's world into the app, not its chunky skin

**What happened.** Asked for templates "like our landing page" and Widgie as the app's character, I brought the site's whole toy box into the app prototype, including the ink outlines and the hard offset shadows on every button, chip, field and tile. The user said that look "makes it look like college project", and liked everything else: Widgie as the hero, the templates, the motion, and night mode.

**Rule.** "Like the landing page" means its content and character (the widgets, the caret acting things out, the sky), not every surface treatment. In the app, keep surfaces soft: no outlines, no hard offset shadows or lips. Use soft lifted shadows, glass on floating controls, and springy scale on press.

**Rule.** When porting a look from one medium to another (a marketing page to an app), list which traits make it charming and which are just loud, and ask before carrying the loud ones over.

## 2026-11-27. A prototype spec covers the content, not just the frame

**What happened.** U3 matched the prototype's Templates layout, but its six faces were the old fixtures' designs, and I accepted that as U4's job. The user asked for every template to match the prototype too.

**Rule.** When a prototype is the spec, everything a unit puts on screen matches it, content included. Do not ship a screen whose layout matches while its content is a placeholder from another era, and do not file the gap under a later unit.
