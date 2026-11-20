#!/usr/bin/env python3
"""Assemble the two language references from shared and per-variant parts."""
from pathlib import Path

root = Path(__file__).parent
vocab = (root / "lang/vocabulary.md").read_text()
data = (root / "examples/reading-data.json").read_text().strip()

example_intro = (
    "## Worked example\n\n"
    "A reading tracker. Its data looks like this, and it has one action, `logPages`.\n\n"
    f"```json\n{data}\n```\n\n"
    "The look shows the title, a percentage that turns into a seal when the goal is reached, "
    "a progress bar whose width and color follow the data, one bar per reading session, "
    "an extra line of text in the medium family, and a button.\n\n"
)

# Round two extended the vocabulary for JavaScript only. The template reference stays as it was in round one.
for name, head, vocab, example, fence in [
    ("template", "lang/template-head.md", vocab, "examples/reading.template.json", "json"),
    ("js", "lang/js-head.md", (root / "lang/vocabulary-js.md").read_text(), "examples/reading.js", "js"),
]:
    body = (root / example).read_text().strip()
    doc = (root / head).read_text().strip() + "\n\n" + vocab.strip() + "\n\n" + example_intro + f"```{fence}\n{body}\n```\n"
    assert chr(0x2014) not in doc
    (root / f"lang-{name}.md").write_text(doc)
    print(f"lang-{name}.md: {len(doc)} chars, {len(doc.split())} words, {len(doc.splitlines())} lines, "
          f"head {len((root / head).read_text().split())} words, example {len(body.split())} words")
