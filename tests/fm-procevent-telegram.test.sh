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
first_argument=${1:-}
if [ -n "${CURL_STUB_CALL_LOG:-}" ]; then
  printf '%s\n' "$config" >> "$CURL_STUB_CALL_LOG"
fi
if [ -n "${CURL_STUB_CAPTURE:-}" ]; then
  printf '%s\n' "$config" > "$CURL_STUB_CAPTURE"
fi
send_request=0
send_data_fd=
send_body=
write_format=
previous_argument=
for argument in "$@"; do
  [ "$previous_argument" = "--data-binary" ] && send_data_fd=$argument
  [ "$previous_argument" = "-w" ] && write_format=$argument
  [ "$argument" = "--data-binary" ] && send_request=1
  previous_argument=$argument
done

if [ "$send_request" -eq 1 ] && [ -n "$send_data_fd" ]; then
  send_body=$(cat "${send_data_fd#@}")
fi

# Render curl's --write-out format the way curl does, so a caller that escapes
# the http_code directive incorrectly gets the literal text curl would emit.
emit_write_out() {
  local format=$1 code=$2 rendered=""
  while [ -n "$format" ]; do
    case "$format" in
      '\n'*)            rendered="$rendered
"; format=${format:2} ;;
      '%%'*)            rendered="$rendered%"; format=${format:2} ;;
      '%{http_code}'*)  rendered="$rendered$code"; format=${format:12} ;;
      *)                rendered="$rendered${format:0:1}"; format=${format:1} ;;
    esac
  done
  printf '%s' "$rendered"
}
if [ "$send_request" -eq 1 ] && [ -n "${CURL_STUB_SEND_CAPTURE:-}" ]; then
  printf '%s' "$send_body" > "$CURL_STUB_SEND_CAPTURE"
fi
if [ "$send_request" -eq 1 ] && [ -n "${CURL_STUB_SEND_ATTEMPTS:-}" ]; then
  printf 'send\n' >> "$CURL_STUB_SEND_ATTEMPTS"
  if [ -n "${CURL_STUB_AMBIENT_TRACE:-}" ] && [ "$first_argument" != "-q" ]; then
    printf '%s' "$send_body" > "$CURL_STUB_AMBIENT_TRACE"
    printf 'send\n' >> "$CURL_STUB_SEND_ATTEMPTS"
  fi
fi
if [ "$send_request" -eq 1 ] && [ -n "${CURL_STUB_SLEEP:-}" ]; then
  sleep "$CURL_STUB_SLEEP"
  [ -n "${CURL_STUB_TIMEOUT:-}" ] && exit 28
fi
if [ "$send_request" -eq 1 ] && [ -n "${CURL_STUB_SEND_ECHO_TEXT:-}" ]; then
  printf '%s' "$send_body" | python3 -c '
import json
import sys
import urllib.parse

request = urllib.parse.parse_qs(sys.stdin.read(), strict_parsing=True)
reply_parameters = json.loads(request["reply_parameters"][0])
response = {
    "ok": True,
    "result": {
        "message_id": 8801,
        "chat": {"id": int(request["chat_id"][0])},
        "reply_to_message": {"message_id": reply_parameters["message_id"]},
        "text": request["text"][0].strip(),
    },
}
json.dump(response, sys.stdout, separators=(",", ":"))
'
elif [ "$send_request" -eq 1 ] && [ -n "${CURL_STUB_SEND_BODY:-}" ]; then
  cat "$CURL_STUB_SEND_BODY"
elif [ -n "${CURL_STUB_BULK_BYTES:-}" ]; then
  head -c "$CURL_STUB_BULK_BYTES" /dev/zero | tr '\0' 'x'
elif [ -n "${CURL_STUB_BODY:-}" ]; then
  cat "$CURL_STUB_BODY"
fi
case "${CURL_STUB_TRAILER:-full}" in
  full)    emit_write_out "$write_format" "${CURL_STUB_HTTP:-200}" ;;
  partial) emit_write_out "$write_format" "$(printf '%s' "${CURL_STUB_HTTP:-200}" | cut -c1-2)" ;;
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
fixture replyable-text \
  '{"ok":true,"result":[{"update_id":1101,"message":{"message_id":771,"date":1700000000,"chat":{"id":555},"from":{"id":909},"text":"reply to this"}}]}'
fixture reply-success \
  '{"ok":true,"result":{"message_id":8801,"chat":{"id":555},"reply_to_message":{"message_id":771},"text":"reply"}}'
fixture reply-wrong-chat \
  '{"ok":true,"result":{"message_id":8801,"chat":{"id":556},"reply_to_message":{"message_id":771},"text":"shape check"}}'
fixture reply-wrong-message \
  '{"ok":true,"result":{"message_id":8801,"chat":{"id":555},"reply_to_message":{"message_id":772},"text":"shape check"}}'
fixture reply-wrong-text \
  '{"ok":true,"result":{"message_id":8801,"chat":{"id":555},"reply_to_message":{"message_id":771},"text":"different reply"}}'
fixture reply-missing-text \
  '{"ok":true,"result":{"message_id":8801,"chat":{"id":555},"reply_to_message":{"message_id":771}}}'
fixture reply-malformed '{"ok":true,"result":{"message_id":8801}}'
fixture legacy-redelivery \
  '{"ok":true,"result":[{"update_id":3302,"message":{"message_id":4402,"date":5,"chat":{"id":555},"from":{"id":909},"text":"legacy receipt"}}]}'
fixture legacy-redelivery-changed \
  '{"ok":true,"result":[{"update_id":3302,"message":{"message_id":4402,"date":5,"chat":{"id":555},"from":{"id":909},"text":"rewritten by someone else"}}]}'
fixture foreign-unusable-message-id \
  '{"ok":true,"result":[{"update_id":1201,"message":{"message_id":0,"date":1,"chat":{"id":777},"from":{"id":888},"text":"another chat"}},{"update_id":1202,"message":{"message_id":772,"date":2,"chat":{"id":555},"from":{"id":909},"text":"captain in the same batch"}}]}'
fixture captain-unusable-message-id \
  '{"ok":true,"result":[{"update_id":1301,"message":{"message_id":0,"date":1,"chat":{"id":555},"from":{"id":909},"text":"captain without usable message identity"}}]}'
fixture reply-api-failure '{"ok":false,"error_code":400,"description":"bad request"}'
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
ambiguous_poll_file="$TMP_ROOT/ambiguous-parked.out"
clear_curl_calls
FM_TELEGRAM_POLL_TIMEOUT=1 FM_HOME="$H_AMBIGUOUS" \
  FM_TELEGRAM_ENV_FILE="$AMBIGUOUS_ENV" "$ADAPTER" poll >"$ambiguous_poll_file" 2>&1 &
ambiguous_pid=$!
sleep 3
kill -0 "$ambiguous_pid" 2>/dev/null || fail "an acknowledged blocked migration did not park its poll"
[ ! -s "$ambiguous_poll_file" ] || fail "a parked blocked migration emitted a repeated result"
assert_no_curl "a parked blocked migration called Telegram from a guessed offset"
kill "$ambiguous_pid" 2>/dev/null || true
wait "$ambiguous_pid" 2>/dev/null || true
assert_equal "$(db_query "$H_AMBIGUOUS" "SELECT committed_offset FROM meta")" 0 \
  "a parked blocked migration guessed an offset"
pass "ambiguous migration preserves evidence, guesses nothing, and parks silently after acknowledgement"

# --- operator-acknowledged migration resolution -----------------------------
H_RESOLVE="$TMP_ROOT/migrate-resolve"
RESOLVE_ENV="$TMP_ROOT/migrate-resolve.env"
new_home "$H_RESOLVE"
write_env_file "$RESOLVE_ENV" "$TOKEN"
printf '0\n' > "$H_RESOLVE/state/.telegram-offset"
mkdir -p "$H_RESOLVE/state/telegram-inbox"
for resolution_id in 3101 3102 3103 3104; do
  printf '{"update_id":%s,"date":1,"chat_id":555,"text":"historical"}\n' "$resolution_id" \
    > "$H_RESOLVE/state/telegram-inbox/$resolution_id.json"
done
resolution_migrate=0
FM_HOME="$H_RESOLVE" FM_TELEGRAM_ENV_FILE="$RESOLVE_ENV" "$ADAPTER" migrate >/dev/null 2>&1 \
  || resolution_migrate=$?
[ "$resolution_migrate" -ne 0 ] || fail "resolution fixture did not create a blocked migration"
resolution_doctor=$(FM_HOME="$H_RESOLVE" "$ADAPTER" doctor)
resolution_fingerprint=$(printf '%s\n' "$resolution_doctor" | sed -n 's/^migration_fingerprint=//p')
resolution_manifest=$(printf '%s\n' "$resolution_doctor" | sed -n 's/^migration_resolution_manifest_sha256=//p')
assert_contains "$resolution_doctor" "migration_resolution=available" \
  "doctor did not expose non-secret resolution evidence"
assert_equal "$(printf '%s\n' "$resolution_doctor" | grep -c '^migration_resolution_blocker\.')" 4 \
  "doctor did not derive all four resolution blockers"
resolution_args=()
while IFS= read -r resolution_line; do
  resolution_path=$(printf '%s' "$resolution_line" | cut -d= -f2 | cut -d' ' -f1)
  resolution_digest=$(printf '%s' "$resolution_line" | sed -n 's/.* sha256=\([^ ]*\).*/\1/p')
  resolution_args+=(--acknowledge-delivered "$resolution_path=sha256:$resolution_digest")
done < <(printf '%s\n' "$resolution_doctor" | grep '^migration_resolution_blocker\.')
wrong_resolution_status=0
FM_HOME="$H_RESOLVE" "$ADAPTER" resolve-migration \
  --blocked-fingerprint "$resolution_fingerprint" \
  --archive-manifest-sha256 "$resolution_manifest" \
  --acknowledge-delivered "telegram-inbox/3101.json=sha256:$(printf '0%.0s' {1..64})" \
  "${resolution_args[@]:2}" >/dev/null 2>&1 || wrong_resolution_status=$?
[ "$wrong_resolution_status" -ne 0 ] || fail "a mismatched acknowledgement was accepted"
assert_equal "$(db_query "$H_RESOLVE" "SELECT migration_status FROM meta")" blocked \
  "a refused resolution mutated migration status"
resolution_archive_rel=$(db_query "$H_RESOLVE" "SELECT migration_archive FROM meta")
resolution_archive="$H_RESOLVE/state/$resolution_archive_rel"
resolution_manifest_before=$(sha256sum "$resolution_archive/manifest.json" | cut -d' ' -f1)
resolution_out=$(FM_HOME="$H_RESOLVE" "$ADAPTER" resolve-migration \
  --blocked-fingerprint "$resolution_fingerprint" \
  --archive-manifest-sha256 "$resolution_manifest" "${resolution_args[@]}")
assert_contains "$resolution_out" "resolved: migration fingerprint=" \
  "the complete resolution did not commit"
assert_equal "$(db_query "$H_RESOLVE" "SELECT migration_status FROM meta")" complete \
  "resolution did not complete migration"
assert_equal "$(db_query "$H_RESOLVE" "SELECT committed_offset FROM meta")" 0 \
  "resolution advanced offset from an acknowledged update id"
assert_equal "$(db_query "$H_RESOLVE" "SELECT count(*) FROM migration_resolution_payloads")" 4 \
  "resolution did not persist every acknowledgement"
assert_equal "$(db_query "$H_RESOLVE" "SELECT count(*) FROM messages WHERE payload IS NULL")" 4 \
  "resolution did not create one tombstone per unique update"
assert_equal "$(db_query "$H_RESOLVE" "SELECT count(*) FROM notices WHERE acknowledged_at IS NULL")" 0 \
  "resolution left the migration notice pending"
assert_equal "$(sha256sum "$resolution_archive/manifest.json" | cut -d' ' -f1)" "$resolution_manifest_before" \
  "resolution changed the sealed archive manifest"
resolution_after=$(FM_HOME="$H_RESOLVE" "$ADAPTER" doctor)
assert_contains "$resolution_after" "migration_resolution=operator-acknowledged-delivery" \
  "doctor did not prove the committed resolution"
assert_contains "$resolution_after" "migration_resolution_payload_count=4" \
  "doctor did not report all committed proof rows"
resolution_retry=$(FM_HOME="$H_RESOLVE" "$ADAPTER" resolve-migration \
  --blocked-fingerprint "$resolution_fingerprint" \
  --archive-manifest-sha256 "$resolution_manifest" "${resolution_args[@]}")
assert_contains "$resolution_retry" "already-resolved:" \
  "an exact resolution retry was not idempotent"
changed_resolution_status=0
FM_HOME="$H_RESOLVE" "$ADAPTER" resolve-migration \
  --blocked-fingerprint "$resolution_fingerprint" \
  --archive-manifest-sha256 "$resolution_manifest" \
  --acknowledge-delivered "telegram-inbox/3101.json=sha256:$(printf 'f%.0s' {1..64})" \
  "${resolution_args[@]:2}" >/dev/null 2>&1 || changed_resolution_status=$?
[ "$changed_resolution_status" -ne 0 ] || fail "a changed resolution retry was accepted"
fixture resolution-replay \
  '{"ok":true,"result":[{"update_id":3101,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"historical"}}]}'
clear_curl_calls
resolution_replay=$(poll_once "$H_RESOLVE" "$RESOLVE_ENV" "$FIXTURES/resolution-replay.json") || true
[ -z "$resolution_replay" ] || fail "an acknowledged historical replay produced a message result"
assert_equal "$(db_query "$H_RESOLVE" "SELECT count(*) FROM notices WHERE kind = 'message'")" 0 \
  "an acknowledged historical replay created a message notice"
fixture resolution-new-message \
  '{"ok":true,"result":[{"update_id":5001,"message":{"date":9,"chat":{"id":555},"from":{"id":909},"text":"post resolution"}}]}'
clear_curl_calls
resolution_new=$(poll_once "$H_RESOLVE" "$RESOLVE_ENV" "$FIXTURES/resolution-new-message.json")
assert_contains "$resolution_new" "message: 1" \
  "a resolved channel did not deliver a genuinely new captain message"
assert_equal "$(db_query "$H_RESOLVE" "SELECT count(*) FROM notices WHERE acknowledged_at IS NULL")" 1 \
  "a resolved channel did not publish one pending notice for the new message"
ack_result "$H_RESOLVE" "$RESOLVE_ENV" "$resolution_new" >/dev/null \
  || fail "a resolved channel could not acknowledge a new captain message"
assert_equal "$(db_query "$H_RESOLVE" "SELECT count(*) FROM notices WHERE acknowledged_at IS NULL")" 0 \
  "the new-message notice stayed pending after acknowledgement"
assert_equal "$(db_query "$H_RESOLVE" "SELECT committed_offset FROM meta")" 5002 \
  "a resolved channel did not advance its offset past the new message"
assert_contains "$(FM_HOME="$H_RESOLVE" "$ADAPTER" doctor)" "integrity=ok" \
  "ordinary traffic after resolution invalidated the store"
resolution_after_new=$(poll_once "$H_RESOLVE" "$RESOLVE_ENV" "$FIXTURES/empty.json") || true
assert_equal "$resolution_after_new" "" "a resolved channel stopped polling after ordinary traffic"
pass "a resolved channel keeps delivering and acknowledging ordinary captain traffic"

pass "resolution proves exact archived payloads, commits tombstones atomically, and retries idempotently"

derive_resolution_args() {
  local home=$1 line path digest
  RESOLUTION_DOCTOR=$(FM_HOME="$home" "$ADAPTER" doctor)
  RESOLUTION_FINGERPRINT=$(printf '%s\n' "$RESOLUTION_DOCTOR" \
    | sed -n 's/^migration_fingerprint=//p')
  RESOLUTION_MANIFEST=$(printf '%s\n' "$RESOLUTION_DOCTOR" \
    | sed -n 's/^migration_resolution_manifest_sha256=//p')
  RESOLUTION_ARGS=()
  while IFS= read -r line; do
    path=$(printf '%s' "$line" | cut -d= -f2 | cut -d' ' -f1)
    digest=$(printf '%s' "$line" | sed -n 's/.* sha256=\([^ ]*\).*/\1/p')
    RESOLUTION_ARGS+=(--acknowledge-delivered "$path=sha256:$digest")
  done < <(printf '%s\n' "$RESOLUTION_DOCTOR" | grep '^migration_resolution_blocker\.')
}

blocked_migration_home() {
  local home=$1 env_file=$2 status=0
  FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate >/dev/null 2>&1 \
    || status=$?
  [ "$status" -ne 0 ] || fail "$home did not create a blocked migration"
}

seed_resolution_home() {
  local home=$1 env_file=$2 id
  new_home "$home"
  write_env_file "$env_file" "$TOKEN"
  printf '0\n' > "$home/state/.telegram-offset"
  mkdir -p "$home/state/telegram-inbox"
  for id in 3101 3102; do
    printf '{"update_id":%s,"date":1,"chat_id":555,"text":"historical"}\n' "$id" \
      > "$home/state/telegram-inbox/$id.json"
  done
  blocked_migration_home "$home" "$env_file"
  derive_resolution_args "$home"
  [ "${#RESOLUTION_ARGS[@]}" -eq 4 ] \
    || fail "resolution crash fixture did not derive both blockers"
}

run_resolution() {
  local home=$1
  FM_HOME="$home" "$ADAPTER" resolve-migration \
    --blocked-fingerprint "$RESOLUTION_FINGERPRINT" \
    --archive-manifest-sha256 "$RESOLUTION_MANIFEST" "${RESOLUTION_ARGS[@]}"
}

assert_resolution_committed() {
  local home=$1 case_name=$2
  assert_equal "$(db_query "$home" "SELECT migration_status FROM meta")" complete \
    "$case_name did not converge to a resolved cutover"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM migration_resolution_payloads")" 2 \
    "$case_name did not converge to one proof row per blocker"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM messages WHERE payload IS NULL")" 2 \
    "$case_name did not converge to one tombstone per blocker"
  assert_equal "$(db_query "$home" "SELECT count(*) FROM notices WHERE acknowledged_at IS NULL")" 0 \
    "$case_name left the migration notice pending"
  assert_equal "$(db_query "$home" "SELECT committed_offset FROM meta")" 0 \
    "$case_name advanced the offset from an acknowledged update id"
  assert_contains "$(FM_HOME="$home" "$ADAPTER" doctor)" \
    "migration_resolution=operator-acknowledged-delivery" \
    "$case_name did not converge to a provable resolution"
}

resolution_crash_case() {
  local point=$1 committed=$2
  local home="$TMP_ROOT/resolve-crash-$point" env_file="$TMP_ROOT/resolve-crash-$point.env"
  seed_resolution_home "$home" "$env_file"
  local archive_rel archive manifest_before status=0 recovered
  archive_rel=$(db_query "$home" "SELECT migration_archive FROM meta")
  archive="$home/state/$archive_rel"
  manifest_before=$(sha256sum "$archive/manifest.json" | cut -d' ' -f1)
  FM_TELEGRAM_FAILPOINT="$point" run_resolution "$home" >/dev/null 2>&1 || status=$?
  assert_equal "$status" 91 "$point did not stop at its resolution crash boundary"
  assert_contains "$(FM_HOME="$home" "$ADAPTER" doctor)" "integrity=ok" \
    "$point left an invalid database behind"
  if [ "$committed" = uncommitted ]; then
    assert_equal "$(db_query "$home" "SELECT migration_status FROM meta")" blocked \
      "$point published a resolved cutover past its transaction boundary"
    assert_equal "$(db_query "$home" "SELECT count(*) FROM sqlite_master WHERE name LIKE 'migration_resolution%'")" 0 \
      "$point exposed partial resolution proof tables"
    assert_equal "$(db_query "$home" "SELECT count(*) FROM messages")" 0 \
      "$point exposed a partial tombstone"
    assert_equal "$(db_query "$home" "SELECT count(*) FROM notices WHERE acknowledged_at IS NULL")" 1 \
      "$point acknowledged the migration notice past its transaction boundary"
    recovered=$(run_resolution "$home")
    assert_contains "$recovered" "resolved: migration fingerprint=" \
      "$point could not be recovered by rerunning resolve-migration"
  else
    recovered=$(run_resolution "$home")
    assert_contains "$recovered" "already-resolved:" \
      "$point did not expose its durable resolution to an exact retry"
  fi
  assert_resolution_committed "$home" "$point"
  assert_equal "$(sha256sum "$archive/manifest.json" | cut -d' ' -f1)" "$manifest_before" \
    "$point changed the sealed archive manifest"
  assert_present "$home/state/telegram-inbox/3101.json" \
    "$point destroyed the preserved legacy bytes"
}

resolution_crash_case after_resolution_ddl uncommitted
resolution_crash_case after_resolution_ack uncommitted
resolution_crash_case after_resolution_tombstone uncommitted
resolution_crash_case after_resolution_plan uncommitted
resolution_crash_case after_resolution_meta uncommitted
resolution_crash_case before_resolution_commit uncommitted
resolution_crash_case after_resolution_commit committed
pass "a crash at any resolution boundary leaves the store valid and reruns to one complete resolution"

H_DRIFT="$TMP_ROOT/resolve-evidence-drift"
DRIFT_ENV="$TMP_ROOT/resolve-evidence-drift.env"
seed_resolution_home "$H_DRIFT" "$DRIFT_ENV"
run_resolution "$H_DRIFT" >/dev/null || fail "the drift fixture could not be resolved"
rm -f "$H_DRIFT/state/telegram-inbox/3101.json"
drift_status=0
drift_doctor=$(FM_HOME="$H_DRIFT" "$ADAPTER" doctor) || drift_status=$?
assert_equal "$drift_status" 0 "doctor refused to report on drifted resolution evidence"
assert_contains "$drift_doctor" "migration_resolution=operator-acknowledged-delivery" \
  "doctor dropped the committed resolution proof when preserved copies drifted"
assert_contains "$drift_doctor" "migration_resolution_evidence=unavailable" \
  "doctor did not report that the preserved legacy evidence is unavailable"
assert_contains "$drift_doctor" "migration_resolution_detail=" \
  "doctor reported unavailable evidence without a bounded reason"
assert_contains "$drift_doctor" "pending_notices=0" \
  "doctor stopped before its notice report"
assert_contains "$drift_doctor" "journal_mode=" \
  "doctor stopped before its durability report"
case "$drift_doctor" in
  *"$H_DRIFT"*) fail "doctor leaked an absolute home path in its unavailable reason" ;;
esac
drift_resolve_status=0
run_resolution "$H_DRIFT" >/dev/null 2>&1 || drift_resolve_status=$?
[ "$drift_resolve_status" -ne 0 ] \
  || fail "resolve-migration accepted drifted preserved legacy evidence"
pass "doctor still reports the committed resolution when preserved legacy copies drift"

fixture resolution-resume \
  '{"ok":true,"result":[{"update_id":6001,"message":{"date":9,"chat":{"id":555},"from":{"id":909},"text":"resumed"}}]}'
H_RESUME="$TMP_ROOT/resolve-parked-resume"
RESUME_ENV="$TMP_ROOT/resolve-parked-resume.env"
seed_resolution_home "$H_RESUME" "$RESUME_ENV"
resume_notice=$(poll_once "$H_RESUME" "$RESUME_ENV" "$FIXTURES/empty.json")
assert_contains "$resume_notice" "blocked: migration-blocked" \
  "the resume fixture did not announce its blocked migration"
ack_result "$H_RESUME" "$RESUME_ENV" "$resume_notice" >/dev/null \
  || fail "the resume fixture could not acknowledge its blocked-migration notice"
resume_poll_file="$TMP_ROOT/resolve-parked-resume.out"
clear_curl_calls
CURL_STUB_BODY="$FIXTURES/resolution-resume.json" CURL_STUB_HTTP=200 \
  FM_TELEGRAM_POLL_TIMEOUT=1 FM_HOME="$H_RESUME" FM_TELEGRAM_ENV_FILE="$RESUME_ENV" \
  "$ADAPTER" poll >"$resume_poll_file" 2>&1 &
resume_pid=$!
sleep 3
kill -0 "$resume_pid" 2>/dev/null \
  || fail "the acknowledged blocked migration did not park its poll before resolution"
[ ! -s "$resume_poll_file" ] || fail "a parked blocked migration emitted a result before resolution"
assert_no_curl "a parked blocked migration called Telegram before resolution"
run_resolution "$H_RESUME" >/dev/null || fail "the parked home could not be resolved"
resume_deadline=$((SECONDS + 30))
while kill -0 "$resume_pid" 2>/dev/null; do
  if [ "$SECONDS" -ge "$resume_deadline" ]; then
    kill "$resume_pid" 2>/dev/null || true
    fail "the parked poll never resumed after the resolution transaction became visible"
  fi
  sleep 0.2
done
resume_status=0
wait "$resume_pid" || resume_status=$?
assert_equal "$resume_status" 0 "the resumed poll did not exit with a delivered result"
resume_out=$(cat "$resume_poll_file")
assert_contains "$resume_out" "message: 1" \
  "the parked poll did not resume normal polling after resolution"
assert_equal "$(printf '%s\n' "$resume_out" | grep -c '^message: ')" 1 \
  "the resumed poll emitted more than one result"
[ -s "$CURL_CALLS" ] || fail "the resumed poll delivered a message without calling Telegram"
assert_equal "$(db_query "$H_RESUME" "SELECT count(*) FROM notices WHERE acknowledged_at IS NULL")" 1 \
  "the resumed poll did not publish exactly one pending notice"
ack_result "$H_RESUME" "$RESUME_ENV" "$resume_out" >/dev/null \
  || fail "the resumed poll's result could not be acknowledged"
assert_equal "$(db_query "$H_RESUME" "SELECT committed_offset FROM meta")" 6002 \
  "the resumed poll did not advance the offset past its delivered message"
assert_equal "$(db_query "$H_RESUME" "SELECT migration_status FROM meta")" complete \
  "the resumed parked poll did not observe the committed resolution"
assert_equal "$(db_query "$H_RESUME" "SELECT count(*) FROM migration_resolution_payloads")" 2 \
  "the resumed parked poll did not keep one proof row per blocker"
pass "a parked blocked poll resumes normal polling exactly once after the resolution commits"

H_MIXED="$TMP_ROOT/resolve-mixed-payloads"
MIXED_ENV="$TMP_ROOT/resolve-mixed-payloads.env"
new_home "$H_MIXED"
write_env_file "$MIXED_ENV" "$TOKEN"
printf '0\n' > "$H_MIXED/state/.telegram-offset"
mkdir -p "$H_MIXED/state/telegram-inbox" "$H_MIXED/state/.telegram-delivery-receipts"
printf '{"update_id":3201,"date":1,"chat_id":555,"text":"identity gap"}\n' \
  > "$H_MIXED/state/telegram-inbox/3201.json"
printf '{"update_id":3202,"date":1,"chat_id":555,"from_id":909,"text":"coherent receipt"}\n' \
  > "$H_MIXED/state/.telegram-delivery-receipts/3202.json"
blocked_migration_home "$H_MIXED" "$MIXED_ENV"
derive_resolution_args "$H_MIXED"
assert_contains "$RESOLUTION_DOCTOR" "migration_resolution=available" \
  "a coherent legacy payload beside the blocker made the guarded exit unavailable"
assert_equal "$(printf '%s\n' "$RESOLUTION_DOCTOR" | grep -c '^migration_resolution_blocker\.')" 2 \
  "doctor did not derive every undelivered legacy payload as a blocker"
mixed_out=$(run_resolution "$H_MIXED")
assert_contains "$mixed_out" "acknowledged-delivered=2" \
  "the mixed archive did not acknowledge both undelivered payloads"
assert_equal "$(db_query "$H_MIXED" "SELECT migration_status FROM meta")" complete \
  "the mixed archive did not resolve"
assert_equal "$(db_query "$H_MIXED" "SELECT count(*) FROM migration_resolution_payloads")" 2 \
  "the mixed archive did not persist one proof row per undelivered payload"
assert_equal "$(db_query "$H_MIXED" "SELECT count(*) FROM messages WHERE payload IS NULL")" 2 \
  "the mixed archive did not tombstone every acknowledged payload"
assert_equal "$(db_query "$H_MIXED" "SELECT count(*) FROM messages WHERE payload IS NOT NULL")" 0 \
  "the resolution delivered a historical payload"
assert_equal "$(db_query "$H_MIXED" "SELECT count(*) FROM notices WHERE kind = 'message'")" 0 \
  "the resolution announced a historical payload"
assert_equal "$(db_query "$H_MIXED" "SELECT committed_offset FROM meta")" 0 \
  "the resolution advanced the offset from an acknowledged update id"
pass "a coherent legacy payload beside an identity-gap blocker is acknowledged, never delivered"

H_STALE="$TMP_ROOT/resolve-stale-receipt"
STALE_ENV="$TMP_ROOT/resolve-stale-receipt.env"
new_home "$H_STALE"
write_env_file "$STALE_ENV" "$TOKEN"
printf '0\n' > "$H_STALE/state/.telegram-offset"
mkdir -p "$H_STALE/state/telegram-inbox/handled" "$H_STALE/state/.telegram-delivery-receipts"
printf '{"update_id":3301,"date":1,"chat_id":555,"text":"identity gap"}\n' \
  > "$H_STALE/state/telegram-inbox/3301.json"
printf '{"update_id":3302,"date":1,"chat_id":555,"from_id":909,"text":"already delivered"}\n' \
  > "$H_STALE/state/telegram-inbox/handled/3302.json"
printf '{"update_id":3302,"date":1,"chat_id":555,"from_id":909,"text":"already delivered"}\n' \
  > "$H_STALE/state/.telegram-delivery-receipts/3302.json"
blocked_migration_home "$H_STALE" "$STALE_ENV"
derive_resolution_args "$H_STALE"
assert_contains "$RESOLUTION_DOCTOR" "migration_resolution=available" \
  "a stale receipt for an already-handled update made the guarded exit unavailable"
assert_equal "$(printf '%s\n' "$RESOLUTION_DOCTOR" | grep -c '^migration_resolution_blocker\.')" 1 \
  "doctor derived a non-blocking stale receipt as a blocker"
case "$RESOLUTION_DOCTOR" in
  *".telegram-delivery-receipts/3302.json"*)
    fail "doctor demanded an acknowledgement for an already-handled update" ;;
esac
stale_extra_status=0
FM_HOME="$H_STALE" "$ADAPTER" resolve-migration \
  --blocked-fingerprint "$RESOLUTION_FINGERPRINT" \
  --archive-manifest-sha256 "$RESOLUTION_MANIFEST" "${RESOLUTION_ARGS[@]}" \
  --acknowledge-delivered ".telegram-delivery-receipts/3302.json=sha256:$(sha256sum "$H_STALE/state/.telegram-delivery-receipts/3302.json" | cut -d' ' -f1)" \
  >/dev/null 2>&1 || stale_extra_status=$?
[ "$stale_extra_status" -ne 0 ] \
  || fail "an acknowledgement for a non-blocking stale receipt was accepted"
assert_equal "$(db_query "$H_STALE" "SELECT migration_status FROM meta")" blocked \
  "a refused extra acknowledgement mutated migration status"
stale_out=$(run_resolution "$H_STALE")
assert_contains "$stale_out" "acknowledged-delivered=1" \
  "the stale-receipt archive acknowledged more than its one blocker"
assert_equal "$(db_query "$H_STALE" "SELECT count(*) FROM migration_resolution_payloads")" 1 \
  "the stale-receipt archive persisted a proof row for a non-blocking payload"
assert_equal "$(db_query "$H_STALE" "SELECT count(*) FROM messages WHERE payload IS NULL")" 2 \
  "the stale-receipt archive lost the already-handled dedup tombstone"
assert_equal "$(db_query "$H_STALE" "SELECT count(*) FROM messages WHERE update_id = 3302")" 1 \
  "the already-handled update did not migrate as a dedup tombstone"
assert_equal "$(db_query "$H_STALE" "SELECT committed_offset FROM meta")" 0 \
  "the stale-receipt resolution advanced the offset from an acknowledged update id"
pass "a stale receipt for an already-handled update is non-blocking and needs no acknowledgement"




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
URI_ENV="$TMP_ROOT/uri-metachars.env"
URI_HOMES=(
  "$TMP_ROOT/uri%25pct#frag?query"
  "/$TMP_ROOT/uri-double-slash-home"
)
for H_URI in "${URI_HOMES[@]}"; do
  case "$H_URI" in
    //*) uri_shape="a leading // authority" ;;
    *)   uri_shape="URI metacharacters" ;;
  esac
  arm_home "$H_URI" "$URI_ENV"
  uri_out=$(poll_once "$H_URI" "$URI_ENV" "$FIXTURES/one-text.json")
  assert_contains "$uri_out" "message:" \
    "a state path with $uri_shape could not be reopened after creation"
  assert_equal "$(db_query "$H_URI" "SELECT committed_offset FROM meta")" 1002 \
    "a state path with $uri_shape lost its committed offset"
  write_result "$uri_out"
  assert_contains \
    "$(FM_HOME="$H_URI" FM_TELEGRAM_ENV_FILE="$URI_ENV" "$ADAPTER" messages "$RESULT_FILE")" \
    "ahoy from the captain" \
    "a state path with $uri_shape hid the captain payload"
  assert_contains "$(FM_HOME="$H_URI" "$ADAPTER" doctor)" "integrity=ok" \
    "doctor could not read a state path with $uri_shape"
done
pass "creation and reopen agree for state paths containing URI metacharacters or a // prefix"

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
assert_present "$H_NO_ENGINE/state/procevent/telegram.source" \
  "the engine-unavailable fixture was not armed before the cutover attempt"
NO_ENGINE_BIN="$TMP_ROOT/bin-without-engine"
cp -R "$ROOT/bin" "$NO_ENGINE_BIN"
rm -f "$NO_ENGINE_BIN/fm_procevent_telegram_state.py"
NO_ENGINE_ADAPTER="$NO_ENGINE_BIN/fm-procevent-telegram.sh"
no_engine_migrate_status=0
no_engine_migrate_err="$TMP_ROOT/engine-unavailable.migrate.err"
no_engine_migrate=$(FM_HOME="$H_NO_ENGINE" FM_TELEGRAM_ENV_FILE="$NO_ENGINE_ENV" \
  "$NO_ENGINE_ADAPTER" migrate 2>"$no_engine_migrate_err") \
  || no_engine_migrate_status=$?
[ "$no_engine_migrate_status" -ne 0 ] || fail "a missing engine reported migration success"
assert_present "$H_NO_ENGINE/state/procevent/telegram.source" \
  "a cutover refused for a missing engine still deregistered the captain's channel"
assert_absent "$H_NO_ENGINE/state/telegram-migration-archive" \
  "a cutover refused for a missing engine still archived legacy state"
assert_equal "$no_engine_migrate" "" "a refused cutover printed a result on stdout"
assert_contains "$(cat "$no_engine_migrate_err")" "Telegram state engine is unavailable" \
  "a missing engine refused the cutover without an actionable message"
pass "a missing engine still yields a blocked result the handler can classify and dispose, and refuses the cutover before deregistering the channel"

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

# --- bound outbound reply transaction ---------------------------------------
reply_once() {
  local home=$1 env_file=$2 response=$3 http=${4:-200}
  local echo_text=
  [ "$response" = "$FIXTURES/reply-success.json" ] && echo_text=1
  CURL_STUB_SEND_BODY="$response" CURL_STUB_SEND_ECHO_TEXT="$echo_text" CURL_STUB_HTTP="$http" \
    FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" \
    "$ADAPTER" reply 1101
}

seed_receipts_only_home() {
  local home=$1 env_file=$2
  new_home "$home"
  write_env_file "$env_file" "$TOKEN"
  printf '3000\n' > "$home/state/.telegram-offset"
  mkdir -p "$home/state/telegram-inbox/handled"
  mkdir -p "$home/state/.telegram-delivery-receipts"
  printf '{"update_id":3302,"date":5,"chat_id":555,"from_id":909,"text":"legacy receipt"}\n' \
    > "$home/state/.telegram-delivery-receipts/3302.json"
  FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" "$ADAPTER" migrate >/dev/null
  local announced
  announced=$(poll_once "$home" "$env_file" "$FIXTURES/empty.json")
  assert_contains "$announced" "message: 1" "the migrated receipt did not announce"
  ack_result "$home" "$env_file" "$announced" >/dev/null
}

for reply_credential_case in missing bad-mode incomplete; do
  credential_home="$TMP_ROOT/reply-credential-$reply_credential_case"
  credential_env="$TMP_ROOT/reply-credential-$reply_credential_case.env"
  arm_home "$credential_home" "$credential_env"
  poll_once "$credential_home" "$credential_env" "$FIXTURES/replyable-text.json" >/dev/null
  case "$reply_credential_case" in
    missing)
      rm -f "$credential_env"
      ;;
    bad-mode)
      chmod 644 "$credential_env"
      ;;
    incomplete)
      printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=555\n' "$TOKEN" > "$credential_env"
      chmod 600 "$credential_env"
      ;;
  esac
  clear_curl_calls
  credential_reply_status=0
  credential_reply_out=$(printf 'private credential reply\n' | \
    FM_HOME="$credential_home" FM_TELEGRAM_ENV_FILE="$credential_env" \
    "$ADAPTER" reply 1101 2>&1) || credential_reply_status=$?
  [ "$credential_reply_status" -ne 0 ] \
    || fail "reply accepted $reply_credential_case credentials"
  assert_contains "$credential_reply_out" \
    "repair the configured credential file, then retry with: reply 1101" \
    "$reply_credential_case credential refusal did not provide a repair and retry action"
  case "$credential_reply_out" in
    *"local Telegram state failure"*)
      fail "$reply_credential_case credential refusal looked like an internal state failure"
      ;;
    *"private credential reply"*|*"$TOKEN"*)
      fail "$reply_credential_case credential refusal leaked private input"
      ;;
  esac
  assert_no_curl "$reply_credential_case credentials allowed a Telegram request"
  assert_equal "$(db_query "$credential_home" "SELECT count(*) FROM replies")" 0 \
    "$reply_credential_case credentials created a reply reservation"
done
pass "reply credential failures provide sanitized repair and retry guidance"

for reply_state_case in missing-db corrupt-header database-mode; do
  reply_state_home="$TMP_ROOT/reply-state-$reply_state_case"
  reply_state_env="$TMP_ROOT/reply-state-$reply_state_case.env"
  arm_home "$reply_state_home" "$reply_state_env"
  poll_once "$reply_state_home" "$reply_state_env" "$FIXTURES/replyable-text.json" >/dev/null
  case "$reply_state_case" in
    missing-db)
      rm -f "$reply_state_home/state/telegram/channel.db"
      ;;
    corrupt-header)
      printf 'not a sqlite database\n' > "$reply_state_home/state/telegram/channel.db"
      chmod 600 "$reply_state_home/state/telegram/channel.db"
      ;;
    database-mode)
      chmod 644 "$reply_state_home/state/telegram/channel.db"
      ;;
  esac
  clear_curl_calls
  reply_state_status=0
  reply_state_out=$(printf 'private state reply\n' | \
    FM_HOME="$reply_state_home" FM_TELEGRAM_ENV_FILE="$reply_state_env" \
    "$ADAPTER" reply 1101 2>&1) || reply_state_status=$?
  [ "$reply_state_status" -ne 0 ] || fail "reply accepted $reply_state_case local state"
  assert_contains "$reply_state_out" "Telegram reply state is unavailable" \
    "$reply_state_case did not identify unavailable reply state"
  assert_contains "$reply_state_out" "doctor" \
    "$reply_state_case did not direct the operator to inspect durable state"
  assert_contains "$reply_state_out" "before deciding whether retry is safe" \
    "$reply_state_case invited a retry before durable-state inspection"
  case "$reply_state_out" in
    *"local Telegram state failure"*|*"private state reply"*|*"$TOKEN"*)
      fail "$reply_state_case reply failure produced opaque or private output"
      ;;
  esac
  assert_no_curl "$reply_state_case local state allowed a Telegram request"
done
pass "reply state failures require doctor inspection before any retry decision"

H_LEGACY_REDELIVERY="$TMP_ROOT/legacy-redelivery"
LEGACY_REDELIVERY_ENV="$TMP_ROOT/legacy-redelivery.env"
seed_receipts_only_home "$H_LEGACY_REDELIVERY" "$LEGACY_REDELIVERY_ENV"
assert_equal "$(db_query "$H_LEGACY_REDELIVERY" "SELECT committed_offset FROM meta")" 3000 \
  "a receipts-only migration advanced the offset past the imported update"
redelivery_out=$(poll_once "$H_LEGACY_REDELIVERY" "$LEGACY_REDELIVERY_ENV" \
  "$FIXTURES/legacy-redelivery.json" 2>&1) || true
assert_equal "$redelivery_out" "" \
  "redelivering a migrated legacy update did not pass silently"
assert_equal "$(db_query "$H_LEGACY_REDELIVERY" "SELECT committed_offset FROM meta")" 3303 \
  "the redelivered legacy update did not let the offset advance"
assert_equal "$(db_query "$H_LEGACY_REDELIVERY" "SELECT count(*) FROM messages")" 1 \
  "the redelivered legacy update was stored twice"
redelivery_reply_status=0
redelivery_reply=$(printf 'no identity\n' | FM_HOME="$H_LEGACY_REDELIVERY" \
  FM_TELEGRAM_ENV_FILE="$LEGACY_REDELIVERY_ENV" "$ADAPTER" reply 3302 2>&1) \
  || redelivery_reply_status=$?
[ "$redelivery_reply_status" -ne 0 ] || fail "a legacy record silently gained reply identity"
assert_contains "$redelivery_reply" "lacks strict reply identity evidence" \
  "the legacy record's reply refusal changed"

H_LEGACY_CONFLICT="$TMP_ROOT/legacy-conflict"
LEGACY_CONFLICT_ENV="$TMP_ROOT/legacy-conflict.env"
seed_receipts_only_home "$H_LEGACY_CONFLICT" "$LEGACY_CONFLICT_ENV"
conflict_out=$(poll_once "$H_LEGACY_CONFLICT" "$LEGACY_CONFLICT_ENV" \
  "$FIXTURES/legacy-redelivery-changed.json" 2>&1)
assert_contains "$conflict_out" "blocked: local-state fingerprint=" \
  "redelivered content that actually changed was not refused"
assert_equal "$(db_query "$H_LEGACY_CONFLICT" "SELECT committed_offset FROM meta")" 3000 \
  "a conflicting redelivery advanced the committed offset"
pass "a migrated legacy record tolerates its own redelivery but still refuses changed content"

H_REPLY="$TMP_ROOT/reply"
REPLY_ENV="$TMP_ROOT/reply.env"
REPLY_REQUEST="$TMP_ROOT/reply.request"
arm_home "$H_REPLY" "$REPLY_ENV"
poll_once "$H_REPLY" "$REPLY_ENV" "$FIXTURES/replyable-text.json" >/dev/null
clear_curl_calls
reply_out=$(printf 'captain reply\n' | CURL_STUB_SEND_CAPTURE="$REPLY_REQUEST" reply_once \
  "$H_REPLY" "$REPLY_ENV" "$FIXTURES/reply-success.json")
assert_contains "$reply_out" "sent: update_id=1101 telegram_message_id=8801" \
  "a validated Telegram reply was not committed"
assert_grep 'chat_id=555' "$REPLY_REQUEST" "reply did not target the configured captain chat"
assert_grep 'reply_parameters=%7B%22message_id%22%3A771%7D' "$REPLY_REQUEST" \
  "reply did not target the accepted inbound message"
assert_grep 'text=captain+reply%0A' "$REPLY_REQUEST" "reply request was not sent through stdin-bound data"
case "$reply_out" in *reply*) fail "reply output leaked reply text" ;; esac
assert_equal "$(db_query "$H_REPLY" "SELECT state FROM replies WHERE update_id=1101")" sent \
  "successful reply did not persist sent state"
clear_curl_calls
repeat_reply=$(printf 'captain reply\n' | reply_once "$H_REPLY" "$REPLY_ENV" "$FIXTURES/reply-success.json")
assert_contains "$repeat_reply" "already-sent: update_id=1101" \
  "a repeated inbound reply was not idempotent"
assert_no_curl "a sent reply was sent again"
assert_present "$H_REPLY/state/procevent/telegram.source" \
  "reply handling retired the Telegram source"
reply_doctor=$(FM_HOME="$H_REPLY" "$ADAPTER" doctor)
assert_contains "$reply_doctor" "reply_count=1" "doctor omitted the reply total"
assert_contains "$reply_doctor" "reply_sent=1" "doctor did not count the sent reply"
assert_contains "$reply_doctor" "reply_attention_omitted=0" \
  "doctor did not report an empty attention set"
case "$reply_doctor" in *"reply.1101="*) fail "doctor enumerated a sent reply row" ;; esac
pass "a reply is bound to the configured chat and accepted message, and repeats do not resend"

H_REPLY_CURLRC="$TMP_ROOT/reply-curlrc"
REPLY_CURLRC_ENV="$TMP_ROOT/reply-curlrc.env"
REPLY_CURLRC_TRACE="$TMP_ROOT/reply-curlrc.trace"
REPLY_CURLRC_ATTEMPTS="$TMP_ROOT/reply-curlrc.attempts"
arm_home "$H_REPLY_CURLRC" "$REPLY_CURLRC_ENV"
poll_once "$H_REPLY_CURLRC" "$REPLY_CURLRC_ENV" "$FIXTURES/replyable-text.json" >/dev/null
printf 'private answer\n' | CURL_STUB_AMBIENT_TRACE="$REPLY_CURLRC_TRACE" \
  CURL_STUB_SEND_ATTEMPTS="$REPLY_CURLRC_ATTEMPTS" reply_once \
  "$H_REPLY_CURLRC" "$REPLY_CURLRC_ENV" "$FIXTURES/reply-success.json" >/dev/null
assert_absent "$REPLY_CURLRC_TRACE" "ambient curl configuration captured the reply body"
assert_equal "$(wc -l < "$REPLY_CURLRC_ATTEMPTS" | tr -d ' ')" 1 \
  "ambient curl configuration repeated the reply request"
pass "reply delivery disables ambient curl configuration before processing options"

H_REPLY_OLD="$TMP_ROOT/reply-old"
REPLY_OLD_ENV="$TMP_ROOT/reply-old.env"
arm_home "$H_REPLY_OLD" "$REPLY_OLD_ENV"
poll_once "$H_REPLY_OLD" "$REPLY_OLD_ENV" "$FIXTURES/one-text.json" >/dev/null
old_reply_status=0
old_reply_out=$(printf 'not sent\n' | FM_HOME="$H_REPLY_OLD" FM_TELEGRAM_ENV_FILE="$REPLY_OLD_ENV" \
  "$ADAPTER" reply 1001 2>&1) || old_reply_status=$?
[ "$old_reply_status" -ne 0 ] || fail "reply accepted an inbound record without message identity"
assert_contains "$old_reply_out" "lacks strict reply identity evidence" \
  "missing message identity refusal was not actionable"
assert_equal "$(db_query "$H_REPLY_OLD" "SELECT count(*) FROM replies")" 0 \
  "missing message identity created a reply reservation"

arbitrary_status=0
arbitrary_out=$(printf 'bad destination\n' | FM_HOME="$H_REPLY" FM_TELEGRAM_ENV_FILE="$REPLY_ENV" \
  "$ADAPTER" reply --chat-id 999 1101 2>&1) || arbitrary_status=$?
[ "$arbitrary_status" -ne 0 ] || fail "reply accepted a caller-supplied destination"
assert_contains "$arbitrary_out" "Usage:" "arbitrary destination refusal was not actionable"
pass "older inbound records and arbitrary destinations are refused without a network call"

H_REPLY_FAIL="$TMP_ROOT/reply-failure"
REPLY_FAIL_ENV="$TMP_ROOT/reply-failure.env"
arm_home "$H_REPLY_FAIL" "$REPLY_FAIL_ENV"
poll_once "$H_REPLY_FAIL" "$REPLY_FAIL_ENV" "$FIXTURES/replyable-text.json" >/dev/null
api_fail_status=0
api_fail_out=$(printf 'definite failure\n' | CURL_STUB_HTTP=400 reply_once "$H_REPLY_FAIL" "$REPLY_FAIL_ENV" /dev/null 400 2>&1) \
  || api_fail_status=$?
[ "$api_fail_status" -ne 0 ] || fail "definite Telegram refusal reported success"
assert_contains "$api_fail_out" "definitely refused" "definite refusal was not actionable"
assert_equal "$(db_query "$H_REPLY_FAIL" "SELECT state FROM replies WHERE update_id=1101")" failed \
  "definite refusal was not durably failed"
assert_contains "$(FM_HOME="$H_REPLY_FAIL" "$ADAPTER" doctor)" \
  "reply.1101=definitely-failed detail=http-400" "doctor did not report definite failure"

H_REPLY_UNKNOWN="$TMP_ROOT/reply-unknown"
REPLY_UNKNOWN_ENV="$TMP_ROOT/reply-unknown.env"
arm_home "$H_REPLY_UNKNOWN" "$REPLY_UNKNOWN_ENV"
poll_once "$H_REPLY_UNKNOWN" "$REPLY_UNKNOWN_ENV" "$FIXTURES/replyable-text.json" >/dev/null
transport_status=0
transport_out=$(printf 'uncertain transport\n' | CURL_STUB_EXIT=7 reply_once "$H_REPLY_UNKNOWN" "$REPLY_UNKNOWN_ENV" /dev/null 2>&1) \
  || transport_status=$?
[ "$transport_status" -ne 0 ] || fail "transport failure reported success"
assert_contains "$transport_out" "delivery is unknown" "transport failure was not delivery-unknown"
assert_equal "$(db_query "$H_REPLY_UNKNOWN" "SELECT state FROM replies WHERE update_id=1101")" unknown \
  "transport failure was not durably unknown"
retry_status=0
retry_out=$(printf 'uncertain transport\n' | reply_once "$H_REPLY_UNKNOWN" "$REPLY_UNKNOWN_ENV" "$FIXTURES/reply-success.json" 2>&1) \
  || retry_status=$?
[ "$retry_status" -ne 0 ] || fail "delivery-unknown reply was automatically retried"
assert_contains "$retry_out" "automatic retry is refused" \
  "delivery-unknown refusal did not prevent duplicate delivery"
rm -f "$REPLY_UNKNOWN_ENV"
clear_curl_calls
unknown_credential_status=0
unknown_credential_out=$(printf 'uncertain transport\n' | reply_once "$H_REPLY_UNKNOWN" \
  "$REPLY_UNKNOWN_ENV" "$FIXTURES/reply-success.json" 2>&1) || unknown_credential_status=$?
[ "$unknown_credential_status" -ne 0 ] \
  || fail "delivery-unknown reply with unavailable credentials reported success"
assert_contains "$unknown_credential_out" "delivery is unknown" \
  "unavailable credentials hid the durable delivery-unknown state"
assert_contains "$unknown_credential_out" "doctor" \
  "delivery-unknown credential refusal did not point to doctor"
case "$unknown_credential_out" in
  *"repair the configured credential file"*)
    fail "delivery-unknown reply invited an unsafe retry after credential repair"
    ;;
esac
assert_no_curl "delivery-unknown reply with unavailable credentials reached Telegram"
pass "definite refusal and uncertain transport outcomes remain non-sent and non-retryable"

H_REPLY_CRASH="$TMP_ROOT/reply-crash"
REPLY_CRASH_ENV="$TMP_ROOT/reply-crash.env"
arm_home "$H_REPLY_CRASH" "$REPLY_CRASH_ENV"
poll_once "$H_REPLY_CRASH" "$REPLY_CRASH_ENV" "$FIXTURES/replyable-text.json" >/dev/null
crash_status=0
printf 'crash boundary\n' | FM_TELEGRAM_FAILPOINT=after_reply_response reply_once "$H_REPLY_CRASH" "$REPLY_CRASH_ENV" \
  "$FIXTURES/reply-success.json" >/dev/null 2>&1 || crash_status=$?
[ "$crash_status" -ne 0 ] || fail "reply response crash failpoint reported success"
assert_contains "$(FM_HOME="$H_REPLY_CRASH" "$ADAPTER" doctor)" \
  "reply.1101=delivery-unknown" "response crash was not surfaced as unknown"
crash_retry_status=0
crash_retry=$(printf 'crash boundary\n' | reply_once "$H_REPLY_CRASH" "$REPLY_CRASH_ENV" "$FIXTURES/reply-success.json" 2>&1) \
  || crash_retry_status=$?
[ "$crash_retry_status" -ne 0 ] || fail "response crash allowed an automatic duplicate retry"
assert_contains "$crash_retry" "automatic retry is refused" \
  "response crash retry refusal was not actionable"
pass "a crash after the API response cannot falsely become sent or authorize a duplicate"

H_REPLY_FINISH_FAILURE="$TMP_ROOT/reply-finish-failure"
REPLY_FINISH_FAILURE_ENV="$TMP_ROOT/reply-finish-failure.env"
arm_home "$H_REPLY_FINISH_FAILURE" "$REPLY_FINISH_FAILURE_ENV"
poll_once "$H_REPLY_FINISH_FAILURE" "$REPLY_FINISH_FAILURE_ENV" \
  "$FIXTURES/replyable-text.json" >/dev/null
finish_failure_status=0
finish_failure_out=$(printf 'uncommitted success\n' | \
  FM_TELEGRAM_FAILPOINT=before_reply_finish_commit reply_once \
  "$H_REPLY_FINISH_FAILURE" "$REPLY_FINISH_FAILURE_ENV" \
  "$FIXTURES/reply-success.json" 2>&1) || finish_failure_status=$?
[ "$finish_failure_status" -ne 0 ] || fail "an uncommitted send success reported sent"
assert_contains "$finish_failure_out" "delivery is unknown" \
  "an uncommitted send success did not report delivery-unknown"
assert_contains "$finish_failure_out" "automatic retry is refused" \
  "an uncommitted send success permitted an unsafe retry"
assert_contains "$finish_failure_out" "doctor" \
  "an uncommitted send success did not point to doctor"
case "$finish_failure_out" in
  *"local Telegram state failure"*|*"uncommitted success"*)
    fail "an uncommitted send success produced opaque or private output"
    ;;
esac
assert_equal "$(db_query "$H_REPLY_FINISH_FAILURE" \
  "SELECT state, network_started FROM replies WHERE update_id=1101")" "unknown|1" \
  "a failed sent-state commit did not retain delivery-unknown"
clear_curl_calls
finish_failure_retry_status=0
finish_failure_retry=$(printf 'uncommitted success\n' | reply_once \
  "$H_REPLY_FINISH_FAILURE" "$REPLY_FINISH_FAILURE_ENV" \
  "$FIXTURES/reply-success.json" 2>&1) || finish_failure_retry_status=$?
[ "$finish_failure_retry_status" -ne 0 ] \
  || fail "an uncommitted send success allowed a duplicate retry"
assert_contains "$finish_failure_retry" "automatic retry is refused" \
  "the failed sent-state commit was not durably non-retryable"
assert_no_curl "a failed sent-state commit reached Telegram again"
pass "reply commit failures surface durable unknown state and refuse retry"

for reply_boundary in before-reserve before-network after-commit; do
  boundary_home="$TMP_ROOT/reply-$reply_boundary"
  boundary_env="$TMP_ROOT/reply-$reply_boundary.env"
  arm_home "$boundary_home" "$boundary_env"
  poll_once "$boundary_home" "$boundary_env" "$FIXTURES/replyable-text.json" >/dev/null
  boundary_status=0
  case "$reply_boundary" in
    before-reserve)
      printf 'boundary body\n' | FM_TELEGRAM_FAILPOINT=before_reply_reserve reply_once \
        "$boundary_home" "$boundary_env" "$FIXTURES/reply-success.json" >/dev/null 2>&1 || boundary_status=$?
      [ "$boundary_status" -ne 0 ] || fail "before-reserve crash reported success"
      assert_equal "$(db_query "$boundary_home" "SELECT count(*) FROM replies")" 0 \
        "before-reserve crash created a reply"
      ;;
    before-network)
      printf 'boundary body\n' | FM_TELEGRAM_FAILPOINT=before_reply_network reply_once \
        "$boundary_home" "$boundary_env" "$FIXTURES/reply-success.json" >/dev/null 2>&1 || boundary_status=$?
      [ "$boundary_status" -ne 0 ] || fail "before-network crash reported success"
      assert_equal "$(db_query "$boundary_home" "SELECT state FROM replies WHERE update_id=1101")" unknown \
        "before-network crash was not delivery-unknown"
      ;;
    after-commit)
      clear_curl_calls
      printf 'boundary body\n' | FM_TELEGRAM_FAILPOINT=after_reply_commit reply_once \
        "$boundary_home" "$boundary_env" "$FIXTURES/reply-success.json" >/dev/null 2>&1 || boundary_status=$?
      [ "$boundary_status" -ne 0 ] || fail "after-commit crash reported success"
      assert_equal "$(db_query "$boundary_home" "SELECT state FROM replies WHERE update_id=1101")" sent \
        "after-commit crash lost sent state"
      clear_curl_calls
      boundary_retry=$(printf 'boundary body\n' | reply_once "$boundary_home" "$boundary_env" \
        "$FIXTURES/reply-success.json")
      assert_contains "$boundary_retry" "already-sent" "after-commit restart did not remain idempotent"
      assert_no_curl "after-commit restart sent a duplicate"
      ;;
  esac
done
pass "reply crashes before reservation, before network, and after commit preserve honest restart behavior"

for reply_bad_response in reply-malformed reply-api-failure; do
  bad_home="$TMP_ROOT/$reply_bad_response"
  bad_env="$TMP_ROOT/$reply_bad_response.env"
  arm_home "$bad_home" "$bad_env"
  poll_once "$bad_home" "$bad_env" "$FIXTURES/replyable-text.json" >/dev/null
  bad_status=0
  bad_out=$(printf 'bad response\n' | reply_once "$bad_home" "$bad_env" \
    "$FIXTURES/$reply_bad_response.json" 2>&1) || bad_status=$?
  [ "$bad_status" -ne 0 ] || fail "$reply_bad_response reported success"
  if [ "$reply_bad_response" = reply-api-failure ]; then
    assert_contains "$bad_out" "definitely refused" "API refusal was not identified"
    expected_bad_state=failed
  else
    assert_contains "$bad_out" "did not prove delivery" "malformed success was not unknown"
    expected_bad_state=unknown
  fi
  assert_equal "$(db_query "$bad_home" "SELECT state FROM replies WHERE update_id=1101")" \
    "$expected_bad_state" "$reply_bad_response persisted the wrong state"
done
pass "malformed successes become unknown while explicit Telegram refusals become definitely failed"

H_REPLY_TIMEOUT="$TMP_ROOT/reply-timeout"
REPLY_TIMEOUT_ENV="$TMP_ROOT/reply-timeout.env"
arm_home "$H_REPLY_TIMEOUT" "$REPLY_TIMEOUT_ENV"
poll_once "$H_REPLY_TIMEOUT" "$REPLY_TIMEOUT_ENV" "$FIXTURES/replyable-text.json" >/dev/null
timeout_status=0
timeout_out=$(printf 'timeout body\n' | FM_TELEGRAM_SEND_MAX_TIME=1 CURL_STUB_SLEEP=1 CURL_STUB_TIMEOUT=1 \
  reply_once "$H_REPLY_TIMEOUT" "$REPLY_TIMEOUT_ENV" /dev/null 2>&1) || timeout_status=$?
[ "$timeout_status" -ne 0 ] || fail "reply timeout reported success"
assert_contains "$timeout_out" "delivery is unknown" "reply timeout was not delivery-unknown"
assert_equal "$(db_query "$H_REPLY_TIMEOUT" "SELECT state FROM replies WHERE update_id=1101")" unknown \
  "reply timeout did not persist delivery-unknown"
pass "a send timeout is nonzero, durable, and never reported as sent"

H_REPLY_RESERVED="$TMP_ROOT/reply-reserved"
REPLY_RESERVED_ENV="$TMP_ROOT/reply-reserved.env"
arm_home "$H_REPLY_RESERVED" "$REPLY_RESERVED_ENV"
poll_once "$H_REPLY_RESERVED" "$REPLY_RESERVED_ENV" "$FIXTURES/replyable-text.json" >/dev/null
reserve_crash_status=0
printf 'reserved then retry\n' | FM_TELEGRAM_FAILPOINT=after_reply_reserve reply_once \
  "$H_REPLY_RESERVED" "$REPLY_RESERVED_ENV" "$FIXTURES/reply-success.json" >/dev/null 2>&1 \
  || reserve_crash_status=$?
[ "$reserve_crash_status" -ne 0 ] || fail "reserve crash failpoint reported success"
assert_equal "$(db_query "$H_REPLY_RESERVED" "SELECT state FROM replies WHERE update_id=1101")" reserved \
  "crash before network did not leave a durable reservation"
reserved_retry_status=0
reserved_retry=$(printf 'reserved then retry\n' | reply_once "$H_REPLY_RESERVED" "$REPLY_RESERVED_ENV" \
  "$FIXTURES/reply-success.json" 2>&1) || reserved_retry_status=$?
[ "$reserved_retry_status" -eq 0 ] || fail "a reservation with no network start could not safely resume"
assert_contains "$reserved_retry" "sent: update_id=1101" \
  "resumed reservation did not commit a validated send"

H_REPLY_REGENERATED="$TMP_ROOT/reply-regenerated"
REPLY_REGENERATED_ENV="$TMP_ROOT/reply-regenerated.env"
REGENERATED_REQUEST="$TMP_ROOT/reply-regenerated.request"
arm_home "$H_REPLY_REGENERATED" "$REPLY_REGENERATED_ENV"
poll_once "$H_REPLY_REGENERATED" "$REPLY_REGENERATED_ENV" "$FIXTURES/replyable-text.json" >/dev/null
regenerated_crash_status=0
printf 'first answer\n' | FM_TELEGRAM_FAILPOINT=after_reply_reserve reply_once \
  "$H_REPLY_REGENERATED" "$REPLY_REGENERATED_ENV" "$FIXTURES/reply-success.json" >/dev/null 2>&1 \
  || regenerated_crash_status=$?
[ "$regenerated_crash_status" -ne 0 ] || fail "reserve crash failpoint reported success"
assert_equal "$(db_query "$H_REPLY_REGENERATED" \
  "SELECT state, network_started FROM replies WHERE update_id=1101")" "reserved|0" \
  "the crash did not leave a reservation that proves it never reached the network"
regenerated_status=0
regenerated_out=$(printf 'second answer\n' | CURL_STUB_SEND_CAPTURE="$REGENERATED_REQUEST" reply_once \
  "$H_REPLY_REGENERATED" "$REPLY_REGENERATED_ENV" "$FIXTURES/reply-success.json" 2>&1) \
  || regenerated_status=$?
[ "$regenerated_status" -eq 0 ] || fail "a regenerated body could not replace a pre-network reservation"
assert_contains "$regenerated_out" "sent: update_id=1101" \
  "the regenerated reply was not committed as sent"
assert_grep 'text=second+answer%0A' "$REGENERATED_REQUEST" \
  "the regenerated body was not the text actually sent"
sent_conflict_status=0
sent_conflict=$(printf 'third answer\n' | reply_once "$H_REPLY_REGENERATED" "$REPLY_REGENERATED_ENV" \
  "$FIXTURES/reply-success.json" 2>&1) || sent_conflict_status=$?
[ "$sent_conflict_status" -ne 0 ] || fail "a sent reply accepted a different body"
assert_contains "$sent_conflict" "already has a different reply" \
  "a sent reply did not keep its body binding"

H_REPLY_STARTED="$TMP_ROOT/reply-network-started"
REPLY_STARTED_ENV="$TMP_ROOT/reply-network-started.env"
arm_home "$H_REPLY_STARTED" "$REPLY_STARTED_ENV"
poll_once "$H_REPLY_STARTED" "$REPLY_STARTED_ENV" "$FIXTURES/replyable-text.json" >/dev/null
started_crash_status=0
printf 'first answer\n' | FM_TELEGRAM_FAILPOINT=before_reply_network reply_once \
  "$H_REPLY_STARTED" "$REPLY_STARTED_ENV" "$FIXTURES/reply-success.json" >/dev/null 2>&1 \
  || started_crash_status=$?
[ "$started_crash_status" -ne 0 ] || fail "network-start crash failpoint reported success"
assert_equal "$(db_query "$H_REPLY_STARTED" \
  "SELECT state, network_started FROM replies WHERE update_id=1101")" "unknown|1" \
  "the crash after network start was not durably delivery-unknown"
clear_curl_calls
started_conflict_status=0
started_conflict=$(printf 'second answer\n' | reply_once "$H_REPLY_STARTED" "$REPLY_STARTED_ENV" \
  "$FIXTURES/reply-success.json" 2>&1) || started_conflict_status=$?
[ "$started_conflict_status" -ne 0 ] || fail "a possibly delivered reply accepted a different body"
assert_contains "$started_conflict" "delivery is unknown" \
  "a different body hid the durable delivery-unknown state"
assert_contains "$started_conflict" "automatic retry is refused" \
  "a different body made delivery-unknown look retryable"
assert_contains "$started_conflict" "doctor" \
  "a different body hid the delivery-unknown recovery action"
assert_no_curl "a possibly delivered reply was sent again with a different body"
pass "only a reservation that proves it never reached the network accepts a regenerated body"

H_REPLY_RACE="$TMP_ROOT/reply-body-race"
REPLY_RACE_ENV="$TMP_ROOT/reply-body-race.env"
RACE_MARKER="$TMP_ROOT/reply-body-race.marker"
RACE_RELEASE="$TMP_ROOT/reply-body-race.release"
RACE_OUT="$TMP_ROOT/reply-body-race.out"
RACE_BODY_A="$TMP_ROOT/reply-body-race.a"
RACE_BODY_B="$TMP_ROOT/reply-body-race.b"
RACE_REQUEST="$TMP_ROOT/reply-body-race.request"
printf 'answer alpha\n' > "$RACE_BODY_A"
printf 'answer beta\n' > "$RACE_BODY_B"
arm_home "$H_REPLY_RACE" "$REPLY_RACE_ENV"
poll_once "$H_REPLY_RACE" "$REPLY_RACE_ENV" "$FIXTURES/replyable-text.json" >/dev/null
clear_curl_calls
CURL_STUB_SEND_BODY="$FIXTURES/reply-success.json" \
  FM_TELEGRAM_FAILPOINT=reply-after-reserve \
  FM_TELEGRAM_FAILPOINT_MARKER="$RACE_MARKER" \
  FM_TELEGRAM_FAILPOINT_RELEASE="$RACE_RELEASE" \
  FM_HOME="$H_REPLY_RACE" FM_TELEGRAM_ENV_FILE="$REPLY_RACE_ENV" \
  "$ADAPTER" reply 1101 < "$RACE_BODY_A" > "$RACE_OUT" 2>&1 &
race_pid=$!
for _ in $(seq 1 500); do
  [ -e "$RACE_MARKER" ] && break
  sleep 0.01
done
assert_present "$RACE_MARKER" "the reply race never reached the post-reservation boundary"
race_replace_status=0
CURL_STUB_SEND_BODY="$FIXTURES/reply-success.json" FM_TELEGRAM_FAILPOINT=after_reply_reserve \
  FM_HOME="$H_REPLY_RACE" FM_TELEGRAM_ENV_FILE="$REPLY_RACE_ENV" \
  "$ADAPTER" reply 1101 < "$RACE_BODY_B" >/dev/null 2>&1 || race_replace_status=$?
[ "$race_replace_status" -ne 0 ] || fail "the replacing reply reported success"
: > "$RACE_RELEASE"
race_status=0
wait "$race_pid" || race_status=$?
[ "$race_status" -ne 0 ] || fail "a reply whose reserved body was replaced still reported success"
assert_contains "$(cat "$RACE_OUT")" "reservation changed before sending" \
  "a stale reply body did not fail closed at the send claim"
assert_no_curl "a reply sent a body the durable reservation no longer held"
assert_equal "$(db_query "$H_REPLY_RACE" "SELECT state, network_started FROM replies WHERE update_id=1101")" \
  "reserved|0" "a refused stale send still consumed the reservation"
race_final=$(CURL_STUB_SEND_CAPTURE="$RACE_REQUEST" reply_once "$H_REPLY_RACE" "$REPLY_RACE_ENV" \
  "$FIXTURES/reply-success.json" < "$RACE_BODY_B")
assert_contains "$race_final" "sent: update_id=1101" "the surviving reserved body could not be sent"
assert_grep 'text=answer+beta%0A' "$RACE_REQUEST" \
  "the delivered text was not the body the reservation recorded"
pass "a reservation whose body was replaced cannot send the body it no longer holds"

H_REPLY_CONCURRENT="$TMP_ROOT/reply-concurrent"
REPLY_CONCURRENT_ENV="$TMP_ROOT/reply-concurrent.env"
arm_home "$H_REPLY_CONCURRENT" "$REPLY_CONCURRENT_ENV"
poll_once "$H_REPLY_CONCURRENT" "$REPLY_CONCURRENT_ENV" "$FIXTURES/replyable-text.json" >/dev/null
clear_curl_calls
concurrent_pids=()
for concurrent_number in $(seq 1 8); do
  printf 'one concurrent reply\n' | reply_once "$H_REPLY_CONCURRENT" "$REPLY_CONCURRENT_ENV" \
    "$FIXTURES/reply-success.json" >"$TMP_ROOT/reply-concurrent.$concurrent_number" 2>&1 &
  concurrent_pids+=("$!")
done
for concurrent_pid in "${concurrent_pids[@]}"; do
  wait "$concurrent_pid" || true
done
assert_equal "$(grep -c 'sendMessage' "$CURL_CALLS" || true)" 1 \
  "concurrent attempts performed more than one Telegram send"
assert_equal "$(db_query "$H_REPLY_CONCURRENT" "SELECT state FROM replies WHERE update_id=1101")" sent \
  "concurrent attempts did not converge to sent"
pass "concurrent attempts serialize to one durable Telegram reply"

for malformed_response in reply-wrong-chat reply-wrong-message reply-wrong-text reply-missing-text; do
  shape_home="$TMP_ROOT/$malformed_response-shape"
  shape_env="$TMP_ROOT/$malformed_response-shape.env"
  arm_home "$shape_home" "$shape_env"
  poll_once "$shape_home" "$shape_env" "$FIXTURES/replyable-text.json" >/dev/null
  shape_status=0
  shape_out=$(printf 'shape check\n' | reply_once "$shape_home" "$shape_env" \
    "$FIXTURES/$malformed_response.json" 2>&1) || shape_status=$?
  [ "$shape_status" -ne 0 ] || fail "$malformed_response reported success"
  assert_contains "$shape_out" "did not prove delivery" \
    "$malformed_response was not rejected as unbound"
  assert_equal "$(db_query "$shape_home" "SELECT state FROM replies WHERE update_id=1101")" unknown \
    "$malformed_response did not persist delivery-unknown"
done
pass "a response with mismatched destination, target, or text is not accepted as delivery proof"

H_REPLY_LONG="$TMP_ROOT/reply-long"
REPLY_LONG_ENV="$TMP_ROOT/reply-long.env"
arm_home "$H_REPLY_LONG" "$REPLY_LONG_ENV"
poll_once "$H_REPLY_LONG" "$REPLY_LONG_ENV" "$FIXTURES/replyable-text.json" >/dev/null
clear_curl_calls
long_status=0
long_out=$(python3 -c 'print("x" * 4097, end="")' | reply_once "$H_REPLY_LONG" "$REPLY_LONG_ENV" \
  "$FIXTURES/reply-success.json" 2>&1) || long_status=$?
[ "$long_status" -ne 0 ] || fail "an over-limit reply reported success"
assert_contains "$long_out" "exceeds the Telegram limit" "over-limit refusal was not actionable"
case "$long_out" in *xxxx*) fail "over-limit refusal echoed the reply text" ;; esac
assert_no_curl "an over-limit reply reached the network"
assert_equal "$(db_query "$H_REPLY_LONG" "SELECT count(*) FROM replies")" 0 \
  "an over-limit reply created a reservation"
limit_out=$(python3 -c 'print("y" * 4096, end="")' | reply_once "$H_REPLY_LONG" "$REPLY_LONG_ENV" \
  "$FIXTURES/reply-success.json")
assert_contains "$limit_out" "sent: update_id=1101" "a reply at the Telegram limit was refused"

H_REPLY_BLANK="$TMP_ROOT/reply-blank"
REPLY_BLANK_ENV="$TMP_ROOT/reply-blank.env"
arm_home "$H_REPLY_BLANK" "$REPLY_BLANK_ENV"
poll_once "$H_REPLY_BLANK" "$REPLY_BLANK_ENV" "$FIXTURES/replyable-text.json" >/dev/null
clear_curl_calls
blank_status=0
blank_out=$(printf ' \t\n' | reply_once "$H_REPLY_BLANK" "$REPLY_BLANK_ENV" \
  "$FIXTURES/reply-success.json" 2>&1) || blank_status=$?
[ "$blank_status" -ne 0 ] || fail "a whitespace-only reply reported success"
assert_contains "$blank_out" "must not be empty" "the whitespace-only refusal was not actionable"
assert_no_curl "a whitespace-only reply reached the network"
assert_equal "$(db_query "$H_REPLY_BLANK" "SELECT count(*) FROM replies")" 0 \
  "a whitespace-only reply created a reservation"
blank_corrected=$(printf 'corrected answer\n' | reply_once "$H_REPLY_BLANK" "$REPLY_BLANK_ENV" \
  "$FIXTURES/reply-success.json")
assert_contains "$blank_corrected" "sent: update_id=1101" \
  "a whitespace-only body left the reply permanently unanswerable"

H_REPLY_ASTRAL="$TMP_ROOT/reply-astral"
REPLY_ASTRAL_ENV="$TMP_ROOT/reply-astral.env"
arm_home "$H_REPLY_ASTRAL" "$REPLY_ASTRAL_ENV"
poll_once "$H_REPLY_ASTRAL" "$REPLY_ASTRAL_ENV" "$FIXTURES/replyable-text.json" >/dev/null
clear_curl_calls
astral_status=0
astral_out=$(python3 -c 'print("\U0001F600" * 2049, end="")' | reply_once "$H_REPLY_ASTRAL" \
  "$REPLY_ASTRAL_ENV" "$FIXTURES/reply-success.json" 2>&1) || astral_status=$?
[ "$astral_status" -ne 0 ] || fail "a reply over the limit in UTF-16 code units reported success"
assert_contains "$astral_out" "exceeds the Telegram limit" \
  "the UTF-16 over-limit refusal was not actionable"
assert_no_curl "a reply over the UTF-16 limit reached the network"
assert_equal "$(db_query "$H_REPLY_ASTRAL" "SELECT count(*) FROM replies")" 0 \
  "a reply over the UTF-16 limit created a reservation"
astral_limit=$(python3 -c 'print("\U0001F600" * 2048, end="")' | reply_once "$H_REPLY_ASTRAL" \
  "$REPLY_ASTRAL_ENV" "$FIXTURES/reply-success.json")
assert_contains "$astral_limit" "sent: update_id=1101" \
  "a reply exactly at the UTF-16 limit was refused"
pass "reply text is bounded by the Telegram character limit before any reservation or send"

H_REPLY_CONFIG="$TMP_ROOT/reply-config"
REPLY_CONFIG_ENV="$TMP_ROOT/reply-config.env"
arm_home "$H_REPLY_CONFIG" "$REPLY_CONFIG_ENV"
poll_once "$H_REPLY_CONFIG" "$REPLY_CONFIG_ENV" "$FIXTURES/replyable-text.json" >/dev/null
clear_curl_calls
config_status=0
config_out=$(printf 'config typo\n' | FM_TELEGRAM_SEND_MAX_TIME=abc reply_once \
  "$H_REPLY_CONFIG" "$REPLY_CONFIG_ENV" "$FIXTURES/reply-success.json" 2>&1) || config_status=$?
[ "$config_status" -ne 0 ] || fail "an invalid send timeout reported success"
assert_contains "$config_out" "still owed" \
  "an invalid send timeout did not preserve the reply obligation"
assert_contains "$config_out" "reply 1101" \
  "an invalid send timeout did not name the safe explicit retry"
assert_contains "$config_out" "doctor" \
  "an invalid send timeout did not provide state-inspection guidance"
assert_no_curl "an invalid send timeout still reached the network"
assert_equal "$(db_query "$H_REPLY_CONFIG" "SELECT state FROM replies WHERE update_id=1101")" reserved \
  "a purely local failure before the network was recorded as delivery-unknown"
config_resume=$(printf 'config typo\n' | reply_once "$H_REPLY_CONFIG" "$REPLY_CONFIG_ENV" \
  "$FIXTURES/reply-success.json")
assert_contains "$config_resume" "sent: update_id=1101" \
  "a reservation left by a local failure could not resume"
pass "local send configuration failures stay recoverable instead of destroying the reply"

H_REPLY_LIMITED="$TMP_ROOT/reply-rate-limited"
REPLY_LIMITED_ENV="$TMP_ROOT/reply-rate-limited.env"
arm_home "$H_REPLY_LIMITED" "$REPLY_LIMITED_ENV"
poll_once "$H_REPLY_LIMITED" "$REPLY_LIMITED_ENV" "$FIXTURES/replyable-text.json" >/dev/null
limited_status=0
limited_out=$(printf 'throttled reply\n' | CURL_STUB_HTTP=429 reply_once "$H_REPLY_LIMITED" \
  "$REPLY_LIMITED_ENV" /dev/null 429 2>&1) || limited_status=$?
[ "$limited_status" -ne 0 ] || fail "a rate-limited reply reported success"
assert_contains "$limited_out" "rate-limited" "rate-limit refusal was not actionable"
assert_contains "$limited_out" "reply 1101" \
  "the rate-limit refusal did not name the exact reply to send again"
assert_equal "$(db_query "$H_REPLY_LIMITED" \
  "SELECT state, network_started FROM replies WHERE update_id=1101")" "reserved|0" \
  "a rate-limited reply did not stay owed as a pre-network reservation"
limited_doctor=$(FM_HOME="$H_REPLY_LIMITED" "$ADAPTER" doctor)
assert_contains "$limited_doctor" "reply_reserved=1" "doctor lost the reply still owed"
assert_contains "$limited_doctor" "reply.1101=reserved" \
  "doctor did not name the reply still owed"
limited_retry=$(printf 'throttled reply\n' | reply_once "$H_REPLY_LIMITED" "$REPLY_LIMITED_ENV" \
  "$FIXTURES/reply-success.json")
assert_contains "$limited_retry" "sent: update_id=1101" \
  "an explicit attempt after a rate limit could not deliver the reply"
pass "a Telegram rate limit is never sent, is nonzero, and permits one later explicit attempt"

H_REPLY_RETENTION="$TMP_ROOT/reply-owed-retention"
REPLY_RETENTION_ENV="$TMP_ROOT/reply-owed-retention.env"
arm_home "$H_REPLY_RETENTION" "$REPLY_RETENTION_ENV"
retention_notice=$(poll_once "$H_REPLY_RETENTION" "$REPLY_RETENTION_ENV" \
  "$FIXTURES/replyable-text.json")
retention_status=0
printf 'throttled reply\n' | CURL_STUB_HTTP=429 reply_once "$H_REPLY_RETENTION" \
  "$REPLY_RETENTION_ENV" /dev/null 429 >/dev/null 2>&1 || retention_status=$?
[ "$retention_status" -ne 0 ] || fail "the rate-limited reply reported success"
assert_equal "$(db_query "$H_REPLY_RETENTION" "SELECT count(*) FROM replies")" 1 \
  "the rate-limited reply was not retained as owed"
ack_result "$H_REPLY_RETENTION" "$REPLY_RETENTION_ENV" "$retention_notice" >/dev/null
poll_once "$H_REPLY_RETENTION" "$REPLY_RETENTION_ENV" "$FIXTURES/empty.json" >/dev/null
assert_equal "$(db_query "$H_REPLY_RETENTION" "SELECT count(*) FROM replies")" 1 \
  "a poll dropped a reply that is still worth sending"
db_exec "$H_REPLY_RETENTION" \
  "UPDATE replies SET reserved_at = reserved_at - 90000, updated_at = updated_at - 90000;"
poll_once "$H_REPLY_RETENTION" "$REPLY_RETENTION_ENV" "$FIXTURES/empty.json" >/dev/null
assert_equal "$(db_query "$H_REPLY_RETENTION" "SELECT count(*) FROM replies")" 1 \
  "a poll abandoned an old reply that is still owed"
retention_doctor=$(FM_HOME="$H_REPLY_RETENTION" "$ADAPTER" doctor)
assert_contains "$retention_doctor" "reply_reserved=1" \
  "doctor lost an old reply that is still owed"
assert_contains "$retention_doctor" "reply.1101=reserved" \
  "doctor stopped reporting the old reply obligation"
retention_send=$(printf 'late but explicit\n' | reply_once "$H_REPLY_RETENTION" \
  "$REPLY_RETENTION_ENV" \
  "$FIXTURES/reply-success.json")
assert_contains "$retention_send" "sent: update_id=1101" \
  "an old owed reply blocked a later explicit correction"
pass "a reply still owed remains durable across polls and age"

for reply_bot_status in 401 404; do
  bot_home="$TMP_ROOT/reply-bot-$reply_bot_status"
  bot_env="$TMP_ROOT/reply-bot-$reply_bot_status.env"
  arm_home "$bot_home" "$bot_env"
  poll_once "$bot_home" "$bot_env" "$FIXTURES/replyable-text.json" >/dev/null
  bot_status_code=0
  bot_out=$(printf 'stale credentials\n' | CURL_STUB_HTTP="$reply_bot_status" reply_once \
    "$bot_home" "$bot_env" /dev/null "$reply_bot_status" 2>&1) || bot_status_code=$?
  [ "$bot_status_code" -ne 0 ] || fail "http-$reply_bot_status reply reported success"
  assert_contains "$bot_out" "credentials or endpoint" \
    "http-$reply_bot_status refusal was not actionable"
  assert_contains "$bot_out" "reply 1101" \
    "the http-$reply_bot_status refusal did not name the exact reply to send again"
  assert_equal "$(db_query "$bot_home" \
    "SELECT state, network_started FROM replies WHERE update_id=1101")" "reserved|0" \
    "http-$reply_bot_status left the reply permanently unanswerable"
  bot_retry=$(printf 'corrected credentials\n' | reply_once "$bot_home" "$bot_env" \
    "$FIXTURES/reply-success.json")
  assert_contains "$bot_retry" "sent: update_id=1101" \
    "an explicit attempt after http-$reply_bot_status could not deliver the reply"
done
pass "a refusal about the bot rather than the message stays recoverable after correction"

H_REPLY_BULK="$TMP_ROOT/reply-bulk"
REPLY_BULK_ENV="$TMP_ROOT/reply-bulk.env"
python3 - "$FIXTURES/reply-bulk.json" "$CAPTAIN_CHAT_ID" "$CAPTAIN_USER_ID" <<'BULK'
import json
import sys

path, chat_id, user_id = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
updates = [
    {
        "update_id": 1400 + n,
        "message": {
            "message_id": 771,
            "date": 1700000000 + n,
            "chat": {"id": chat_id},
            "from": {"id": user_id},
            "text": "bulk message %d" % n,
        },
    }
    for n in range(1, 15)
]
with open(path, "w") as handle:
    handle.write(json.dumps({"ok": True, "result": updates}))
BULK
arm_home "$H_REPLY_BULK" "$REPLY_BULK_ENV"
poll_once "$H_REPLY_BULK" "$REPLY_BULK_ENV" "$FIXTURES/reply-bulk.json" >/dev/null
for bulk_number in $(seq 1 14); do
  bulk_update=$((1400 + bulk_number))
  if [ "$bulk_number" -le 3 ]; then
    printf 'bulk answer %s\n' "$bulk_number" | CURL_STUB_SEND_ECHO_TEXT=1 \
      FM_HOME="$H_REPLY_BULK" FM_TELEGRAM_ENV_FILE="$REPLY_BULK_ENV" \
      "$ADAPTER" reply "$bulk_update" >/dev/null 2>&1 \
      || fail "bulk reply $bulk_update did not send"
  else
    printf 'bulk answer %s\n' "$bulk_number" | CURL_STUB_EXIT=7 \
      FM_HOME="$H_REPLY_BULK" FM_TELEGRAM_ENV_FILE="$REPLY_BULK_ENV" \
      "$ADAPTER" reply "$bulk_update" >/dev/null 2>&1 \
      && fail "bulk reply $bulk_update reported success after a transport failure"
  fi
done
bulk_doctor=$(FM_HOME="$H_REPLY_BULK" "$ADAPTER" doctor)
assert_contains "$bulk_doctor" "reply_count=14" "doctor lost the reply total"
assert_contains "$bulk_doctor" "reply_sent=3" "doctor miscounted sent replies"
assert_contains "$bulk_doctor" "reply_delivery_unknown=11" \
  "doctor miscounted delivery-unknown replies"
assert_contains "$bulk_doctor" "reply_reserved=0" "doctor miscounted reserved replies"
assert_contains "$bulk_doctor" "reply_definitely_failed=0" \
  "doctor miscounted definitely-failed replies"
assert_equal "$(printf '%s\n' "$bulk_doctor" | grep -c '^reply\.')" 10 \
  "doctor did not bound its per-reply enumeration"
assert_contains "$bulk_doctor" "reply_attention_omitted=1" \
  "doctor did not report how many attention rows it omitted"
assert_contains "$bulk_doctor" "reply.1414=delivery-unknown detail=delivery-unknown" \
  "doctor omitted the newest reply needing attention"
case "$bulk_doctor" in
  *"reply.1404="*) fail "doctor listed an older reply beyond its bound" ;;
  *"=sent"*) fail "doctor enumerated a sent reply row" ;;
esac
pass "doctor reports bounded reply totals and only the newest rows still needing attention"

H_FOREIGN_ID="$TMP_ROOT/foreign-message-id"
FOREIGN_ID_ENV="$TMP_ROOT/foreign-message-id.env"
arm_home "$H_FOREIGN_ID" "$FOREIGN_ID_ENV"
foreign_out=$(poll_once "$H_FOREIGN_ID" "$FOREIGN_ID_ENV" "$FIXTURES/foreign-unusable-message-id.json")
assert_contains "$foreign_out" "message: 1" \
  "a skipped message with an unusable message_id blocked the captain's batch"
assert_equal "$(db_query "$H_FOREIGN_ID" "SELECT committed_offset FROM meta")" 1203 \
  "a skipped message with an unusable message_id stalled the committed offset"
assert_equal "$(db_query "$H_FOREIGN_ID" "SELECT update_id FROM messages")" 1202 \
  "the captain message in a mixed batch was not stored"
pass "an unusable message_id outside the captain conversation never poisons a batch"

H_CAPTAIN_ID="$TMP_ROOT/captain-message-id"
CAPTAIN_ID_ENV="$TMP_ROOT/captain-message-id.env"
arm_home "$H_CAPTAIN_ID" "$CAPTAIN_ID_ENV"
captain_id_out=$(poll_once "$H_CAPTAIN_ID" "$CAPTAIN_ID_ENV" "$FIXTURES/captain-unusable-message-id.json")
assert_contains "$captain_id_out" "message: 1" \
  "a captain message with an unusable message_id was not delivered"
write_result "$captain_id_out"
assert_contains "$(FM_HOME="$H_CAPTAIN_ID" "$ADAPTER" messages "$RESULT_FILE")" \
  "captain without usable message identity" "intake dropped the captain text"
clear_curl_calls
captain_id_status=0
captain_id_reply=$(printf 'no identity\n' | FM_HOME="$H_CAPTAIN_ID" FM_TELEGRAM_ENV_FILE="$CAPTAIN_ID_ENV" \
  "$ADAPTER" reply 1301 2>&1) || captain_id_status=$?
[ "$captain_id_status" -ne 0 ] || fail "reply accepted an inbound record with an unusable message_id"
assert_contains "$captain_id_reply" "lacks strict reply identity evidence" \
  "unusable reply identity refusal was not actionable"
assert_no_curl "an unusable reply identity still reached the network"
assert_equal "$(db_query "$H_CAPTAIN_ID" "SELECT count(*) FROM replies")" 0 \
  "an unusable reply identity created a reservation"
pass "a captain message with an unusable message_id stays readable but refuses a reply"

PATH="$ORIGINAL_PATH"
printf 'all fm-procevent-telegram tests passed\n'
