#!/usr/bin/env python3
"""Round two: JavaScript looks only, with a fit check and reference images.

Part B reruns the six round-one look prompts. Part C gives the model a reference image and the
words "make my widget look like this". Every cell gets at most one validity repair and one fit repair.

Usage: generate_round2.py [--only SUBSTRING] [--force] [--jobs N] [--rerender] [--sanity]
"""
import argparse
import base64
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import generate as round1

ROOT = Path(__file__).resolve().parent
RENDER = ROOT / ".build/release/render"
RUNS = ROOT / "runs-round2"
RESULTS = ROOT / "results-round2.json"
MODELS = ["haiku", "sonnet"]
SIZES = {"small": (158, 158), "medium": (338, 158)}
STATES = ["a", "b"]
FIT_LIMIT_PT = 2
WIDGETS = round1.WIDGETS
SYSTEM_PROMPT = round1.SYSTEM_PROMPT
USER_WORDS = "make my widget look like this"

REFERENCES = [
    {"id": "R1-lcd-habit", "widget": "habit", "image": "refs/R1-lcd-watch.png",
     "what": "inside the vocabulary: the round-one LCD watch render (prompt 2, J-sonnet, medium)"},
    {"id": "R2-pass-todo", "widget": "todo", "image": "refs/R2-boarding-pass.png",
     "what": "outside the vocabulary: a vintage boarding pass drawn as SVG and rasterized here"},
    {"id": "R3-photo-water", "widget": "water", "image": "refs/R3-photo.jpg",
     "what": "a photo: one still from the macOS desktop pictures"},
]

JOBS = [{"group": "rerun", "id": p["id"], "widget": p["widget"], "text": p["text"], "image": None} for p in round1.PROMPTS] + [
    {"group": "reference", "id": r["id"], "widget": r["widget"], "text": USER_WORDS, "image": r["image"]} for r in REFERENCES
]

MEDIA_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


def fixture_path(widget, state):
    return ROOT / "fixtures" / f"{widget}-{state}.json"


def image_size(path):
    out = subprocess.run(["sips", "-g", "pixelWidth", "-g", "pixelHeight", str(path)], capture_output=True, text=True).stdout
    return int(re.search(r"pixelWidth: (\d+)", out).group(1)), int(re.search(r"pixelHeight: (\d+)", out).group(1))


def build_prompt(job):
    w = WIDGETS[job["widget"]]
    reference = (ROOT / "lang-js.md").read_text().strip()
    sample = fixture_path(job["widget"], "a").read_text().strip()
    if w["actions"]:
        actions = "\n".join(f"- `{k}`: {d}" for k, d in w["actions"].items())
        actions += "\n\nUse these ids as the `action` of `button` nodes. No other action ids exist."
    else:
        actions = "This widget has no actions. Do not use `button`."
    if job["image"]:
        iw, ih = image_size(ROOT / job["image"])
        images = (
            f"The user attached one picture. It is shown to you with this message, and it is available as the image asset "
            f"`reference` ({iw} x {ih} pixels). No other image assets exist."
        )
        asked = f"The user attached the picture and wrote: \"{job['text']}\""
    else:
        images = "This widget has no image assets. Do not use `image`."
        asked = f"\"{job['text']}\""
    return (
        f"{reference}\n\n---\n\n# Your task\n\n"
        f"Write the look for this widget.\n\n"
        f"## Data\n\nThe widget's data has these fields:\n\n```\n{w['schema']}\n```\n\n"
        f"One sample of the data. The values change over time, and the look must work for any values:\n\n"
        f"```json\n{sample}\n```\n\n"
        f"## Actions\n\n{actions}\n\n"
        f"## Images\n\n{images}\n\n"
        f"## Sizes\n\nThe same look is drawn in both families: small (158 x 158 points) and medium (338 x 158 points). "
        f"It must look right in both.\n\n"
        f"## The look the user asked for\n\n{asked}\n\n"
        f"Reply with the look only, as one fenced ```js code block. No explanation before or after."
    )


def second_sample(job):
    return json.dumps(json.loads(fixture_path(job["widget"], "b").read_text()), separators=(",", ":"))


def build_validity_repair(job, look, error, state, family):
    where = f"The error came up while drawing the {family} family"
    where += f" with this data:\n\n```json\n{second_sample(job)}\n```" if state != "a" else " with the sample data above."
    return (
        build_prompt(job)
        + f"\n\n---\n\n# Your previous attempt\n\n```js\n{look}\n```\n\n"
        f"# It failed with this error\n\n```\n{error}\n```\n\n{where}\n\n"
        f"Reply with the complete corrected look only, as one fenced ```js code block. No explanation before or after."
    )


EDGE_WORDS = {"top": "past the top edge", "bottom": "past the bottom edge", "leading": "past the left edge", "trailing": "past the right edge"}


def describe_fit(fit, family):
    """One paragraph of measured facts for one render."""
    w, h = SIZES[family]
    if fit["max"] <= FIT_LIMIT_PT:
        line = "fits."
    else:
        parts = []
        lw, lh = fit["layout"]["width"], fit["layout"]["height"]
        if lw > 0 or lh > 0:
            parts.append(
                f"the layout needs {fmt(w + lw)} x {fmt(h + lh)} points, which is "
                + " and ".join(x for x in [f"{fmt(lw)} pt too wide" if lw > 0 else "", f"{fmt(lh)} pt too tall" if lh > 0 else ""] if x)
                + ". It is centered, so the excess is cut off on both sides"
            )
        cut = []
        for c in fit["cut"][:6]:
            label = c["label"] if len(c["label"]) <= 40 else c["label"][:37] + "..."
            name = f"{c['type']} \"{label}\"" if c["type"] == "text" else f"{c['type']} `{label}`"
            if c["within"] == "widget":
                where = ", ".join(f"{fmt(c[e])} pt {EDGE_WORDS[e]}" for e in EDGE_WORDS if e in c)
            else:
                where = f"{fmt(c['max'])} pt outside the clipped container it sits in"
            cut.append(f"{name} ({where})")
        if cut:
            more = fit["cut_count"] - len(cut)
            parts.append("cut off: " + "; ".join(cut) + (f"; and {more} more" if more > 0 else ""))
        line = "does not fit. " + ". ".join(p[0].upper() + p[1:] for p in parts) + "."
    if fit["truncated"]:
        names = []
        for t in fit["truncated"][:6]:
            value = t["value"] if len(t["value"]) <= 40 else t["value"][:37] + "..."
            names.append(f"\"{value}\"")
        line += " Text cut short with an ellipsis: " + ", ".join(names) + "."
    return line


def fmt(x):
    return f"{x:.1f}".rstrip("0").rstrip(".")


def build_fit_repair(job, look, renders):
    lines = []
    needs_second = False
    for family in SIZES:
        w, h = SIZES[family]
        for state in STATES:
            fit = renders[f"{state}-{family}"]["fit"]
            sample = "the sample data above" if state == "a" else "the second data sample below"
            if state == "b" and (fit["max"] > FIT_LIMIT_PT or fit["truncated"]):
                needs_second = True
            lines.append(f"- {family} ({w} x {h} points), {sample}: {describe_fit(fit, family)}")
    second = f"\n\nThe second data sample:\n\n```json\n{second_sample(job)}\n```" if needs_second else ""
    return (
        build_prompt(job)
        + f"\n\n---\n\n# Your previous attempt\n\n```js\n{look}\n```\n\n"
        f"# It draws without errors, but it does not fit the widget\n\n"
        f"The app drew it in both sizes with two data samples and measured it. Whatever falls outside the widget is cut off. "
        f"The small widget is 158 x 158 points and the medium widget is 338 x 158 points.\n\n"
        + "\n".join(lines)
        + second
        + "\n\nChange the look so that everything fits inside the widget in both sizes, with nothing cut off and no text cut short. "
        f"Keep the design the user asked for. Make things smaller or tighter, or show less in the small size. "
        f"Clipping or hiding the overflow is not a fix.\n\n"
        f"Reply with the complete corrected look only, as one fenced ```js code block. No explanation before or after."
    )


def call_model(model, prompt, image, empty_dir, system_prompt=SYSTEM_PROMPT):
    """One model call. The image, when there is one, travels as an image block in the user message."""
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    cmd = [
        "claude", "-p", "--model", model, "--safe-mode", "--system-prompt", system_prompt,
        "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
        "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    ]
    content = []
    if image:
        path = ROOT / image
        content.append({"type": "image", "source": {
            "type": "base64", "media_type": MEDIA_TYPES[path.suffix.lower()], "data": base64.b64encode(path.read_bytes()).decode()}})
    content.append({"type": "text", "text": prompt})
    message = json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n"
    last = None
    for attempt in range(3):
        t0 = time.time()
        try:
            proc = subprocess.run(cmd, input=message, capture_output=True, text=True, cwd=empty_dir, env=env, timeout=900)
        except subprocess.TimeoutExpired:
            last = "timed out after 900 s"
            continue
        seconds = time.time() - t0
        out = None
        for line in proc.stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "result":
                out = event
        if out and not out.get("is_error") and isinstance(out.get("result"), str) and out["result"].strip():
            usage = out.get("usage", {})
            return {
                "text": out["result"],
                "seconds": round(seconds, 2),
                "api_seconds": round(out.get("duration_api_ms", 0) / 1000, 2),
                "num_turns": out.get("num_turns"),
                "output_tokens": usage.get("output_tokens"),
                "input_tokens": (usage.get("input_tokens") or 0) + (usage.get("cache_creation_input_tokens") or 0)
                + (usage.get("cache_read_input_tokens") or 0),
                "models": sorted((out.get("modelUsage") or {}).keys()),
                "transport_retries": attempt,
            }
        last = f"exit {proc.returncode}: {json.dumps(out)[:400] if out else proc.stdout[-300:]} {proc.stderr[:300]}"
        time.sleep(3)
    raise RuntimeError(f"model call failed three times: {last}")


def render_all(job, look_path, out_dir):
    renders = {}
    first_error = None
    assets = ["--asset", f"reference={ROOT / job['image']}"] if job["image"] else []
    for state in STATES:
        for family in SIZES:
            png = out_dir / f"{state}-{family}.png"
            if png.exists():
                png.unlink()
            proc = subprocess.run(
                [str(RENDER), "js", str(look_path), str(fixture_path(job["widget"], state)), family, str(png)] + assets,
                capture_output=True, text=True, timeout=60,
            )
            key = f"{state}-{family}"
            if proc.returncode == 0:
                stats = json.loads(proc.stdout)
                stats["png"] = str(png.relative_to(ROOT))
                renders[key] = stats
            else:
                error = proc.stderr.strip().splitlines()[-1] if proc.stderr.strip() else f"render exited {proc.returncode}"
                error = re.sub(r"^error: ", "", error)
                renders[key] = {"ok": False, "error": error}
                if first_error is None:
                    first_error = {"error": error, "state": state, "family": family}
    return renders, first_error


def measure(renders):
    ok = {k: r for k, r in renders.items() if r.get("ok")}
    return {
        "overflow_pt": {k: r["fit"]["max"] for k, r in ok.items()},
        "layout_overflow_pt": {k: max(r["fit"]["layout"]["width"], r["fit"]["layout"]["height"]) for k, r in ok.items()},
        "content_overflow_pt": {k: r["fit"]["content_max"] for k, r in ok.items()},
        "truncated_texts": {k: len(r["fit"]["truncated"]) for k, r in ok.items()},
        "texts": {k: r["fit"]["texts"] for k, r in ok.items()},
    }


def run_attempt(job, model, cell_dir, number, kind, request, empty_dir):
    try_dir = cell_dir / f"try{number}"
    try_dir.mkdir(parents=True, exist_ok=True)
    (try_dir / "request.md").write_text(request)
    reply = call_model(model, request, job["image"], empty_dir)
    (try_dir / "reply.txt").write_text(reply["text"])
    look, fence = round1.extract_look(reply["text"])
    look_path = try_dir / "look.js"
    look_path.write_text(look)
    renders, first_error = render_all(job, look_path, try_dir)
    attempt = {
        "kind": kind,
        "look": str(look_path.relative_to(ROOT)),
        "reply": str((try_dir / "reply.txt").relative_to(ROOT)),
        "request": str((try_dir / "request.md").relative_to(ROOT)),
        "image_sent": job["image"],
        "bytes": len(look.encode()),
        "gen_seconds": reply["seconds"],
        "api_seconds": reply["api_seconds"],
        "num_turns": reply["num_turns"],
        "output_tokens": reply["output_tokens"],
        "input_tokens": reply["input_tokens"],
        "models": reply["models"],
        "transport_retries": reply["transport_retries"],
        "fence": fence,
        "valid": first_error is None,
        "first_error": first_error,
        "renders": renders,
        **measure(renders),
    }
    return attempt, look


def worst(attempt):
    return max(attempt["overflow_pt"].values(), default=0)


def assemble(job, model, attempts):
    cell_id = f"{job['id']}__J-{model}"
    first_valid = next((i for i, a in enumerate(attempts) if a["valid"]), None)
    fit_index = next((i for i, a in enumerate(attempts) if a["kind"] == "fit repair"), None)
    valid_indexes = [i for i, a in enumerate(attempts) if a["valid"]]
    # The look that was fit-checked, and the look the user would end up with.
    before_index = (fit_index - 1) if fit_index is not None else (valid_indexes[-1] if valid_indexes else None)
    final_index = valid_indexes[-1] if valid_indexes else len(attempts) - 1
    before = attempts[before_index] if before_index is not None else None
    final = attempts[final_index]

    fit_status = "not checked"
    if before is not None:
        if fit_index is None:
            fit_status = "fits first time" if worst(before) <= FIT_LIMIT_PT else "overflows, no repair run"
        elif final_index < fit_index:
            fit_status = "fit repair broke the look, previous look kept"
        elif worst(final) <= FIT_LIMIT_PT:
            fit_status = "fit repaired"
        else:
            fit_status = "still overflows after fit repair"

    allowed = set(WIDGETS[job["widget"]]["actions"])
    ok = [r for r in final["renders"].values() if r.get("ok")]
    used = sorted({a["action"] for r in ok for a in r.get("actions", [])})
    look_text = (ROOT / final["look"]).read_text()
    diffs = {}
    if final["valid"]:
        for family in SIZES:
            diffs[family] = round1.diff_share(final["renders"][f"a-{family}"]["png"], final["renders"][f"b-{family}"]["png"])
    return {
        "id": cell_id,
        "group": job["group"],
        "job_id": job["id"],
        "widget": job["widget"],
        "user_words": job["text"],
        "reference_image": job["image"],
        "model": model,
        "model_ids": final["models"],
        "valid_first_try": attempts[0]["valid"],
        "valid_final": final["valid"],
        "validity_repair_used": any(a["kind"] == "validity repair" for a in attempts),
        "fit_repair_used": fit_index is not None,
        "validity_status": "first try" if attempts[0]["valid"] else ("repaired" if first_valid is not None else "failed"),
        "fit_status": fit_status,
        "errors": [{"attempt": i + 1, "kind": a["kind"], **a["first_error"]} for i, a in enumerate(attempts) if a["first_error"]],
        "before_attempt": before_index + 1 if before_index is not None else None,
        "final_attempt": final_index + 1,
        "overflow_before_pt": before["overflow_pt"] if before else {},
        "overflow_after_pt": final["overflow_pt"] if final["valid"] else {},
        "truncated_before": before["truncated_texts"] if before else {},
        "truncated_after": final["truncated_texts"] if final["valid"] else {},
        "assets_used": sorted({a for r in ok for a in r.get("assets_used", [])}),
        "assets_used_by_render": {k: r.get("assets_used", []) for k, r in final["renders"].items() if r.get("ok")},
        "look_mentions_reference_asset": bool(re.search(r"""asset\s*:\s*['"]reference['"]""", look_text)),
        "fonts_used": sorted({f for r in ok for f in r.get("fonts_used", [])}),
        "state_diff_share": diffs,
        "actions_used": used,
        "actions_unknown": sorted(set(used) - allowed),
        "actions_missing": sorted(allowed - set(used)),
        "output_bytes": final["bytes"],
        "gen_seconds_total": round(sum(a["gen_seconds"] for a in attempts), 2),
        "model_calls": len(attempts),
        "attempts": attempts,
    }


def run_cell(job, model, empty_dir, force):
    cell_id = f"{job['id']}__J-{model}"
    cell_dir = RUNS / cell_id
    cached = cell_dir / "cell.json"
    if cached.exists() and not force:
        return json.loads(cached.read_text())
    cell_dir.mkdir(parents=True, exist_ok=True)
    attempts = []
    validity_repairs = 0

    def attempt(kind, request):
        a, look = run_attempt(job, model, cell_dir, len(attempts) + 1, kind, request, empty_dir)
        attempts.append(a)
        return a, look

    def repair_validity(a, look):
        nonlocal validity_repairs
        validity_repairs += 1
        e = a["first_error"]
        return attempt("validity repair", build_validity_repair(job, look, e["error"], e["state"], e["family"]))

    current, look = attempt("first", build_prompt(job))
    if not current["valid"]:
        current, look = repair_validity(current, look)
    if current["valid"] and worst(current) > FIT_LIMIT_PT:
        current, look = attempt("fit repair", build_fit_repair(job, look, current["renders"]))
        if not current["valid"] and validity_repairs == 0:
            repair_validity(current, look)

    cell = assemble(job, model, attempts)
    cached.write_text(json.dumps(cell, indent=2))
    print(f"{cell_id}: validity {cell['validity_status']}, fit {cell['fit_status']}, {cell['model_calls']} calls, "
          f"before {max(cell['overflow_before_pt'].values(), default='-')} after {max(cell['overflow_after_pt'].values(), default='-')}"
          + "".join(f"\n    attempt {e['attempt']} error: {e['error']}" for e in cell["errors"]), flush=True)
    return cell


def rerender_cell(job, model):
    cached = RUNS / f"{job['id']}__J-{model}" / "cell.json"
    attempts = json.loads(cached.read_text())["attempts"]
    for a in attempts:
        look_path = ROOT / a["look"]
        a["renders"], a["first_error"] = render_all(job, look_path, look_path.parent)
        a["valid"] = a["first_error"] is None
        a.update(measure(a["renders"]))
    cell = assemble(job, model, attempts)
    cached.write_text(json.dumps(cell, indent=2))
    return cell


def sanity(empty_dir):
    """Ask each model to describe each reference, to prove the image reaches it."""
    out_dir = RUNS / "_sanity"
    out_dir.mkdir(parents=True, exist_ok=True)
    question = "Describe this image in two sentences. Then list every piece of text you can read in it, exactly as written. If there is no text, say so."
    rows = []

    def one(ref, model):
        reply = call_model(model, question, ref["image"], empty_dir, system_prompt="You describe images accurately and briefly.")
        path = out_dir / f"{ref['id']}__{model}.txt"
        path.write_text(reply["text"])
        return {"reference": ref["id"], "image": ref["image"], "model": model, "model_ids": reply["models"], "num_turns": reply["num_turns"],
                "reply_file": str(path.relative_to(ROOT)), "reply": reply["text"]}

    with ThreadPoolExecutor(max_workers=6) as pool:
        futures = [pool.submit(one, ref, model) for ref in REFERENCES for model in MODELS]
        rows = [f.result() for f in futures]
    (out_dir / "sanity.json").write_text(json.dumps({"question": question, "calls": rows}, indent=2))
    for r in rows:
        print(f"--- {r['reference']} {r['model']}\n{r['reply']}\n", flush=True)


def fonts():
    out_dir = RUNS / "_fonts"
    out_dir.mkdir(parents=True, exist_ok=True)
    proc = subprocess.run([str(RENDER), "fonts", str(out_dir / "specimen.png")], capture_output=True, text=True, check=True)
    report = json.loads(proc.stdout)
    report["png"] = str((out_dir / "specimen.png").relative_to(ROOT))
    return report


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--rerender", action="store_true", help="re-render and re-measure saved looks, no model calls")
    ap.add_argument("--sanity", action="store_true", help="only run the image sanity calls")
    args = ap.parse_args()
    if not RENDER.exists():
        sys.exit("build first: swift build -c release --build-system native")
    RUNS.mkdir(exist_ok=True)
    empty_dir = tempfile.mkdtemp(prefix="look-gen-")
    assert not os.listdir(empty_dir), "the model working directory must be empty"
    if args.sanity:
        sanity(empty_dir)
        return

    jobs = [(j, m) for j in JOBS for m in MODELS if args.only in f"{j['id']}__J-{m}"]
    if args.rerender:
        for j, m in jobs:
            if (RUNS / f"{j['id']}__J-{m}" / "cell.json").exists():
                rerender_cell(j, m)
    else:
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [pool.submit(run_cell, j, m, empty_dir, args.force) for j, m in jobs]
            failures = []
            for (j, m), f in zip(jobs, futures):
                try:
                    f.result()
                except Exception as e:
                    failures.append(f"{j['id']}__J-{m}: {e}")
            for line in failures:
                print("CELL DID NOT RUN:", line, flush=True)

    cells = []
    for j in JOBS:
        for m in MODELS:
            path = RUNS / f"{j['id']}__J-{m}" / "cell.json"
            if path.exists():
                cells.append(json.loads(path.read_text()))
    old = {c["id"]: c for c in json.loads((ROOT / "results.json").read_text())["cells"]}
    for c in cells:
        prior = old.get(c["id"])
        c["round1_overflow_pt"] = prior["overflow_pt"] if prior else None
    sanity_path = RUNS / "_sanity" / "sanity.json"
    results = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "fit_limit_pt": FIT_LIMIT_PT,
        "models": MODELS,
        "sizes": SIZES,
        "prompts": [{**p, "states": WIDGETS[p["widget"]]["states"]} for p in round1.PROMPTS],
        "references": [{**r, "states": WIDGETS[r["widget"]]["states"], "pixels": list(image_size(ROOT / r["image"]))} for r in REFERENCES],
        "user_words": USER_WORDS,
        "cells_expected": len(JOBS) * len(MODELS),
        "cells": cells,
        "fonts": fonts(),
        "image_sanity": json.loads(sanity_path.read_text()) if sanity_path.exists() else None,
    }
    RESULTS.write_text(json.dumps(results, indent=2))
    print(f"wrote {RESULTS.name} with {len(cells)} of {results['cells_expected']} cells")


if __name__ == "__main__":
    main()
