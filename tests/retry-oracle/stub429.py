#!/usr/bin/env python3
# Deterministic transient-failure stub for the bgworker retry/backoff oracle
# (the #243 fix: in-loop retry on 429/5xx so a transient blip mid-tool-loop
# doesn't fail the whole stage). OpenAI-compat POST /v1/chat/completions:
# returns HTTP 429 for the first `fail_first` requests since the last reset,
# then a valid streaming (SSE) completion. Control plane (no restart between
# test phases):
#   GET /set?fail=N   -> fail_first=N, counter=0   (returns the new state)
#   GET /count        -> current {fail_first,count}
# See RUNME.md for the full harness.
import http.server, json, os, sys, threading, urllib.parse

state = {"fail_first": int(os.environ.get("STUB_FAIL_FIRST", "0")), "count": 0}
lock = threading.Lock()
PORT = int(os.environ.get("STUB_PORT", "8799"))

def log(m):
    sys.stderr.write(m + "\n"); sys.stderr.flush()

class H(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def _json(self, code, obj):
        b = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(b)))
        self.end_headers()
        self.wfile.write(b)

    def do_GET(self):
        u = urllib.parse.urlparse(self.path)
        if u.path == "/set":
            q = urllib.parse.parse_qs(u.query)
            with lock:
                state["fail_first"] = int(q.get("fail", ["0"])[0])
                state["count"] = 0
            log(f"STUB /set fail_first={state['fail_first']} count=0")
            return self._json(200, dict(state))
        if u.path == "/count":
            return self._json(200, dict(state))
        return self._json(404, {"error": "not found"})

    def do_POST(self):
        with lock:
            state["count"] += 1
            n = state["count"]
            ff = state["fail_first"]
        ln = int(self.headers.get("Content-Length", 0) or 0)
        if ln:
            self.rfile.read(ln)
        if n <= ff:
            log(f"STUB req#{n} -> 429")
            return self._json(429, {"error": {"message": "Resource exhausted (stub 429)", "code": 429}})
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        for c in [
            '{"choices":[{"index":0,"delta":{"role":"assistant","content":"pong"},"finish_reason":null}]}',
            '{"choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":1,"completion_tokens":1,"total_tokens":2}}',
        ]:
            self.wfile.write(f"data: {c}\n\n".encode())
        self.wfile.write(b"data: [DONE]\n\n")
        self.wfile.flush()
        log(f"STUB req#{n} -> 200 SSE")

if __name__ == "__main__":
    log(f"STUB listening :{PORT} fail_first={state['fail_first']}")
    http.server.HTTPServer(("0.0.0.0", PORT), H).serve_forever()
