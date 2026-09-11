#!/usr/bin/env bash
# Tests for fm-secret-parity-check.sh.
#
# All provider responses and credentials are generated in a temporary home.
# The fake curl transport never prints request headers, bodies, or values.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-secret-parity-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-secret-parity)
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

V_BEANBOT=
V_ASSISTANT=
V_SUPABASE_URL=
V_SUPABASE_KEY=
V_STRIPE=
V_WEBHOOK=
V_PRICE=
V_N8N=
V_BRAIN_LIST=
QUOTED=0
MADE_HOME=

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
url=
writeout=
for arg in "$@"; do
  case "$arg" in
    -w) ;;
    *'%{http_code}'*) writeout=$arg ;;
    http://*|https://*) url=$arg ;;
  esac
done
status=200
body='{}'
if [[ "$url" == */api/v1/applications/*/envs ]]; then
  id=${url#*/api/v1/applications/}
  id=${id%/envs}
  body=$(cat "$FM_FAKE_COOLIFY_FIXTURES/$id.json")
elif [[ "$url" == */api/v1/services/*/envs ]]; then
  id=${url#*/api/v1/services/}
  id=${id%/envs}
  body=$(cat "$FM_FAKE_COOLIFY_FIXTURES/$id.json")
elif [[ "$url" == */v1/services/*/env-vars/* ]]; then
  key=${url##*/}
  file="$FM_FAKE_RENDER_FIXTURES/$key.json"
  if [ -f "$file" ]; then
    body=$(cat "$file")
  else
    status=404
    body='{"message":"not found"}'
  fi
else
  status=404
  body='{"message":"not found"}'
fi
if [ -n "${FM_FAKE_FAIL_URL_SUBSTR:-}" ] && [[ "$url" == *"$FM_FAKE_FAIL_URL_SUBSTR"* ]]; then
  exit 1
fi
if [ -n "${FM_FAKE_SLEEP_SECS:-}" ]; then
  sleep "$FM_FAKE_SLEEP_SECS"
fi
printf '%s' "$body"
if [ -n "$writeout" ]; then
  printf '\n%s' "$status"
fi
SH
chmod 0755 "$FAKEBIN/curl"

value_for() {
  case "$1" in
    BEANBOT_PLATFORM_SYNC_TOKEN) printf '%s' "$V_BEANBOT" ;;
    LALO_ASSISTANT_API_KEY) printf '%s' "$V_ASSISTANT" ;;
    PLATFORM_SUPABASE_URL) printf '%s' "$V_SUPABASE_URL" ;;
    PLATFORM_SUPABASE_SERVICE_ROLE_KEY) printf '%s' "$V_SUPABASE_KEY" ;;
    STRIPE_SECRET_KEY) printf '%s' "$V_STRIPE" ;;
    STRIPE_WEBHOOK_SECRET) printf '%s' "$V_WEBHOOK" ;;
    STRIPE_PAID_BETA_PRICE_ID) printf '%s' "$V_PRICE" ;;
    BRAIN_TOKEN_N8N) printf '%s' "$V_N8N" ;;
    LALO_APP_API_URL) printf '%s' 'https://admin.laloapp.co' ;;
    LALO_DIRECTORY_MATCH_URL)
      printf '%s' 'https://admin.laloapp.co/api/internal/local-signals/directory-match'
      ;;
    *) return 1 ;;
  esac
}

write_entry_json() {
  local key=$1 value=$2
  if [ "$QUOTED" -eq 1 ]; then
    value="\"$value\""
  fi
  printf '%s' "$value"
}

write_coolify_fixture() {
  local id=$1 key value json='[]'
  shift
  for key in "$@"; do
    if [ "$key" = BRAIN_TOKENS ]; then
      value=$V_BRAIN_LIST
    else
      value=$(value_for "$key")
    fi
    value=$(write_entry_json "$key" "$value")
    json=$(jq -c --arg key "$key" --arg value "$value" \
      '. + [{key:$key,value:$value,real_value:$value}]' <<<"$json")
  done
  printf '%s\n' "$json" > "$FM_FAKE_COOLIFY_FIXTURES/$id.json"
}

write_render_fixture() {
  local key=$1 value
  value=$(value_for "$key")
  printf '%s\n' "$(jq -cn --arg key "$key" --arg value "$value" \
    '{key:$key,value:$value}')" > "$FM_FAKE_RENDER_FIXTURES/$key.json"
}

make_home() {
  local name=$1
  local home="$TMP_ROOT/$name"
  local coolify_credential="transport-$$-$RANDOM"
  local render_credential="transport-$$-$RANDOM"
  local other_token="other-$$-$RANDOM"
  mkdir -p "$home/state" "$home/config" "$home/coolify" "$home/render"
  printf 'COOLIFY_URL=https://coolify.test\nCOOLIFY_API_TOKEN=%s\n' "$coolify_credential" \
    > "$home/config/coolify.env"
  printf 'RENDER_API_KEY=%s\n' "$render_credential" > "$home/config/render.env"
  FM_FAKE_COOLIFY_FIXTURES="$home/coolify"
  FM_FAKE_RENDER_FIXTURES="$home/render"
  export FM_FAKE_COOLIFY_FIXTURES FM_FAKE_RENDER_FIXTURES

  V_BEANBOT="fixture-beanbot-$$-$RANDOM"
  V_ASSISTANT="fixture-assistant-$$-$RANDOM"
  V_SUPABASE_URL="https://fixture-$RANDOM.supabase.test"
  V_SUPABASE_KEY="fixture-supabase-key-$$-$RANDOM"
  V_STRIPE="fixture-stripe-$$-$RANDOM"
  V_WEBHOOK="fixture-webhook-$$-$RANDOM"
  V_PRICE="fixture-price-$$-$RANDOM"
  V_N8N="fixture-n8n-$$-$RANDOM"
  V_BRAIN_LIST="$V_N8N:n8n,$other_token:rich"

  write_coolify_fixture ga48pn39tt4b9bswgsuaqu7v \
    BEANBOT_PLATFORM_SYNC_TOKEN LALO_ASSISTANT_API_KEY \
    PLATFORM_SUPABASE_URL PLATFORM_SUPABASE_SERVICE_ROLE_KEY \
    STRIPE_SECRET_KEY STRIPE_WEBHOOK_SECRET STRIPE_PAID_BETA_PRICE_ID
  write_coolify_fixture o13agfus3ladxv4zpii2x792 \
    BEANBOT_PLATFORM_SYNC_TOKEN PLATFORM_SUPABASE_URL PLATFORM_SUPABASE_SERVICE_ROLE_KEY
  write_coolify_fixture ywlch69qmlddbx611t6h01dh \
    BEANBOT_PLATFORM_SYNC_TOKEN PLATFORM_SUPABASE_URL PLATFORM_SUPABASE_SERVICE_ROLE_KEY \
    LALO_APP_API_URL LALO_DIRECTORY_MATCH_URL
  write_coolify_fixture funzds3h0heoscr1h0ppw0ya BRAIN_TOKENS
  write_coolify_fixture kr2enxkgumv2eph6a4i1sibj BRAIN_TOKEN_N8N
  for key in BEANBOT_PLATFORM_SYNC_TOKEN LALO_ASSISTANT_API_KEY \
    PLATFORM_SUPABASE_URL PLATFORM_SUPABASE_SERVICE_ROLE_KEY STRIPE_SECRET_KEY \
    STRIPE_WEBHOOK_SECRET STRIPE_PAID_BETA_PRICE_ID; do
    write_render_fixture "$key"
  done
  MADE_HOME=$home
}

run_check() {
  local home=$1 out=$2 status=0
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/render.env" \
    FM_SECRET_PARITY_INTERVAL=0 \
    FM_FAKE_COOLIFY_FIXTURES="$home/coolify" \
    FM_FAKE_RENDER_FIXTURES="$home/render" \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "secret parity check exit"
}

run_preflight() {
  local home=$1 out=$2
  PREFLIGHT_STATUS=0
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/render.env" \
    FM_SECRET_PARITY_INTERVAL=0 \
    FM_FAKE_COOLIFY_FIXTURES="$home/coolify" \
    FM_FAKE_RENDER_FIXTURES="$home/render" \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" preflight >"$out" 2>&1 || PREFLIGHT_STATUS=$?
}

test_equal_values_are_silent() {
  local home out
  QUOTED=0
  make_home equal
  home=$MADE_HOME
  out="$home/out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "equal provider values produced an alert: $(cat "$out")"
  pass "equal approved values produce no alert"
}

test_preflight_passes_equal_values() {
  local home out
  QUOTED=0
  make_home preflight-pass
  home=$MADE_HOME
  out="$home/out"
  run_preflight "$home" "$out"
  expect_code 0 "$PREFLIGHT_STATUS" "equal-value preflight exit"
  assert_contains "$(cat "$out")" 'secret parity preflight passed' \
    "equal-value preflight did not report a pass"
  pass "release preflight passes equal approved values"
}

test_preflight_rejects_mismatch() {
  local home out report
  QUOTED=0
  make_home preflight-mismatch
  home=$MADE_HOME
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "fixture-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$home/render/LALO_ASSISTANT_API_KEY.json"
  out="$home/out"
  run_preflight "$home" "$out"
  expect_code 1 "$PREFLIGHT_STATUS" "mismatched-value preflight exit"
  report=$(cat "$out")
  assert_contains "$report" 'secret parity preflight failed: LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "mismatched-value preflight omitted the tuple"
  assert_not_contains "$report" "$V_ASSISTANT" \
    "mismatched-value preflight exposed a credential value"
  pass "release preflight rejects mismatched approved values"
}

test_preflight_rejects_empty_required_value() {
  local home out report
  QUOTED=0
  make_home preflight-empty
  home=$MADE_HOME
  jq -cn --arg key STRIPE_SECRET_KEY '{key:$key,value:""}' \
    > "$home/render/STRIPE_SECRET_KEY.json"
  out="$home/out"
  run_preflight "$home" "$out"
  expect_code 1 "$PREFLIGHT_STATUS" "empty-value preflight exit"
  report=$(cat "$out")
  assert_contains "$report" 'secret parity preflight failed: STRIPE_SECRET_KEY [admin-prod, render-llalo]' \
    "empty required value was treated as healthy"
  pass "release preflight rejects an empty required value"
}

test_quoted_coolify_values_are_unwrapped() {
  local home out
  QUOTED=1
  make_home quoted
  home=$MADE_HOME
  out="$home/out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "quoted Coolify values produced an alert: $(cat "$out")"
  pass "quoted Coolify values compare equal after unwrapping"
}

test_mismatch_is_one_redacted_alert() {
  local home out report
  QUOTED=0
  make_home mismatch
  home=$MADE_HOME
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "fixture-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$home/render/LALO_ASSISTANT_API_KEY.json"
  out="$home/out"
  run_check "$home" "$out"
  report=$(cat "$out")
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "mismatch did not produce exactly one alert"
  assert_contains "$report" 'LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "mismatch alert omitted the approved names and environments"
  assert_not_contains "$report" "$V_ASSISTANT" "mismatch alert exposed a credential value"
  assert_not_contains "$report" 'sha256' "mismatch alert exposed a hash marker"
  assert_not_contains "$(cat "$home/state/.secret-parity")" "$V_ASSISTANT" \
    "private finding record exposed a credential value"
  pass "a mismatch produces one redacted alert and value-free record"
}

test_duplicate_alert_is_suppressed() {
  local home out
  QUOTED=0
  make_home duplicate
  home=$MADE_HOME
  jq -cn --arg key STRIPE_SECRET_KEY --arg value "fixture-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$home/render/STRIPE_SECRET_KEY.json"
  out="$home/out"
  run_check "$home" "$out"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the same mismatch was alerted twice: $(cat "$out")"
  pass "the same mismatch produces only one alert until it changes"
}

test_missing_secret_is_named_without_value() {
  local home out report
  QUOTED=0
  make_home missing
  home=$MADE_HOME
  jq -c 'map(select(.key != "PLATFORM_SUPABASE_URL"))' \
    "$home/coolify/o13agfus3ladxv4zpii2x792.json" \
    > "$home/coolify/missing.json"
  mv "$home/coolify/missing.json" "$home/coolify/o13agfus3ladxv4zpii2x792.json"
  out="$home/out"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'PLATFORM_SUPABASE_URL [admin-prod, admin-staging, signals, render-llalo]' \
    "missing secret alert omitted the tuple names and environments"
  assert_not_contains "$report" "$V_SUPABASE_URL" "missing alert exposed a value"
  pass "a missing secret is reported without its value"
}

test_n8n_membership_is_checked() {
  local home out report
  QUOTED=0
  make_home membership
  home=$MADE_HOME
  V_BRAIN_LIST="fixture-other:rich"
  write_coolify_fixture funzds3h0heoscr1h0ppw0ya BRAIN_TOKENS
  out="$home/out"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'BRAIN_TOKEN_N8N [n8n, brain]' \
    "n8n token membership mismatch was not named"
  assert_not_contains "$report" "$V_N8N" "n8n token value appeared in the alert"
  pass "n8n token membership is checked against brain's token-name list"
}

test_pins_are_checked() {
  local home out report
  QUOTED=0
  make_home pins
  home=$MADE_HOME
  jq --arg key LALO_DIRECTORY_MATCH_URL --arg value 'https://wrong.example/match' \
    'map(if .key == $key then .value=$value | .real_value=$value else . end)' \
    "$home/coolify/ywlch69qmlddbx611t6h01dh.json" \
    > "$home/coolify/signals.json"
  mv "$home/coolify/signals.json" "$home/coolify/ywlch69qmlddbx611t6h01dh.json"
  out="$home/out"
  run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'LALO_DIRECTORY_MATCH_URL [signals]' \
    "directory-match pin mismatch was not named"
  assert_not_contains "$report" 'wrong.example' "pin value appeared in the alert"
  pass "the signals URL pins are checked without exposing their values"
}

test_operator_arm_registers_private_check() {
  local home out status=0
  QUOTED=0
  make_home arm
  home=$MADE_HOME
  FM_HOME="$home" "$CHECK" arm >"$home/arm.out" 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/secret-parity.check.sh" "arm did not create the private check shim"
  assert_present "$home/state/secret-parity.check-trust" "arm did not call fm-check-register.sh"
  out="$home/check.out"
  FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/render.env" \
    FM_SECRET_PARITY_INTERVAL=0 PATH="$FAKEBIN:$PATH" \
    FM_FAKE_COOLIFY_FIXTURES="$home/coolify" \
    FM_FAKE_RENDER_FIXTURES="$home/render" \
    "$home/state/secret-parity.check.sh" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "armed check exit"
  [ ! -s "$out" ] || fail "the registered check was not silent on equal values"
  FM_HOME="$home" "$CHECK" disarm >/dev/null
  assert_absent "$home/state/secret-parity.check.sh" "disarm left the private check shim"
  assert_absent "$home/state/secret-parity.check-trust" "disarm left the trust binding"
  pass "operator arm uses the existing fm-check-register path in the home"
}

test_partial_mismatch_survives_later_probe_failure() {
  local home out report
  QUOTED=0
  make_home partial-probe-failure
  home=$MADE_HOME
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "fixture-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$home/render/LALO_ASSISTANT_API_KEY.json"
  out="$home/out"
  FM_FAKE_FAIL_URL_SUBSTR=/api/v1/services/ \
    run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "partial sweep dropped an earlier mismatch after a later probe failed"
  pass "earlier mismatches are still alerted when a later probe fails"
}

test_preflight_reports_mismatch_when_sweep_incomplete() {
  local home out report
  QUOTED=0
  make_home preflight-partial-probe-failure
  home=$MADE_HOME
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "fixture-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$home/render/LALO_ASSISTANT_API_KEY.json"
  out="$home/out"
  FM_FAKE_FAIL_URL_SUBSTR=/api/v1/services/ \
    run_preflight "$home" "$out"
  expect_code 1 "$PREFLIGHT_STATUS" "incomplete preflight with mismatch exit"
  report=$(cat "$out")
  assert_contains "$report" 'secret parity preflight failed: LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "incomplete preflight hid an earlier mismatch after a later probe failed"
  assert_not_contains "$report" 'secret parity preflight unavailable' \
    "incomplete preflight replaced a known mismatch with unavailable"
  pass "release preflight names earlier mismatches when a later probe fails"
}

test_incomplete_sweep_preserves_prior_findings() {
  local home out status=0 stored
  QUOTED=0
  make_home incomplete-preserve
  home=$MADE_HOME
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "fixture-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$home/render/LALO_ASSISTANT_API_KEY.json"
  out="$home/out1"
  run_check "$home" "$out"
  stored=$(sed -n '3p' "$home/state/.secret-parity")
  assert_contains "$stored" 'LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "initial mismatch was not recorded"
  : > "$out"
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/render.env" \
    FM_SECRET_PARITY_INTERVAL=0 \
    FM_CHECK_TIMEOUT=5 \
    FM_FAKE_SLEEP_SECS=1 \
    FM_FAKE_COOLIFY_FIXTURES="$home/coolify" \
    FM_FAKE_RENDER_FIXTURES="$home/render" \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "incomplete sweep exit"
  stored=$(sed -n '3p' "$home/state/.secret-parity")
  assert_contains "$stored" 'LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "incomplete sweep cleared a prior mismatch record"
  [ ! -s "$out" ] || fail "incomplete sweep re-alerted an unchanged mismatch: $(cat "$out")"
  pass "incomplete sweeps preserve prior mismatch records"
}

test_intra_tuple_mismatch_survives_probe_failure() {
  local home out report
  QUOTED=0
  make_home intra-tuple-probe-failure
  home=$MADE_HOME
  jq --arg key BEANBOT_PLATFORM_SYNC_TOKEN --arg value "fixture-mismatch-$$-$RANDOM" \
    'map(if .key == $key then .value=$value | .real_value=$value else . end)' \
    "$home/coolify/o13agfus3ladxv4zpii2x792.json" \
    > "$home/coolify/staging-mismatch.json"
  mv "$home/coolify/staging-mismatch.json" "$home/coolify/o13agfus3ladxv4zpii2x792.json"
  out="$home/out"
  FM_FAKE_FAIL_URL_SUBSTR=/v1/services/ \
    run_check "$home" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'BEANBOT_PLATFORM_SYNC_TOKEN [admin-prod, admin-staging, signals, render-llalo]' \
    "intra-tuple mismatch was dropped after a later probe failed"
  pass "intra-tuple mismatches survive a later probe failure in the same tuple"
}

test_unavailable_sweep_records_cadence() {
  local home out status=0 epoch
  QUOTED=0
  make_home unavailable-cadence
  home=$MADE_HOME
  rm -f "$home/config/render.env"
  out="$home/out1"
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/missing-render.env" \
    FM_SECRET_PARITY_INTERVAL=900 \
    FM_SECRET_PARITY_NOW=1000 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "unavailable check exit"
  assert_contains "$(cat "$out")" 'secret parity check unavailable' \
    "missing credentials did not report unavailable"
  assert_present "$home/state/.secret-parity" "unavailable sweep did not record cadence state"
  epoch=$(sed -n '2p' "$home/state/.secret-parity")
  [ "$epoch" = 1000 ] || fail "unavailable sweep did not bump the record epoch"
  : > "$out"
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/missing-render.env" \
    FM_SECRET_PARITY_INTERVAL=900 \
    FM_SECRET_PARITY_NOW=1500 \
    PATH="$FAKEBIN:$PATH" \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "second unavailable check exit"
  [ ! -s "$out" ] || fail "unavailable alert repeated before the interval elapsed: $(cat "$out")"
  pass "unavailable sweeps advance the cadence record without spamming wakes"
}

test_equal_values_are_silent
test_preflight_passes_equal_values
test_preflight_rejects_mismatch
test_preflight_rejects_empty_required_value
test_quoted_coolify_values_are_unwrapped
test_mismatch_is_one_redacted_alert
test_duplicate_alert_is_suppressed
test_missing_secret_is_named_without_value
test_n8n_membership_is_checked
test_pins_are_checked
test_operator_arm_registers_private_check
test_partial_mismatch_survives_later_probe_failure
test_preflight_reports_mismatch_when_sweep_incomplete
test_incomplete_sweep_preserves_prior_findings
test_intra_tuple_mismatch_survives_probe_failure
test_unavailable_sweep_records_cadence
