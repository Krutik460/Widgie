#!/usr/bin/env python3
"""Builds widgets from plain requests with a model and proves each one with the real engine.

For each case and model: send the build prompt and the person's request to the model, write the reply as a
widget directory, and run `render-tool proof` on it. On a rejection, send the request, the previous document,
and the verdict line back, at most twice. Everything lands in Engine/.artifacts/evals/<run name>/. Running the
same name again picks up where the last run stopped: finished builds and finished model calls are kept.

    run.py <run name> [--models haiku,sonnet] [--cases id,id] [--jobs 6] [--stop-after SECONDS]

Needs the release render tool: `swift build -c release --build-system native` in Engine/.
"""

import argparse
import base64
import json
import os
import re
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from collections import Counter
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path

import sheet

EVALS = Path(__file__).resolve().parent
ENGINE = EVALS.parent
REFERENCE = ENGINE / "Reference"
RENDER_TOOL = ENGINE / ".build" / "release" / "render-tool"
ARTIFACTS = ENGINE / ".artifacts" / "evals"

# Proofs render at one fixed instant, so a rerun of the same reply gets the same verdict.
PROOF_DATE = "2026-11-18T09:00:00Z"
# The first try, then at most two repairs.
ATTEMPTS = 3
STATUS = {1: "first try", 2: "repaired once", 3: "repaired twice", None: "failed"}
MEDIA_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


@dataclass(frozen=True)
class Case:
    id: str
    group: str
    request: str
    image: Path | None


@dataclass(frozen=True)
class Run:
    directory: Path
    system_prompt: str
    workdir: str
    deadline: float | None


class Deferred(Exception):
    """The run reached --stop-after before this build's next model call."""


class ModelError(Exception):
    pass


class ProofError(Exception):
    pass


def load_cases() -> tuple[list[str], list[Case]]:
    raw = json.loads((EVALS / "cases.json").read_text())
    groups = raw["groups"]
    cases = []
    for entry in raw["cases"]:
        image = EVALS / entry["image"] if entry.get("image") else None
        if entry["group"] not in groups:
            sys.exit(f"cases.json: case {entry['id']} has unknown group {entry['group']!r}")
        if image and image.suffix.lower() not in MEDIA_TYPES:
            sys.exit(f"cases.json: case {entry['id']} needs a PNG or JPEG, not {image.name}")
        if image and not image.exists():
            sys.exit(f"cases.json: case {entry['id']} names a missing image {image}")
        cases.append(Case(entry["id"], entry["group"], entry["request"], image))
    ids = [c.id for c in cases]
    if len(ids) != len(set(ids)):
        sys.exit("cases.json: case ids must be unique")
    return groups, cases


def compose_system_prompt() -> str:
    """Reference/build-prompt.md with each {{include file}} line replaced and every HTML comment removed."""
    text = (REFERENCE / "build-prompt.md").read_text()
    text = re.sub(r"^\{\{include ([^}]+)\}\}$", lambda m: (REFERENCE / m.group(1)).read_text(), text, flags=re.M)
    return re.sub(r"<!--.*?-->\s*", "", text, flags=re.S).strip() + "\n"


def repair_message(case: Case, document: str, verdict: str) -> str:
    return (
        f"The person's request:\n\n{case.request}\n\n"
        f"Your previous document:\n\n```json\n{document}\n```\n\n"
        f"The line from the app:\n\n{verdict}\n\n"
        "Reply with the complete corrected document."
    )


def message_content(case: Case, text: str) -> list[dict]:
    content = []
    if case.image:
        data = base64.b64encode(case.image.read_bytes()).decode()
        media_type = MEDIA_TYPES[case.image.suffix.lower()]
        content.append({"type": "image", "source": {"type": "base64", "media_type": media_type, "data": data}})
    content.append({"type": "text", "text": text})
    return content


def call_model(model: str, system_prompt: str, content: list[dict], workdir: str) -> dict:
    """One near-raw model call through Claude Code: our system prompt, no tools, no project context.

    Transport failures are retried twice. Only the call that answered is timed.
    """
    command = [
        "claude", "-p", "--model", model, "--safe-mode", "--system-prompt", system_prompt,
        "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
        "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    ]
    message = json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n"
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    failure = ""
    for retry in range(3):
        started = time.monotonic()
        try:
            proc = subprocess.run(
                command, input=message, capture_output=True, text=True, cwd=workdir, env=env, timeout=900)
        except subprocess.TimeoutExpired:
            failure = "timed out after 900 s"
            continue
        seconds = time.monotonic() - started
        result = None
        for line in proc.stdout.splitlines():
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "result":
                result = event
        if result and not result.get("is_error") and isinstance(result.get("result"), str) and result["result"].strip():
            usage = result.get("usage") or {}
            return {
                "text": result["result"],
                "seconds": round(seconds, 1),
                "api_seconds": round((result.get("duration_api_ms") or 0) / 1000, 1),
                "input_tokens": sum(
                    usage.get(key) or 0
                    for key in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")),
                "output_tokens": usage.get("output_tokens") or 0,
                "cost_usd": result.get("total_cost_usd"),
                "models": sorted((result.get("modelUsage") or {}).keys()),
                "transport_retries": retry,
            }
        failure = f"exit {proc.returncode}: {json.dumps(result)[:300] if result else proc.stdout[-300:]} {proc.stderr[-300:]}"
        time.sleep(5)
    raise ModelError(f"{model} failed three times; last: {failure}")


def extract_document(reply: str) -> str:
    """The fenced json block of a reply, else its longest fenced block, else the whole reply.

    A JSON string holds no raw line break, so inside the document no line can start with a fence.
    """
    lines = reply.splitlines()
    blocks: list[tuple[str, str]] = []
    index = 0
    while index < len(lines):
        opening = re.fullmatch(r"```([A-Za-z0-9_-]*)\s*", lines[index])
        if not opening:
            index += 1
            continue
        end = index + 1
        while end < len(lines) and lines[end].strip() != "```":
            end += 1
        blocks.append((opening.group(1), "\n".join(lines[index + 1:end])))
        index = end + 1
    if not blocks:
        return reply.strip()
    tagged = [body for info, body in blocks if info == "json"]
    return max(tagged or [body for _, body in blocks], key=len)


def parsed(document: str) -> dict:
    try:
        value = json.loads(document)
    except json.JSONDecodeError:
        return {}
    return value if isinstance(value, dict) else {}


def write_widget(directory: Path, document: str, case: Case) -> None:
    """The reply as the app would hand it to the engine: the document exactly as written, plus the person's
    picture as asset `reference` when the document declares that asset."""
    shutil.rmtree(directory, ignore_errors=True)
    directory.mkdir(parents=True)
    (directory / "widget.json").write_text(document)
    assets = parsed(document).get("assets")
    if case.image and isinstance(assets, dict) and assets.get("reference") is not None:
        (directory / "assets").mkdir()
        shutil.copyfile(case.image, directory / "assets" / f"reference{case.image.suffix.lower()}")


def prove(widget: Path, output: Path) -> str | None:
    """The verdict line `build` would send, or None when it would save the widget."""
    shutil.rmtree(output, ignore_errors=True)
    proc = subprocess.run(
        [str(RENDER_TOOL), "proof", str(widget), str(output), "--date", PROOF_DATE],
        capture_output=True, text=True, timeout=600)
    line = proc.stdout.strip()
    if proc.returncode == 0 and line == "accepted":
        return None
    if proc.returncode == 1 and line:
        return line
    raise ProofError(f"render-tool proof {widget} exited {proc.returncode}: {proc.stderr.strip()[-300:]}")


def write_json(path: Path, value) -> None:
    """Whole or not at all: a crash never leaves a half-written record that a rerun would trust."""
    temporary = path.with_name(path.name + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, ensure_ascii=False) + "\n")
    os.replace(temporary, path)


def read_json(path: Path):
    return json.loads(path.read_text())


def run_attempt(run: Run, case: Case, model: str, directory: Path, previous: tuple[str, str] | None) -> dict:
    """One model call and its proof. A finished attempt is read back. A reply saved before a crash is proved
    again instead of asking the model a second time."""
    record_path = directory / "attempt.json"
    if record_path.exists():
        return read_json(record_path)
    reply_path = directory / "reply.json"
    if reply_path.exists():
        reply = read_json(reply_path)
    else:
        if run.deadline is not None and time.monotonic() > run.deadline:
            raise Deferred()
        text = case.request if previous is None else repair_message(case, *previous)
        directory.mkdir(parents=True, exist_ok=True)
        (directory / "message.md").write_text(text + (f"\n\n[image: {case.image.name}]\n" if case.image else "\n"))
        reply = call_model(model, run.system_prompt, message_content(case, text), run.workdir)
        write_json(reply_path, reply)
    document = extract_document(reply["text"])
    write_widget(directory / "widget", document, case)
    verdict = prove(directory / "widget", directory / "proof")
    fields = parsed(document)
    record = {
        "attempt": int(directory.name),
        "verdict": verdict,
        "seconds": reply["seconds"],
        "api_seconds": reply["api_seconds"],
        "input_tokens": reply["input_tokens"],
        "output_tokens": reply["output_tokens"],
        "cost_usd": reply["cost_usd"],
        "models": reply["models"],
        "document_bytes": len(document.encode()),
        "look_bytes": len(fields["look"].encode()) if isinstance(fields.get("look"), str) else None,
        "samples": len(fields["samples"]) if isinstance(fields.get("samples"), dict) else 0,
        "uses_reference": (directory / "widget" / "assets").exists(),
    }
    write_json(record_path, record)
    return record


def run_build(run: Run, case: Case, model: str) -> dict:
    build_dir = run.directory / case.id / model
    record_path = build_dir / "build.json"
    if record_path.exists():
        return read_json(record_path)
    attempts: list[dict] = []
    for number in range(1, ATTEMPTS + 1):
        previous = None
        if attempts:
            document = (build_dir / str(number - 1) / "widget" / "widget.json").read_text()
            previous = (document, attempts[-1]["verdict"])
        attempts.append(run_attempt(run, case, model, build_dir / str(number), previous))
        if attempts[-1]["verdict"] is None:
            break
    accepted = attempts[-1]["attempt"] if attempts[-1]["verdict"] is None else None
    final = build_dir / str(attempts[-1]["attempt"]) / "proof"
    record = {
        "case": case.id,
        "group": case.group,
        "model": model,
        "status": STATUS[accepted],
        "accepted_attempt": accepted,
        "verdicts": [a["verdict"] for a in attempts if a["verdict"]],
        "calls": len(attempts),
        "seconds": round(sum(a["seconds"] for a in attempts), 1),
        "input_tokens": sum(a["input_tokens"] for a in attempts),
        "output_tokens": sum(a["output_tokens"] for a in attempts),
        "final_report": str((final / "report.json").relative_to(run.directory)),
        "final_pngs": sorted(str(p.relative_to(run.directory)) for p in final.glob("*.png")),
        "attempts": attempts,
    }
    write_json(record_path, record)
    return record


def verdict_kind(line: str) -> str:
    """A verdict with its names, numbers, and paths blanked, so lines of one kind count together."""
    line = re.sub(r'^(small|medium)(, (empty|full|sample "[^"]*"))?: ', "", line)
    line = re.sub(r'"[^"]*"', '"x"', line)
    line = re.sub(r"'[^']*'", "'x'", line)
    line = re.sub(r"\broot[\w.\[\]]*", "PATH", line)
    return re.sub(r"\d+(\.\d+)?", "N", line)


def summarize(run_dir: Path, groups: list[str], cases: list[Case], models: list[str]) -> dict:
    builds = []
    for case in cases:
        for model in models:
            path = run_dir / case.id / model / "build.json"
            if path.exists():
                builds.append(read_json(path))
    table = {
        group: {
            model: Counter(b["status"] for b in builds if b["group"] == group and b["model"] == model)
            for model in models}
        for group in groups}
    per_model = {}
    for model in models:
        mine = [b for b in builds if b["model"] == model]
        calls = [a for b in mine for a in b["attempts"]]
        if not mine:
            continue
        per_model[model] = {
            "builds": len(mine),
            "calls": len(calls),
            "model_ids": sorted({m for a in calls for m in a["models"]}),
            "seconds_per_call_median": statistics.median(a["seconds"] for a in calls),
            "output_tokens_per_call_median": statistics.median(a["output_tokens"] for a in calls),
            "input_tokens_per_call_median": statistics.median(a["input_tokens"] for a in calls),
            "seconds_per_build_median": statistics.median(b["seconds"] for b in mine),
            "seconds_per_build_mean": round(statistics.mean(b["seconds"] for b in mine), 1),
            "output_tokens_per_build_mean": round(statistics.mean(b["output_tokens"] for b in mine)),
            "document_bytes_median": statistics.median(a["document_bytes"] for a in calls),
        }
    kinds = Counter(verdict_kind(v) for b in builds for v in b["verdicts"])
    summary = {
        "run": run_dir.name,
        "proof_date": PROOF_DATE,
        "builds": len(builds),
        "expected": len(cases) * len(models),
        "table": {g: {m: dict(c) for m, c in row.items()} for g, row in table.items()},
        "per_model": per_model,
        "verdict_kinds": kinds.most_common(),
    }
    write_json(run_dir / "results.json", summary)

    order = ["first try", "repaired once", "repaired twice", "failed"]
    print(f"\n{run_dir.name}: {len(builds)} of {len(cases) * len(models)} builds finished")
    print(f"{'group':<20}" + "".join(f"{m:>26}" for m in models))
    print(f"{'':<20}" + "".join(f"{'first/once/twice/failed':>26}" for _ in models))
    for group, row in table.items():
        cells = "".join(f"{'/'.join(str(row[m][s]) for s in order):>26}" for m in models)
        print(f"{group:<20}{cells}")
    for model, stats in per_model.items():
        print(f"{model}: {stats}")
    print("verdict kinds:")
    for kind, count in kinds.most_common(12):
        print(f"  {count:>3}  {kind}")
    return summary


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run", help="the run's name, a folder under Engine/.artifacts/evals/")
    parser.add_argument("--models", default="haiku,sonnet")
    parser.add_argument("--cases", default="", help="comma-separated case ids; all cases when left out")
    parser.add_argument("--jobs", type=int, default=6, help="builds that run at once")
    parser.add_argument("--stop-after", type=float, help="start no model call after this many seconds")
    args = parser.parse_args()

    if not RENDER_TOOL.exists():
        sys.exit(f"no {RENDER_TOOL}; run swift build -c release --build-system native in {ENGINE}")
    groups, cases = load_cases()
    models = [m for m in args.models.split(",") if m]
    wanted = [c for c in args.cases.split(",") if c]
    unknown = set(wanted) - {c.id for c in cases}
    if unknown:
        sys.exit(f"unknown case ids: {', '.join(sorted(unknown))}")
    selected = [c for c in cases if not wanted or c.id in wanted]

    run_dir = ARTIFACTS / args.run
    run_dir.mkdir(parents=True, exist_ok=True)
    system_prompt = compose_system_prompt()
    prompt_path = run_dir / "system-prompt.md"
    if prompt_path.exists() and prompt_path.read_text() != system_prompt:
        sys.exit(f"{run_dir} was run with a different system prompt; give this run a new name")
    prompt_path.write_text(system_prompt)

    workdir = tempfile.mkdtemp(prefix="widget-eval-")
    deadline = time.monotonic() + args.stop_after if args.stop_after else None
    run = Run(run_dir, system_prompt, workdir, deadline)
    pending = 0
    with ThreadPoolExecutor(max_workers=args.jobs) as pool:
        futures = {pool.submit(run_build, run, c, m): (c, m) for c in selected for m in models}
        for future in as_completed(futures):
            case, model = futures[future]
            try:
                build = future.result()
            except Deferred:
                pending += 1
                print(f"{case.id} {model}: stopped at --stop-after; run again to resume", flush=True)
                continue
            except (ModelError, ProofError) as error:
                pending += 1
                print(f"{case.id} {model}: did not finish: {error}", flush=True)
                continue
            verdicts = "".join(f"\n    {v}" for v in build["verdicts"])
            print(f"{case.id} {model}: {build['status']} in {build['calls']} calls, {build['seconds']} s{verdicts}",
                  flush=True)
    shutil.rmtree(workdir, ignore_errors=True)

    summarize(run_dir, groups, cases, models)
    print(f"contact sheet: {sheet.write(run_dir)}")
    if pending:
        print(f"{pending} builds did not finish; run the same command again to resume")


if __name__ == "__main__":
    main()
