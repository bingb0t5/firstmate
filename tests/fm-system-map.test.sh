#!/usr/bin/env bash
# Tests for fm-system-map.sh.
#
# The fixtures model the five evidence sources without contacting the
# automation registry or n8n.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-system-map.sh"
TMP_ROOT=$(fm_test_tmproot fm-system-map)

make_fixture() {
  local name=$1
  local home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/repo/n8n" "$home/radar/reports"
  cat > "$home/manifests.json" <<'JSON'
{"manifests":[{"manifest_id":"daily-map","manifest_version":"1","owner":"n8n","cadence":"daily","host_id":"lalo-dev"}]}
JSON
  cat > "$home/hosts.json" <<'JSON'
{"hosts":[{"id":"lalo-dev","status":"healthy","reachable":true}]}
JSON
  cat > "$home/registry.json" <<'JSON'
{"automations":[{"manifest_id":"daily-map","manifest_version":"1","owner":"n8n","cadence":"daily","host_id":"lalo-dev","health":"healthy","terminal_outcome":"succeeded","last_success_at":"2026-09-11T10:00:00.000Z"}]}
JSON
  printf '{"name":"daily-map","nodes":[],"connections":{}}\n' > "$home/repo/n8n/daily-map.json"
  cat > "$home/n8n-comparison.json" <<'JSON'
{"schema":"n8n.workflow.comparison.v1","generated_at":"2026-09-12T00:00:00.000Z","committed_count":1,"live_count":1,"matching":["daily-map"],"drifted":[],"missing_live":[],"extra_live":[],"credential_values_checked":false}
JSON
  cat > "$home/radar/reports/weekly-2026-09-11.md" <<'MD'
# Engineering Radar weekly report

## Findings

### Evidence manifests
The radar found a new evidence-manifest practice.

### Repository feedback
The radar found a repository feedback change.
MD
  MADE_HOME=$home
}

MAP_NOW=$(date -d 2026-09-12T12:00:00Z +%s)

run_map() {
  local home=$1 action=$2 output=$3 interval=${4:-0} now=${5:-$MAP_NOW} status=0
  FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_SYSTEM_MAP_INTERVAL="$interval" \
    FM_SYSTEM_MAP_NOW="$now" \
    "$CHECK" "$action" \
    --manifests "$home/manifests.json" \
    --hosts "$home/hosts.json" \
    --repo "$home/repo" \
    --radar-root "$home/radar" \
    --registry-file "$home/registry.json" \
    --n8n-comparison "$home/n8n-comparison.json" \
    --output-json "$home/report.json" \
    --output-markdown "$home/report.md" > "$output" 2>&1 || status=$?
  printf '%s\n' "$status"
}

test_green_map_has_all_sources() {
  local home out status report markdown
  make_fixture green
  home=$MADE_HOME
  out="$home/out"
  status=$(run_map "$home" score "$out")
  expect_code 0 "$status" "green system-map score"
  report=$(cat "$home/report.json")
  markdown=$(cat "$home/report.md")
  assert_contains "$report" '"schema": "firstmate.system-map.v1"' \
    "system map schema was not emitted"
  assert_contains "$report" '"status": "pass"' \
    "matching evidence sources did not produce a passing score"
  assert_contains "$report" '"changed_this_week"' \
    "changed-this-week section was not included"
  assert_contains "$report" 'Evidence manifests' \
    "Engineering Radar finding was not sourced into the map"
  assert_contains "$report" 'daily-map' \
    "declared workflow was not included"
  assert_contains "$markdown" 'Source: Engineering Radar (available).' \
    "markdown map did not identify its radar source"
  pass "system map combines declarations, registry, host, export, live, and radar evidence"
}

test_drift_fails_daily_score() {
  local home out status report
  make_fixture drift
  home=$MADE_HOME
  cat > "$home/registry.json" <<'JSON'
{"automations":[{"manifest_id":"daily-map","manifest_version":"1","owner":"n8n","cadence":"daily","host_id":"lalo-dev","health":"failed","terminal_outcome":"failed","last_success_at":null}]}
JSON
  cat > "$home/n8n-comparison.json" <<'JSON'
{"schema":"n8n.workflow.comparison.v1","generated_at":"2026-09-12T00:00:00.000Z","committed_count":1,"live_count":2,"matching":[],"drifted":[{"name":"daily-map","committed_sha256":"a","live_sha256":"b"}],"missing_live":[],"extra_live":["surprise"],"credential_values_checked":false}
JSON
  out="$home/out"
  status=$(run_map "$home" score "$out")
  expect_code 1 "$status" "drifted system-map score"
  report=$(cat "$home/report.json")
  assert_contains "$report" '"status": "fail"' \
    "reality disagreement did not fail the daily score"
  assert_contains "$report" 'registry outcome daily-map is not healthy' \
    "registry disagreement was not reported"
  assert_contains "$report" 'X-05 found drifted n8n workflow exports' \
    "repo/live n8n drift was not reported"
  assert_contains "$report" 'live n8n workflows without repository exports' \
    "extra live n8n workflow was not reported"
  pass "daily score fails on registry and live n8n drift"
}

test_check_dedupes_stable_digest() {
  local home out first second
  make_fixture dedup
  home=$MADE_HOME
  out="$home/out"
  run_map "$home" check "$out" 86400 "$MAP_NOW" >/dev/null
  first=$(cat "$out")
  assert_contains "$first" 'system map: pass' \
    "first check did not print the initial pass notification"
  : > "$out"
  run_map "$home" check "$out" 86400 "$MAP_NOW" >/dev/null
  second=$(cat "$out")
  [ -z "$second" ] || fail "stable digest check was not silent: $second"
  pass "armed check on stable digest produces no stdout"
}

test_check_interval_zero_stable_digest_silent() {
  local home out first second
  make_fixture interval-zero
  home=$MADE_HOME
  out="$home/out"
  run_map "$home" check "$out" 0 "$MAP_NOW" >/dev/null
  first=$(cat "$out")
  assert_contains "$first" 'system map: pass' \
    "interval-zero first check did not print the initial notification"
  : > "$out"
  run_map "$home" check "$out" 0 "$MAP_NOW" >/dev/null
  second=$(cat "$out")
  [ -z "$second" ] || fail "interval-zero stable digest check was not silent: $second"
  pass "interval-zero check on stable digest produces no stdout"
}

test_score_always_prints() {
  local home out first second
  make_fixture score-print
  home=$MADE_HOME
  out="$home/out"
  run_map "$home" score "$out" 86400 "$MAP_NOW" >/dev/null
  first=$(cat "$out")
  assert_contains "$first" 'system map: pass' \
    "first score did not print a notification"
  run_map "$home" score "$out" 86400 "$MAP_NOW" >/dev/null
  second=$(cat "$out")
  assert_contains "$second" 'system map: pass' \
    "second score did not print on an unchanged digest"
  pass "score command always prints notification even when digest is unchanged"
}

test_check_within_interval_skips() {
  local home out later=$((MAP_NOW + 3600))
  make_fixture sweep-skip
  home=$MADE_HOME
  out="$home/out"
  run_map "$home" check "$out" 86400 "$MAP_NOW" >/dev/null
  assert_contains "$(cat "$out")" 'system map: pass' \
    "initial sweep did not print"
  : > "$out"
  run_map "$home" check "$out" 86400 "$later" >/dev/null
  [ ! -s "$out" ] || fail "check within daily interval was not silent: $(cat "$out")"
  pass "check within daily sweep interval skips work entirely"
}

test_check_digest_change_prints_notification() {
  local home out later=$((MAP_NOW + 86401))
  make_fixture digest-change
  home=$MADE_HOME
  out="$home/out"
  run_map "$home" check "$out" 86400 "$MAP_NOW" >/dev/null
  assert_contains "$(cat "$out")" 'system map: pass' \
    "baseline sweep did not print pass"
  cat > "$home/registry.json" <<'JSON'
{"automations":[{"manifest_id":"daily-map","manifest_version":"1","owner":"n8n","cadence":"daily","host_id":"lalo-dev","health":"failed","terminal_outcome":"failed","last_success_at":null}]}
JSON
  : > "$out"
  run_map "$home" check "$out" 86400 "$later" >/dev/null
  assert_contains "$(cat "$out")" 'system map: fail' \
    "digest change after interval did not print fail notification"
  pass "check after digest change on next due sweep prints updated fail notification"
}

test_operator_arm_disarm_lifecycle() {
  local home status=0
  make_fixture arm
  home=$MADE_HOME
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$CHECK" arm >"$home/arm.out" 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/system-map.check.sh" "arm did not create the private check shim"
  assert_present "$home/state/system-map.check-trust" "arm did not register the trust binding"
  [ -x "$home/state/system-map.check.sh" ] || fail "armed check shim is not executable"
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    "$CHECK" disarm >"$home/disarm.out" 2>&1 || status=$?
  expect_code 0 "$status" "disarm exit"
  assert_absent "$home/state/system-map.check.sh" "disarm left the private check shim"
  assert_absent "$home/state/system-map.check-trust" "disarm left the trust binding"
  pass "operator arm and disarm manage watcher check shim lifecycle"
}

test_green_map_has_all_sources
test_drift_fails_daily_score
test_check_dedupes_stable_digest
test_check_interval_zero_stable_digest_silent
test_score_always_prints
test_check_within_interval_skips
test_check_digest_change_prints_notification
test_operator_arm_disarm_lifecycle

printf '# fm-system-map.test.sh: all assertions passed\n'
