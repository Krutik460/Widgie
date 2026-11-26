#!/usr/bin/env python3
"""Builds prototype.html: prototype.src.html with the landing page's own caret, widgets, tile styles and font inlined,
so the app prototype shows the exact toy box tiles from Site/public. Run: python3 -I build-prototype.py"""

import base64
import pathlib
import re

here = pathlib.Path(__file__).resolve().parent
site = here.parents[2] / "Site" / "public"


def module(name, also=()):
    """A site module as a plain script in its own scope, its exports made constants, so two modules may share a
    private name (both declare INK). `also` names private constants the prototype needs too."""
    text = (site / name).read_text()
    text = re.sub(r"^import .*?;\n", "", text, flags=re.M | re.S)
    exports = re.findall(r"^export (?:const|function) (\w+)", text, flags=re.M) + list(also)
    body = re.sub(r"^export ", "", text, flags=re.M)
    if not exports:
        return body
    names = ", ".join(exports)
    return f"const {{ {names} }} = (() => {{\n{body}\nreturn {{ {names} }};\n}})();"


css = (site / "styles.css").read_text().split("\n")
# The toy key, the blocks and widget art, and the caret (styles.css sections between their banners).
start = next(i for i, l in enumerate(css) if "The button: a toy key" in l)
end = next(i for i, l in enumerate(css) if "---------- Nav ----------" in l)
tiles = "\n".join(css[start:end])
font = base64.b64encode((site / "fonts" / "bricolage.woff2").read_bytes()).decode()

src = (here / "prototype.src.html").read_text()
out = (
    src.replace("/*FONT*/", font)
    .replace("/*SITE_CSS*/", tiles)
    .replace("/*SITE_JS*/", module("caret.js") + "\n" + module("heroes.js") + "\n" + module("widgets.js", also=("MEDIUM", "puppy", "MEDAL")))
)
(here / "prototype.html").write_text(out)
print(f"wrote {here / 'prototype.html'} ({len(out) // 1024} KB)")
