// The home screen world: mount the real widgets, run the live build, rotate the Smart Stack, place the carets.

const SKY = "#C4D8F3";
const CHEEK = "#FF7F8E";

function caret(el, o, fit = "xMidYMid meet") {
    const box = 100;
    el.innerHTML = `<svg viewBox="0 0 ${box} ${box}" preserveAspectRatio="${fit}">${caretSVG({ size: box, x: 0, y: 0, color: INK, eye: SKY, cheek: CHEEK, ...o })}</svg>`;
}

// One more small widget for couples and housemates alike.
WIDGETS.safe = {
    size: "small",
    state: () => ({ alex: "6:12pm", me: false }),
    draw: (s) => `<div class="w safe">
            <div class="w-label"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.4" stroke-linejoin="round"><path d="M4 11l8-6.5 8 6.5V20H4z"/></svg>Home safe</div>
            <div class="w-big">${s.me ? "Both" : "Alex"}</div>
            <div class="w-small">${s.me ? "home, sleep well" : `home at ${s.alex}`}</div>
            <button class="w-tap" data-tap="1" aria-label="I'm home">${svg.check}</button>
        </div>`,
    tap(s, target) {
        if (!target.closest("[data-tap]")) return false;
        s.me = !s.me;
        return true;
    },
};

function mount(face, key) {
    const widget = WIDGETS[key];
    const state = widget.state();
    const render = () => {
        face.innerHTML = widget.draw(state);
    };
    render();
    face.addEventListener("click", (e) => {
        if (widget.tap(state, e.target, face.firstElementChild)) render();
    });
    return render;
}

const renders = [...document.querySelectorAll("[data-widget]")].map((tile) => mount(tile.querySelector(".face"), tile.dataset.widget));
setInterval(() => renders.forEach((r) => r()), 30000);

// ---------- Carets around the world ----------

caret(document.getElementById("peek"), { pose: "lean", mirror: true });
caret(document.getElementById("stand"), { pose: "lean", mirror: true, eyes: "open", shadow: INK, shadowOpacity: 0.16 }, "xMidYMax slice");
caret(document.getElementById("sitter"), { pose: "idle", eyes: "happy", shadow: INK, shadowOpacity: 0.18 }, "xMidYMax slice");
caret(document.getElementById("mini-caret"), { pose: "draw" });
document.getElementById("jumper").innerHTML = `<svg viewBox="0 0 100 100" preserveAspectRatio="xMidYMax meet">${caretSVG({
    size: 100, x: 0, y: 0, pose: "jump", color: "#E9F2FF", eye: "#2B4E82", cheek: CHEEK, eyes: "happy", shadow: "#0B1A33", shadowOpacity: 0.35,
})}</svg>`;

// The wallpaper: one giant caret stroke, no face, soft as a cloud.
(function wallpaper() {
    const el = document.getElementById("giant");
    const w = Math.max(document.documentElement.clientWidth, 390);
    const size = Math.max(1500, w * 1.25);
    el.setAttribute("viewBox", `0 0 ${w} 2800`);
    el.innerHTML =
        caretSVG({ size, x: w * 0.42 - size * 0.5, y: -size * 0.12, pose: "lean", color: "rgba(255,255,255,0.55)", eye: "transparent" }) +
        caretSVG({ size: size * 0.8, x: -size * 0.32, y: 1150, pose: "draw", mirror: true, color: "rgba(150,186,236,0.55)", eye: "transparent" });
})();

// ---------- The live build ----------

const build = (() => {
    const tile = document.getElementById("build");
    const slot = tile.querySelector(".slot");
    const svgEl = slot.querySelector(".outline");
    const dash = slot.querySelector(".dash-path");
    const reveal = slot.querySelector(".reveal-path");
    const typed = slot.querySelector(".typed");
    const built = slot.querySelector(".built");
    const drawer = slot.querySelector(".drawer");
    const label = document.getElementById("build-label");

    const ORDER = ["countdown", "baby", "groceries"];
    const TYPE = 1700;
    const DRAW = 2700;
    const FILL = 3000;
    const HOLD = 6400;
    const CYCLE = 7000;

    let length = 1;
    let size = 100;
    let pose = "";

    function layout() {
        const r = slot.getBoundingClientRect();
        const w = r.width;
        const h = r.height;
        const rad = parseFloat(getComputedStyle(slot).borderRadius) || 30;
        svgEl.setAttribute("viewBox", `0 0 ${w} ${h}`);
        // Start a third of the way down the right edge and go clockwise, so the caret ends where it began,
        // leaning out into the margin instead of over the content.
        const sy = h * 0.36;
        const q = rad - 1.5;
        const d = `M${w - 1.5} ${sy} V${h - rad} A${q} ${q} 0 0 1 ${w - rad} ${h - 1.5} H${rad} A${q} ${q} 0 0 1 1.5 ${h - rad} V${rad} A${q} ${q} 0 0 1 ${rad} 1.5 H${w - rad} A${q} ${q} 0 0 1 ${w - 1.5} ${rad} Z`;
        dash.setAttribute("d", d);
        reveal.setAttribute("d", d);
        length = dash.getTotalLength();
        reveal.style.strokeDasharray = `${length} ${length}`;
        size = Math.round(h * (w < 500 ? 0.4 : 0.36));
        drawer.style.width = drawer.style.height = `${size}px`;
        pose = "";
    }

    function setPose(p, eyes) {
        const key = p + eyes;
        if (key === pose) return;
        pose = key;
        caret(drawer, { pose: p, eyes });
    }

    function place(len, lift, p) {
        const pt = dash.getPointAtLength(((len % length) + length) % length);
        // the caret's tip (its foot) is the first point of its pose curve
        const [fx, fy] = POSES[p].p;
        drawer.style.transform = `translate(${pt.x - fx * size}px, ${pt.y - fy * size - lift}px)`;
    }

    let index = -1;
    let start = 0;

    function cycle(n) {
        index = n;
        const key = ORDER[n % ORDER.length];
        const widget = WIDGETS[key];
        built.innerHTML = widget.draw(widget.state());
        built.dataset.prompt = widget.prompt.split(".")[0] + ".";
        slot.classList.remove("filled");
        label.textContent = "Building a widget";
    }

    function frame(t) {
        const n = Math.floor(t / CYCLE);
        if (n !== index) cycle(n);
        const p = t % CYCLE;
        const key = ORDER[n % ORDER.length];
        const prompt = built.dataset.prompt;

        typed.textContent = p < FILL ? prompt.slice(0, Math.round(prompt.length * Math.min(1, p / TYPE))) + (p >= TYPE ? "”" : "") : "";
        const drawn = Math.min(1, p / DRAW);
        const fade = p > HOLD ? 1 - (p - HOLD) / (CYCLE - HOLD) : 1;
        reveal.style.strokeDashoffset = `${length * (1 - drawn)}`;
        dash.style.opacity = p > FILL ? 0 : 1;

        if (p >= FILL && p < HOLD) {
            if (!slot.classList.contains("filled")) {
                slot.classList.add("filled");
                label.textContent = WIDGETS[key].chip;
            }
        } else if (p >= HOLD) {
            slot.classList.remove("filled");
        }

        // The caret draws with its tip, hops once when the widget lands, then waits.
        // After the hop it ducks down behind the new widget, and comes back up for the next one.
        let lift = 0;
        let shown = Math.min(1, p / 250);
        let current = "draw";
        if (p < DRAW) setPose("draw", "open");
        else if (p < FILL + 600) {
            const k = (p - DRAW) / (FILL + 600 - DRAW);
            lift = Math.sin(Math.PI * k) * size * 0.28;
            current = "jump";
            setPose("jump", "happy");
        } else {
            const k = Math.min(1, (p - FILL - 600) / 350);
            lift = -k * size * 0.5;
            shown = 1 - k;
            current = "jump";
            setPose("jump", "happy");
        }
        place(length * drawn, lift, current);
        drawer.style.opacity = shown * fade;
    }

    layout();
    addEventListener("resize", layout);

    // ?t=ms freezes the loop at one moment (for still renders); otherwise start mid-draw so it reads at once.
    const frozen = new URLSearchParams(location.search).get("t");
    if (frozen !== null) {
        document.documentElement.classList.add("still");
        frame(Number(frozen));
        return;
    }
    const offset = 500;
    start = performance.now() - offset;
    // a timer rather than requestAnimationFrame, so the loop also runs in offscreen snapshot renders
    const tick = () => frame(performance.now() - start);
    tick();
    setInterval(tick, 1000 / 60);
})();

// ---------- Smart Stack and the steps beside it ----------

(function stack() {
    const cards = [...document.querySelectorAll("#stack .card")];
    const pips = [...document.querySelectorAll("#stack .pips i")];
    const steps = [...document.querySelectorAll(".steps li")];
    let front = 0;
    const show = () => {
        cards.forEach((c, i) => (c.dataset.pos = (i - front + cards.length) % cards.length));
        pips.forEach((p, i) => p.classList.toggle("on", i === front));
        steps.forEach((s, i) => s.classList.toggle("on", i === front));
    };
    show();
    setInterval(() => {
        const leaving = cards[front];
        leaving.classList.add("leaving");
        setTimeout(() => {
            leaving.classList.remove("leaving");
            front = (front + 1) % cards.length;
            show();
        }, 380);
    }, 3400);
})();

// ---------- Page dots follow the scroll; the sky goes dusk on page three ----------

(function pagesDots() {
    const pages = [...document.querySelectorAll(".page")];
    const dots = [...document.querySelectorAll(".pages i")];
    const update = () => {
        const mid = innerHeight * 0.5;
        let current = 0;
        pages.forEach((p, i) => {
            if (p.getBoundingClientRect().top < mid) current = i;
        });
        dots.forEach((d, i) => d.classList.toggle("on", i === current));
        document.body.classList.toggle("at-dusk", current === 2);
    };
    addEventListener("scroll", update, { passive: true });
    update();
})();

function joined(form) {
    form.classList.add("done");
    const button = form.querySelector("button");
    button.firstChild.textContent = "You're in";
    form.querySelector("input").disabled = true;
    return false;
}
