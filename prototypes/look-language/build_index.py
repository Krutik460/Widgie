#!/usr/bin/env python3
"""Build the static contact sheet index.html from results.json."""
import html
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
REP = int(sys.argv[1]) if len(sys.argv) > 1 else 1
SUFFIX = "" if REP == 1 else f"-rep{REP}"
results = json.loads((ROOT / f"results{SUFFIX}.json").read_text())
cells = {c["id"]: c for c in results["cells"]}
columns = [("template", "haiku"), ("template", "sonnet"), ("js", "haiku"), ("js", "sonnet")]
short = results["variants"]
sizes = {"small": (158, 158), "medium": (338, 158)}


def esc(s):
    return html.escape(str(s), quote=True)


def image(cell, attempt, state, family, label):
    r = attempt["renders"].get(f"{state}-{family}", {})
    w, h = sizes[family]
    if r.get("ok"):
        body = f'<img src="{esc(r["png"])}" width="{w}" height="{h}" alt="{esc(label)}">'
    else:
        body = f'<div class="missing" style="width:{w}px;height:{h}px">{esc(r.get("error", "not rendered"))}</div>'
    return f'<figure>{body}<figcaption>{esc(label)}</figcaption></figure>'


def cell_html(prompt, variant, model):
    cid = f"{prompt['id']}__{short[variant]}-{model}"
    c = cells.get(cid)
    if c is None:
        return '<td class="cell"><span class="badge failed">not run</span></td>'
    final = c["attempts"][-1]
    states = prompt["states"]
    kind = {"first try": "first", "repaired": "repaired", "failed": "failed"}[c["status"]]
    meta = [f"{c['output_bytes']} bytes", f"{c['gen_seconds']} s to generate"]
    if c["repair_gen_seconds"] is not None:
        meta.append(f"{c['repair_gen_seconds']} s to repair")
    links = [f'<a href="{esc(final["look"])}">look source</a>', f'<a href="{esc(final["reply"])}">raw reply</a>']
    if len(c["attempts"]) > 1:
        links.append(f'<a href="{esc(c["attempts"][0]["look"])}">first attempt</a>')
    notes = []
    if c["error_first_try"]:
        notes.append(f'<p class="error"><b>First try error.</b> {esc(c["error_first_try"])}</p>')
    if c["error_after_repair"]:
        notes.append(f'<p class="error"><b>After repair.</b> {esc(c["error_after_repair"])}</p>')
    if c["actions_unknown"]:
        notes.append(f'<p class="error">Unknown action ids: {esc(", ".join(c["actions_unknown"]))}</p>')
    if c["actions_missing"]:
        notes.append(f'<p class="note">Actions with no button: {esc(", ".join(c["actions_missing"]))}</p>')
    over = {k: v for k, v in c.get("overflow_pt", {}).items() if v > 0}
    if over:
        worst = max(over.values())
        where = ", ".join(sorted({k.split("-")[1] for k in over}))
        notes.append(f'<p class="note">Content is up to {worst} pt larger than the widget and gets clipped ({esc(where)}).</p>')
    images = (
        '<div class="pair">'
        + image(c, final, "a", "small", f"small, {states['a']}")
        + image(c, final, "b", "small", f"small, {states['b']}")
        + "</div>"
        + image(c, final, "a", "medium", f"medium, {states['a']}")
        + image(c, final, "b", "medium", f"medium, {states['b']}")
    )
    return (
        f'<td class="cell"><div class="info"><div class="head"><span class="badge {kind}">{esc(c["status"])}</span>'
        f'<span class="meta">{esc(" · ".join(meta))}</span></div>'
        f'<div class="links">{" ".join(links)}</div>{"".join(notes)}</div>{images}</td>'
    )


rows = []
for i, p in enumerate(results["prompts"], 1):
    tds = "".join(cell_html(p, v, m) for v, m in columns)
    rows.append(
        f'<tr class="prompt"><th colspan="4"><span class="widget">Prompt {i}, {esc(p["widget"])} widget</span>'
        f'<span class="quote">{esc(p["text"])}</span></th></tr><tr class="cells">{tds}</tr>'
    )

valid_first = sum(1 for c in results["cells"] if c["valid_first_try"])
valid_final = sum(1 for c in results["cells"] if c["valid_after_repair"])
summary = (
    f"{len(results['cells'])} of {results['cells_expected']} cells run. "
    f"{valid_first} valid on the first try, {valid_final} valid after at most one repair. "
    f"Generated {esc(results['generated_at'])}. Images are shown at point size (small 158 x 158, medium 338 x 158), rendered at 3x on macOS."
)

page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Look language contact sheet</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin: 0; padding: 24px; background: #17181a; color: #e4e5e7; font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }}
  h1 {{ font-size: 20px; margin: 0 0 6px; font-weight: 600; }}
  p.summary {{ margin: 0 0 10px; color: #a2a5ab; max-width: 900px; }}
  p.summary a {{ color: #8ab4f8; margin-right: 8px; }}
  table {{ border-collapse: collapse; }}
  thead th {{ position: sticky; top: 0; background: #17181a; text-align: left; padding: 10px 8px; font-size: 14px; font-weight: 600; border-bottom: 1px solid #34363b; z-index: 1; }}
  thead th small {{ display: block; color: #a2a5ab; font-weight: 400; font-size: 12px; }}
  tr.cells {{ border-bottom: 1px solid #2a2c30; }}
  tr.prompt th {{ text-align: left; padding: 22px 8px 2px; font-weight: 400; }}
  tr.prompt .widget {{ color: #a2a5ab; font-size: 12px; margin-right: 10px; }}
  tr.prompt .quote {{ font-size: 16px; font-weight: 600; }}
  td.cell {{ vertical-align: top; padding: 10px 8px 16px; width: 338px; min-width: 338px; }}
  .info {{ min-height: 118px; }}
  .head {{ display: flex; align-items: center; gap: 8px; }}
  .badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }}
  .badge.first {{ background: #1f4d33; color: #b6f0cd; }}
  .badge.repaired {{ background: #5a4514; color: #ffe1a1; }}
  .badge.failed {{ background: #5c2323; color: #ffc4c4; }}
  .meta {{ color: #a2a5ab; font-size: 12px; }}
  .links {{ margin: 6px 0 8px; font-size: 12px; }}
  .links a {{ color: #8ab4f8; margin-right: 10px; }}
  p.error, p.note {{ margin: 0 0 8px; font-size: 12px; color: #ffc4c4; overflow-wrap: anywhere; }}
  p.note {{ color: #ffe1a1; }}
  .pair {{ display: flex; gap: 12px; }}
  figure {{ margin: 0 0 10px; }}
  figure img {{ display: block; }}
  figcaption {{ color: #a2a5ab; font-size: 11px; margin-top: 3px; }}
  .missing {{ box-sizing: border-box; border: 1px dashed #5c2323; border-radius: 22px; color: #ffc4c4; font-size: 11px; padding: 14px; overflow: hidden; overflow-wrap: anywhere; }}
</style>
</head>
<body>
<h1>Look language contact sheet{" (replicate " + str(REP) + ")" if REP > 1 else ""}</h1>
<p class="summary">{summary}</p>
<p class="summary">Replicates of the same matrix: <a href="index.html">1</a> <a href="index-rep2.html">2</a> <a href="index-rep3.html">3</a></p>
<table>
<thead><tr>
<th>T-haiku<small>template, haiku</small></th>
<th>T-sonnet<small>template, sonnet</small></th>
<th>J-haiku<small>JavaScript, haiku</small></th>
<th>J-sonnet<small>JavaScript, sonnet</small></th></tr></thead>
<tbody>
{chr(10).join(rows)}
</tbody>
</table>
</body>
</html>
"""
assert chr(0x2014) not in page
(ROOT / f"index{SUFFIX}.html").write_text(page)
print(f"wrote index{SUFFIX}.html: {len(results['cells'])} cells")
