#!/usr/bin/env bash
# shellcheck disable=SC2089,SC2090
# Tests for fm-release-receipt-check.sh.
#
# The transport fixtures contain only deployment and ledger responses. The
# fake provider never prints request headers or credential values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-release-receipt-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-release-receipt)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
output=
url=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */api/v1/applications/*) body="$FM_RELEASE_COOLIFY_STATUS" ;;
  */api/build-id) body="$FM_RELEASE_BUILD_ID" ;;
  */v1/services/*/deploys/*|*/v1/services/*) body="$FM_RELEASE_RENDER_STATUS" ;;
  */rest/v1/lalo_app_migration_ledger*) body="$FM_RELEASE_LEDGER" ;;
  *) exit 1 ;;
esac
printf '%s\n' "$body" > "$output"
printf '200'
SH
chmod 0755 "$FAKEBIN/curl"

make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  cat > "$home/config/release-receipt.json" <<'JSON'
{
  "release_id": "admin-prod-2026-09-12",
  "intended_commit": "ada46a5dda0a1d654c29acf82a6db20d8296c407",
  "targets": [
    {
      "provider": "coolify",
      "app_id": "ga48pn39tt4b9bswgsuaqu7v",
      "status_url": "https://coolify.test/api/v1/applications/ga48pn39tt4b9bswgsua7v",
      "build_id_url": "https://admin.test/api/build-id",
      "expected_build_id": "dev-mty0b1u3"
    }
  ],
  "migrations": [
    {"name": "20260912120000_checkin_anomaly_review_items.sql"},
    {"name": "20260912130000_whats_on_editor_decision_exceptions.sql"}
  ],
  "ledger": {
    "url": "https://db.test/rest/v1/lalo_app_migration_ledger?select=*",
    "project_ref": "evvrlbeilubeggmrhjgs"
  }
}
JSON
  MADE_HOME=$home
}

run_check() {
  local home=$1 out=$2 status=0
  FM_HOME="$home" \
    FM_RELEASE_COOLIFY_URL=https://coolify.test \
    FM_RELEASE_COOLIFY_API_TOKEN=coolify-secret \
    FM_RELEASE_APP_DB_TOKEN=app-db-secret \
    FM_RELEASE_POLL_SECS=0 \
    FM_FAKE=1 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "release receipt check exit"
}

healthy_fixtures() {
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_COOLIFY_STATUS='{"status":"running","git_commit_sha":"ada46a5dda0a1d654c29acf82a6db20d8296c407"}'
  FM_RELEASE_BUILD_ID='dev-mty0b1u3'
  FM_RELEASE_RENDER_STATUS='{}'
  FM_RELEASE_LEDGER='[
    {"name":"20260912120000_checkin_anomaly_review_items.sql"},
    {"name":"20260912130000_whats_on_editor_decision_exceptions.sql"}
  ]'
  export FM_RELEASE_COOLIFY_STATUS FM_RELEASE_BUILD_ID FM_RELEASE_RENDER_STATUS FM_RELEASE_LEDGER
}

test_healthy_release_is_complete() {
  local home out
  make_home healthy
  home=$MADE_HOME
  healthy_fixtures
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'app=healthy migration=verified' \
    "healthy release was not reported as complete"
  assert_contains "$(cat "$home/state/.release-receipt")" '"overall": "healthy"' \
    "healthy release did not leave a durable receipt"
  pass "release receipt verifies commit, build id, and migration ledger"
}

test_healthy_app_unverified_migration_is_distinct() {
  local home out
  make_home unverified
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_LEDGER='[{"name":"20260912120000_checkin_anomaly_review_items.sql"}]'
  export FM_RELEASE_LEDGER
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'app=healthy migration=unverified' \
    "healthy app with missing migration was not distinguished"
  assert_contains "$(cat "$home/state/.release-receipt")" '"overall": "unverified"' \
    "unverified migration did not persist its audit state"
  pass "audit distinguishes healthy app from unverified migration"
}

test_commit_mismatch_is_reported() {
  local home out
  make_home mismatch
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_COOLIFY_STATUS='{"status":"running","git_commit_sha":"7576626447416cf71ea2aa92aafa15d75921ed16"}'
  export FM_RELEASE_COOLIFY_STATUS
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'mismatch' \
    "deployed commit mismatch was not reported"
  assert_contains "$(cat "$home/state/.release-receipt")" 'deployed commit mismatch' \
    "commit mismatch was not retained in the receipt"
  pass "release receipt reports a deployed commit mismatch"
}

test_render_target_uses_deploy_completion_and_build() {
  local home out
  make_home render
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_RENDER_STATUS='{"status":"live","commit":{"id":"ada46a5dda0a1d654c29acf82a6db20d8296c407"},"build_id":"render-build-20260912"}'
  export FM_RELEASE_RENDER_STATUS
  jq '.targets = [{
    provider: "render",
    service_id: "srv-admin",
    deploy_id: "dep-admin",
    status_url: "https://render.test/v1/services/srv-admin/deploys/dep-admin",
    expected_build_id: "render-build-20260912"
  }]' "$home/config/release-receipt.json" > "$home/config/release-receipt.json.next"
  mv "$home/config/release-receipt.json.next" "$home/config/release-receipt.json"
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'app=healthy migration=verified' \
    "Render deployment was not verified as healthy"
  pass "Render deployment status and build id are receipt-backed"
}

test_check_deduplicates_unchanged_receipt() {
  local home out first second
  make_home dedupe
  home=$MADE_HOME
  healthy_fixtures
  out="$home/out"
  run_check "$home" "$out"
  first=$(cat "$out")
  : > "$out"
  run_check "$home" "$out"
  second=$(cat "$out")
  [ -n "$first" ] || fail "initial healthy receipt did not alert"
  [ -z "$second" ] || fail "unchanged receipt was not deduplicated"
  pass "watcher check deduplicates an unchanged durable receipt"
}

test_build_id_url_json_build_field_is_parsed() {
  local home out
  make_home build-json
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_BUILD_ID='{"build":"dev-mty0b1u3"}'
  export FM_RELEASE_BUILD_ID
  out="$home/out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'app=healthy migration=verified' \
    "JSON build field from build_id_url was not parsed"
  pass "build_id_url JSON {\"build\":...} shape is receipt-backed"
}

test_stale_build_id_before_commit_stays_waiting() {
  local home out status=0
  make_home waiting-build
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_COOLIFY_STATUS='{"status":"running"}'
  FM_RELEASE_BUILD_ID='prior-live-build'
  export FM_RELEASE_COOLIFY_STATUS FM_RELEASE_BUILD_ID
  out="$home/out"
  FM_HOME="$home" \
    FM_RELEASE_COOLIFY_URL=https://coolify.test \
    FM_RELEASE_COOLIFY_API_TOKEN=coolify-secret \
    FM_RELEASE_APP_DB_TOKEN=app-db-secret \
    FM_RELEASE_POLL_SECS=0 \
    FM_RELEASE_TIMEOUT_SECS=1 \
    FM_FAKE=1 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" run >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "run should time out while commit is still empty"
  assert_contains "$(cat "$out")" 'waiting for deployment or migration receipt' \
    "stale build id during rollout was not treated as waiting"
  case "$(cat "$out")" in
    *mismatch*) fail "stale build id before commit was mislabeled as mismatch" ;;
  esac
  pass "stale build id before commit observable stays waiting"
}

test_stale_build_id_after_matching_commit_stays_waiting() {
  local home out status=0
  make_home waiting-build-after-commit
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_COOLIFY_STATUS='{"status":"running","git_commit_sha":"ada46a5dda0a1d654c29acf82a6db20d8296c407"}'
  FM_RELEASE_BUILD_ID='prior-live-build'
  export FM_RELEASE_COOLIFY_STATUS FM_RELEASE_BUILD_ID
  out="$home/out"
  FM_HOME="$home" \
    FM_RELEASE_COOLIFY_URL=https://coolify.test \
    FM_RELEASE_COOLIFY_API_TOKEN=coolify-secret \
    FM_RELEASE_APP_DB_TOKEN=app-db-secret \
    FM_RELEASE_POLL_SECS=0 \
    FM_RELEASE_TIMEOUT_SECS=1 \
    FM_FAKE=1 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" run >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "run should time out while build id is still stale"
  assert_contains "$(cat "$out")" 'waiting for deployment or migration receipt' \
    "stale build id after matching commit was not treated as waiting"
  case "$(cat "$out")" in
    *mismatch*) fail "stale build id after matching commit was mislabeled as mismatch" ;;
  esac
  pass "stale build id after matching commit stays waiting"
}

test_complete_status_without_commit_stays_waiting() {
  local home out status=0
  make_home waiting-commit
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_COOLIFY_STATUS='{"status":"running"}'
  export FM_RELEASE_COOLIFY_STATUS
  out="$home/out"
  FM_HOME="$home" \
    FM_RELEASE_COOLIFY_URL=https://coolify.test \
    FM_RELEASE_COOLIFY_API_TOKEN=coolify-secret \
    FM_RELEASE_APP_DB_TOKEN=app-db-secret \
    FM_RELEASE_POLL_SECS=0 \
    FM_RELEASE_TIMEOUT_SECS=1 \
    FM_FAKE=1 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" run >"$out" 2>&1 || status=$?
  expect_code 1 "$status" "run should time out while commit is still empty"
  assert_contains "$(cat "$out")" 'waiting for deployment or migration receipt' \
    "empty commit during rollout was not treated as waiting"
  case "$(cat "$out")" in
    *mismatch*) fail "empty commit during rollout was mislabeled as mismatch" ;;
  esac
  pass "complete status with empty commit stays waiting until observable"
}

test_manifest_error_deduplicates() {
  local home out first second
  make_home manifest-dedupe
  home=$MADE_HOME
  rm -f "$home/config/release-receipt.json"
  out="$home/out"
  FM_HOME="$home" \
    FM_RELEASE_COOLIFY_URL=https://coolify.test \
    FM_RELEASE_COOLIFY_API_TOKEN=coolify-secret \
    FM_RELEASE_APP_DB_TOKEN=app-db-secret \
    FM_FAKE=1 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" >"$out" 2>&1 || true
  first=$(cat "$out")
  : > "$out"
  FM_HOME="$home" \
    FM_RELEASE_COOLIFY_URL=https://coolify.test \
    FM_RELEASE_COOLIFY_API_TOKEN=coolify-secret \
    FM_RELEASE_APP_DB_TOKEN=app-db-secret \
    FM_FAKE=1 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" >"$out" 2>&1 || true
  second=$(cat "$out")
  assert_contains "$first" 'manifest is missing' \
    "missing manifest did not alert once"
  [ -z "$second" ] || fail "missing manifest alert was not deduplicated"
  pass "manifest errors deduplicate like other watcher alerts"
}

test_arm_and_disarm_use_custom_check_registration() {
  local home out
  make_home arm
  home=$MADE_HOME
  out="$home/out"
  FM_HOME="$home" FM_RELEASE_SPEC_FILE="$home/config/release-receipt.json" \
    PATH="$FAKEBIN:$PATH" "$CHECK" arm >"$out" 2>&1 || fail "arm failed"
  assert_present "$home/state/release-receipt.check.sh" "arm did not create watcher check"
  assert_present "$home/state/release-receipt.check-trust" "arm did not bind watcher check"
  FM_HOME="$home" PATH="$FAKEBIN:$PATH" "$CHECK" disarm >"$out" 2>&1 \
    || fail "disarm failed"
  assert_absent "$home/state/release-receipt.check.sh" "disarm left watcher check"
  pass "release receipt uses the existing watcher registration pattern"
}

test_healthy_release_is_complete
test_healthy_app_unverified_migration_is_distinct
test_commit_mismatch_is_reported
test_render_target_uses_deploy_completion_and_build
test_check_deduplicates_unchanged_receipt
test_build_id_url_json_build_field_is_parsed
test_stale_build_id_before_commit_stays_waiting
test_stale_build_id_after_matching_commit_stays_waiting
test_complete_status_without_commit_stays_waiting
test_manifest_error_deduplicates
test_arm_and_disarm_use_custom_check_registration
