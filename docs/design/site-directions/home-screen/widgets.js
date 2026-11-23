// Phone scenes: a real-size iPhone home screen per audience, holding the widgets that audience would build
// (from docs/research/icp-and-widgets.md). The caret "says" each prompt, the slot is drawn in the app's dashed
// building style, then the widget fills in and works when tapped. Sizes are in iPhone points through --u.

const INK = "#121A2E";

const svg = {
    paw: '<svg viewBox="0 0 24 24" fill="currentColor"><ellipse cx="6" cy="10" rx="2.2" ry="2.8"/><ellipse cx="10" cy="5.8" rx="2.2" ry="2.8"/><ellipse cx="14.5" cy="5.8" rx="2.2" ry="2.8"/><ellipse cx="18.5" cy="10" rx="2.2" ry="2.8"/><path d="M12.2 11.2c-3 0-6.2 4.6-6.2 6.8 0 1.8 1.6 2.6 3 2.6 1.3 0 2-.6 3.2-.6s1.9.6 3.2.6c1.4 0 3-.8 3-2.6 0-2.2-3.2-6.8-6.2-6.8z"/></svg>',
    check: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="3.4" stroke-linecap="round" stroke-linejoin="round"><path d="M4.5 12.5l5 5 10-11"/></svg>',
    heart: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21s-7.5-4.6-9.6-9.3C.9 8.2 3 4.5 6.6 4.5c2.1 0 3.6 1.2 5.4 3.2 1.8-2 3.3-3.2 5.4-3.2 3.6 0 5.7 3.7 4.2 7.2C19.5 16.4 12 21 12 21z"/></svg>',
    bottle: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"><path d="M9 2.5h6M10 2.5v3l-2 3v11a2 2 0 0 0 2 2h4a2 2 0 0 0 2-2v-11l-2-3v-3"/><path d="M8 13h8"/></svg>',
    bin: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M4 6.5h16M9.5 6.5V4h5v2.5M6 6.5l1 14h10l1-14"/></svg>',
    cart: '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linecap="round" stroke-linejoin="round"><path d="M3 4h2.5l2.2 11h10.6L20.5 7H7"/><circle cx="9.5" cy="19.5" r="1.4"/><circle cx="17" cy="19.5" r="1.4"/></svg>',
    plane: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M21 15.5v-2l-8-5V3.8a1.5 1.5 0 0 0-3 0v4.7l-8 5v2l8-2.5v5l-2 1.5V21l3.5-1 3.5 1v-1.5l-2-1.5v-5z"/></svg>',
    spark: '<svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 2l2.2 7.8L22 12l-7.8 2.2L12 22l-2.2-7.8L2 12l7.8-2.2z"/></svg>',
};

/// Five faces for the mood widget, from low to high. Each is a mouth path and an eye style.
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
    return `<svg viewBox="0 0 24 24"><circle cx="12" cy="12" r="11" fill="${color}"/>${eyes}<path d="${f.mouth}" fill="${fill}" stroke="${INK}" stroke-width="1.8" stroke-linecap="round"/></svg>`;
}

const minutesAgo = (minutes) => Date.now() - minutes * 60000;

function since(at) {
    const minutes = Math.max(0, Math.floor((Date.now() - at) / 60000));
    if (minutes < 1) return "just now";
    if (minutes < 60) return `${minutes}m`;
    return `${Math.floor(minutes / 60)}h ${String(minutes % 60).padStart(2, "0")}m`;
}

// Each widget: its size, the prompt that builds it, its starting state, how to draw it, and what a tap does.
// `tap(state, target)` returns true when the widget should redraw.

const WIDGETS = {
    baby: {
        size: "medium",
        chip: "Baby feeds, red after 3 hours",
        prompt: "Log feeds with left, right or bottle. Show time since the last one, and turn red after 3 hours.",
        state: () => ({ at: minutesAgo(184), side: "Right", by: "Sam", today: 5 }),
        draw(s) {
            const late = Date.now() - s.at > 3 * 3600000;
            const dots = Array.from({ length: 8 }, (_, i) => `<i class="${i < s.today ? "on" : ""}"></i>`).join("");
            return `<div class="w baby ${late ? "late" : ""}">
                <div class="col">
                    <div class="w-label">${svg.bottle}Last feed</div>
                    <div class="w-big">${since(s.at)}</div>
                    <div class="w-small">${s.side} · by ${s.by}</div>
                    <div class="dots">${dots}</div>
                    <div class="w-tiny">${s.today} today</div>
                </div>
                <div class="sides">
                    <button data-tap="Left">L</button><button data-tap="Right">R</button><button data-tap="Bottle">${svg.bottle}</button>
                </div>
            </div>`;
        },
        tap(s, target) {
            if (!target.dataset.tap) return false;
            Object.assign(s, { at: Date.now(), side: target.dataset.tap, by: "you", today: Math.min(8, s.today + 1) });
            return true;
        },
    },
    luna: {
        size: "small",
        chip: "Fed the dog? Who and when",
        prompt: "One button for fed the dog. Show how long ago, and who did it.",
        state: () => ({ at: minutesAgo(134), by: "Maya" }),
        draw: (s) => `<div class="w luna">
                <div class="w-label">${svg.paw}Luna</div>
                <div class="w-big">${since(s.at)}</div>
                <div class="w-small">fed by ${s.by}</div>
                <button class="w-tap" data-tap="1" aria-label="Fed Luna">${svg.check}</button>
            </div>`,
        tap(s, target) {
            if (!target.closest("[data-tap]")) return false;
            Object.assign(s, { at: Date.now(), by: "you" });
            return true;
        },
    },
    bins: {
        size: "small",
        chip: "Whose turn for the bins",
        prompt: "Whose turn is it to take out the bins? Tap to pass it on.",
        state: () => ({ turn: 0, people: ["Sam", "Priya", "you"] }),
        draw: (s) => `<div class="w bins">
                <div class="w-label">${svg.bin}Bins night</div>
                <div class="w-big">${s.people[s.turn]}</div>
                <div class="w-small">${s.people[s.turn] === "you" ? "your turn" : "their turn"}</div>
                <button class="w-pass" data-tap="1">pass it on</button>
            </div>`,
        tap(s, target) {
            if (!target.closest("[data-tap]")) return false;
            s.turn = (s.turn + 1) % s.people.length;
            return true;
        },
    },
    groceries: {
        size: "medium",
        chip: "Shared grocery list",
        prompt: "Shared grocery list. Tap an item to cross it off.",
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
        draw: (s) => `<div class="w groceries">
                <div class="w-label">${svg.cart}Groceries <span>${s.items.filter((i) => !i[1]).length} left</span></div>
                <ul>${s.items.map(([name, done], i) => `<li><button data-tap="${i}" class="${done ? "crossed" : ""}"><i></i>${name}</button></li>`).join("")}</ul>
            </div>`,
        tap(s, target) {
            const button = target.closest("[data-tap]");
            if (!button) return false;
            const item = s.items[Number(button.dataset.tap)];
            item[1] = !item[1];
            return true;
        },
    },
    countdown: {
        size: "medium",
        chip: "Countdown to when I see Alex",
        prompt: "Countdown to when I see Alex, with cute hearts.",
        // Always twelve days out, so the date on the widget is real whenever someone visits.
        state: () => ({ visit: new Date(Date.now() + 12 * 86400000) }),
        draw: (s) => `<div class="w countdown">
                <div class="sun"></div>
                <div class="col">
                    <div class="w-label">${svg.plane}Lisbon</div>
                    <div class="w-huge">${Math.ceil((s.visit - Date.now()) / 86400000)}</div>
                    <div class="w-small">days until I see Alex</div>
                </div>
                <div class="floaters" data-tap="1">${[0, 1, 2, 3, 4].map((i) => `<span style="--i:${i}">${svg.heart}</span>`).join("")}</div>
                <div class="date">${s.visit.toLocaleDateString("en-US", { month: "short", day: "numeric" }).toUpperCase()}</div>
            </div>`,
        tap(_s, target, el) {
            if (!target.closest("[data-tap]")) return false;
            el.querySelector(".floaters").classList.remove("go");
            void el.offsetWidth;
            el.querySelector(".floaters").classList.add("go");
            return false;
        },
    },
    hearts: {
        size: "small",
        chip: "A heart button for Jo",
        prompt: "A button that sends a heart to Jo's widget. Show how many today.",
        state: () => ({ got: 5, sent: 3 }),
        draw: (s) => `<div class="w hearts">
                <div class="w-label">${svg.heart}Jo</div>
                <div class="w-big">${s.got}</div>
                <div class="w-small">from Jo today<br>${s.sent} sent</div>
                <button class="w-tap" data-tap="1" aria-label="Send Jo a heart">${svg.heart}</button>
            </div>`,
        tap(s, target, el) {
            if (!target.closest("[data-tap]")) return false;
            s.sent += 1;
            const flying = document.createElement("span");
            flying.className = "fly";
            flying.innerHTML = svg.heart;
            el.appendChild(flying);
            flying.addEventListener("animationend", () => flying.remove());
            return true;
        },
    },
    mood: {
        size: "small",
        chip: "Both of our moods today",
        prompt: "Pick my mood from 5 faces. Show both of our latest moods.",
        state: () => ({ mine: 2, theirs: 4 }),
        draw: (s) => `<div class="w mood">
                <div class="w-label">Today</div>
                <div class="faces">
                    <button data-tap="1" aria-label="Change my mood">${face(s.mine, "#FFFFFF")}<span>you</span></button>
                    <div>${face(s.theirs, "#FFC2CE")}<span>Jo</span></div>
                </div>
            </div>`,
        tap(s, target) {
            if (!target.closest("[data-tap]")) return false;
            s.mine = (s.mine + 1) % FACES.length;
            return true;
        },
    },
    question: {
        size: "medium",
        chip: "A new question for us every morning",
        prompt: "A new couples question every morning. Both of us tap when we've answered.",
        state: () => ({ me: false }),
        draw: (s) => `<div class="w question">
                <div class="w-label">${svg.spark}Today's question</div>
                <p>What's a tiny thing I did this week that you loved?</p>
                <div class="answered">
                    <span class="who on">Jo ✓</span>
                    <button data-tap="1" class="who ${s.me ? "on" : ""}">${s.me ? "You ✓" : "I answered"}</button>
                    <span class="note">${s.me ? "New one tomorrow" : ""}</span>
                </div>
            </div>`,
        tap(s, target) {
            if (!target.closest("[data-tap]")) return false;
            s.me = !s.me;
            return true;
        },
    },
};

/// Which widgets each page's phone shows, top to bottom (two smalls share a row).
const SCENES = {
    home: ["baby", "luna", "bins", "groceries"],
    us: ["countdown", "hearts", "mood", "question"],
    all: ["baby", "hearts", "luna", "countdown"],
};

const WALLPAPER = { home: "home", us: "us", all: "all" };
