#!/usr/bin/env bash
# Behavior tests for fm-coolify-env.sh - credential-touching Coolify env updates
# must never print secret material on any path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-coolify-env-tests)
SCRIPT="$ROOT/bin/fm-coolify-env.sh"
SECRET='sekret-never-print-xyzzy-998877'
FAKE_TOKEN='coolify-api-fake-token-445566'
FAKE_URL='https://coolify.test.example'

setup_config() {
  local dir=$1
  mkdir -p "$dir"
  printf 'COOLIFY_URL=%s\nCOOLIFY_API_TOKEN=%s\n' "$FAKE_URL" "$FAKE_TOKEN" > "$dir/coolify.env"
  chmod 600 "$dir/coolify.env"
  printf 'COOLIFY_SERVICE_brain=%s\n' 'app-uuid-1234' > "$dir/coolify-services.env"
  chmod 600 "$dir/coolify-services.env"
  printf 'POSTHOG_API_KEY=%s\n' "$SECRET" > "$dir/posthog.env"
  chmod 600 "$dir/posthog.env"
  printf 'BRAIN_TOKENS=%s:n8n,%s:rich\n' "$SECRET" 'tok_public_rich' > "$dir/brain.env"
  chmod 600 "$dir/brain.env"
}

make_fakebin() {
  local dir=$1 fakebin log=$2 mode=${3:-ok}
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\${FM_FAKE_CURL_MODE:-$mode}" in
  ok)
    printf '{"uuid":"env-1"}\n200'
    exit 0
    ;;
  auth)
    printf '{"message":"Unauthorized"}\n401'
    exit 0
    ;;
  network)
    exit 7
    ;;
  missing)
    printf '{"message":"Not found"}\n404'
    exit 0
    ;;
  *)
    printf 'error\n500'
    exit 0
    ;;
esac
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

capture_run() {
  local case_dir=$1
  shift
  local fakebin out rc=0
  fakebin=$(make_fakebin "$case_dir" "$case_dir/curl.log" "${FM_FAKE_CURL_MODE:-ok}")
  out=$(
    env FM_BEANZ_CONFIG_DIR="$case_dir/config" \
      PATH="$fakebin:$BASE_PATH" \
      bash -x "$SCRIPT" "$@" 2>&1
  ) || rc=$?
  CAPTURE_OUT=$out
  CAPTURE_RC=$rc
}

assert_no_secret() {
  local label=$1
  assert_not_contains "$CAPTURE_OUT" "$SECRET" "$label leaked the secret on stdout/stderr/trace"
  assert_not_contains "$CAPTURE_OUT" "$FAKE_TOKEN" "$label leaked the Coolify API token"
}

test_success_from_env_file() {
  local case_dir="$TMP_ROOT/success-env"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain POSTHOG_API_KEY --value-from "env:posthog.env:POSTHOG_API_KEY"
  expect_code 0 "$CAPTURE_RC" "success path should exit 0"
  assert_contains "$CAPTURE_OUT" 'ok: brain POSTHOG_API_KEY set' "success path should print ok line"
  assert_no_secret "success path"
  pass "success path prints ok and never leaks the secret"
}

test_auth_failure() {
  local case_dir="$TMP_ROOT/auth-fail"
  setup_config "$case_dir/config"
  FM_FAKE_CURL_MODE=auth capture_run "$case_dir" set brain POSTHOG_API_KEY --value-from "env:posthog.env:POSTHOG_API_KEY"
  expect_code 1 "$CAPTURE_RC" "auth failure should exit non-zero"
  assert_not_contains "$CAPTURE_OUT" 'ok:' "auth failure must not print ok"
  assert_no_secret "auth failure"
  pass "auth failure exits non-zero without leaking the secret"
}

test_malformed_value_from() {
  local case_dir="$TMP_ROOT/malformed"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain POSTHOG_API_KEY --value-from 'env:../etc/passwd:POSTHOG_API_KEY'
  expect_code 1 "$CAPTURE_RC" "malformed source should exit non-zero"
  assert_no_secret "malformed --value-from"
  pass "malformed --value-from fails closed without leaking the secret"
}

test_network_failure() {
  local case_dir="$TMP_ROOT/network"
  setup_config "$case_dir/config"
  FM_FAKE_CURL_MODE=network capture_run "$case_dir" set brain POSTHOG_API_KEY --value-from "env:posthog.env:POSTHOG_API_KEY"
  expect_code 1 "$CAPTURE_RC" "network failure should exit non-zero"
  assert_no_secret "network failure"
  pass "network failure exits non-zero without leaking the secret"
}

test_missing_key() {
  local case_dir="$TMP_ROOT/missing-key"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain MISSING_KEY --value-from 'env:posthog.env:MISSING_KEY'
  expect_code 1 "$CAPTURE_RC" "missing key should exit non-zero"
  assert_no_secret "missing key"
  pass "missing key exits non-zero without leaking the secret"
}

test_brain_identity_lookup() {
  local case_dir="$TMP_ROOT/brain"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain BRAIN_TOKEN_N8N --value-from 'brain:n8n'
  expect_code 0 "$CAPTURE_RC" "brain identity lookup should succeed"
  assert_contains "$CAPTURE_OUT" 'ok: brain BRAIN_TOKEN_N8N set' "brain lookup should print ok"
  assert_no_secret "brain identity lookup"
  pass "brain identity lookup succeeds without leaking the token"
}

test_success_from_env_file
test_auth_failure
test_malformed_value_from
test_network_failure
test_missing_key
test_brain_identity_lookup
echo "# fm-coolify-env.test.sh: all assertions passed"
