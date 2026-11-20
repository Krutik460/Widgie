#!/usr/bin/env python3
"""Build the static contact sheet index-round2.html from results-round2.json."""
import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
results = json.loads((ROOT / "results-round2.json").read_text())
cells = {c["id"]: c for c in results["cells"]}
models = results["models"]
sizes = {k: tuple(v) for k, v in results["sizes"].items()}
limit = results["fit_limit_pt"]
KEYS = ["a-small", "b-small", "a-medium", "b-medium"]


def esc(s):
    return html.escape(str(s), quote=True)


def num(x):
    return f"{x:.1f}".rstrip("0").rstrip(".")


def figure(attempt, key, label):
    state, family = key.split("-")
    r = attempt["renders"].get(key, {})
    w, h = sizes[family]
    if r.get("ok"):
        over = attempt["overflow_pt"][key]
        cut = attempt["truncated_texts"][key]
        tags = [f'<span class="{"bad" if over > limit else "good"}">overflow {num(over)} pt</span>']
        if cut:
            tags.append(f'<span class="warn">{cut} text{"s" if cut != 1 else ""} cut with an ellipsis</span>')
        body = f'<img src="{esc(r["png"])}" width="{w}" height="{h}" alt="{esc(label)}">'
        caption = f'{esc(label)}<br>{" · ".join(tags)}'
    else:
        body = f'<div class="missing" style="width:{w}px;height:{h}px">{esc(r.get("error", "not rendered"))}</div>'
        caption = esc(label)
    return f'<figure>{body}<figcaption>{caption}</figcaption></figure>'


def block(title, attempt, states):
    labels = {k: f"{k.split('-')[1]}, {states[k.split('-')[0]]}" for k in KEYS}
    return (
        f'<div class="block"><div class="blocktitle">{esc(title)} '
        f'<a href="{esc(attempt["look"])}">look</a> <a href="{esc(attempt["request"])}">request</a></div>'
        f'<div class="pair">{figure(attempt, "a-small", labels["a-small"])}{figure(attempt, "b-small", labels["b-small"])}</div>'
        f'{figure(attempt, "a-medium", labels["a-medium"])}{figure(attempt, "b-medium", labels["b-medium"])}</div>'
    )


def cell_html(cell_id, states):
    c = cells.get(cell_id)
    if c is None:
        return '<td class="cell"><span class="badge failed">not run</span></td>'
    attempts = c["attempts"]
    validity = {"first try": "first", "repaired": "repaired", "failed": "failed"}[c["validity_status"]]
    fit_kind = {"fits first time": "first", "fit repaired": "repaired"}.get(c["fit_status"], "failed")
    meta = [f"{c['model_calls']} model call{'s' if c['model_calls'] != 1 else ''}", f"{c['gen_seconds_total']} s generating", f"{c['output_bytes']} bytes"]
    notes = []
    for e in c["errors"]:
        notes.append(f'<p class="error"><b>Attempt {e["attempt"]} ({esc(e["kind"])}) error, {esc(e["family"])} with data {esc(e["state"])}.</b> {esc(e["error"])}</p>')
    if c["actions_unknown"]:
        notes.append(f'<p class="error">Unknown action ids: {esc(", ".join(c["actions_unknown"]))}</p>')
    if c["actions_missing"]:
        notes.append(f'<p class="note">Actions with no button: {esc(", ".join(c["actions_missing"]))}</p>')
    if c["group"] == "reference":
        if c["assets_used"]:
            where = sorted({k.split("-")[1] for k, v in c["assets_used_by_render"].items() if v})
            notes.append(f'<p class="note">Uses the <code>reference</code> image as a layer ({esc(", ".join(where))}).</p>')
        else:
            notes.append('<p class="plain">Recreated in code. The <code>reference</code> image is not drawn.</p>')
    if c["fonts_used"]:
        notes.append(f'<p class="plain">Named fonts: {esc(", ".join(c["fonts_used"]))}</p>')
    if c.get("round1_overflow_pt"):
        notes.append(f'<p class="plain">Round one, same prompt and model, no fit check: up to {num(max(c["round1_overflow_pt"].values()))} pt overflow (round-one measure).</p>')

    blocks = ""
    if not c["valid_final"]:
        blocks = block("Last attempt (failed)", attempts[-1], states)
    elif c["fit_repair_used"]:
        before = attempts[c["before_attempt"] - 1]
        final = attempts[c["final_attempt"] - 1]
        blocks = block(f"Before fit repair (attempt {c['before_attempt']})", before, states)
        if c["final_attempt"] > c["before_attempt"]:
            blocks += block(f"After fit repair (attempt {c['final_attempt']})", final, states)
        else:
            blocks += '<div class="block"><div class="blocktitle">After fit repair</div><p class="error">The repaired look did not draw. The look on the left is kept.</p></div>'
    else:
        blocks = block(f"Attempt {c['final_attempt']}, no fit repair needed", attempts[c["final_attempt"] - 1], states)
    return (
        f'<td class="cell"><div class="info"><div class="head">'
        f'<span class="badge {validity}">valid: {esc(c["validity_status"])}</span>'
        f'<span class="badge {fit_kind}">fit: {esc(c["fit_status"])}</span></div>'
        f'<div class="meta">{esc(" · ".join(meta))}</div>{"".join(notes)}</div><div class="blocks">{blocks}</div></td>'
    )


def model_head():
    return "<thead><tr>" + "".join(f"<th>J-{esc(m)}<small>JavaScript, {esc(m)}</small></th>" for m in models) + "</tr></thead>"


rerun_rows = []
for i, p in enumerate(results["prompts"], 1):
    tds = "".join(cell_html(f"{p['id']}__J-{m}", p["states"]) for m in models)
    rerun_rows.append(
        f'<tr class="prompt"><th colspan="{len(models)}"><span class="widget">Prompt {i}, {esc(p["widget"])} widget</span>'
        f'<span class="quote">{esc(p["text"])}</span></th></tr><tr class="cells">{tds}</tr>'
    )

reference_rows = []
for r in results["references"]:
    w, h = r["pixels"]
    shown = 338
    tds = "".join(cell_html(f"{r['id']}__J-{m}", r["states"]) for m in models)
    reference_rows.append(
        f'<tr class="prompt"><th colspan="{len(models) + 1}"><span class="widget">{esc(r["id"])}, {esc(r["widget"])} widget</span>'
        f'<span class="quote">{esc(results["user_words"])}</span><span class="widget"> {esc(r["what"])}</span></th></tr>'
        f'<tr class="cells"><td class="cell ref"><figure><img src="{esc(r["image"])}" width="{shown}" height="{round(shown * h / w)}" alt="reference {esc(r["id"])}">'
        f'<figcaption>The reference, {w} x {h} pixels. <a href="{esc(r["image"])}">full size</a></figcaption></figure></td>{tds}</tr>'
    )

sanity = results.get("image_sanity")
sanity_html = ""
if sanity:
    items = "".join(
        f'<details><summary>{esc(c["reference"])}, {esc(c["model"])}</summary><pre>{esc(c["reply"])}</pre></details>' for c in sanity["calls"]
    )
    sanity_html = (
        f'<p class="summary">Proof that the model sees the picture. Before the matrix, each model got each reference with the question '
        f'"{esc(sanity["question"])}" and no tools.</p><div class="sanity">{items}</div>'
    )

fonts = results["fonts"]
font_rows = "".join(
    f'<tr><td>{esc(f["family"])}</td><td>{esc(f["style"])}</td><td>{"yes" if f["resolves"] else "NO"}</td>'
    f'<td>{esc(", ".join(f["faces"]))}</td></tr>' for f in fonts["fonts"]
)

rerun = [c for c in results["cells"] if c["group"] == "rerun"]
refs = [c for c in results["cells"] if c["group"] == "reference"]


def tally(group):
    over_before = sum(1 for c in group if max(c["overflow_before_pt"].values(), default=0) > limit)
    over_after = sum(1 for c in group if c["valid_final"] and max(c["overflow_after_pt"].values(), default=0) > limit)
    valid = sum(1 for c in group if c["valid_final"])
    first = sum(1 for c in group if c["valid_first_try"])
    return f"{len(group)} cells, {first} valid on the first try, {valid} valid at the end. {over_before} overflowed by more than {limit} pt before the fit repair, {over_after} after."


page = f"""<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Look language round two</title>
<style>
  :root {{ color-scheme: dark; }}
  body {{ margin: 0; padding: 24px; background: #17181a; color: #e4e5e7; font: 14px/1.45 -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif; }}
  h1 {{ font-size: 20px; margin: 0 0 6px; font-weight: 600; }}
  h2 {{ font-size: 17px; margin: 38px 0 6px; font-weight: 600; padding-top: 18px; border-top: 1px solid #34363b; }}
  p.summary {{ margin: 0 0 10px; color: #a2a5ab; max-width: 980px; }}
  a {{ color: #8ab4f8; }}
  table {{ border-collapse: collapse; }}
  thead th {{ text-align: left; padding: 10px 8px; font-size: 14px; font-weight: 600; border-bottom: 1px solid #34363b; }}
  thead th small {{ display: block; color: #a2a5ab; font-weight: 400; font-size: 12px; }}
  tr.cells {{ border-bottom: 1px solid #2a2c30; }}
  tr.prompt th {{ text-align: left; padding: 22px 8px 2px; font-weight: 400; }}
  tr.prompt .widget {{ color: #a2a5ab; font-size: 12px; margin-right: 10px; }}
  tr.prompt .quote {{ font-size: 16px; font-weight: 600; margin-right: 10px; }}
  td.cell {{ vertical-align: top; padding: 10px 14px 16px 8px; min-width: 338px; }}
  td.cell.ref {{ min-width: 338px; width: 338px; }}
  .info {{ min-height: 96px; max-width: 700px; }}
  .head {{ display: flex; align-items: center; gap: 8px; flex-wrap: wrap; }}
  .badge {{ display: inline-block; padding: 2px 8px; border-radius: 4px; font-size: 12px; font-weight: 600; }}
  .badge.first {{ background: #1f4d33; color: #b6f0cd; }}
  .badge.repaired {{ background: #5a4514; color: #ffe1a1; }}
  .badge.failed {{ background: #5c2323; color: #ffc4c4; }}
  .meta {{ color: #a2a5ab; font-size: 12px; margin: 6px 0; }}
  p.error, p.note, p.plain {{ margin: 0 0 6px; font-size: 12px; color: #ffc4c4; overflow-wrap: anywhere; }}
  p.note {{ color: #ffe1a1; }}
  p.plain {{ color: #a2a5ab; }}
  .blocks {{ display: flex; gap: 22px; align-items: flex-start; }}
  .block {{ width: 338px; }}
  .blocktitle {{ font-size: 12px; font-weight: 600; margin: 8px 0; }}
  .blocktitle a {{ font-weight: 400; margin-left: 8px; }}
  .pair {{ display: flex; gap: 12px; }}
  figure {{ margin: 0 0 10px; }}
  figure img {{ display: block; }}
  figcaption {{ color: #a2a5ab; font-size: 11px; margin-top: 3px; }}
  .good {{ color: #8fd9ac; }}
  .bad {{ color: #ff9c9c; }}
  .warn {{ color: #ffe1a1; }}
  .missing {{ box-sizing: border-box; border: 1px dashed #5c2323; border-radius: 22px; color: #ffc4c4; font-size: 11px; padding: 14px; overflow: hidden; overflow-wrap: anywhere; }}
  .sanity details {{ margin: 0 0 4px; font-size: 12px; color: #a2a5ab; }}
  .sanity pre {{ white-space: pre-wrap; max-width: 900px; background: #1f2023; padding: 10px; border-radius: 6px; color: #e4e5e7; }}
  table.fonts td, table.fonts th {{ text-align: left; padding: 4px 14px 4px 0; font-size: 12px; border-bottom: 1px solid #2a2c30; vertical-align: top; }}
  img.specimen {{ display: block; margin: 12px 0 16px; max-width: 100%; height: auto; }}
  code {{ font-family: inherit; background: #26282c; padding: 0 4px; border-radius: 3px; }}
</style>
</head>
<body>
<h1>Look language round two: fit check, named fonts, reference images</h1>
<p class="summary">JavaScript looks only. {len(results['cells'])} of {results['cells_expected']} cells run. Generated {esc(results['generated_at'])}.
Images are shown at point size (small 158 x 158, medium 338 x 158), rendered at 3x on macOS. Round one is at <a href="index.html">index.html</a>.</p>
<p class="summary">Overflow is the larger of two measurements taken from the real render: how much bigger than the widget the root layout is, and how far any text, symbol, or button
sticks out of the widget or of a clipped container. A look that overflows by more than {limit} pt gets one fit repair. Shapes and images that bleed past the edge are not counted.
"Cut with an ellipsis" counts texts that need more lines or height than they got at their smallest allowed scale. It is recorded, and it does not trigger a repair.</p>

<h2>1. Fit check on the six round-one prompts</h2>
<p class="summary">{tally(rerun)}</p>
<table>
{model_head()}
<tbody>
{chr(10).join(rerun_rows)}
</tbody>
</table>

<h2>2. Reference images</h2>
<p class="summary">{tally(refs)} The model gets the picture as an image block in the same message as the task, and the same file is registered as the image asset <code>reference</code>.</p>
{sanity_html}
<table>
<thead><tr><th>Reference</th>{"".join(f"<th>J-{esc(m)}<small>JavaScript, {esc(m)}</small></th>" for m in models)}</tr></thead>
<tbody>
{chr(10).join(reference_rows)}
</tbody>
</table>

<h2>3. Named fonts</h2>
<p class="summary">The <code>fontName</code> allowlist, drawn by the renderer on this Mac. Every family resolves here. Whether each one ships on iOS was not verified in this round.
Where a family has no bold or italic face, the nearest face is used, so some columns repeat.</p>
<img class="specimen" src="{esc(fonts['png'])}" width="{fonts['pixel_width'] // 2}" height="{fonts['pixel_height'] // 2}" alt="font specimen">
<table class="fonts">
<thead><tr><th>fontName</th><th>style</th><th>resolves on this Mac</th><th>faces installed</th></tr></thead>
<tbody>{font_rows}</tbody>
</table>
</body>
</html>
"""
assert chr(0x2014) not in page
(ROOT / "index-round2.html").write_text(page)
print(f"wrote index-round2.html: {len(results['cells'])} cells")
