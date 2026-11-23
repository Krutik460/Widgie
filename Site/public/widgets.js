// The toy box: every widget on the site, the carets that act around them, and where each scene puts them.
// Widgets are real (each tap changes its state and redraws), sized in iPhone points through --u so a scene scales
// as one object. The caret drawing comes from /caret.js, a classic script that defines caretSVG before this runs.

const INK = "#121A2E";

export const icon = {
    paw: '<svg viewBox="0 0 24 24" fill="currentColor"><ellipse cx="6" cy="10" rx="2.2" ry="2.8"/><ellipse cx="10" cy="5.8" rx="2.2" ry="2.8"/><ellipse cx="14.5" cy="5.8" rx="2.2" ry="2.8"/><ellipse cx="18.5" cy="10" rx="2.2" ry="2.8"/><path d="M12.2 11.2c-3 0-6.2 4.6-6.2 6.8 0 1.8 1.6 2.6 3 2.6 1.3 0 2-.6 3.2-.6s1.9.6 3.2.6c1.4 0 3-.8 3-2.6 0-2.2-3.2-6.8-6.2-6.8z"/></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.6" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 12.5l5 5 10-11"/></svg>',
    heart: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21s-7.5-4.6-9.6-9.3C.9 8.2 3 4.5 6.6 4.5c2.1 0 3.6 1.2 5.4 3.2 1.8-2 3.3-3.2 5.4-3.2 3.6 0 5.7 3.7 4.2 7.2C19.5 16.4 12 21 12 21z"/></svg>',
    bottle: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"><path d="M9 2.5h6M10 2.5v3l-2 3v11a2 2 0 0 0 2 2h4a2 2 0 0 0 2-2v-11l-2-3v-3"/><path d="M8 13h8"/></svg>',
    bin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5h16M9.5 6.5V4h5v2.5M6 6.5l1 14h10l1-14"/></svg>',
    cart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h2.5l2.2 11h10.6L20.5 7H7"/><circle cx="9.5" cy="19.5" r="1.4"/><circle cx="17" cy="19.5" r="1.4"/></svg>',
    plane: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M21 15.5v-2l-8-5V3.8a1.5 1.5 0 0 0-3 0v4.7l-8 5v2l8-2.5v5l-2 1.5V21l3.5-1 3.5 1v-1.5l-2-1.5v-5z"/></svg>',
    plate: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 11h18a9 9 0 0 1-18 0z"/><path d="M9 7.5c0-1.5 1-1.5 1-3.5M14 7.5c0-1.5 1-1.5 1-3.5"/></svg>',
    spark: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l2.2 7.8L22 12l-7.8 2.2L12 22l-2.2-7.8L2 12l7.8-2.2z"/></svg>',
};

/// Five faces for the mood widget, from low to high.
const FACES = [
    { mouth: "M8 17 q4 -4 8 0", eyes: "open" },
    { mouth: "M8 16 h8", eyes: "sleepy" },
    { mouth: "M8 15.5 q4 2 8 0", eyes: "open" },
    { mouth: "M7.5 14.5 q4.5 4.5 9 0", eyes: "open" },
    { mouth: "M7 14 q5 6 10 0 z", eyes: "happy" },
];

function face(index, color) {
    const f = FACES[index];
    const eyes =
        f.eyes === "sleepy"
            ? `<path d="M7 10.5 h3M14 10.5 h3" stroke="${INK}" stroke-width="1.8" stroke-linecap="round"/>`
            : f.eyes === "happy"
              ? `<path d="M7 11 q1.5 -2 3 0M14 11 q1.5 -2 3 0" fill="none" stroke="${INK}" stroke-width="1.8" stroke-linecap="round"/>`
              : `<circle cx="8.6" cy="10.3" r="1.4" fill="${INK}"/><circle cx="15.4" cy="10.3" r="1.4" fill="${INK}"/>`;
    const fill = f.mouth.endsWith("z") ? INK : "none";
    return `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="10.6" fill="${color}" stroke="${INK}" stroke-width="1.6"/>${eyes}<path d="${f.mouth}" fill="${fill}" stroke="${INK}" stroke-width="1.8" stroke-linecap="round"/></svg>`;
}

const ago = (minutes) => Date.now() - minutes * 60000;

function since(at) {
    const minutes = Math.max(0, Math.floor((Date.now() - at) / 60000));
    if (minutes < 1) return "just now";
    if (minutes < 60) return `${minutes}m`;
    return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

/// Each widget: its starting state, how it draws, and what a tap does (returns true to redraw).
/// Medium widgets (twice as wide) are listed in MEDIUM.
const WIDGETS = {
    luna: {
        state: () => ({ at: ago(134), by: "Maya" }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.paw}Luna</div><div class="w-big">${since(s.at)}</div><div class="w-small">fed by ${s.by}</div><button class="w-tap" data-tap aria-label="Fed Luna">${icon.check}</button></div>`,
        tap(s) {
            Object.assign(s, { at: Date.now(), by: "you" });
            return true;
        },
    },
    hearts: {
        state: () => ({ got: 5, sent: 3 }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.heart}Jo</div><div class="w-big">${s.got}</div><div class="w-small">from Jo today<br>${s.sent} sent back</div><button class="w-tap" data-tap aria-label="Send Jo a heart">${icon.heart}</button></div>`,
        tap(s, _target, el) {
            s.sent += 1;
            const heart = document.createElement("span");
            heart.className = "fly";
            heart.innerHTML = icon.heart;
            setTimeout(() => {
                el.querySelector(".w").appendChild(heart);
                heart.addEventListener("animationend", () => heart.remove());
            });
            return true;
        },
    },
    bins: {
        state: () => ({
            turn: 0,
            people: [
                ["Priya", "her turn"],
                ["Sam", "his turn"],
                ["You", "your turn"],
            ],
        }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.bin}Bins night</div><div class="w-big">${s.people[s.turn][0]}</div><div class="w-small">${s.people[s.turn][1]}, Tuesday</div><button class="pass" data-tap>Pass it on</button></div>`,
        tap(s) {
            s.turn = (s.turn + 1) % 3;
            return true;
        },
    },
    groc: {
        state: () => ({
            items: [
                ["Oat milk", true],
                ["Nappies, size 3", false],
                ["Eggs", false],
                ["Basil", true],
                ["Dog food", false],
                ["Lemons", false],
            ],
        }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.cart}Groceries<span class="aside">${s.items.filter((i) => !i[1]).length} left</span></div><ul>${s.items.map(([name, done], i) => `<li><button data-tap="${i}" class="${done ? "crossed" : ""}"><i></i>${name}</button></li>`).join("")}</ul></div>`,
        tap(s, target) {
            const item = s.items[Number(target.dataset.tap)];
            item[1] = !item[1];
            return true;
        },
    },
    baby: {
        state: () => ({ at: ago(184), side: "Right", by: "Sam", today: 5 }),
        draw(s, el) {
            el.classList.toggle("late", Date.now() - s.at > 3 * 3600000);
            const dots = Array.from({ length: 8 }, (_, i) => `<i class="${i < s.today ? "on" : ""}"></i>`).join("");
            return `<div class="w"><div><div class="w-label">${icon.bottle}Last feed</div><div class="w-big">${since(s.at)}</div><div class="w-small">${s.side}, by ${s.by}</div><div class="dots">${dots}</div></div><div class="sides"><button data-tap="Left">L</button><button data-tap="Right">R</button><button data-tap="Bottle" aria-label="Bottle">${icon.bottle}</button></div></div>`;
        },
        tap(s, target) {
            Object.assign(s, { at: Date.now(), side: target.dataset.tap, by: "you", today: Math.min(8, s.today + 1) });
            return true;
        },
    },
    dinner: {
        state: () => ({ me: false }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.plate}Dinner tonight</div><div class="faces"><b>S</b><b>P</b><b class="${s.me ? "" : "out"}">${s.me ? "Me" : "?"}</b></div><div class="w-small">${s.me ? "All three of you" : "Sam and Priya are in"}</div><button class="in" data-tap>${s.me ? "Count me out" : "I'm in"}</button></div>`,
        tap(s) {
            s.me = !s.me;
            return true;
        },
    },
    count: {
        // Always twelve days out, so the date on the widget is real whenever someone visits.
        state: () => ({ visit: new Date(Date.now() + 12 * 86400000) }),
        draw: (s) =>
            `<div class="w"><div class="sun"></div><div class="col"><div class="w-label">${icon.plane}Lisbon</div><div class="w-huge">${Math.ceil((s.visit - Date.now()) / 86400000)}</div><div class="w-small">days until I see Alex</div></div><div class="date">${s.visit.toLocaleDateString("en-US", { month: "short", day: "numeric" }).toUpperCase()}</div></div>`,
    },
    mood: {
        state: () => ({ mine: 2, theirs: 4 }),
        draw: (s) =>
            `<div class="w"><div class="w-label">Today</div><div class="faces"><button data-tap aria-label="Change my mood">${face(s.mine, "#FFFFFF")}<span>you</span></button><div>${face(s.theirs, "#FFC2CE")}<span>Jo</span></div></div></div>`,
        tap(s) {
            s.mine = (s.mine + 1) % FACES.length;
            return true;
        },
    },
    quest: {
        state: () => ({ me: false }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.spark}Today's question</div><p>What tiny thing did I do this week that you loved?</p><div class="row"><span class="who on">Jo answered</span><button data-tap class="who ${s.me ? "on" : ""}">${s.me ? "You answered" : "I answered"}</button><span class="note">${s.me ? "New one tomorrow" : ""}</span></div></div>`,
        tap(s) {
            s.me = !s.me;
            return true;
        },
    },
};

const MEDIUM = new Set(["groc", "baby", "count", "quest"]);

/// Draws the widget named by `el.dataset.widget` into `el` and makes it tappable.
export function mountWidget(el) {
    const spec = WIDGETS[el.dataset.widget];
    el.classList.add(el.dataset.widget);
    const state = spec.state();
    const render = () => {
        el.innerHTML = spec.draw(state, el);
    };
    render();
    if (spec.tap) {
        el.addEventListener("click", (event) => {
            const target = event.target.closest("[data-tap]");
            if (target && spec.tap(state, target, el)) render();
        });
    }
    // Times like "2h 14m" keep moving while the page is open.
    if (["luna", "baby"].includes(el.dataset.widget)) setInterval(render, 30000);
}

/// Draws a caret from data attributes: pose, mirror, eyes ("happy"), moon (light on dark), shadow, and halo (a cut
/// line in the field color that separates the caret from ink it touches, like a sticker).
export function mountCaret(el) {
    const d = el.dataset;
    const moon = d.moon === "1";
    const eye = moon ? "#2B4E82" : d.eye || "#C4D8F3";
    const body = globalThis.caretSVG({
        pose: d.pose || "idle",
        size: 100,
        x: 0,
        y: 0,
        color: moon ? "#E9F2FF" : INK,
        eye,
        cheek: "#FF7F8E",
        eyes: d.eyes || "open",
        mirror: d.mirror === "1",
        cheeks: 1.15,
        shadow: d.shadow ? "#000" : null,
        shadowOpacity: 0.16,
    });
    const halo = d.halo
        ? (body.match(
              /<path d="([^"]+)" fill="none" stroke="[^"]+" stroke-width="([\d.]+)" stroke-linecap="round"\/>/,
          ) ?? [])[0]
              ?.replace(/stroke="[^"]+"/, `stroke="${d.halo}"`)
              .replace(/stroke-width="([\d.]+)"/, (_, w) => `stroke-width="${Number(w) + 7}"`)
        : "";
    // The eyes get two wrappers: the outer one looks toward the pointer, the inner one blinks.
    const withEyes = body.replace(
        /(stroke-linecap="round"\/>)(<(?:ellipse|path)[^>]*\/>)(<(?:ellipse|path)[^>]*\/>)/,
        '$1<g class="look"><g class="eyes">$2$3</g></g>',
    );
    el.innerHTML = `<svg viewBox="0 4 100 100" aria-hidden="true">${halo || ""}${withEyes}</svg>`;
}

// ---------- Scenes ----------

/// `still` marks a block a caret holds or stands on: it does not drift with scroll, so the pair stays together.
const block = (w, x, y, r, still = false) =>
    `<div class="blk ${MEDIUM.has(w) ? "m" : ""}" data-widget="${w}"${still ? " data-still" : ""} style="left: calc(${x} * var(--u)); top: calc(${y} * var(--u)); --rot: ${r}deg"></div>`;
const caret = (pose, x, y, w, extra = "") =>
    `<span class="caret" data-pose="${pose}" ${extra} style="left: calc(${x} * var(--u)); top: calc(${y} * var(--u)); width: calc(${w} * var(--u))"></span>`;
const floatingHeart = (x, y, w) =>
    `<div class="caret heart-float" style="left: calc(${x} * var(--u)); top: calc(${y} * var(--u)); width: calc(${w} * var(--u))">${icon.heart}</div>`;
const note = (x, y, w, text, arrow = "") =>
    `<div class="scrawl" style="left: calc(${x} * var(--u)); top: calc(${y} * var(--u)); width: calc(${w} * var(--u))">${text}${arrow}</div>`;
const ARROW = `<svg viewBox="0 0 60 60" style="left: calc(-46 * var(--u)); top: calc(40 * var(--u)); width: calc(50 * var(--u))"><path d="M54 6 C40 10 24 22 12 44" fill="none" stroke="${INK}" stroke-width="3.4" stroke-linecap="round"/><path d="M5 31 L12 46 L27 41" fill="none" stroke="${INK}" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"/></svg>`;
/// Caret confetti, as on the app's Saved screen: short round bars in the section colors.
const confettiBits = (cx, cy) =>
    [
        [-150, -40, 30, "#ffd23c"],
        [-120, 60, -40, "#ff7f8e"],
        [-170, 140, 70, "#a9e9cd"],
        [130, -60, -25, "#a9e9cd"],
        [150, 40, 50, "#ffd23c"],
        [120, 130, -60, "#ff7f8e"],
        [-60, -110, 80, "#ff7f8e"],
        [60, -120, 15, "#ffd23c"],
    ]
        .map(
            ([x, y, r, c]) =>
                `<i class="bit" style="left: calc(${cx + x} * var(--u)); top: calc(${cy + y} * var(--u)); transform: rotate(${r}deg); background: ${c}"></i>`,
        )
        .join("");
const tall = (height, inner) => `<div class="mob-scene" style="height: ${height}px">${inner}</div>`;

/// Each scene's layout for desktop and for phones. `first` is true when the section opens its page (on /home and
/// /us), where a button sits under the copy, so the lower widgets move down to make room.
export const SCENES = {
    hero: {
        desk: () =>
            block("groc", 790, 528, -4) +
            block("luna", 812, 344, 6) +
            block("hearts", 990, 352, -5) +
            block("bins", 958, 120, 17),
        mob: () =>
            block("bins", 150, 0, 14) +
            block("luna", 8, 150, -6) +
            block("hearts", 188, 172, 7) +
            block("groc", 2, 350, -3),
    },
    house: {
        desk: (first) => {
            const low = first ? 110 : 0;
            return (
                block("baby", 790, 232, -4, true) +
                caret("idle", 772, 400, 400, 'data-shadow="1"') +
                note(960, 100, 170, "Goes red after<br>three hours.<br>Tap L or R.", ARROW) +
                block("dinner", 70, 610 + low, -6) +
                block("bins", 286, 600 + low, 7)
            );
        },
        mob: () =>
            tall(
                900,
                block("luna", 4, 0, -7) +
                    note(200, 40, 140, "Maya fed her.<br>Nobody has to ask.") +
                    block("baby", 6, 220, -4, true) +
                    caret("idle", 10, 380, 340, 'data-shadow="1"') +
                    note(226, 470, 120, "Goes red after<br>three hours.<br>Tap L or R.") +
                    block("groc", 0, 720, 3),
            ),
    },
    two: {
        desk: (first) => {
            const low = first ? 120 : 0;
            return (
                block("count", 140, 560, -3, true) +
                caret("lean", 173, 259, 340, 'data-eyes="happy"') +
                caret("lean", 288, 259, 340, 'data-mirror="1"') +
                floatingHeart(374, 204, 52) +
                block("hearts", 506, 150, 9) +
                block("mood", 560, 670 + low, -7) +
                block("quest", 776, 650 + low, 3)
            );
        },
        mob: () =>
            tall(
                760,
                block("count", 8, 370, -3, true) +
                    caret("lean", 22, 60, 330, 'data-eyes="happy"') +
                    caret("lean", 133, 60, 330, 'data-mirror="1"') +
                    floatingHeart(170, 40, 46) +
                    block("mood", 186, 590, 6) +
                    block("hearts", 4, 580, -6),
            ),
    },
    join: {
        desk: () =>
            block("mood", 820, 520, -4) +
            block("bins", 984, 532, 5) +
            block("hearts", 904, 342, -6) +
            caret("jump", 860, 74, 260, 'data-moon="1"') +
            confettiBits(990, 190),
        mob: () => "",
    },
};
