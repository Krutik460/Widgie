"""How a refine changed a widget's tables, scored against what its eval case expects. `run.py` puts it in the
summary and `sheet.py` on the contact sheet."""

import json
from pathlib import Path

QUERY_SHAPES = ("count", "sum", "latest", "list", "streak", "daily")
# The actions that add rows. A set, toggle, or delete only changes rows that already exist.
ADDING_ACTIONS = ("insert", "insertOn", "form")


def parsed(document: str) -> dict:
    try:
        value = json.loads(document)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def members(value) -> dict:
    return value if isinstance(value, dict) else {}


def targets(document: dict, key: str, effects: tuple[str, ...]) -> set[str]:
    """The tables that the blocks under `key` name with one of `effects`, a "table.field" counted as its table."""
    return {target.split(".")[0] for block in members(document.get(key)).values()
            for effect, target in members(block).items() if effect in effects and isinstance(target, str)}


def table_changes(before: dict, after: dict, expect_new_table: bool, replaces: str | None = None) -> dict:
    """The tables and fields a refine added, and the problems that keep it from meeting the case. A case that
    expects a new table needs one the widget reads with a query and adds rows to, so a reply that only relabels
    a kept table fails. Any other refine adds no table. Every table the base read is still read, except the one
    the case `replaces`, which nothing reads or adds rows to any more."""
    old, new = members(before.get("tables")), members(after.get("tables"))
    added = sorted(set(new) - set(old))
    fields_added = {}
    for table in sorted(set(old) & set(new)):
        kept, now = (members(members(t[table]).get("fields")) for t in (old, new))
        fields = sorted(set(now) - set(kept))
        if fields:
            fields_added[table] = fields
    read = targets(after, "queries", QUERY_SHAPES)
    filled = targets(after, "actions", ADDING_ACTIONS) | targets(after, "automations", ("writes",))
    problems = []
    if expect_new_table and not any(table in read and table in filled for table in added):
        problems.append("no new table that a query reads and something adds rows to")
    if not expect_new_table and added:
        problems.append(f"adds {', '.join(added)}")
    problems += [f"stops reading {table}"
                 for table in sorted(targets(before, "queries", QUERY_SHAPES) - read - {replaces})]
    if replaces in read:
        problems.append(f"still reads {replaces}")
    if replaces in filled:
        problems.append(f"still adds rows to {replaces}")
    return {"added": added, "fields_added": fields_added, "problems": problems}


def check_tables(run_dir: Path, refines: list[tuple[dict, bool, str | None]]) -> dict:
    """`table_changes` of each accepted refine build, given with its case's `expect_new_table` and `replaces`, by
    model and case, and how many pass. A failed build saved no widget, so its tables neither pass nor fail."""
    checks = {}
    for build, expect_new_table, replaces in refines:
        if not build["accepted_attempt"]:
            continue
        case_dir = run_dir / build["case"]
        before = parsed((case_dir / "before" / "current" / "widget.json").read_text())
        after = parsed((case_dir / build["model"] / str(build["accepted_attempt"]) / "widget" / "widget.json").read_text())
        check = checks.setdefault(build["model"], {"passed": 0, "of": 0, "misses": [], "cases": {}})
        check["cases"][build["case"]] = changes = table_changes(before, after, expect_new_table, replaces)
        check["of"] += 1
        if changes["problems"]:
            check["misses"].append(build["case"])
        else:
            check["passed"] += 1
    return checks
