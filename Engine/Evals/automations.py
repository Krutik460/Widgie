#!/usr/bin/env python3
"""Runs automations for 30 days in a row against the dev Worker and counts invalid rows and repeats.

Each case is one automation: the owner's prompt and the table's fields. A day is one call to the dev Worker's
POST /v1/dev/run (Backend/src/dev-run.ts), which runs the consumer's model calls (the run prompt, the JSON schema,
the reply checks, the repeat rule, and the repair) with the real model, and writes nothing. Each row it answers is
fed back as the newest of the recent rows of the next day, the last 60 as the consumer reads them, so the run
simulates consecutive days of one widget. A refine case switches to its second prompt halfway, on the same history.

For every case it records each day's row, outcome, refusal reason, model calls, and cost; counts invalid rows,
exact repeats (every text field the same, ignoring case and surrounding space) and near repeats (the case's key
field the same); and writes everything to Engine/.artifacts/evals/<name>/, with summary.md and summary.json.

    python3 -I Engine/Evals/automations.py <base url> <secret file> [--cases id,id] [--runs 30] [--name NAME]

The secret file holds the dev Worker's DEV_REGISTRATION_SECRET. It is sent in a header and never printed.
"""

import argparse
import json
import sys
import time
import urllib.error
import urllib.request
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timedelta
from pathlib import Path
from zoneinfo import ZoneInfo

EVALS = Path(__file__).resolve().parent
ARTIFACTS = EVALS.parent / ".artifacts" / "evals"

# The consumer reads back this many of a dataset's rows (RECENT_ROWS in Backend/src/run.ts).
RECENT_ROWS = 60
RUNS = 30
ZONE = "America/New_York"
# The first simulated day's run: 06:00 in ZONE, then one day later each run.
FIRST_DAY = (2026, 12, 1)
RUN_TIME = (6, 0)
# Cloudflare refuses Python's default User-Agent.
USER_AGENT = "widgie-evals/1"
# Above the Worker's 95 s model deadline, twice for a repair.
TIMEOUT_S = 200
# Tries of one day's request when the Worker itself fails (a network error or a status other than 200).
TRIES = 3


@dataclass(frozen=True)
class Case:
    id: str
    prompt: str
    fields: dict
    # The field whose repeat alone is a near repeat: the item itself, such as the word or the question.
    key: str
    # A refine: from day `switch_at` (1-based) on, the automation runs `refined` instead of `prompt`.
    refined: str | None = None
    switch_at: int | None = None
    # A table whose key only names a category: the values it may hold. Its repeats are expected, not failures.
    allowed: tuple = ()
    # Text fields the owner's prompt leaves empty, which a valid row may hold as "".
    may_be_empty: tuple = ()

    def prompt_on(self, day: int) -> str:
        return self.refined if self.refined and self.switch_at and day >= self.switch_at else self.prompt


SPANISH = ("Pick a Spanish cooking word, such as an ingredient, a utensil, or a kitchen verb, that a home cook "
           "learning Spanish may not know yet. Give the word in Spanish and its meaning in a few plain English "
           "words starting in lower case.")
ITALIAN = ("Pick an Italian cooking word, such as an ingredient, a utensil, or a kitchen verb, that a home cook "
           "learning Italian may not know yet. Give the word in Italian and its meaning in a few plain English "
           "words starting in lower case.")

CASES = [
    Case(
        id="nursing-terms",
        prompt=("Pick a medical term a nursing student should know for their exam, and not one picked before. Give "
                "the term, its part of speech, a plain English definition in one sentence, and one short example "
                "sentence a nurse might say on a ward."),
        fields={"word": "text", "kind": "text", "definition": "text", "example": "text"},
        key="word",
    ),
    Case(id="spanish-cooking", prompt=SPANISH, fields={"word": "text", "definition": "text"}, key="word"),
    Case(
        id="stoic-quote",
        prompt=("A short quote from a Stoic writer, such as Marcus Aurelius, Seneca, or Epictetus, at most 140 "
                "characters, in a well-known English translation, with the writer's name."),
        fields={"quote": "text", "author": "text"},
        key="quote",
    ),
    Case(
        id="couple-question",
        prompt=("Write one warm, specific question for a couple to ask each other today, in plain words, at most 70 "
                "characters, ending in a question mark. Make it playful or tender, never heavy."),
        fields={"question": "text"},
        key="question",
    ),
    Case(
        id="workout-focus",
        prompt="Today's workout focus: Push, Pull or Legs. Answer with just the one word.",
        fields={"focus": "text"},
        key="focus",
        allowed=("push", "pull", "legs"),
    ),
    Case(id="refine-cooking", prompt=SPANISH, fields={"word": "text", "definition": "text"}, key="word",
         refined=ITALIAN, switch_at=16),
]


@dataclass
class Day:
    day: int
    prompt: str
    run_at: int
    outcome: str
    row: dict | None
    reason: str | None = None
    calls: int = 0
    cost_usd: float | None = None
    usage: dict = field(default_factory=dict)
    seconds: float | None = None
    problems: list = field(default_factory=list)
    exact_repeat_of: int | None = None
    near_repeat_of: int | None = None


def run_times(runs: int, zone: str = ZONE) -> list[int]:
    """Each day's run time in milliseconds: RUN_TIME on consecutive local days from FIRST_DAY, across DST."""
    first = datetime(*FIRST_DAY, *RUN_TIME, tzinfo=ZoneInfo(zone))
    times = []
    for offset in range(runs):
        local = datetime.combine(first.date() + timedelta(days=offset), first.timetz())
        times.append(int(local.timestamp() * 1000))
    return times


def recent_row(case: Case, row: dict) -> dict:
    """A row as the consumer reads it back: only its text values (Backend/src/runner.ts, recentRows)."""
    return {name: row[name] for name, kind in case.fields.items() if kind == "text" and isinstance(row.get(name), str)}


def comparable(text: str) -> str:
    return text.strip().lower()


def problems_of(case: Case, row: dict) -> list[str]:
    """What makes a written row unusable for the widget beyond what the Worker checks: a text field left empty that
    the prompt asks for, or a category outside its values."""
    found = []
    for name, kind in case.fields.items():
        value = row.get(name)
        if kind == "text" and name not in case.may_be_empty and (not isinstance(value, str) or not value.strip()):
            found.append(f'"{name}" is empty')
    if case.allowed and comparable(str(row.get(case.key, ""))) not in case.allowed:
        found.append(f'"{case.key}" is not one of {", ".join(case.allowed)}')
    return found


def run_case(case: Case, post, runs: int = RUNS, log=lambda line: None) -> list[Day]:
    """Runs the case's automation for `runs` consecutive days through `post`, which takes a /v1/dev/run body and
    answers the Worker's JSON (or raises). Each written row becomes the newest recent row of the days after it."""
    history: list[dict] = []
    days: list[Day] = []
    for number, run_at in enumerate(run_times(runs), start=1):
        prompt = case.prompt_on(number)
        recent = [recent_row(case, row) for row in reversed(history[-RECENT_ROWS:])]
        recent = [row for row in recent if row]
        body = {"prompt": prompt, "fields": case.fields, "timeZone": ZONE, "runAt": run_at, "recent": recent}
        try:
            answer = post(body)
        except Exception as error:
            day = Day(number, prompt, run_at, "error", None, reason=str(error).splitlines()[0][:200])
        else:
            usage = answer.get("usage") or {}
            day = Day(number, prompt, run_at, answer.get("outcome", "error"), answer.get("row"),
                      reason=answer.get("reason"), calls=answer.get("calls", 0), cost_usd=usage.get("cost_usd"),
                      usage=usage, seconds=answer.get("seconds"))
        if day.row is not None:
            day.problems = problems_of(case, day.row)
            texts = recent_row(case, day.row)
            for earlier in days:
                if earlier.row is None:
                    continue
                before = recent_row(case, earlier.row)
                if day.exact_repeat_of is None and texts and \
                        {k: comparable(v) for k, v in texts.items()} == {k: comparable(v) for k, v in before.items()}:
                    day.exact_repeat_of = earlier.day
                key, earlier_key = texts.get(case.key), before.get(case.key)
                if day.near_repeat_of is None and key and earlier_key and comparable(key) == comparable(earlier_key):
                    day.near_repeat_of = earlier.day
            history.append(day.row)
        days.append(day)
        log(f"{case.id} day {number}: {day.outcome}" + (f" ({day.reason})" if day.reason else ""))
    return days


def case_summary(case: Case, days: list[Day]) -> dict:
    written = [day for day in days if day.row is not None]
    costs = [day.cost_usd for day in days if day.cost_usd is not None]
    reasons: dict = {}
    for day in days:
        if day.reason:
            reasons[day.reason] = reasons.get(day.reason, 0) + 1
    return {
        "case": case.id,
        "runs": len(days),
        "written": len(written),
        "retry": sum(day.outcome == "retry" for day in days),
        "errors": sum(day.outcome == "error" for day in days),
        "valid": sum(not day.problems for day in written),
        "exact_repeats": sum(day.exact_repeat_of is not None for day in written),
        "near_repeats": sum(day.near_repeat_of is not None for day in written),
        "repeats_expected": bool(case.allowed),
        "calls": sum(day.calls for day in days),
        "repaired": sum(day.calls > 1 for day in days),
        "reasons": reasons,
        "cost_usd": round(sum(costs), 6) if costs else None,
        "cost_known_for": len(costs),
        "output_tokens": sum(day.usage.get("output_tokens", 0) for day in days),
        "passed": len(written) == len(days) and all(not day.problems for day in written)
        and (bool(case.allowed) or not any(day.near_repeat_of is not None for day in written)),
    }


def summary_table(summaries: list[dict]) -> str:
    """A Markdown table: one line per case, then the totals. A category case's repeats are marked as expected."""
    lines = [
        "| case | runs | written | valid | exact repeats | near repeats | retry | errors | calls | repaired | "
        "cost (USD) | passed |",
        "|---|---|---|---|---|---|---|---|---|---|---|---|",
    ]
    for s in summaries:
        expected = " (expected)" if s["repeats_expected"] else ""
        cost = "?" if s["cost_usd"] is None else f"{s['cost_usd']:.4f}"
        lines.append(f"| {s['case']} | {s['runs']} | {s['written']} | {s['valid']} | {s['exact_repeats']}{expected} | "
                     f"{s['near_repeats']}{expected} | {s['retry']} | {s['errors']} | {s['calls']} | {s['repaired']} | "
                     f"{cost} | {'yes' if s['passed'] else 'no'} |")
    total_cost = sum(s["cost_usd"] or 0 for s in summaries)
    lines.append(f"| total | {sum(s['runs'] for s in summaries)} | {sum(s['written'] for s in summaries)} | "
                 f"{sum(s['valid'] for s in summaries)} | | | {sum(s['retry'] for s in summaries)} | "
                 f"{sum(s['errors'] for s in summaries)} | {sum(s['calls'] for s in summaries)} | "
                 f"{sum(s['repaired'] for s in summaries)} | {total_cost:.4f} | "
                 f"{sum(s['passed'] for s in summaries)}/{len(summaries)} |")
    return "\n".join(lines)


def rows_section(case: Case, days: list[Day]) -> str:
    """Every day's row, to read for topic and quality, with its repeats and problems marked."""
    lines = [f"## {case.id}", ""]
    if case.refined:
        lines.append(f"Days {case.switch_at} on run the refined prompt.\n")
    for day in days:
        marks = []
        if day.exact_repeat_of:
            marks.append(f"repeats day {day.exact_repeat_of}")
        elif day.near_repeat_of:
            marks.append(f"{case.key} as on day {day.near_repeat_of}")
        marks += day.problems
        if day.row is None:
            marks.append(f"{day.outcome}: {day.reason}")
        cells = " / ".join(str(value) for value in (day.row or {}).values())
        lines.append(f"{day.day}. {cells}" + (f" ({'; '.join(marks)})" if marks else ""))
    return "\n".join(lines)


def poster(base_url: str, secret: str):
    """A `post` for run_case that sends a body to the Worker, trying a failed request again up to TRIES times."""
    url = base_url.rstrip("/") + "/v1/dev/run"

    def post(body: dict) -> dict:
        data = json.dumps(body).encode()
        last = None
        for attempt in range(TRIES):
            request = urllib.request.Request(url, data=data, method="POST", headers={
                "Content-Type": "application/json",
                "User-Agent": USER_AGENT,
                "X-Widgie-Dev-Secret": secret,
            })
            try:
                with urllib.request.urlopen(request, timeout=TIMEOUT_S) as response:
                    return json.loads(response.read())
            except urllib.error.HTTPError as error:
                with error:
                    text = error.read().decode(errors="replace").strip()
                last = f"HTTP {error.code}: {text[:200]}"
                if error.code in (400, 404, 413):
                    break
            except (urllib.error.URLError, TimeoutError, OSError) as error:
                last = f"request failed: {error}"
            time.sleep(2 * (attempt + 1))
        raise RuntimeError(last)

    return post


def write_json(path: Path, value) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("base_url", help="the dev Worker, such as https://widgie-dev.<account>.workers.dev")
    parser.add_argument("secret_file", type=Path, help="a file holding DEV_REGISTRATION_SECRET")
    parser.add_argument("--cases", help="comma-separated case ids (default: all)")
    parser.add_argument("--runs", type=int, default=RUNS)
    parser.add_argument("--name", default="p5-automations", help="the folder under Engine/.artifacts/evals/")
    args = parser.parse_args(argv)

    secret = args.secret_file.read_text().strip()
    if not secret:
        parser.error(f"{args.secret_file} is empty")
    cases = CASES
    if args.cases:
        wanted = args.cases.split(",")
        unknown = sorted(set(wanted) - {case.id for case in CASES})
        if unknown:
            parser.error(f"unknown cases: {', '.join(unknown)}")
        cases = [case for case in CASES if case.id in wanted]

    out = ARTIFACTS / args.name
    post = poster(args.base_url, secret)
    # Cases run side by side, each day of a case after the one before it.
    with ThreadPoolExecutor(max_workers=len(cases)) as pool:
        results = list(pool.map(lambda case: run_case(case, post, args.runs, log=print), cases))

    summaries = []
    for case, days in zip(cases, results):
        summary = case_summary(case, days)
        summaries.append(summary)
        write_json(out / f"{case.id}.json", {"case": case.__dict__, "summary": summary,
                                              "days": [day.__dict__ for day in days]})
    table = summary_table(summaries)
    write_json(out / "summary.json", summaries)
    sections = "\n\n".join(rows_section(case, days) for case, days in zip(cases, results))
    (out / "summary.md").write_text(f"# Automation evals: {args.runs} days a case\n\n{table}\n\n{sections}\n")
    print(f"\n{table}\n\nWritten to {out}")
    return 0 if all(summary["passed"] for summary in summaries) else 1


if __name__ == "__main__":
    sys.exit(main())
