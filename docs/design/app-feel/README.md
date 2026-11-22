# App feel

Widgie should feel like itself, not like another app's genre. Two rounds of mocks got there.

**Round one** (Paint Quest, Arcade Chat, Night Workshop) used playful-learning-app traits: bright tokens, lipped buttons, a blob mascot. The user rejected it as generic and AI-like. They asked for an identity of Widgie's own, not a copied genre look.

**Round two** started from what Widgie is: your words become a small living object on your home screen. It produced three concepts, [A. Proofmarks](a-proofmarks.png), [B. Tileworks](b-tileworks.png), and [C. The Caret](c-caret.png). [directions.md](directions.md) has the research, the concepts, and the palettes.

## Decision: The Caret, in Sky

Widgie is the blinking text cursor come alive: one round-capped stroke with two eyes that acts only through posture. It leans in while you type, draws your widget with its tip, jumps when you save, and slumps at a broken bridge when the builder can't be reached. The same shape is the wordmark's end, the cursor in every field, the speaker mark in the transcript, and the blinking bar on the main buttons.

- **Light mode is [Sky](c2-caret-sky.png):** a calm light blue ground with an ink caret. [c2-caret-sky.html](c2-caret-sky.html) holds the tokens and the caret's shapes.
- **Dark mode is [Sky turned dark](c2-caret-sky-dark.png):** the same simple UI and the same caret on a cobalt dusk ground, not a different mood. [c2-caret-sky-dark.html](c2-caret-sky-dark.html) holds its tokens. The user turned down the [Night](c2-caret-night.png) palette for dark mode. [Coral](c2-caret-coral.png) was the other light option.
- **Simplicity first:** one action per screen, very little text, and the caret's posture does the talking. Color comes in as playful touches, not as a loud ground. The user rejected the first, chartreuse Caret as too loud and too wordy.
- **Color comes in three small touches:** a soft fill per chip, blush cheeks on the caret, and caret-shaped confetti on Saved. `directions.md` (Round 4) has every token for both modes.
- On failure, "Check that the bridge is running." shows only in Debug builds.

The standing rules still hold: no cream or off-white background, no italic accent words in headlines, no numbered section labels, no monospace labels, and no pill-shaped buttons.
