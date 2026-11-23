// The toy box: every widget on the site, the carets that act around them, and where each scene puts them.
// Widgets are real (each tap changes its state and redraws), sized in iPhone points through --u so a scene scales
// as one object. The caret drawing comes from /caret.js, a classic script that defines caretSVG before this runs.

import { couchArt, workoutArt } from "/heroes.js";

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
    leaf: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M20.5 3.5C12 3.5 5 7.6 5 14.2c0 1.8.6 3.4 1.6 4.6L4 21.4l1.4 1.4 2.6-2.6c1.2 1 2.8 1.6 4.6 1.6 6.6 0 7.9-9.8 7.9-18.3zM9 18.4c1.7-4.6 4.6-7.8 8.4-9.9-3 2.8-5.4 6-6.8 10.5z"/></svg>',
    phone: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M6.6 10.8a15.1 15.1 0 0 0 6.6 6.6l2.2-2.2a1 1 0 0 1 1-.25 11.4 11.4 0 0 0 3.6.57 1 1 0 0 1 1 1V20a1 1 0 0 1-1 1A17 17 0 0 1 3 4a1 1 0 0 1 1-1h3.5a1 1 0 0 1 1 1c0 1.25.2 2.45.57 3.6a1 1 0 0 1-.25 1z"/></svg>',
    crown: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M3 7l4.5 4L12 4l4.5 7L21 7l-2 12H5z"/></svg>',
    infinity:
        '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.6" stroke-linecap="round"><path d="M12 12c-2-2.7-3.7-4-5.5-4a4 4 0 0 0 0 8c1.8 0 3.5-1.3 5.5-4zm0 0c2 2.7 3.7 4 5.5 4a4 4 0 0 0 0-8c-1.8 0-3.5 1.3-5.5 4z"/></svg>',
    drop: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2.5s-7 7.6-7 12.3a7 7 0 0 0 14 0C19 10.1 12 2.5 12 2.5z"/></svg>',
    lotus: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 4c2 2.2 3 4.6 3 7.2 0 1.8-1.1 3.6-3 4.8-1.9-1.2-3-3-3-4.8C9 8.6 10 6.2 12 4zM3 10.5c2.6-.3 5 .5 6.8 2.3.4 1.6.2 3.1-.5 4.3-2.6-.4-4.8-1.9-5.6-4.1L3 10.5zm18 0l-.7 2.5c-.8 2.2-3 3.7-5.6 4.1-.7-1.2-.9-2.7-.5-4.3 1.8-1.8 4.2-2.6 6.8-2.3zM4 18h16v2H4z"/></svg>',
    bolt: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M13.5 2 4 14h6.5L9 22l11-13h-6.8z"/></svg>',
    grid: '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="3" y="3" width="8" height="8" rx="2"/><rect x="13" y="3" width="8" height="8" rx="2"/><rect x="3" y="13" width="8" height="8" rx="2"/><rect x="13" y="13" width="8" height="8" rx="2"/></svg>',
    jar: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"><path d="M8 3h8v3H8zM7 6h10l1 3v10a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V9z"/><path d="M9 14h6"/></svg>',
    book: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"><path d="M4 5.5A2.5 2.5 0 0 1 6.5 3H20v15H6.5A2.5 2.5 0 0 0 4 20.5zM4 20.5A2.5 2.5 0 0 0 6.5 23H20v-5"/></svg>',
    dumbbell:
        '<svg viewBox="0 0 24 24" fill="currentColor"><rect x="1.5" y="8" width="3.5" height="8" rx="1.2"/><rect x="5" y="6" width="3.5" height="12" rx="1.2"/><rect x="15.5" y="6" width="3.5" height="12" rx="1.2"/><rect x="19" y="8" width="3.5" height="8" rx="1.2"/><rect x="8.5" y="10.6" width="7" height="2.8" rx="1"/></svg>',
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

/// Luna herself: big eyes looking up while she waits, eyes shut and tongue out once she has just been fed.
function puppy(fed) {
    const ink = "#2b1f14";
    const eyes = fed
        ? `<path d="M21.5 27.5 q3 -3.6 6 0M36.5 27.5 q3 -3.6 6 0" fill="none" stroke="${ink}" stroke-width="2" stroke-linecap="round"/>`
        : `<circle cx="24.5" cy="27" r="3" fill="${ink}"/><circle cx="39.5" cy="27" r="3" fill="${ink}"/><circle cx="25.6" cy="25.8" r="1" fill="#fff"/><circle cx="40.6" cy="25.8" r="1" fill="#fff"/>`;
    const tongue = fed ? `<path d="M29.6 42.4 q2.4 7 4.8 0z" fill="#ff7f8e" stroke="${ink}" stroke-width="1.2"/>` : "";
    return `<svg class="puppy" viewBox="0 0 64 60" aria-hidden="true"><path d="M12 13 C2 17 2 37 11 41 C17 37 19 24 17 14Z" fill="#8a5527"/><path d="M52 13 C62 17 62 37 53 41 C47 37 45 24 47 14Z" fill="#8a5527"/><ellipse cx="32" cy="30" rx="20" ry="19" fill="#f2b46b"/><ellipse cx="32" cy="40" rx="11" ry="8.5" fill="#fff1dc"/>${eyes}<ellipse cx="18.5" cy="34.5" rx="3" ry="2" fill="#ff9aa8" opacity=".85"/><ellipse cx="45.5" cy="34.5" rx="3" ry="2" fill="#ff9aa8" opacity=".85"/><ellipse cx="32" cy="35.5" rx="4" ry="3" fill="${ink}"/><path d="M32 38.6v2.4M28.4 41.8q3.6 2.6 7.2 0" fill="none" stroke="${ink}" stroke-width="1.6" stroke-linecap="round"/>${tongue}</svg>`;
}

/// A progress ring toward a goal, with an icon in the middle.
function ring(fraction, glyph) {
    const r = 21;
    const length = 2 * Math.PI * r;
    const shown = Math.min(1, Math.max(0, fraction)) * length;
    return `<div class="ring" aria-hidden="true"><svg viewBox="0 0 54 54"><circle cx="27" cy="27" r="${r}" fill="none" stroke="rgba(255,255,255,.14)" stroke-width="6"/><circle cx="27" cy="27" r="${r}" fill="none" stroke="currentColor" stroke-width="6" stroke-linecap="round" stroke-dasharray="${shown.toFixed(1)} ${length.toFixed(1)}" transform="rotate(-90 27 27)"/></svg>${glyph}</div>`;
}

/// A gold medal on a two-color ribbon.
const MEDAL = `<svg class="medal" viewBox="0 0 44 58" aria-hidden="true"><path d="M8 2h11l6 18h-11z" fill="#ff6b5c" stroke="#0b1430" stroke-width="2" stroke-linejoin="round"/><path d="M36 2H25l-6 18h11z" fill="#9cc3f5" stroke="#0b1430" stroke-width="2" stroke-linejoin="round"/><circle cx="22" cy="38" r="17" fill="#ffd23c" stroke="#0b1430" stroke-width="2.4"/><circle cx="22" cy="38" r="11.5" fill="none" stroke="#e8a400" stroke-width="2"/><path d="M22 30.5l2.3 4.8 5.2.6-3.9 3.6 1.1 5.1-4.7-2.7-4.7 2.7 1.1-5.1-3.9-3.6 5.2-.6z" fill="#e8a400"/></svg>`;

/// Mount Fuji under a red sun, with a small torii gate: the Japan fund's picture.
const FUJI = `<svg class="fuji" viewBox="0 0 130 84" aria-hidden="true"><circle cx="92" cy="24" r="15" fill="#e5484d"/><path d="M6 80 L50 30 Q55 25 60 30 L104 80Z" fill="#2b3a67"/><path d="M41 41 L50 30 Q55 25 60 30 L69 41 L62 38 L55 44 L48 38Z" fill="#fff"/><g fill="#e5484d"><rect x="12" y="56" width="26" height="3.6" rx="1"/><rect x="14" y="62" width="22" height="2.8"/><rect x="16" y="56" width="3.2" height="24"/><rect x="31" y="56" width="3.2" height="24"/></g><path d="M0 80h130" stroke="#9cc98a" stroke-width="4"/></svg>`;

/// A boarding pass for the trip, tilted on the right of the countdown.
function boardingPass(date) {
    const day = date.toLocaleDateString("en-US", { month: "short", day: "numeric" }).toUpperCase();
    return `<div class="ticket" aria-hidden="true"><div class="route"><b>SFO</b>${icon.plane}<b>LIS</b></div><div class="meta"><span>Lisbon</span><span>${day}</span></div><div class="meta"><span>Seats</span><span>4A 4B</span></div><div class="cut"></div><div class="bars"></div></div>`;
}

/// Each widget: its starting state, how it draws, and what a tap does (returns true to redraw).
/// Medium widgets (twice as wide) are listed in MEDIUM.
const WIDGETS = {
    luna: {
        state: () => ({ at: ago(134), by: "Sam" }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.paw}Luna</div><div class="w-big">${since(s.at)}</div><div class="w-small">fed by ${s.by}</div>${puppy(Date.now() - s.at < 30 * 60000)}<button class="w-tap" data-tap aria-label="Fed Luna">${icon.check}</button></div>`,
        tap(s) {
            Object.assign(s, { at: Date.now(), by: "you" });
            return true;
        },
    },
    hearts: {
        state: () => ({ got: 5, sent: 3 }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.heart}Sam</div><div class="w-big">${s.got}</div><div class="w-small">from Sam today<br>you sent ${s.sent}</div><button class="w-tap" data-tap aria-label="Send Sam a heart">${icon.heart}</button></div>`,
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
            people: ["Sam", "You"],
        }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.bin}Bins night</div><div class="w-big">${s.people[s.turn]}</div><div class="w-small">${s.turn === 1 ? "your turn tonight" : "up tonight"}</div><button class="pass" data-tap>Pass it on</button></div>`,
        tap(s) {
            s.turn = (s.turn + 1) % s.people.length;
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
            `<div class="w"><div class="w-label">${icon.plate}Dinner tonight</div><div class="faces"><b class="${s.me ? "out" : ""}">S</b><b class="${s.me ? "" : "out"}">Me</b></div><div class="w-small">${s.me ? "You're cooking, Sam's on dishes" : "Sam's cooking, you're on dishes"}</div><button class="in" data-tap>${s.me ? "Swap back" : "I'll cook"}</button></div>`,
        tap(s) {
            s.me = !s.me;
            return true;
        },
    },
    count: {
        // Always twelve days out, so the date on the widget is real whenever someone visits.
        state: () => ({ visit: new Date(Date.now() + 12 * 86400000) }),
        draw: (s) =>
            `<div class="w"><div class="col"><div class="w-label">${icon.plane}Lisbon</div><div class="w-huge">${Math.ceil((s.visit - Date.now()) / 86400000)}</div><div class="w-small">days until our trip</div></div>${boardingPass(s.visit)}</div>`,
    },
    mood: {
        state: () => ({ mine: 2, theirs: 4 }),
        draw: (s) =>
            `<div class="w"><div class="w-label">Our moods</div><div class="faces"><button data-tap aria-label="Change my mood">${face(s.mine, "#FFFFFF")}<span>you</span></button><div>${face(s.theirs, "#FFC2CE")}<span>Sam</span></div></div></div>`,
        tap(s) {
            s.mine = (s.mine + 1) % FACES.length;
            return true;
        },
    },
    quest: {
        state: () => ({ me: false }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.spark}Today's question</div><p>What tiny thing did I do this week that you loved?</p><div class="row"><span class="who on">Sam answered</span><button data-tap class="who ${s.me ? "on" : ""}">${s.me ? "You answered" : "I answered"}</button><span class="note">${s.me ? "New one tomorrow" : ""}</span></div></div>`,
        tap(s) {
            s.me = !s.me;
            return true;
        },
    },
    plant: {
        // Six days since watering: a day from turning red, as the prompt asked.
        state: () => ({ days: 6, by: "Sam" }),
        draw(s, el) {
            el.classList.toggle("late", s.days >= 7);
            const big = s.days === 0 ? "Watered" : `${s.days} days`;
            const small = s.days === 0 ? "just now, by you" : `since watering,<br>last by ${s.by}`;
            return `<div class="w"><div class="w-label">${icon.leaf}Monstera</div><div class="w-big">${big}</div><div class="w-small">${small}</div><button class="w-tap" data-tap aria-label="Watered the monstera">${icon.check}</button></div>`;
        },
        tap(s) {
            Object.assign(s, { days: 0, by: "you" });
            return true;
        },
    },
    chores: {
        state: () => ({
            people: [
                ["Sam", 11],
                ["You", 9],
            ],
        }),
        draw(s) {
            const top = Math.max(...s.people.map((p) => p[1]));
            const rows = s.people
                .map(
                    ([name, points]) =>
                        `<li><span class="who">${name}${points === top ? `<i class="crown">${icon.crown}</i>` : ""}</span><span class="bar"><b style="width: ${(points / 15) * 100}%"></b></span><span class="pts">${points}</span></li>`,
                )
                .join("");
            return `<div class="w"><div class="w-label">${icon.crown}Chores this week</div><ul>${rows}</ul><p class="foot-line">Winner picks Friday's movie</p><button class="did" data-tap>I did one</button></div>`;
        },
        tap(s) {
            const me = s.people.find((p) => p[0] === "You");
            me[1] = Math.min(15, me[1] + 1);
            return true;
        },
    },
    days: {
        state: () => ({ n: 1204 }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.infinity}Together</div><div class="w-big">${s.n.toLocaleString("en-US")}</div><div class="w-small">days since<br>our first date</div></div>`,
    },
    water: {
        state: () => ({ n: 5, goal: 8 }),
        draw: (s) => {
            const level = Math.min(1, s.n / s.goal);
            return `<div class="w"><div class="w-label">${icon.drop}Water</div><div class="w-big">${s.n}/${s.goal}</div><div class="w-small">glasses today</div><svg class="bottle" viewBox="0 0 30 60" aria-hidden="true"><clipPath id="bottle-clip"><path d="M10 2h10v8l5 7v37a4 4 0 0 1-4 4H9a4 4 0 0 1-4-4V17l5-7z"/></clipPath><g clip-path="url(#bottle-clip)"><rect width="30" height="60" fill="rgba(255,255,255,.12)"/><rect y="${(60 - 48 * level).toFixed(1)}" width="30" height="60" fill="#5ac8fa"/></g><path d="M10 2h10v8l5 7v37a4 4 0 0 1-4 4H9a4 4 0 0 1-4-4V17l5-7z" fill="none" stroke="#c9ecff" stroke-width="2.2"/></svg><button class="pass" data-tap>+1 glass</button></div>`;
        },
        tap(s) {
            s.n = s.n >= s.goal ? 0 : s.n + 1;
            return true;
        },
    },
    streak: {
        state: () => ({ days: 12, today: false }),
        draw: (s) =>
            `<div class="w${s.today ? " done" : ""}"><div class="w-label">${icon.lotus}Meditate</div><div class="breathe" aria-hidden="true"><i></i><i></i>${icon.lotus}</div><div class="w-big">${s.days + (s.today ? 1 : 0)}</div><div class="w-small">day streak${s.today ? ",<br>done today" : ""}</div><button class="w-tap" data-tap aria-label="Meditated today">${icon.check}</button></div>`,
        tap(s) {
            s.today = !s.today;
            return true;
        },
    },
    grid: {
        // Two weeks of three habits; a tap on a habit's last square marks today.
        state: () => ({
            habits: [
                ["Gym", "10110101101100"],
                ["Read", "11111011111110"],
                ["No sugar", "01101110111010"],
            ],
        }),
        draw: (s) => {
            const rows = s.habits
                .map(
                    ([name, days], i) =>
                        `<li><span>${name}</span><span class="days">${[...days].map((d, j) => (j === days.length - 1 ? `<button data-tap="${i}" class="${d === "1" ? "on" : ""}" aria-label="${name} today"></button>` : `<i class="${d === "1" ? "on" : ""}"></i>`)).join("")}</span></li>`,
                )
                .join("");
            // Today counts once it is marked; until then the streak runs through yesterday.
            const read = s.habits[1][1].endsWith("1") ? s.habits[1][1] : s.habits[1][1].slice(0, -1);
            const streak = read.length - 1 - read.lastIndexOf("0");
            return `<div class="w"><div class="w-label">${icon.grid}Last two weeks<span class="aside">today</span></div><ul>${rows}</ul><p class="foot-line">Reading: ${streak} days in a row</p></div>`;
        },
        tap(s, target) {
            const habit = s.habits[Number(target.dataset.tap)];
            habit[1] = habit[1].slice(0, -1) + (habit[1].endsWith("1") ? "0" : "1");
            return true;
        },
    },
    sober: {
        state: () => ({ since: new Date(Date.now() - 47 * 86400000) }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.spark}Alcohol-free</div><div class="w-big">${Math.floor((Date.now() - s.since) / 86400000)} days</div><div class="w-small">since ${s.since.toLocaleDateString("en-US", { month: "short", day: "numeric" })}<br>next medal: 60</div>${MEDAL}</div>`,
    },
    pushups: {
        state: () => ({ week: 120, goal: 300 }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.bolt}Pushups</div>${ring(s.week / s.goal, icon.dumbbell)}<div class="w-big">${s.week}</div><div class="w-small">this week<br>goal ${s.goal}</div><button class="pass" data-tap>+10</button></div>`,
        tap(s) {
            s.week = s.week >= s.goal ? 0 : s.week + 10;
            return true;
        },
    },
    savings: {
        state: () => ({ saved: 1240, goal: 2000 }),
        draw: (s) => {
            const pct = Math.min(100, Math.round((s.saved / s.goal) * 100));
            return `<div class="w"><div class="w-label">${icon.jar}Japan fund<span class="aside">${pct}%</span></div>${FUJI}<div class="w-big">$${s.saved.toLocaleString("en-US")}</div><div class="w-small">of $${s.goal.toLocaleString("en-US")}, $95 a week to make it by June</div><div class="track"><b style="width: ${pct}%"></b></div><button class="pass" data-tap>+$50</button></div>`;
        },
        tap(s) {
            s.saved = s.saved >= s.goal ? 1240 : s.saved + 50;
            return true;
        },
    },
    word: {
        state: () => ({ known: 48, shown: false }),
        draw: (s) =>
            `<div class="w"><div class="w-label">${icon.book}Palabra del día<span class="aside">${s.known} learned</span></div><div class="w-big">madrugar</div><div class="w-small">to get up early. "Mañana tengo que madrugar."</div><div class="row"><button data-tap="know" class="who on">Know it</button><button data-tap="again" class="who">Again</button></div></div>`,
        tap(s, target) {
            if (target.dataset.tap === "know") s.known += 1;
            return true;
        },
    },
};

const MEDIUM = new Set(["groc", "baby", "count", "quest", "chores", "grid", "savings", "word"]);

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

/// Where each pose's body crosses its middle, in the caret's 100-unit box (from the curves in /caret.js).
const MIDDLE = { idle: [50, 55], lean: [46.4, 46.5], jump: [50, 52], draw: [40.5, 52] };

/// A flexed arm on the caret's right side: upper arm out, a round bicep, forearm up, a fist on top.
function flexArm(pose, mirror, color, shine) {
    const [mx, my] = MIDDLE[pose] ?? MIDDLE.idle;
    const x = (mirror ? 100 - mx : mx) + 5;
    const y = my + 5;
    return `<g class="arm" fill="${color}" stroke="${color}" stroke-linecap="round" stroke-linejoin="round"><path d="M${x} ${y} L${x + 19} ${y - 1}" stroke-width="9.5" fill="none"/><ellipse cx="${x + 10.5}" cy="${y - 6}" rx="10.5" ry="8.4" stroke="none"/><path d="M${x + 19} ${y - 1} L${x + 22} ${y - 19}" stroke-width="8.5" fill="none"/><circle cx="${x + 22.5}" cy="${y - 23}" r="6.8" stroke="none"/><path d="M${x + 5.5} ${y - 9.5} Q${x + 10.5} ${y - 14} ${x + 15.5} ${y - 9.5}" fill="none" stroke="${shine}" stroke-width="1.8" opacity=".7"/></g>`;
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
    // data-arm="flex": a bicep curled up beside the body, for the growth page. It starts at the body's middle.
    const arm = d.arm === "flex" ? flexArm(d.pose || "idle", d.mirror === "1", moon ? "#E9F2FF" : INK, eye) : "";
    // The eyes get two wrappers: the outer one looks toward the pointer, the inner one blinks.
    const withEyes = body.replace(
        /(stroke-linecap="round"\/>)(<(?:ellipse|path)[^>]*\/>)(<(?:ellipse|path)[^>]*\/>)/,
        '$1<g class="look"><g class="eyes">$2$3</g></g>',
    );
    el.innerHTML = `<svg viewBox="0 4 100 100" aria-hidden="true">${halo || ""}${arm}${withEyes}</svg>`;
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
const tall = (height, inner) => `<div class="mob-scene" style="height: calc(${height} * var(--u))">${inner}</div>`;

/// A phone arrangement built from a list: small widgets pair up side by side, medium widgets and carets take a row,
/// and a small widget with no partner sits in the middle of its row. Entries are widget names, or ["caret", pose, extra].
const isSmall = (entry) => typeof entry === "string" && !MEDIUM.has(entry);
function stack(entries) {
    let html = "";
    let y = 0;
    let column = 0;
    const tilts = [-5, 6, -3, 7, -6, 4];
    entries.forEach((entry, i) => {
        const tilt = tilts[i % tilts.length];
        if (Array.isArray(entry)) {
            if (column) y += 214;
            column = 0;
            html += caret(entry[1], 60, y, 250, entry[2] ?? "");
            y += 250;
        } else if (MEDIUM.has(entry)) {
            if (column) y += 214;
            column = 0;
            html += block(entry, 0, y, tilt / 2, true);
            y += 222;
        } else if (!column && !isSmall(entries[i + 1])) {
            html += block(entry, 105, y, tilt);
            y += 214;
        } else {
            html += block(entry, column ? 186 : 4, y + (column ? 22 : 0), tilt);
            if (column) y += 236;
            column = column ? 0 : 1;
        }
    });
    if (column) y += 214;
    return tall(y + 20, html);
}

/// One member of the home hero's cast: a widget at scale `k` with the words that asked for it above, and a pencil
/// sketch of its outline that app.js traces while the caret draws it. Positions are in page units. Without motion the
/// cast sits greyed out with one widget lit; with motion the caret draws them one by one at the easel.
const SKETCH = `<svg class="sketch" viewBox="0 0 170 182" aria-hidden="true"><rect class="edge" x="2" y="2" width="166" height="178" rx="26" pathLength="1"/><path class="lines" d="M18 28 h54 M18 66 h76 M18 90 h50" pathLength="1"/><circle class="lines" cx="134" cy="138" r="18" pathLength="1"/></svg>`;
const cast = (w, x, y, k, r, words, lit = false) =>
    `<div class="cast${lit ? " lit" : ""}" data-k="${k}" style="left: calc(${x} * var(--unit)); top: calc(${y} * var(--unit)); --u: calc(${k} * var(--unit)); --rot: ${r}deg"><p class="ask">${words}</p>${SKETCH}${block(w, 0, 0, r, true)}<i class="spark a"></i><i class="spark b"></i></div>`;
/// Where the caret draws each widget before it joins the group.
const easel = (x, y, k) =>
    `<div class="easel" data-k="${k}" style="left: calc(${x} * var(--unit)); top: calc(${y} * var(--unit))"></div>`;
const heroCaret = (x, y, w) =>
    `<span class="caret maker" data-pose="draw" data-eyes="happy" data-halo="#9cc3f5" style="left: calc(${x} * var(--u)); top: calc(${y} * var(--u)); width: calc(${w} * var(--u))"></span>`;
/// An audience hero's drawing, placed like a block.
const heroArt = (svg) => ({
    desk: () => `<div class="hero-art">${svg()}</div>`,
    mob: () => `<div class="hero-art">${svg()}</div>`,
});

/// A sign-up scene: three widgets for the audience under the moon caret's confetti.
const joinPile = (a, b, c) => ({
    desk: () =>
        block(a, 830, 600, -4) +
        block(b, 1000, 612, 5) +
        block(c, 915, 400, -6) +
        caret("jump", 870, 120, 260, 'data-moon="1"') +
        confettiBits(1000, 240),
    mob: () => "",
});

/// Each scene's layout for desktop and for phones. Section text sits left or right; the scene takes the other side.
export const SCENES = {
    // ---- Home page: two doors ----
    hero: {
        desk: () =>
            easel(966, 430, 0.89) +
            cast("luna", 690, 540, 0.64, -5, "“Tell me when<br>Luna was fed”", true) +
            cast("hearts", 690, 176, 0.66, -6, "“A heart button<br>for Sam”") +
            cast("streak", 1000, 170, 0.66, 5, "“Did I meditate<br>today?”") +
            heroCaret(752, 404, 285),
        // On a phone the drawing comes first, right under the headline, so the first screen shows the caret making a
        // widget; the finished group lines up below it.
        mob: () =>
            easel(214, 72, 0.72) +
            cast("hearts", 10, 330, 0.5, -6, "“A heart button<br>for Sam”") +
            cast("streak", 146, 336, 0.5, 4, "“Did I<br>meditate?”") +
            cast("luna", 282, 330, 0.5, -5, "“Tell me when<br>Luna was fed”", true) +
            heroCaret(58, 82, 200),
    },
    partnersDoor: {
        desk: () =>
            block("luna", 770, 250, -6) +
            block("hearts", 940, 210, 8) +
            floatingHeart(1110, 170, 44) +
            block("count", 740, 520, -3) +
            block("bins", 980, 720, 6),
        mob: () => stack(["luna", "hearts", "count", "bins"]),
    },
    growthDoor: {
        desk: () =>
            block("grid", 70, 230, -3) +
            block("water", 90, 500, 7) +
            block("streak", 320, 530, -6) +
            note(470, 120, 170, "Tap today's<br>square. That's<br>the whole log.", ARROW),
        mob: () => stack(["grid", "water", "streak"]),
    },
    joinAny: joinPile("streak", "luna", "hearts"),

    // ---- /partners ----
    partnersHero: heroArt(couchArt),
    home: {
        desk: () =>
            block("groc", 790, 260, -4, true) +
            caret("idle", 772, 428, 400, 'data-shadow="1"') +
            note(970, 110, 180, "Cross it off.<br>It's gone from<br>Sam's list too.", ARROW) +
            block("baby", 70, 720, -4) +
            block("chores", 470, 780, 3) +
            block("plant", 1000, 870, 7),
        mob: () =>
            stack(["luna", "bins", "groc", ["caret", "idle", 'data-shadow="1"'], "baby", "chores", "plant", "dinner"]),
    },
    couple: {
        desk: () =>
            block("days", 70, 190, -6) +
            block("count", 140, 640, -3, true) +
            caret("lean", 173, 339, 340, 'data-eyes="happy"') +
            caret("lean", 288, 339, 340, 'data-mirror="1"') +
            floatingHeart(374, 284, 52) +
            block("hearts", 470, 170, 9) +
            block("mood", 580, 800, -7) +
            block("quest", 800, 790, 3),
        mob: () => stack(["count", ["caret", "lean", 'data-eyes="happy"'], "hearts", "days", "mood", "quest"]),
    },
    joinPartners: joinPile("mood", "luna", "days"),

    // ---- /growth ----
    growthHero: heroArt(workoutArt),
    habits: {
        desk: () =>
            block("grid", 690, 240, -3) +
            note(960, 100, 190, "Tap today's square.<br>That's the whole log.", ARROW) +
            block("streak", 720, 510, 6) +
            block("water", 940, 530, -5) +
            block("pushups", 820, 790, 4),
        mob: () => stack(["grid", "streak", "water", "pushups"]),
    },
    goals: {
        desk: () =>
            block("savings", 70, 230, -3) +
            caret("lean", 440, 190, 260, 'data-mirror="1" data-arm="flex"') +
            block("sober", 90, 520, 7) +
            block("word", 300, 600, -4),
        mob: () => stack(["savings", "sober", ["caret", "lean", 'data-arm="flex"'], "word"]),
    },
    joinGrowth: {
        desk: () =>
            block("water", 830, 600, -4) +
            block("streak", 1000, 612, 5) +
            block("sober", 915, 400, -6) +
            caret("jump", 870, 120, 260, 'data-moon="1" data-arm="flex"') +
            confettiBits(1000, 240),
        mob: () => "",
    },
};
