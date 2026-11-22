# App feel

The app should feel like a playful learning app: bright confident color, chunky pressable buttons, a rounded heavy typeface, a reacting mascot, short encouraging copy, and a celebration on success. Every asset is original.

Three directions were mocked at phone width before any SwiftUI was written:

- [A. Arcade Chat](a-arcade-chat.png): one chat thread does everything, ultraviolet and sun yellow on lavender, a widget-tile mascot.
- [B. Paint Quest](b-paint-quest.png): a guided path of describe, build, try it, save, with a chunky step bar, one big card and one big button per screen, and Pip, an orange paint-drop mascot. Tangerine and sky on a sky-blue ground.
- [C. Night Workshop](c-night-workshop.png): a canvas that looks like the home screen with a bottom sheet for the talking, deep indigo with teal, and a pencil mascot.

## Decision: B, with two changes

B is picked. Its step bar gives the clearest sense of progress, it shows one decision per screen to a person who has never built anything, and Pip is simple to draw with SwiftUI shapes.

- Buttons use sentence case, not uppercase tracked labels.
- The failure state badges the kept preview "Last working version", as A does, so the person sees nothing was lost.

[b-paint-quest.html](b-paint-quest.html) holds the color tokens, the button styles, and Pip's SVG. Its widget images point at local eval renders and do not resolve outside the machine that made them.

The standing rules still hold: no cream or off-white background, no italic accent words in headlines, no numbered section labels, no monospace labels, and no pill-shaped buttons.
