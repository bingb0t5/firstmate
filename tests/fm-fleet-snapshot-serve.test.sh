#!/usr/bin/env bash
# tests/fm-fleet-snapshot-serve.test.sh - authenticated HTTP access to the canonical fleet snapshot.
#
# The suite drives the foreground service through HTTP and a disposable copy of
# its adjacent canonical producer.  It covers the server contract without
# inspecting implementation bytes: authentication, the exact read path,
# loopback default, canonical invocation, bounded failures, schema refusal, and
# the Lalo adapter's typed payload shape.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

SERVER="$ROOT/bin/fm-fleet-snapshot-serve.py"
TMP_ROOT=$(fm_test_tmproot fm-fleet-snapshot-serve)
APP_BIN="$TMP_ROOT/bin"
mkdir -p "$APP_BIN"
cp "$SERVER" "$APP_BIN/fm-fleet-snapshot-serve.py"
chmod +x "$APP_BIN/fm-fleet-snapshot-serve.py"

TOKEN='snapshot-read-secret'
INVOCATIONS="$TMP_ROOT/invocations"
MODE_FILE="$TMP_ROOT/mode"
FM_HOME_FIXTURE="$TMP_ROOT/home"
mkdir -p "$FM_HOME_FIXTURE"
SERVER_PID=
SERVER_PORT=

stop_server() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=
  fi
}
trap 'stop_server; fm_test_cleanup || true' EXIT

write_canonical_fixture() {
  cat > "$APP_BIN/fm-fleet-snapshot.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\t%s\n' "$*" "${FM_HOME:-}" >> "${FM_SNAPSHOT_INVOCATIONS:?}"
case "$(cat "${FM_SNAPSHOT_MODE:?}")" in
  valid)
    cat <<'JSON'
{"schema":"fm-fleet-snapshot.v1","generated":"2026-08-26T00:00:00Z","fm_home":"/private/home","roots":{"fm_root":"/private/root","state":"/private/state","data":"/private/data","config":"/private/config","projects":"/private/projects"},"backlog":{"path":"/private/data/backlog.md","present":true,"records":[{"order":1,"state":"in_flight","structured":true,"id":"ship-1","title":"Build snapshot service","repo":"bingb0t5/firstmate","kind":"ship"},{"order":2,"state":"queued","structured":true,"id":"hold-1","title":"Captain review","repo":"bingb0t5/firstmate","kind":"ship","captain_actionable":true,"hold_reason":"Needs captain approval"},{"order":3,"state":"queued","structured":true,"id":"gate-1","title":"Waiting on dependency","repo":"bingb0t5/firstmate","kind":"ship","unresolved_blocker_ids":["ship-1"],"blocked_reason":"Waiting on ship-1"},{"order":4,"state":"done","structured":true,"id":"done-1","title":"Earlier work","repo":"bingb0t5/firstmate","kind":"ship"}]},"tasks":[{"id":"ship-1","kind":"ship","backlog":{"repo":"bingb0t5/firstmate"},"current_state":{"state":"working","source":"run-step","detail":"serving","observed_at":"2026-08-26T00:00:00Z"},"pr":{"url":null}},{"id":"hold-1","kind":"ship","backlog":{"repo":"bingb0t5/firstmate"},"current_state":{"state":"unknown","source":"none","detail":"not started","observed_at":"2026-08-26T00:00:00Z"},"pr":{"url":null}},{"id":"gate-1","kind":"ship","backlog":{"repo":"bingb0t5/firstmate"},"current_state":{"state":"unknown","source":"none","detail":"not started","observed_at":"2026-08-26T00:00:00Z"},"pr":{"url":null}},{"id":"done-1","kind":"ship","backlog":{"repo":"bingb0t5/firstmate"},"current_state":{"state":"done","source":"run-step","detail":null,"observed_at":"2026-08-26T00:00:00Z"},"pr":{"url":null}}],"main_inventory":{"valid":true,"reason":null,"orphan_in_flight":[],"unstructured_current_count":0},"scout_reports":[],"secondmate_current":{"registry":{"available":true},"records":[],"total":0,"shown":0,"truncated":0},"secondmate_landed":{"records":[],"truncated":[],"unreadable":[],"partial":[]},"secondmate_guidance":{"note":"read-only"}}
JSON
    ;;
  malformed) printf '%s\n' '{"schema":"wrong"}' ;;
  failure) printf '%s\n' 'producer failure' >&2; exit 1 ;;
  timeout) sleep 10 ;;
esac
SH
  chmod +x "$APP_BIN/fm-fleet-snapshot.sh"
}

free_port() {
  python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()'
}

wait_for_port() {
  local port=$1 attempt
  # shellcheck disable=SC2034 # attempt bounds the retry count.
  for attempt in $(seq 1 60); do
    python3 -c "import socket; s=socket.socket(); s.settimeout(.2); s.connect(('127.0.0.1',$port)); s.close()" 2>/dev/null && return 0
    sleep 0.1
  done
  return 1
}

request() {
  # request <method> <path> [authorization]
  python3 - "$SERVER_PORT" "$1" "$2" "${3:-}" <<'PY'
import http.client
import sys
port, method, path, authorization = sys.argv[1:]
conn = http.client.HTTPConnection('127.0.0.1', int(port), timeout=8)
headers = {'Authorization': authorization} if authorization else {}
try:
    conn.request(method, path, headers=headers)
    response = conn.getresponse()
    print(response.status)
    sys.stdout.write(response.read().decode('utf-8', 'replace'))
finally:
    conn.close()
PY
}

start_server() {
  local mode=${1:-valid} token=${2:-$TOKEN}
  stop_server
  : > "$INVOCATIONS"
  write_canonical_fixture
  printf '%s\n' "$mode" > "$MODE_FILE"
  SERVER_PORT=$(free_port)
  if [ "$token" = __MISSING__ ]; then
    env -u FM_FLEET_SNAPSHOT_READ_TOKEN \
      FM_HOME="$FM_HOME_FIXTURE" \
      FM_SNAPSHOT_INVOCATIONS="$INVOCATIONS" \
      FM_SNAPSHOT_MODE="$MODE_FILE" \
      python3 "$APP_BIN/fm-fleet-snapshot-serve.py" --port "$SERVER_PORT" >"$TMP_ROOT/server.log" 2>&1 &
  else
    FM_HOME="$FM_HOME_FIXTURE" \
    FM_FLEET_SNAPSHOT_READ_TOKEN="$token" \
    FM_SNAPSHOT_INVOCATIONS="$INVOCATIONS" \
    FM_SNAPSHOT_MODE="$MODE_FILE" \
      python3 "$APP_BIN/fm-fleet-snapshot-serve.py" --port "$SERVER_PORT" >"$TMP_ROOT/server.log" 2>&1 &
  fi
  SERVER_PID=$!
  wait_for_port "$SERVER_PORT" || fail "server did not start"
}

count_invocations() { wc -l < "$INVOCATIONS" | tr -d ' '; }

# --- required end-to-end proof ----------------------------------------------

test_authenticated_canonical_payload() {
  start_server valid
  local response status body
  response=$(request GET /api/fleet/snapshot "Bearer $TOKEN")
  status=$(printf '%s' "$response" | head -n1)
  body=$(printf '%s' "$response" | tail -n +2)
  [ "$status" = 200 ] || fail "authenticated snapshot returned $status"
  python3 - "$body" <<'PY'
import json
import sys
value = json.loads(sys.argv[1])
assert value['schema'] == 'fm-fleet-snapshot.v1'
for key in ('generatedAt', 'inFlight', 'decisions', 'gates', 'recentCompletions', 'omitted', 'mainInventory', 'secondmate', 'provenance'):
    assert key in value, key
assert value['inFlight'][0]['id'] == 'ship-1'
assert value['inFlight'][0]['currentSource'] == 'authoritative_current'
assert value['decisions'][0]['holdReason'] == 'Needs captain approval'
assert value['gates'][0]['gate'] == 'Waiting on ship-1'
assert value['recentCompletions'][0]['id'] == 'done-1'
PY
  [ "$(count_invocations)" = 1 ] || fail "authenticated request did not invoke the producer exactly once"
  grep -qx -- "--json${TAB:-$'\t'}$FM_HOME_FIXTURE" "$INVOCATIONS" || fail "producer was not called with --json and explicit FM_HOME"
  pass "authenticated GET returns the canonical v1 data in the Lalo adapter shape"
}

test_missing_and_wrong_auth_rejected_without_invocation() {
  start_server valid
  local response
  response=$(request GET /api/fleet/snapshot)
  [ "$(printf '%s' "$response" | head -n1)" = 401 ] || fail "missing auth was not rejected"
  response=$(request GET /api/fleet/snapshot 'Bearer wrong-secret')
  [ "$(printf '%s' "$response" | head -n1)" = 401 ] || fail "wrong auth was not rejected"
  [ "$(count_invocations)" = 0 ] || fail "unauthorized requests invoked the producer"
  case "$response" in *"$TOKEN"*) fail "secret appeared in unauthorized response" ;; esac
  pass "missing and wrong bearer credentials fail closed without running the producer"
}

test_missing_or_malformed_config_fails_closed() {
  local response
  start_server valid __MISSING__
  response=$(request GET /api/fleet/snapshot "Bearer $TOKEN")
  [ "$(printf '%s' "$response" | head -n1)" = 503 ] || fail "missing configured token was accepted"
  [ "$(count_invocations)" = 0 ] || fail "missing configured token invoked the producer"
  start_server valid 'token with whitespace'
  response=$(request GET /api/fleet/snapshot "Bearer $TOKEN")
  [ "$(printf '%s' "$response" | head -n1)" = 503 ] || fail "malformed configured token was accepted"
  [ "$(count_invocations)" = 0 ] || fail "malformed configured token invoked the producer"
  pass "missing and malformed configured tokens fail closed without invoking the producer"
}

test_non_get_and_wrong_path_cannot_invoke() {
  start_server valid
  local response
  response=$(request POST /api/fleet/snapshot "Bearer $TOKEN")
  [ "$(printf '%s' "$response" | head -n1)" = 405 ] || fail "POST was not rejected"
  response=$(request GET /api/fleet/snapshot/ "Bearer $TOKEN")
  [ "$(printf '%s' "$response" | head -n1)" = 404 ] || fail "wrong path was not rejected"
  [ "$(count_invocations)" = 0 ] || fail "non-GET or wrong-path request invoked the producer"
  pass "only the exact authenticated GET is exposed and mutation methods cannot invoke the producer"
}

test_loopback_default_and_secret_free_logs() {
  start_server valid
  grep -q "listening on 127.0.0.1:$SERVER_PORT" "$TMP_ROOT/server.log" || fail "default listener was not loopback"
  request GET /api/fleet/snapshot 'Bearer wrong-secret' >/dev/null
  if grep -q "$TOKEN" "$TMP_ROOT/server.log"; then
    fail "server log disclosed the bearer token"
  fi
  pass "the default listener is loopback and logs contain no bearer secret"
}

# --- producer failure and bounded output policy -----------------------------

test_failure_and_schema_refusal_are_unavailable() {
  local mode response
  for mode in failure malformed; do
    start_server "$mode"
    response=$(request GET /api/fleet/snapshot "Bearer $TOKEN")
    [ "$(printf '%s' "$response" | head -n1)" = 503 ] || fail "$mode returned a non-unavailable status"
    case "$response" in *"producer failure"*|*"wrong"*|*"$TOKEN"*) fail "$mode leaked upstream content" ;; esac
    [ "$(count_invocations)" = 1 ] || fail "$mode did not invoke the canonical producer exactly once"
  done
  pass "producer failure and non-v1 output return bounded unavailable errors"
}

test_timeout_is_bounded_and_unavailable() {
  start_server timeout
  local started response elapsed
  started=$(date +%s)
  response=$(request GET /api/fleet/snapshot "Bearer $TOKEN")
  elapsed=$(( $(date +%s) - started ))
  [ "$(printf '%s' "$response" | head -n1)" = 503 ] || fail "timed-out producer was not unavailable"
  [ "$elapsed" -le 7 ] || fail "producer timeout exceeded the bounded service budget: ${elapsed}s"
  [ "$(count_invocations)" = 1 ] || fail "timed-out request did not invoke the canonical producer exactly once"
  pass "snapshot production timeout returns unavailable within a bounded interval"
}

test_authenticated_canonical_payload
test_missing_and_wrong_auth_rejected_without_invocation
test_missing_or_malformed_config_fails_closed
test_non_get_and_wrong_path_cannot_invoke
test_loopback_default_and_secret_free_logs
test_failure_and_schema_refusal_are_unavailable
test_timeout_is_bounded_and_unavailable
