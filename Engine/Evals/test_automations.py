import contextlib
import io
import json
import tempfile
import unittest
import urllib.error
from datetime import datetime
from pathlib import Path
from unittest import mock
from zoneinfo import ZoneInfo

import automations
from automations import CASES, Case, case_summary, run_case, run_times, summary_table

WORDS = Case(id="words", prompt="A word.", fields={"word": "text", "kind": "text", "rank": "number"}, key="word")


def answering(rows, outcome="written"):
    """A fake Worker that answers each call with the next row, and keeps every body it was sent."""
    sent = []
    queue = list(rows)

    def post(body):
        sent.append(json.loads(json.dumps(body)))
        row = queue.pop(0)
        return {"row": row, "outcome": outcome if row is not None else "retry", "reason": None if row else "json",
                "calls": 1 if row else 2, "usage": {"cost_usd": 0.0002, "output_tokens": 50}, "seconds": 1.2}

    return post, sent


class RunCaseTests(unittest.TestCase):
    def test_each_written_row_is_the_newest_recent_row_of_the_next_day_with_only_its_text(self):
        post, sent = answering([{"word": f"w{i}", "kind": "noun", "rank": i} for i in range(3)])
        run_case(WORDS, post, runs=3)
        self.assertEqual([body["recent"] for body in sent], [
            [],
            [{"word": "w0", "kind": "noun"}],
            [{"word": "w1", "kind": "noun"}, {"word": "w0", "kind": "noun"}],
        ])
        self.assertEqual({body["timeZone"] for body in sent}, {"America/New_York"})

    def test_the_recent_rows_stop_at_sixty(self):
        post, sent = answering([{"word": f"w{i}", "kind": "noun", "rank": i} for i in range(62)])
        run_case(WORDS, post, runs=62)
        self.assertEqual(len(sent[61]["recent"]), 60)
        self.assertEqual(sent[61]["recent"][0]["word"], "w60")
        self.assertEqual(sent[61]["recent"][-1]["word"], "w1")

    def test_a_day_with_no_row_adds_nothing_to_the_history_and_fails_the_case(self):
        post, sent = answering([{"word": "a", "kind": "noun", "rank": 1}, None, {"word": "b", "kind": "noun",
                                                                                 "rank": 2}])
        days = run_case(WORDS, post, runs=3)
        self.assertEqual(sent[2]["recent"], [{"word": "a", "kind": "noun"}])
        summary = case_summary(WORDS, days)
        self.assertEqual((summary["written"], summary["retry"], summary["passed"]), (2, 1, False))
        self.assertEqual(summary["reasons"], {"json": 1})

    def test_a_worker_failure_is_an_error_day_and_the_run_goes_on(self):
        calls = []

        def post(body):
            calls.append(body)
            if len(calls) == 1:
                raise RuntimeError("HTTP 502: bad gateway\nmore")
            return {"row": {"word": "a", "kind": "noun", "rank": 1}, "outcome": "written", "calls": 1, "usage": {}}

        days = run_case(WORDS, post, runs=2)
        self.assertEqual([day.outcome for day in days], ["error", "written"])
        self.assertEqual(days[0].reason, "HTTP 502: bad gateway")

    def test_exact_and_near_repeats_ignore_case_and_space_and_a_shared_category_is_neither(self):
        post, _ = answering([
            {"word": "Madrugar", "kind": "verb", "rank": 1},
            {"word": "aprovechar", "kind": "verb", "rank": 2},
            {"word": " madrugar ", "kind": "VERB", "rank": 3},
            {"word": "Aprovechar", "kind": "noun", "rank": 4},
        ])
        days = run_case(WORDS, post, runs=4)
        self.assertEqual([(d.exact_repeat_of, d.near_repeat_of) for d in days],
                         [(None, None), (None, None), (1, 1), (None, 2)])
        summary = case_summary(WORDS, days)
        self.assertEqual((summary["exact_repeats"], summary["near_repeats"], summary["passed"]), (1, 2, False))

    def test_an_empty_text_field_is_invalid_unless_the_prompt_leaves_it_empty(self):
        row = {"word": "a", "kind": " ", "rank": 1}
        days = run_case(WORDS, answering([row])[0], runs=1)
        self.assertEqual(days[0].problems, ['"kind" is empty'])
        lenient = Case(id="w", prompt="p", fields=WORDS.fields, key="word", may_be_empty=("kind",))
        self.assertEqual(run_case(lenient, answering([row])[0], runs=1)[0].problems, [])

    def test_a_category_case_expects_repeats_and_checks_the_values(self):
        focus = next(case for case in CASES if case.id == "workout-focus")
        post, _ = answering([{"focus": "Push"}, {"focus": "pull"}, {"focus": "Push"}, {"focus": "Cardio"}])
        days = run_case(focus, post, runs=4)
        self.assertEqual(days[3].problems, ['"focus" is not one of push, pull, legs'])
        summary = case_summary(focus, days)
        self.assertTrue(summary["repeats_expected"])
        self.assertEqual(summary["near_repeats"], 1)
        self.assertFalse(summary["passed"])
        days = run_case(focus, answering([{"focus": "Legs"}, {"focus": "legs"}])[0], runs=2)
        self.assertTrue(case_summary(focus, days)["passed"])

    def test_a_refine_switches_prompt_halfway_on_the_same_history(self):
        refine = next(case for case in CASES if case.id == "refine-cooking")
        post, sent = answering([{"word": f"w{i}", "definition": "d"} for i in range(30)])
        run_case(refine, post, runs=30)
        self.assertEqual({body["prompt"] for body in sent[:15]}, {refine.prompt})
        self.assertEqual({body["prompt"] for body in sent[15:]}, {refine.refined})
        self.assertIn("Italian", refine.refined)
        self.assertEqual(len(sent[15]["recent"]), 15)


class CaseTests(unittest.TestCase):
    def test_the_cases_the_plan_names_are_there_with_their_fields(self):
        cases = {case.id: case for case in CASES}
        self.assertEqual(set(cases), {"nursing-terms", "spanish-cooking", "stoic-quote", "couple-question",
                                      "workout-focus", "refine-cooking"})
        self.assertEqual(list(cases["nursing-terms"].fields), ["word", "kind", "definition", "example"])
        self.assertEqual(list(cases["spanish-cooking"].fields), ["word", "definition"])
        self.assertEqual(list(cases["stoic-quote"].fields), ["quote", "author"])
        self.assertEqual(list(cases["couple-question"].fields), ["question"])
        for case in CASES:
            self.assertIn(case.key, case.fields, case.id)

    def test_days_are_consecutive_at_six_in_the_morning(self):
        zone = ZoneInfo("America/New_York")
        times = [datetime.fromtimestamp(ms / 1000, zone) for ms in run_times(30)]
        self.assertEqual({(t.hour, t.minute) for t in times}, {(6, 0)})
        self.assertEqual([(b.date() - a.date()).days for a, b in zip(times, times[1:])], [1] * 29)


class MainTests(unittest.TestCase):
    def test_main_sends_the_secret_and_a_user_agent_writes_the_results_and_never_prints_the_secret(self):
        seen = []

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *exc):
                return False

        def urlopen(request, timeout):
            seen.append(request)
            return Response(json.dumps({"row": {"question": f"Q{len(seen)}?"}, "outcome": "written", "reason": None,
                                        "calls": 1, "usage": {"cost_usd": 0.001}}).encode())

        with tempfile.TemporaryDirectory() as temp:
            secret_file = Path(temp) / "secret"
            secret_file.write_text("s3cret-value\n")
            output = io.StringIO()
            with mock.patch("automations.ARTIFACTS", Path(temp) / "evals"), \
                    mock.patch("automations.urllib.request.urlopen", urlopen), \
                    contextlib.redirect_stdout(output):
                code = automations.main(["https://dev.example/", str(secret_file), "--cases", "couple-question",
                                         "--runs", "3", "--name", "t"])
            self.assertEqual(code, 0)
            self.assertEqual(len(seen), 3)
            self.assertEqual(seen[0].full_url, "https://dev.example/v1/dev/run")
            self.assertEqual(seen[0].get_header("X-widgie-dev-secret"), "s3cret-value")
            self.assertEqual(seen[0].get_header("User-agent"), automations.USER_AGENT)
            self.assertNotIn("s3cret", output.getvalue())
            out = Path(temp) / "evals" / "t"
            for name in ("couple-question.json", "summary.json", "summary.md"):
                self.assertNotIn("s3cret", (out / name).read_text())
            summary = json.loads((out / "summary.json").read_text())
            self.assertEqual(summary[0]["written"], 3)
            self.assertIn("| couple-question | 3 | 3 | 3 | 0 | 0 |", (out / "summary.md").read_text())

    def test_a_refused_request_is_not_tried_again(self):
        tries = []

        def urlopen(request, timeout):
            tries.append(request)
            raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, io.BytesIO(b"not found\n"))

        with mock.patch("automations.urllib.request.urlopen", urlopen):
            with self.assertRaises(RuntimeError) as caught:
                automations.poster("https://dev.example", "s")({"prompt": "p"})
        self.assertEqual(len(tries), 1)
        self.assertEqual(str(caught.exception), "HTTP 404: not found")


class SummaryTests(unittest.TestCase):
    def test_the_table_marks_a_category_case_s_repeats_as_expected_and_adds_totals(self):
        focus = next(case for case in CASES if case.id == "workout-focus")
        days = run_case(focus, answering([{"focus": "Push"}, {"focus": "Push"}])[0], runs=2)
        table = summary_table([case_summary(focus, days)])
        self.assertIn("| workout-focus | 2 | 2 | 2 | 1 (expected) | 1 (expected) |", table)
        self.assertIn("| total | 2 | 2 | 2 |", table)


if __name__ == "__main__":
    unittest.main()
