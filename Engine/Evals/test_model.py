import json
import subprocess
import unittest
from pathlib import Path
from unittest import mock

import model

TESTDATA = Path(__file__).resolve().parent / "testdata"
ANSWER = {
    "type": "result", "is_error": False, "result": "```json\n{}\n```", "duration_api_ms": 4200,
    "usage": {"input_tokens": 10, "cache_read_input_tokens": 20000, "output_tokens": 900},
    "total_cost_usd": 0.01, "modelUsage": {"claude-haiku-5-5": {}},
}


def finished(stdout: str, returncode: int = 0) -> subprocess.CompletedProcess:
    return subprocess.CompletedProcess([], returncode, stdout=stdout, stderr="")


class UserMessageTests(unittest.TestCase):
    def test_claude_receives_the_bytes_run_py_sent_before_the_move(self):
        requests = json.loads((TESTDATA / "requests.json").read_text())
        for name, request in requests.items():
            with self.subTest(name), mock.patch("model.subprocess.run") as run:
                run.return_value = finished(json.dumps(ANSWER) + "\n")
                model.call("haiku", "prompt", model.user_message(request), tries=1, timeout=110, workdir="/tmp")
                self.assertEqual(run.call_args.kwargs["input"], (TESTDATA / f"{name}.jsonl").read_text())

    def test_claude_runs_with_no_tools_no_project_context_and_no_parent_session(self):
        with mock.patch("model.subprocess.run", return_value=finished(json.dumps(ANSWER) + "\n")) as run, \
                mock.patch.dict("model.os.environ", {"CLAUDECODE": "1"}):
            model.call("haiku", "prompt", [], tries=1, timeout=110, workdir="/tmp")
        command, env = run.call_args.args[0], run.call_args.kwargs["env"]
        self.assertEqual(command[command.index("--tools") + 1], "")
        for flag in ("--safe-mode", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence"):
            self.assertIn(flag, command)
        self.assertNotIn("CLAUDECODE", env)

    def test_a_refine_is_refused_until_the_prompt_has_a_refine_mode(self):
        with self.assertRaisesRegex(ValueError, "refine"):
            model.user_message({"words": "make it blue", "current": "{}"})

    def test_a_malformed_request_is_refused(self):
        for request in [
            [],
            {},
            {"words": "  "},
            {"words": "a", "colour": "blue"},
            {"words": "a", "image": {"mime": "image/gif", "base64": "AAAA"}},
            {"words": "a", "image": {"mime": "image/png", "base64": "not base64!"}},
            {"words": "a", "image": {"mime": "image/png", "base64": ""}},
            {"words": "a", "repair": {"document": "{}"}},
        ]:
            with self.subTest(request=request), self.assertRaises(ValueError):
                model.user_message(request)


class CallTests(unittest.TestCase):
    def test_an_answer_reports_its_text_time_and_tokens(self):
        with mock.patch("model.subprocess.run", return_value=finished("noise\n" + json.dumps(ANSWER) + "\n")):
            reply = model.call("haiku", "prompt", [], tries=1, timeout=110, workdir="/tmp")
        self.assertEqual(reply["text"], ANSWER["result"])
        self.assertEqual((reply["input_tokens"], reply["output_tokens"]), (20010, 900))
        self.assertEqual((reply["api_seconds"], reply["models"], reply["transport_retries"]),
                         (4.2, ["claude-haiku-5-5"], 0))

    def test_a_failed_try_is_tried_again_while_tries_remain(self):
        failure = finished(json.dumps({**ANSWER, "is_error": True}) + "\n", returncode=1)
        with mock.patch("model.subprocess.run", side_effect=[failure, finished(json.dumps(ANSWER))]), \
                mock.patch("model.time.sleep"):
            self.assertEqual(model.call("haiku", "p", [], tries=2, timeout=1, workdir="/tmp")["transport_retries"], 1)

    def test_one_try_fails_at_once_with_the_timeout_it_was_given(self):
        timeout = subprocess.TimeoutExpired("claude", 110)
        with mock.patch("model.subprocess.run", side_effect=timeout) as run, mock.patch("model.time.sleep") as sleep:
            with self.assertRaisesRegex(model.ModelError, "timed out after 110 s"):
                model.call("haiku", "p", [], tries=1, timeout=110, workdir="/tmp")
        self.assertEqual((run.call_count, run.call_args.kwargs["timeout"], sleep.call_count), (1, 110, 0))


class ExtractTests(unittest.TestCase):
    def test_the_document_is_found_in_the_reply(self):
        for case in json.loads((TESTDATA / "extract.json").read_text()):
            with self.subTest(case["name"]):
                self.assertEqual(model.extract(case["reply"]), case["document"])


if __name__ == "__main__":
    unittest.main()
