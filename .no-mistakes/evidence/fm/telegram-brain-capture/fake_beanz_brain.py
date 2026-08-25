#!/usr/bin/env python3
"""A stand-in Mr Beanz that speaks the real /v1/capture wire protocol over TLS.

Used only to produce end-to-end evidence: the capture path talks to this with
the real curl binary, so every request recorded here crossed a real socket.

Every capture attempt is appended to $BEANZ_LOG as one JSON line recording
whether it was accepted, the path, whether the bearer token matched, and the
decoded request body.
"""
import http.server, json, os, ssl

LOG = os.environ["BEANZ_LOG"]
MODE = os.environ.get("BEANZ_MODE", "ok")   # ok | 500
TOKEN = os.environ["BEANZ_EXPECT_TOKEN"]


def accepted_so_far():
    if not os.path.exists(LOG):
        return 0
    with open(LOG, encoding="utf-8") as fh:
        return sum(1 for line in fh if line.strip() and json.loads(line)["accepted"])


counter = {"n": accepted_so_far()}


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *a):
        pass

    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length)
        auth_ok = self.headers.get("Authorization", "") == "Bearer " + TOKEN
        routed = auth_ok and self.path == "/v1/capture"
        accepted = routed and MODE == "ok"
        record = {
            "accepted": accepted,
            "authorization_ok": auth_ok,
            "body": json.loads(raw.decode("utf-8")),
            "content_type": self.headers.get("Content-Type", ""),
            "path": self.path,
        }
        with open(LOG, "a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, ensure_ascii=False, sort_keys=True) + "\n")
        if not routed:
            self.send_error(401)
            return
        if accepted:
            counter["n"] += 1
            payload = json.dumps(
                {"capture_id": "beanz-%04d" % counter["n"], "status": "captured"}
            ).encode("utf-8")
            self.send_response(200)
        else:
            payload = b'{"error":"brain is down"}'
            self.send_response(500)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)


httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(os.environ["BEANZ_CERT"], os.environ["BEANZ_KEY"])
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
with open(os.environ["BEANZ_PORT_FILE"], "w") as fh:
    fh.write(str(httpd.server_address[1]))
httpd.serve_forever()
