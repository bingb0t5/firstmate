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

run_map() {
  local home=$1 action=$2 output=$3 status=0
  FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_SYSTEM_MAP_INTERVAL=0 \
    FM_SYSTEM_MAP_NOW="$(date -d 2026-09-12T12:00:00Z +%s)" \
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

test_green_map_has_all_sources
test_drift_fails_daily_score

printf '# fm-system-map.test.sh: all assertions passed\n'
