import json, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG = sys.argv[2]
TEXT = ["```lua\n", "local x", " = 2\n", "return x\n", "```"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        with open(LOG, "a") as f:
            f.write(json.dumps({"path": self.path, "headers": dict(self.headers), "body": body}) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.end_headers()
        slow = body["messages"][-1]["content"].endswith("SLOW")
        for piece in TEXT * (200 if slow else 1):
            if self.path.endswith("/chat/completions"):
                event = {"choices": [{"delta": {"content": piece}}]}
                lines = f"data: {json.dumps(event)}\n\n"
            else:
                event = {"type": "content_block_delta", "delta": {"type": "text_delta", "text": piece}}
                lines = f"event: content_block_delta\r\ndata: {json.dumps(event)}\r\n\r\n"
            raw = lines.encode()
            # Split events mid-line to exercise partial-chunk buffering.
            for part in (raw[:7], raw[7:]):
                self.wfile.write(part)
                self.wfile.flush()
                time.sleep(0.01 if not slow else 0.05)
        if self.path.endswith("/chat/completions"):
            self.wfile.write(b"data: [DONE]\n\n")


ThreadingHTTPServer(("127.0.0.1", int(sys.argv[1])), Handler).serve_forever()
