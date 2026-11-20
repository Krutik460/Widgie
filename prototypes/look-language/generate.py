#!/usr/bin/env python3
"""Generate every look prompt x variant x model, render it, repair once on failure, write results.json.

Usage: generate.py [--only SUBSTRING] [--force] [--jobs N]
"""
import argparse
import json
import os
import re
import subprocess
import sys
import tempfile
import time
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RENDER = ROOT / ".build/release/render"
RUNS = ROOT / "runs"
FAMILIES = ["small", "medium"]
STATES = ["a", "b"]
MODELS = ["haiku", "sonnet"]
VARIANTS = {
    "template": {"short": "T", "ext": "json", "fence": "json", "ref": "lang-template.md"},
    "js": {"short": "J", "ext": "js", "fence": "js", "ref": "lang-js.md"},
}

SYSTEM_PROMPT = (
    "You write looks for home screen widgets in the look language described in the user's message. "
    "Reply with exactly one fenced code block that contains the complete look, and nothing else."
)

WIDGETS = {
    "water": {
        "schema": (
            "todayCount: number, glasses drunk today\n"
            "goal: number, the daily goal in glasses\n"
            "unit: string\n"
            "last7: list of 7 numbers, glasses per day for the last 7 days, oldest first, today last"
        ),
        "actions": {"addGlass": "logs one more glass", "undoLast": "removes the most recent glass"},
        "states": {"a": "2 of 8", "b": "7 of 8"},
    },
    "todo": {
        "schema": (
            "items: list of { id: string, title: string, done: boolean }\n"
            "doneCount: number of finished items\n"
            "total: number of items"
        ),
        "actions": {
            "toggleDone": "toggles one item; pass the item's id as rowId",
            "openAdd": "opens the app to add an item",
        },
        "states": {"a": "1 of 4 done", "b": "3 of 4 done"},
    },
    "habit": {
        "schema": (
            "name: string, the habit\n"
            "streak: number, the current streak in days\n"
            "doneToday: boolean\n"
            "days: list of exactly 35 { date: \"YYYY-MM-DD\", done: boolean }, oldest first, today last"
        ),
        "actions": {"toggleToday": "marks today done or not done"},
        "states": {"a": "streak 2", "b": "streak 21"},
    },
    "wotd": {
        "schema": (
            "word: string\n"
            "partOfSpeech: string\n"
            "definition: string\n"
            "example: string, a sentence that uses the word\n"
            "date: string, \"YYYY-MM-DD\""
        ),
        "actions": {},
        "states": {"a": "petrichor", "b": "sesquipedalian (long)"},
    },
}

PROMPTS = [
    {"id": "1-water-glass", "widget": "water", "data_driven": True,
     "text": "a glass that fills up with water as I drink, bubbly blue, with a big plus button"},
    {"id": "2-water-lcd", "widget": "water", "data_driven": True,
     "text": "retro LCD digital watch look, grey-green screen, segmented progress bar with one segment per glass"},
    {"id": "3-habit-heatmap", "widget": "habit", "data_driven": True,
     "text": "a heatmap of the last 5 weeks like a code contribution graph, neon green on black"},
    {"id": "4-habit-ring", "widget": "habit", "data_driven": True,
     "text": "a ring that goes from red to green as my streak grows, with a flame in the middle and the streak number"},
    {"id": "5-todo-sticky", "widget": "todo", "data_driven": False,
     "text": "a yellow sticky note, slightly tilted, handwriting feel, finished items crossed out and faded"},
    {"id": "6-wotd-magazine", "widget": "wotd", "data_driven": False,
     "text": "elegant magazine typography, serif, a giant first letter, cream and deep red"},
]


def fixture_path(widget, state):
    return ROOT / "fixtures" / f"{widget}-{state}.json"


def build_prompt(prompt, variant):
    v = VARIANTS[variant]
    w = WIDGETS[prompt["widget"]]
    reference = (ROOT / v["ref"]).read_text().strip()
    sample = fixture_path(prompt["widget"], "a").read_text().strip()
    if w["actions"]:
        actions = "\n".join(f"- `{k}`: {d}" for k, d in w["actions"].items())
        actions += "\n\nUse these ids as the `action` of `button` nodes. No other action ids exist."
    else:
        actions = "This widget has no actions. Do not use `button`."
    return (
        f"{reference}\n\n---\n\n# Your task\n\n"
        f"Write the look for this widget.\n\n"
        f"## Data\n\nThe widget's data has these fields:\n\n```\n{w['schema']}\n```\n\n"
        f"One sample of the data. The values change over time, and the look must work for any values:\n\n"
        f"```json\n{sample}\n```\n\n"
        f"## Actions\n\n{actions}\n\n"
        f"## Sizes\n\nThe same look is drawn in both families: small (158 x 158 points) and medium (338 x 158 points). "
        f"It must look right in both.\n\n"
        f"## The look the user asked for\n\n\"{prompt['text']}\"\n\n"
        f"Reply with the look only, as one fenced ```{v['fence']} code block. No explanation before or after."
    )


def build_repair_prompt(prompt, variant, look, error, state, family):
    v = VARIANTS[variant]
    where = f"The error came up while drawing the {family} family"
    if state != "a":
        data = json.dumps(json.loads(fixture_path(prompt["widget"], state).read_text()), separators=(",", ":"))
        where += f" with this data:\n\n```json\n{data}\n```"
    else:
        where += " with the sample data above."
    return (
        build_prompt(prompt, variant)
        + f"\n\n---\n\n# Your previous attempt\n\n```{v['fence']}\n{look}\n```\n\n"
        f"# It failed with this error\n\n```\n{error}\n```\n\n{where}\n\n"
        f"Reply with the complete corrected look only, as one fenced ```{v['fence']} code block. No explanation before or after."
    )


def call_model(model, prompt, empty_dir):
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    cmd = [
        "claude", "-p", "--model", model, "--safe-mode", "--system-prompt", SYSTEM_PROMPT,
        "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
        "--output-format", "json",
    ]
    last = None
    for attempt in range(3):
        t0 = time.time()
        proc = subprocess.run(cmd, input=prompt, capture_output=True, text=True, cwd=empty_dir, env=env, timeout=600)
        seconds = time.time() - t0
        try:
            out = json.loads(proc.stdout)
            if not out.get("is_error") and isinstance(out.get("result"), str) and out["result"].strip():
                usage = out.get("usage", {})
                return {
                    "text": out["result"],
                    "seconds": round(seconds, 2),
                    "api_seconds": round(out.get("duration_api_ms", 0) / 1000, 2),
                    "output_tokens": usage.get("output_tokens"),
                    "thinking_tokens": (usage.get("output_tokens_details") or {}).get("thinking_tokens"),
                    "input_tokens": (usage.get("input_tokens") or 0) + (usage.get("cache_creation_input_tokens") or 0)
                    + (usage.get("cache_read_input_tokens") or 0),
                    "models": sorted((out.get("modelUsage") or {}).keys()),
                    "transport_retries": attempt,
                }
            last = f"is_error result: {proc.stdout[:400]}"
        except json.JSONDecodeError:
            last = f"exit {proc.returncode}: {proc.stdout[:300]} {proc.stderr[:300]}"
        time.sleep(3)
    raise RuntimeError(f"model call failed three times: {last}")


def extract_look(reply):
    blocks = re.findall(r"```[A-Za-z0-9_-]*[ \t]*\n(.*?)```", reply, flags=re.DOTALL)
    if not blocks:
        return reply.strip() + "\n", {"fenced": False, "blocks": 0, "chars_outside_fence": 0}
    look = max(blocks, key=len)
    outside = len(re.sub(r"```[A-Za-z0-9_-]*[ \t]*\n.*?```", "", reply, flags=re.DOTALL).strip())
    return look.rstrip() + "\n", {"fenced": True, "blocks": len(blocks), "chars_outside_fence": outside}


def render_all(prompt, variant, look_path, out_dir):
    """Render both states in both families. Returns (renders, first_error)."""
    renders = {}
    first_error = None
    for state in STATES:
        for family in FAMILIES:
            png = out_dir / f"{state}-{family}.png"
            if png.exists():
                png.unlink()
            proc = subprocess.run(
                [str(RENDER), variant, str(look_path), str(fixture_path(prompt["widget"], state)), family, str(png)],
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


def diff_share(a, b):
    proc = subprocess.run([str(RENDER), "diff", str(ROOT / a), str(ROOT / b)], capture_output=True, text=True)
    return json.loads(proc.stdout)["diff_share"] if proc.returncode == 0 else None


def run_attempt(prompt, variant, model, cell_dir, number, request, empty_dir):
    v = VARIANTS[variant]
    try_dir = cell_dir / f"try{number}"
    try_dir.mkdir(parents=True, exist_ok=True)
    (try_dir / "request.md").write_text(request)
    reply = call_model(model, request, empty_dir)
    (try_dir / "reply.txt").write_text(reply["text"])
    look, fence = extract_look(reply["text"])
    look_path = try_dir / f"look.{v['ext']}"
    look_path.write_text(look)
    renders, first_error = render_all(prompt, variant, look_path, try_dir)
    return {
        "look": str(look_path.relative_to(ROOT)),
        "reply": str((try_dir / "reply.txt").relative_to(ROOT)),
        "bytes": len(look.encode()),
        "gen_seconds": reply["seconds"],
        "api_seconds": reply["api_seconds"],
        "output_tokens": reply["output_tokens"],
        "thinking_tokens": reply["thinking_tokens"],
        "input_tokens": reply["input_tokens"],
        "models": reply["models"],
        "transport_retries": reply["transport_retries"],
        "fence": fence,
        "valid": first_error is None,
        "first_error": first_error,
        "renders": renders,
    }, look


def assemble(prompt, variant, model, attempts):
    cell_id = f"{prompt['id']}__{VARIANTS[variant]['short']}-{model}"
    final = attempts[-1]
    allowed = set(WIDGETS[prompt["widget"]]["actions"])
    used = sorted({a["action"] for r in final["renders"].values() if r.get("ok") for a in r.get("actions", [])})
    ok = [r for r in final["renders"].values() if r.get("ok")]
    diffs = {}
    if final["valid"]:
        for family in FAMILIES:
            diffs[family] = diff_share(final["renders"][f"a-{family}"]["png"], final["renders"][f"b-{family}"]["png"])

    def median(key):
        vals = sorted(r[key] for r in ok if key in r)
        return round(vals[len(vals) // 2], 3) if vals else None

    cell = {
        "id": cell_id,
        "prompt_id": prompt["id"],
        "widget": prompt["widget"],
        "variant": variant,
        "model": model,
        "model_ids": final["models"],
        "valid_first_try": attempts[0]["valid"],
        "valid_after_repair": final["valid"],
        "status": "first try" if attempts[0]["valid"] else ("repaired" if final["valid"] else "failed"),
        "error_first_try": (attempts[0]["first_error"] or {}).get("error"),
        "error_after_repair": (attempts[1]["first_error"] or {}).get("error") if len(attempts) > 1 else None,
        "output_bytes": final["bytes"],
        "output_bytes_first_try": attempts[0]["bytes"],
        "gen_seconds": attempts[0]["gen_seconds"],
        "repair_gen_seconds": attempts[1]["gen_seconds"] if len(attempts) > 1 else None,
        "render_ms": median("render_ms"),
        "tree_ms": median("tree_ms"),
        "peak_rss_mb": median("peak_rss_mb"),
        "js_setup_ms": median("js_setup_ms"),
        "js_eval_ms": median("js_eval_ms"),
        "nodes": median("nodes"),
        "ink_share_min": round(min((r["ink_share"] for r in ok), default=0), 4),
        "overflow_pt": {
            k: max(r["content_width"] - (338 if k.endswith("medium") else 158), r["content_height"] - 158, 0)
            for k, r in final["renders"].items() if r.get("ok") and "content_width" in r
        },
        "state_diff_share": diffs,
        "actions_used": used,
        "actions_unknown": sorted(set(used) - allowed),
        "actions_missing": sorted(allowed - set(used)),
        "final_attempt": len(attempts),
        "attempts": attempts,
    }
    return cell


def rerender_cell(prompt, variant, model):
    """Re-render the saved looks of a finished cell without calling the model."""
    cell_id = f"{prompt['id']}__{VARIANTS[variant]['short']}-{model}"
    cached = RUNS / cell_id / "cell.json"
    attempts = json.loads(cached.read_text())["attempts"]
    for a in attempts:
        look_path = ROOT / a["look"]
        a["renders"], a["first_error"] = render_all(prompt, variant, look_path, look_path.parent)
        a["valid"] = a["first_error"] is None
    cell = assemble(prompt, variant, model, attempts)
    cached.write_text(json.dumps(cell, indent=2))
    return cell


def run_cell(prompt, variant, model, empty_dir, force):
    cell_id = f"{prompt['id']}__{VARIANTS[variant]['short']}-{model}"
    cell_dir = RUNS / cell_id
    cached = cell_dir / "cell.json"
    if cached.exists() and not force:
        return json.loads(cached.read_text())
    cell_dir.mkdir(parents=True, exist_ok=True)
    attempts = []
    first, look = run_attempt(prompt, variant, model, cell_dir, 1, build_prompt(prompt, variant), empty_dir)
    attempts.append(first)
    if not first["valid"]:
        e = first["first_error"]
        request = build_repair_prompt(prompt, variant, look, e["error"], e["state"], e["family"])
        second, _ = run_attempt(prompt, variant, model, cell_dir, 2, request, empty_dir)
        attempts.append(second)

    cell = assemble(prompt, variant, model, attempts)
    cached.write_text(json.dumps(cell, indent=2))
    print(f"{cell_id}: {cell['status']}  {cell['output_bytes']} bytes  {cell['gen_seconds']} s"
          + (f"  first error: {cell['error_first_try']}" if cell["error_first_try"] else ""), flush=True)
    return cell


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default="")
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--empty-dir", default="")
    ap.add_argument("--rerender", action="store_true", help="re-render saved looks, no model calls")
    ap.add_argument("--rep", type=int, default=1, help="replicate number; 2 and up write to runs-repN and results-repN.json")
    args = ap.parse_args()
    global RUNS
    results_path = ROOT / "results.json"
    if args.rep > 1:
        RUNS = ROOT / f"runs-rep{args.rep}"
        results_path = ROOT / f"results-rep{args.rep}.json"
    if not RENDER.exists():
        sys.exit("build first: swift build -c release --build-system native")
    empty_dir = args.empty_dir or tempfile.mkdtemp(prefix="look-gen-")
    assert not os.listdir(empty_dir), "the model working directory must be empty"

    jobs = [(p, v, m) for p in PROMPTS for v in VARIANTS for m in MODELS]
    jobs = [j for j in jobs if args.only in f"{j[0]['id']}__{VARIANTS[j[1]]['short']}-{j[2]}"]
    if args.rerender:
        for p, v, m in jobs:
            rerender_cell(p, v, m)
    else:
        with ThreadPoolExecutor(max_workers=args.jobs) as pool:
            futures = [pool.submit(run_cell, p, v, m, empty_dir, args.force) for p, v, m in jobs]
            for f in futures:
                f.result()

    cells = []
    for p in PROMPTS:
        for v in VARIANTS:
            for m in MODELS:
                path = RUNS / f"{p['id']}__{VARIANTS[v]['short']}-{m}" / "cell.json"
                if path.exists():
                    cells.append(json.loads(path.read_text()))
    results = {
        "generated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "prompts": [{**p, "states": WIDGETS[p["widget"]]["states"]} for p in PROMPTS],
        "variants": {k: v["short"] for k, v in VARIANTS.items()},
        "models": MODELS,
        "cells_expected": len(PROMPTS) * len(VARIANTS) * len(MODELS),
        "cells": cells,
    }
    previous = results_path
    if previous.exists():
        old = json.loads(previous.read_text())
        for key in ("perf", "replicates"):
            if key in old:
                results[key] = old[key]
    previous.write_text(json.dumps(results, indent=2))
    print(f"wrote {results_path.name} with {len(cells)} of {results['cells_expected']} cells")


if __name__ == "__main__":
    main()
