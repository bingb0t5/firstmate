#!/usr/bin/env bash
# Behavior tests for fm-coolify-env.sh - credential-touching Coolify env updates
# must never print secret material on any path.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/../bin/fm-timeout-lib.sh"

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

# The recorder turns the request body into a value-free receipt: the key
# verbatim plus a digest of the value. That proves what was transmitted without
# putting the secret in the test log.
write_body_recorder() {
  cat > "$1" <<'PYX'
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)
digest = hashlib.sha256(payload.get("value", "").encode("utf-8")).hexdigest()
print("body key=%s value_sha256=%s" % (payload.get("key", ""), digest))
PYX
}

value_digest() {
  printf '%s' "$1" | python3 -c \
    'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

make_fakebin() {
  local dir=$1 fakebin log=$2 mode=${3:-ok}
  fakebin=$(fm_fakebin "$dir")
  write_body_recorder "$dir/record-body.py"
  cat > "$fakebin/curl" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
method=GET
body=
prev=
for arg in "\$@"; do
  [ "\$prev" = -X ] && method=\$arg
  case "\$prev" in
    -d) body=\${arg#@} ;;
  esac
  prev=\$arg
done
if [ -n "\$body" ] && [ -f "\$body" ]; then
  python3 "$dir/record-body.py" "\$body" >> "$log" 2>&1
fi
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
  create)
    if [ "\$method" = POST ]; then
      printf '{"uuid":"env-1"}\n201'
    else
      printf '{"message":"Not found"}\n404'
    fi
    exit 0
    ;;
  hang)
    sleep 30
    printf '{"uuid":"env-1"}\n200'
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

# Every run gets its own TMPDIR so a case can assert what the tool left behind,
# and a hard outer bound so an argument-parsing regression fails the suite
# instead of hanging it.
capture_run() {
  local case_dir=$1
  shift
  local fakebin out rc=0 run_tmp="$case_dir/tmp"
  mkdir -p "$run_tmp"
  fakebin=$(make_fakebin "$case_dir" "$case_dir/curl.log" "${FM_FAKE_CURL_MODE:-ok}")
  out=$(
    fm_run_timed 20 env FM_BEANZ_CONFIG_DIR="$case_dir/config" \
      TMPDIR="$run_tmp" \
      FM_COOLIFY_TIMEOUT="${FM_COOLIFY_TIMEOUT:-30}" \
      PATH="$fakebin:$BASE_PATH" \
      bash -x "$SCRIPT" "$@" 2>&1
  ) || rc=$?
  CAPTURE_OUT=$out
  CAPTURE_RC=$rc
  CAPTURE_TMPDIR=$run_tmp
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
  assert_grep "body key=POSTHOG_API_KEY value_sha256=$(value_digest "$SECRET")" "$case_dir/curl.log" \
    "the request body must carry the requested key and the resolved secret"
  assert_no_secret "success path"
  pass "success path transmits the resolved credential and never leaks it"
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
  assert_grep "body key=BRAIN_TOKEN_N8N value_sha256=$(value_digest "$SECRET")" "$case_dir/curl.log" \
    "the request body must carry the token resolved for the identity"
  assert_no_secret "brain identity lookup"
  pass "brain identity lookup succeeds without leaking the token"
}


test_creates_env_var_when_coolify_reports_404() {
  local case_dir="$TMP_ROOT/create"
  setup_config "$case_dir/config"
  FM_FAKE_CURL_MODE=create capture_run "$case_dir" set brain NEW_KEY --value-from "env:posthog.env:POSTHOG_API_KEY"
  expect_code 0 "$CAPTURE_RC" "a 404 from PATCH should fall through to a create"
  assert_contains "$CAPTURE_OUT" 'ok: brain NEW_KEY set' "create path should print ok"
  assert_grep '-X POST' "$case_dir/curl.log" "a 404 from PATCH must be followed by a POST create"
  assert_grep "body key=NEW_KEY value_sha256=$(value_digest "$SECRET")" "$case_dir/curl.log" \
    "the create request must carry the requested key and the resolved secret"
  assert_no_secret "create path"
  pass "a missing env var is created via POST after PATCH returns 404"
}

test_timeout_fails_closed() {
  local case_dir="$TMP_ROOT/timeout"
  setup_config "$case_dir/config"
  FM_FAKE_CURL_MODE=hang FM_COOLIFY_TIMEOUT=1 capture_run "$case_dir" \
    set brain POSTHOG_API_KEY --value-from "env:posthog.env:POSTHOG_API_KEY"
  expect_code 1 "$CAPTURE_RC" "a bounded call that hits its bound should exit non-zero"
  assert_contains "$CAPTURE_OUT" 'Coolify API request timed out' "a bound hit should be reported as a timeout"
  assert_not_contains "$CAPTURE_OUT" 'ok:' "a timeout must not print ok"
  assert_no_secret "timeout"
  pass "a network bound hit fails closed and is reported as a timeout"
}

test_auth_failure_names_the_credential_rejection() {
  local case_dir="$TMP_ROOT/auth-reason"
  setup_config "$case_dir/config"
  FM_FAKE_CURL_MODE=auth capture_run "$case_dir" set brain POSTHOG_API_KEY --value-from "env:posthog.env:POSTHOG_API_KEY"
  assert_contains "$CAPTURE_OUT" 'Coolify API rejected credentials' "a 401 should be reported as a credential rejection"
  assert_no_secret "auth failure reason"
  pass "a 401 is reported as a credential rejection, not a generic failure"
}

test_missing_option_operand_fails_closed() {
  local case_dir="$TMP_ROOT/no-operand"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain POSTHOG_API_KEY --value-from
  expect_code 2 "$CAPTURE_RC" "a missing --value-from operand should exit 2, not spin"
  assert_contains "$CAPTURE_OUT" '--value-from requires a source' "missing operand should say what is missing"
  assert_absent "$case_dir/curl.log" "a missing operand must not reach the Coolify API"
  pass "a missing option operand fails closed instead of looping forever"
}

test_missing_set_operands_fail_closed() {
  local case_dir="$TMP_ROOT/no-set-operands"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain --value-from "env:posthog.env:POSTHOG_API_KEY"
  expect_code 2 "$CAPTURE_RC" "set without a KEY should exit 2"
  assert_contains "$CAPTURE_OUT" 'set requires <service> <KEY>' \
    "an option in an operand position should name the missing operand, not the option"
  assert_absent "$case_dir/curl.log" "an incomplete set must not reach the Coolify API"
  pass "an option token is never consumed as a set operand"
}

test_literal_source_is_not_redacted() {
  local case_dir="$TMP_ROOT/literal"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain APP_NAME --value-from 'literal:brain'
  expect_code 0 "$CAPTURE_RC" "a literal non-secret value should succeed"
  assert_contains "$CAPTURE_OUT" 'ok: brain APP_NAME set' "the ok line must name the service verbatim"
  assert_not_contains "$CAPTURE_OUT" '[redacted]' "a declared non-secret literal must not be redacted"
  pass "a literal non-secret value leaves the contracted ok line intact"
}

test_quoted_credential_value_fails_closed() {
  local case_dir="$TMP_ROOT/quoted"
  setup_config "$case_dir/config"
  printf 'QUOTED_KEY="%s"\n' "$SECRET" >> "$case_dir/config/posthog.env"
  capture_run "$case_dir" set brain QUOTED_KEY --value-from 'env:posthog.env:QUOTED_KEY'
  expect_code 1 "$CAPTURE_RC" "a quoted assignment is ambiguous and should exit non-zero"
  assert_not_contains "$CAPTURE_OUT" 'ok:' "an ambiguous read must not report success"
  assert_absent "$case_dir/curl.log" "an ambiguous value must not be transmitted"
  assert_no_secret "quoted credential value"
  pass "a quoted credential value fails closed instead of transmitting the quotes"
}

test_crlf_credential_value_fails_closed() {
  local case_dir="$TMP_ROOT/crlf"
  setup_config "$case_dir/config"
  printf 'CR_KEY=%s\r\n' "$SECRET" >> "$case_dir/config/posthog.env"
  capture_run "$case_dir" set brain CR_KEY --value-from 'env:posthog.env:CR_KEY'
  expect_code 1 "$CAPTURE_RC" "a CRLF assignment is ambiguous and should exit non-zero"
  assert_not_contains "$CAPTURE_OUT" 'ok:' "an ambiguous read must not report success"
  assert_absent "$case_dir/curl.log" "an ambiguous value must not be transmitted"
  assert_no_secret "CRLF credential value"
  pass "a CRLF-terminated credential value fails closed instead of transmitting the CR"
}

test_identifier_shaped_continuation_fails_closed() {
  local case_dir="$TMP_ROOT/multiline"
  setup_config "$case_dir/config"
  printf 'MULTILINE_KEY=first-part\nQUJDREVGRw==\n' >> "$case_dir/config/posthog.env"
  capture_run "$case_dir" set brain MULTILINE_KEY --value-from 'env:posthog.env:MULTILINE_KEY'
  expect_code 1 "$CAPTURE_RC" "an identifier-shaped continuation is ambiguous and should exit non-zero"
  assert_not_contains "$CAPTURE_OUT" 'ok:' "an ambiguous multi-line read must not report success"
  assert_absent "$case_dir/curl.log" "an ambiguous multi-line value must not be transmitted"
  assert_no_secret "identifier-shaped continuation"
  pass "an identifier-shaped continuation fails closed"
}

test_unknown_argument_is_value_free() {
  local case_dir="$TMP_ROOT/unknown-argument"
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain APP_NAME --value-from 'literal:firstmate' "$SECRET"
  expect_code 2 "$CAPTURE_RC" "an unknown argument should exit 2"
  assert_contains "$CAPTURE_OUT" 'fm-coolify-env: unknown argument' \
    "an unknown argument should produce a generic diagnostic"
  assert_not_contains "$CAPTURE_OUT" "$SECRET" \
    "an unknown argument must not be echoed in combined output or shell trace"
  assert_absent "$case_dir/curl.log" "an unknown argument must not reach the Coolify API"
  pass "an unknown argument produces only a value-free error"
}

test_non_https_url_fails_closed() {
  local case_dir="$TMP_ROOT/non-https"
  setup_config "$case_dir/config"
  printf 'COOLIFY_URL=http://localhost:8000\nCOOLIFY_API_TOKEN=%s\n' "$FAKE_TOKEN" > "$case_dir/config/coolify.env"
  capture_run "$case_dir" set brain APP_NAME --value-from 'literal:firstmate'
  expect_code 1 "$CAPTURE_RC" "a non-HTTPS Coolify URL should exit non-zero"
  assert_contains "$CAPTURE_OUT" 'Coolify URL must be an HTTPS origin' "a non-HTTPS URL should name the transport requirement"
  assert_absent "$case_dir/curl.log" "a non-HTTPS URL must not reach curl"
  assert_no_secret "non-HTTPS URL"
  pass "a non-HTTPS Coolify URL fails closed"
}

test_unsafe_https_url_components_fail_closed() {
  local kind url case_dir rc
  for kind in userinfo query fragment empty_query empty_fragment empty_host bad_port whitespace backslash path; do
    case_dir="$TMP_ROOT/unsafe-url-$kind"
    setup_config "$case_dir/config"
    case "$kind" in
      userinfo) url="https://user:$SECRET@coolify.test.example" ;;
      query) url="https://coolify.test.example?token=$SECRET" ;;
      fragment) url="https://coolify.test.example#$SECRET" ;;
      empty_query) url='https://coolify.test.example?' ;;
      empty_fragment) url='https://coolify.test.example#' ;;
      empty_host) url='https://:443' ;;
      bad_port) url='https://coolify.test.example:invalid' ;;
      whitespace) url='https://coolify.test.example ' ;;
      backslash) url='https://coolify.test.example\suffix' ;;
      path) url='https://coolify.test.example/base' ;;
    esac
    printf 'COOLIFY_URL=%s\nCOOLIFY_API_TOKEN=%s\n' "$url" "$FAKE_TOKEN" \
      > "$case_dir/config/coolify.env"
    capture_run "$case_dir" set brain APP_NAME --value-from 'literal:firstmate'
    rc=$CAPTURE_RC
    expect_code 1 "$rc" "an HTTPS URL with $kind should exit non-zero"
    assert_contains "$CAPTURE_OUT" 'Coolify URL must be an HTTPS origin' \
      "an HTTPS URL with $kind should produce a value-free validation error"
    assert_not_contains "$CAPTURE_OUT" "$SECRET" \
      "an HTTPS URL with $kind leaked credential material"
    assert_absent "$case_dir/curl.log" "an HTTPS URL with $kind must not reach curl"
  done
  pass "unsafe HTTPS URL components fail closed before curl"
}

test_https_scheme_is_case_insensitive() {
  local case_dir="$TMP_ROOT/uppercase-https"
  setup_config "$case_dir/config"
  printf 'COOLIFY_URL=HTTPS://COOLIFY.TEST.EXAMPLE/\nCOOLIFY_API_TOKEN=%s\n' "$FAKE_TOKEN" \
    > "$case_dir/config/coolify.env"
  capture_run "$case_dir" set brain APP_NAME --value-from 'literal:firstmate'
  expect_code 0 "$CAPTURE_RC" "an uppercase HTTPS scheme should remain valid"
  assert_contains "$CAPTURE_OUT" 'ok: brain APP_NAME set' \
    "an uppercase HTTPS scheme should preserve normal success behavior"
  assert_grep 'https://coolify.test.example/api/v1/applications/app-uuid-1234/envs' \
    "$case_dir/curl.log" "the accepted origin should be normalized before curl"
  assert_no_secret "uppercase HTTPS scheme"
  pass "HTTPS scheme matching remains case-insensitive"
}

test_leaves_no_secret_scratch_behind() {
  local case_dir="$TMP_ROOT/scratch" leftovers
  setup_config "$case_dir/config"
  capture_run "$case_dir" set brain POSTHOG_API_KEY --value-from "env:posthog.env:POSTHOG_API_KEY"
  expect_code 0 "$CAPTURE_RC" "success path should exit 0"
  leftovers=$(find "$CAPTURE_TMPDIR" -mindepth 1 2>/dev/null)
  [ -z "$leftovers" ] || fail "the tool left scratch state behind:"$'\n'"$leftovers"
  pass "a successful run leaves no scratch state holding secret material"
}

test_success_from_env_file
test_auth_failure
test_malformed_value_from
test_network_failure
test_missing_key
test_brain_identity_lookup
test_creates_env_var_when_coolify_reports_404
test_timeout_fails_closed
test_auth_failure_names_the_credential_rejection
test_missing_option_operand_fails_closed
test_missing_set_operands_fail_closed
test_literal_source_is_not_redacted
test_quoted_credential_value_fails_closed
test_crlf_credential_value_fails_closed
test_identifier_shaped_continuation_fails_closed
test_unknown_argument_is_value_free
test_non_https_url_fails_closed
test_unsafe_https_url_components_fail_closed
test_https_scheme_is_case_insensitive
test_leaves_no_secret_scratch_behind
echo "# fm-coolify-env.test.sh: all assertions passed"
