#!/usr/bin/env python3
"""Writes index.html into a run folder: one row per case, one column per model, with the final renders of one
sample and of the full state in both sizes, the build's status, and every verdict line. Paths are relative, so
the folder can be moved or zipped whole.

    sheet.py <run dir>
"""

import html
import json
import os
import sys
from collections import Counter
from pathlib import Path

EVALS = Path(__file__).resolve().parent
STATUSES = ["first try", "repaired once", "repaired twice", "failed"]
STATUS_CLASS = {"first try": "first", "repaired once": "once", "repaired twice": "twice", "failed": "failed"}

STYLE = """
:root {
  color-scheme: dark;
  --bg: #131417; --panel: #1b1d21; --line: #2a2d33; --text: #e6e7ea; --muted: #979ba3;
  --first: #6fcf8e; --once: #a9c96a; --twice: #e2b45a; --failed: #ef6f6c;
}
* { box-sizing: border-box; }
body {
  margin: 0; padding: 24px 16px 64px; background: var(--bg); color: var(--text);
  font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", system-ui, sans-serif;
}
main { max-width: 1400px; margin: 0 auto; }
h1 { font-size: 22px; margin: 0 0 4px; }
h2 { font-size: 17px; margin: 40px 0 0; padding-bottom: 8px; border-bottom: 1px solid var(--line); }
p.meta { color: var(--muted); margin: 0 0 20px; }
table.summary { border-collapse: collapse; margin: 8px 0 8px; }
table.summary th, table.summary td { padding: 4px 12px; text-align: right; border-bottom: 1px solid var(--line); }
table.summary th:first-child, table.summary td:first-child { text-align: left; }
table.summary thead th { color: var(--muted); font-weight: 500; }
.row { display: grid; gap: 20px; padding: 20px 0; border-bottom: 1px solid var(--line); }
.case .id { font-weight: 600; }
.case .request { color: var(--muted); margin-top: 4px; }
.case img { display: block; width: 100%; margin-top: 10px; border-radius: 6px; }
.build { background: var(--panel); border-radius: 8px; padding: 12px; min-width: 0; }
.head { display: flex; justify-content: space-between; gap: 12px; align-items: baseline; }
.model { font-weight: 600; }
.status { font-weight: 600; }
.status.first { color: var(--first); } .status.once { color: var(--once); }
.status.twice { color: var(--twice); } .status.failed { color: var(--failed); } .status.none { color: var(--muted); }
.stats { color: var(--muted); font-size: 12px; margin: 2px 0 10px; }
.state { color: var(--muted); font-size: 12px; margin: 8px 0 4px; }
.pair { display: grid; grid-template-columns: 158fr 338fr; gap: 8px; align-items: start; }
.pair img { display: block; width: 100%; }
.pair .missing { aspect-ratio: 1; display: grid; place-items: center; color: var(--muted); font-size: 12px;
  border: 1px dashed var(--line); border-radius: 12px; }
.pair .missing.wide { aspect-ratio: 338 / 158; }
ol.verdicts { margin: 10px 0 0; padding-left: 18px; font-size: 12px; color: var(--muted); }
ol.verdicts li { margin-top: 4px; overflow-wrap: anywhere; }
@media (max-width: 900px) { .row { grid-template-columns: 1fr !important; } }
"""


def write(run_dir: Path) -> Path:
    config = json.loads((EVALS / "cases.json").read_text())
    builds = {}
    for path in run_dir.glob("*/*/build.json"):
        build = json.loads(path.read_text())
        builds[(build["case"], build["model"])] = build
    models = sorted({model for _, model in builds} | {p.parent.name for p in run_dir.glob("*/*/1")})
    page = [
        "<!doctype html>",
        '<html lang="en"><head><meta charset="utf-8">',
        '<meta name="viewport" content="width=device-width, initial-scale=1">',
        f"<title>Widget evals {html.escape(run_dir.name)}</title>",
        f"<style>{STYLE}</style></head><body><main>",
        f"<h1>Widget evals, run {html.escape(run_dir.name)}</h1>",
        f'<p class="meta">{len(builds)} builds finished. Each build sends the request to the model, proves the '
        "reply with the engine, and sends the verdict line back at most twice.</p>",
        summary_table(config, builds, models),
    ]
    columns = f"minmax(180px, 260px) repeat({max(len(models), 1)}, minmax(0, 1fr))"
    for group in config["groups"]:
        page.append(f"<h2>{html.escape(group)}</h2>")
        for case in (c for c in config["cases"] if c["group"] == group):
            cells = [case_cell(case, run_dir)]
            cells += [build_cell(builds.get((case["id"], model)), model, run_dir / case["id"] / model, run_dir)
                      for model in models]
            page.append(f'<div class="row" style="grid-template-columns: {columns}">{"".join(cells)}</div>')
    page.append("</main></body></html>")
    out = run_dir / "index.html"
    out.write_text("\n".join(page) + "\n")
    return out


def summary_table(config: dict, builds: dict, models: list[str]) -> str:
    head = "".join(f"<th>{html.escape(m)}: {s}</th>" for m in models for s in STATUSES)
    rows = []
    for group in config["groups"] + ["all"]:
        cells = []
        for model in models:
            counts = Counter(b["status"] for (_, m), b in builds.items()
                             if m == model and (group == "all" or b["group"] == group))
            cells += [f"<td>{counts[s]}</td>" for s in STATUSES]
        rows.append(f"<tr><td>{html.escape(group)}</td>{''.join(cells)}</tr>")
    return f'<table class="summary"><thead><tr><th>group</th>{head}</tr></thead><tbody>{"".join(rows)}</tbody></table>'


def case_cell(case: dict, run_dir: Path) -> str:
    parts = [f'<div class="case"><div class="id">{html.escape(case["id"])}</div>',
             f'<div class="request">{html.escape(case["request"])}</div>']
    if case.get("image"):
        src = os.path.relpath(EVALS / case["image"], run_dir)
        parts.append(f'<a href="{html.escape(src)}"><img src="{html.escape(src)}" alt="the reference picture"></a>')
    parts.append("</div>")
    return "".join(parts)


def build_cell(build: dict | None, model: str, build_dir: Path, run_dir: Path) -> str:
    if build is None:
        return (f'<div class="build"><div class="head"><span class="model">{html.escape(model)}</span>'
                '<span class="status none">not finished</span></div></div>')
    report_path = run_dir / build["final_report"]
    renders = json.loads(report_path.read_text())["renders"] if report_path.exists() else []
    samples = [r["state"] for r in renders if r["state"] not in ("empty", "full")]
    shown = ([samples[-1]] if samples else []) + ["full"]
    stats = (f'{build["calls"]} {"call" if build["calls"] == 1 else "calls"}, {build["seconds"]:.0f} s, '
             f'{build["output_tokens"]:,} output tokens, {build["attempts"][-1]["document_bytes"]:,} bytes')
    parts = [
        '<div class="build"><div class="head">',
        f'<span class="model">{html.escape(model)}</span>',
        f'<span class="status {STATUS_CLASS[build["status"]]}">{html.escape(build["status"])}</span></div>',
        f'<div class="stats">{stats}</div>',
    ]
    for state in shown:
        label = "full" if state == "full" else f'sample "{state}"'
        parts.append(f'<div class="state">{html.escape(label)}</div><div class="pair">')
        for family in ("small", "medium"):
            render = next((r for r in renders if r["state"] == state and r["family"] == family), None)
            if render and render["png"]:
                src = os.path.relpath(report_path.parent / render["png"], run_dir)
                parts.append(f'<a href="{html.escape(src)}"><img src="{html.escape(src)}" alt="{family}"></a>')
            else:
                wide = " wide" if family == "medium" else ""
                parts.append(f'<div class="missing{wide}">no {family} render</div>')
        parts.append("</div>")
    if build["verdicts"]:
        items = "".join(f'<li>{html.escape(v)}</li>' for v in build["verdicts"])
        parts.append(f'<ol class="verdicts">{items}</ol>')
    parts.append("</div>")
    return "".join(parts)


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: sheet.py <run dir>")
    print(write(Path(sys.argv[1]).resolve()))
