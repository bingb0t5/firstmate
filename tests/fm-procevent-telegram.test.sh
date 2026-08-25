#!/usr/bin/env bash
# Behavioral and crash-boundary proofs for the transactional Telegram adapter.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-telegram-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

telegram_test_cleanup() {
  chmod -R u+w "$TMP_ROOT" 2>/dev/null || true
  fm_test_cleanup
}

trap telegram_test_cleanup EXIT
trap 'telegram_test_cleanup; exit 130' INT
trap 'telegram_test_cleanup; exit 143' TERM

ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
ORIGINAL_PATH=$PATH
export PATH="$FAKEBIN:$PATH"

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
set -u
out=
i=1
args=("$@")
while [ "$i" -le "$#" ]; do
  if [ "${args[$((i - 1))]}" = -o ]; then
    out=${args[$i]}
  fi
  i=$((i + 1))
done
config=$(cat)
if [ -n "${CURL_STUB_CALL_LOG:-}" ]; then
  printf '%s\n' "$config" >> "$CURL_STUB_CALL_LOG"
fi
if [ -n "${CURL_STUB_CAPTURE:-}" ]; then
  printf '%s\n' "$config" > "$CURL_STUB_CAPTURE"
fi
if [ -n "$out" ] && [ -n "${CURL_STUB_BODY:-}" ]; then
  cp "$CURL_STUB_BODY" "$out"
fi
printf '%s' "${CURL_STUB_HTTP:-200}"
exit "${CURL_STUB_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl"

CURL_CALLS="$TMP_ROOT/curl.calls"
: > "$CURL_CALLS"
export CURL_STUB_CALL_LOG="$CURL_CALLS"

FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"
TOKEN='123456:SEKRIT-TEST-TOKEN-7f3a9c'
CAPTAIN_CHAT_ID=555
CAPTAIN_USER_ID=909

fixture() {
  printf '%s\n' "$2" > "$FIXTURES/$1.json"
}

fixture one-text \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":1700000000,"chat":{"id":555},"from":{"id":909},"text":"ahoy from the captain"}}]}'
fixture next-text \
  '{"ok":true,"result":[{"update_id":1002,"message":{"date":1700000001,"chat":{"id":555},"from":{"id":909},"text":"second captain message"}}]}'
fixture two-text \
  '{"ok":true,"result":[{"update_id":3001,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"first message"}},{"update_id":3002,"message":{"date":2,"chat":{"id":555},"from":{"id":909},"text":"second message"}}]}'
fixture empty '{"ok":true,"result":[]}'
fixture non-text \
  '{"ok":true,"result":[{"update_id":2001,"message":{"date":1700000001,"chat":{"id":555},"from":{"id":909},"sticker":{"file_id":"abc"}}}]}'
fixture untrusted \
  '{"ok":true,"result":[{"update_id":2501,"message":{"date":1,"chat":{"id":555},"from":{"id":424242},"text":"not the captain"}}]}'
fixture no-sender \
  '{"ok":true,"result":[{"update_id":2502,"message":{"date":1,"chat":{"id":555},"text":"sender missing"}}]}'
fixture noncontiguous \
  '{"ok":true,"result":[{"update_id":100,"message":{"sticker":{"file_id":"a"}}},{"update_id":200,"message":{"sticker":{"file_id":"b"}}}]}'
fixture max-id \
  '{"ok":true,"result":[{"update_id":2147483647,"message":{"sticker":{"file_id":"max"}}}]}'
fixture malformed-json '{"ok":true,"result":'
fixture ok-false '{"ok":false,"result":[]}'
fixture result-object '{"ok":true,"result":{}}'
fixture update-string '{"ok":true,"result":["not-an-update"]}'
fixture bool-id '{"ok":true,"result":[{"update_id":true}]}'
fixture zero-id '{"ok":true,"result":[{"update_id":0}]}'
fixture negative-id '{"ok":true,"result":[{"update_id":-1}]}'
fixture string-id '{"ok":true,"result":[{"update_id":"1001"}]}'
fixture float-id '{"ok":true,"result":[{"update_id":1001.5}]}'
fixture range-id '{"ok":true,"result":[{"update_id":2147483648}]}'
fixture duplicate-id '{"ok":true,"result":[{"update_id":1001},{"update_id":1001}]}'
fixture malformed-message \
  '{"ok":true,"result":[{"update_id":1001,"message":"not-an-object"}]}'
fixture malformed-chat \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":1,"chat":"bad","from":{"id":909},"text":"bad chat"}}]}'
fixture malformed-sender \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":1,"chat":{"id":555},"from":"bad","text":"bad sender"}}]}'
fixture malformed-text \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":7}}]}'
fixture malformed-date \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":"today","chat":{"id":555},"from":{"id":909},"text":"bad date"}}]}'
fixture mixed-invalid \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"must not commit"}},{"update_id":true}]}'
fixture stale-id '{"ok":true,"result":[{"update_id":1001}]}'

new_home() {
  mkdir -p "$1/state"
}

write_env_file() {
  mkdir -p "$(dirname "$1")"
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=%s\nTELEGRAM_CAPTAIN_USER_ID=%s\n' \
    "$2" "${3:-$CAPTAIN_CHAT_ID}" "${4:-$CAPTAIN_USER_ID}" > "$1"
  chmod 600 "$1"
}

arm_home() {
  local home=$1 env_file=$2
  new_home "$home"
  write_env_file "$env_file" "$TOKEN"
  FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" arm >/dev/null
}

poll_once() {
  local home=$1 env_file=$2 body=$3 http=${4:-200}
  CURL_STUB_BODY="$body" CURL_STUB_HTTP="$http" \
    FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" poll
}

db_query() {
  python3 - "$1/state/telegram/channel.db" "$2" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    row = db.execute(sys.argv[2]).fetchone()
if row is None:
    print("")
elif len(row) == 1:
    print("" if row[0] is None else row[0])
else:
    print("|".join("" if value is None else str(value) for value in row))
PY
}

db_exec() {
  python3 - "$1/state/telegram/channel.db" "$2" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    db.executescript(sys.argv[2])
PY
}

safety_snapshot() {
  local home=$1
  db_query "$home" \
    "SELECT (SELECT committed_offset FROM meta), (SELECT count(*) FROM messages), (SELECT group_concat(kind, ',') FROM (SELECT kind FROM conditions WHERE kind LIKE 'api-%' ORDER BY kind))"
}

RESULT_NUMBER=0
write_result() {
  RESULT_NUMBER=$((RESULT_NUMBER + 1))
  RESULT_FILE="$TMP_ROOT/result.$RESULT_NUMBER"
  printf '%s\n' "$1" > "$RESULT_FILE"
}

ack_result() {
  local home=$1 env_file=$2 output=$3
  write_result "$output"
  FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" ack "$RESULT_FILE"
}

assert_equal() {
  [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"
}

assert_no_curl() {
  [ ! -s "$CURL_CALLS" ] || fail "$1"
}

clear_curl_calls() {
  : > "$CURL_CALLS"
}

# --- strict credential intake and explicit first arm ------------------------
H_NOCRED="$TMP_ROOT/no-credential"
new_home "$H_NOCRED"
no_cred_status=0
no_cred_out=$(FM_HOME="$H_NOCRED" FM_TELEGRAM_ENV_FILE="$H_NOCRED/missing.env" \
  "$ADAPTER" arm 2>&1) || no_cred_status=$?
[ "$no_cred_status" -ne 0 ] || fail "arm accepted a missing credential"
assert_contains "$no_cred_out" "no valid Telegram credential" "arm explains missing credentials"
assert_absent "$H_NOCRED/state/telegram/channel.db" "arm created state without credentials"

for credential_case in bad-mode symlink incomplete unknown duplicate; do
  home="$TMP_ROOT/credential-$credential_case"
  env_file="$TMP_ROOT/credential-$credential_case.env"
  new_home "$home"
  case "$credential_case" in
    bad-mode)
      write_env_file "$env_file" "$TOKEN"
      chmod 644 "$env_file"
      ;;
    symlink)
      write_env_file "$env_file.real" "$TOKEN"
      ln -s "$env_file.real" "$env_file"
      ;;
    incomplete)
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=555\n' "$TOKEN" > "$env_file"
      chmod 600 "$env_file"
      ;;
    unknown)
      write_env_file "$env_file" "$TOKEN"
      printf 'EXTRA_KEY=nope\n' >> "$env_file"
      ;;
    duplicate)
      write_env_file "$env_file" "$TOKEN"
      printf 'TELEGRAM_BOT_TOKEN=again\n' >> "$env_file"
      ;;
  esac
  credential_status=0
  FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" arm >/dev/null 2>&1 \
    || credential_status=$?
  [ "$credential_status" -ne 0 ] || fail "arm accepted $credential_case credentials"
  assert_absent "$home/state/telegram/channel.db" "$credential_case credentials created state"
done
pass "arm accepts only one strict, private, complete credential snapshot"

H_ROTATE="$TMP_ROOT/credential-rotate"
ROTATE_ENV="$TMP_ROOT/credential-rotate.env"
ROTATE_REPLACEMENT="$TMP_ROOT/credential-rotate.replacement"
ROTATE_MARKER="$TMP_ROOT/credential-rotate.marker"
ROTATE_RELEASE="$TMP_ROOT/credential-rotate.release"
ROTATE_OUT="$TMP_ROOT/credential-rotate.out"
new_home "$H_ROTATE"
write_env_file "$ROTATE_ENV" "$TOKEN"
write_env_file "$ROTATE_REPLACEMENT" "987654:ROTATED-TOKEN"
FM_TELEGRAM_FAILPOINT=credential-after-lstat \
  FM_TELEGRAM_FAILPOINT_MARKER="$ROTATE_MARKER" \
  FM_TELEGRAM_FAILPOINT_RELEASE="$ROTATE_RELEASE" \
  FM_HOME="$H_ROTATE" FM_TELEGRAM_ENV_FILE="$ROTATE_ENV" \
  "$ADAPTER" arm > "$ROTATE_OUT" 2>&1 &
rotate_pid=$!
for _ in $(seq 1 100); do
  [ -e "$ROTATE_MARKER" ] && break
  sleep 0.01
done
assert_present "$ROTATE_MARKER" "credential replacement test never reached the open boundary"
mv "$ROTATE_REPLACEMENT" "$ROTATE_ENV"
: > "$ROTATE_RELEASE"
rotate_status=0
wait "$rotate_pid" || rotate_status=$?
[ "$rotate_status" -ne 0 ] || fail "arm accepted a credential file replaced between inspection and open"
assert_absent "$H_ROTATE/state/telegram/channel.db" \
  "credential replacement assembled a mixed snapshot into live state"
pass "credential replacement during read is detected as one rejected snapshot"

H_DATA="$TMP_ROOT/credential-data"
DATA_ENV="$TMP_ROOT/credential-data.env"
new_home "$H_DATA"
SHELL_MARKER="$TMP_ROOT/credential-executed"
# shellcheck disable=SC2016  # Literal command substitution proves the file is never sourced.
printf 'TELEGRAM_BOT_TOKEN=123:$(touch%s)\nTELEGRAM_CAPTAIN_CHAT_ID=555\nTELEGRAM_CAPTAIN_USER_ID=909\n' \
  "$SHELL_MARKER" > "$DATA_ENV"
chmod 600 "$DATA_ENV"
data_status=0
FM_HOME="$H_DATA" FM_TELEGRAM_ENV_FILE="$DATA_ENV" "$ADAPTER" arm >/dev/null 2>&1 \
  || data_status=$?
[ "$data_status" -ne 0 ] || fail "executable-looking credential syntax was accepted"
assert_absent "$SHELL_MARKER" "credential syntax was executed as shell"
assert_absent "$H_DATA/state/telegram/channel.db" \
  "executable-looking credential syntax initialized state"
pass "credential files are parsed as data and never executed"

# --- state initialization, registration, and private SQLite settings --------
H_ARM="$TMP_ROOT/arm"
ARM_ENV="$TMP_ROOT/arm.env"
arm_home "$H_ARM" "$ARM_ENV"
assert_contains "$(FM_HOME="$H_ARM" "$ROOT/bin/fm-procevent.sh" list)" "telegram" \
  "arm did not register the canonical source"
assert_equal "$("$ADAPTER" source-id)" telegram "source-id is not canonical"
assert_equal "$(db_query "$H_ARM" "SELECT committed_offset FROM meta")" 0 \
  "fresh state did not start at offset zero"
doctor_out=$(FM_HOME="$H_ARM" FM_TELEGRAM_ENV_FILE="$ARM_ENV" "$ADAPTER" doctor)
assert_contains "$doctor_out" "integrity=ok" "doctor did not prove database integrity"
assert_contains "$doctor_out" "journal_mode=delete" "rollback journaling is not pinned"
assert_contains "$doctor_out" "synchronous=2" "synchronous FULL is not pinned"
assert_contains "$doctor_out" "fullfsync=1" "fullfsync is not enabled"
db_mode=$(stat -c %a "$H_ARM/state/telegram/channel.db" 2>/dev/null \
  || stat -f %Lp "$H_ARM/state/telegram/channel.db")
dir_mode=$(stat -c %a "$H_ARM/state/telegram" 2>/dev/null \
  || stat -f %Lp "$H_ARM/state/telegram")
assert_equal "$db_mode" 600 "database mode is not private"
assert_equal "$dir_mode" 700 "Telegram state directory mode is not private"
retire_out=$(FM_HOME="$H_ARM" "$ADAPTER" retire)
assert_contains "$retire_out" "retired: telegram" "retire did not use the generic source owner"
assert_present "$H_ARM/state/telegram/channel.db" "retire deleted transactional state"
pass "arm creates private durable state, registers one source, and retire preserves state"

# --- stable message notice, identity, acknowledgement, and secrecy -----------
H_MSG="$TMP_ROOT/message"
MSG_ENV="$TMP_ROOT/message.env"
arm_home "$H_MSG" "$MSG_ENV"
clear_curl_calls
msg_out=$(poll_once "$H_MSG" "$MSG_ENV" "$FIXTURES/one-text.json")
assert_contains "$msg_out" "message: 1 notice=" "captain message did not create a stable notice"
assert_equal "$(db_query "$H_MSG" "SELECT committed_offset FROM meta")" 1002 \
  "message transaction did not advance the offset"
assert_equal "$(db_query "$H_MSG" "SELECT count(*) FROM messages")" 1 \
  "message transaction did not store the payload"
write_result "$msg_out"
assert_equal "$(FM_HOME="$H_MSG" "$ADAPTER" classify "$RESULT_FILE")" message \
  "pending message notice did not classify"
message_json=$(FM_HOME="$H_MSG" "$ADAPTER" messages "$RESULT_FILE")
assert_contains "$message_json" "ahoy from the captain" "messages did not expose the captain text"
assert_contains "$message_json" '"from_id":909' "stored payload lost sender identity"
calls_before=$(wc -l < "$CURL_CALLS" | tr -d ' ')
repeat_out=$(poll_once "$H_MSG" "$MSG_ENV" "$FIXTURES/next-text.json")
assert_equal "$repeat_out" "$msg_out" "pre-ack retry did not emit the same stable notice"
calls_after=$(wc -l < "$CURL_CALLS" | tr -d ' ')
assert_equal "$calls_after" "$calls_before" "a pending notice allowed another irreversible poll"
ack_out=$(FM_HOME="$H_MSG" "$ADAPTER" ack "$RESULT_FILE")
assert_contains "$ack_out" "acknowledged:" "notice acknowledgement failed"
assert_equal "$(FM_HOME="$H_MSG" "$ADAPTER" classify "$RESULT_FILE")" none \
  "an acknowledged capture could authorize the message twice"
assert_equal "$(FM_HOME="$H_MSG" "$ADAPTER" messages "$RESULT_FILE")" "" \
  "acknowledged messages remained actionable"
assert_contains "$(FM_HOME="$H_MSG" "$ADAPTER" ack "$RESULT_FILE")" "already-acknowledged:" \
  "notice acknowledgement is not idempotent"
pass "a message, offset, and stable notice commit together and deduplicate until acknowledgement"

CAPTURE="$TMP_ROOT/curl-config"
H_SECRET="$TMP_ROOT/secret"
SECRET_ENV="$TMP_ROOT/secret.env"
arm_home "$H_SECRET" "$SECRET_ENV"
secret_out=$(CURL_STUB_CAPTURE="$CAPTURE" poll_once \
  "$H_SECRET" "$SECRET_ENV" "$FIXTURES/one-text.json")
assert_grep "$TOKEN" "$CAPTURE" "positive control: curl did not receive the token"
case "$secret_out" in *"$TOKEN"*) fail "token leaked into adapter output" ;; esac
while IFS= read -r state_file; do
  assert_no_grep "$TOKEN" "$state_file" "token leaked into durable Telegram state"
done < <(find "$H_SECRET/state" -type f)
pass "the token reaches curl through stdin and never durable state or results"

# --- authorization and accepted update-id domain -----------------------------
H_NON_TEXT="$TMP_ROOT/non-text"
NON_TEXT_ENV="$TMP_ROOT/non-text.env"
arm_home "$H_NON_TEXT" "$NON_TEXT_ENV"
non_text_status=0
non_text_out=$(poll_once "$H_NON_TEXT" "$NON_TEXT_ENV" "$FIXTURES/non-text.json") \
  || non_text_status=$?
[ "$non_text_status" -ne 0 ] || fail "non-text update produced a captured result"
assert_equal "$non_text_out" "" "non-text update printed output"
assert_equal "$(db_query "$H_NON_TEXT" "SELECT committed_offset FROM meta")" 2002 \
  "non-text update did not advance atomically"
assert_equal "$(db_query "$H_NON_TEXT" "SELECT count(*) FROM messages")" 0 \
  "non-text update became a command"

for identity_case in untrusted no-sender; do
  home="$TMP_ROOT/$identity_case"
  env_file="$TMP_ROOT/$identity_case.env"
  arm_home "$home" "$env_file"
  identity_status=0
  identity_out=$(poll_once "$home" "$env_file" "$FIXTURES/$identity_case.json") \
    || identity_status=$?
  if [ "$identity_case" = untrusted ]; then
    [ "$identity_status" -ne 0 ] || fail "another sender became the captain"
    assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" 2502 \
      "unauthorized sender was not safely consumed"
  else
    [ "$identity_status" -eq 0 ] || fail "malformed sender did not announce a protocol block"
    assert_contains "$identity_out" "blocked: protocol-blocked" \
      "missing sender died silently"
    assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" 0 \
      "malformed sender advanced the offset"
  fi
  assert_equal "$(db_query "$home" "SELECT count(*) FROM messages")" 0 \
    "$identity_case created a captain message"
done

H_GAPS="$TMP_ROOT/noncontiguous"
GAPS_ENV="$TMP_ROOT/noncontiguous.env"
arm_home "$H_GAPS" "$GAPS_ENV"
gaps_status=0
poll_once "$H_GAPS" "$GAPS_ENV" "$FIXTURES/noncontiguous.json" >/dev/null \
  || gaps_status=$?
[ "$gaps_status" -ne 0 ] || fail "noncontiguous non-text updates woke firstmate"
assert_equal "$(db_query "$H_GAPS" "SELECT committed_offset FROM meta")" 201 \
  "the validator incorrectly required contiguous identifiers"

H_MAX="$TMP_ROOT/max-id"
MAX_ENV="$TMP_ROOT/max-id.env"
arm_home "$H_MAX" "$MAX_ENV"
max_status=0
poll_once "$H_MAX" "$MAX_ENV" "$FIXTURES/max-id.json" >/dev/null || max_status=$?
[ "$max_status" -ne 0 ] || fail "maximum valid non-text update woke firstmate"
assert_equal "$(db_query "$H_MAX" "SELECT committed_offset FROM meta")" 2147483648 \
  "maximum signed 32-bit update id was not safely committed"
pass "only the configured sender is authorized, gaps are legal, and the current Bot API id range is enforced"

# --- every rejected batch preserves the irreversible state boundary ----------
INVALID_CASES=(
  malformed-json ok-false result-object update-string bool-id zero-id
  negative-id string-id float-id range-id duplicate-id malformed-message
  malformed-chat malformed-sender malformed-text malformed-date mixed-invalid
)
for invalid_case in "${INVALID_CASES[@]}"; do
  home="$TMP_ROOT/rejected-$invalid_case"
  env_file="$TMP_ROOT/rejected-$invalid_case.env"
  arm_home "$home" "$env_file"
  before=$(safety_snapshot "$home")
  clear_curl_calls
  rejected_status=0
  rejected_out=$(poll_once "$home" "$env_file" "$FIXTURES/$invalid_case.json") \
    || rejected_status=$?
  [ "$rejected_status" -eq 0 ] || fail "$invalid_case died silently instead of announcing"
  assert_contains "$rejected_out" "blocked: protocol-blocked invalid-response" \
    "$invalid_case did not produce a protocol block"
  after=$(safety_snapshot "$home")
  assert_equal "$after" "$before" "$invalid_case changed offset, messages, or API episodes"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM notices WHERE kind='message'")" 0 \
    "$invalid_case committed a partial message notice"
  ack_result "$home" "$env_file" "$rejected_out" >/dev/null
  retry_status=0
  retry_out=$(poll_once "$home" "$env_file" "$FIXTURES/$invalid_case.json") \
    || retry_status=$?
  [ "$retry_status" -ne 0 ] || fail "$invalid_case re-announced one continuous protocol episode"
  assert_equal "$retry_out" "" "$invalid_case repeated output after acknowledgement"
  assert_grep 'offset=0&timeout=' "$CURL_CALLS" \
    "$invalid_case caused a later request to use a higher offset"
done

H_STALE="$TMP_ROOT/rejected-stale"
STALE_ENV="$TMP_ROOT/rejected-stale.env"
arm_home "$H_STALE" "$STALE_ENV"
seed_status=0
poll_once "$H_STALE" "$STALE_ENV" "$FIXTURES/one-text.json" >/dev/null || seed_status=$?
[ "$seed_status" -eq 0 ] || fail "stale-id setup message failed"
seed_result=$(poll_once "$H_STALE" "$STALE_ENV" "$FIXTURES/empty.json")
write_result "$seed_result"
# The second call above re-emits the pending notice without polling.
FM_HOME="$H_STALE" "$ADAPTER" ack "$RESULT_FILE" >/dev/null
stale_before=$(safety_snapshot "$H_STALE")
stale_out=$(poll_once "$H_STALE" "$STALE_ENV" "$FIXTURES/stale-id.json")
assert_contains "$stale_out" "blocked: protocol-blocked" "stale update id did not block"
assert_equal "$(safety_snapshot "$H_STALE")" "$stale_before" \
  "stale update id moved the irreversible boundary"
pass "all rejected envelopes, identifiers, shapes, duplicates, and stale batches preserve offset and message state"

# --- independent sticky API episodes and validated-success recovery ----------
H_API="$TMP_ROOT/api-episodes"
API_ENV="$TMP_ROOT/api-episodes.env"
arm_home "$H_API" "$API_ENV"
api_401=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/empty.json" 401)
assert_contains "$api_401" "blocked: api-blocked 401" "401 did not announce"
ack_result "$H_API" "$API_ENV" "$api_401" >/dev/null
repeat_401_status=0
repeat_401=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/empty.json" 401) \
  || repeat_401_status=$?
[ "$repeat_401_status" -ne 0 ] || fail "continuous 401 announced twice"
assert_equal "$repeat_401" "" "continuous 401 produced output"

malformed_during_401=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/malformed-json.json")
assert_contains "$malformed_during_401" "blocked: protocol-blocked" \
  "malformed 200 died silently during 401"
assert_equal "$(db_query "$H_API" "SELECT count(*) FROM conditions WHERE kind='api-401'")" 1 \
  "malformed 200 cleared sticky 401"
ack_result "$H_API" "$API_ENV" "$malformed_during_401" >/dev/null

api_409=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/empty.json" 409)
assert_contains "$api_409" "blocked: api-blocked 409" "409 did not announce independently"
ack_result "$H_API" "$API_ENV" "$api_409" >/dev/null
assert_equal "$(db_query "$H_API" "SELECT count(*) FROM conditions WHERE kind LIKE 'api-%'")" 2 \
  "401 and 409 were not retained independently"

for code in 401 409; do
  continuous_status=0
  continuous_out=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/empty.json" "$code") \
    || continuous_status=$?
  [ "$continuous_status" -ne 0 ] || fail "continuous HTTP $code announced twice"
  assert_equal "$continuous_out" "" "continuous HTTP $code produced output"
done

success_status=0
success_out=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/empty.json") || success_status=$?
[ "$success_status" -ne 0 ] || fail "empty validated success produced a wake"
assert_equal "$success_out" "" "empty validated success printed output"
assert_equal "$(db_query "$H_API" "SELECT count(*) FROM conditions WHERE kind IN ('api-401','api-409','protocol')")" 0 \
  "validated success did not clear resolved episodes atomically"
recur_401=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/empty.json" 401)
assert_contains "$recur_401" "blocked: api-blocked 401" "401 recurrence after success did not announce"

FM_HOME="$H_API" "$ADAPTER" retire >/dev/null
FM_HOME="$H_API" FM_TELEGRAM_ENV_FILE="$API_ENV" "$ADAPTER" arm >/dev/null
ack_result "$H_API" "$API_ENV" "$recur_401" >/dev/null
rearm_status=0
rearm_out=$(poll_once "$H_API" "$API_ENV" "$FIXTURES/empty.json" 401) || rearm_status=$?
[ "$rearm_status" -ne 0 ] || fail "retire and arm cleared the sticky 401"
assert_equal "$rearm_out" "" "retire and arm repeated the sticky 401 notice"
pass "401 and 409 remain independent and clear only with one fully validated success transaction"

# --- bounded transport silence and recovery ---------------------------------
H_TRANSPORT="$TMP_ROOT/transport"
TRANSPORT_ENV="$TMP_ROOT/transport.env"
arm_home "$H_TRANSPORT" "$TRANSPORT_ENV"
for attempt in 1 2; do
  transport_status=0
  transport_out=$(poll_once "$H_TRANSPORT" "$TRANSPORT_ENV" "$FIXTURES/empty.json" 500) \
    || transport_status=$?
  [ "$transport_status" -ne 0 ] || fail "transport attempt $attempt announced before the budget"
  assert_equal "$transport_out" "" "transport attempt $attempt printed output"
done
transport_block=$(poll_once "$H_TRANSPORT" "$TRANSPORT_ENV" "$FIXTURES/empty.json" 500)
assert_contains "$transport_block" "blocked: transport-blocked failure-budget" \
  "third consecutive transport failure died silently"
ack_result "$H_TRANSPORT" "$TRANSPORT_ENV" "$transport_block" >/dev/null
fourth_status=0
fourth_out=$(poll_once "$H_TRANSPORT" "$TRANSPORT_ENV" "$FIXTURES/empty.json" 429) \
  || fourth_status=$?
[ "$fourth_status" -ne 0 ] || fail "one continuous transport episode announced twice"
assert_equal "$fourth_out" "" "continuous transport episode printed output after acknowledgement"
recovery_status=0
poll_once "$H_TRANSPORT" "$TRANSPORT_ENV" "$FIXTURES/empty.json" >/dev/null \
  || recovery_status=$?
[ "$recovery_status" -ne 0 ] || fail "transport recovery empty success woke firstmate"
assert_equal "$(db_query "$H_TRANSPORT" "SELECT consecutive_failures FROM meta")" 0 \
  "validated success did not reset transport failures"
assert_equal "$(db_query "$H_TRANSPORT" "SELECT count(*) FROM conditions WHERE kind='transport'")" 0 \
  "validated success did not clear transport episode"

H_BUDGET="$TMP_ROOT/transport-budget"
BUDGET_ENV="$TMP_ROOT/transport-budget.env"
arm_home "$H_BUDGET" "$BUDGET_ENV"
budget_out=$(FM_TELEGRAM_TRANSIENT_ERROR_BUDGET=1 poll_once \
  "$H_BUDGET" "$BUDGET_ENV" "$FIXTURES/empty.json" 500)
assert_contains "$budget_out" "blocked: transport-blocked" \
  "explicit one-failure budget was not honored"
ack_result "$H_BUDGET" "$BUDGET_ENV" "$budget_out" >/dev/null
clear_curl_calls
bad_budget_out=$(FM_TELEGRAM_TRANSIENT_ERROR_BUDGET=0 poll_once \
  "$H_BUDGET" "$BUDGET_ENV" "$FIXTURES/empty.json")
assert_contains "$bad_budget_out" "blocked: local-state" \
  "invalid transport budget failed silently"
assert_no_curl "invalid transport budget made a network call"
pass "transient failures are silent only for an explicit bounded budget and announce once per episode"

# --- credential loss after arm announces and never polls --------------------
H_CRED_LOSS="$TMP_ROOT/credential-loss"
CRED_LOSS_ENV="$TMP_ROOT/credential-loss.env"
arm_home "$H_CRED_LOSS" "$CRED_LOSS_ENV"
rm -f "$CRED_LOSS_ENV"
clear_curl_calls
credential_block=$(poll_once "$H_CRED_LOSS" "$CRED_LOSS_ENV" "$FIXTURES/one-text.json")
assert_contains "$credential_block" "blocked: credential-blocked unavailable" \
  "credential loss after arm died silently"
assert_no_curl "invalid credentials made a Telegram request"
assert_equal "$(db_query "$H_CRED_LOSS" "SELECT committed_offset FROM meta")" 0 \
  "credential loss changed the offset"
ack_result "$H_CRED_LOSS" "$CRED_LOSS_ENV" "$credential_block" >/dev/null
credential_repeat_status=0
credential_repeat=$(poll_once "$H_CRED_LOSS" "$CRED_LOSS_ENV" "$FIXTURES/one-text.json") \
  || credential_repeat_status=$?
[ "$credential_repeat_status" -ne 0 ] || fail "continuous credential loss announced twice"
assert_equal "$credential_repeat" "" "continuous credential loss printed output"
write_env_file "$CRED_LOSS_ENV" "$TOKEN"
credential_recovered=$(poll_once "$H_CRED_LOSS" "$CRED_LOSS_ENV" "$FIXTURES/one-text.json")
assert_contains "$credential_recovered" "message: 1" "restored credentials did not resume delivery"
assert_equal "$(db_query "$H_CRED_LOSS" "SELECT count(*) FROM conditions WHERE kind='credential'")" 0 \
  "credential restoration did not close its episode"
pass "credential loss is actionable, inert, sticky, and automatically recoverable"

# --- transaction crash matrix: old or new complete state, never partial -----
PRECOMMIT_FAILPOINTS=(after_validate after_begin after_notice after_message after_offset before_commit)
for point in "${PRECOMMIT_FAILPOINTS[@]}"; do
  home="$TMP_ROOT/crash-$point"
  env_file="$TMP_ROOT/crash-$point.env"
  arm_home "$home" "$env_file"
  crash_out=$(FM_TELEGRAM_FAILPOINT="$point" poll_once \
    "$home" "$env_file" "$FIXTURES/one-text.json")
  assert_contains "$crash_out" "blocked: local-state" \
    "$point did not surface the injected child crash"
  assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" 0 \
    "$point exposed an advanced offset before commit"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM messages")" 0 \
    "$point exposed a partial message"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM notices")" 0 \
    "$point exposed a partial notice"
  recovered=$(poll_once "$home" "$env_file" "$FIXTURES/one-text.json")
  assert_contains "$recovered" "message: 1" "$point did not recover from the old transaction"
  assert_equal "$(db_query "$home" "SELECT committed_offset, (SELECT count(*) FROM messages), (SELECT count(*) FROM notices WHERE acknowledged_at IS NULL) FROM meta")" \
    "1002|1|1" "$point recovery did not expose one complete new transaction"
done

for point in after_commit before_output after_output; do
  home="$TMP_ROOT/crash-$point"
  env_file="$TMP_ROOT/crash-$point.env"
  arm_home "$home" "$env_file"
  crash_status=0
  crash_out=$(FM_TELEGRAM_FAILPOINT="$point" poll_once \
    "$home" "$env_file" "$FIXTURES/one-text.json") || crash_status=$?
  [ "$crash_status" -eq 0 ] || fail "$point left the wrapper non-capturable"
  assert_equal "$(db_query "$home" "SELECT committed_offset, (SELECT count(*) FROM messages), (SELECT count(*) FROM notices WHERE acknowledged_at IS NULL) FROM meta")" \
    "1002|1|1" "$point did not preserve the complete committed transaction"
  calls_before=$(wc -l < "$CURL_CALLS" | tr -d ' ')
  recovered=$(poll_once "$home" "$env_file" "$FIXTURES/next-text.json")
  assert_contains "$recovered" "message: 1" "$point did not re-emit the committed notice"
  calls_after=$(wc -l < "$CURL_CALLS" | tr -d ' ')
  assert_equal "$calls_after" "$calls_before" "$point recovery polled past a pending notice"
done
pass "fault injection at every validation, write, commit, and output boundary exposes only complete transactions"

H_ACK_CRASH="$TMP_ROOT/ack-crash"
ACK_CRASH_ENV="$TMP_ROOT/ack-crash.env"
arm_home "$H_ACK_CRASH" "$ACK_CRASH_ENV"
ack_crash_message=$(poll_once "$H_ACK_CRASH" "$ACK_CRASH_ENV" "$FIXTURES/one-text.json")
write_result "$ack_crash_message"
ack_crash_status=0
FM_TELEGRAM_FAILPOINT=before_ack_commit FM_HOME="$H_ACK_CRASH" \
  FM_TELEGRAM_ENV_FILE="$ACK_CRASH_ENV" "$ADAPTER" ack "$RESULT_FILE" >/dev/null 2>&1 \
  || ack_crash_status=$?
[ "$ack_crash_status" -ne 0 ] || fail "pre-commit acknowledgement failpoint did not crash"
assert_equal "$(FM_HOME="$H_ACK_CRASH" "$ADAPTER" classify "$RESULT_FILE")" message \
  "pre-commit acknowledgement crash lost the pending notice"
ack_after_status=0
FM_TELEGRAM_FAILPOINT=after_ack_commit FM_HOME="$H_ACK_CRASH" \
  FM_TELEGRAM_ENV_FILE="$ACK_CRASH_ENV" "$ADAPTER" ack "$RESULT_FILE" >/dev/null 2>&1 \
  || ack_after_status=$?
[ "$ack_after_status" -ne 0 ] || fail "post-commit acknowledgement failpoint did not crash"
assert_equal "$(FM_HOME="$H_ACK_CRASH" "$ADAPTER" classify "$RESULT_FILE")" none \
  "post-commit acknowledgement crash repeated an already handled notice"
pass "notice acknowledgement is atomic across its own crash boundaries"

# --- malformed authoritative state always announces before any network call -
corrupt_case() {
  local case_name=$1 home="$TMP_ROOT/corrupt-$1" env_file="$TMP_ROOT/corrupt-$1.env"
  arm_home "$home" "$env_file"
  case "$case_name" in
    missing-db)
      rm -f "$home/state/telegram/channel.db"
      ;;
    corrupt-header)
      printf 'not a sqlite database\n' > "$home/state/telegram/channel.db"
      chmod 600 "$home/state/telegram/channel.db"
      ;;
    wrong-schema)
      db_exec "$home" "PRAGMA user_version=99;"
      ;;
    impossible-row)
      db_exec "$home" "PRAGMA ignore_check_constraints=ON; UPDATE meta SET committed_offset=-1;"
      ;;
    missing-table)
      db_exec "$home" "DROP TABLE messages;"
      ;;
    database-symlink)
      mv "$home/state/telegram/channel.db" "$home/state/channel.real"
      ln -s "$home/state/channel.real" "$home/state/telegram/channel.db"
      ;;
    database-mode)
      chmod 644 "$home/state/telegram/channel.db"
      ;;
    database-directory)
      rm -f "$home/state/telegram/channel.db"
      mkdir "$home/state/telegram/channel.db"
      ;;
    state-symlink)
      mv "$home/state/telegram" "$home/state/telegram.real"
      ln -s "$home/state/telegram.real" "$home/state/telegram"
      ;;
  esac
  clear_curl_calls
  local first second
  first=$(poll_once "$home" "$env_file" "$FIXTURES/one-text.json")
  second=$(poll_once "$home" "$env_file" "$FIXTURES/one-text.json")
  assert_contains "$first" "blocked: local-state fingerprint=" \
    "$case_name did not announce local state blockage"
  assert_equal "$second" "$first" "$case_name did not produce a stable fingerprint"
  assert_no_curl "$case_name reached Telegram from invalid local state"
  write_result "$first"
  assert_equal "$(FM_HOME="$home" "$ADAPTER" classify "$RESULT_FILE")" blocked \
    "$case_name local-state result did not classify as blocked"
  assert_contains "$(FM_HOME="$home" "$ADAPTER" ack "$RESULT_FILE")" \
    "unacknowledgeable: local-state" \
    "$case_name local-state result pretended to persist an acknowledgement"
  local terminal_status=0
  FM_HOME="$home" "$ADAPTER" terminal "$RESULT_FILE" || terminal_status=$?
  [ "$terminal_status" -ne 0 ] || fail "$case_name retired the permanent channel"
}

for state_case in missing-db corrupt-header wrong-schema impossible-row missing-table \
  database-symlink database-mode database-directory state-symlink; do
  corrupt_case "$state_case"
done
pass "missing, corrupt, impossible, unsafe, and unreadable state repeats a stable blocked result without polling"

# --- real runner captures local-state failure instead of nonzero-empty -------
H_E2E_BLOCK="$TMP_ROOT/e2e-local-block"
E2E_BLOCK_ENV="$TMP_ROOT/e2e-local-block.env"
arm_home "$H_E2E_BLOCK" "$E2E_BLOCK_ENV"
db_exec "$H_E2E_BLOCK" "PRAGMA user_version=99;"
clear_curl_calls
FM_HOME="$H_E2E_BLOCK" FM_TELEGRAM_ENV_FILE="$E2E_BLOCK_ENV" \
  "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 80); do
  [ -e "$H_E2E_BLOCK/state/.wake-queue" ] && break
  sleep 0.1
done
assert_present "$H_E2E_BLOCK/state/.wake-queue" \
  "real runner never announced malformed Telegram state"
assert_grep 'procevent telegram telegram 1' "$H_E2E_BLOCK/state/.wake-queue" \
  "local-state blockage did not use the ordinary durable event"
E2E_BLOCK_RESULT="$H_E2E_BLOCK/state/procevent-inbox/telegram.1.result"
assert_present "$E2E_BLOCK_RESULT" "real runner did not capture the local-state result"
assert_equal "$(FM_HOME="$H_E2E_BLOCK" "$ADAPTER" classify "$E2E_BLOCK_RESULT")" blocked \
  "captured local-state result did not classify as blocked"
assert_no_curl "real runner called Telegram from malformed local state"
FM_HOME="$H_E2E_BLOCK" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null
pass "the real runner durably announces internal corruption and keeps the source permanent"

# --- offline migration archives everything and never guesses ----------------
H_LEGACY_REFUSE="$TMP_ROOT/legacy-refuse"
LEGACY_REFUSE_ENV="$TMP_ROOT/legacy-refuse.env"
new_home "$H_LEGACY_REFUSE"
write_env_file "$LEGACY_REFUSE_ENV" "$TOKEN"
printf '1002\n' > "$H_LEGACY_REFUSE/state/.telegram-offset"
legacy_arm_status=0
FM_HOME="$H_LEGACY_REFUSE" FM_TELEGRAM_ENV_FILE="$LEGACY_REFUSE_ENV" \
  "$ADAPTER" arm >/dev/null 2>&1 || legacy_arm_status=$?
[ "$legacy_arm_status" -ne 0 ] || fail "arm bypassed required legacy migration"

printf '#!/usr/bin/env bash\n' > "$H_LEGACY_REFUSE/state/telegram-watch.check.sh"
chmod 700 "$H_LEGACY_REFUSE/state/telegram-watch.check.sh"
legacy_check_status=0
FM_HOME="$H_LEGACY_REFUSE" FM_TELEGRAM_ENV_FILE="$LEGACY_REFUSE_ENV" \
  "$ADAPTER" migrate >/dev/null 2>&1 || legacy_check_status=$?
[ "$legacy_check_status" -ne 0 ] || fail "migration ran while the legacy check remained registered"
rm -f "$H_LEGACY_REFUSE/state/telegram-watch.check.sh"
printf 'snapshot\n' > "$H_LEGACY_REFUSE/state/.fm-custom-check.active"
snapshot_status=0
FM_HOME="$H_LEGACY_REFUSE" FM_TELEGRAM_ENV_FILE="$LEGACY_REFUSE_ENV" \
  "$ADAPTER" migrate >/dev/null 2>&1 || snapshot_status=$?
[ "$snapshot_status" -ne 0 ] || fail "migration ran while a custom-check snapshot could be active"
rm -f "$H_LEGACY_REFUSE/state/.fm-custom-check.active"
pass "migration refuses until both the source and legacy producer are stopped"

H_MIGRATE="$TMP_ROOT/migrate"
MIGRATE_ENV="$TMP_ROOT/migrate.env"
new_home "$H_MIGRATE"
write_env_file "$MIGRATE_ENV" "$TOKEN"
printf '1002\n' > "$H_MIGRATE/state/.telegram-offset"
printf 'staged but unpublished\n' > "$H_MIGRATE/state/.telegram-offset.staged"
printf '401\n409\n' > "$H_MIGRATE/state/.telegram-blocked"
mkdir -p "$H_MIGRATE/state/telegram-inbox/handled"
printf '{"update_id":900,"date":1,"chat_id":555,"from_id":909,"text":"already handled"}\n' \
  > "$H_MIGRATE/state/telegram-inbox/handled/900.json"
printf '{"update_id":1002,"date":2,"chat_id":555,"from_id":909,"text":"pending legacy"}\n' \
  > "$H_MIGRATE/state/telegram-inbox/1002.json"
printf '1 1003\n' > "$H_MIGRATE/state/.telegram-pending-delivery"
mkdir -p "$H_MIGRATE/state/.telegram-delivery-receipts"
cp "$H_MIGRATE/state/telegram-inbox/1002.json" \
  "$H_MIGRATE/state/.telegram-delivery-receipts/1002.json"
migrate_out=$(FM_HOME="$H_MIGRATE" FM_TELEGRAM_ENV_FILE="$MIGRATE_ENV" \
  "$ADAPTER" migrate)
assert_contains "$migrate_out" "migrated: archive=" "coherent migration did not complete"
assert_present "$H_MIGRATE/state/.telegram-offset" "migration deleted the old offset"
assert_present "$H_MIGRATE/state/.telegram-blocked" "migration deleted old API episodes"
assert_present "$H_MIGRATE/state/.telegram-pending-delivery" "migration deleted old pending state"
assert_present "$H_MIGRATE/state/.telegram-delivery-receipts/1002.json" \
  "migration deleted an old receipt"
assert_equal "$(db_query "$H_MIGRATE" "SELECT committed_offset FROM meta")" 1003 \
  "migration did not import the pending target offset"
assert_equal "$(db_query "$H_MIGRATE" "SELECT count(*) FROM messages")" 2 \
  "migration did not import handled and pending payloads"
assert_equal "$(db_query "$H_MIGRATE" "SELECT count(*) FROM conditions WHERE kind LIKE 'api-%'")" 2 \
  "migration did not preserve both API episodes"
archive_rel=$(db_query "$H_MIGRATE" "SELECT migration_archive FROM meta")
archive="$H_MIGRATE/state/$archive_rel"
assert_present "$archive/manifest.json" "migration archive has no integrity manifest"
assert_grep '.telegram-offset' "$archive/manifest.json" "archive omitted the old offset"
assert_grep '.telegram-offset.staged' "$archive/manifest.json" \
  "archive omitted an abandoned legacy temp artifact"
assert_grep '.telegram-delivery-receipts/1002.json' "$archive/manifest.json" \
  "archive omitted a receipt"
archive_mode=$(stat -c %a "$archive" 2>/dev/null || stat -f %Lp "$archive")
assert_equal "$archive_mode" 500 "migration archive is not read-only"
archive_parent_mode=$(stat -c %a "$(dirname "$archive")" 2>/dev/null \
  || stat -f %Lp "$(dirname "$archive")")
assert_equal "$archive_parent_mode" 500 "migration archive parent still allows accidental deletion"

clear_curl_calls
migrated_pending=$(poll_once "$H_MIGRATE" "$MIGRATE_ENV" "$FIXTURES/empty.json")
assert_contains "$migrated_pending" "message: 1" "migrated pending message did not announce first"
assert_no_curl "migrated pending notice allowed a network call"
ack_result "$H_MIGRATE" "$MIGRATE_ENV" "$migrated_pending" >/dev/null
migrated_401=$(poll_once "$H_MIGRATE" "$MIGRATE_ENV" "$FIXTURES/empty.json")
assert_contains "$migrated_401" "api-blocked 401" "migrated 401 episode was lost"
assert_no_curl "unannounced migrated API condition allowed a network call"
ack_result "$H_MIGRATE" "$MIGRATE_ENV" "$migrated_401" >/dev/null
migrated_409=$(poll_once "$H_MIGRATE" "$MIGRATE_ENV" "$FIXTURES/empty.json")
assert_contains "$migrated_409" "api-blocked 409" "migrated 409 episode was lost"
assert_no_curl "second unannounced migrated API condition allowed a network call"
pass "coherent migration archives every old byte, imports exact state, and drains notices before polling"

H_AMBIGUOUS="$TMP_ROOT/migrate-ambiguous"
AMBIGUOUS_ENV="$TMP_ROOT/migrate-ambiguous.env"
new_home "$H_AMBIGUOUS"
write_env_file "$AMBIGUOUS_ENV" "$TOKEN"
printf 'not-an-offset\n' > "$H_AMBIGUOUS/state/.telegram-offset"
ambiguous_status=0
ambiguous_out=$(FM_HOME="$H_AMBIGUOUS" FM_TELEGRAM_ENV_FILE="$AMBIGUOUS_ENV" \
  "$ADAPTER" migrate 2>&1) || ambiguous_status=$?
[ "$ambiguous_status" -ne 0 ] || fail "ambiguous migration reported success"
assert_contains "$ambiguous_out" "blocked: migration-ambiguous" \
  "ambiguous migration did not explain its blocked state"
assert_equal "$(db_query "$H_AMBIGUOUS" "SELECT migration_status FROM meta")" blocked \
  "ambiguous migration did not persist a blocked cutover"
assert_equal "$(db_query "$H_AMBIGUOUS" "SELECT committed_offset FROM meta")" 0 \
  "ambiguous migration guessed an offset"
assert_present "$H_AMBIGUOUS/state/.telegram-offset" "ambiguous migration deleted evidence"
FM_HOME="$H_AMBIGUOUS" FM_TELEGRAM_ENV_FILE="$AMBIGUOUS_ENV" "$ADAPTER" arm >/dev/null
clear_curl_calls
ambiguous_poll=$(poll_once "$H_AMBIGUOUS" "$AMBIGUOUS_ENV" "$FIXTURES/one-text.json")
assert_contains "$ambiguous_poll" "blocked: migration-blocked ambiguous" \
  "blocked migration did not announce through the channel"
assert_no_curl "blocked migration called Telegram from a guessed offset"
pass "ambiguous migration preserves evidence, guesses nothing, and remains visibly blocked"

# --- explicit rollback export can only move the old format forward ----------
H_EXPORT="$TMP_ROOT/export"
EXPORT_ENV="$TMP_ROOT/export.env"
arm_home "$H_EXPORT" "$EXPORT_ENV"
export_poll_status=0
poll_once "$H_EXPORT" "$EXPORT_ENV" "$FIXTURES/non-text.json" >/dev/null \
  || export_poll_status=$?
[ "$export_poll_status" -ne 0 ] || fail "rollback export setup unexpectedly woke firstmate"
export_out=$(FM_HOME="$H_EXPORT" "$ADAPTER" export-legacy-offset)
assert_contains "$export_out" "exported-offset: 2002" "rollback export reported the wrong offset"
assert_equal "$(tr -d '\n' < "$H_EXPORT/state/.telegram-offset")" 2002 \
  "rollback export wrote an older offset"
printf '3000\n' > "$H_EXPORT/state/.telegram-offset"
newer_status=0
FM_HOME="$H_EXPORT" "$ADAPTER" export-legacy-offset >/dev/null 2>&1 || newer_status=$?
[ "$newer_status" -ne 0 ] || fail "rollback export overwrote a newer legacy offset"
assert_equal "$(tr -d '\n' < "$H_EXPORT/state/.telegram-offset")" 3000 \
  "failed rollback export changed the newer offset"
pass "rollback preparation exports the transactional offset forward and never backward"

# --- end to end message capture, adapter read/ack, and generic handled -------
H_E2E="$TMP_ROOT/e2e-message"
E2E_ENV="$TMP_ROOT/e2e-message.env"
arm_home "$H_E2E" "$E2E_ENV"
FM_HOME="$H_E2E" FM_TELEGRAM_ENV_FILE="$E2E_ENV" CURL_STUB_BODY="$FIXTURES/one-text.json" \
  "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 80); do
  [ -e "$H_E2E/state/.wake-queue" ] && break
  sleep 0.1
done
assert_present "$H_E2E/state/.wake-queue" "real runner did not publish the message"
assert_grep 'procevent telegram telegram 1' "$H_E2E/state/.wake-queue" \
  "real runner wake has the wrong source identity"
E2E_RESULT="$H_E2E/state/procevent-inbox/telegram.1.result"
assert_present "$E2E_RESULT" "real runner did not durably capture the result"
assert_contains "$(FM_HOME="$H_E2E" "$ADAPTER" messages "$E2E_RESULT")" \
  "ahoy from the captain" "handler could not read the captured notice"
FM_HOME="$H_E2E" "$ADAPTER" ack "$E2E_RESULT" >/dev/null
FM_HOME="$H_E2E" "$ROOT/bin/fm-procevent.sh" handled telegram 1 >/dev/null
assert_equal "$(FM_HOME="$H_E2E" "$ADAPTER" classify "$E2E_RESULT")" none \
  "fully handled runner capture remained actionable"
FM_HOME="$H_E2E" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null
pass "the real runner captures a stable notice whose payload and two acknowledgements complete end to end"

PATH="$ORIGINAL_PATH"
printf 'all fm-procevent-telegram tests passed\n'
