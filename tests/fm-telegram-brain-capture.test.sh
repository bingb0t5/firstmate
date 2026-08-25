#!/usr/bin/env bash
# Behavior tests for fm-telegram-brain-capture.sh, the Firstmate-owned path that
# records Telegram payloads in Mr Beanz.
#
# These cases drive the public commands through a fakebin curl and never touch a
# live brain or Telegram. The interrupt adapter is stubbed only for from-result.
set -uo pipefail

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CAPTURE="$ROOT/bin/fm-telegram-brain-capture.sh"
TMP_ROOT=$(fm_test_tmproot fm-telegram-brain-capture)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

TOKEN='tok_test_brain_capture_secret'
CAPTAIN_CHAT=4242
CAPTAIN_USER=909

make_home() {
  local name=$1 home
  home="$TMP_ROOT/$name"
  mkdir -p "$home/state" "$home/config" "$home/secrets"
  umask 077
  cat > "$home/secrets/mcp.env" <<EOF
BEANZ_MCP_TOKEN=$TOKEN
BEANZ_MCP_URL=https://brain.test
EOF
  chmod 600 "$home/secrets/mcp.env"
  printf '%s\n' "$home"
}

payload() {
  local update_id=$1 text=$2 chat_id=${3:-$CAPTAIN_CHAT} from_id=${4:-$CAPTAIN_USER}
  printf '{"chat_id":%s,"date":1700000000,"from_id":%s,"text":%s,"update_id":%s}\n' \
    "$chat_id" "$from_id" "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$text")" "$update_id"
}

make_fake_curl() {
  local home=$1 fakebin
  fakebin=$(fm_fakebin "$home")
  cat > "$fakebin/curl" <<'SH'
#!/usr/bin/env bash
ofile="" argv=$*
config=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) ofile=$2; shift 2 ;;
    -w|--max-time) shift 2 ;;
    -K)
      if [ "$2" = - ]; then
        config=$(cat)
      fi
      shift 2
      ;;
    -s) shift ;;
    *) shift ;;
  esac
done
url=""
while IFS= read -r line; do
  case "$line" in
    'url = '*) url=${line#url = } ; url=${url#\"} ; url=${url%\"} ;;
  esac
done <<EOF
$config
EOF
if [ -n "${FAKE_CURL_LOG:-}" ]; then
  {
    echo "argv=$argv"
    echo "url=$url"
  } >> "$FAKE_CURL_LOG"
fi
if [ -n "$ofile" ]; then
  body=${FAKE_CAPTURE_BODY-}
  if [ -z "$body" ]; then
    body='{"capture_id":"cap-1","status":"captured"}'
  fi
  printf '%s' "$body" > "$ofile"
fi
printf '%s' "${FAKE_CAPTURE_CODE:-200}"
exit "${FAKE_CURL_EXIT:-0}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

run_capture() {
  local home=$1
  shift
  PATH="$1:$BASE_PATH" \
    FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" \
    FM_CONFIG_OVERRIDE="$home/config" \
    FM_BEANZ_ENV_FILE="$home/secrets/mcp.env" \
    FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
    FAKE_CURL_LOG="${FAKE_CURL_LOG-}" \
    FAKE_CAPTURE_BODY="${FAKE_CAPTURE_BODY-}" \
    FAKE_CAPTURE_CODE="${FAKE_CAPTURE_CODE-}" \
    FAKE_CURL_EXIT="${FAKE_CURL_EXIT-}" \
    FM_TELEGRAM_BRAIN_CAPTURE_GROUP="${FM_TELEGRAM_BRAIN_CAPTURE_GROUP-}" \
    FM_TELEGRAM_BRAIN_CAPTURE_FAILPOINT="${FM_TELEGRAM_BRAIN_CAPTURE_FAILPOINT-}" \
    "$CAPTURE" "${@:2}"
}

home=$(make_home base)
fakebin=$(make_fake_curl "$home")

# --- captain payload is posted and receipted --------------------------------
log="$home/curl.log"
FAKE_CURL_LOG=$log
out=$(payload 1001 "remember the homestay partner" | run_capture "$home" "$fakebin" capture -)
expect_code 0 $? "captain capture should succeed"
assert_contains "$out" "captured 1001 cap-1" "captain capture did not report the capture_id"
assert_present "$home/state/telegram-brain-capture/1001" "captain capture wrote no receipt"
assert_grep 'url=https://brain.test/v1/capture' "$log" "captain capture did not POST to /v1/capture"
assert_no_grep "$TOKEN" "$log" "brain token leaked into curl argv"
assert_no_grep "$TOKEN" "$home/state/telegram-brain-capture/1001" "brain token leaked into the receipt"
pass "a captain Telegram payload is posted to Mr Beanz and receipted"

# --- retry is idempotent ----------------------------------------------------
log2="$home/curl.retry.log"
FAKE_CURL_LOG=$log2
out=$(payload 1001 "remember the homestay partner" | run_capture "$home" "$fakebin" capture -)
expect_code 0 $? "retry should succeed"
assert_contains "$out" "already-captured 1001 cap-1" "retry did not reuse the receipt"
assert_absent "$log2" "retry posted to the brain again"
pass "a matching receipt skips a second brain write"

# --- failed brain write leaves no receipt -----------------------------------
fail_home=$(make_home fail)
fail_bin=$(make_fake_curl "$fail_home")
FAKE_CAPTURE_CODE=200
FAKE_CAPTURE_BODY='{"status":"captured"}'
FAKE_CURL_LOG="$fail_home/curl.log"
if payload 2002 "do not lose this" | run_capture "$fail_home" "$fail_bin" capture - >/dev/null 2>"$fail_home/err"; then
  fail "a 200 without capture_id must fail"
fi
assert_absent "$fail_home/state/telegram-brain-capture/2002" \
  "a failed brain write still wrote a receipt"
assert_grep "no capture_id" "$fail_home/err" "missing capture_id was not reported"
pass "HTTP 200 without capture_id writes no receipt"

# --- group payloads are skipped while the flag is off -----------------------
group_home=$(make_home group-off)
group_bin=$(make_fake_curl "$group_home")
FAKE_CURL_LOG="$group_home/curl.log"
FAKE_CAPTURE_BODY='{"capture_id":"cap-group","status":"captured"}'
FAKE_CAPTURE_CODE=200
out=$(payload 3003 "group chatter" -100123 "$CAPTAIN_USER" | run_capture "$group_home" "$group_bin" capture -)
expect_code 0 $? "skipped group payload should succeed"
assert_contains "$out" "skipped:group 3003" "group payload was not skipped"
assert_absent "$group_home/curl.log" "group skip still posted to the brain"
assert_absent "$group_home/state/telegram-brain-capture/3003" "group skip wrote a receipt"
pass "group discussion is skipped while the flag is off"

# --- group payloads are captured when the flag is on ------------------------
group_on=$(make_home group-on)
printf 'on\n' > "$group_on/config/telegram-brain-capture-group"
group_on_bin=$(make_fake_curl "$group_on")
FAKE_CURL_LOG="$group_on/curl.log"
FAKE_CAPTURE_BODY='{"capture_id":"cap-on","status":"captured"}'
FAKE_CAPTURE_CODE=200
out=$(payload 3004 "group decision" -100123 "$CAPTAIN_USER" | run_capture "$group_on" "$group_on_bin" capture -)
expect_code 0 $? "enabled group capture should succeed"
assert_contains "$out" "captured 3004 cap-on" "enabled group capture did not post"
assert_grep '"source":"firstmate-telegram-group"' "$group_on/state/telegram-brain-capture/3004" \
  "group receipt did not record the group source"
pass "group discussion is captured when the flag is on"

# --- missing credentials refuse without a network call ----------------------
nocred=$(make_home nocred)
rm -f "$nocred/secrets/mcp.env"
nocred_bin=$(make_fake_curl "$nocred")
FAKE_CURL_LOG="$nocred/curl.log"
if payload 4004 "should not send" | \
  PATH="$nocred_bin:$BASE_PATH" FM_HOME="$nocred" \
  FM_STATE_OVERRIDE="$nocred/state" \
  FM_CONFIG_OVERRIDE="$nocred/config" \
  FM_BEANZ_ENV_FILE="$nocred/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  "$CAPTURE" capture - >/dev/null 2>"$nocred/err"; then
  fail "missing brain credentials must refuse"
fi
assert_absent "$nocred/curl.log" "missing credentials still called curl"
pass "missing brain credentials refuse without a network call"

# --- boolean update ids are rejected ----------------------------------------
bad=$(make_home bool)
bad_bin=$(make_fake_curl "$bad")
if printf '{"update_id":true,"text":"x","chat_id":4242,"from_id":909}\n' | \
  run_capture "$bad" "$bad_bin" capture - >/dev/null 2>"$bad/err"; then
  fail "boolean update_id must be rejected"
fi
assert_grep "update_id is not an integer" "$bad/err" "boolean update_id was accepted"
pass "boolean update ids are rejected"

# --- from-result uses the interrupt adapter's messages command --------------
from_home=$(make_home from-result)
from_bin=$(make_fake_curl "$from_home")
mkdir -p "$from_home/bin"
payload 5005 "from the adapter" > "$from_home/messages.jsonl"
{
  printf '%s\n' '#!/usr/bin/env bash'
  # shellcheck disable=SC2016 # $1 belongs to the stub adapter, not this test.
  printf '%s\n' '[ "$1" = messages ] || exit 2'
  printf '%s\n' "[ \"\$2\" = \"$from_home/result\" ] || exit 3"
  printf '%s\n' "cat -- $(printf '%q' "$from_home/messages.jsonl")"
} > "$from_home/bin/fm-procevent-telegram.sh"
chmod +x "$from_home/bin/fm-procevent-telegram.sh"
printf 'notice\n' > "$from_home/result"
FAKE_CURL_LOG="$from_home/curl.log"
FAKE_CAPTURE_BODY='{"capture_id":"cap-from","status":"captured"}'
out=$(PATH="$from_home/bin:$from_bin:$BASE_PATH" \
  FM_HOME="$from_home" \
  FM_STATE_OVERRIDE="$from_home/state" \
  FM_CONFIG_OVERRIDE="$from_home/config" \
  FM_BEANZ_ENV_FILE="$from_home/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  FAKE_CURL_LOG="$from_home/curl.log" \
  FAKE_CAPTURE_BODY='{"capture_id":"cap-from","status":"captured"}' \
  "$CAPTURE" from-result "$from_home/result")
expect_code 0 $? "from-result should succeed"
assert_contains "$out" "captured 5005 cap-from" "from-result did not capture adapter payloads"
pass "from-result captures payloads from the interrupt adapter"

# --- from-result refuses when the interrupt adapter is absent ---------------
no_adapter=$(make_home no-adapter)
no_adapter_bin=$(make_fake_curl "$no_adapter")
if PATH="$no_adapter_bin:$BASE_PATH" \
  FM_HOME="$no_adapter" \
  FM_STATE_OVERRIDE="$no_adapter/state" \
  FM_CONFIG_OVERRIDE="$no_adapter/config" \
  FM_BEANZ_ENV_FILE="$no_adapter/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  "$CAPTURE" from-result "$no_adapter/result" >/dev/null 2>"$no_adapter/err"; then
  fail "from-result must refuse without the interrupt adapter"
fi
assert_grep "telegram interrupt adapter is not in this checkout" "$no_adapter/err" \
  "missing adapter was not reported"
pass "from-result refuses when the interrupt adapter is absent"

# --- crash before receipt can retry the write -------------------------------
crash=$(make_home crash)
crash_bin=$(make_fake_curl "$crash")
FAKE_CURL_LOG="$crash/curl.log"
FAKE_CAPTURE_BODY='{"capture_id":"cap-crash","status":"captured"}'
FAKE_CAPTURE_CODE=200
set +e
payload 6006 "crash window" | \
  FM_TELEGRAM_BRAIN_CAPTURE_FAILPOINT=before-receipt \
  run_capture "$crash" "$crash_bin" capture - >/dev/null 2>"$crash/err"
crash_rc=$?
expect_code 91 "$crash_rc" "failpoint should exit 91"
assert_absent "$crash/state/telegram-brain-capture/6006" "failpoint still wrote a receipt"
FAKE_CURL_LOG="$crash/curl.retry.log"
unset FM_TELEGRAM_BRAIN_CAPTURE_FAILPOINT
out=$(payload 6006 "crash window" | run_capture "$crash" "$crash_bin" capture -)
expect_code 0 $? "retry after failpoint should succeed"
assert_contains "$out" "captured 6006 cap-crash" "retry after failpoint did not capture"
assert_present "$crash/curl.retry.log" "retry after failpoint skipped the POST"
pass "a crash before the receipt can still write on retry"

# --- doctor reports non-secret readiness ------------------------------------
doc=$(make_home doctor)
doc_bin=$(make_fake_curl "$doc")
out=$(PATH="$doc_bin:$BASE_PATH" \
  FM_HOME="$doc" \
  FM_STATE_OVERRIDE="$doc/state" \
  FM_CONFIG_OVERRIDE="$doc/config" \
  FM_BEANZ_ENV_FILE="$doc/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  "$CAPTURE" doctor)
assert_contains "$out" "brain-env: present" "doctor missed brain credentials"
assert_contains "$out" "brain-url: https://brain.test" "doctor missed the brain URL"
assert_contains "$out" "captain-chat: configured" "doctor missed captain chat identity"
assert_contains "$out" "group-capture: off" "doctor missed the default-off group flag"
assert_not_contains "$out" "$TOKEN" "doctor printed the brain token"
pass "doctor reports non-secret readiness"

printf 'all fm-telegram-brain-capture tests passed\n'
