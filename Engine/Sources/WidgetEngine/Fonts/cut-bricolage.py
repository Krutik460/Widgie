"""Cuts the static Bricolage Grotesque faces the app bundles from the full OFL variable font.

The prototype draws titles at weight 800 and 82 percent width, and keys at weight 700 and 92 percent width. Browsers
pick the optical size from the font size, so the instances use the optical size of the text they set: about 36 for
titles and banner lines, 18 for keys. iOS cannot load the site's woff2 subset, which also lacks accented letters.

Run: python3 -m venv venv && venv/bin/pip install fonttools && venv/bin/python cut-bricolage.py <outdir>
"""

import sys
import urllib.request
from pathlib import Path

from fontTools.ttLib import TTFont
from fontTools.varLib.instancer import instantiateVariableFont

COMMIT = "6ce172f74aa355ea43eb964fa4a91570a4d3064d"
SOURCE = f"https://raw.githubusercontent.com/google/fonts/{COMMIT}/ofl/bricolagegrotesque/BricolageGrotesque%5Bopsz,wdth,wght%5D.ttf"
FACES = {
    "BricolageGrotesque-Display": {"wght": 800, "wdth": 82, "opsz": 36},
    "BricolageGrotesque-Key": {"wght": 700, "wdth": 92, "opsz": 18},
}


def name(font: TTFont, postscript: str) -> None:
    family, style = "Bricolage Grotesque " + postscript.split("-")[1], "Regular"
    table = font["name"]
    table.names = [n for n in table.names if n.nameID not in (1, 2, 3, 4, 6, 16, 17, 25)]
    for nid, value in {1: family, 2: style, 3: f"{postscript};{COMMIT[:7]}", 4: family, 6: postscript}.items():
        table.setName(value, nid, 3, 1, 0x409)
        table.setName(value, nid, 1, 0, 0)


def main(out: Path) -> None:
    out.mkdir(parents=True, exist_ok=True)
    data = urllib.request.urlopen(SOURCE).read()
    source = out / ".variable.ttf"
    source.write_bytes(data)
    for postscript, axes in FACES.items():
        font = instantiateVariableFont(TTFont(source), axes)
        for table in ("STAT", "fvar", "avar"):
            if table in font:
                del font[table]
        name(font, postscript)
        font.save(out / f"{postscript}.ttf")
    source.unlink()


if __name__ == "__main__":
    main(Path(sys.argv[1]))
