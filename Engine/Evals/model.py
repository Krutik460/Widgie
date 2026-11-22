"""The model call shared by the eval harness and the dev bridge.

A request is the app's ModelRequest as a dict: `words`, optional `image` {mime, base64}, optional `current`,
and optional `repair` {document, line}. `user_message` turns it into the message content, `call` sends it with
the build prompt through Claude Code, and `extract` finds the document in the reply.
"""

import base64
import json
import os
import re
import subprocess
import time
from pathlib import Path

REFERENCE = Path(__file__).resolve().parent.parent / "Reference"
MEDIA_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg"}


class ModelError(Exception):
    pass


def compose_prompt() -> str:
    """Reference/build-prompt.md with each {{include file}} line replaced and every HTML comment removed."""
    text = (REFERENCE / "build-prompt.md").read_text()
    text = re.sub(r"^\{\{include ([^}]+)\}\}$", lambda m: (REFERENCE / m.group(1)).read_text(), text, flags=re.M)
    return re.sub(r"<!--.*?-->\s*", "", text, flags=re.S).strip() + "\n"


def user_message(request: dict) -> list[dict]:
    """The content blocks for one request. Raises ValueError for a request this module cannot send."""
    if not isinstance(request, dict):
        raise ValueError("the request must be a JSON object")
    unknown = set(request) - {"words", "image", "current", "repair"}
    if unknown:
        raise ValueError(f"unknown request fields: {', '.join(sorted(unknown))}")
    words = request.get("words")
    if not isinstance(words, str) or not words.strip():
        raise ValueError('"words" must be a non-empty string')
    if request.get("current") is not None:
        raise ValueError('"current" (refine) is not supported yet')

    text = words
    repair = request.get("repair")
    if repair is not None:
        if not isinstance(repair, dict) or not all(isinstance(repair.get(k), str) for k in ("document", "line")):
            raise ValueError('"repair" must hold "document" and "line" strings')
        text = (
            f"The person's request:\n\n{words}\n\n"
            f"Your previous document:\n\n```json\n{repair['document']}\n```\n\n"
            f"The line from the app:\n\n{repair['line']}\n\n"
            "Reply with the complete corrected document."
        )

    content = []
    image = request.get("image")
    if image is not None:
        if not isinstance(image, dict) or image.get("mime") not in MEDIA_TYPES.values():
            raise ValueError(f'"image" must hold a "mime" of {" or ".join(sorted(set(MEDIA_TYPES.values())))}')
        data = image.get("base64")
        try:
            base64.b64decode(data, validate=True)
        except (TypeError, ValueError):
            raise ValueError('"image" must hold "base64" image data') from None
        content.append({"type": "image", "source": {"type": "base64", "media_type": image["mime"], "data": data}})
    content.append({"type": "text", "text": text})
    return content


def call(model: str, prompt: str, content: list[dict], *, tries: int, timeout: float, workdir: str) -> dict:
    """One near-raw model call through Claude Code: our system prompt, no tools, no project context.

    A transport failure is tried again until `tries` run out. Only the call that answered is timed.
    """
    command = [
        "claude", "-p", "--model", model, "--safe-mode", "--system-prompt", prompt,
        "--tools", "", "--strict-mcp-config", "--disable-slash-commands", "--no-session-persistence",
        "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
    ]
    message = json.dumps({"type": "user", "message": {"role": "user", "content": content}}) + "\n"
    env = {k: v for k, v in os.environ.items() if k != "CLAUDECODE"}
    failure = ""
    for retry in range(tries):
        started = time.monotonic()
        try:
            proc = subprocess.run(
                command, input=message, capture_output=True, text=True, cwd=workdir, env=env, timeout=timeout)
        except subprocess.TimeoutExpired:
            failure = f"timed out after {timeout:g} s"
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
        if retry < tries - 1:
            time.sleep(5)
    raise ModelError(f"{model} gave no answer in {tries} {'try' if tries == 1 else 'tries'}; last: {failure}")


def extract(reply: str) -> str:
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
