#!/usr/bin/env bash
set -u
EVIDENCE=/home/rich/.no-mistakes/evidence/01M29WZ20174HCJ8DVD6W99C9N
ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29WZ20174HCJ8DVD6W99C9N
FIXTURES=$ROOT/tests/fixtures/automation-health
CHECK=$ROOT/bin/fm-automation-health-check.sh
LIVE_HOME=$(mktemp -d /tmp/fm-registry-live-XXXXXX)
PORT=$(python3 -c 'import socket;s=socket.socket();s.bind(("127.0.0.1",0));print(s.getsockname()[1]);s.close()')
POINTER="$LIVE_HOME/current-fixture"
mkdir -p "$LIVE_HOME/state" "$LIVE_HOME/config"
printf 'FM_AUTOMATION_REGISTRY_URL=http://127.0.0.1:%s/v1/automations\nFM_AUTOMATION_REGISTRY_TOKEN=secret-value\n' "$PORT" > "$LIVE_HOME/.env"
export FM_HOME="$LIVE_HOME"
export FM_REGISTRY_HEALTH_GRACE_SECS=60
export FM_AUTOMATION_HEALTH_INTERVAL=0
export FM_REGISTRY_HEALTH_NOW
FM_REGISTRY_HEALTH_NOW=$(date -u -d '2026-09-12T00:20:00Z' +%s)

set_fixture() {
  printf '%s\n' "$1" > "$POINTER"
}

python3 "$EVIDENCE/live-registry-server.py" "$PORT" "$POINTER" &
SERVER_PID=$!
sleep 0.4

cleanup() {
  kill "$SERVER_PID" 2>/dev/null || true
  wait "$SERVER_PID" 2>/dev/null || true
  rm -rf "$LIVE_HOME"
}
trap cleanup EXIT

run_action() {
  local action=$1 out=$2
  "$CHECK" "$action" >"$out" 2>&1
}

echo "live home: $LIVE_HOME" > "$EVIDENCE/live-setup.txt"
echo "registry port: $PORT" >> "$EVIDENCE/live-setup.txt"

set_fixture "$FIXTURES/registry-healthy.json"
run_action report "$EVIDENCE/scenario-report-healthy.out"
cp "$EVIDENCE/scenario-report-healthy.out" "$EVIDENCE/scenario-report-healthy.txt"

set_fixture "$FIXTURES/registry-open-failure.json"
run_action report "$EVIDENCE/scenario-report-open-failure.out"
cp "$EVIDENCE/scenario-report-open-failure.out" "$EVIDENCE/scenario-report-open-failure.txt"

set_fixture "$FIXTURES/registry-stale-heartbeat.json"
rm -f "$LIVE_HOME/state/.automation-health-stale"
run_action run "$EVIDENCE/scenario-stale-first.out"
cp "$EVIDENCE/scenario-stale-first.out" "$EVIDENCE/scenario-stale-first.txt"
run_action run "$EVIDENCE/scenario-stale-repeat.out"
cp "$EVIDENCE/scenario-stale-repeat.out" "$EVIDENCE/scenario-stale-repeat.txt"

set_fixture "$FIXTURES/registry-stale-heartbeat-new-run.json"
run_action run "$EVIDENCE/scenario-stale-new-run.out"
cp "$EVIDENCE/scenario-stale-new-run.out" "$EVIDENCE/scenario-stale-new-run.txt"

set_fixture "$FIXTURES/registry-stale-heartbeat-recovered.json"
run_action run "$EVIDENCE/scenario-stale-recovered.out"
set_fixture "$FIXTURES/registry-stale-heartbeat.json"
run_action run "$EVIDENCE/scenario-stale-after-recovery.out"
cp "$EVIDENCE/scenario-stale-after-recovery.out" "$EVIDENCE/scenario-stale-after-recovery.txt"

set_fixture "$FIXTURES/registry-open-failure.json"
run_action run "$EVIDENCE/scenario-terminal-no-stale.out"
cp "$EVIDENCE/scenario-terminal-no-stale.out" "$EVIDENCE/scenario-terminal-no-stale.txt"

printf '{"status":"ok"}\n' > "$LIVE_HOME/bad-registry.json"
set_fixture "$LIVE_HOME/bad-registry.json"
run_action run "$EVIDENCE/scenario-run-unavailable.out"
cp "$EVIDENCE/scenario-run-unavailable.out" "$EVIDENCE/scenario-run-unavailable.txt"

set_fixture "$FIXTURES/registry-stale-heartbeat.json"
rm -f "$LIVE_HOME/state/.automation-health" "$LIVE_HOME/state/.automation-health-stale"
run_action check "$EVIDENCE/scenario-armed-check-first.out"
run_action check "$EVIDENCE/scenario-armed-check-second.out"
cp "$EVIDENCE/scenario-armed-check-first.out" "$EVIDENCE/scenario-armed-check-first.txt"
cp "$EVIDENCE/scenario-armed-check-second.out" "$EVIDENCE/scenario-armed-check-second.txt"

# Green rollup check uses projection-format fixture
cat > "$LIVE_HOME/green-projection.json" <<'JSON'
{"automations":[{"id":"secret-parity","source_freshness_age_seconds":12,"queue_age_seconds":0,"last_success_age_seconds":45,"retry_count":1,"open_alerts":[],"last_terminal_receipt":{"type":"automation.run.receipt.v1","terminal":true,"status":"success"}}]}
JSON
set_fixture "$LIVE_HOME/green-projection.json"
rm -f "$LIVE_HOME/state/.automation-health" "$LIVE_HOME/state/.automation-health-stale"
run_action check "$EVIDENCE/scenario-check-rollup-first.out"
run_action check "$EVIDENCE/scenario-check-rollup-second.out"
cp "$EVIDENCE/scenario-check-rollup-first.out" "$EVIDENCE/scenario-check-rollup-first.txt"
cp "$EVIDENCE/scenario-check-rollup-second.out" "$EVIDENCE/scenario-check-rollup-second.txt"

# Arm/disarm shim path
set_fixture "$FIXTURES/registry-stale-heartbeat.json"
rm -f "$LIVE_HOME/state/.automation-health" "$LIVE_HOME/state/.automation-health-stale"
FM_HOME="$LIVE_HOME" "$CHECK" arm >"$EVIDENCE/scenario-arm.out" 2>&1
PATH="$PATH" FM_REGISTRY_HEALTH_NOW="$FM_REGISTRY_HEALTH_NOW" \
  FM_AUTOMATION_HEALTH_INTERVAL=0 \
  "$LIVE_HOME/state/automation-health.check.sh" >"$EVIDENCE/scenario-armed-shim.out" 2>&1
FM_HOME="$LIVE_HOME" "$CHECK" disarm >>"$EVIDENCE/scenario-arm.out" 2>&1
cp "$EVIDENCE/scenario-armed-shim.out" "$EVIDENCE/scenario-armed-shim.txt"

if grep -r 'secret-value' "$EVIDENCE"/scenario-*.out >/dev/null 2>&1; then
  echo 'CREDENTIAL LEAK DETECTED' > "$EVIDENCE/credential-leak.txt"
else
  echo 'no credential leak' > "$EVIDENCE/credential-leak.txt"
fi

echo 'live scenarios complete'
