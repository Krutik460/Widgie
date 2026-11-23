// Five app icon directions, each a full-bleed 1024 x 1024 SVG (iOS applies the rounded mask).
// Colors are the app tokens: sky ground, ink caret, sky eyes, coral cheeks.

const SKY = "#C4D8F3";
const INK = "#121A2E";
const CHEEK = "#FF7F8E";
const NIGHT = "#2B4E82";
const MOON = "#E9F2FF";

function frame(inner, background) {
    return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 1024 1024" width="1024" height="1024">${background}${inner}</svg>`;
}

function sky(dots = true) {
    const grid = dots
        ? `<defs><pattern id="d" width="68" height="68" patternUnits="userSpaceOnUse" x="12" y="12"><circle cx="34" cy="34" r="5" fill="${INK}" fill-opacity=".09"/></pattern></defs><rect width="1024" height="1024" fill="url(#d)"/>`
        : "";
    return `<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#D3E3F8"/><stop offset="1" stop-color="#B6CDEE"/></linearGradient></defs><rect width="1024" height="1024" fill="url(#g)"/>${grid}`;
}

const ICONS = {
    standing: {
        name: "A. Standing",
        note: "The caret as it waits for words in the app. The calmest, most legible at small sizes.",
        svg: () => frame(caretSVG({ pose: "idle", size: 860, x: 82, y: 40, color: INK, eye: SKY, cheek: CHEEK, shadow: INK }), sky()),
    },
    peek: {
        name: "B. Peek",
        note: "Leaning in from the corner and looking at you. Bigger, cropped by the icon edge, more personality.",
        svg: () => frame(caretSVG({ pose: "lean", size: 1240, x: -170, y: 10, color: INK, eye: SKY, cheek: CHEEK }), sky()),
    },
    peekZoom: {
        name: "B3. Peek, closer",
        note: "The same peek cropped closer, so the face carries the icon. The base the widget variants sit on.",
        svg: () => frame(caretSVG({ pose: "lean", size: 1500, x: -300, y: -20, color: INK, eye: SKY, cheek: CHEEK }), sky()),
    },
    peekCard: {
        name: "B4. Peek over a widget",
        note: "A white widget with a number and a button, the caret peeking over its corner. Says 'widgets' without words.",
        svg: () => {
            const card = `<g transform="rotate(6 750 355)">
<rect x="560" y="150" width="380" height="410" rx="92" fill="#FFFFFF" fill-opacity=".9"/>
<rect x="690" y="222" width="110" height="28" rx="14" fill="${SKY}"/>
<rect x="690" y="282" width="190" height="86" rx="22" fill="${SKY}"/>
<circle cx="850" cy="476" r="44" fill="#FFBE1A"/>
</g>`;
            return frame(card + caretSVG({ pose: "lean", size: 1500, x: -300, y: -20, color: INK, eye: SKY, cheek: CHEEK }), sky());
        },
    },
    peekBuild: {
        name: "B5. Peek, building",
        note: "A widget outline half drawn in the app's dashed building style, as if the caret just drew it.",
        svg: () => {
            const box = `<rect x="560" y="150" width="380" height="410" rx="92" fill="none" stroke="${INK}" stroke-opacity=".22" stroke-width="22" stroke-dasharray="2 44" stroke-linecap="round"/>
<path d="M700 150 L848 150 A92 92 0 0 1 940 242 L940 440" fill="none" stroke="${INK}" stroke-width="28" stroke-linecap="round" stroke-linejoin="round"/>
<rect x="770" y="236" width="96" height="26" rx="13" fill="${INK}"/>
<rect x="730" y="296" width="136" height="70" rx="20" fill="${INK}"/>`;
            return frame(box + caretSVG({ pose: "lean", size: 1500, x: -300, y: -20, color: INK, eye: SKY, cheek: CHEEK }), sky());
        },
    },
    peekGrid: {
        name: "B6. Peek on a home screen",
        note: "Four soft widget tiles in the chip colors behind the caret, like the home screen it lives on.",
        svg: () => {
            const tiles = [
                [600, 160, "#A9E9CD"], [784, 160, "#FFE594"], [600, 344, "#FFC2CE"], [784, 344, "#D2C6FF"],
            ].map(([x, y, c]) => `<rect x="${x}" y="${y}" width="164" height="164" rx="44" fill="${c}"/>`).join("");
            return frame(tiles + caretSVG({ pose: "lean", size: 1500, x: -300, y: -20, color: INK, eye: SKY, cheek: CHEEK }), sky());
        },
    },
    peekNight: {
        name: "B2. Peek, night",
        note: "The same peek on an ink field with a sky caret. Louder on a busy home screen; the light art becomes the dark-mode icon's opposite.",
        svg: () => frame(
            caretSVG({ pose: "lean", size: 1240, x: -170, y: 10, color: SKY, eye: INK, cheek: CHEEK }),
            `<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1B2640"/><stop offset="1" stop-color="#0E1424"/></linearGradient></defs><rect width="1024" height="1024" fill="url(#g)"/>`,
        ),
    },
    drawing: {
        name: "C. Drawing a widget",
        note: "Tilted like a pencil, drawing a widget outline, the same moment as the app's Building screen.",
        svg: () => {
            const box = `<g transform="translate(0 56)"><rect x="150" y="470" width="560" height="400" rx="92" fill="none" stroke="${INK}" stroke-opacity=".2" stroke-width="22" stroke-dasharray="2 44" stroke-linecap="round"/>
<path d="M560 470 L242 470 A92 92 0 0 0 150 562 L150 778 A92 92 0 0 0 242 870 L618 870 A92 92 0 0 0 710 778 L710 640" fill="none" stroke="${INK}" stroke-width="30" stroke-linecap="round" stroke-linejoin="round"/>
<rect x="222" y="548" width="120" height="30" rx="12" fill="${INK}"/>
<rect x="222" y="620" width="200" height="74" rx="18" fill="${INK}"/>
<circle cx="258" cy="790" r="34" fill="${INK}"/></g>`;
            return frame(box + caretSVG({ pose: "draw", size: 540, x: 441, y: 2, color: INK, eye: SKY, cheek: CHEEK }), sky());
        },
    },
    hello: {
        name: "D. Hello",
        note: "Jumping with happy eyes and confetti, the Saved screen. The most joyful, busier when small.",
        svg: () => {
            const bits = [
                [190, 300, -28, "#2FBF80"], [300, 170, -34, "#FFBE1A"], [740, 180, -11, "#FF6F8C"], [850, 330, 14, "#8F78FF"],
                [160, 560, -5, "#FF9447"], [870, 600, -33, "#2FBF80"], [250, 760, 22, "#8F78FF"], [790, 790, -18, "#FFBE1A"],
            ].map(([x, y, r, c]) => `<rect x="${x - 15}" y="${y - 48}" width="30" height="96" rx="15" fill="${c}" transform="rotate(${r} ${x} ${y})"/>`).join("");
            return frame(bits + caretSVG({ pose: "jump", size: 780, x: 122, y: 70, color: INK, eye: SKY, cheek: CHEEK, eyes: "happy", cheeks: 1.3, shadow: INK, shadowOpacity: 0.1 }), sky());
        },
    },
    ink: {
        name: "E. Night cursor",
        note: "The cursor blinking in the dark: an ink field, a sky caret. Stands out most on a busy home screen.",
        svg: () => frame(
            caretSVG({ pose: "idle", size: 860, x: 82, y: 40, color: SKY, eye: INK, cheek: CHEEK, shadow: "#000", shadowOpacity: 0.3 }),
            `<defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#1B2640"/><stop offset="1" stop-color="#0E1424"/></linearGradient></defs><rect width="1024" height="1024" fill="url(#g)"/>`,
        ),
    },
};

/// The appearance variants for any direction: dark is "Sky turned dark", tinted is grayscale for iOS to tint.
function variant(svg, kind) {
    if (kind === "dark") {
        return svg
            .replaceAll('stop-color="#D3E3F8"', 'stop-color="#34598F"')
            .replaceAll('stop-color="#B6CDEE"', 'stop-color="#223F6C"')
            .replaceAll(`stroke="${INK}"`, `stroke="${MOON}"`)
            .replaceAll(`fill="${INK}"`, `fill="${MOON}"`)
            .replaceAll(`fill="${SKY}"`, `fill="${NIGHT}"`);
    }
    return svg;
}

/// Tinted: grayscale on black, which iOS recolors with the user's tint. Light means strong tint.
function tinted(key) {
    if (key !== "peekZoom") throw new Error("tinted art is drawn for the chosen icon only");
    return frame(
        caretSVG({ pose: "lean", size: 1500, x: -300, y: -20, color: "#FFFFFF", eye: "#000000", cheek: "#8C8C8C" }),
        `<rect width="1024" height="1024" fill="#000000"/>`,
    );
}
