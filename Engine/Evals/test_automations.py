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
from automations import CASES, Case, RouteNotFound, case_summary, run_case, run_times, summary_table

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

    def test_repeats_compare_text_in_one_unicode_form_as_the_worker_does(self):
        # "Jalapeño" with a precomposed ñ, then with n and a combining tilde: the Worker's NFC makes them one.
        post, _ = answering([{"word": "Jalape\u00f1o", "kind": "noun", "rank": 1},
                             {"word": " JALAPEN\u0303O", "kind": "Noun ", "rank": 2}])
        days = run_case(WORDS, post, runs=2)
        self.assertEqual((days[1].exact_repeat_of, days[1].near_repeat_of), (1, 1))

    def test_calls_and_usage_add_up_over_every_call_and_repaired_counts_days_with_more_than_one(self):
        answers = [
            {"row": {"word": "a", "kind": "noun", "rank": 1}, "outcome": "written", "calls": 1,
             "usage": {"cost_usd": 0.0001, "input_tokens": 400, "output_tokens": 60}},
            # A call cut off with no text, then the repair: two calls, both billed.
            {"row": {"word": "b", "kind": "noun", "rank": 2}, "outcome": "written", "calls": 2,
             "usage": {"cost_usd": 0.0004, "input_tokens": 800, "output_tokens": 1060}},
            {"row": None, "outcome": "retry", "reason": "cut", "calls": 2,
             "usage": {"cost_usd": 0.0006, "input_tokens": 800, "output_tokens": 2000}},
        ]
        days = run_case(WORDS, lambda body: answers.pop(0), runs=3)
        summary = case_summary(WORDS, days)
        self.assertEqual((summary["calls"], summary["repaired"]), (5, 2))
        self.assertEqual((summary["input_tokens"], summary["output_tokens"]), (2000, 3120))
        self.assertAlmostEqual(summary["cost_usd"], 0.0011)

    def test_a_404_on_the_first_day_stops_the_case_and_a_later_one_is_an_error_day(self):
        def not_found(body):
            raise RouteNotFound("HTTP 404: not found")

        with self.assertRaises(RouteNotFound):
            run_case(WORDS, not_found, runs=3)
        calls = []

        def later(body):
            calls.append(body)
            if len(calls) == 2:
                raise RouteNotFound("HTTP 404: not found")
            return {"row": {"word": f"w{len(calls)}", "kind": "noun", "rank": 1}, "outcome": "written", "calls": 1,
                    "usage": {}}

        days = run_case(WORDS, later, runs=3)
        self.assertEqual([(day.outcome, day.reason) for day in days],
                         [("written", None), ("error", "HTTP 404"), ("written", None)])

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

    def test_a_refine_passes_only_when_its_rows_from_the_switch_leave_the_first_topic(self):
        refine = next(case for case in CASES if case.id == "refine-cooking")
        spanish = ["sartén", "cuchara", "olla", "picar", "hervir", "sofreír", "ajo", "cebolla", "aceite", "freír",
                   "horno", "pimentón", "rallar", "batir", "jamón"]
        italian = ["mestolo", "soffritto", "tagliere", "mantecare", "pentola", "grattugia", "sbattere", "aglio",
                   "cipolla", "forno", "padella", "frullare", "rosolare", "guanciale", "basilico"]

        def run(later):
            post, _ = answering([{"word": word, "definition": "d"} for word in spanish + later])
            days = run_case(refine, post, runs=30)
            return days, case_summary(refine, days)

        days, summary = run(italian)
        self.assertEqual(summary["refine"], {"switch_at": 16, "repeats_earlier_key": [], "earlier_letters": [],
                                             "passed": True})
        self.assertTrue(summary["passed"])
        self.assertIn("| yes | yes |", summary_table([summary]))

        # Day 16 repeats a Spanish word (in another case and form), and day 20 is Spanish by its letters.
        days, summary = run(["CUCHARA"] + italian[1:4] + ["albóndiga"] + italian[5:])
        self.assertEqual(summary["refine"], {"switch_at": 16, "repeats_earlier_key": [16], "earlier_letters": [20],
                                             "passed": False})
        self.assertFalse(summary["passed"])
        self.assertIn("| no | no |", summary_table([summary]))
        section = automations.rows_section(refine, days)
        self.assertIn("16. CUCHARA / d (repeats day 2)", section)
        self.assertIn("20. albóndiga / d (a letter of the first topic's language)", section)

        # Without a refine there is nothing to check.
        plain = case_summary(WORDS, run_case(WORDS, answering([{"word": "a", "kind": "n", "rank": 1}])[0], runs=1))
        self.assertIsNone(plain["refine"])
        self.assertIn("| - | yes |", summary_table([plain]))


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
        for code, error in ((404, RouteNotFound), (400, RuntimeError), (413, RuntimeError)):
            tries = []

            def urlopen(request, timeout):
                tries.append(request)
                raise urllib.error.HTTPError(request.full_url, code, "No", {}, io.BytesIO(b"refused\n"))

            with mock.patch("automations.urllib.request.urlopen", urlopen):
                with self.assertRaises(error) as caught:
                    automations.poster("https://dev.example", "s")({"prompt": "p"})
            self.assertEqual(len(tries), 1, code)
            self.assertEqual(str(caught.exception), f"HTTP {code}: refused")
            self.assertEqual(type(caught.exception) is RouteNotFound, code == 404)

    def run_main(self, base_url, urlopen, cases="couple-question,stoic-quote"):
        """main's exit code, stdout, and stderr, run with `urlopen` as the network and the results in a temporary
        folder."""
        with tempfile.TemporaryDirectory() as temp:
            secret_file = Path(temp) / "secret"
            secret_file.write_text("s3cret-value\n")
            out, err = io.StringIO(), io.StringIO()
            with mock.patch("automations.ARTIFACTS", Path(temp) / "evals"), \
                    mock.patch("automations.urllib.request.urlopen", urlopen), \
                    contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = automations.main([base_url, str(secret_file), "--cases", cases, "--runs", "30"])
                except SystemExit as exit:
                    code = exit.code
            return code, out.getvalue(), err.getvalue()

    def test_a_404_on_the_first_day_stops_the_run_with_its_own_exit_code(self):
        tries = []

        def urlopen(request, timeout):
            tries.append(json.loads(request.data))
            raise urllib.error.HTTPError(request.full_url, 404, "Not Found", {}, io.BytesIO(b"not found\n"))

        code, out, err = self.run_main("https://dev.example", urlopen)
        self.assertEqual(code, automations.NOT_FOUND_EXIT)
        self.assertEqual(code, 2)
        # At most each case's first day, once (a case that had not started yet is cancelled), and nothing after it.
        self.assertIn(len(tries), (1, 2))
        self.assertEqual(len({body["prompt"] for body in tries}), len(tries))
        self.assertEqual({body["runAt"] for body in tries}, {automations.run_times(1)[0]})
        self.assertIn("Stopped: the first day got HTTP 404: not found.", err)
        self.assertIn("DEV_REGISTRATION_SECRET", err)
        self.assertNotIn("s3cret", out + err)

    def test_the_base_url_is_https_or_plain_http_to_a_local_host_only(self):
        for base, allowed in (("http://dev.example", False), ("http://localhost.example:8787", False),
                              ("ftp://localhost", False), ("localhost:8787", False), ("https://", False),
                              ("http://10.0.0.1:8787", False), ("https://dev.example", True),
                              ("http://localhost:8787", True), ("http://127.0.0.1:8787/", True)):
            urlopen = mock.MagicMock()
            urlopen.return_value.__enter__.return_value.read.return_value = json.dumps(
                {"row": {"question": "Q?"}, "outcome": "written", "calls": 1, "usage": {}}).encode()
            code, _, err = self.run_main(base, urlopen, cases="couple-question")
            if allowed:
                self.assertEqual(urlopen.call_count, 30, base)
                self.assertTrue(urlopen.call_args.args[0].full_url.endswith("/v1/dev/run"), base)
            else:
                self.assertEqual(code, 2, base)
                self.assertIn("must be an https URL", err, base)
                self.assertEqual(urlopen.call_count, 0, base)


class SummaryTests(unittest.TestCase):
    def test_the_table_marks_a_category_case_s_repeats_as_expected_and_adds_totals(self):
        focus = next(case for case in CASES if case.id == "workout-focus")
        days = run_case(focus, answering([{"focus": "Push"}, {"focus": "Push"}])[0], runs=2)
        table = summary_table([case_summary(focus, days)])
        self.assertIn("| workout-focus | 2 | 2 | 2 | 1 (expected) | 1 (expected) |", table)
        self.assertIn("| total | 2 | 2 | 2 |", table)


if __name__ == "__main__":
    unittest.main()
