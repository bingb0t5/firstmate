#!/usr/bin/env bash
# Tests for fm-automation-health-check.sh.
#
# The fake registry returns only projection fields and never logs request
# headers, so credentials can be asserted absent from every user-facing result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-automation-health-check.sh"
FIXTURES="$ROOT/tests/fixtures/automation-health"
TMP_ROOT=$(fm_test_tmproot fm-automation-health)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
method=GET
output=
writeout=
url=
data=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -X) method=$2; shift 2 ;;
    -o) output=$2; shift 2 ;;
    -w) writeout=$2; shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
printf '%s\n' "$method $url" >> "$FM_CURL_LOG"
if [ "$method" = GET ]; then
  cat "$FM_REGISTRY_FIXTURE" > "$output"
else
  cat "${data#@}" > "$FM_LAST_BODY"
  case "$url" in
    */start) printf '%s\n' '{"run_id":"run-123"}' > "$output" ;;
    *) printf '%s\n' '{"ok":true}' > "$output" ;;
  esac
fi
printf '200'
SH
chmod 0755 "$FAKEBIN/curl"

make_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config"
  printf 'FM_AUTOMATION_REGISTRY_URL=https://brain.test\nFM_AUTOMATION_REGISTRY_TOKEN=secret-value\n' \
    > "$home/.env"
  FM_REGISTRY_FIXTURE="$home/registry.json"
  FM_CURL_LOG="$home/curl.log"
  FM_LAST_BODY="$home/request.json"
  : > "$FM_CURL_LOG"
  export FM_REGISTRY_FIXTURE FM_CURL_LOG FM_LAST_BODY
  MADE_HOME=$home
}

run_check() {
  local home=$1 out=$2 status=0
  FM_HOME="$home" FM_AUTOMATION_HEALTH_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "automation health check exit"
}

run_registry() {
  local home=$1 action=$2 fixture=$3 out=$4 status=0
  FM_HOME="$home" \
    FM_AUTOMATION_HEALTH_INTERVAL=0 \
    FM_REGISTRY_HEALTH_NOW="$(date -u -d '2026-09-12T00:20:00Z' +%s)" \
    FM_REGISTRY_HEALTH_GRACE_SECS=60 \
    FM_REGISTRY_FIXTURE="$fixture" \
    PATH="$FAKEBIN:$PATH" "$CHECK" "$action" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "automation health $action exit"
}

test_green_rollup_is_compact_and_receipt_backed() {
  local home out first second
  make_home green
  home=$MADE_HOME
  cat > "$FM_REGISTRY_FIXTURE" <<'JSON'
{"automations":[{"id":"secret-parity","source_freshness_age_seconds":12,"queue_age_seconds":0,"last_success_age_seconds":45,"retry_count":1,"open_alerts":[],"last_terminal_receipt":{"type":"automation.run.receipt.v1","terminal":true,"status":"success"}},{"id":"digest","source_freshness_age_seconds":2,"queue_age_seconds":4,"last_success_age_seconds":8,"retry_count":0,"open_alerts":[],"last_terminal_receipt":{"type":"automation.run.receipt.v1","terminal":true,"status":"succeeded"}}]}
JSON
  out="$home/out"
  run_check "$home" "$out"
  first=$(cat "$out")
  assert_contains "$first" 'green' "valid terminal receipts did not produce green rollup"
  assert_contains "$first" 'secret-parity{fresh=12s queue=0s last=45s retries=1 alerts=0 receipt=ok}' \
    "secret-parity metrics were not included"
  assert_contains "$first" 'digest{fresh=2s queue=4s last=8s retries=0 alerts=0 receipt=ok}' \
    "second stream metrics were not included"
  assert_not_contains "$first" 'secret-value' "registry credential was printed"
  run_check "$home" "$out"
  second=$(cat "$out")
  [ -z "$second" ] || fail "unchanged rollup was not deduplicated"
  pass "green automation health requires and reports terminal receipts"
}

test_missing_receipt_is_red() {
  local home out
  make_home missing-receipt
  home=$MADE_HOME
  cat > "$FM_REGISTRY_FIXTURE" <<'JSON'
{"automations":[{"id":"secret-parity","source_freshness_age_seconds":12,"queue_age_seconds":0,"last_success_age_seconds":45,"retry_count":0,"open_alerts":[]}]}
JSON
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'red' "missing receipt did not make status red"
  assert_contains "$(cat "$out")" 'receipt=missing' "missing receipt was not disclosed"
  pass "an execution count without a terminal receipt cannot be green"
}

test_empty_registry_is_green() {
  local home out
  make_home empty-registry
  home=$MADE_HOME
  printf '{"automations":[]}\n' > "$FM_REGISTRY_FIXTURE"
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'green automation health:' \
    "empty registry did not produce green rollup"
  assert_not_contains "$(cat "$out")" 'unavailable' \
    "empty registry was misreported as unavailable"
  pass "reachable empty registry reports green with no streams"
}

test_malformed_registry_is_unavailable() {
  local home out
  make_home malformed-registry
  home=$MADE_HOME
  printf '{"status":"ok"}\n' > "$FM_REGISTRY_FIXTURE"
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'unavailable' \
    "malformed registry body was not reported unavailable"
  assert_not_contains "$(cat "$out")" 'green' \
    "malformed registry body produced false green"
  pass "malformed registry response is not reported healthy"
}

test_missing_id_with_open_alerts_is_red() {
  local home out
  make_home missing-id
  home=$MADE_HOME
  cat > "$FM_REGISTRY_FIXTURE" <<'JSON'
{"automations":[{"source_freshness_age_seconds":12,"queue_age_seconds":0,"last_success_age_seconds":45,"retry_count":0,"open_alerts":[{"msg":"fail"}]}]}
JSON
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'red' \
    "projection without id and open alerts did not force red"
  assert_contains "$(cat "$out")" 'unknown{fresh=12s queue=0s last=45s retries=0 alerts=1 receipt=missing}' \
    "missing-id projection metrics were not included"
  pass "projection without id cannot produce false green"
}

test_lifecycle_uses_registry_and_receipt_schema() {
  local home out
  make_home lifecycle
  home=$MADE_HOME
  printf '{"automations":[]}\n' > "$FM_REGISTRY_FIXTURE"
  out="$home/out"
  FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$CHECK" start secret-parity >"$out" 2>&1 \
    || fail "start failed"
  assert_contains "$(cat "$out")" 'run=run-123' "start did not return registry run id"
  FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$CHECK" heartbeat secret-parity run-123 >"$out" 2>&1 \
    || fail "heartbeat failed"
  FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$CHECK" complete secret-parity run-123 success >"$out" 2>&1 \
    || fail "complete failed"
  assert_contains "$(cat "$out")" 'status=success' "complete did not report success"
  assert_contains "$(cat "$FM_LAST_BODY")" '"type":"automation.run.receipt.v1"' \
    "complete did not send the terminal receipt type"
  assert_contains "$(cat "$FM_LAST_BODY")" '"terminal":true' \
    "complete did not send a terminal receipt"
  assert_not_contains "$(cat "$FM_LAST_BODY")" 'secret-value' "credential reached request body"
  pass "lifecycle actions reuse the registry and send a terminal receipt"
}

test_registry_report_lists_canonical_health_metrics() {
  local home out report
  make_home registry-report
  home=$MADE_HOME
  out="$home/out"
  run_registry "$home" report "$FIXTURES/registry-healthy.json" "$out"
  report=$(cat "$out")
  assert_contains "$report" \
    'automation owner cadence source_freshness_age run_age heartbeat_age open_failures retry_count correlation_id last_run_id health' \
    "registry report omitted metric headings"
  assert_contains "$report" $'s6-02-secret-parity\tinfra\t15 minutes\t1440s\t1500s\t300s\t0\t0\tcorr-healthy\trun-healthy\thealthy' \
    "registry report omitted owner or canonical health ages"
  pass "registry report lists source, run, heartbeat, failure, health, and owner"
}

test_stale_heartbeat_alerts_once_per_fingerprint() {
  local home out first second
  make_home stale-heartbeat
  home=$MADE_HOME
  out="$home/out"
  run_registry "$home" run "$FIXTURES/registry-stale-heartbeat.json" "$out"
  first=$(cat "$out")
  assert_contains "$first" \
    "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" \
    "stale heartbeat did not produce the captain-readable alert"
  : > "$out"
  run_registry "$home" run "$FIXTURES/registry-stale-heartbeat.json" "$out"
  second=$(cat "$out")
  [ -z "$second" ] || fail "same stale fingerprint alerted twice: $second"
  pass "stale heartbeat alerts once per registry fingerprint"
}

test_changed_stale_fingerprint_alerts_again() {
  local home out changed
  make_home stale-fingerprint
  home=$MADE_HOME
  out="$home/out"
  run_registry "$home" run "$FIXTURES/registry-stale-heartbeat.json" "$out"
  : > "$out"
  run_registry "$home" run "$FIXTURES/registry-stale-heartbeat-new-run.json" "$out"
  changed=$(cat "$out")
  assert_contains "$changed" \
    "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" \
    "changed stale fingerprint did not alert again"
  pass "new stale run fingerprint alerts again"
}

test_run_unavailable_reports_failure() {
  local home out
  make_home run-unavailable
  home=$MADE_HOME
  printf '{"status":"ok"}\n' > "$FM_REGISTRY_FIXTURE"
  out="$home/out"
  run_registry "$home" run "$FM_REGISTRY_FIXTURE" "$out"
  assert_contains "$(cat "$out")" 'automation health unavailable' \
    "run did not report unavailable registry"
  pass "run reports unavailable registry"
}

test_registry_report_lists_open_failure() {
  local home out report
  make_home registry-open-failure
  home=$MADE_HOME
  out="$home/out"
  run_registry "$home" report "$FIXTURES/registry-open-failure.json" "$out"
  report=$(cat "$out")
  assert_contains "$report" $'s6-02-secret-parity\tinfra\t15 minutes' \
    "open failure row was not included"
  assert_contains "$report" $'\t1\t2\tcorr-failed\trun-failed\tfailed' \
    "failed terminal outcome did not produce one open failure or identity fields"
  pass "registry report exposes open failure rows"
}

test_armed_check_alerts_once_per_fingerprint() {
  local home out first second
  make_home armed-check
  home=$MADE_HOME
  out="$home/out"
  run_registry "$home" check "$FIXTURES/registry-stale-heartbeat.json" "$out"
  first=$(cat "$out")
  assert_contains "$first" \
    "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" \
    "armed check path did not emit the stale heartbeat alert"
  : > "$out"
  run_registry "$home" check "$FIXTURES/registry-stale-heartbeat.json" "$out"
  second=$(cat "$out")
  [ -z "$second" ] || fail "armed check repeated the same stale fingerprint: $second"
  pass "armed check preserves stale fingerprint deduplication"
}

test_arm_registers_the_stale_heartbeat_runner() {
  local home out status=0
  make_home arm
  home=$MADE_HOME
  FM_HOME="$home" "$CHECK" arm >/dev/null 2>&1 || status=$?
  expect_code 0 "$status" "automation health arm exit"
  assert_present "$home/state/automation-health.check.sh" \
    "arm did not create the watcher shim"
  assert_present "$home/state/automation-health.check-trust" \
    "arm did not create the trust binding"
  out="$home/arm.out"
  FM_REGISTRY_FIXTURE="$FIXTURES/registry-stale-heartbeat.json" \
    FM_REGISTRY_HEALTH_NOW="$(date -u -d '2026-09-12T00:20:00Z' +%s)" \
    FM_AUTOMATION_HEALTH_INTERVAL=0 \
    PATH="$FAKEBIN:$PATH" \
    "$home/state/automation-health.check.sh" >"$out" 2>&1 ||
    fail "armed shim did not execute"
  assert_contains "$(cat "$out")" \
    "infra's s6-02-secret-parity has not reported for 1200s (expected every 15 minutes)" \
    "armed shim did not run the stale heartbeat check"
  FM_HOME="$home" "$CHECK" disarm >/dev/null || fail "disarm failed"
  assert_absent "$home/state/automation-health.check.sh" \
    "disarm left the watcher shim"
  assert_absent "$home/state/automation-health.check-trust" \
    "disarm left the trust binding"
  pass "arm registers the one stale-heartbeat check"
}

test_green_rollup_is_compact_and_receipt_backed
test_missing_receipt_is_red
test_empty_registry_is_green
test_malformed_registry_is_unavailable
test_missing_id_with_open_alerts_is_red
test_lifecycle_uses_registry_and_receipt_schema
test_registry_report_lists_canonical_health_metrics
test_stale_heartbeat_alerts_once_per_fingerprint
test_changed_stale_fingerprint_alerts_again
test_run_unavailable_reports_failure
test_registry_report_lists_open_failure
test_armed_check_alerts_once_per_fingerprint
test_arm_registers_the_stale_heartbeat_runner

printf '# fm-automation-health-check.test.sh: all assertions passed\n'
