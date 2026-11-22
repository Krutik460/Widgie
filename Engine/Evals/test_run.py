import contextlib
import io
import json
import re
import tempfile
import unittest
from pathlib import Path

from run import ADDING_ACTIONS, ENGINE, FIXTURES, QUERY_SHAPES, Case, load_cases, summarize, table_changes

WATER = {
    "name": "Water",
    "tables": {"glasses": {"fields": {}}},
    "queries": {"today": {"count": "glasses", "window": "today"}},
    "actions": {"drink": {"insert": "glasses"}, "undo": {"delete": "glasses"}},
}
COFFEE = {
    **WATER,
    "name": "Coffee",
    "tables": {"glasses": {"fields": {}}, "cups": {"fields": {}}},
    "queries": {"today": {"count": "cups", "window": "today"}},
    "actions": {"drink": {"insert": "cups"}, "undo": {"delete": "cups"}},
}
NO_NEW_TABLE = "no new table that a query reads and something adds rows to"


def refined(**changes) -> dict:
    return {**WATER, **changes}


class TableChangesTests(unittest.TestCase):
    def test_a_relabelled_table_fails_a_case_that_expects_a_new_table(self):
        coffee = refined(name="Coffee")
        self.assertEqual(table_changes(WATER, coffee, expect_new_table=True),
                         {"added": [], "fields_added": {}, "problems": [NO_NEW_TABLE]})
        self.assertEqual(table_changes(WATER, coffee, expect_new_table=True, replaces="glasses")["problems"],
                         [NO_NEW_TABLE, "still reads glasses", "still adds rows to glasses"])

    def test_a_new_table_that_replaces_the_old_one_passes(self):
        self.assertEqual(table_changes(WATER, COFFEE, expect_new_table=True, replaces="glasses"),
                         {"added": ["cups"], "fields_added": {}, "problems": []})

    def test_a_new_table_beside_a_relabelled_one_fails_a_replacement(self):
        mixed = {**COFFEE,
                 "queries": {"today": {"count": "glasses", "window": "today"}, "week": {"daily": "cups", "days": 7}},
                 "actions": {"drink": {"insert": "glasses"}, "coffee": {"insert": "cups"}}}
        self.assertEqual(table_changes(WATER, mixed, expect_new_table=True, replaces="glasses"),
                         {"added": ["cups"], "fields_added": {},
                          "problems": ["still reads glasses", "still adds rows to glasses"]})

    def test_a_replaced_table_that_only_a_delete_touches_passes(self):
        coffee = {**COFFEE, "actions": {"drink": {"insert": "cups"}, "clear": {"delete": "glasses"}}}
        self.assertEqual(table_changes(WATER, coffee, expect_new_table=True, replaces="glasses")["problems"], [])

    def test_a_kept_table_the_reply_stops_reading_fails(self):
        self.assertEqual(table_changes(WATER, COFFEE, expect_new_table=True)["problems"], ["stops reading glasses"])
        unread = refined(queries={}, actions={"drink": {"insert": "glasses"}})
        self.assertEqual(table_changes(WATER, unread, expect_new_table=False)["problems"], ["stops reading glasses"])

    def test_a_new_table_read_through_any_query_shape_and_filled_by_insert_on_counts(self):
        habit = {"tables": {"checkins": {"fields": {}}}, "queries": {"streak": {"streak": "checkins"}},
                 "actions": {"check": {"insertOn": "checkins"}}}
        for shape, query in [("streak", {"streak": "sessions"}), ("daily", {"daily": "sessions", "days": 35}),
                             ("latest", {"latest": "sessions", "window": "today"}),
                             ("list", {"list": "sessions", "window": "all"})]:
            with self.subTest(shape):
                yoga = {"tables": {"checkins": {"fields": {}}, "sessions": {"fields": {}}},
                        "queries": {"streak": query}, "actions": {"check": {"insertOn": "sessions"}}}
                self.assertEqual(table_changes(habit, yoga, expect_new_table=True, replaces="checkins"),
                                 {"added": ["sessions"], "fields_added": {}, "problems": []})

    def test_a_new_table_counts_when_read_through_a_field_and_filled_by_a_form(self):
        coffee = refined(
            tables={"glasses": {"fields": {}}, "cups": {"fields": {"ml": "number"}}},
            queries={"today": {"sum": "cups.ml", "window": "today"}},
            actions={"log": {"form": "cups", "fields": ["ml"]}},
        )
        self.assertEqual(table_changes(WATER, coffee, expect_new_table=True, replaces="glasses")["problems"], [])

    def test_a_new_table_that_an_automation_writes_counts_as_filled(self):
        words = {"tables": {"words": {"fields": {"word": "text"}}}, "queries": {"word": {"latest": "words"}},
                 "automations": {"daily": {"prompt": "Pick a word.", "writes": "words"}}}
        quotes = {"tables": {"words": {"fields": {"word": "text"}}, "quotes": {"fields": {"quote": "text"}}},
                  "queries": {"word": {"latest": "quotes"}},
                  "automations": {"daily": {"prompt": "Pick a quote.", "writes": "quotes"}}}
        self.assertEqual(table_changes(words, quotes, expect_new_table=True, replaces="words")["problems"], [])
        still_writing = {**quotes, "automations": {**quotes["automations"], "old": {"writes": "words"}}}
        self.assertEqual(table_changes(words, still_writing, expect_new_table=True, replaces="words")["problems"],
                         ["still adds rows to words"])

    def test_a_new_table_nothing_reads_or_nothing_fills_fails(self):
        tables = {"glasses": {"fields": {}}, "cups": {"fields": {}}}
        unread = refined(tables=tables, actions={"drink": {"insert": "cups"}})
        unfilled = refined(tables=tables, queries={"today": {"count": "cups", "window": "today"}},
                           actions={"undo": {"delete": "cups"}})
        for name, document in [("unread", unread), ("unfilled", unfilled)]:
            with self.subTest(name):
                result = table_changes(WATER, document, expect_new_table=True, replaces="glasses")
                self.assertEqual(result["added"], ["cups"])
                self.assertIn(NO_NEW_TABLE, result["problems"])

    def test_a_refine_that_expects_no_table_passes_with_added_fields_and_fails_with_a_table(self):
        sized = refined(tables={"glasses": {"fields": {"ml": "number"}}})
        self.assertEqual(table_changes(WATER, sized, expect_new_table=False),
                         {"added": [], "fields_added": {"glasses": ["ml"]}, "problems": []})
        split = refined(tables={"glasses": {"fields": {}}, "drinks": {"fields": {}}})
        self.assertEqual(table_changes(WATER, split, expect_new_table=False),
                         {"added": ["drinks"], "fields_added": {}, "problems": ["adds drinks"]})


class SummarizeTests(unittest.TestCase):
    def setUp(self):
        self.run_dir = Path(tempfile.mkdtemp())
        self.write(self.run_dir / "refine-coffee" / "before" / "current" / "widget.json", WATER)

    def write(self, path: Path, value) -> None:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value))

    def build(self, model: str, replies: list[dict], accepted: bool) -> None:
        directory = self.run_dir / "refine-coffee" / model
        for number, reply in enumerate(replies, 1):
            self.write(directory / str(number) / "widget" / "widget.json", reply)
        attempts = [{"attempt": n, "seconds": 1, "output_tokens": 1, "input_tokens": 1, "models": [model],
                     "document_bytes": 1} for n in range(1, len(replies) + 1)]
        self.write(directory / "build.json", {
            "case": "refine-coffee", "group": "refine", "model": model,
            "status": "repaired once" if accepted else "failed",
            "accepted_attempt": len(replies) if accepted else None,
            "verdicts": ["small: too wide"] * (len(replies) - accepted), "seconds": 1, "output_tokens": 1,
            "attempts": attempts})

    def table_checks(self, case: Case) -> dict:
        with contextlib.redirect_stdout(io.StringIO()):
            summarize(self.run_dir, ["refine"], [case], ["haiku", "sonnet", "opus"])
        return json.loads((self.run_dir / "results.json").read_text())["table_checks"]

    def test_checks_each_accepted_refine_from_its_widget_and_leaves_out_failed_builds(self):
        self.build("haiku", [refined(name="Coffee"), COFFEE], accepted=True)
        self.build("sonnet", [refined(name="Coffee")], accepted=True)
        self.build("opus", [COFFEE, COFFEE, COFFEE], accepted=False)
        case = Case("refine-coffee", "refine", "track coffee instead of water", None, FIXTURES / "water",
                    expect_new_table=True, replaces="glasses")
        self.assertEqual(self.table_checks(case), {
            "haiku": {"passed": 1, "of": 1, "misses": [],
                      "cases": {"refine-coffee": {"added": ["cups"], "fields_added": {}, "problems": []}}},
            "sonnet": {"passed": 0, "of": 1, "misses": ["refine-coffee"],
                       "cases": {"refine-coffee": {"added": [], "fields_added": {}, "problems": [
                           NO_NEW_TABLE, "still reads glasses", "still adds rows to glasses"]}}},
        })

    def test_a_rerun_follows_the_cases_current_expectation(self):
        self.build("haiku", [COFFEE], accepted=True)
        replacing = Case("refine-coffee", "refine", "track coffee", None, FIXTURES / "water", True, "glasses")
        wording = Case("refine-coffee", "refine", "say coffee", None, FIXTURES / "water")
        self.assertEqual(self.table_checks(replacing)["haiku"]["passed"], 1)
        self.assertEqual(self.table_checks(wording)["haiku"]["misses"], ["refine-coffee"])


class LoadCasesTests(unittest.TestCase):
    def load(self, **fields) -> list[Case]:
        path = Path(tempfile.mkdtemp()) / "cases.json"
        entry = {"id": "refine-coffee", "group": "refine", "request": "track coffee instead of water", **fields}
        path.write_text(json.dumps({"groups": ["refine"], "cases": [entry]}))
        return load_cases(path)[1]

    def test_a_replacing_case_loads_with_its_expectation(self):
        [case] = self.load(base="water", expect_new_table=True, replaces="glasses")
        self.assertEqual((case.expect_new_table, case.replaces), (True, "glasses"))
        [case] = self.load(base="water")
        self.assertEqual((case.expect_new_table, case.replaces), (False, None))

    def test_rejects_table_fields_that_do_not_fit_the_case(self):
        for name, fields in [
            ("expect_new_table is not a bool", {"base": "water", "expect_new_table": "yes"}),
            ("expect_new_table without a base", {"expect_new_table": True}),
            ("replaces without expect_new_table", {"base": "water", "replaces": "glasses"}),
            ("replaces names no base table", {"base": "water", "expect_new_table": True, "replaces": "cups"}),
        ]:
            with self.subTest(name), self.assertRaises(SystemExit):
                self.load(**fields)

    def test_the_shipped_cases_load(self):
        load_cases()


class EngineVocabularyTests(unittest.TestCase):
    def kinds(self, source: str) -> list[str]:
        text = (ENGINE / "Sources" / "Spec" / source).read_text()
        return re.search(r"enum Kind: String, CaseIterable \{\s*case ([\w, ]+)\n", text).group(1).split(", ")

    def test_query_shapes_are_the_engines(self):
        self.assertEqual(list(QUERY_SHAPES), self.kinds("Queries.swift"))

    def test_every_engine_action_is_known_to_add_rows_or_not(self):
        self.assertEqual(set(self.kinds("Actions.swift")) - set(ADDING_ACTIONS), {"set", "toggle", "delete"})
        self.assertLessEqual(set(ADDING_ACTIONS), set(self.kinds("Actions.swift")))


if __name__ == "__main__":
    unittest.main()
