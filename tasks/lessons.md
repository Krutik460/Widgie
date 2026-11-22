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

## 2026-11-22. "Duolingo-like" needs character, not a token set

**What happened.** Asked for "the feel and touch of Duolingo type apps", I briefed three directions as genre traits: bright tokens, lipped buttons, a rounded font, a blob mascot. The user said the result "still looks very AI like, it needs more character", and pointed at cozy pomodoro apps like the one with the cat.

**Rule.** For app feel, start from real reference apps the user would name, and study what gives them character: hand-drawn linework, a companion with a personality living in a scene, texture, and hand-made motion. A palette, a button style, and a mascot drawn from primitives is a template, not a character.

**Rule.** Before any visual direction goes to the user, ask whether it looks like a person drew it or like an AI template. Redo anything that reads as the second.
