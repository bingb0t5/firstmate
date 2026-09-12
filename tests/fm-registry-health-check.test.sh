#!/usr/bin/env bash
# Tests for the read-only central automation registry health check.
#
# The fake HTTP transport serves checked-in registry response fixtures and does
# not print request headers or credential values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-registry-health-check.sh"
FIXTURES="$ROOT/tests/fixtures/registry-health"
TMP_ROOT=$(fm_test_tmproot fm-registry-health)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
output=
fixture=${FM_REGISTRY_FIXTURE:?}
while [ "$#" -gt 0 ]; do
  case "$1" in
    --config) shift ;;
    -o) output=$2; shift 2 ;;
    --max-time) shift 2 ;;
    -sS) shift ;;
    http://*|https://*) shift ;;
    *) shift ;;
  esac
done
cat "$fixture" > "$output"
SH
chmod 0755 "$FAKEBIN/curl"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' \
    'FM_AUTOMATION_REGISTRY_URL=https://brain.test' \
    'FM_AUTOMATION_REGISTRY_TOKEN=fixture-secret-value' > "$home/.env"
  MADE_HOME=$home
}

run_check() {
  local home=$1 action=$2 fixture=$3 out=$4 status=0
  FM_HOME="$home" \
    FM_REGISTRY_HEALTH_NOW="$(date -u -d '2026-09-12T00:20:00Z' +%s)" \
    FM_REGISTRY_HEALTH_GRACE_SECS=60 \
    FM_REGISTRY_FIXTURE="$fixture" \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" "$action" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "registry health $action exit"
}

test_healthy_report_contains_all_metrics() {
  local home out report
  make_home healthy
  home=$MADE_HOME
  out="$home/run.out"
  run_check "$home" run "$FIXTURES/healthy.json" "$out"
  [ ! -s "$out" ] || fail "healthy registry produced a stale wake: $(cat "$out")"
  run_check "$home" report "$FIXTURES/healthy.json" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'automation owner cadence source_freshness_age run_age heartbeat_age open_failures health' \
    "report omitted its metric headings"
  assert_contains "$report" $'s6-02-secret-parity\tinfra\t15 minutes\t' \
    "report omitted the automation owner and cadence"
  assert_contains "$report" $'\t1440s\t1500s\t300s\t0\thealthy' \
    "report omitted the source, run, heartbeat, or health values"
  assert_not_contains "$report" 'fixture-secret-value' \
    "registry token appeared in the report"
  pass "healthy registry rows report owner and all health ages"
}

test_stale_heartbeat_wakes_once() {
  local home out report
  make_home stale
  home=$MADE_HOME
  out="$home/run.out"
  run_check "$home" run "$FIXTURES/stale-heartbeat.json" "$out"
  report=$(cat "$out")
  assert_contains "$report" "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" \
    "stale heartbeat did not produce the captain-readable wake"
  : > "$out"
  run_check "$home" run "$FIXTURES/stale-heartbeat.json" "$out"
  [ ! -s "$out" ] || fail "the same stale heartbeat woke twice: $(cat "$out")"
  assert_grep 's6-02-secret-parity|run-stale|stale' "$home/state/.registry-health" \
    "stale fingerprint was not recorded"
  pass "a stale heartbeat wakes once for its registry fingerprint"
}

test_fingerprint_change_is_new_alert() {
  local home out report
  make_home changed-fingerprint
  home=$MADE_HOME
  out="$home/run.out"
  run_check "$home" run "$FIXTURES/stale-heartbeat.json" "$out"
  : > "$out"
  run_check "$home" run "$FIXTURES/open-failure.json" "$out"
  report=$(cat "$out")
  [ ! -s "$out" ] || fail "a terminal failure was treated as a stale heartbeat: $report"
  pass "terminal health changes do not create a stale-heartbeat false positive"
}

test_open_failure_is_reported() {
  local home out report
  make_home open-failure
  home=$MADE_HOME
  out="$home/report.out"
  run_check "$home" report "$FIXTURES/open-failure.json" "$out"
  report=$(cat "$out")
  assert_contains "$report" $'s6-02-secret-parity\tinfra\t15 minutes' \
    "open failure row was not included in the table"
  assert_contains "$report" $'\t1\tfailed' \
    "open failure count or health was not reported"
  pass "open terminal failures are visible without re-running the automation"
}

test_arm_registers_and_disarm_removes_the_check() {
  local home status=0
  make_home arm
  home=$MADE_HOME
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/registry-health.check.sh" "arm did not create the watcher shim"
  assert_present "$home/state/registry-health.check-trust" "arm did not create the trust binding"
  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/registry-health.check.sh" "disarm left the watcher shim"
  assert_absent "$home/state/registry-health.check-trust" "disarm left the trust binding"
  pass "arm registers and disarm removes the read-only watcher check"
}

test_healthy_report_contains_all_metrics
test_stale_heartbeat_wakes_once
test_fingerprint_change_is_new_alert
test_open_failure_is_reported
test_arm_registers_and_disarm_removes_the_check

printf '# fm-registry-health-check.test.sh: all assertions passed\n'
