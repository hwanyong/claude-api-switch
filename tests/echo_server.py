#!/usr/bin/env python3
"""Anthropic-compatible echo server for ccswitch E2E tests.
Logs every request to echo-server.log next to this file."""
import json, os, threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "echo-server.log")
lock = threading.Lock()

def log(msg):
    with lock:
        with open(LOG, "a") as f:
            f.write(msg + "\n")

class H(BaseHTTPRequestHandler):
    def _cors(self):
        return {"Access-Control-Allow-Origin": "*",
                "Access-Control-Allow-Headers": "*",
                "Access-Control-Allow-Methods": "GET,POST,OPTIONS"}

    def do_OPTIONS(self):
        self.send_response(204)
        for k, v in self._cors().items(): self.send_header(k, v)
        self.end_headers()

    def do_GET(self):
        log(f"GET {self.path} auth={self.headers.get('x-api-key') or self.headers.get('authorization')}")
        if self.path.startswith("/v1/models"):
            body = json.dumps({"object": "list", "data": [
                {"id": "echo-model", "object": "model", "owned_by": "test",
                 "aliases": ["echo-alias"],
                 "meta": {"n_ctx": 65536, "published_context_length": 65536}}
            ]}).encode()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(body)))
            for k, v in self._cors().items(): self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()

    def do_POST(self):
        n = int(self.headers.get("content-length", 0))
        raw = self.rfile.read(n)
        try:
            req = json.loads(raw)
        except Exception:
            req = {}
        auth = self.headers.get("x-api-key") or self.headers.get("authorization")
        log(f"POST {self.path} auth={auth} model={req.get('model')} stream={req.get('stream')}")
        if not self.path.startswith("/v1/messages"):
            self.send_response(404); self.end_headers(); return
        text = "ECHO_OK " + str(req.get("model"))
        if req.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            for k, v in self._cors().items(): self.send_header(k, v)
            self.end_headers()
            evs = [
                ("message_start", {"type":"message_start","message":{"id":"msg_echo","type":"message","role":"assistant","content":[],"model":req.get("model","echo-model"),"usage":{"input_tokens":5,"output_tokens":4}}}),
                ("content_block_start", {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}),
                ("ping", {"type":"ping"}),
                ("content_block_delta", {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":text}}),
                ("content_block_stop", {"type":"content_block_stop","index":0}),
                ("message_delta", {"type":"message_delta","delta":{"stop_reason":"end_turn","stop_sequence":None},"usage":{"output_tokens":4}}),
                ("message_stop", {"type":"message_stop"}),
            ]
            for name, data in evs:
                self.wfile.write(f"event: {name}\ndata: {json.dumps(data)}\n\n".encode())
            self.wfile.flush()
        else:
            body = json.dumps({"id":"msg_echo","type":"message","role":"assistant",
                "content":[{"type":"text","text":text}],
                "model":req.get("model","echo-model"),
                "stop_reason":"end_turn","stop_sequence":None,
                "usage":{"input_tokens":5,"output_tokens":4}}).encode()
            self.send_response(200)
            self.send_header("Content-Type","application/json")
            self.send_header("Content-Length", str(len(body)))
            for k, v in self._cors().items(): self.send_header(k, v)
            self.end_headers()
            self.wfile.write(body)

    def log_message(self, *a): pass

if __name__ == "__main__":
    import sys
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 19311
    ThreadingHTTPServer(("127.0.0.1", port), H).serve_forever()
