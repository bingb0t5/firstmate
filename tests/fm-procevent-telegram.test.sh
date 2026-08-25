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
config=$(cat)
if [ -n "${CURL_STUB_CALL_LOG:-}" ]; then
  printf '%s\n' "$config" >> "$CURL_STUB_CALL_LOG"
fi
if [ -n "${CURL_STUB_CAPTURE:-}" ]; then
  printf '%s\n' "$config" > "$CURL_STUB_CAPTURE"
fi
if [ -n "${CURL_STUB_BULK_BYTES:-}" ]; then
  head -c "$CURL_STUB_BULK_BYTES" /dev/zero | tr '\0' 'x'
elif [ -n "${CURL_STUB_BODY:-}" ]; then
  cat "$CURL_STUB_BODY"
fi
case "${CURL_STUB_TRAILER:-full}" in
  full)    printf '\n%s' "${CURL_STUB_HTTP:-200}" ;;
  partial) printf '\n%s' "$(printf '%s' "${CURL_STUB_HTTP:-200}" | cut -c1-2)" ;;
  absent)  ;;
esac
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
CAPTAIN_SECRET_TEXT="deploy the fleet at dawn"

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

database_temps() {
  find "$1/state/telegram" -maxdepth 1 -name '.channel.db.*' 2>/dev/null | wc -l | tr -d ' '
}

assert_printable() {
  printf '%s' "$1" | LC_ALL=C tr -d '\n' | LC_ALL=C grep -q '[[:cntrl:]]' \
    && fail "$2"
  return 0
}

doctor_cause() {
  FM_HOME="$1" "$ADAPTER" doctor | sed -n 's/^migration_cause=//p'
}

blocked_cause_case() {
  local case_name=$1 home="$TMP_ROOT/cause-$1" env_file="$TMP_ROOT/cause-$1.env"
  local expected_artifact=$2
  new_home "$home"
  write_env_file "$env_file" "$TOKEN"
  printf '1002\n' > "$home/state/.telegram-offset"
  mkdir -p "$home/state/telegram-inbox"
  case "$case_name" in
    control-byte-name)
      printf 'x' > "$home/state/telegram-inbox/$(printf 'bad :\033.json')"
      ;;
    unknown-entry)
      printf 'notes\n' > "$home/state/telegram-inbox/notes.txt"
      ;;
    filename-id-mismatch)
      printf '{"update_id":8,"date":1,"chat_id":555,"from_id":909,"text":"%s"}\n' \
        "$CAPTAIN_SECRET_TEXT" > "$home/state/telegram-inbox/7.json"
      ;;
    torn-payload)
      : > "$home/state/telegram-inbox/1002.json"
      ;;
  esac
  local status=0 out
  out=$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "$case_name reported migration success"
  assert_contains "$out" "blocked: migration-ambiguous" \
    "$case_name did not reach the blocked cutover"
  assert_equal "$(db_query "$home" "SELECT migration_status FROM meta")" blocked \
    "$case_name did not persist a blocked cutover"
  assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" 0 \
    "$case_name guessed an offset"
  local cause
  cause=$(doctor_cause "$home")
  assert_contains "$cause" "$expected_artifact" \
    "$case_name cause did not name its state-relative artifact"
  assert_printable "$cause" "$case_name cause carried a raw control byte"
  case "$cause" in
    *"$home"*) fail "$case_name cause leaked an absolute home path" ;;
    *"$CAPTAIN_SECRET_TEXT"*) fail "$case_name cause leaked captain message text" ;;
    *"$TOKEN"*) fail "$case_name cause leaked the bot token" ;;
  esac
  [ "${#cause}" -le 240 ] || fail "$case_name cause is not bounded"
  assert_contains "$out" "detail: $cause" \
    "$case_name did not print the same cause it stored"
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

H_ARM_CRASH="$TMP_ROOT/arm-crash"
ARM_CRASH_ENV="$TMP_ROOT/arm-crash.env"
new_home "$H_ARM_CRASH"
write_env_file "$ARM_CRASH_ENV" "$TOKEN"
arm_crash_status=0
FM_TELEGRAM_FAILPOINT=during_database_build FM_HOME="$H_ARM_CRASH" \
  FM_TELEGRAM_ENV_FILE="$ARM_CRASH_ENV" "$ADAPTER" arm >/dev/null 2>&1 || arm_crash_status=$?
[ "$arm_crash_status" -ne 0 ] || fail "the interrupted fresh arm reported success"
assert_absent "$H_ARM_CRASH/state/telegram/channel.db" \
  "the interrupted fresh arm published a database"
[ "$(database_temps "$H_ARM_CRASH")" -gt 0 ] \
  || fail "the interrupted fresh arm left no staging to reconcile"
assert_contains "$(FM_HOME="$H_ARM_CRASH" FM_TELEGRAM_ENV_FILE="$ARM_CRASH_ENV" \
  "$ADAPTER" arm)" "armed: telegram" "a rerun of arm did not recover the fresh home"
assert_equal "$(database_temps "$H_ARM_CRASH")" 0 \
  "a rerun of arm left the interrupted database staging behind"
assert_contains "$(FM_HOME="$H_ARM_CRASH" "$ADAPTER" doctor)" "integrity=ok" \
  "the recovered fresh arm produced an invalid database"
FM_HOME="$H_ARM_CRASH" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null
rm -f "$H_ARM_CRASH/state/telegram/channel.db"
mkdir -p "$H_ARM_CRASH/state/telegram"
printf 'ambiguous\n' > "$H_ARM_CRASH/state/telegram/.channel.db.stray"
chmod 600 "$H_ARM_CRASH/state/telegram/.channel.db.stray"
arm_unsafe_status=0
arm_unsafe_out=$(FM_HOME="$H_ARM_CRASH" FM_TELEGRAM_ENV_FILE="$ARM_CRASH_ENV" \
  "$ADAPTER" arm 2>&1) || arm_unsafe_status=$?
[ "$arm_unsafe_status" -ne 0 ] || fail "arm accepted ambiguous database staging"
assert_contains "$arm_unsafe_out" "inspect and remove it manually, then rerun arm" \
  "ambiguous staging during arm told the operator to rerun the wrong command"
case "$arm_unsafe_out" in
  *"rerun migrate"*) fail "arm suggested consuming the one-time migration cutover" ;;
esac
assert_absent "$H_ARM_CRASH/state/telegram/channel.db" \
  "a refused arm still created state"
assert_present "$H_ARM_CRASH/state/telegram/.channel.db.stray" \
  "a refused arm swept the ambiguous leftover by name"
assert_absent "$H_ARM_CRASH/state/procevent/telegram.source" \
  "a refused arm still published a source registration record"
case "$(FM_HOME="$H_ARM_CRASH" "$ROOT/bin/fm-procevent.sh" list 2>&1)" in
  *telegram*) fail "a refused arm still registered the source" ;;
esac
pass "an interrupted fresh arm reconciles its own staging and refuses ambiguous leftovers"

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

for identity_case in untrusted:2502 no-sender:2503; do
  identity_name=${identity_case%%:*}
  identity_offset=${identity_case##*:}
  home="$TMP_ROOT/$identity_name"
  env_file="$TMP_ROOT/$identity_name.env"
  arm_home "$home" "$env_file"
  identity_status=0
  identity_out=$(poll_once "$home" "$env_file" "$FIXTURES/$identity_name.json") \
    || identity_status=$?
  [ "$identity_status" -ne 0 ] || fail "$identity_name woke firstmate as the captain"
  assert_equal "$identity_out" "" "$identity_name produced a captured result"
  assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" "$identity_offset" \
    "$identity_name was not safely consumed"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM messages")" 0 \
    "$identity_name created a captain message"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM conditions")" 0 \
    "$identity_name raised a channel condition"
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

# --- the raw response never touches the filesystem and its framing is exact ---
telegram_dir_entries() {
  find "$1/state/telegram" -mindepth 1 -maxdepth 1 | sed "s|.*/||" | LC_ALL=C sort | tr '\n' ' '
}

fixture trailer-bait \
  '{"ok":true,"result":[{"update_id":1001,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"bait"}}]}'
printf '{"ok":true,"result":[{"update_id":1001,"message":{"date":\n200\n,"chat":{"id":555},"from":{"id":909},"text":"embedded trailer bytes"}}]}\n' \
  > "$FIXTURES/embedded-trailer.json"
printf '{"ok":true,"result":[]}\n200' > "$FIXTURES/bait-tail.json"

H_FRAME="$TMP_ROOT/response-framing"
FRAME_ENV="$TMP_ROOT/response-framing.env"
arm_home "$H_FRAME" "$FRAME_ENV"
frame_ok=$(poll_once "$H_FRAME" "$FRAME_ENV" "$FIXTURES/embedded-trailer.json")
assert_contains "$frame_ok" "message: 1" \
  "a body carrying trailer-like bytes was not framed correctly"
write_result "$frame_ok"
assert_contains "$(FM_HOME="$H_FRAME" "$ADAPTER" messages "$RESULT_FILE")" \
  "embedded trailer bytes" "the framed body was truncated at its embedded trailer bytes"
FM_HOME="$H_FRAME" "$ADAPTER" ack "$RESULT_FILE" >/dev/null
assert_equal "$(db_query "$H_FRAME" "SELECT committed_offset FROM meta")" 1002 \
  "a correctly framed body did not advance the committed offset"
assert_equal "$(telegram_dir_entries "$H_FRAME")" "channel.db " \
  "a completed poll left response state on the filesystem"
pass "a response body carrying trailer-like bytes is framed by its exact status suffix"

H_BAIT="$TMP_ROOT/response-bait"
BAIT_ENV="$TMP_ROOT/response-bait.env"
arm_home "$H_BAIT" "$BAIT_ENV"
bait_out=$(CURL_STUB_HTTP=409 poll_once "$H_BAIT" "$BAIT_ENV" "$FIXTURES/bait-tail.json" 409)
assert_contains "$bait_out" "blocked: api-blocked 409" \
  "a body ending in trailer-like bytes was split at the wrong suffix"
assert_equal "$(db_query "$H_BAIT" "SELECT committed_offset FROM meta")" 0 \
  "a misframed response advanced the committed offset"
pass "only the exact final status suffix frames the response, never body content"

framing_failure_case() {
  local case_name=$1 home="$TMP_ROOT/frame-$1" env_file="$TMP_ROOT/frame-$1.env"
  arm_home "$home" "$env_file"
  local status=0 out
  case "$case_name" in
    absent-trailer)
      out=$(CURL_STUB_TRAILER=absent poll_once "$home" "$env_file" \
        "$FIXTURES/one-text.json") || status=$? ;;
    partial-trailer)
      out=$(CURL_STUB_TRAILER=partial poll_once "$home" "$env_file" \
        "$FIXTURES/one-text.json") || status=$? ;;
    nonzero-curl)
      out=$(CURL_STUB_EXIT=7 poll_once "$home" "$env_file" \
        "$FIXTURES/one-text.json") || status=$? ;;
    empty-transfer)
      out=$(CURL_STUB_TRAILER=absent poll_once "$home" "$env_file" \
        "$FIXTURES/empty-file") || status=$? ;;
  esac
  [ "$status" -ne 0 ] || fail "$case_name was accepted as a framed response"
  assert_equal "$out" "" "$case_name announced a result instead of staying silent"
  assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" 0 \
    "$case_name advanced the committed offset"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM messages")" 0 \
    "$case_name committed a message"
  assert_equal "$(db_query "$home" "SELECT consecutive_failures FROM meta")" 1 \
    "$case_name was not counted as one transport failure"
  assert_equal "$(telegram_dir_entries "$home")" "channel.db " \
    "$case_name left response state on the filesystem"
}

: > "$FIXTURES/empty-file"
for frame_case in absent-trailer partial-trailer nonzero-curl empty-transfer; do
  framing_failure_case "$frame_case"
done
pass "an absent, partial, or interrupted status frame is a transport failure, never a batch"

H_OVERSIZE="$TMP_ROOT/response-oversize"
OVERSIZE_ENV="$TMP_ROOT/response-oversize.env"
arm_home "$H_OVERSIZE" "$OVERSIZE_ENV"
oversize_out=$(CURL_STUB_BULK_BYTES=$((8 * 1024 * 1024 + 1)) \
  FM_HOME="$H_OVERSIZE" FM_TELEGRAM_ENV_FILE="$OVERSIZE_ENV" "$ADAPTER" poll)
assert_contains "$oversize_out" "blocked: protocol-blocked response-too-large" \
  "an oversized response did not announce a bounded protocol block"
assert_equal "$(db_query "$H_OVERSIZE" "SELECT committed_offset FROM meta")" 0 \
  "an oversized response advanced the committed offset"
assert_equal "$(db_query "$H_OVERSIZE" "SELECT count(*) FROM messages")" 0 \
  "an oversized response committed a message"
assert_equal "$(telegram_dir_entries "$H_OVERSIZE")" "channel.db " \
  "an oversized response left response state on the filesystem"
pass "an oversized response is bounded, blocked, and leaves no response state"

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

H_UNHANDLED="$TMP_ROOT/migrate-unhandled-capture"
UNHANDLED_ENV="$TMP_ROOT/migrate-unhandled-capture.env"
new_home "$H_UNHANDLED"
write_env_file "$UNHANDLED_ENV" "$TOKEN"
printf '1002\n' > "$H_UNHANDLED/state/.telegram-offset"
mkdir -p "$H_UNHANDLED/state/telegram-inbox/handled"
printf '{"update_id":1001,"date":1,"chat_id":555,"from_id":909,"text":"already acted on"}\n' \
  > "$H_UNHANDLED/state/telegram-inbox/handled/1001.json"
mkdir -p "$H_UNHANDLED/state/procevent-inbox"
printf 'message: 1\n' > "$H_UNHANDLED/state/procevent-inbox/telegram.2.result"
unhandled_first_status=0
unhandled_first=$(FM_HOME="$H_UNHANDLED" FM_TELEGRAM_ENV_FILE="$UNHANDLED_ENV" \
  "$ADAPTER" migrate 2>&1) || unhandled_first_status=$?
[ "$unhandled_first_status" -ne 0 ] || fail "migration ran with an unhandled legacy capture"
assert_contains "$unhandled_first" "1 captured legacy Telegram result still unhandled" \
  "unhandled-capture refusal did not count the pending captures"
assert_contains "$unhandled_first" "procevent-inbox/telegram.2.result" \
  "unhandled-capture refusal did not name the pending capture"
assert_contains "$unhandled_first" "bin/fm-procevent.sh handled telegram" \
  "unhandled-capture refusal did not give the acknowledgement instruction"
[ ! -e "$H_UNHANDLED/state/telegram/channel.db" ] \
  || fail "an unhandled legacy capture published a database"
[ ! -e "$H_UNHANDLED/state/telegram-migration-archive" ] \
  || fail "an unhandled legacy capture created an archive"
unhandled_second_status=0
unhandled_second=$(FM_HOME="$H_UNHANDLED" FM_TELEGRAM_ENV_FILE="$UNHANDLED_ENV" \
  "$ADAPTER" migrate 2>&1) || unhandled_second_status=$?
assert_equal "$unhandled_second_status" "$unhandled_first_status" \
  "repeated unhandled-capture refusal changed its exit status"
assert_equal "$unhandled_second" "$unhandled_first" \
  "repeated unhandled-capture refusal changed its output"
[ ! -e "$H_UNHANDLED/state/telegram/channel.db" ] \
  || fail "a repeated unhandled-capture refusal published a database"
[ ! -e "$H_UNHANDLED/state/telegram-migration-archive" ] \
  || fail "a repeated unhandled-capture refusal created an archive"
printf 'telegram 2\n' > "$H_UNHANDLED/state/procevent-inbox/telegram.2.handled"
unhandled_after=$(FM_HOME="$H_UNHANDLED" FM_TELEGRAM_ENV_FILE="$UNHANDLED_ENV" \
  "$ADAPTER" migrate)
assert_contains "$unhandled_after" "migrated: archive=" \
  "the same migrate command failed after the captures were handled"
assert_equal "$(db_query "$H_UNHANDLED" "SELECT migration_status FROM meta")" complete \
  "handling the captures did not allow a coherent cutover"
assert_equal "$(db_query "$H_UNHANDLED" "SELECT committed_offset FROM meta")" 1002 \
  "the recovered cutover imported the wrong offset"
pass "an unhandled legacy capture refuses migration identically and without side effects until handled"

H_ARCHIVE_FAIL="$TMP_ROOT/migrate-archive-fail"
ARCHIVE_FAIL_ENV="$TMP_ROOT/migrate-archive-fail.env"
new_home "$H_ARCHIVE_FAIL"
write_env_file "$ARCHIVE_FAIL_ENV" "$TOKEN"
printf '1002\n' > "$H_ARCHIVE_FAIL/state/.telegram-offset"
mkdir -p "$H_ARCHIVE_FAIL/state/telegram-inbox"
mkfifo "$H_ARCHIVE_FAIL/state/telegram-inbox/1002.json"
archive_fail_status=0
archive_fail_out=$(FM_HOME="$H_ARCHIVE_FAIL" FM_TELEGRAM_ENV_FILE="$ARCHIVE_FAIL_ENV" \
  "$ADAPTER" migrate 2>&1) || archive_fail_status=$?
[ "$archive_fail_status" -ne 0 ] || fail "an incomplete archive reported migration success"
assert_contains "$archive_fail_out" "could not be archived completely" \
  "an incomplete archive did not explain itself"
assert_contains "$archive_fail_out" "no database exists" \
  "an incomplete archive did not state that no cutover happened"
assert_contains "$archive_fail_out" "telegram-inbox/1002.json" \
  "an incomplete archive did not name the artifact it told the operator to repair"
assert_printable "$archive_fail_out" "the archive refusal carried a raw control byte"
case "$archive_fail_out" in
  *"$H_ARCHIVE_FAIL"*) fail "the archive refusal leaked an absolute home path" ;;
esac
[ ! -e "$H_ARCHIVE_FAIL/state/telegram/channel.db" ] \
  || fail "an incomplete archive still published a cutover database"
[ ! -e "$H_ARCHIVE_FAIL/state/telegram-migration-archive" ] \
  || fail "an incomplete archive left a published archive behind"
[ -z "$(find "$H_ARCHIVE_FAIL/state" -maxdepth 1 -name '.telegram-migration-staging-*')" ] \
  || fail "an incomplete archive left its private staging copy behind"
assert_present "$H_ARCHIVE_FAIL/state/telegram-inbox/1002.json" \
  "an incomplete archive deleted the legacy artifact it could not copy"
assert_equal "$(tr -d '\n' < "$H_ARCHIVE_FAIL/state/.telegram-offset")" 1002 \
  "an incomplete archive changed the legacy offset"
archive_fail_repeat_status=0
archive_fail_repeat=$(FM_HOME="$H_ARCHIVE_FAIL" FM_TELEGRAM_ENV_FILE="$ARCHIVE_FAIL_ENV" \
  "$ADAPTER" migrate 2>&1) || archive_fail_repeat_status=$?
assert_equal "$archive_fail_repeat_status" "$archive_fail_status" \
  "a repeated incomplete archive changed its exit status"
assert_equal "$archive_fail_repeat" "$archive_fail_out" \
  "a repeated incomplete archive changed its output"
[ ! -e "$H_ARCHIVE_FAIL/state/telegram-migration-archive" ] \
  || fail "a repeated incomplete archive accumulated a published archive"
rm -f "$H_ARCHIVE_FAIL/state/telegram-inbox/1002.json"
printf '{"update_id":1002,"date":1,"chat_id":555,"from_id":909,"text":"repaired"}\n' \
  > "$H_ARCHIVE_FAIL/state/telegram-inbox/1002.json"
mkdir -p "$H_ARCHIVE_FAIL/state/.telegram-delivery-receipts"
cp "$H_ARCHIVE_FAIL/state/telegram-inbox/1002.json" \
  "$H_ARCHIVE_FAIL/state/.telegram-delivery-receipts/1002.json"
archive_repaired=$(FM_HOME="$H_ARCHIVE_FAIL" FM_TELEGRAM_ENV_FILE="$ARCHIVE_FAIL_ENV" \
  "$ADAPTER" migrate)
assert_contains "$archive_repaired" "migrated: archive=" \
  "migration stayed refused after the unarchivable artifact was repaired"
assert_equal "$(find "$H_ARCHIVE_FAIL/state/telegram-migration-archive" -mindepth 1 -maxdepth 1 | wc -l | tr -d ' ')" 1 \
  "the sealed archive parent holds more than the one complete archive"
repaired_archive="$H_ARCHIVE_FAIL/state/$(db_query "$H_ARCHIVE_FAIL" "SELECT migration_archive FROM meta")"
assert_present "$repaired_archive/manifest.json" \
  "the one published archive is not manifest-bound"
pass "an archive that cannot be completed refuses before cutover and leaves no database"

legacy_fingerprint() {
  find "$1/state" -path "$1/state/telegram-migration-archive" -prune -o \
    -path "$1/state/telegram" -prune -o -type f -print0 \
    | LC_ALL=C sort -z | xargs -0 sha256sum 2>/dev/null | sed "s|$1/||"
}

seed_migration_home() {
  local home=$1 env_file=$2
  new_home "$home"
  write_env_file "$env_file" "$TOKEN"
  printf '1003\n' > "$home/state/.telegram-offset"
  printf '401\n' > "$home/state/.telegram-blocked"
  mkdir -p "$home/state/telegram-inbox/handled"
  printf '{"update_id":900,"date":1,"chat_id":555,"from_id":909,"text":"old handled"}\n' \
    > "$home/state/telegram-inbox/handled/900.json"
  mkdir -p "$home/state/.telegram-delivery-receipts"
}

published_archives() {
  find "$1/state/telegram-migration-archive" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l | tr -d ' '
}

assert_converged_migration() {
  local home=$1 case_name=$2
  assert_equal "$(published_archives "$home")" 1 \
    "$case_name did not converge to exactly one published archive"
  assert_equal "$(db_query "$home" "SELECT migration_status FROM meta")" complete \
    "$case_name did not converge to a complete cutover"
  assert_contains "$(FM_HOME="$home" "$ADAPTER" doctor)" "integrity=ok" \
    "$case_name converged to an invalid database"
  [ -z "$(find "$home/state" -maxdepth 1 -name '.telegram-migration-staging-*')" ] \
    || fail "$case_name left private staging behind"
  local archive
  archive="$home/state/$(db_query "$home" "SELECT migration_archive FROM meta")"
  assert_present "$archive/manifest.json" "$case_name published an archive with no manifest"
}

crash_recovery_case() {
  local case_name=$1 point=$2
  local home="$TMP_ROOT/crash-$1" env_file="$TMP_ROOT/crash-$1.env"
  seed_migration_home "$home" "$env_file"
  local before after status=0
  before=$(legacy_fingerprint "$home")
  FM_TELEGRAM_FAILPOINT="$point" FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" \
    "$ADAPTER" migrate >/dev/null 2>&1 || status=$?
  assert_equal "$status" 91 "$case_name did not stop at its crash boundary"
  assert_absent "$home/state/telegram/channel.db" \
    "$case_name published a database past its crash boundary"
  local recovered
  recovered=$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate)
  assert_contains "$recovered" "migrated: archive=" \
    "$case_name could not be recovered by rerunning migrate"
  assert_converged_migration "$home" "$case_name"
  after=$(legacy_fingerprint "$home")
  assert_equal "$after" "$before" "$case_name changed the original legacy bytes"
}

crash_recovery_case staged-not-published after_stage
crash_recovery_case published-not-sealed after_archive_publish
crash_recovery_case sealed-no-database after_archive_seal
pass "a crash on either side of archive publication or sealing reruns to one archive and one database"

staged_db_query() {
  python3 - "$1" "$2" <<'PY'
import sqlite3
import sys
with sqlite3.connect(sys.argv[1]) as db:
    print(db.execute(sys.argv[2]).fetchone()[0])
PY
}

staged_database_path() {
  find "$1/state/telegram" -maxdepth 1 -name '.channel.db.*' \
    ! -name '*.owner' ! -name '*-journal'
}

staged_journals() {
  find "$1/state/telegram" -maxdepth 1 -name '.channel.db.*-journal' | wc -l | tr -d ' '
}

H_DB_BUILD="$TMP_ROOT/crash-database-build"
DB_BUILD_ENV="$TMP_ROOT/crash-database-build.env"
seed_migration_home "$H_DB_BUILD" "$DB_BUILD_ENV"
db_build_before=$(legacy_fingerprint "$H_DB_BUILD")
db_build_status=0
FM_TELEGRAM_FAILPOINT=during_database_build FM_HOME="$H_DB_BUILD" \
  FM_TELEGRAM_ENV_FILE="$DB_BUILD_ENV" "$ADAPTER" migrate >/dev/null 2>&1 \
  || db_build_status=$?
assert_equal "$db_build_status" 91 "the database build crash did not stop at its boundary"
assert_absent "$H_DB_BUILD/state/telegram/channel.db" \
  "an interrupted database build published a cutover"
assert_equal "$(database_temps "$H_DB_BUILD")" 3 \
  "an interrupted database build left no marked staging to reconcile"
assert_equal "$(staged_journals "$H_DB_BUILD")" 1 \
  "an interrupted database build left no rollback journal beside its staging"
db_build_recovered=$(FM_HOME="$H_DB_BUILD" FM_TELEGRAM_ENV_FILE="$DB_BUILD_ENV" \
  "$ADAPTER" migrate)
assert_contains "$db_build_recovered" "migrated: archive=" \
  "an interrupted database build could not be recovered by rerunning migrate"
assert_equal "$(database_temps "$H_DB_BUILD")" 0 \
  "a captain payload copy from the interrupted database build was left unmanaged"
assert_converged_migration "$H_DB_BUILD" "database-build crash"
assert_equal "$(legacy_fingerprint "$H_DB_BUILD")" "$db_build_before" \
  "the database build crash changed the original legacy bytes"
pass "an interrupt during database construction leaves no unmanaged payload copy and reruns clean"

cutover_atomicity_case() {
  local case_name=$1 point=$2 expected_meta=$3 expected_messages=$4
  local home="$TMP_ROOT/atomic-$1" env_file="$TMP_ROOT/atomic-$1.env"
  seed_migration_home "$home" "$env_file"
  printf '{"update_id":901,"date":2,"chat_id":555,"from_id":909,"text":"second handled"}\n' \
    > "$home/state/telegram-inbox/handled/901.json"
  local status=0
  FM_TELEGRAM_FAILPOINT="$point" FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" \
    "$ADAPTER" migrate >/dev/null 2>&1 || status=$?
  assert_equal "$status" 91 "$case_name did not stop at its transaction boundary"
  assert_absent "$home/state/telegram/channel.db" \
    "$case_name published a cutover past its transaction boundary"
  local staged
  staged=$(staged_database_path "$home")
  assert_present "$staged" "$case_name left no staged cutover database to inspect"
  if [ "$point" = during_database_build ]; then
    assert_equal "$(staged_journals "$home")" 1 \
      "$case_name left no rollback journal for the open transaction"
  fi
  assert_equal "$(staged_db_query "$staged" "SELECT count(*) FROM meta")" \
    "$expected_meta" "$case_name published a partial meta row"
  assert_equal "$(staged_db_query "$staged" "SELECT count(*) FROM messages")" \
    "$expected_messages" "$case_name published a partial message set"
  local recovered
  recovered=$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate)
  assert_contains "$recovered" "migrated: archive=" \
    "$case_name could not be recovered by rerunning migrate"
  assert_equal "$(database_temps "$home")" 0 \
    "$case_name left staging or its rollback journal behind"
  assert_converged_migration "$home" "$case_name"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM messages")" 2 \
    "$case_name did not import every legacy message on recovery"
}

cutover_atomicity_case rollback-before-commit during_database_build 0 0
cutover_atomicity_case durable-after-commit after_database_commit 1 2
pass "a cutover's meta, messages, notices, and offset commit as one transaction whose journal is reaped"

H_JOURNAL_ONLY="$TMP_ROOT/journal-only-leftover"
JOURNAL_ONLY_ENV="$TMP_ROOT/journal-only-leftover.env"
seed_migration_home "$H_JOURNAL_ONLY" "$JOURNAL_ONLY_ENV"
mkdir -p "$H_JOURNAL_ONLY/state/telegram"
chmod 700 "$H_JOURNAL_ONLY/state/telegram"
JOURNAL_ONLY_BASE=".channel.db.999.bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
printf 'orphan journal\n' > "$H_JOURNAL_ONLY/state/telegram/$JOURNAL_ONLY_BASE-journal"
chmod 600 "$H_JOURNAL_ONLY/state/telegram/$JOURNAL_ONLY_BASE-journal"
assert_contains "$(FM_HOME="$H_JOURNAL_ONLY" FM_TELEGRAM_ENV_FILE="$JOURNAL_ONLY_ENV" \
  "$ADAPTER" migrate)" "migrated: archive=" \
  "an orphan rollback journal blocked migration"
assert_equal "$(database_temps "$H_JOURNAL_ONLY")" 0 \
  "an orphan rollback journal survived reconciliation"
pass "a rollback journal orphaned by an uncatchable termination is reaped, not refused forever"

H_DB_PUBLISH="$TMP_ROOT/crash-database-publish"
DB_PUBLISH_ENV="$TMP_ROOT/crash-database-publish.env"
seed_migration_home "$H_DB_PUBLISH" "$DB_PUBLISH_ENV"
db_publish_status=0
db_publish_out=$(FM_TELEGRAM_FAILPOINT=after_database_publish FM_HOME="$H_DB_PUBLISH" \
  FM_TELEGRAM_ENV_FILE="$DB_PUBLISH_ENV" "$ADAPTER" migrate 2>&1) || db_publish_status=$?
[ "$db_publish_status" -ne 0 ] || fail "a failure after database publication reported success"
assert_present "$H_DB_PUBLISH/state/telegram/channel.db" \
  "a failure after database publication unpublished the cutover"
db_publish_archive="$H_DB_PUBLISH/state/$(db_query "$H_DB_PUBLISH" \
  "SELECT migration_archive FROM meta")"
assert_present "$db_publish_archive/manifest.json" \
  "a failure after database publication discarded the sealed archive the database names"
assert_contains "$db_publish_out" "published but could not be confirmed" \
  "a failure after database publication did not report the concrete condition"
assert_equal "$(database_temps "$H_DB_PUBLISH")" 0 \
  "a failure after database publication left its database staging behind"
db_publish_doctor=$(FM_HOME="$H_DB_PUBLISH" "$ADAPTER" doctor)
assert_contains "$db_publish_doctor" "integrity=ok" \
  "the published cutover database is not valid after the post-publication failure"
assert_contains "$db_publish_doctor" "migration_status=complete" \
  "the published cutover did not survive the post-publication failure"
db_publish_repeat_status=0
db_publish_repeat=$(FM_HOME="$H_DB_PUBLISH" FM_TELEGRAM_ENV_FILE="$DB_PUBLISH_ENV" \
  "$ADAPTER" migrate 2>&1) || db_publish_repeat_status=$?
[ "$db_publish_repeat_status" -ne 0 ] || fail "a published cutover was migrated a second time"
assert_contains "$db_publish_repeat" "migration is single-use" \
  "a published cutover did not refuse a second migration"
assert_present "$db_publish_archive/manifest.json" \
  "the second migration attempt discarded the published cutover's archive"
pass "a failure after database publication preserves both the database and its sealed archive"

write_owner_marker() {
  printf '{"created_at":1,"pid":999,"schema":"%s"}' "$2" > "$1"
  chmod 600 "$1"
}

leftover_refusal_case() {
  local case_name=$1 expected_reason=$2
  local home="$TMP_ROOT/leftover-$1" env_file="$TMP_ROOT/leftover-$1.env"
  seed_migration_home "$home" "$env_file"
  local leftover="$home/state/.telegram-migration-staging-999-deadbeef"
  local db_temp="$home/state/telegram/.channel.db.999.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  case "$case_name" in
    unmarked)
      mkdir -p "$leftover/state"
      printf '{"update_id":1,"text":"copy"}\n' > "$leftover/state/1.json"
      ;;
    symlinked)
      mkdir -p "$home/state/elsewhere"
      ln -s "$home/state/elsewhere" "$leftover"
      ;;
    ambiguous-marker)
      mkdir -p "$leftover/state"
      printf 'not a marker\n' > "$leftover.owner"
      ;;
    stray-archive-entry)
      mkdir -p "$home/state/telegram-migration-archive"
      printf 'stray\n' > "$home/state/telegram-migration-archive/notes.txt"
      chmod 700 "$home/state/telegram-migration-archive"
      ;;
    misnamed-archive)
      mkdir -p "$home/state/telegram-migration-archive/not-an-archive"
      chmod 700 "$home/state/telegram-migration-archive"
      ;;
    unmanifested-archive)
      mkdir -p "$home/state/telegram-migration-archive/20260101T000000Z-abcdef01/state"
      chmod 700 "$home/state/telegram-migration-archive"
      ;;
    archive-parent-mode)
      mkdir -p "$home/state/telegram-migration-archive"
      chmod 755 "$home/state/telegram-migration-archive"
      ;;
    symlinked-telegram-dir)
      mkdir -p "$home/state/elsewhere"
      ln -s "$home/state/elsewhere" "$home/state/telegram"
      ;;
    world-readable-telegram-dir)
      mkdir -p "$home/state/telegram"
      chmod 755 "$home/state/telegram"
      ;;
    stray-database-temp)
      mkdir -p "$home/state/telegram"
      chmod 700 "$home/state/telegram"
      printf 'stray\n' > "$home/state/telegram/.channel.db.stray"
      chmod 600 "$home/state/telegram/.channel.db.stray"
      ;;
    symlinked-database-temp)
      mkdir -p "$home/state/telegram"
      chmod 700 "$home/state/telegram"
      ln -s "$home/state/.telegram-offset" "$db_temp"
      ;;
    unmarked-database-temp)
      mkdir -p "$home/state/telegram"
      chmod 700 "$home/state/telegram"
      printf 'payload copy\n' > "$db_temp"
      chmod 600 "$db_temp"
      ;;
    world-readable-database-temp)
      mkdir -p "$home/state/telegram"
      chmod 700 "$home/state/telegram"
      printf 'payload copy\n' > "$db_temp"
      chmod 644 "$db_temp"
      write_owner_marker "$db_temp.owner" fm-telegram-database-staging.v1
      ;;
  esac
  local status=0 out
  out=$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "$case_name leftover did not refuse migration"
  assert_contains "$out" "inspect and remove it manually, then rerun migrate" \
    "$case_name leftover was not refused actionably for the running command"
  assert_contains "$out" "$expected_reason" \
    "$case_name leftover was refused by a check other than the one it exercises"
  if [ "$case_name" != archive-parent-mode ] \
    && [ "$case_name" != world-readable-telegram-dir ]; then
    case "$out" in
      *"has an unexpected mode"*)
        fail "$case_name leftover never reached its own validation branch" ;;
    esac
  fi
  assert_absent "$home/state/telegram/channel.db" \
    "$case_name leftover still published a database"
  case "$case_name" in
    unmarked|ambiguous-marker)
      assert_present "$leftover/state" "$case_name leftover was swept by name" ;;
    symlinked)
      [ -L "$leftover" ] || fail "$case_name leftover was swept by name" ;;
    stray-archive-entry)
      assert_present "$home/state/telegram-migration-archive/notes.txt" \
        "$case_name leftover was swept by name" ;;
    misnamed-archive)
      assert_present "$home/state/telegram-migration-archive/not-an-archive" \
        "$case_name leftover was swept by name" ;;
    unmanifested-archive)
      assert_present "$home/state/telegram-migration-archive/20260101T000000Z-abcdef01" \
        "$case_name leftover was swept by name" ;;
    archive-parent-mode)
      assert_present "$home/state/telegram-migration-archive" \
        "$case_name leftover was swept by name" ;;
    symlinked-telegram-dir)
      [ -L "$home/state/telegram" ] || fail "$case_name leftover was swept by name"
      [ ! -e "$home/state/telegram-migration-archive" ] \
        || fail "$case_name archived legacy state before refusing" ;;
    world-readable-telegram-dir)
      assert_present "$home/state/telegram" "$case_name leftover was swept by name"
      [ ! -e "$home/state/telegram-migration-archive" ] \
        || fail "$case_name archived legacy state before refusing" ;;
    stray-database-temp)
      assert_present "$home/state/telegram/.channel.db.stray" \
        "$case_name leftover was swept by name" ;;
    symlinked-database-temp)
      [ -L "$db_temp" ] || fail "$case_name leftover was swept by name" ;;
    unmarked-database-temp|world-readable-database-temp)
      assert_present "$db_temp" "$case_name leftover was swept by name" ;;
  esac
  local repeat_status=0 repeat
  repeat=$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate 2>&1) \
    || repeat_status=$?
  assert_equal "$repeat" "$out" "$case_name leftover refusal was not idempotent"
  assert_equal "$repeat_status" "$status" "$case_name leftover refusal changed its status"
  chmod -R u+w "$leftover" "$home/state/telegram-migration-archive" \
    "$home/state/telegram" 2>/dev/null || true
  rm -rf "$leftover" "$leftover.owner" "$home/state/telegram-migration-archive" \
    "$home/state/telegram"
  assert_contains "$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate)" \
    "migrated: archive=" "$case_name blocked migration after the leftover was removed"
  assert_converged_migration "$home" "$case_name"
}

leftover_refusal_case unmarked "has no valid private staging ownership marker"
leftover_refusal_case symlinked "is not a private staging directory"
leftover_refusal_case ambiguous-marker "has no valid private staging ownership marker"
leftover_refusal_case archive-parent-mode "has an unexpected mode"
leftover_refusal_case stray-archive-entry "is not a published archive directory"
leftover_refusal_case misnamed-archive "does not carry a published archive name"
leftover_refusal_case unmanifested-archive "is not a complete manifest-bound archive"
leftover_refusal_case symlinked-telegram-dir "is not a private state directory"
leftover_refusal_case world-readable-telegram-dir "has an unexpected mode"
leftover_refusal_case stray-database-temp \
  "does not carry this migrator's database staging name"
leftover_refusal_case symlinked-database-temp "is not a private database staging file"
leftover_refusal_case unmarked-database-temp \
  "has no valid private database staging ownership marker"
leftover_refusal_case world-readable-database-temp \
  "is not a private mode-0600 database staging file"
pass "unmarked, symlinked, misnamed, and world-readable leftovers each refuse at their own check"

staged_mutation_case() {
  local case_name=$1 home="$TMP_ROOT/staged-$1" env_file="$TMP_ROOT/staged-$1.env"
  local marker="$TMP_ROOT/staged-$1.marker" release="$TMP_ROOT/staged-$1.release"
  local output="$TMP_ROOT/staged-$1.out" boundary="staged-archive"
  if [ "$case_name" = pre-manifest-truncated ]; then
    boundary="staged-copies"
  fi
  seed_migration_home "$home" "$env_file"
  local before after
  before=$(legacy_fingerprint "$home")
  FM_TELEGRAM_FAILPOINT="$boundary" \
    FM_TELEGRAM_FAILPOINT_MARKER="$marker" \
    FM_TELEGRAM_FAILPOINT_RELEASE="$release" \
    FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" \
    "$ADAPTER" migrate > "$output" 2>&1 &
  local pid=$!
  local staged=
  for _ in $(seq 1 500); do
    [ -e "$marker" ] && break
    sleep 0.01
  done
  assert_present "$marker" "$case_name never reached the staged-archive boundary"
  staged=$(find "$home/state" -maxdepth 1 -name '.telegram-migration-staging-*' -type d)
  assert_present "$staged/state/telegram-inbox/handled/900.json" \
    "$case_name did not stage the legacy payload it was supposed to verify"
  case "$case_name" in
    truncated|pre-manifest-truncated)
      : > "$staged/state/telegram-inbox/handled/900.json" ;;
    removed) rm -f "$staged/state/telegram-inbox/handled/900.json" ;;
  esac
  : > "$release"
  local status=0
  wait "$pid" || status=$?
  [ "$status" -ne 0 ] || fail "$case_name published a cutover from mutated staged evidence"
  assert_grep 'telegram-inbox/handled/900.json' "$output" \
    "$case_name verifier did not name the mutated staged artifact"
  assert_absent "$home/state/telegram/channel.db" \
    "$case_name published a database from mutated staged evidence"
  assert_equal "$(published_archives "$home")" 0 \
    "$case_name published an archive from mutated staged evidence"
  [ -z "$(find "$home/state" -maxdepth 1 -name '.telegram-migration-staging-*')" ] \
    || fail "$case_name left its mutated staging behind"
  after=$(legacy_fingerprint "$home")
  assert_equal "$after" "$before" "$case_name changed the original legacy bytes"
  assert_contains "$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate)" \
    "migrated: archive=" "$case_name blocked a clean rerun"
  assert_converged_migration "$home" "$case_name"
}

staged_mutation_case truncated
staged_mutation_case removed
staged_mutation_case pre-manifest-truncated
assert_grep 'does not match the original legacy artifact' \
  "$TMP_ROOT/staged-pre-manifest-truncated.out" \
  "a short staged copy its own manifest agrees with was not compared to the original"
pass "staged evidence mutated before verification publishes neither archive nor database"

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
ack_result "$H_AMBIGUOUS" "$AMBIGUOUS_ENV" "$ambiguous_poll" >/dev/null \
  || fail "the first blocked-migration notice could not be acknowledged"
ambiguous_repeat_status=0
ambiguous_repeat=$(poll_once "$H_AMBIGUOUS" "$AMBIGUOUS_ENV" "$FIXTURES/one-text.json") \
  || ambiguous_repeat_status=$?
[ "$ambiguous_repeat_status" -eq 0 ] \
  || fail "an acknowledged blocked migration fell into the runner's silent nonzero path"
assert_contains "$ambiguous_repeat" "blocked: local-state fingerprint=" \
  "an acknowledged blocked migration stopped producing an actionable result"
ambiguous_again=$(poll_once "$H_AMBIGUOUS" "$AMBIGUOUS_ENV" "$FIXTURES/one-text.json")
assert_equal "$ambiguous_again" "$ambiguous_repeat" \
  "the blocked-migration fingerprint is not stable across polls"
write_result "$ambiguous_repeat"
assert_equal \
  "$(FM_HOME="$H_AMBIGUOUS" FM_TELEGRAM_ENV_FILE="$AMBIGUOUS_ENV" "$ADAPTER" classify "$RESULT_FILE")" \
  blocked "a recurring blocked migration did not classify as blocked"
assert_equal \
  "$(FM_HOME="$H_AMBIGUOUS" FM_TELEGRAM_ENV_FILE="$AMBIGUOUS_ENV" "$ADAPTER" ack "$RESULT_FILE")" \
  "unacknowledgeable: local-state" \
  "a recurring blocked migration could be acknowledged away"
ambiguous_persist=$(poll_once "$H_AMBIGUOUS" "$AMBIGUOUS_ENV" "$FIXTURES/one-text.json")
assert_equal "$ambiguous_persist" "$ambiguous_repeat" \
  "a blocked migration went silent after an acknowledgement attempt"
assert_no_curl "a recurring blocked migration called Telegram from a guessed offset"
assert_equal "$(db_query "$H_AMBIGUOUS" "SELECT committed_offset FROM meta")" 0 \
  "a recurring blocked migration guessed an offset"
pass "ambiguous migration preserves evidence, guesses nothing, and stays unacknowledgeably blocked"

H_CAUSE="$TMP_ROOT/migrate-blocked-cause"
CAUSE_ENV="$TMP_ROOT/migrate-blocked-cause.env"
new_home "$H_CAUSE"
write_env_file "$CAUSE_ENV" "$TOKEN"
printf '1002\n' > "$H_CAUSE/state/.telegram-offset"
printf '418\n' > "$H_CAUSE/state/.telegram-blocked"
mkdir -p "$H_CAUSE/state/telegram-inbox/handled"
printf '{"update_id":1001,"date":1,"chat_id":555,"from_id":909,"text":"%s"}\n' \
  "$CAPTAIN_SECRET_TEXT" > "$H_CAUSE/state/telegram-inbox/handled/1001.json"
cause_status=0
cause_out=$(FM_HOME="$H_CAUSE" FM_TELEGRAM_ENV_FILE="$CAUSE_ENV" "$ADAPTER" migrate 2>&1) \
  || cause_status=$?
[ "$cause_status" -ne 0 ] || fail "a malformed legacy marker reported migration success"
assert_contains "$cause_out" "blocked: migration-ambiguous" \
  "a malformed legacy marker did not block the cutover"
assert_contains "$cause_out" "detail: legacy blocked marker is malformed" \
  "the blocked cutover discarded its cause"
cause_doctor=$(FM_HOME="$H_CAUSE" FM_TELEGRAM_ENV_FILE="$CAUSE_ENV" "$ADAPTER" doctor)
assert_contains "$cause_doctor" "migration_status=blocked" \
  "doctor did not report the blocked migration"
assert_contains "$cause_doctor" "migration_cause=legacy blocked marker is malformed" \
  "doctor reported only a hash instead of the actionable cause"
case "$cause_doctor" in
  *"$CAPTAIN_SECRET_TEXT"*) fail "the retained migration cause leaked captain message text" ;;
esac
case "$cause_doctor" in
  *"$TOKEN"*) fail "the retained migration cause leaked the bot token" ;;
esac
case "$cause_out" in
  *"$CAPTAIN_SECRET_TEXT"*) fail "the blocked migration output leaked captain message text" ;;
esac
cause_stored=$(db_query "$H_CAUSE" "SELECT length(migration_cause) FROM meta")
[ "$cause_stored" -le 240 ] || fail "the retained migration cause is not bounded"
pass "a blocked cutover retains a bounded non-secret cause that doctor reports"

blocked_cause_case control-byte-name "telegram-inbox/bad"
blocked_cause_case unknown-entry "telegram-inbox/notes.txt"
blocked_cause_case filename-id-mismatch "telegram-inbox/7.json"
blocked_cause_case torn-payload "telegram-inbox/1002.json"
H_CTRL="$TMP_ROOT/cause-control-byte-name"
CTRL_ENV="$TMP_ROOT/cause-control-byte-name.env"
FM_HOME="$H_CTRL" FM_TELEGRAM_ENV_FILE="$CTRL_ENV" "$ADAPTER" arm >/dev/null
clear_curl_calls
ctrl_poll=$(poll_once "$H_CTRL" "$CTRL_ENV" "$FIXTURES/one-text.json")
assert_contains "$ctrl_poll" "blocked: migration-blocked ambiguous" \
  "a control-byte artifact name left the channel unbringable instead of blocked"
assert_no_curl "a blocked control-byte migration still called Telegram"
pass "every malformed legacy artifact shape blocks with a printable state-relative cause"

H_RECEIPT_HANDLED="$TMP_ROOT/migrate-receipt-handled"
RECEIPT_HANDLED_ENV="$TMP_ROOT/migrate-receipt-handled.env"
new_home "$H_RECEIPT_HANDLED"
write_env_file "$RECEIPT_HANDLED_ENV" "$TOKEN"
printf '1003\n' > "$H_RECEIPT_HANDLED/state/.telegram-offset"
mkdir -p "$H_RECEIPT_HANDLED/state/telegram-inbox/handled"
printf '{"update_id":1002,"date":2,"chat_id":555,"from_id":909,"text":"receipt then handled"}\n' \
  > "$H_RECEIPT_HANDLED/state/telegram-inbox/handled/1002.json"
mkdir -p "$H_RECEIPT_HANDLED/state/.telegram-delivery-receipts"
cp "$H_RECEIPT_HANDLED/state/telegram-inbox/handled/1002.json" \
  "$H_RECEIPT_HANDLED/state/.telegram-delivery-receipts/1002.json"
receipt_handled_status=0
receipt_handled_out=$(FM_HOME="$H_RECEIPT_HANDLED" FM_TELEGRAM_ENV_FILE="$RECEIPT_HANDLED_ENV" \
  "$ADAPTER" migrate 2>&1) || receipt_handled_status=$?
[ "$receipt_handled_status" -eq 0 ] \
  || fail "a receipt already in handled state failed migration: $receipt_handled_out"
assert_contains "$receipt_handled_out" "migrated: archive=" \
  "a receipt already in handled state did not migrate coherently"
assert_equal "$(db_query "$H_RECEIPT_HANDLED" "SELECT migration_status FROM meta")" complete \
  "a receipt already in handled state did not complete migration"
assert_equal "$(db_query "$H_RECEIPT_HANDLED" "SELECT committed_offset FROM meta")" 1003 \
  "a receipt already in handled state changed the committed offset"
assert_equal "$(db_query "$H_RECEIPT_HANDLED" "SELECT count(*) FROM messages")" 1 \
  "a receipt already in handled state duplicated its message"
assert_equal "$(db_query "$H_RECEIPT_HANDLED" "SELECT count(*) FROM messages WHERE handled_at IS NOT NULL")" 1 \
  "an already handled legacy message was reimported as pending"
assert_present "$H_RECEIPT_HANDLED/state/.telegram-delivery-receipts/1002.json" \
  "migration deleted the already handled receipt"
clear_curl_calls
receipt_handled_poll=$(poll_once "$H_RECEIPT_HANDLED" "$RECEIPT_HANDLED_ENV" "$FIXTURES/empty.json") \
  || true
assert_equal "$receipt_handled_poll" "" \
  "a fully handled legacy receipt announced a phantom pending message"
pass "a receipt whose update is already handled migrates without a phantom pending message"

H_TOMBSTONE="$TMP_ROOT/migrate-tombstone"
TOMBSTONE_ENV="$TMP_ROOT/migrate-tombstone.env"
new_home "$H_TOMBSTONE"
write_env_file "$TOMBSTONE_ENV" "$TOKEN"
mkdir -p "$H_TOMBSTONE/state/telegram-inbox/handled"
printf '{"update_id":1001,"text":"ahoy from the captain"}\n' \
  > "$H_TOMBSTONE/state/telegram-inbox/handled/1001.json"
tombstone_out=$(FM_HOME="$H_TOMBSTONE" FM_TELEGRAM_ENV_FILE="$TOMBSTONE_ENV" \
  "$ADAPTER" migrate)
assert_contains "$tombstone_out" "migrated: archive=" \
  "a sparse already-handled legacy row blocked migration"
assert_equal "$(db_query "$H_TOMBSTONE" "SELECT committed_offset FROM meta")" 0 \
  "an already-handled legacy row advanced the committed offset by itself"
assert_equal "$(db_query "$H_TOMBSTONE" \
  "SELECT count(*) FROM messages WHERE payload IS NULL AND handled_at IS NOT NULL")" 1 \
  "an already-handled legacy row was not imported as a dedup tombstone"
FM_HOME="$H_TOMBSTONE" FM_TELEGRAM_ENV_FILE="$TOMBSTONE_ENV" "$ADAPTER" arm >/dev/null
clear_curl_calls
tombstone_replay_status=0
tombstone_replay=$(poll_once "$H_TOMBSTONE" "$TOMBSTONE_ENV" "$FIXTURES/one-text.json") \
  || tombstone_replay_status=$?
assert_equal "$tombstone_replay" "" \
  "a Telegram replay of an already-handled update woke the captain again"
[ "$tombstone_replay_status" -ne 0 ] \
  || fail "a replay consumed by a tombstone reported a deliverable result"
assert_equal "$(db_query "$H_TOMBSTONE" "SELECT committed_offset FROM meta")" 1002 \
  "the replay batch's own transition did not advance the committed offset"
assert_equal "$(db_query "$H_TOMBSTONE" \
  "SELECT count(*) FROM notices WHERE kind = 'message'")" 0 \
  "a replay consumed by a tombstone created a message notice"
tombstone_next=$(poll_once "$H_TOMBSTONE" "$TOMBSTONE_ENV" "$FIXTURES/next-text.json")
assert_contains "$tombstone_next" "message: 1" \
  "the channel did not keep delivering after a tombstone consumed a replay"
pass "an already-handled legacy row deduplicates a later replay without delivering it again"

H_SPARSE_PENDING="$TMP_ROOT/migrate-sparse-pending"
SPARSE_PENDING_ENV="$TMP_ROOT/migrate-sparse-pending.env"
new_home "$H_SPARSE_PENDING"
write_env_file "$SPARSE_PENDING_ENV" "$TOKEN"
mkdir -p "$H_SPARSE_PENDING/state/telegram-inbox"
printf '{"update_id":1002,"text":"never delivered"}\n' \
  > "$H_SPARSE_PENDING/state/telegram-inbox/1002.json"
sparse_pending_status=0
sparse_pending_out=$(FM_HOME="$H_SPARSE_PENDING" \
  FM_TELEGRAM_ENV_FILE="$SPARSE_PENDING_ENV" "$ADAPTER" migrate 2>&1) \
  || sparse_pending_status=$?
[ "$sparse_pending_status" -ne 0 ] \
  || fail "a sparse undelivered legacy row migrated as coherent state"
assert_contains "$sparse_pending_out" "blocked: migration-ambiguous" \
  "a sparse undelivered legacy row did not block the cutover"
assert_contains "$(doctor_cause "$H_SPARSE_PENDING")" \
  "telegram-inbox/1002.json" \
  "the blocked cutover did not name the incoherent undelivered artifact"
assert_equal "$(db_query "$H_SPARSE_PENDING" "SELECT committed_offset FROM meta")" 0 \
  "a blocked sparse-pending cutover guessed an offset"
pass "a legacy row still awaiting delivery must carry coherent identity or block the cutover"

pending_date_case() {
  local case_name=$1 payload=$2 expect=$3
  local home="$TMP_ROOT/pending-date-$1" env_file="$TMP_ROOT/pending-date-$1.env"
  new_home "$home"
  write_env_file "$env_file" "$TOKEN"
  printf '1000\n' > "$home/state/.telegram-offset"
  mkdir -p "$home/state/.telegram-delivery-receipts"
  printf '%s\n' "$payload" > "$home/state/.telegram-delivery-receipts/1500.json"
  local status=0 out
  out=$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate 2>&1) || status=$?
  if [ "$expect" = migrated ]; then
    [ "$status" -eq 0 ] || fail "$case_name refused a coherent undelivered payload: $out"
    assert_contains "$out" "migrated: archive=" "$case_name did not complete the cutover"
    assert_equal "$(db_query "$home" \
      "SELECT count(*) FROM messages WHERE payload LIKE '%\"date\":1700000000%'")" 1 \
      "$case_name did not import the exact legacy date"
    return
  fi
  [ "$status" -ne 0 ] || fail "$case_name migrated an incoherent undelivered date"
  assert_contains "$out" "blocked: migration-ambiguous" \
    "$case_name did not block the cutover"
  assert_contains "$(doctor_cause "$home")" "coherent integer date" \
    "$case_name did not name the incoherent date as its cause"
  assert_present "$home/state/$(db_query "$home" "SELECT migration_archive FROM meta")/manifest.json" \
    "$case_name blocked without archiving the legacy evidence"
  assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" 0 \
    "$case_name guessed an offset"
}

pending_date_case exact-date \
  '{"update_id":1500,"date":1700000000,"chat_id":555,"from_id":909,"text":"hi"}' migrated
pending_date_case missing-date '{"update_id":1500,"chat_id":555,"from_id":909,"text":"hi"}' blocked
pending_date_case null-date \
  '{"update_id":1500,"date":null,"chat_id":555,"from_id":909,"text":"hi"}' blocked
pending_date_case boolean-date \
  '{"update_id":1500,"date":true,"chat_id":555,"from_id":909,"text":"hi"}' blocked
pending_date_case string-date \
  '{"update_id":1500,"date":"1700000000","chat_id":555,"from_id":909,"text":"hi"}' blocked
pass "an undelivered legacy payload needs an exact integer date or the cutover blocks"

tombstone_identity_case() {
  local case_name=$1 payload=$2
  local home="$TMP_ROOT/tombstone-id-$1" env_file="$TMP_ROOT/tombstone-id-$1.env"
  new_home "$home"
  write_env_file "$env_file" "$TOKEN"
  mkdir -p "$home/state/telegram-inbox/handled"
  printf '%s\n' "$payload" > "$home/state/telegram-inbox/handled/1001.json"
  local status=0 out
  out=$(FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate 2>&1) || status=$?
  [ "$status" -ne 0 ] || fail "$case_name created a tombstone from a malformed identifier"
  assert_contains "$out" "blocked: migration-ambiguous" \
    "$case_name did not block the cutover"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM messages")" 0 \
    "$case_name imported a message row"
}

tombstone_identity_case boolean-id '{"update_id":true,"text":"hi"}'
tombstone_identity_case zero-id '{"update_id":0,"text":"hi"}'
tombstone_identity_case string-id '{"update_id":"1001","text":"hi"}'
tombstone_identity_case out-of-range-id '{"update_id":2147483648,"text":"hi"}'
pass "a malformed update identifier can never become a dedup tombstone"

H_UNREADABLE="$TMP_ROOT/migrate-unreadable"
UNREADABLE_ENV="$TMP_ROOT/migrate-unreadable.env"
new_home "$H_UNREADABLE"
write_env_file "$UNREADABLE_ENV" "$TOKEN"
printf '1002\n' > "$H_UNREADABLE/state/.telegram-offset"
mkdir -p "$H_UNREADABLE/state/telegram-inbox"
python3 -c 'import sys; open(sys.argv[1], "w").write("[" * 60000 + "]" * 60000)' \
  "$H_UNREADABLE/state/telegram-inbox/1002.json"
unreadable_status=0
unreadable_out=$(FM_HOME="$H_UNREADABLE" FM_TELEGRAM_ENV_FILE="$UNREADABLE_ENV" \
  "$ADAPTER" migrate 2>&1) || unreadable_status=$?
[ "$unreadable_status" -ne 0 ] || fail "an unreadable legacy payload reported migration success"
assert_contains "$unreadable_out" "blocked: migration-ambiguous" \
  "a non-UserError legacy read failure escaped the blocked migration path"
assert_equal "$(db_query "$H_UNREADABLE" "SELECT migration_status FROM meta")" blocked \
  "a non-UserError legacy read failure published no blocked cutover"
assert_equal "$(db_query "$H_UNREADABLE" "SELECT committed_offset FROM meta")" 0 \
  "a non-UserError legacy read failure guessed an offset"
assert_present "$H_UNREADABLE/state/telegram-inbox/1002.json" \
  "a non-UserError legacy read failure deleted its evidence"
pass "a legacy read failure that is not a UserError still publishes an actionable blocked migration"

H_TORN="$TMP_ROOT/migrate-torn-claim"
TORN_ENV="$TMP_ROOT/migrate-torn-claim.env"
new_home "$H_TORN"
write_env_file "$TORN_ENV" "$TOKEN"
printf '1002\n' > "$H_TORN/state/.telegram-offset"
mkdir -p "$H_TORN/state/telegram-inbox"
: > "$H_TORN/state/telegram-inbox/1002.json"
torn_status=0
torn_out=$(FM_HOME="$H_TORN" FM_TELEGRAM_ENV_FILE="$TORN_ENV" "$ADAPTER" migrate 2>&1) \
  || torn_status=$?
[ "$torn_status" -ne 0 ] || fail "a torn legacy claim reported migration success"
assert_contains "$torn_out" "blocked: migration-ambiguous" \
  "a torn legacy claim did not block the cutover"
torn_archive_rel=$(db_query "$H_TORN" "SELECT migration_archive FROM meta")
torn_archive="$H_TORN/state/$torn_archive_rel"
assert_present "$torn_archive/manifest.json" "a torn legacy claim produced no archive manifest"
assert_grep 'telegram-inbox/1002.json' "$torn_archive/manifest.json" \
  "the archive omitted the torn legacy claim"
assert_present "$torn_archive/state/telegram-inbox/1002.json" \
  "the archive did not preserve the torn legacy claim itself"
assert_present "$H_TORN/state/telegram-inbox/1002.json" \
  "migration deleted the torn legacy claim"
assert_equal "$(tr -d '\n' < "$H_TORN/state/.telegram-offset")" 1002 \
  "migration advanced the unadvanced legacy offset"
assert_equal "$(db_query "$H_TORN" "SELECT migration_status FROM meta")" blocked \
  "a torn legacy claim did not persist a blocked cutover"
assert_equal "$(db_query "$H_TORN" "SELECT committed_offset FROM meta")" 0 \
  "a torn legacy claim guessed an offset"
FM_HOME="$H_TORN" FM_TELEGRAM_ENV_FILE="$TORN_ENV" "$ADAPTER" arm >/dev/null
clear_curl_calls
torn_poll=$(poll_once "$H_TORN" "$TORN_ENV" "$FIXTURES/one-text.json")
assert_contains "$torn_poll" "blocked: migration-blocked ambiguous" \
  "a torn legacy claim did not announce its blocked migration through the channel"
assert_no_curl "a blocked torn-claim migration still called Telegram"
assert_equal "$(db_query "$H_TORN" "SELECT committed_offset FROM meta")" 0 \
  "a poll from a blocked torn-claim migration advanced the committed offset"
pass "a torn legacy claim is archived, visibly blocked, and never advances the irreversible offset"

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

# --- a state path carrying URI metacharacters opens the same way it was built -
H_URI="$TMP_ROOT/uri%25pct#frag?query"
URI_ENV="$TMP_ROOT/uri-metachars.env"
arm_home "$H_URI" "$URI_ENV"
uri_out=$(poll_once "$H_URI" "$URI_ENV" "$FIXTURES/one-text.json")
assert_contains "$uri_out" "message:" \
  "a state path with URI metacharacters could not be reopened after creation"
assert_equal "$(db_query "$H_URI" "SELECT committed_offset FROM meta")" 1002 \
  "a state path with URI metacharacters lost its committed offset"
write_result "$uri_out"
assert_contains \
  "$(FM_HOME="$H_URI" FM_TELEGRAM_ENV_FILE="$URI_ENV" "$ADAPTER" messages "$RESULT_FILE")" \
  "ahoy from the captain" \
  "a state path with URI metacharacters hid the captain payload"
assert_contains "$(FM_HOME="$H_URI" "$ADAPTER" doctor)" "integrity=ok" \
  "doctor could not read a state path with URI metacharacters"
pass "creation and reopen agree for state paths containing URI metacharacters"

# --- a missing engine stays capturable, classifiable, and disposable ---------
H_NO_ENGINE="$TMP_ROOT/engine-unavailable"
NO_ENGINE_ENV="$TMP_ROOT/engine-unavailable.env"
arm_home "$H_NO_ENGINE" "$NO_ENGINE_ENV"
NO_PYTHON_BIN="$TMP_ROOT/no-python-bin"
mkdir -p "$NO_PYTHON_BIN"
for required_tool in bash dirname; do
  ln -sf "$(command -v "$required_tool")" "$NO_PYTHON_BIN/$required_tool"
done
PATH="$NO_PYTHON_BIN" command -v python3 >/dev/null 2>&1 \
  && fail "the engine-unavailable fixture still exposes python3"
no_engine_poll_status=0
no_engine_poll=$(PATH="$NO_PYTHON_BIN" FM_HOME="$H_NO_ENGINE" \
  FM_TELEGRAM_ENV_FILE="$NO_ENGINE_ENV" "$ADAPTER" poll) || no_engine_poll_status=$?
[ "$no_engine_poll_status" -eq 0 ] || fail "a missing engine made poll uncapturable"
assert_contains "$no_engine_poll" "blocked: local-state fingerprint=" \
  "a missing engine did not announce a local-state block"
write_result "$no_engine_poll"
no_engine_classify_status=0
no_engine_classify=$(PATH="$NO_PYTHON_BIN" FM_HOME="$H_NO_ENGINE" \
  FM_TELEGRAM_ENV_FILE="$NO_ENGINE_ENV" "$ADAPTER" classify "$RESULT_FILE") \
  || no_engine_classify_status=$?
[ "$no_engine_classify_status" -eq 0 ] || fail "classify failed instead of reporting blocked"
assert_equal "$no_engine_classify" blocked \
  "a missing engine muted the documented interpretation path"
no_engine_ack_status=0
no_engine_ack=$(PATH="$NO_PYTHON_BIN" FM_HOME="$H_NO_ENGINE" \
  FM_TELEGRAM_ENV_FILE="$NO_ENGINE_ENV" "$ADAPTER" ack "$RESULT_FILE") \
  || no_engine_ack_status=$?
[ "$no_engine_ack_status" -eq 0 ] || fail "ack failed instead of reporting unacknowledgeable"
assert_equal "$no_engine_ack" "unacknowledgeable: local-state" \
  "a missing engine muted the documented disposal path"
pass "a missing engine still yields a blocked result the handler can classify and dispose"

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
