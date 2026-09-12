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
headers=
for argument in "$@"; do
  case "$argument" in
    *fixture-*-token*|*coolify-secret*|*app-db-secret*)
      [ -z "${FM_RELEASE_TEST_ARGV_MARKER:-}" ] || : > "$FM_RELEASE_TEST_ARGV_MARKER"
      ;;
  esac
done
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) output=$2; shift 2 ;;
    -H|--header)
      if [ "$2" = @- ]; then
        headers="$headers"$'\n'"$(cat)"
      else
        headers="$headers"$'\n'"$2"
      fi
      shift 2
      ;;
    http://*|https://*) url=$1; shift ;;
    *) shift ;;
  esac
done
case "$url" in
  */api/v1/applications/*) body="$FM_RELEASE_COOLIFY_STATUS" ;;
  */api/build-id) body="$FM_RELEASE_BUILD_ID" ;;
  */v1/services/*/deploys/*|*/v1/services/*) body="$FM_RELEASE_RENDER_STATUS" ;;
  */rest/v1/lalo_app_migration_ledger*)
    if [ "${FM_RELEASE_TEST_AUTH:-}" = 1 ]; then
      expected=${FM_RELEASE_TEST_TOKEN:-fixture-app-token}
      bearer_ok=false
      apikey_ok=false
      while IFS= read -r header; do
        case "$header" in
          "Authorization: Bearer $expected") bearer_ok=true ;;
          "apikey: $expected") apikey_ok=true ;;
        esac
      done <<< "$headers"
      if [[ "$url" != https://app-db.test/rest/v1/* ]] ||
        [ "$bearer_ok" != true ] || [ "$apikey_ok" != true ]; then
        printf '{}\n' > "$output"
        printf '401'
        exit 0
      fi
    fi
    body="$FM_RELEASE_LEDGER"
    ;;
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
    {"filename":"20260912120000_checkin_anomaly_review_items.sql","status":"applied"},
    {"filename":"20260912130000_whats_on_editor_decision_exceptions.sql","status":"applied"}
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
  FM_RELEASE_LEDGER='[{"filename":"20260912120000_checkin_anomaly_review_items.sql","status":"applied"}]'
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

test_commit_placeholder_stays_waiting() {
  local home out status=0
  make_home waiting-commit-placeholder
  home=$MADE_HOME
  healthy_fixtures
  # shellcheck disable=SC2089,SC2090
  FM_RELEASE_COOLIFY_STATUS='{"status":"running","git_commit_sha":"HEAD"}'
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
  expect_code 1 "$status" "run should time out while commit is still a placeholder"
  assert_contains "$(cat "$out")" 'waiting for deployment or migration receipt' \
    "HEAD commit placeholder during rollout was not treated as waiting"
  case "$(cat "$out")" in
    *mismatch*) fail "HEAD commit placeholder during rollout was mislabeled as mismatch" ;;
  esac
  pass "commit placeholder stays waiting until observable SHA"
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

make_auth_home() {
  make_home "$1"
  healthy_fixtures
  jq 'del(.ledger.url)' "$MADE_HOME/config/release-receipt.json" > "$MADE_HOME/config/spec.next"
  mv "$MADE_HOME/config/spec.next" "$MADE_HOME/config/release-receipt.json"
  cat > "$MADE_HOME/config/operator db.env" <<'ENV'
SUPABASE_URL=https://generic-db.test
SUPABASE_SERVICE_ROLE_KEY=fixture-generic-token
LALO_APP_SUPABASE_URL=https://app-db.test
LALO_APP_SUPABASE_SERVICE_ROLE_KEY=fixture-app-token
ENV
}

fresh_auth_check() {
  local home=$1
  shift
  env -i HOME="$home" TMPDIR="$TMP_ROOT" PATH="$FAKEBIN:$PATH" \
    FM_RELEASE_TEST_AUTH=1 FM_RELEASE_TEST_ARGV_MARKER="$home/argv-leak" \
    FM_RELEASE_COOLIFY_STATUS="$FM_RELEASE_COOLIFY_STATUS" \
    FM_RELEASE_BUILD_ID="$FM_RELEASE_BUILD_ID" FM_RELEASE_LEDGER="$FM_RELEASE_LEDGER" \
    "$@" > "$home/out" 2>&1
}

test_app_db_names_and_overrides() {
  local home
  make_auth_home app-names
  home=$MADE_HOME
  fresh_auth_check "$home" FM_HOME="$home" \
    FM_RELEASE_APP_DB_ENV_FILE="$home/config/operator db.env" "$CHECK" check
  jq -e '.overall == "healthy" and .migration == "verified"' "$home/state/.release-receipt" >/dev/null \
    || fail "App DB names did not select working credentials ahead of generic names"
  fresh_auth_check "$home" FM_HOME="$home" \
    FM_RELEASE_APP_DB_ENV_FILE="$home/config/operator db.env" \
    FM_RELEASE_APP_DB_URL=https://app-db.test FM_RELEASE_APP_DB_TOKEN=fixture-explicit-token \
    FM_RELEASE_TEST_TOKEN=fixture-explicit-token "$CHECK" check
  jq -e '.migration == "verified"' "$home/state/.release-receipt" >/dev/null \
    || fail "explicit receipt credentials did not override the App DB names"
  fresh_auth_check "$home" FM_HOME="$home" \
    FM_RELEASE_APP_DB_URL=https://app-db.test "$CHECK" check
  jq -e '.migration == "unverified"' "$home/state/.release-receipt" >/dev/null \
    || fail "absent auth was accepted"
  fresh_auth_check "$home" FM_HOME="$home" \
    FM_RELEASE_APP_DB_ENV_FILE="$home/config/operator db.env" \
    FM_RELEASE_APP_DB_TOKEN=fixture-rejected-token "$CHECK" check
  jq -e '.migration == "unverified"' "$home/state/.release-receipt" >/dev/null \
    || fail "rejected explicit auth was replaced with fallback credentials"
  fresh_auth_check "$home" FM_HOME="$home" \
    FM_RELEASE_APP_DB_ENV_FILE="$home/config/operator db.env" \
    FM_RELEASE_APP_DB_URL=https://wrong-db.test "$CHECK" check
  jq -e '.migration == "unverified"' "$home/state/.release-receipt" >/dev/null \
    || fail "explicit receipt URL was ignored"
  cat > "$home/config/generic.env" <<'ENV'
SUPABASE_URL=https://app-db.test
SUPABASE_SERVICE_ROLE_KEY=fixture-app-token
ENV
  fresh_auth_check "$home" FM_HOME="$home" \
    FM_RELEASE_APP_DB_ENV_FILE="$home/config/generic.env" "$CHECK" check
  jq -e '.migration == "verified"' "$home/state/.release-receipt" >/dev/null \
    || fail "generic credential fallback stopped working"
  pass "App DB names, explicit overrides, and absent/rejected authentication are respected"
}

test_arm_preserves_lookup_across_processes() {
  local home file
  make_auth_home 'armed home'
  home=$MADE_HOME
  (
    cd "$home" || exit 1
    FM_HOME="$home" FM_RELEASE_APP_DB_ENV_FILE='config/operator db.env' \
      FM_RELEASE_APP_DB_TOKEN=fixture-never-persist-token \
      "$CHECK" arm --spec config/release-receipt.json > "$home/arm.out"
  ) || fail "arming with relative input paths failed"
  (
    cd "$TMP_ROOT" || exit 1
    fresh_auth_check "$home" "$home/state/release-receipt.check.sh"
  ) || fail "fresh-process shim execution failed"
  jq -e '.overall == "healthy" and .migration == "verified"' "$home/state/.release-receipt" >/dev/null \
    || fail "arming did not retain env-file and manifest lookup outside the original cwd"
  for file in "$home/state/release-receipt.check.sh" "$home/state/.release-receipt" "$home/out"; do
    case "$(cat "$file")" in
      *fixture-*-token*) fail "generated output serialized a credential" ;;
    esac
  done
  assert_present "$home/state/release-receipt.check-trust" "arming did not register the new shim"
  assert_absent "$home/argv-leak" "curl received credentials as command arguments"
  pass "armed checks retain only normalized nonsecret paths and authenticate from a fresh process"
}

test_coolify_combined_status_requires_release_evidence() {
  local home commit build expected
  make_home combined-status
  home=$MADE_HOME
  healthy_fixtures
  for expected in healthy head stale missing wrong; do
    commit=ada46a5dda0a1d654c29acf82a6db20d8296c407
    build=dev-mty0b1u3
    case "$expected" in
      head) commit=HEAD ;;
      stale) build=prior-live-build ;;
      missing) commit= ;;
      wrong) commit=7576626447416cf71ea2aa92aafa15d75921ed16 ;;
    esac
    FM_RELEASE_COOLIFY_STATUS=$(jq -cn --arg commit "$commit" '{status:"running:healthy",git_commit_sha:$commit}')
    FM_RELEASE_BUILD_ID=$build
    export FM_RELEASE_COOLIFY_STATUS FM_RELEASE_BUILD_ID
    run_check "$home" "$home/out"
    case "$expected" in
      healthy) expected=healthy ;;
      wrong) expected=mismatch ;;
      *) expected=waiting ;;
    esac
    jq -e --arg expected "$expected" '.overall == $expected' "$home/state/.release-receipt" >/dev/null \
      || fail "running:healthy did not respect independent commit/build evidence"
  done
  pass "Coolify running:healthy requires observable matching commit and build"
}

test_ledger_requires_affirmative_applied_status() {
  local home ledger_status
  make_home applied-evidence
  home=$MADE_HOME
  for ledger_status in unapplied unknown missing null applied; do
    healthy_fixtures
    FM_RELEASE_LEDGER=$(jq -c --arg state "$ledger_status" '
      if $state == "missing" then map(del(.status))
      elif $state == "null" then map(.status = null)
      else map(.status = $state) end' <<< "$FM_RELEASE_LEDGER")
    export FM_RELEASE_LEDGER
    run_check "$home" "$home/out"
    if [ "$ledger_status" = applied ]; then
      jq -e '.migration == "verified"' "$home/state/.release-receipt" >/dev/null \
        || fail "applied ledger rows were not verified"
    else
      jq -e '.migration == "unverified" and .overall != "healthy"' "$home/state/.release-receipt" >/dev/null \
        || fail "ledger row without affirmative applied evidence was verified"
    fi
  done
  pass "unapplied, unknown, missing, and null ledger status cannot complete a release"
}

test_transport_keeps_credentials_out_of_argv() {
  local home
  make_home private-transport
  home=$MADE_HOME
  healthy_fixtures
  FM_RELEASE_TEST_ARGV_MARKER="$home/argv-leak" run_check "$home" "$home/out"
  assert_absent "$home/argv-leak" "curl received credentials as command arguments"
  jq -e '.overall == "healthy"' "$home/state/.release-receipt" >/dev/null \
    || fail "private header transport lost the release response"
  pass "credential-bearing request headers never enter curl argv"
}

case "${1:-all}" in
  auth) test_app_db_names_and_overrides; exit ;;
  arm) test_arm_preserves_lookup_across_processes; exit ;;
  coolify) test_coolify_combined_status_requires_release_evidence; exit ;;
  ledger) test_ledger_requires_affirmative_applied_status; exit ;;
  transport) test_transport_keeps_credentials_out_of_argv; exit ;;
  all) ;;
  *) fail "unknown release receipt test group" ;;
esac

test_healthy_release_is_complete
test_healthy_app_unverified_migration_is_distinct
test_commit_mismatch_is_reported
test_render_target_uses_deploy_completion_and_build
test_check_deduplicates_unchanged_receipt
test_build_id_url_json_build_field_is_parsed
test_stale_build_id_before_commit_stays_waiting
test_stale_build_id_after_matching_commit_stays_waiting
test_complete_status_without_commit_stays_waiting
test_commit_placeholder_stays_waiting
test_manifest_error_deduplicates
test_arm_and_disarm_use_custom_check_registration
test_app_db_names_and_overrides
test_arm_preserves_lookup_across_processes
test_coolify_combined_status_requires_release_evidence
test_ledger_requires_affirmative_applied_status
test_transport_keeps_credentials_out_of_argv
