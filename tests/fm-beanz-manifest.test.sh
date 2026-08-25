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

test_manifest_lists_services_without_secrets
test_manifest_default_output_path
test_missing_output_operand_fails_closed
echo "# fm-beanz-manifest.test.sh: all assertions passed"
