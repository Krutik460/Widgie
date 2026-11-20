#!/usr/bin/env python3
"""Aggregate first-try validity across the replicate runs and store it in results.json."""
import json
import statistics
from pathlib import Path

ROOT = Path(__file__).resolve().parent
files = ["results.json", "results-rep2.json", "results-rep3.json"]
groups = {}
failures = []
for rep, name in enumerate(files, 1):
    path = ROOT / name
    if not path.exists():
        continue
    for c in json.loads(path.read_text())["cells"]:
        g = groups.setdefault(f"{c['variant']} {c['model']}", {
            "cells": 0, "valid_first_try": 0, "valid_after_repair": 0, "overflow_over_8pt": 0,
            "actions_missing": 0, "bytes": [], "gen_seconds": [], "thinking_tokens": 0})
        g["cells"] += 1
        g["valid_first_try"] += c["valid_first_try"]
        g["valid_after_repair"] += c["valid_after_repair"]
        g["overflow_over_8pt"] += bool(c["overflow_pt"]) and max(c["overflow_pt"].values()) > 8
        g["actions_missing"] += bool(c["actions_missing"])
        g["bytes"].append(c["output_bytes"])
        g["gen_seconds"].append(c["gen_seconds"])
        g["thinking_tokens"] += c["attempts"][0]["thinking_tokens"] or 0
        if not c["valid_first_try"]:
            failures.append({"replicate": rep, "cell": c["id"], "status": c["status"],
                             "error_first_try": c["error_first_try"], "error_after_repair": c["error_after_repair"]})
for g in groups.values():
    g["median_bytes"] = statistics.median(g.pop("bytes"))
    g["median_gen_seconds"] = statistics.median(g.pop("gen_seconds"))

main = ROOT / "results.json"
results = json.loads(main.read_text())
results["replicates"] = {"files": files, "by_variant_and_model": groups, "first_try_failures": failures}
main.write_text(json.dumps(results, indent=2))
for k, g in groups.items():
    print(k, g)
for f in failures:
    print(f)
