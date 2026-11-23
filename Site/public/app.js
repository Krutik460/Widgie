// Behavior for every page: the toy box scenes and their motion, the sign-up form, the pair page and the leave page.
// A plain ES module, no build step; each part runs only when its elements are on the page.

import { mountCaret, mountWidget, SCENES } from "/widgets.js";

const TURNSTILE_SITE_KEY = ["localhost", "127.0.0.1"].includes(location.hostname)
    ? "1x00000000000000000000AA" // Cloudflare's always-pass test key
    : "0x4AAAAAAGPFp8cYi7D7tqsk";

const reducedMotion = matchMedia("(prefers-reduced-motion: reduce)").matches;
const mouse = matchMedia("(hover: hover) and (pointer: fine)").matches;
document.documentElement.classList.add("js");

// Remember where the visitor came from for the whole visit, so a signup two pages later still credits the channel.
const params = new URLSearchParams(location.search);
const arrivedFrom = params.get("utm_source") || params.get("ref");
if (arrivedFrom) sessionStorage.setItem("source", arrivedFrom);

// ---------- Scenes ----------

// Phones get their own arrangement of each scene; the breakpoint matches the stylesheet's.
const phone = matchMedia("(max-width: 760px)").matches;
for (const scene of document.querySelectorAll("[data-scene]")) {
    const layout = SCENES[scene.dataset.scene];
    scene.innerHTML = phone ? layout.mob() : layout.desk(scene.dataset.first === "1");
}
for (const el of document.querySelectorAll("[data-widget]")) mountWidget(el);
for (const el of document.querySelectorAll(".caret[data-pose]")) mountCaret(el);

// ---------- Motion: things arrive when their section does ----------

/// Wraps each letter of a headline's own text in a span, so the letters can pop in one after another.
function splitLetters(heading) {
    let index = 0;
    const walk = (node) => {
        for (const child of [...node.childNodes]) {
            if (child.nodeType === Node.TEXT_NODE) {
                const fragment = document.createDocumentFragment();
                for (const char of child.textContent) {
                    if (char.trim() === "") {
                        fragment.append(char);
                        continue;
                    }
                    const span = document.createElement("span");
                    span.className = "ch";
                    span.style.setProperty("--i", String(index++));
                    span.textContent = char;
                    fragment.append(span);
                }
                child.replaceWith(fragment);
            } else if (child.nodeType === Node.ELEMENT_NODE && !child.matches(".caret, .dot-tile, .blk")) {
                walk(child);
            }
        }
    };
    walk(heading);
    heading.setAttribute("aria-label", heading.textContent.replace(/\s+/g, " ").trim());
}

const fields = [...document.querySelectorAll(".field")];
if (!reducedMotion) {
    for (const heading of document.querySelectorAll(".field .display")) splitLetters(heading);
    for (const field of fields) {
        [...field.querySelectorAll(".blk")].forEach((blk, i) => {
            blk.style.setProperty("--i", String(i));
        });
    }
    const arrive = new IntersectionObserver(
        (entries) => {
            for (const entry of entries) {
                if (!entry.isIntersecting) continue;
                entry.target.classList.add("in");
                arrive.unobserve(entry.target);
            }
        },
        { threshold: 0.18 },
    );
    for (const field of fields) arrive.observe(field);
} else {
    for (const field of fields) field.classList.add("in");
}

// ---------- Motion: blocks drift with scroll, at their own depth ----------

const blocks = [...document.querySelectorAll(".blk")];
blocks.forEach((blk, i) => {
    // -0.5 to 0.5, a stable mix per block; blocks a caret holds or stands on stay put.
    blk.dataset.depth = blk.hasAttribute("data-still") ? "0" : String(((i * 37) % 5) / 4 - 0.5);
});
if (!reducedMotion) {
    let queued = false;
    const drift = () => {
        queued = false;
        const middle = innerHeight / 2;
        for (const blk of blocks) {
            const field = blk.closest(".field");
            const box = field.getBoundingClientRect();
            const offset = (box.top + box.height / 2 - middle) / innerHeight;
            blk.style.setProperty("--py", `${(offset * Number(blk.dataset.depth) * 90).toFixed(1)}px`);
        }
    };
    addEventListener(
        "scroll",
        () => {
            if (!queued) {
                queued = true;
                requestAnimationFrame(drift);
            }
        },
        { passive: true },
    );
    drift();
}

// ---------- Interaction: pick up, throw and stack the blocks (mouse and pen; touch keeps scrolling and tapping) ----------

let lifted = 100;
for (const blk of blocks) {
    let start = null;
    let moved = false;
    let last = null;
    let velocity = { x: 0, y: 0 };

    const position = () => ({
        x: Number.parseFloat(blk.style.getPropertyValue("--dx")) || 0,
        y: Number.parseFloat(blk.style.getPropertyValue("--dy")) || 0,
    });

    // A block can be picked up once it has landed; mid-drop its box is still moving.
    if (reducedMotion) blk.dataset.landed = "1";
    blk.addEventListener("animationend", (event) => {
        if (event.animationName === "drop") blk.dataset.landed = "1";
    });

    blk.addEventListener("pointerdown", (event) => {
        if (event.pointerType === "touch" || event.button !== 0 || event.target.closest("[data-tap]")) return;
        if (!blk.dataset.landed) return;
        const from = position();
        start = { x: event.clientX - from.x, y: event.clientY - from.y, at: from };
        last = { x: event.clientX, y: event.clientY, t: performance.now() };
        moved = false;
        blk.setPointerCapture(event.pointerId);
    });

    blk.addEventListener("pointermove", (event) => {
        if (start) {
            const x = event.clientX - start.x;
            const y = event.clientY - start.y;
            if (!moved && Math.hypot(x - start.at.x, y - start.at.y) < 5) return;
            if (!moved) {
                moved = true;
                blk.classList.add("held");
                blk.style.zIndex = String(++lifted);
            }
            const now = performance.now();
            const dt = Math.max(1, now - last.t);
            velocity = { x: (event.clientX - last.x) / dt, y: (event.clientY - last.y) / dt };
            last = { x: event.clientX, y: event.clientY, t: now };
            blk.style.setProperty("--dx", `${x}px`);
            blk.style.setProperty("--dy", `${y}px`);
            blk.style.setProperty("--tilt", `${Math.max(-18, Math.min(18, velocity.x * 14))}deg`);
        } else if (mouse && !reducedMotion) {
            // Hover: the block leans toward the pointer.
            const box = blk.getBoundingClientRect();
            const across = (event.clientX - box.left) / box.width - 0.5;
            blk.style.setProperty("--tilt", `${(across * 6).toFixed(2)}deg`);
        }
    });

    const release = () => {
        if (!start) return;
        start = null;
        if (!moved) return;
        // A throw: keep going a little in the direction of travel, then settle with a bounce. Speed is capped and the
        // landing spot stays inside the block's own section, so nothing can be flung off the page.
        const at = position();
        const fresh = performance.now() - last.t < 80;
        const cap = (v) => Math.max(-1.6, Math.min(1.6, fresh ? v : 0));
        let x = at.x + cap(velocity.x) * 140;
        let y = at.y + cap(velocity.y) * 140;
        const field = blk.closest(".field").getBoundingClientRect();
        const box = blk.getBoundingClientRect();
        const margin = 12;
        x +=
            Math.max(0, field.left + margin - (box.left + x - at.x)) -
            Math.max(0, box.right + x - at.x - (field.right - margin));
        y +=
            Math.max(0, field.top + margin - (box.top + y - at.y)) -
            Math.max(0, box.bottom + y - at.y - (field.bottom - margin));
        blk.classList.remove("held");
        blk.classList.add("thrown");
        blk.style.setProperty("--dx", `${x}px`);
        blk.style.setProperty("--dy", `${y}px`);
        blk.style.setProperty("--tilt", "0deg");
        setTimeout(() => blk.classList.remove("thrown"), 600);
        // The click that follows a drag must not tap the widget.
        blk.addEventListener("click", (e) => e.stopPropagation(), { capture: true, once: true });
    };
    blk.addEventListener("pointerup", release);
    blk.addEventListener("pointercancel", release);
    blk.addEventListener("pointerleave", () => {
        if (!start) blk.style.setProperty("--tilt", "0deg");
    });
}

// ---------- Interaction: every caret watches the pointer ----------

const eyes = [...document.querySelectorAll(".caret .look")];
if (mouse && !reducedMotion && eyes.length) {
    addEventListener("pointermove", (event) => {
        for (const look of eyes) {
            const box = look.getBoundingClientRect();
            const dx = event.clientX - (box.left + box.width / 2);
            const dy = event.clientY - (box.top + box.height / 2);
            const length = Math.hypot(dx, dy) || 1;
            look.style.transform = `translate(${(dx / length) * 1.6}px, ${(dy / length) * 1.4}px)`;
        }
    });
}

// ---------- Sign-up form ----------

function renderTurnstile() {
    // The script defines window.turnstile before render exists; onTurnstileLoad calls back once it is ready.
    if (typeof window.turnstile?.render !== "function") return;
    for (const box of document.querySelectorAll(".turnstile:not([data-rendered])")) {
        box.dataset.rendered = "1";
        window.turnstile.render(box, {
            sitekey: TURNSTILE_SITE_KEY,
            appearance: "interaction-only",
            callback: (token) => {
                box.dataset.token = token;
            },
            "expired-callback": () => {
                box.dataset.token = "";
            },
        });
    }
}
window.onTurnstileLoad = renderTurnstile;

function confetti() {
    if (reducedMotion) return;
    const layer = document.createElement("div");
    layer.className = "confetti";
    const colors = ["#ffd23c", "#ff7f8e", "#a9e9cd", "#9cc3f5", "#ff6b5c"];
    for (let i = 0; i < 60; i++) {
        const bit = document.createElement("i");
        bit.style.left = `${Math.random() * 100}%`;
        bit.style.background = colors[i % colors.length];
        bit.style.animationDelay = `${Math.random() * 0.35}s`;
        bit.style.setProperty("--r", `${Math.random() * 720 - 360}deg`);
        layer.appendChild(bit);
    }
    document.body.appendChild(layer);
    setTimeout(() => layer.remove(), 2600);
}

function setupForm(form, extra) {
    const error = form.querySelector(".error");
    const button = form.querySelector("button[type=submit]");
    const check = form.querySelector(".turnstile");
    const done = form.parentElement.querySelector(".done");
    form.addEventListener("submit", async (event) => {
        event.preventDefault();
        error.textContent = "";
        const token = check?.dataset.token;
        if (!token) {
            error.textContent = "One second, checking you're a person. Try again in a moment.";
            return;
        }
        button.disabled = true;
        const data = new FormData(form);
        try {
            const response = await fetch("/api/signup", {
                method: "POST",
                headers: { "Content-Type": "application/json" },
                body: JSON.stringify({
                    email: data.get("email"),
                    idea: data.get("idea") || "",
                    segment: form.dataset.segment || data.get("segment") || "home",
                    source: sessionStorage.getItem("source") || "",
                    turnstile: token,
                    ...extra(),
                }),
            });
            const body = await response.json().catch(() => ({}));
            if (!response.ok) throw new Error(body.error || "Something went wrong, try again.");
            form.hidden = true;
            for (const element of document.querySelectorAll("[data-hide-on-done]")) element.hidden = true;
            done.hidden = false;
            for (const el of done.querySelectorAll(".caret[data-pose]")) mountCaret(el);
            confetti();
        } catch (failure) {
            const line = failure.message || "Something went wrong, try again.";
            error.textContent = line.charAt(0).toUpperCase() + line.slice(1);
            button.disabled = false;
            window.turnstile?.reset(check);
            check.dataset.token = "";
        }
    });
}

for (const form of document.querySelectorAll("form.signup:not([data-pair])")) setupForm(form, () => ({}));

// ---------- Pair page: /p/<code> to join someone, /p/<code>?joined=1 after confirming ----------

const COPY = {
    home: {
        invite: "Someone in your home wants to share widgets with you.",
        waiting: (n) =>
            n === 1 ? "1 person from this home is on the list" : `${n} people from this home are on the list`,
        share: (n) =>
            n === 1
                ? "Send this to the people you live with. When they join, you get in together."
                : "Your home is on the list together. Anyone else who lives with you? Send them this too.",
        count: (n) => (n === 1 ? "Just you so far" : `${n} people in this home`),
        complete: () => false,
        text: "Let's stop asking who fed the dog. Join me on the Widgie early list:",
    },
    us: {
        invite: "Your person wants a widget only the two of you share.",
        waiting: () => "They're already on the list",
        share: (n) =>
            n === 1
                ? "Send this to your person. When they join, you get in together."
                : "You're both on the list, so you'll get in together.",
        count: (n) => (n === 1 ? "Just you so far" : n === 2 ? "You two are in" : `${n} of you are in`),
        complete: (n) => n >= 2,
        text: "I want a widget only we share. Join me on the Widgie early list:",
    },
};

async function setupPair(root) {
    const code = location.pathname.split("/")[2];
    const joined = params.get("joined") === "1";
    let info = null;
    try {
        const response = await fetch(`/api/pair/${code}`);
        if (response.ok) info = await response.json();
    } catch {}

    if (!info) {
        root.querySelector("#unknown").hidden = false;
        return;
    }
    const copy = COPY[info.segment];
    const shareUrl = `${location.origin}/p/${code}`;

    if (joined) {
        const share = root.querySelector("#share");
        share.hidden = false;
        share.querySelector(".share-copy").textContent = copy.share(info.members);
        share.querySelector(".count").textContent = copy.count(info.members);
        if (info.members > 1) {
            const party = share.querySelector(".caret");
            party.dataset.pose = "jump";
            party.dataset.eyes = "happy";
            mountCaret(party);
            party.classList.add("hopping");
            confetti();
        }
        if (copy.complete(info.members)) {
            share.querySelector(".share-box").hidden = true;
            return;
        }
        share.querySelector(".share-box input").value = shareUrl;
        const copyButton = share.querySelector("#copy");
        copyButton.addEventListener("click", async () => {
            await navigator.clipboard.writeText(shareUrl);
            copyButton.textContent = "Copied";
            setTimeout(() => {
                copyButton.textContent = "Copy";
            }, 1600);
        });
        const nativeShare = share.querySelector("#native-share");
        if (navigator.share) {
            nativeShare.hidden = false;
            nativeShare.addEventListener("click", () =>
                navigator.share({ title: "Join me on Widgie", text: copy.text, url: shareUrl }).catch(() => {}),
            );
        }
        return;
    }

    const join = root.querySelector("#join-state");
    join.hidden = false;
    join.querySelector(".invite-copy").textContent = copy.invite;
    join.querySelector(".count").textContent = copy.waiting(info.members);
    const form = join.querySelector("form");
    form.dataset.segment = info.segment;
    setupForm(form, () => ({ pair: code }));
}

const pairRoot = document.getElementById("join-root");
if (pairRoot) setupPair(pairRoot);

// ---------- Leave page ----------

const leaveButton = document.getElementById("leave");
leaveButton?.addEventListener("click", async () => {
    leaveButton.disabled = true;
    const response = await fetch(`/api/leave${location.search}`, { method: "POST" }).catch(() => null);
    document.getElementById(response?.ok ? "left" : "leave-failed").hidden = false;
    leaveButton.hidden = true;
});

// Last, so nothing above waits on the bot check's script.
renderTurnstile();
