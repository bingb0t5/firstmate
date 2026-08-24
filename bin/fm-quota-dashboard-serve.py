#!/usr/bin/env python3
"""fm-quota-dashboard-serve.py - serve the fleet's remaining AI credits on the tailnet.

Shells out to `quota-axi --json` on every request and serves one self-contained
HTML page: a fleet summary line plus one card per provider, with live,
signed-out, and error states rendered using quota-axi's own strings. No
collector, no framework, no client-side quota math beyond a countdown
formatted from each window's `resetsAt`. Design: data/fm-quota-dashboard/report.md.

Binds only to this host's own Tailscale IPv4 address (`tailscale ip -4`),
never 0.0.0.0 or any other interface, and refuses to start if that address
cannot be confirmed. Point a browser already on the tailnet at it, the phone
included - the exact URL is also printed on startup:

    http://<this-host's-tailscale-ip>:8787/
    http://<magicdns-name>:8787/          (e.g. http://lalo-dev.tailnet-name.ts.net:8787/)

Usage:
    fm-quota-dashboard-serve.py [--port PORT] [--bind-host HOST]

Optional user-level systemd unit, so it survives logout/reboot (run
`loginctl enable-linger $USER` once, save this as
~/.config/systemd/user/fm-quota-dashboard.service, then
`systemctl --user enable --now fm-quota-dashboard`):

    [Unit]
    Description=Firstmate quota dashboard

    [Service]
    ExecStart=/usr/bin/python3 /path/to/bin/fm-quota-dashboard-serve.py
    Restart=on-failure

    [Install]
    WantedBy=default.target
"""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_PORT = 8787
QUOTA_AXI_TIMEOUT_SECS = 15
TAILSCALE_IP_TIMEOUT_SECS = 10


class BindHostError(SystemExit):
    """The resolved or requested bind host is not this host's own tailnet address."""


def tailscale_ipv4_addresses(tailscale_bin="tailscale"):
    """Return this host's Tailscale IPv4 addresses, or [] if that cannot be confirmed."""
    try:
        proc = subprocess.run(
            [tailscale_bin, "ip", "-4"],
            capture_output=True, text=True, timeout=TAILSCALE_IP_TIMEOUT_SECS,
        )
    except (OSError, subprocess.TimeoutExpired):
        return []
    if proc.returncode != 0:
        return []
    return [line.strip() for line in proc.stdout.splitlines() if line.strip()]


def resolve_bind_host(requested, tailscale_bin="tailscale"):
    """Resolve and validate the bind host against this host's own tailnet addresses.

    Never falls back to 0.0.0.0 or any other interface: with no requested host
    the first confirmed tailnet address wins, and a requested host is only
    accepted when it is one of them.
    """
    addrs = tailscale_ipv4_addresses(tailscale_bin)
    if not addrs:
        raise BindHostError(
            "fm-quota-dashboard-serve: could not confirm this host's Tailscale "
            "IPv4 address (`tailscale ip -4` returned none); is tailscale "
            "installed and this host joined to a tailnet?"
        )
    if requested is None:
        return addrs[0]
    if requested not in addrs:
        raise BindHostError(
            "fm-quota-dashboard-serve: refusing to bind "
            f"{requested!r}: not one of this host's Tailscale IPv4 addresses "
            f"({', '.join(addrs)})"
        )
    return requested


PAGE = """<!doctype html>
<html><head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Quota</title>
<style>
  :root { color-scheme: dark light; }
  body { font-family: -apple-system, system-ui, sans-serif; margin: 0;
         background: #111318; color: #e8e8ea; }
  header { padding: 12px 16px; display: flex; justify-content: space-between;
           align-items: baseline; border-bottom: 1px solid #2a2d36; }
  header h1 { font-size: 15px; margin: 0; font-weight: 600; }
  #summary { font-size: 12px; color: #9aa0ac; }
  main { padding: 10px; display: grid; gap: 10px;
         grid-template-columns: repeat(auto-fill, minmax(280px, 1fr)); }
  .card { background: #191c22; border: 1px solid #2a2d36; border-radius: 10px;
          padding: 12px 14px; }
  .card.dead { opacity: 0.55; }
  .card h2 { margin: 0 0 6px; font-size: 14px; display: flex; gap: 6px;
             align-items: center; }
  .dot { width: 8px; height: 8px; border-radius: 50%; display: inline-block; }
  .dot.live { background: #37d67a; }
  .dot.dead { background: #5a5f6b; }
  .dot.err { background: #e5534b; }
  .sub { font-size: 11px; color: #9aa0ac; margin-bottom: 8px; }
  .window { margin: 6px 0; }
  .window .row1 { display: flex; justify-content: space-between;
                  font-size: 12px; margin-bottom: 3px; }
  .bar { height: 6px; border-radius: 3px; background: #2a2d36; overflow: hidden; }
  .bar > div { height: 100%; }
  .pace-behind { background: #37d67a; }
  .pace-ahead  { background: #e5534b; }
  .pace-on_pace, .pace-unknown { background: #9aa0ac; }
  .msg { font-size: 12px; color: #c8b23a; }
  footer { padding: 8px 16px; font-size: 11px; color: #5a5f6b; }
</style>
</head>
<body>
<header><h1>Quota</h1><div id="summary">loading...</div></header>
<main id="cards"></main>
<footer id="updated"></footer>
<script>
function fmtSecs(s) {
  if (s == null) return '';
  s = Math.max(0, Math.round(s));
  const d = Math.floor(s / 86400); s -= d * 86400;
  const h = Math.floor(s / 3600); s -= h * 3600;
  const m = Math.floor(s / 60);
  if (d > 0) return d + 'd ' + h + 'h';
  if (h > 0) return h + 'h ' + m + 'm';
  return m + 'm';
}
// quota-axi's own liveness predicate: a provider is live iff its state is
// fresh or stale; every other status (unavailable, rate_limited, error,
// auth_required) means there is nothing to plot, only a message to show.
const LIVE_STATUSES = ['fresh', 'stale'];
const PACE_STATUSES = ['ahead', 'on_pace', 'behind', 'unknown'];
function paceClass(p) {
  const s = p && p.status;
  return 'pace-' + (PACE_STATUSES.indexOf(s) >= 0 ? s : 'unknown');
}
function el(tag, cls, text) {
  const node = document.createElement(tag);
  if (cls) node.className = cls;
  if (text != null) node.textContent = text;
  return node;
}
function windowNode(w) {
  const pct = typeof w.percentRemaining === 'number' ? w.percentRemaining : null;
  const wrap = el('div', 'window');
  const row = el('div', 'row1');
  row.appendChild(el('span', null, w.label == null ? '' : w.label));
  const right = [];
  if (pct != null) right.push(pct + '%');
  if (w.resetsAt) right.push(fmtSecs((new Date(w.resetsAt) - new Date()) / 1000));
  row.appendChild(el('span', null, right.join(' \\u00b7 ')));
  wrap.appendChild(row);
  const bar = el('div', 'bar');
  const fill = el('div', pct == null ? 'pace-unknown' : paceClass(w.pace));
  fill.style.width = (pct == null ? 0 : pct) + '%';
  bar.appendChild(fill);
  wrap.appendChild(bar);
  return wrap;
}
function render(data) {
  const cards = document.getElementById('cards');
  cards.textContent = '';
  let live = 0, dead = 0, err = 0;
  for (const p of data.providers) {
    const state = p.state || {};
    const isLive = LIVE_STATUSES.indexOf(state.status) >= 0;
    const signedOut = state.status === 'auth_required';
    if (isLive) live++; else if (signedOut) dead++; else err++;
    const div = el('div', 'card' + (isLive ? '' : ' dead'));
    const h2 = el('h2');
    h2.appendChild(el('span', 'dot ' + (isLive ? 'live' : signedOut ? 'dead' : 'err')));
    h2.appendChild(document.createTextNode(p.provider == null ? '' : p.provider));
    if (p.plan) {
      const plan = el('span', 'sub', '\\u00b7 ' + p.plan);
      plan.style.margin = '0';
      h2.appendChild(plan);
    }
    div.appendChild(h2);
    if (isLive) {
      for (const w of p.windows || []) div.appendChild(windowNode(w));
      if (state.error) div.appendChild(el('div', 'msg', state.error));
    } else {
      div.appendChild(el('div', 'msg', state.error || state.status || 'unavailable'));
    }
    cards.appendChild(div);
  }
  document.getElementById('summary').textContent =
    live + ' live \\u00b7 ' + dead + ' signed out \\u00b7 ' + err + ' unavailable';
  document.getElementById('updated').textContent =
    'updated ' + new Date(data.generatedAt).toLocaleTimeString();
}
async function tick() {
  try {
    const r = await fetch('/data.json', {cache: 'no-store'});
    const data = await r.json();
    if (!r.ok || !data || !Array.isArray(data.providers)) {
      document.getElementById('summary').textContent =
        data && data.error ? String(data.error) : 'quota unavailable (HTTP ' + r.status + ')';
      return;
    }
    render(data);
  } catch (e) {
    document.getElementById('summary').textContent = 'fetch failed: ' + e;
  }
}
tick();
setInterval(tick, 30000);
</script>
</body></html>"""


class Handler(BaseHTTPRequestHandler):
    server_version = "fm-quota-dashboard/1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        if self.path == "/data.json":
            self._serve_data()
        elif self.path == "/":
            self._serve_page()
        else:
            self.send_response(404)
            self.end_headers()

    def _serve_data(self):
        # Plain `--json`, never `--full`: `--full` is the only flag that adds
        # account emails/org names (report.md section 3.3), and nothing here
        # needs them. The response body is quota-axi's own stdout, unmodified.
        try:
            out = subprocess.run(
                ["quota-axi", "--json"],
                capture_output=True,
                timeout=QUOTA_AXI_TIMEOUT_SECS, check=True,
            ).stdout
        except Exception as exc:
            self._write(502, "application/json", json.dumps({"error": str(exc)}).encode("utf-8"))
            return
        self._write(200, "application/json", out, no_store=True)

    def _serve_page(self):
        self._write(200, "text/html; charset=utf-8", PAGE.encode("utf-8"))

    def _write(self, status, content_type, body, no_store=False):
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        if no_store:
            self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def build_arg_parser():
    parser = argparse.ArgumentParser(
        description="Serve the fleet's quota-axi dashboard on this host's tailnet.",
    )
    parser.add_argument(
        "--port", type=int, default=DEFAULT_PORT,
        help=f"TCP port to listen on (default: {DEFAULT_PORT})",
    )
    parser.add_argument(
        "--bind-host", default=None,
        help=(
            "Tailscale IPv4 address to bind (default: this host's own, via "
            "`tailscale ip -4`); refused if it is not one of this host's own "
            "tailnet addresses"
        ),
    )
    return parser


def main(argv):
    args = build_arg_parser().parse_args(argv)
    bind_host = resolve_bind_host(args.bind_host)
    server = ThreadingHTTPServer((bind_host, args.port), Handler)
    print(
        f"fm-quota-dashboard-serve: listening on http://{bind_host}:{args.port}/ "
        f"({datetime.now(timezone.utc).isoformat()})"
    )
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
