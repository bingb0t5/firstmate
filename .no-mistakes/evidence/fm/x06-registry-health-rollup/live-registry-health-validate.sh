#!/usr/bin/env bash
# Live validation: real fm-automation-health-check.sh against local HTTP registry.
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29WZ20174HCJ8DVD6W99C9N"
EVID="/home/rich/.no-mistakes/evidence/01M29WZ20174HCJ8DVD6W99C9N"
FIXTURES="$ROOT/tests/fixtures/automation-health"
CHECK="$ROOT/bin/fm-automation-health-check.sh"
NOW_EPOCH=$(date -u -d '2026-09-12T00:20:00Z' +%s)
LOG="$EVID/live-registry-health-transcript.txt"
: > "$LOG"

log() { printf '%s\n' "$*" | tee -a "$LOG"; }

start_server() {
  local fixture=$1 port=$2
  python3 - "$fixture" "$port" <<'PY' &
import json, sys
from http.server import BaseHTTPRequestHandler, HTTPServer

fixture_path, port = sys.argv[1], int(sys.argv[2])
with open(fixture_path) as f:
    body = f.read().encode()

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_GET(self):
        auth = self.headers.get("Authorization", "")
        if "secret-live-token" not in auth:
            self.send_response(401); self.end_headers(); return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
  SERVER_PID=$!
  sleep 0.3
}

stop_server() { kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null || true; }

make_home() {
  local name=$1 port=$2
  HOME_DIR="$EVID/live-home-$name"
  rm -rf "$HOME_DIR"
  mkdir -p "$HOME_DIR/state"
  printf 'FM_AUTOMATION_REGISTRY_URL=http://127.0.0.1:%s\nFM_AUTOMATION_REGISTRY_TOKEN=secret-live-token\n' "$port" \
    > "$HOME_DIR/.env"
}

run_action() {
  local action=$1 out=$2
  FM_HOME="$HOME_DIR" \
    FM_REGISTRY_HEALTH_NOW="$NOW_EPOCH" \
    FM_REGISTRY_HEALTH_GRACE_SECS=60 \
    FM_AUTOMATION_HEALTH_INTERVAL=0 \
    "$CHECK" "$action" >"$out" 2>&1
}

PASS=0
FAIL=0
record() {
  local name=$1 result=$2 detail=$3
  log "SCENARIO: $name => $result"
  log "$detail"
  log "---"
  case "$result" in
    pass) PASS=$((PASS + 1)) ;;
    fail) FAIL=$((FAIL + 1)) ;;
  esac
}

# Scenario 1: report canonical rows
PORT=18701
make_home report "$PORT"
start_server "$FIXTURES/registry-healthy.json" "$PORT"
OUT="$EVID/scenario-report.txt"
run_action report "$OUT"
stop_server
if grep -q $'s6-02-secret-parity\tinfra\t15 minutes\t1440s\t1500s\t300s\t0\t0\tcorr-healthy\trun-healthy\thealthy' "$OUT" &&
   grep -q 'automation owner cadence source_freshness_age run_age heartbeat_age open_failures retry_count correlation_id last_run_id health' "$OUT"; then
  record "report canonical rows" pass "$(cat "$OUT")"
else
  record "report canonical rows" fail "$(cat "$OUT")"
fi

# Scenario 2: stale alert
PORT=18702
make_home stale1 "$PORT"
start_server "$FIXTURES/registry-stale-heartbeat.json" "$PORT"
OUT="$EVID/scenario-stale-first.txt"
run_action run "$OUT"
if grep -q "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" "$OUT"; then
  record "stale alert first run" pass "$(cat "$OUT")"
else
  record "stale alert first run" fail "$(cat "$OUT")"
fi

# Scenario 3: dedupe same fingerprint
OUT="$EVID/scenario-stale-repeat.txt"
run_action run "$OUT"
if [ ! -s "$OUT" ]; then
  record "stale dedupe same fingerprint" pass "(empty output)"
else
  record "stale dedupe same fingerprint" fail "$(cat "$OUT")"
fi
stop_server

# Scenario 4: new fingerprint alerts again
PORT=18703
make_home stale2 "$PORT"
start_server "$FIXTURES/registry-stale-heartbeat.json" "$PORT"
run_action run "$EVID/scenario-stale-seed.txt" >/dev/null
stop_server
start_server "$FIXTURES/registry-stale-heartbeat-new-run.json" "$PORT"
OUT="$EVID/scenario-stale-new-run.txt"
run_action run "$OUT"
stop_server
if grep -q "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" "$OUT"; then
  record "stale new fingerprint alerts" pass "$(cat "$OUT")"
else
  record "stale new fingerprint alerts" fail "$(cat "$OUT")"
fi

# Scenario 5: adversarial terminal failed - no stale alert
PORT=18705
make_home failed "$PORT"
start_server "$FIXTURES/registry-open-failure.json" "$PORT"
OUT="$EVID/scenario-failed-no-stale.txt"
run_action run "$OUT"
stop_server
if [ ! -s "$OUT" ]; then
  record "terminal failed no stale alert" pass "(empty output)"
else
  record "terminal failed no stale alert" fail "$(cat "$OUT")"
fi

# Scenario 6: report open failure row
PORT=18706
make_home openfail "$PORT"
start_server "$FIXTURES/registry-open-failure.json" "$PORT"
OUT="$EVID/scenario-open-failure-report.txt"
run_action report "$OUT"
stop_server
if grep -q $'\t1\t2\tcorr-failed\trun-failed\tfailed' "$OUT"; then
  record "report open failure row" pass "$(cat "$OUT")"
else
  record "report open failure row" fail "$(cat "$OUT")"
fi

# Scenario 7: armed check path stale + dedupe
PORT=18707
make_home armed "$PORT"
start_server "$FIXTURES/registry-stale-heartbeat.json" "$PORT"
OUT1="$EVID/scenario-armed-first.txt"
run_action check "$OUT1"
OUT2="$EVID/scenario-armed-second.txt"
run_action check "$OUT2"
stop_server
if grep -q "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" "$OUT1" &&
   [ ! -s "$OUT2" ]; then
  record "armed check stale once" pass "first: $(cat "$OUT1") second: (empty)"
else
  record "armed check stale once" fail "first: $(cat "$OUT1") second: $(cat "$OUT2")"
fi

# Scenario 8: credential not leaked
LEAK=$(grep -r 'secret-live-token' "$EVID"/scenario-*.txt "$EVID"/live-registry-health-transcript.txt 2>/dev/null || true)
if [ -z "$LEAK" ]; then
  record "no credential leak" pass "token absent from all scenario outputs"
else
  record "no credential leak" fail "$LEAK"
fi

# Scenario 9: rollup preserved in check path (stream projection fixture)
PORT=18708
make_home rollup "$PORT"
ROLLUP_FIX="$EVID/rollup-green.json"
cat > "$ROLLUP_FIX" <<'JSON'
{"automations":[{"id":"secret-parity","source_freshness_age_seconds":12,"queue_age_seconds":0,"last_success_age_seconds":45,"retry_count":1,"open_alerts":[],"last_terminal_receipt":{"type":"automation.run.receipt.v1","terminal":true,"status":"success"}},{"id":"digest","source_freshness_age_seconds":2,"queue_age_seconds":4,"last_success_age_seconds":8,"retry_count":0,"open_alerts":[],"last_terminal_receipt":{"type":"automation.run.receipt.v1","terminal":true,"status":"succeeded"}}]}
JSON
start_server "$ROLLUP_FIX" "$PORT"
OUT1="$EVID/scenario-check-rollup-first.txt"
run_action check "$OUT1"
OUT2="$EVID/scenario-check-rollup-second.txt"
run_action check "$OUT2"
stop_server
if grep -q 'green automation health:' "$OUT1" && [ ! -s "$OUT2" ]; then
  record "check preserves rollup dedupe" pass "first: $(cat "$OUT1") second: (empty)"
else
  record "check preserves rollup dedupe" fail "first: $(cat "$OUT1") second: $(cat "$OUT2")"
fi

# Scenario 10: adversarial failed terminal with old heartbeat - no stale
PORT=18709
make_home advfailed "$PORT"
ADV_FIX="$EVID/failed-old-heartbeat.json"
cat > "$ADV_FIX" <<'JSON'
{"automations":[{"schema":"automation.registry.v1","manifest_id":"s6-02-secret-parity","owner":"infra","cadence":"15 minutes","last_start_at":"2026-09-11T23:59:00.000Z","terminal_outcome":"failed","retry_count":1,"correlation_id":"corr-adv","heartbeat_at":"2026-09-12T00:00:00.000Z","health":"failed","last_run_id":"run-adv-failed"}]}
JSON
start_server "$ADV_FIX" "$PORT"
OUT="$EVID/scenario-adv-failed-no-stale.txt"
run_action run "$OUT"
stop_server
if [ ! -s "$OUT" ]; then
  record "adversarial failed terminal old heartbeat" pass "(empty output)"
else
  record "adversarial failed terminal old heartbeat" fail "$(cat "$OUT")"
fi

log "SUMMARY: pass=$PASS fail=$FAIL"
exit "$FAIL"
