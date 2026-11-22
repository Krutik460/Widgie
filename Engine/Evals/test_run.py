import unittest

from run import table_changes

WATER = {
    "name": "Water",
    "tables": {"glasses": {"fields": {}}},
    "queries": {"today": {"count": "glasses", "window": "today"}},
    "actions": {"drink": {"insert": "glasses"}, "undo": {"delete": "glasses"}},
}


def refined(**changes) -> dict:
    return {**WATER, **changes}


class TableChangesTests(unittest.TestCase):
    def test_a_relabelled_table_fails_a_case_that_expects_a_new_table(self):
        coffee = refined(name="Coffee")
        self.assertEqual(table_changes(WATER, coffee, expect_new_table=True),
                         {"added": [], "fields_added": {}, "expected": True, "ok": False})

    def test_a_new_table_that_the_widget_reads_and_adds_rows_to_passes(self):
        coffee = refined(
            name="Coffee",
            tables={"glasses": {"fields": {}}, "cups": {"fields": {}}},
            queries={"today": {"count": "cups", "window": "today"}},
            actions={"drink": {"insert": "cups"}, "undo": {"delete": "cups"}},
        )
        self.assertEqual(table_changes(WATER, coffee, expect_new_table=True),
                         {"added": ["cups"], "fields_added": {}, "expected": True, "ok": True})

    def test_a_new_table_counts_when_read_through_a_field_and_filled_by_a_form(self):
        coffee = refined(
            tables={"glasses": {"fields": {}}, "cups": {"fields": {"ml": "number"}}},
            queries={"today": {"sum": "cups.ml", "window": "today"}},
            actions={"log": {"form": "cups", "fields": ["ml"]}},
        )
        self.assertTrue(table_changes(WATER, coffee, expect_new_table=True)["ok"])

    def test_a_new_table_that_an_automation_writes_counts_as_filled(self):
        words = refined(
            tables={"glasses": {"fields": {}}, "words": {"fields": {"word": "text"}}},
            queries={"today": {"count": "glasses", "window": "today"}, "word": {"latest": "words", "window": "all"}},
            automations={"daily": {"prompt": "Pick a word.", "every": "day", "at": "06:00", "writes": "words"}},
        )
        self.assertTrue(table_changes(WATER, words, expect_new_table=True)["ok"])

    def test_a_new_table_nothing_reads_or_nothing_fills_fails(self):
        tables = {"glasses": {"fields": {}}, "cups": {"fields": {}}}
        unread = refined(tables=tables, actions={"drink": {"insert": "cups"}})
        unfilled = refined(tables=tables, queries={"today": {"count": "cups", "window": "today"}},
                           actions={"undo": {"delete": "cups"}})
        for name, document in [("unread", unread), ("unfilled", unfilled)]:
            with self.subTest(name):
                result = table_changes(WATER, document, expect_new_table=True)
                self.assertEqual(result["added"], ["cups"])
                self.assertFalse(result["ok"])

    def test_a_refine_that_expects_no_table_passes_with_added_fields_and_fails_with_a_table(self):
        sized = refined(tables={"glasses": {"fields": {"ml": "number"}}})
        self.assertEqual(table_changes(WATER, sized, expect_new_table=False),
                         {"added": [], "fields_added": {"glasses": ["ml"]}, "expected": False, "ok": True})
        split = refined(tables={"glasses": {"fields": {}}, "drinks": {"fields": {}}})
        self.assertEqual(table_changes(WATER, split, expect_new_table=False),
                         {"added": ["drinks"], "fields_added": {}, "expected": False, "ok": False})

    def test_an_unreadable_reply_adds_nothing(self):
        self.assertEqual(table_changes(WATER, {}, expect_new_table=False),
                         {"added": [], "fields_added": {}, "expected": False, "ok": True})
        self.assertFalse(table_changes(WATER, {}, expect_new_table=True)["ok"])


if __name__ == "__main__":
    unittest.main()
