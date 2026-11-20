#!/usr/bin/env python3
"""Sequential timing and memory pass over every valid look, variants interleaved.

Each run is a fresh process (the closest stand-in here for a widget extension launch) rendering
state a in the small family. Writes the "perf" section of results.json.
"""
import json
import os
import statistics
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RENDER = ROOT / ".build/release/render"
ROUNDS = int(sys.argv[1]) if len(sys.argv) > 1 else 7
WARM_RUNS = 20
KEYS = ["tree_ms", "render_ms", "peak_rss_mb", "footprint_mb", "tree_footprint_mb", "js_setup_ms", "js_eval_ms",
        "tree_ms_warm_median", "tree_footprint_mb_after_warm", "process_ms"]

results = json.loads((ROOT / "results.json").read_text())
tmp = ROOT / "runs" / "_measure"
tmp.mkdir(parents=True, exist_ok=True)

baseline_dir = ROOT / "runs" / "_baseline"
baseline_dir.mkdir(parents=True, exist_ok=True)
(baseline_dir / "one-text.json").write_text('{ "type": "text", "value": "{{ data.todayCount }}" }\n')
(baseline_dir / "one-text.js").write_text('function render(ctx) { return { type: "text", value: ctx.data.todayCount }; }\n')

targets = []
for c in results["cells"]:
    if c["valid_after_repair"]:
        targets.append({
            "id": c["id"], "variant": c["variant"], "model": c["model"],
            "look": c["attempts"][-1]["look"], "fixture": f"fixtures/{c['widget']}-a.json",
        })
targets.append({"id": "baseline one text node T", "variant": "template", "model": None,
                "look": "runs/_baseline/one-text.json", "fixture": "fixtures/water-a.json"})
targets.append({"id": "baseline one text node J", "variant": "js", "model": None,
                "look": "runs/_baseline/one-text.js", "fixture": "fixtures/water-a.json"})

# Interleave so each round alternates template and JS runs.
t_side = [t for t in targets if t["variant"] == "template"]
j_side = [t for t in targets if t["variant"] == "js"]
order = [x for pair in zip(t_side, j_side) for x in pair] + t_side[len(j_side):] + j_side[len(t_side):]

load_before = os.getloadavg()
samples = {t["id"]: {k: [] for k in KEYS} for t in targets}
errors = 0
COLD_KEYS = ["tree_ms", "render_ms", "peak_rss_mb", "footprint_mb", "tree_footprint_mb", "js_setup_ms", "js_eval_ms", "process_ms"]
WARM_KEYS = ["tree_ms_warm_median", "tree_footprint_mb_after_warm"]
cold_env = {k: v for k, v in os.environ.items() if k != "LOOK_WARM_RUNS"}
warm_env = dict(cold_env, LOOK_WARM_RUNS=str(WARM_RUNS))


def run_once(t, env):
    global errors
    t0 = time.perf_counter()
    proc = subprocess.run(
        [str(RENDER), t["variant"], str(ROOT / t["look"]), str(ROOT / t["fixture"]), "small", str(tmp / "out.png")],
        capture_output=True, text=True, env=env,
    )
    wall = (time.perf_counter() - t0) * 1000
    if proc.returncode != 0:
        errors += 1
        return None
    stats = json.loads(proc.stdout)
    assert stats["nodes"] > 0 and stats["pixel_width"] == 474
    stats["process_ms"] = wall
    return stats


for rnd in range(ROUNDS + 1):
    for t in order:
        # A fresh process with one evaluation gives the cold numbers. A second process repeats the
        # evaluation in place for the warm numbers, so the repeats never inflate the cold ones.
        cold = run_once(t, cold_env)
        warm = run_once(t, warm_env)
        if rnd == 0:
            continue  # the first round only warms the disk cache
        for stats, keys in ((cold, COLD_KEYS), (warm, WARM_KEYS)):
            if stats:
                for k in keys:
                    if k in stats:
                        samples[t["id"]][k].append(stats[k])
load_after = os.getloadavg()


def summarize(values):
    if not values:
        return None
    return {"median": round(statistics.median(values), 3), "min": round(min(values), 3), "max": round(max(values), 3), "n": len(values)}


per_look = []
for t in targets:
    row = {"id": t["id"], "variant": t["variant"], "model": t["model"]}
    for k in KEYS:
        row[k] = summarize(samples[t["id"]][k])
    per_look.append(row)


def across(variant, key, baseline=False):
    meds = [r[key]["median"] for r in per_look
            if r["variant"] == variant and r[key] and (r["id"].startswith("baseline") == baseline)]
    if not meds:
        return None
    return {"median_of_look_medians": round(statistics.median(meds), 3), "min": round(min(meds), 3), "max": round(max(meds), 3), "looks": len(meds)}


perf = {
    "measured_on": "macOS, release build, fresh process per run, state a, small family",
    "rounds_per_look": ROUNDS,
    "warm_runs_in_process": WARM_RUNS,
    "render_errors_during_measurement": errors,
    "load_average_before": [round(x, 2) for x in load_before],
    "load_average_after": [round(x, 2) for x in load_after],
    "by_variant": {
        v: {k: across(v, k) for k in KEYS} for v in ("template", "js")
    },
    "baseline_one_text_node": {
        v: {k: across(v, k, baseline=True) for k in KEYS} for v in ("template", "js")
    },
    "per_look": per_look,
}
results["perf"] = perf
(ROOT / "results.json").write_text(json.dumps(results, indent=2))

print(f"rounds {ROUNDS}, errors {errors}, load before {perf['load_average_before']} after {perf['load_average_after']}")
for v in ("template", "js"):
    print(v)
    for k in KEYS:
        a = perf["by_variant"][v][k]
        b = perf["baseline_one_text_node"][v][k]
        if a:
            print(f"  {k}: median of look medians {a['median_of_look_medians']} (range {a['min']} to {a['max']}, {a['looks']} looks)"
                  + (f"; one-text baseline {b['median_of_look_medians']}" if b else ""))
