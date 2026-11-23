// The audience page heroes: the caret acts out each page instead of showing widgets, which the sections below have.
// Each returns one SVG drawn on a 660-unit square. Named groups (.zz, .curl, .reps and so on) carry the motion in
// styles.css. Needs caretSVG from /caret.js.

const INK = "#121A2E";
const CHEEK = "#FF7F8E";

const HEART = (x, y, size, color = "#ff4f72") =>
    `<path transform="translate(${x} ${y}) scale(${size / 24})" d="M12 21s-7.5-4.6-9.6-9.3C.9 8.2 3 4.5 6.6 4.5c2.1 0 3.6 1.2 5.4 3.2 1.8-2 3.3-3.2 5.4-3.2 3.6 0 5.7 3.7 4.2 7.2C19.5 16.4 12 21 12 21z" fill="${color}" stroke="${INK}" stroke-width="${(24 / size) * 1.6}"/>`;

const text = (x, y, size, content, extra = "") =>
    `<text x="${x}" y="${y}" font-family="Bricolage" font-weight="800" font-size="${size}" style="font-stretch: 85%" fill="${INK}" ${extra}>${content}</text>`;

const art = (name, inner) => `<svg class="art-svg ${name}" viewBox="0 0 660 660" aria-hidden="true">${inner}</svg>`;

/// Partners: two carets on a couch under one blanket, hearts on both phones and floating up, the dog asleep below.
export function couchArt() {
    const caret = globalThis.caretSVG;
    const purple = "#6b4fd8";
    const rug = `<ellipse cx="330" cy="616" rx="300" ry="34" fill="#ff8a72" stroke="${INK}" stroke-width="4"/><ellipse cx="330" cy="612" rx="250" ry="22" fill="none" stroke="#fff" stroke-width="3" stroke-dasharray="10 12" opacity=".7"/>`;
    const back = `<rect x="70" y="250" width="520" height="230" rx="46" fill="${purple}" stroke="${INK}" stroke-width="5"/>`;
    const left = caret({
        pose: "lean",
        size: 250,
        x: 160,
        y: 180,
        color: INK,
        eye: "#ffd23c",
        cheek: CHEEK,
        eyes: "happy",
    });
    const right = caret({
        pose: "lean",
        size: 250,
        x: 245,
        y: 180,
        color: INK,
        eye: "#ffd23c",
        cheek: CHEEK,
        mirror: true,
    });
    const seat = `<rect x="50" y="410" width="560" height="140" rx="34" fill="#8a6ff0" stroke="${INK}" stroke-width="5"/><path d="M330 418 v124" stroke="${INK}" stroke-width="4" opacity=".35"/>`;
    const arms = `<rect x="22" y="340" width="96" height="220" rx="40" fill="${purple}" stroke="${INK}" stroke-width="5"/><rect x="542" y="340" width="96" height="220" rx="40" fill="${purple}" stroke="${INK}" stroke-width="5"/>`;
    const legs = `<rect x="70" y="548" width="26" height="40" rx="8" fill="${INK}"/><rect x="564" y="548" width="26" height="40" rx="8" fill="${INK}"/>`;
    const blanket =
        `<path d="M150 392 C210 372 260 404 330 388 C400 372 450 400 510 386 L530 560 C450 578 400 560 330 574 C260 588 210 566 132 572 Z" fill="${CHEEK}" stroke="${INK}" stroke-width="5" stroke-linejoin="round"/>` +
        `<g stroke="#fff" stroke-width="10" opacity=".8" stroke-linecap="round" fill="none"><path d="M170 430 C240 416 280 440 330 428 C390 414 440 438 500 424"/><path d="M160 500 C230 488 280 512 330 500 C390 486 440 510 515 496"/></g>`;
    const phone = (x, y, rot, beat) =>
        `<g transform="rotate(${rot} ${x + 24} ${y + 40})"><rect x="${x}" y="${y}" width="48" height="82" rx="10" fill="${INK}"/><rect x="${x + 5}" y="${y + 7}" width="38" height="66" rx="6" fill="#c4d8f3"/><g class="beat ${beat}">${HEART(x + 13, y + 26, 22)}</g></g>`;
    const glow = `<g class="glow"><circle cx="252" cy="372" r="46" fill="#fff" opacity=".22"/><circle cx="412" cy="372" r="46" fill="#fff" opacity=".22"/></g>`;
    const hearts = `<g class="rise one">${HEART(298, 104, 60)}</g><g class="rise two">${HEART(250, 66, 26)}</g><g class="rise three">${HEART(374, 50, 20)}</g>`;
    const pupBody = `<g class="breath"><ellipse cx="520" cy="590" rx="72" ry="34" fill="#f2b46b" stroke="${INK}" stroke-width="4"/></g><g class="wag"><path d="M586 584 q30 -10 22 -34" fill="none" stroke="${INK}" stroke-width="10" stroke-linecap="round"/><path d="M586 584 q30 -10 22 -34" fill="none" stroke="#f2b46b" stroke-width="5" stroke-linecap="round"/></g>`;
    const pupHead =
        `<g transform="translate(408 528) scale(1.5)"><path d="M12 13 C2 17 2 37 11 41 C17 37 19 24 17 14Z" fill="#8a5527"/><path d="M52 13 C62 17 62 37 53 41 C47 37 45 24 47 14Z" fill="#8a5527"/><ellipse cx="32" cy="30" rx="20" ry="19" fill="#f2b46b" stroke="${INK}" stroke-width="2"/><ellipse cx="32" cy="40" rx="11" ry="8.5" fill="#fff1dc"/><path d="M21.5 28 q3 3 6 0M36.5 28 q3 3 6 0" fill="none" stroke="${INK}" stroke-width="2" stroke-linecap="round"/><ellipse cx="32" cy="35.5" rx="4" ry="3" fill="${INK}"/></g>` +
        `<g class="zz one">${text(560, 520, 30, "z", 'opacity=".5"')}</g><g class="zz two">${text(586, 494, 22, "z", 'opacity=".4"')}</g>`;
    return art(
        "couch",
        rug +
            back +
            left +
            right +
            arms +
            seat +
            legs +
            blanket +
            glow +
            phone(228, 330, -8, "a") +
            phone(388, 330, 8, "b") +
            hearts +
            pupBody +
            pupHead,
    );
}

/// Growth: the caret in a sweatband curls a dumbbell with a flexed arm, a water bottle in the other hand, counting reps.
export function workoutArt() {
    const mint = "#8fe3bd";
    const mat = `<ellipse cx="330" cy="604" rx="230" ry="20" fill="${INK}" opacity=".12"/><rect x="110" y="580" width="440" height="30" rx="15" fill="#5a3fc0" stroke="${INK}" stroke-width="4"/><path d="M140 595 h380" stroke="#fff" stroke-width="3" stroke-dasharray="14 12" opacity=".5"/>`;
    const body = globalThis.caretSVG({ pose: "idle", size: 440, x: 110, y: 170, color: INK, eye: mint, cheek: CHEEK });
    // The head sits near the top of the stroke: x 330, y about 170 + 0.16 * 440.
    const band = `<rect x="288" y="222" width="84" height="22" rx="9" fill="#ff4f5e" stroke="${INK}" stroke-width="3.5"/><g class="tails"><path d="M366 230 q30 -6 44 -24" fill="none" stroke="#ff4f5e" stroke-width="9" stroke-linecap="round"/><path d="M366 236 q34 6 48 -6" fill="none" stroke="#ff4f5e" stroke-width="9" stroke-linecap="round"/></g>`;
    // The upper arm and bicep stay; the forearm, fist and dumbbell swing about the elbow (460, 414).
    const upper =
        `<g stroke="${INK}" stroke-linecap="round" fill="${INK}"><path d="M370 420 L460 414" stroke-width="30" fill="none"/><ellipse cx="410" cy="392" rx="40" ry="31" stroke="none"/><circle cx="460" cy="414" r="15" stroke="none"/></g>` +
        `<path d="M392 378 Q410 362 430 378" fill="none" stroke="${mint}" stroke-width="4" stroke-linecap="round" opacity=".8"/>`;
    const curl =
        `<g class="curl"><g stroke="${INK}" stroke-linecap="round" fill="${INK}"><path d="M460 414 L476 322" stroke-width="27" fill="none"/><circle cx="478" cy="306" r="22" stroke="none"/></g>` +
        `<g fill="#3e4c6b" stroke="${INK}" stroke-width="4"><rect x="424" y="298" width="110" height="16" rx="6"/><rect x="410" y="270" width="24" height="72" rx="8" fill="#ff9447"/><rect x="524" y="270" width="24" height="72" rx="8" fill="#ff9447"/></g></g>`;
    const holdBottle = `<path d="M292 450 L232 512" stroke="${INK}" stroke-width="26" stroke-linecap="round"/><rect x="186" y="430" width="48" height="104" rx="14" fill="#5ac8fa" stroke="${INK}" stroke-width="4"/><rect x="198" y="416" width="24" height="18" rx="5" fill="#ff4f5e" stroke="${INK}" stroke-width="3.5"/><rect x="186" y="470" width="48" height="10" fill="#fff" opacity=".6"/><circle cx="230" cy="512" r="19" fill="${INK}"/>`;
    const effort = `<g class="effort" stroke="${INK}" stroke-width="5" stroke-linecap="round"><path d="M500 250 l14 -22"/><path d="M528 268 l24 -10"/><path d="M470 236 l2 -26"/></g><path class="drip" d="M262 300 c-8 12 -10 20 -2 26 c8 4 14 -4 10 -12 z" fill="#5ac8fa" stroke="${INK}" stroke-width="3"/>`;
    const reps =
        `<g class="reps"><g transform="rotate(7 545 162)"><rect x="470" y="127" width="150" height="84" rx="24" fill="${INK}"/><rect x="470" y="120" width="150" height="84" rx="24" fill="#fff" stroke="${INK}" stroke-width="4"/>${text(498, 180, 52, '<tspan class="count">12</tspan>!')}</g>` +
        `<path d="M500 200 L486 238 L530 204" fill="#fff" stroke="${INK}" stroke-width="4" stroke-linejoin="round"/></g>`;
    return art("workout", mat + holdBottle + body + band + upper + curl + effort + reps);
}
