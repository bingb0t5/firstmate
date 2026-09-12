#!/usr/bin/env python3
"""Minimal local automation registry for live CLI validation."""
import http.server
import socketserver
import sys

PORT = int(sys.argv[1])
FIXTURE_POINTER = sys.argv[2]


class ReuseTCPServer(socketserver.TCPServer):
    allow_reuse_address = True


class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_args):
        pass

    def do_GET(self):
        if self.path.startswith("/v1/automations"):
            auth = self.headers.get("Authorization", "")
            if "secret-value" not in auth:
                self.send_response(401)
                self.end_headers()
                return
            with open(FIXTURE_POINTER, encoding="utf-8") as pointer:
                fixture = pointer.read().strip()
            self.send_response(200)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            with open(fixture, "rb") as handle:
                self.wfile.write(handle.read())
            return
        self.send_response(404)
        self.end_headers()

    def do_POST(self):
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b'{"ok":true}')


with ReuseTCPServer(("127.0.0.1", PORT), Handler) as httpd:
    httpd.serve_forever()
