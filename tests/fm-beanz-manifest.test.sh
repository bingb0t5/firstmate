#!/usr/bin/env bash
# Behavior tests for fm-beanz-manifest.sh - generates README from temp config only.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-timeout-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-beanz-manifest-tests)
SCRIPT="$ROOT/bin/fm-beanz-manifest.sh"
SECRET='manifest-secret-must-not-appear-554433'
PEM_BODY='MIIEowIBAAKCAQEAsuperSECRETmaterial12345'

setup_config() {
  local dir=$1
  mkdir -p "$dir"
  printf 'COOLIFY_API_TOKEN=%s\nCOOLIFY_URL=https://coolify.example\n' "$SECRET" > "$dir/coolify.env"
  chmod 600 "$dir/coolify.env"
  printf 'POSTHOG_API_KEY=%s\nPOSTHOG_HOST=https://posthog.example\n' "$SECRET" > "$dir/posthog.env"
  chmod 600 "$dir/posthog.env"
  cat > "$dir/posthog.env.beanz" <<'EOF'
service=PostHog analytics (sidecar)
obtain=PostHog project settings
POSTHOG_API_KEY=Sidecar-documented Personal API key
POSTHOG_HOST=Analytics host URL
EOF
}

test_manifest_lists_services_without_secrets() {
  local case_dir="$TMP_ROOT/write"
  local out="$case_dir/README.md"
  setup_config "$case_dir/config"
  FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write --output "$out" \
    || fail "manifest write failed"
  [ -f "$out" ] || fail "README was not written"
  assert_contains "$(cat "$out")" 'PostHog analytics (sidecar)' "sidecar service name should appear"
  assert_contains "$(cat "$out")" 'COOLIFY_API_TOKEN' "Coolify key name should appear"
  assert_contains "$(cat "$out")" 'Bearer token for Coolify API calls' "built-in purpose should appear"
  assert_not_contains "$(cat "$out")" "$SECRET" "manifest must not embed secret values"
  pass "manifest lists services, files, keys, and purposes without secrets"
}

test_manifest_default_output_path() {
  local case_dir="$TMP_ROOT/default"
  local out="$case_dir/config/README.md"
  setup_config "$case_dir/config"
  FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write \
    || fail "default manifest write failed"
  [ -f "$out" ] || fail "default README path was not written"
  assert_not_contains "$(cat "$out")" "$SECRET" "default path manifest leaked a secret"
  pass "manifest writes default README.md under the config dir"
}

test_missing_output_operand_fails_closed() {
  local case_dir="$TMP_ROOT/no-operand" out rc=0
  setup_config "$case_dir/config"
  out=$(
    fm_run_timed 20 env FM_BEANZ_CONFIG_DIR="$case_dir/config" \
      bash "$SCRIPT" write --output 2>&1
  ) || rc=$?
  expect_code 2 "$rc" "a missing --output operand should exit 2, not spin"
  assert_contains "$out" '--output requires a path' "missing operand should say what is missing"
  pass "a missing --output operand fails closed instead of looping forever"
}

test_multiline_value_is_never_listed_as_a_key() {
  local case_dir="$TMP_ROOT/multiline" out
  out="$case_dir/README.md"
  mkdir -p "$case_dir/config"
  printf 'PRIVATE_KEY=-----BEGIN RSA PRIVATE KEY-----\n%s==\n-----END RSA PRIVATE KEY-----\n' \
    "$PEM_BODY" > "$case_dir/config/pem.env"
  chmod 600 "$case_dir/config/pem.env"
  FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write --output "$out" \
    || fail "manifest write failed on a file with a multi-line value"
  assert_not_contains "$(cat "$out")" "$PEM_BODY" \
    "credential material must never be listed as a key in the generated index"
  assert_contains "$(cat "$out")" 'not a plain list of KEY=value lines' \
    "an unparseable credential file should be reported instead of guessed at"
  pass "a multi-line credential value is never emitted as a key row"
}

test_unwritable_output_fails_closed() {
  local case_dir="$TMP_ROOT/unwritable" out rc=0
  setup_config "$case_dir/config"
  out=$(
    FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write \
      --output "$case_dir/missing/README.md" 2>&1
  ) || rc=$?
  expect_code 1 "$rc" "an unwritable output path should exit 1"
  assert_contains "$out" 'fm-beanz-manifest: cannot write the output path' \
    "an unwritable output path should fail through die"
  pass "an unwritable output path fails closed"
}

test_unwritable_output_fails_closed_with_no_credential_files() {
  local case_dir="$TMP_ROOT/unwritable-empty" out rc=0
  mkdir -p "$case_dir/config"
  out=$(
    FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write \
      --output "$case_dir/missing/README.md" 2>&1
  ) || rc=$?
  expect_code 1 "$rc" "exit status must not depend on how many credential files exist"
  assert_contains "$out" 'fm-beanz-manifest: cannot write the output path' \
    "an unwritable output path should fail through die"
  pass "an unwritable output path fails closed even with no credential files"
}

test_manifest_lists_services_without_secrets
test_manifest_default_output_path
test_missing_output_operand_fails_closed
test_multiline_value_is_never_listed_as_a_key
test_unwritable_output_fails_closed
test_unwritable_output_fails_closed_with_no_credential_files
echo "# fm-beanz-manifest.test.sh: all assertions passed"
