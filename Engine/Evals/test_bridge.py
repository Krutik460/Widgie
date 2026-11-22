import http.client
import json
import threading
import unittest
from http.server import ThreadingHTTPServer
from unittest import mock

import bridge
from model import ModelError

REPLY = {"text": "```json\n{}\n```", "seconds": 4.2, "input_tokens": 20000, "output_tokens": 900,
         "models": ["claude-sonnet-5-5"]}


class BridgeTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), bridge.handler("sonnet", "prompt", "/tmp"))
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)
        printing = mock.patch("builtins.print")
        printing.start()
        self.addCleanup(printing.stop)

    def post(self, body, path="/v1/reply", headers=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        connection.request("POST", path, data, {"Content-Type": "application/json", **(headers or {})})
        response = connection.getresponse()
        status, text = response.status, response.read()
        connection.close()
        return status, json.loads(text) if text.startswith(b"{") else text

    def test_a_request_gets_the_reply_its_seconds_and_its_model(self):
        with mock.patch("bridge.call", return_value=REPLY) as call:
            status, body = self.post({"words": "a water tracker"})
        self.assertEqual((status, body), (200, {"reply": REPLY["text"], "seconds": 4.2, "model": "claude-sonnet-5-5"}))
        self.assertEqual((call.call_args.kwargs["tries"], call.call_args.kwargs["timeout"]), (1, 110))

    def test_a_body_it_cannot_send_is_a_400(self):
        for body in [b"", b"{not json", {"words": ""}]:
            with self.subTest(body=body), mock.patch("bridge.call") as call:
                self.assertEqual(self.post(body)[0], 400)
                call.assert_not_called()

    def test_a_failed_model_call_is_a_502_with_one_line(self):
        with mock.patch("bridge.call", side_effect=ModelError("sonnet gave no answer\nin 1 try")):
            self.assertEqual(self.post({"words": "a"}), (502, {"error": "sonnet gave no answer in 1 try"}))

    def test_only_local_json_requests_reach_the_model(self):
        cases = [
            ({"Host": "attacker.example"}, 403),
            ({"Content-Type": "text/plain"}, 415),
            ({"Content-Length": str(bridge.MAX_BODY + 1)}, 413),
        ]
        for headers, expected in cases:
            with self.subTest(headers=headers), mock.patch("bridge.call") as call:
                connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
                connection.putrequest("POST", "/v1/reply", skip_host="Host" in headers)
                merged = {"Content-Type": "application/json", "Content-Length": "13", **headers}
                for name, value in merged.items():
                    connection.putheader(name, value)
                connection.endheaders(b'{"words":"x"}')
                self.assertEqual(connection.getresponse().status, expected)
                connection.close()
                call.assert_not_called()

    def test_an_unknown_path_is_a_404(self):
        self.assertEqual(self.post({"words": "a"}, path="/v2/reply")[0], 404)


if __name__ == "__main__":
    unittest.main()
