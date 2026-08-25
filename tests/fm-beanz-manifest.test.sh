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
PEM_BODY='QUJDREVGRw'

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

test_unknown_argument_is_value_free() {
  local case_dir="$TMP_ROOT/unknown-argument" out rc=0
  setup_config "$case_dir/config"
  out=$(
    FM_BEANZ_CONFIG_DIR="$case_dir/config" bash -x "$SCRIPT" write "$SECRET" 2>&1
  ) || rc=$?
  expect_code 2 "$rc" "an unknown argument should exit 2"
  assert_contains "$out" 'fm-beanz-manifest: unknown argument' \
    "an unknown argument should produce a generic diagnostic"
  assert_not_contains "$out" "$SECRET" \
    "an unknown argument must not be echoed in combined output or shell trace"
  pass "an unknown argument produces only a value-free error"
}

test_multiline_value_is_never_listed_as_a_key() {
  local case_dir="$TMP_ROOT/multiline" out
  out="$case_dir/README.md"
  mkdir -p "$case_dir/config"
  printf 'PRIVATE_KEY=-----BEGIN RSA PRIVATE KEY-----\n%s==\n' \
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

test_shell_trace_never_contains_live_values() {
  local case_dir="$TMP_ROOT/trace" out trace rc=0
  out="$case_dir/README.md"
  setup_config "$case_dir/config"
  trace=$(
    FM_BEANZ_CONFIG_DIR="$case_dir/config" bash -x "$SCRIPT" write --output "$out" 2>&1
  ) || rc=$?
  expect_code 0 "$rc" "manifest generation under shell tracing should succeed"
  [ -f "$out" ] || fail "shell-traced manifest generation did not write its output"
  assert_not_contains "$trace" "$SECRET" "shell tracing must not expose live credential values"
  pass "manifest generation disables shell tracing before reading credentials"
}

test_output_aliases_inputs_fail_closed() {
  local case_dir="$TMP_ROOT/input-alias" out rc
  setup_config "$case_dir/config"
  cp "$case_dir/config/coolify.env" "$case_dir/coolify.before"
  cp "$case_dir/config/posthog.env.beanz" "$case_dir/sidecar.before"

  rc=0
  out=$(
    FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write \
      --output "$case_dir/config/coolify.env" 2>&1
  ) || rc=$?
  expect_code 1 "$rc" "a credential file cannot be the manifest output"
  assert_contains "$out" 'output path aliases an input file' \
    "a direct input alias should produce a value-free error"
  cmp -s "$case_dir/config/coolify.env" "$case_dir/coolify.before" \
    || fail "a direct output alias modified the credential file"

  ln -s "$case_dir/config/coolify.env" "$case_dir/credential-link"
  rc=0
  FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write \
    --output "$case_dir/credential-link" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a symlink to a credential file cannot be the manifest output"
  cmp -s "$case_dir/config/coolify.env" "$case_dir/coolify.before" \
    || fail "a symlink output alias modified the credential file"

  ln "$case_dir/config/posthog.env.beanz" "$case_dir/sidecar-link"
  rc=0
  FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write \
    --output "$case_dir/sidecar-link" >/dev/null 2>&1 || rc=$?
  expect_code 1 "$rc" "a hardlink to a sidecar cannot be the manifest output"
  cmp -s "$case_dir/config/posthog.env.beanz" "$case_dir/sidecar.before" \
    || fail "a hardlink output alias modified the sidecar"
  pass "manifest output refuses direct, symlink, and hardlink input aliases"
}

test_directory_output_fails_closed() {
  local case_dir="$TMP_ROOT/directory-output" output_dir link out rc leftovers
  setup_config "$case_dir/config"
  output_dir="$case_dir/output-dir"
  mkdir -p "$output_dir"

  rc=0
  out=$(
    FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write --output "$output_dir" 2>&1
  ) || rc=$?
  expect_code 1 "$rc" "an output directory should exit non-zero"
  assert_contains "$out" 'output path must be a file' \
    "an output directory should produce a value-free diagnostic"
  assert_not_contains "$out" "$SECRET" "an output-directory failure leaked a credential value"
  leftovers=$(find "$output_dir" -mindepth 1 2>/dev/null)
  [ -z "$leftovers" ] || fail "an output directory received unexpected manifest artifacts"

  link="$case_dir/output-link"
  ln -s "$output_dir" "$link"
  rc=0
  out=$(
    FM_BEANZ_CONFIG_DIR="$case_dir/config" "$SCRIPT" write --output "$link" 2>&1
  ) || rc=$?
  expect_code 1 "$rc" "a symlink to an output directory should exit non-zero"
  assert_not_contains "$out" "$SECRET" \
    "a symlinked output-directory failure leaked a credential value"
  leftovers=$(find "$output_dir" -mindepth 1 2>/dev/null)
  [ -z "$leftovers" ] || fail "a symlinked output directory received unexpected manifest artifacts"
  pass "directory outputs fail closed without creating hidden manifests"
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
test_unknown_argument_is_value_free
test_multiline_value_is_never_listed_as_a_key
test_shell_trace_never_contains_live_values
test_output_aliases_inputs_fail_closed
test_directory_output_fails_closed
test_unwritable_output_fails_closed
test_unwritable_output_fails_closed_with_no_credential_files
echo "# fm-beanz-manifest.test.sh: all assertions passed"
