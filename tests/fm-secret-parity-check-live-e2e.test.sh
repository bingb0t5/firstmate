#!/usr/bin/env bash
# Live HTTP e2e for fm-secret-parity-check.sh (live-harness-optin family).
#
# Exercises the real script and curl transport against a loopback mock provider
# for mismatch, missing, quoted-Coolify, membership, pin, duplicate-alert,
# reappearance, probe-failure, and unavailable-cadence scenarios. When operator
# credential files exist, also drives read-only checks against production
# Coolify and Render for equal-secret silence and redaction.
#
# Run explicitly:
#   FM_SECRET_PARITY_LIVE_E2E=1 tests/fm-secret-parity-check-live-e2e.test.sh
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/bin/fm-secret-parity-check.sh"

if [ "${FM_SECRET_PARITY_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_SECRET_PARITY_LIVE_E2E=1 to run the secret parity live e2e"
  exit 0
fi

command -v curl >/dev/null 2>&1 || { echo "not ok - curl is required" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "not ok - jq is required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "not ok - python3 is required" >&2; exit 1; }

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-secret-parity-live)
MOCK_PID=
MOCK_PORT=
MOCK_ROOT="$TMP_ROOT/mock"
MOCK_SERVER="$TMP_ROOT/mock-server.py"

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

cleanup_mock() {
  if [ -n "${MOCK_PID:-}" ]; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
    MOCK_PID=
  fi
}
trap cleanup_mock EXIT

free_port() {
  python3 -c "import socket; s=socket.socket(); s.bind(('127.0.0.1',0)); print(s.getsockname()[1]); s.close()"
}

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
  mkdir -p "$MOCK_ROOT/coolify"
  printf '%s\n' "$json" > "$MOCK_ROOT/coolify/$id.json"
}

write_render_fixture() {
  local key=$1 value
  value=$(value_for "$key")
  mkdir -p "$MOCK_ROOT/render"
  printf '%s\n' "$(jq -cn --arg key "$key" --arg value "$value" \
    '{key:$key,value:$value}')" > "$MOCK_ROOT/render/$key.json"
}

seed_equal_fixtures() {
  local other_token="other-$$-$RANDOM"
  V_BEANBOT="live-beanbot-$$-$RANDOM"
  V_ASSISTANT="live-assistant-$$-$RANDOM"
  V_SUPABASE_URL="https://live-$RANDOM.supabase.test"
  V_SUPABASE_KEY="live-supabase-key-$$-$RANDOM"
  V_STRIPE="live-stripe-$$-$RANDOM"
  V_WEBHOOK="live-webhook-$$-$RANDOM"
  V_PRICE="live-price-$$-$RANDOM"
  V_N8N="live-n8n-$$-$RANDOM"
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
}

write_mock_server() {
  cat > "$MOCK_SERVER" <<'PY'
#!/usr/bin/env python3
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, HTTPServer

FIXTURE_ROOT = os.environ["FM_MOCK_FIXTURE_ROOT"]
FAIL_SUBSTR = os.environ.get("FM_MOCK_FAIL_SUBSTR", "")


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if FAIL_SUBSTR and FAIL_SUBSTR in self.path:
            self.send_error(500)
            return
        path = None
        if "/api/v1/applications/" in self.path and self.path.endswith("/envs"):
            uuid = self.path.split("/api/v1/applications/")[1].split("/envs")[0]
            path = os.path.join(FIXTURE_ROOT, "coolify", f"{uuid}.json")
        elif "/api/v1/services/" in self.path and self.path.endswith("/envs"):
            uuid = self.path.split("/api/v1/services/")[1].split("/envs")[0]
            path = os.path.join(FIXTURE_ROOT, "coolify", f"{uuid}.json")
        elif "/env-vars/" in self.path:
            key = self.path.rsplit("/", 1)[-1]
            path = os.path.join(FIXTURE_ROOT, "render", f"{key}.json")
        if not path or not os.path.isfile(path):
            self.send_error(404)
            return
        with open(path, "rb") as handle:
            body = handle.read()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_args):
        return


port = int(sys.argv[1])
HTTPServer(("127.0.0.1", port), Handler).serve_forever()
PY
  chmod 0755 "$MOCK_SERVER"
}

start_mock() {
  local fail_substr=${1:-}
  cleanup_mock
  MOCK_PORT=$(free_port)
  export FM_MOCK_FIXTURE_ROOT="$MOCK_ROOT"
  export FM_MOCK_FAIL_SUBSTR="$fail_substr"
  python3 "$MOCK_SERVER" "$MOCK_PORT" &
  MOCK_PID=$!
  python3 -c "
import socket, sys, time
for _ in range(50):
    s = socket.socket()
    s.settimeout(0.2)
    try:
        s.connect(('127.0.0.1', $MOCK_PORT))
    except OSError:
        time.sleep(0.1)
        continue
    finally:
        s.close()
    sys.exit(0)
sys.exit(1)
" || fail "mock provider server never opened port $MOCK_PORT"
}

make_mock_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state"
  printf 'COOLIFY_URL=http://127.0.0.1:%s\nCOOLIFY_API_TOKEN=mock-token\n' "$MOCK_PORT" > "$home/coolify.env"
  printf 'RENDER_API_URL=http://127.0.0.1:%s\nRENDER_API_KEY=mock-token\n' "$MOCK_PORT" > "$home/render.env"
  printf '%s' "$home"
}

run_mock_check() {
  local home=$1 coolify=$2 render=$3 out=$4
  shift 4
  local status=0
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$coolify" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$render" \
    FM_SECRET_PARITY_RENDER_API_URL="http://127.0.0.1:$MOCK_PORT" \
    FM_SECRET_PARITY_INTERVAL=0 \
    "$CHECK" "$@" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "live mock check exit"
}

test_live_mock_mismatch_is_redacted() {
  local home coolify render out report
  QUOTED=0
  seed_equal_fixtures
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "live-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$MOCK_ROOT/render/LALO_ASSISTANT_API_KEY.json"
  start_mock
  home=$(make_mock_home mismatch)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  report=$(cat "$out")
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "live mismatch did not produce exactly one alert"
  assert_contains "$report" 'LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "live mismatch alert omitted names and environments"
  assert_not_contains "$report" "$V_ASSISTANT" "live mismatch alert exposed a credential value"
  pass "live mock mismatch produces one redacted alert"
}

test_live_mock_duplicate_suppressed() {
  local home coolify render out
  QUOTED=0
  seed_equal_fixtures
  jq -cn --arg key STRIPE_SECRET_KEY --arg value "live-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$MOCK_ROOT/render/STRIPE_SECRET_KEY.json"
  start_mock
  home=$(make_mock_home duplicate)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  : > "$out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  [ ! -s "$out" ] || fail "live duplicate mismatch alert was not suppressed: $(cat "$out")"
  pass "live mock duplicate mismatch alert is suppressed"
}

test_live_mock_mismatch_reappears() {
  local home coolify render out
  QUOTED=0
  seed_equal_fixtures
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "live-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$MOCK_ROOT/render/LALO_ASSISTANT_API_KEY.json"
  start_mock
  home=$(make_mock_home reappear)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  assert_contains "$(cat "$out")" 'LALO_ASSISTANT_API_KEY' "initial live mismatch did not alert"
  write_render_fixture LALO_ASSISTANT_API_KEY
  : > "$out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "live-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$MOCK_ROOT/render/LALO_ASSISTANT_API_KEY.json"
  : > "$out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  assert_contains "$(cat "$out")" 'LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "live mismatch did not alert again after reappearance"
  pass "live mock mismatch alerts again after reappearance"
}

test_live_mock_missing_secret() {
  local home coolify render out report
  QUOTED=0
  seed_equal_fixtures
  jq -c 'map(select(.key != "PLATFORM_SUPABASE_URL"))' \
    "$MOCK_ROOT/coolify/o13agfus3ladxv4zpii2x792.json" \
    > "$MOCK_ROOT/coolify/missing.json"
  mv "$MOCK_ROOT/coolify/missing.json" "$MOCK_ROOT/coolify/o13agfus3ladxv4zpii2x792.json"
  start_mock
  home=$(make_mock_home missing)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'PLATFORM_SUPABASE_URL [admin-prod, admin-staging, signals, render-llalo]' \
    "live missing secret alert omitted tuple locations"
  assert_not_contains "$report" "$V_SUPABASE_URL" "live missing alert exposed a value"
  pass "live mock missing secret is named without its value"
}

test_live_mock_quoted_coolify() {
  local home coolify render out
  QUOTED=1
  seed_equal_fixtures
  start_mock
  home=$(make_mock_home quoted)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  [ ! -s "$out" ] || fail "live quoted Coolify values produced an alert: $(cat "$out")"
  pass "live mock quoted Coolify values compare equal after unwrapping"
}

test_live_mock_n8n_membership() {
  local home coolify render out report
  QUOTED=0
  seed_equal_fixtures
  V_BRAIN_LIST="fixture-other:rich"
  write_coolify_fixture funzds3h0heoscr1h0ppw0ya BRAIN_TOKENS
  start_mock
  home=$(make_mock_home membership)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'BRAIN_TOKEN_N8N [n8n, brain]' \
    "live n8n membership mismatch was not named"
  assert_not_contains "$report" "$V_N8N" "live n8n token value appeared in the alert"
  pass "live mock n8n membership mismatch is named without token value"
}

test_live_mock_pin_mismatch() {
  local home coolify render out report
  QUOTED=0
  seed_equal_fixtures
  jq --arg key LALO_DIRECTORY_MATCH_URL --arg value 'https://wrong.example/match' \
    'map(if .key == $key then .value=$value | .real_value=$value else . end)' \
    "$MOCK_ROOT/coolify/ywlch69qmlddbx611t6h01dh.json" \
    > "$MOCK_ROOT/coolify/signals.json"
  mv "$MOCK_ROOT/coolify/signals.json" "$MOCK_ROOT/coolify/ywlch69qmlddbx611t6h01dh.json"
  start_mock
  home=$(make_mock_home pins)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'LALO_DIRECTORY_MATCH_URL [signals]' \
    "live pin mismatch was not named"
  assert_not_contains "$report" 'wrong.example' "live pin value appeared in the alert"
  pass "live mock pin mismatch is named without exposing URL value"
}

test_live_mock_partial_probe_failure() {
  local home coolify render out report
  QUOTED=0
  seed_equal_fixtures
  jq -cn --arg key LALO_ASSISTANT_API_KEY --arg value "live-mismatch-$$-$RANDOM" \
    '{key:$key,value:$value}' > "$MOCK_ROOT/render/LALO_ASSISTANT_API_KEY.json"
  start_mock '/api/v1/services/'
  home=$(make_mock_home partial-probe)
  out="$home/out"
  run_mock_check "$home" "$home/coolify.env" "$home/render.env" "$out"
  report=$(cat "$out")
  assert_contains "$report" 'LALO_ASSISTANT_API_KEY [admin-prod, render-llalo]' \
    "live partial sweep dropped an earlier mismatch after a later probe failed"
  pass "live mock earlier mismatches survive a later probe failure"
}

test_live_unavailable_cadence() {
  local home out status=0 epoch
  home="$TMP_ROOT/unavailable"
  mkdir -p "$home/state" "$home/config"
  printf 'COOLIFY_URL=https://coolify.test\nCOOLIFY_API_TOKEN=token\n' > "$home/config/coolify.env"
  out="$home/out"
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/missing-render.env" \
    FM_SECRET_PARITY_INTERVAL=900 \
    FM_SECRET_PARITY_NOW=1000 \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "live unavailable check exit"
  assert_contains "$(cat "$out")" 'secret parity check unavailable' \
    "live unavailable sweep did not report unavailable"
  epoch=$(sed -n '2p' "$home/state/.secret-parity")
  [ "$epoch" = 1000 ] || fail "live unavailable sweep did not bump cadence epoch"
  : > "$out"
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$home/config/coolify.env" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$home/config/missing-render.env" \
    FM_SECRET_PARITY_INTERVAL=900 \
    FM_SECRET_PARITY_NOW=1500 \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "live second unavailable check exit"
  [ ! -s "$out" ] || fail "live unavailable alert repeated before interval: $(cat "$out")"
  pass "live unavailable sweep advances cadence without repeat spam"
}

test_live_prod_equal_and_redaction() {
  local coolify render home out status=0
  coolify="${HOME}/.config/beanz/coolify.env"
  render="${HOME}/.config/lalo/render-api.env"
  [ -f "$coolify" ] && [ -f "$render" ] || {
    echo "skip: operator Coolify/Render credential files absent"
    return 0
  }
  home="$TMP_ROOT/prod-equal"
  mkdir -p "$home/state"
  out="$home/out"
  FM_HOME="$home" \
    FM_SECRET_PARITY_COOLIFY_ENV_FILE="$coolify" \
    FM_SECRET_PARITY_RENDER_ENV_FILE="$render" \
    FM_SECRET_PARITY_INTERVAL=0 \
    "$CHECK" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "live production equal check exit"
  [ ! -s "$out" ] || fail "live production equal check produced an alert: $(cat "$out")"
  if [ -f "$home/state/.secret-parity" ]; then
    assert_not_contains "$(cat "$home/state/.secret-parity")" 'sk_' \
      "live production record exposed a credential marker"
    assert_not_contains "$(cat "$home/state/.secret-parity")" 'sha256' \
      "live production record exposed a hash marker"
  fi
  pass "live production equal secrets stay silent with redacted record"
}

write_mock_server
test_live_mock_mismatch_is_redacted
test_live_mock_duplicate_suppressed
test_live_mock_mismatch_reappears
test_live_mock_missing_secret
test_live_mock_quoted_coolify
test_live_mock_n8n_membership
test_live_mock_pin_mismatch
test_live_mock_partial_probe_failure
test_live_unavailable_cadence
test_live_prod_equal_and_redaction

echo "# fm-secret-parity-check-live-e2e.test.sh: all live assertions passed"
