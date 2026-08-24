#!/usr/bin/env bash
# tests/fm-quota-dashboard-serve.test.sh - the phone-facing quota dashboard server.
#
# Three things matter here, all exercised through the running server's public
# HTTP interface rather than its source: it must refuse to bind anywhere but
# a confirmed Tailscale address of this host (never 0.0.0.0, never a public
# IP, never an address `tailscale ip -4` does not vouch for); the /data.json
# route must pass quota-axi's own `--json` output straight through, calling
# it with no extra flag that would add account emails (`--full`); and the two
# real routes (page, data) must behave, with everything else 404.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

SERVER="$ROOT/bin/fm-quota-dashboard-serve.py"
TMP_ROOT=$(fm_test_tmproot fm-quota-dashboard-serve)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

SERVER_PID=

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
  fi
}
trap stop_server EXIT

# fake_tailscale <addr>...: a `tailscale ip -4` stub that reports exactly the
# given addresses (one per line), and refuses every other subcommand loudly
# rather than silently succeeding, so a wrong invocation fails a test instead
# of passing by accident.
fake_tailscale() {
  local addr
  {
    printf '#!/usr/bin/env bash\n'
    # shellcheck disable=SC2016 # writing the stub's own literal source, not expanding here
    printf 'if [ "${1:-}" = ip ] && [ "${2:-}" = -4 ]; then\n'
    for addr in "$@"; do
      printf '  echo %q\n' "$addr"
    done
    printf '  exit 0\n'
    printf 'fi\n'
    printf 'echo "fake_tailscale: unexpected invocation: $*" >&2\n'
    printf 'exit 1\n'
  } > "$FAKEBIN/tailscale"
  chmod +x "$FAKEBIN/tailscale"
}

# fake_tailscale_absent: simulate a host where `tailscale ip -4` cannot
# confirm any address (not installed, or not joined to a tailnet).
fake_tailscale_absent() {
  cat > "$FAKEBIN/tailscale" <<'SH'
#!/usr/bin/env bash
exit 1
SH
  chmod +x "$FAKEBIN/tailscale"
}

# fake_quota_axi <json>: a `quota-axi --json` stub that records every
# invocation's argv (so a test can prove no extra flag, such as --full, was
# ever passed) and answers only the exact `--json` call; anything else fails
# loudly instead of quietly returning something plausible.
fake_quota_axi() {
  local json=$1
  printf '%s' "$json" > "$TMP_ROOT/quota-axi.stdout"
  cat > "$FAKEBIN/quota-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/quota-axi.invocations"
if [ "\$#" -eq 1 ] && [ "\$1" = --json ]; then
  cat "$TMP_ROOT/quota-axi.stdout"
  exit 0
fi
echo "fake_quota_axi: unexpected invocation: \$*" >&2
exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
}

FIXTURE_JSON='{"generatedAt":"2026-08-24T00:00:00Z","schemaVersion":5,"providers":[{"provider":"claude","plan":"max","windows":[{"id":"five_hour","label":"session","resetsAt":"2026-08-24T05:00:00Z","percentRemaining":68,"pace":{"status":"behind"}}],"state":{"status":"fresh","stale":false}}]}'

free_port() {
  python3 -c 'import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()'
}

wait_for_port() {
  local host=$1 port=$2 attempt
  # shellcheck disable=SC2034 # attempt only bounds the retry count
  for attempt in $(seq 1 50); do
    python3 -c "
import socket, sys
s = socket.socket()
s.settimeout(0.2)
try:
    s.connect(('$host', $port))
except OSError:
    sys.exit(1)
s.close()
" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

http_get() {
  # http_get <host> <port> <path>: print "<status>\n<body>".
  python3 -c "
import urllib.request, sys
req = urllib.request.Request('http://$1:$2$3')
try:
    with urllib.request.urlopen(req, timeout=5) as r:
        print(r.status)
        sys.stdout.write(r.read().decode('utf-8', 'replace'))
except urllib.error.HTTPError as e:
    print(e.code)
    sys.stdout.write(e.read().decode('utf-8', 'replace'))
"
}

# --- bind-host refusal -------------------------------------------------------

test_refuses_wildcard_bind() {
  fake_tailscale 100.99.99.1
  local out rc
  out=$(PATH="$FAKEBIN:$PATH" python3 "$SERVER" --bind-host 0.0.0.0 --port 1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "server accepted 0.0.0.0 as a bind host"
  case "$out" in
    *refusing*0.0.0.0*) ;;
    *) fail "refusal message did not name 0.0.0.0: $out" ;;
  esac
  pass "refuses to bind the wildcard address 0.0.0.0"
}

test_refuses_public_address_not_owned_by_this_host() {
  fake_tailscale 100.99.99.1
  local out rc
  out=$(PATH="$FAKEBIN:$PATH" python3 "$SERVER" --bind-host 203.0.113.5 --port 1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "server accepted a public address as a bind host"
  case "$out" in
    *refusing*203.0.113.5*) ;;
    *) fail "refusal message did not name 203.0.113.5: $out" ;;
  esac
  pass "refuses a public address that is not one of this host's tailnet addresses"
}

test_refuses_when_tailscale_address_unconfirmed() {
  fake_tailscale_absent
  local out rc
  out=$(PATH="$FAKEBIN:$PATH" python3 "$SERVER" --port 1 2>&1)
  rc=$?
  [ "$rc" -ne 0 ] || fail "server started with no confirmed Tailscale address"
  case "$out" in
    *"could not confirm"*) ;;
    *) fail "refusal message did not explain the missing Tailscale address: $out" ;;
  esac
  pass "refuses to start when this host's Tailscale address cannot be confirmed"
}

test_accepts_this_hosts_own_tailnet_address() {
  fake_tailscale 127.0.0.1
  fake_quota_axi "$FIXTURE_JSON"
  local port
  port=$(free_port)
  PATH="$FAKEBIN:$PATH" python3 "$SERVER" --port "$port" >"$TMP_ROOT/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_port 127.0.0.1 "$port" || fail "server never opened its port after accepting its own tailnet address"
  stop_server
  pass "starts once the requested bind host matches this host's own tailnet address"
}

# --- routes and JSON passthrough --------------------------------------------

start_server_for_routes() {
  fake_tailscale 127.0.0.1
  fake_quota_axi "$FIXTURE_JSON"
  local port
  port=$(free_port)
  PATH="$FAKEBIN:$PATH" python3 "$SERVER" --port "$port" >"$TMP_ROOT/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_port 127.0.0.1 "$port" || fail "server never opened its port"
  printf '%s' "$port"
}

test_data_route_passes_quota_axi_json_through_unchanged() {
  local port resp status body
  port=$(start_server_for_routes)
  resp=$(http_get 127.0.0.1 "$port" /data.json)
  status=$(printf '%s' "$resp" | head -n1)
  body=$(printf '%s' "$resp" | tail -n +2)
  stop_server
  [ "$status" = 200 ] || fail "/data.json returned status $status"
  [ "$body" = "$FIXTURE_JSON" ] || fail "/data.json body was not quota-axi's --json output unchanged: $body"
  grep -qx -- '--json' "$TMP_ROOT/quota-axi.invocations" \
    || fail "quota-axi was not invoked with exactly --json: $(cat "$TMP_ROOT/quota-axi.invocations")"
  grep -q -- '--full' "$TMP_ROOT/quota-axi.invocations" \
    && fail "quota-axi was invoked with --full, which surfaces account emails"
  pass "/data.json is quota-axi's own --json output, unchanged, called with no --full"
}

test_data_route_sets_no_store_and_json_content_type() {
  local port resp status headers
  port=$(start_server_for_routes)
  headers=$(python3 -c "
import urllib.request
with urllib.request.urlopen('http://127.0.0.1:$port/data.json', timeout=5) as r:
    for k, v in r.headers.items():
        print(f'{k}: {v}')
")
  resp=$(http_get 127.0.0.1 "$port" /data.json)
  status=$(printf '%s' "$resp" | head -n1)
  stop_server
  [ "$status" = 200 ] || fail "/data.json returned status $status"
  case "$headers" in
    *"Content-Type: application/json"*) ;;
    *) fail "/data.json did not set an application/json content type: $headers" ;;
  esac
  case "$headers" in
    *"Cache-Control: no-store"*) ;;
    *) fail "/data.json did not set Cache-Control: no-store, so a phone browser could show stale quota: $headers" ;;
  esac
  pass "/data.json is served as fresh, uncached JSON"
}

test_page_route_serves_self_contained_html() {
  local port resp status body
  port=$(start_server_for_routes)
  resp=$(http_get 127.0.0.1 "$port" /)
  status=$(printf '%s' "$resp" | head -n1)
  body=$(printf '%s' "$resp" | tail -n +2)
  stop_server
  [ "$status" = 200 ] || fail "/ returned status $status"
  case "$body" in
    *"fetch('/data.json'"*) ;;
    *) fail "page does not fetch /data.json" ;;
  esac
  case "$body" in
    *"setInterval(tick, 30000)"*) ;;
    *) fail "page does not refresh roughly every 30s" ;;
  esac
  case "$body" in
    *"<script src="*|*"<link "*stylesheet*) fail "page pulls in an external script or stylesheet (must be self-contained)" ;;
  esac
  pass "/ serves one self-contained page that polls /data.json about every 30s"
}

test_unknown_route_is_404() {
  local port resp status
  port=$(start_server_for_routes)
  resp=$(http_get 127.0.0.1 "$port" /nope)
  status=$(printf '%s' "$resp" | head -n1)
  stop_server
  [ "$status" = 404 ] || fail "unknown route returned status $status, expected 404"
  pass "an unknown route returns 404"
}

test_data_route_surfaces_upstream_failure_as_502() {
  fake_tailscale 127.0.0.1
  cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
echo "quota-axi: boom" >&2
exit 1
SH
  chmod +x "$FAKEBIN/quota-axi"
  local port resp status
  port=$(free_port)
  PATH="$FAKEBIN:$PATH" python3 "$SERVER" --port "$port" >"$TMP_ROOT/server.log" 2>&1 &
  SERVER_PID=$!
  wait_for_port 127.0.0.1 "$port" || fail "server never opened its port"
  resp=$(http_get 127.0.0.1 "$port" /data.json)
  status=$(printf '%s' "$resp" | head -n1)
  stop_server
  [ "$status" = 502 ] || fail "a failing quota-axi call returned status $status, expected 502"
  pass "a failing quota-axi call surfaces as a 502, not a silent empty page"
}

test_refuses_wildcard_bind
test_refuses_public_address_not_owned_by_this_host
test_refuses_when_tailscale_address_unconfirmed
test_accepts_this_hosts_own_tailnet_address
test_data_route_passes_quota_axi_json_through_unchanged
test_data_route_sets_no_store_and_json_content_type
test_page_route_serves_self_contained_html
test_unknown_route_is_404
test_data_route_surfaces_upstream_failure_as_502
