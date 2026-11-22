#!/usr/bin/env python3
"""The dev stand-in for the model service: the app posts a ModelRequest, local Claude Code answers.

    bridge.py [--model haiku|sonnet]

POST /v1/reply takes a ModelRequest as JSON and returns {"reply": "<raw text>", "seconds": <model seconds>,
"model": "<id>"}. It answers only a local Host and a Content-Type of application/json (403 and 415 otherwise),
and a body over 20 MB is a 413. A body this bridge cannot send is a 400 and a failed model call is a 502, each
with {"error": "<one line>"}. A reply without a fenced document is still a 200, because the app's build rejects it
like any other bad document. GET /health prints ok. Each request logs one line to stdout.
"""

import argparse
import json
import shutil
import signal
import tempfile
import time
from datetime import datetime
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

from model import ModelError, call, compose_prompt, user_message

ADDRESS = ("127.0.0.1", 8787)
# One try that ends before the app's 120 s request timeout, so no model call outlives its request.
TRIES = 1
TIMEOUT = 110
MAX_BODY = 20 * 1024 * 1024


def one_line(text: str) -> str:
    return " ".join(text.split())


def kind(request) -> str:
    if not isinstance(request, dict):
        return "-"
    if request.get("repair") is not None:
        return "repair"
    return "refine" if request.get("current") is not None else "create"


def handler(model: str, prompt: str, workdir: str) -> type[BaseHTTPRequestHandler]:
    class Handler(BaseHTTPRequestHandler):
        def do_GET(self):
            if self.path != "/health":
                return self.send(404, "text/plain", b"not found\n")
            self.send(200, "text/plain", b"ok\n")

        def do_POST(self):
            if self.path != "/v1/reply":
                return self.send(404, "text/plain", b"not found\n")
            started = time.monotonic()
            request = None
            # A web page can send a text/plain POST with no preflight, and a rebound DNS name reaches 127.0.0.1
            # under its own Host. Requiring JSON and a local Host keeps both from spending the model quota.
            port = self.server.server_address[1]
            if self.headers.get("Host") not in (f"127.0.0.1:{port}", f"localhost:{port}"):
                return self.answer(started, request, 403, {"error": "only local clients may use the bridge"})
            if (self.headers.get("Content-Type") or "").split(";")[0].strip() != "application/json":
                return self.answer(started, request, 415, {"error": "send the body as application/json"})
            try:
                length = int(self.headers.get("Content-Length") or 0)
                if length > MAX_BODY:
                    return self.answer(started, request, 413, {"error": f"the body is over {MAX_BODY} bytes"})
                if length <= 0:
                    raise ValueError("the body must be a ModelRequest JSON object")
                request = json.loads(self.rfile.read(length))
                content = user_message(request)
            except ValueError as error:
                return self.answer(started, request, 400, {"error": one_line(f"bad request: {error}")})
            try:
                reply = call(model, prompt, content, tries=TRIES, timeout=TIMEOUT, workdir=workdir)
            except ModelError as error:
                return self.answer(started, request, 502, {"error": one_line(str(error))})
            body = {"reply": reply["text"], "seconds": reply["seconds"], "model": ",".join(reply["models"]) or model}
            self.answer(started, request, 200, body, reply)

        def answer(self, started: float, request, status: int, body: dict, reply: dict | None = None):
            self.send(status, "application/json", json.dumps(body).encode())
            tokens = f"in {reply['input_tokens']} out {reply['output_tokens']}" if reply else body["error"]
            model_seconds = f"model {reply['seconds']:.1f} s" if reply else "no model answer"
            print(f"{datetime.now().isoformat(timespec='seconds')} {kind(request)} {status} "
                  f"total {time.monotonic() - started:.2f} s, {model_seconds}, {tokens}", flush=True)

        def send(self, status: int, mime: str, data: bytes):
            try:
                self.send_response(status)
                self.send_header("Content-Type", mime)
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)
            except (BrokenPipeError, ConnectionResetError):
                pass

        def log_message(self, format, *args):
            pass

    return Handler


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--model", choices=["haiku", "sonnet"], default="sonnet")
    args = parser.parse_args()

    # kill sends SIGTERM, which would skip the cleanup below and leave in-flight model calls unattended.
    signal.signal(signal.SIGTERM, signal.default_int_handler)
    workdir = tempfile.mkdtemp(prefix="widget-bridge-")
    server = ThreadingHTTPServer(ADDRESS, handler(args.model, compose_prompt(), workdir))
    print(f"bridge on http://{ADDRESS[0]}:{ADDRESS[1]} with {args.model}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
        shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    main()
