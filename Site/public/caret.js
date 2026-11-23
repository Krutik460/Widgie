// The caret from App/Widgie/Design/Caret.swift, as SVG. Same pose curves, eye and cheek placement, so the app icon
// renders (docs/design/app-icon) and the site draw the in-app mascot. Coordinates are in a unit square scaled by `size`.

const POSES = {
    idle: { p: [0.5, 0.94, 0.5, 0.68, 0.5, 0.42, 0.5, 0.16], width: 0.17 },
    lean: { p: [0.42, 0.94, 0.42, 0.578, 0.484, 0.296, 0.581, 0.16], width: 0.177 },
    draw: { p: [0.22, 0.94, 0.339, 0.644, 0.474, 0.364, 0.576, 0.16], width: 0.186 },
    jump: { p: [0.5, 0.94, 0.528, 0.626, 0.472, 0.383, 0.5, 0.16], width: 0.153 },
};

function bezier(p, t) {
    const u = 1 - t;
    const [a, b, c, d] = [u * u * u, 3 * u * u * t, 3 * u * t * t, t * t * t];
    return [
        a * p[0][0] + b * p[1][0] + c * p[2][0] + d * p[3][0],
        a * p[0][1] + b * p[1][1] + c * p[2][1] + d * p[3][1],
    ];
}

function derivative(p, t) {
    const u = 1 - t;
    const [a, b, c] = [3 * u * u, 6 * u * t, 3 * t * t];
    return [0, 1].map((k) => a * (p[1][k] - p[0][k]) + b * (p[2][k] - p[1][k]) + c * (p[3][k] - p[2][k]));
}

/// options: pose, size, x, y (top-left of the square), color, eye, cheek, eyes ("open" | "happy"), cheeks (scale),
/// mirror (lean left), shadow (color or null), shadowOpacity.
// biome-ignore lint/correctness/noUnusedVariables: a global, for the classic scripts and modules that draw the caret.
function caretSVG(o) {
    const pose = POSES[o.pose || "idle"];
    const s = o.size;
    const pts = [0, 1, 2, 3].map((i) => {
        let x = pose.p[i * 2];
        if (o.mirror) x = 1 - x;
        return [o.x + x * s, o.y + pose.p[i * 2 + 1] * s];
    });
    const w = pose.width * s;
    let out = "";
    if (o.shadow) {
        const f = pts[0];
        out += `<ellipse cx="${f[0]}" cy="${f[1] + 2}" rx="${1.5 * w}" ry="${0.28 * w}" fill="${o.shadow}" opacity="${o.shadowOpacity ?? 0.16}"/>`;
    }
    out += `<path d="M${pts[0]} C${pts[1]} ${pts[2]} ${pts[3]}" fill="none" stroke="${o.color}" stroke-width="${w}" stroke-linecap="round"/>`;
    const along = (t) => {
        const c = bezier(pts, t);
        const d = derivative(pts, t);
        const len = Math.hypot(d[0], d[1]) || 1;
        return { c, n: [-d[1] / len, d[0] / len] };
    };
    const face = along(0.88);
    const rx = 0.134 * w;
    const ry = 0.169 * w;
    for (const sign of [-1, 1]) {
        const cx = face.c[0] + sign * face.n[0] * 0.22 * w;
        const cy = face.c[1] + sign * face.n[1] * 0.22 * w;
        if ((o.eyes || "open") === "open") {
            out += `<ellipse cx="${cx}" cy="${cy}" rx="${rx}" ry="${ry}" fill="${o.eye}"/>`;
        } else {
            out += `<path d="M${cx - 1.35 * rx} ${cy} Q${cx} ${cy - 1.6 * ry} ${cx + 1.35 * rx} ${cy}" fill="none" stroke="${o.eye}" stroke-width="${0.1 * w}" stroke-linecap="round"/>`;
        }
    }
    const cheeks = o.cheeks ?? 1;
    if (cheeks > 0 && o.cheek) {
        const blush = along(0.77);
        for (const sign of [-1, 1]) {
            const cx = blush.c[0] + sign * blush.n[0] * 0.3 * w;
            const cy = blush.c[1] + sign * blush.n[1] * 0.3 * w;
            out += `<ellipse cx="${cx}" cy="${cy}" rx="${0.14 * w * cheeks}" ry="${0.095 * w * cheeks}" fill="${o.cheek}" opacity=".95"/>`;
        }
    }
    return out;
}
