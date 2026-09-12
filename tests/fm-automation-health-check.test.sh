#!/usr/bin/env bash
# Tests for fm-automation-health-check.sh.
#
# The fake registry returns only projection fields and never logs request
# headers, so credentials can be asserted absent from every user-facing result.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-automation-health-check.sh"
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

test_green_rollup_is_compact_and_receipt_backed
test_missing_receipt_is_red
test_empty_registry_is_green
test_malformed_registry_is_unavailable
test_missing_id_with_open_alerts_is_red
test_lifecycle_uses_registry_and_receipt_schema

printf '# fm-automation-health-check.test.sh: all assertions passed\n'
