#!/usr/bin/env bash
# Behavior tests for the Telegram process-to-event adapter
# (bin/fm-procevent-telegram.sh).
#
# `curl` is replaced by a fake binary on PATH for every scenario here: no test
# talks to the real Telegram API. The fake reads and discards the `-K -`
# config fed over stdin (optionally capturing it for the token-leak checks
# below), writes a canned response body to the path named by `-o`, and prints
# a canned HTTP status code - enough to drive the adapter's own parsing and
# write-before-offset-advance logic for real, with no network involved.
#
# Nothing here asserts against the adapter's own source text; every check
# reads data the adapter produced (inbox files, the offset file, its own
# stdout) or drives it through fm-procevent.sh, the real generic runner.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP_ROOT=$(fm_test_tmproot fm-procevent-telegram-tests)
export FM_PROCEVENT_CLAIM_ROOT="$TMP_ROOT/claims"

ADAPTER="$ROOT/bin/fm-procevent-telegram.sh"
FAKEBIN=$(fm_fakebin "$TMP_ROOT")

cat > "$FAKEBIN/curl" <<'SH'
#!/usr/bin/env bash
# Fake curl: writes CURL_STUB_BODY's content to the path named by -o, prints
# CURL_STUB_HTTP (default 200), and optionally saves the piped -K - config to
# CURL_STUB_CAPTURE so a test can inspect exactly what would have been sent -
# including proving the real token was in it, as a positive control against
# the negative "the token never reaches durable output" assertions below.
set -u
out=""
i=1
argc=$#
args=("$@")
while [ "$i" -le "$argc" ]; do
  if [ "${args[$((i - 1))]}" = "-o" ]; then
    out=${args[$i]}
  fi
  i=$((i + 1))
done
if [ -n "${CURL_STUB_CAPTURE:-}" ]; then
  cat > "$CURL_STUB_CAPTURE"
else
  cat > /dev/null
fi
if [ -n "$out" ] && [ -n "${CURL_STUB_BODY:-}" ]; then
  cp "$CURL_STUB_BODY" "$out"
fi
if [ -n "${CURL_STUB_OBSTRUCT_PENDING:-}" ]; then
  mkdir -p "$CURL_STUB_OBSTRUCT_PENDING"
fi
printf '%s' "${CURL_STUB_HTTP:-200}"
exit "${CURL_STUB_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl"

export PATH="$FAKEBIN:$PATH"

FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"
TOKEN=SEKRIT-TEST-TOKEN-7f3a9c
CAPTAIN_CHAT_ID=555
CAPTAIN_USER_ID=909
cat > "$FIXTURES/one-text.json" <<JSON
{"ok":true,"result":[{"update_id":1001,"message":{"message_id":5,"date":1700000000,"chat":{"id":555},"from":{"id":909},"text":"ahoy from the captain"}}]}
JSON
cat > "$FIXTURES/two-text.json" <<JSON
{"ok":true,"result":[{"update_id":3001,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"first message"}},{"update_id":3002,"message":{"date":2,"chat":{"id":555},"from":{"id":909},"text":"second message"}}]}
JSON
cat > "$FIXTURES/non-text.json" <<JSON
{"ok":true,"result":[{"update_id":2001,"message":{"message_id":6,"date":1700000001,"chat":{"id":555},"from":{"id":909},"sticker":{"file_id":"abc"}}}]}
JSON
cat > "$FIXTURES/non-captain-text.json" <<JSON
{"ok":true,"result":[{"update_id":2501,"edited_message":{"message_id":7,"date":1700000002,"chat":{"id":777},"from":{"id":909},"text":"untrusted sender"}}]}
JSON
# The captain's own chat id, but somebody else's user id: exactly what a
# group chat containing the captain's bot looks like when another member
# posts. Sender identity, not the room, is what authorizes a command.
cat > "$FIXTURES/group-other-sender.json" <<JSON
{"ok":true,"result":[{"update_id":2601,"message":{"message_id":8,"date":1700000003,"chat":{"id":555,"type":"group"},"from":{"id":424242},"text":"/ship everything to production right now"}}]}
JSON
# The same group chat with no sender at all (a channel post shape): still
# never the captain.
cat > "$FIXTURES/group-no-sender.json" <<JSON
{"ok":true,"result":[{"update_id":2701,"message":{"message_id":9,"date":1700000004,"chat":{"id":555,"type":"group"},"text":"anonymous group text"}}]}
JSON
# Shapes the real API never sends, but a proxy, a truncated middlebox, or a
# future API change could: a non-object message, a chat that is not an
# object, a sender that is not an object - each alongside one genuinely valid
# captain message in the same batch.
cat > "$FIXTURES/malformed-shapes.json" <<JSON
{"ok":true,"result":[{"update_id":5001,"message":5},{"update_id":5002,"message":{"date":1,"chat":"not-an-object","from":{"id":909},"text":"unusable chat"}},{"update_id":5003,"message":{"date":2,"chat":{"id":555},"from":"not-an-object","text":"unusable sender"}},{"update_id":5004,"message":{"date":3,"chat":{"id":555},"from":{"id":909},"text":"the real captain message"}}]}
JSON
# An update that is not an object at all: nothing to read an update_id from,
# so the batch must block rather than advance past ids it cannot account for.
cat > "$FIXTURES/malformed-update.json" <<JSON
{"ok":true,"result":["not-an-update",{"update_id":5101,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"after the garbage"}}]}
JSON
cat > "$FIXTURES/empty.json" <<JSON
{"ok":true,"result":[]}
JSON
printf '{"ok":true,"result":' > "$FIXTURES/malformed-response.json"
cat > "$FIXTURES/rejected-response.json" <<JSON
{"ok":false,"result":[]}
JSON
cat > "$FIXTURES/overlap-batch.json" <<JSON
{"ok":true,"result":[{"update_id":4001,"message":{"date":1,"chat":{"id":555},"from":{"id":909},"text":"already delivered by the legacy script"}},{"update_id":4002,"message":{"date":2,"chat":{"id":555},"from":{"id":909},"text":"genuinely new in this batch"}}]}
JSON

new_home() { mkdir -p "$1/state"; }

write_env_file() {  # <path> <token> [captain-chat-id] [captain-user-id]
  mkdir -p "$(dirname "$1")"
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=%s\nTELEGRAM_CAPTAIN_USER_ID=%s\n' \
    "$2" "${3:-$CAPTAIN_CHAT_ID}" "${4:-$CAPTAIN_USER_ID}" > "$1"
  chmod 600 "$1"
}

# Runs the adapter's blocking child once against a given curl fixture.
# poll_once <home> <env-file> <body-fixture> [http-code] [capture-file]
poll_once() {
  local home=$1 env_file=$2 body=$3 http=${4:-200} capture=${5:-}
  CURL_STUB_BODY="$body" CURL_STUB_HTTP="$http" CURL_STUB_CAPTURE="$capture" \
    FM_HOME="$home" FM_TELEGRAM_ENV_FILE="$env_file" \
    "$ADAPTER" poll
}

# --- credential gating on arm ------------------------------------------------
H_NOCRED="$TMP_ROOT/nocred"; new_home "$H_NOCRED"
noarm_status=0
noarm_out=$(FM_HOME="$H_NOCRED" FM_TELEGRAM_ENV_FILE="$H_NOCRED/nonexistent.env" \
  "$ADAPTER" arm 2>&1) || noarm_status=$?
[ "$noarm_status" -ne 0 ] || fail "arm succeeded with no credential file"
assert_contains "$noarm_out" "no readable Telegram credential" "arm explains the refusal"
assert_absent "$H_NOCRED/state/procevent/telegram.source" "arm registered a source with no credential"
pass "arm refuses to register a source with no readable credential file"

H_NOCHAT="$TMP_ROOT/nochat"; new_home "$H_NOCHAT"
NOCHAT_ENV="$TMP_ROOT/nochat.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_USER_ID=%s\n' "$TOKEN" "$CAPTAIN_USER_ID" > "$NOCHAT_ENV"
chmod 600 "$NOCHAT_ENV"
nochat_status=0
nochat_out=$(FM_HOME="$H_NOCHAT" FM_TELEGRAM_ENV_FILE="$NOCHAT_ENV" \
  "$ADAPTER" arm 2>&1) || nochat_status=$?
[ "$nochat_status" -ne 0 ] || fail "arm succeeded without a captain chat id"
assert_contains "$nochat_out" "no readable Telegram credential" "arm explains the incomplete credential"
assert_absent "$H_NOCHAT/state/procevent/telegram.source" "arm registered a source without a captain chat id"
pass "arm refuses to register without a captain chat id"

H_NOUSER="$TMP_ROOT/nouser"; new_home "$H_NOUSER"
NOUSER_ENV="$TMP_ROOT/nouser.env"
printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=%s\n' "$TOKEN" "$CAPTAIN_CHAT_ID" > "$NOUSER_ENV"
chmod 600 "$NOUSER_ENV"
nouser_status=0
nouser_out=$(FM_HOME="$H_NOUSER" FM_TELEGRAM_ENV_FILE="$NOUSER_ENV" \
  "$ADAPTER" arm 2>&1) || nouser_status=$?
[ "$nouser_status" -ne 0 ] || fail "arm succeeded without a captain user id"
assert_contains "$nouser_out" "no readable Telegram credential" "arm explains the missing captain user id"
assert_absent "$H_NOUSER/state/procevent/telegram.source" "arm registered a source without a captain user id"
nouser_poll_status=0
nouser_poll_out=$(poll_once "$H_NOUSER" "$NOUSER_ENV" "$FIXTURES/one-text.json" \
  2>"$TMP_ROOT/nouser.err") || nouser_poll_status=$?
[ "$nouser_poll_status" -eq 0 ] || fail "a poll with no captain user id did not exit 0: status=$nouser_poll_status"
[ -z "$nouser_poll_out" ] || fail "a poll with no captain user id produced output: $nouser_poll_out"
assert_absent "$H_NOUSER/state/telegram-inbox/1001.json" \
  "a chat id alone must never authorize a message without a configured captain user id"
assert_absent "$H_NOUSER/state/.telegram-offset" "a poll with no captain user id must not advance an offset"
pass "chat id alone is not captain identity: arm refuses and poll stays inert without a user id"

# --- arm registers with the real runner, list shows it, retire cleans up ----
H_ARM="$TMP_ROOT/arm"; new_home "$H_ARM"
ARM_ENV="$TMP_ROOT/arm.env"; write_env_file "$ARM_ENV" "$TOKEN"
arm_out=$(FM_HOME="$H_ARM" FM_TELEGRAM_ENV_FILE="$ARM_ENV" "$ADAPTER" arm)
assert_contains "$arm_out" "armed: telegram" "arm reports the fixed source id"
list_out=$(FM_HOME="$H_ARM" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$list_out" "telegram" "the registered source is visible to the generic runner"
sid_out=$("$ADAPTER" source-id)
assert_contains "$sid_out" "telegram" "source-id is the fixed constant"
retire_out=$(FM_HOME="$H_ARM" "$ADAPTER" retire)
assert_contains "$retire_out" "retired: telegram" "retire is the explicit operator path"
list_after=$(FM_HOME="$H_ARM" "$ROOT/bin/fm-procevent.sh" list)
assert_contains "$list_after" "no sources registered" "retire actually removes the registration"
pass "arm registers with the real runner, list shows it, and retire cleans it up"

# --- happy path: a new text message is captured and wakes the source -------
H_MSG="$TMP_ROOT/msg"; new_home "$H_MSG"
MSG_ENV="$TMP_ROOT/msg.env"; write_env_file "$MSG_ENV" "$TOKEN"
msg_status=0
msg_out=$(poll_once "$H_MSG" "$MSG_ENV" "$FIXTURES/one-text.json") || msg_status=$?
[ "$msg_status" -eq 0 ] || fail "a delivered text message did not exit 0: $msg_out"
assert_contains "$msg_out" "message: 1" "a delivered text message is reported by count"
assert_present "$H_MSG/state/telegram-inbox/1001.json" "the message was written to the inbox"
mode=$(PATH="${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}" bash -c \
  '. "$1/bin/fm-pr-lib.sh"; fm_pr_file_mode "$2"' _ "$ROOT" "$H_MSG/state/telegram-inbox/1001.json")
assert_contains "$mode" 600 "the inbox message file is private"
assert_grep 'ahoy from the captain' "$H_MSG/state/telegram-inbox/1001.json" "the inbox file carries the real message text"
assert_grep '"chat_id": 555' "$H_MSG/state/telegram-inbox/1001.json" "the inbox file carries the chat id"
[ "$(cat "$H_MSG/state/.telegram-offset")" = 1002 ] || fail "the offset did not advance past the delivered update"
pass "a new text message is written to the inbox, and the offset advances past it"

# --- missing credential file: silent and inert ------------------------------
H_NOCRED2="$TMP_ROOT/nocred2"; new_home "$H_NOCRED2"
noc_status=0
noc_out=$(CURL_STUB_BODY="$FIXTURES/one-text.json" FM_HOME="$H_NOCRED2" \
  FM_TELEGRAM_ENV_FILE="$H_NOCRED2/absent.env" "$ADAPTER" poll 2>"$TMP_ROOT/nocred2.err") || noc_status=$?
[ "$noc_status" -eq 0 ] || fail "missing credential file did not exit 0: status=$noc_status"
[ -z "$noc_out" ] || fail "missing credential file produced output: $noc_out"
[ ! -s "$TMP_ROOT/nocred2.err" ] || fail "missing credential file wrote to stderr: $(cat "$TMP_ROOT/nocred2.err")"
assert_absent "$H_NOCRED2/state/telegram-inbox" "a missing credential file must never create an inbox"
assert_absent "$H_NOCRED2/state/.telegram-offset" "a missing credential file must never advance an offset"
pass "an absent credential file exits zero, silent, and touches nothing"

H_BADMODE="$TMP_ROOT/badmode"; new_home "$H_BADMODE"
BADMODE_ENV="$TMP_ROOT/badmode.env"; write_env_file "$BADMODE_ENV" "$TOKEN"
chmod 0644 "$BADMODE_ENV"
badmode_arm_status=0
badmode_arm_out=$(FM_HOME="$H_BADMODE" FM_TELEGRAM_ENV_FILE="$BADMODE_ENV" \
  "$ADAPTER" arm 2>&1) || badmode_arm_status=$?
[ "$badmode_arm_status" -ne 0 ] || fail "arm succeeded with a mode-0644 credential file"
assert_contains "$badmode_arm_out" "no readable Telegram credential" "arm explains the insecure credential refusal"
assert_absent "$H_BADMODE/state/procevent/telegram.source" "arm registered a source with insecure credentials"
badmode_poll_status=0
badmode_poll_out=$(poll_once "$H_BADMODE" "$BADMODE_ENV" "$FIXTURES/one-text.json" \
  2>"$TMP_ROOT/badmode.err") || badmode_poll_status=$?
[ "$badmode_poll_status" -eq 0 ] || fail "insecure credential poll did not exit 0: status=$badmode_poll_status"
[ -z "$badmode_poll_out" ] || fail "insecure credential poll produced output: $badmode_poll_out"
[ ! -s "$TMP_ROOT/badmode.err" ] || fail "insecure credential poll wrote to stderr: $(cat "$TMP_ROOT/badmode.err")"
assert_absent "$H_BADMODE/state/telegram-inbox" "insecure credentials must never create an inbox"
assert_absent "$H_BADMODE/state/.telegram-offset" "insecure credentials must never advance an offset"
pass "mode-0644 credentials make arm refuse and poll exit silent"

# --- a non-text update advances the offset without waking -------------------
H_STICKER="$TMP_ROOT/sticker"; new_home "$H_STICKER"
STICKER_ENV="$TMP_ROOT/sticker.env"; write_env_file "$STICKER_ENV" "$TOKEN"
sticker_status=0
sticker_out=$(poll_once "$H_STICKER" "$STICKER_ENV" "$FIXTURES/non-text.json") || sticker_status=$?
[ "$sticker_status" -ne 0 ] || fail "a non-text-only poll exited 0 and would have woken firstmate"
[ -z "$sticker_out" ] || fail "a non-text-only poll produced output: $sticker_out"
[ "$(cat "$H_STICKER/state/.telegram-offset")" = 2002 ] || fail "the non-text update's offset was not consumed"
assert_absent "$H_STICKER/state/telegram-inbox/2001.json" "a non-text update must never create an inbox file"
pass "a non-text update advances the offset and produces no capturable result"

# --- text from a non-captain chat is consumed without waking ----------------
H_UNTRUSTED="$TMP_ROOT/untrusted"; new_home "$H_UNTRUSTED"
UNTRUSTED_ENV="$TMP_ROOT/untrusted.env"; write_env_file "$UNTRUSTED_ENV" "$TOKEN"
untrusted_status=0
untrusted_out=$(poll_once "$H_UNTRUSTED" "$UNTRUSTED_ENV" "$FIXTURES/non-captain-text.json") || untrusted_status=$?
[ "$untrusted_status" -ne 0 ] || fail "a non-captain text exited 0 and would have woken firstmate"
[ -z "$untrusted_out" ] || fail "a non-captain text produced output: $untrusted_out"
[ "$(cat "$H_UNTRUSTED/state/.telegram-offset")" = 2502 ] || fail "the non-captain update's offset was not consumed"
assert_absent "$H_UNTRUSTED/state/telegram-inbox/2501.json" "a non-captain text must never create an inbox file"
pass "a non-captain text advances the offset without capture or wake"

# --- text from another member of the captain's own chat is not a command ---
# The dangerous case: TELEGRAM_CAPTAIN_CHAT_ID is a group, so a non-captain
# member's text arrives with the captain's chat id on it. It must be consumed
# exactly like any other unauthorized traffic - no inbox file, no wake.
H_GROUP="$TMP_ROOT/group-other-sender"; new_home "$H_GROUP"
GROUP_ENV="$TMP_ROOT/group-other-sender.env"; write_env_file "$GROUP_ENV" "$TOKEN"
group_status=0
group_out=$(poll_once "$H_GROUP" "$GROUP_ENV" "$FIXTURES/group-other-sender.json") || group_status=$?
[ "$group_status" -ne 0 ] || fail "a non-captain group member's text exited 0 and would have woken firstmate: $group_out"
[ -z "$group_out" ] || fail "a non-captain group member's text produced output: $group_out"
assert_absent "$H_GROUP/state/telegram-inbox/2601.json" \
  "a non-captain group member's text must never become a captain command"
[ "$(cat "$H_GROUP/state/.telegram-offset")" = 2602 ] || fail "the non-captain group update's offset was not consumed"
group_none_status=0
group_none_out=$(poll_once "$H_GROUP" "$GROUP_ENV" "$FIXTURES/group-no-sender.json") || group_none_status=$?
[ "$group_none_status" -ne 0 ] || fail "a senderless group text exited 0 and would have woken firstmate: $group_none_out"
[ -z "$group_none_out" ] || fail "a senderless group text produced output: $group_none_out"
assert_absent "$H_GROUP/state/telegram-inbox/2701.json" \
  "a text with no sender at all must never become a captain command"
[ "$(cat "$H_GROUP/state/.telegram-offset")" = 2702 ] || fail "the senderless group update's offset was not consumed"
pass "text in the captain's own chat from anyone but the captain is never a captain command"

# --- the same chat, the captain's own user id: still delivered -------------
H_SENDER_OK="$TMP_ROOT/sender-ok"; new_home "$H_SENDER_OK"
SENDER_OK_ENV="$TMP_ROOT/sender-ok.env"; write_env_file "$SENDER_OK_ENV" "$TOKEN"
sender_ok_status=0
sender_ok_out=$(poll_once "$H_SENDER_OK" "$SENDER_OK_ENV" "$FIXTURES/one-text.json") || sender_ok_status=$?
[ "$sender_ok_status" -eq 0 ] || fail "the captain's own message was not delivered: $sender_ok_out"
assert_contains "$sender_ok_out" "message: 1" "the captain's own message still wakes firstmate"
assert_grep '"from_id": 909' "$H_SENDER_OK/state/telegram-inbox/1001.json" \
  "the inbox file records the authorized sender it was accepted from"
pass "positive control: a message from the configured captain user id is still delivered"

# --- an empty long-poll result is equally silent ----------------------------
H_EMPTY="$TMP_ROOT/empty"; new_home "$H_EMPTY"
EMPTY_ENV="$TMP_ROOT/empty.env"; write_env_file "$EMPTY_ENV" "$TOKEN"
empty_status=0
empty_out=$(poll_once "$H_EMPTY" "$EMPTY_ENV" "$FIXTURES/empty.json") || empty_status=$?
[ "$empty_status" -ne 0 ] || fail "an empty long-poll result exited 0 and would have woken firstmate"
[ -z "$empty_out" ] || fail "an empty long-poll result produced output: $empty_out"
assert_absent "$H_EMPTY/state/.telegram-offset" "an empty long-poll result has nothing to advance the offset past"
pass "an empty long-poll result is silent and advances nothing"

H_EMPTY_RECEIPTS="$TMP_ROOT/empty-receipts"; new_home "$H_EMPTY_RECEIPTS"
EMPTY_RECEIPTS_ENV="$TMP_ROOT/empty-receipts.env"; write_env_file "$EMPTY_RECEIPTS_ENV" "$TOKEN"
empty_receipts_status=0
CURL_STUB_EXIT=28 poll_once "$H_EMPTY_RECEIPTS" "$EMPTY_RECEIPTS_ENV" "$FIXTURES/one-text.json" \
  >/dev/null || empty_receipts_status=$?
[ "$empty_receipts_status" -ne 0 ] || fail "a simulated curl failure unexpectedly succeeded"
[ -d "$H_EMPTY_RECEIPTS/state/.telegram-delivery-receipts" ] \
  || fail "the simulated curl failure did not leave an empty receipt directory"
empty_receipts_retry_status=0
empty_receipts_retry_out=$(poll_once "$H_EMPTY_RECEIPTS" "$EMPTY_RECEIPTS_ENV" "$FIXTURES/one-text.json") \
  || empty_receipts_retry_status=$?
[ "$empty_receipts_retry_status" -eq 0 ] \
  || fail "an empty receipt directory blocked the next poll: $empty_receipts_retry_out"
assert_contains "$empty_receipts_retry_out" "message: 1" \
  "the poll after an empty receipt directory still delivers the message"
assert_present "$H_EMPTY_RECEIPTS/state/telegram-inbox/1001.json" \
  "the poll after an empty receipt directory reaches the Telegram delivery path"
pass "an empty receipt directory does not wedge later polling"

# --- write-before-offset-advance: a mid-batch write failure is recoverable --
# Requirement: a message is durably on disk BEFORE the offset advances past
# it, and a write failure leaves the offset untouched so the whole batch is
# safely retried. The obstruction here is a real filesystem failure - a
# directory already occupies the second message's own target path - not a
# stubbed helper, so the write really does fail the way a full disk or a
# permissions problem would.
H_FAIL="$TMP_ROOT/writefail"; new_home "$H_FAIL"
FAIL_ENV="$TMP_ROOT/writefail.env"; write_env_file "$FAIL_ENV" "$TOKEN"
mkdir -p "$H_FAIL/state/telegram-inbox/3002.json"
fail_status=0
fail_out=$(poll_once "$H_FAIL" "$FAIL_ENV" "$FIXTURES/two-text.json") || fail_status=$?
[ "$fail_status" -ne 0 ] || fail "a mid-batch write failure exited 0 and would have woken firstmate"
[ -z "$fail_out" ] || fail "a mid-batch write failure produced output: $fail_out"
assert_present "$H_FAIL/state/telegram-inbox/3001.json" \
  "the first message was durably written before the second message's write failed"
assert_grep 'first message' "$H_FAIL/state/telegram-inbox/3001.json" "the durably written first message carries its real text"
assert_absent "$H_FAIL/state/.telegram-offset" \
  "the offset must not advance past a batch that only partially wrote"
assert_present "$H_FAIL/state/.telegram-pending-delivery" \
  "the first message remains pending for a wake after the later batch failure"
rmdir "$H_FAIL/state/telegram-inbox/3002.json"
recover_status=0
recover_out=$(poll_once "$H_FAIL" "$FAIL_ENV" "$FIXTURES/two-text.json") || recover_status=$?
[ "$recover_status" -eq 0 ] || fail "the pending partial delivery was not reported: $recover_out"
assert_contains "$recover_out" "message: 1" \
  "the first message receives its wake before the batch is retried"
[ "$(cat "$H_FAIL/state/.telegram-offset")" = 0 ] || fail "reporting a partial delivery advanced the unresolved batch"
recover_status=0
recover_out=$(poll_once "$H_FAIL" "$FAIL_ENV" "$FIXTURES/two-text.json") || recover_status=$?
[ "$recover_status" -eq 0 ] || fail "the retried batch did not succeed once the obstruction was removed: $recover_out"
assert_contains "$recover_out" "message: 1" \
  "the retried batch delivers only the genuinely new second message"
assert_present "$H_FAIL/state/telegram-inbox/3002.json" "the second message is written once the obstruction clears"
[ "$(cat "$H_FAIL/state/.telegram-offset")" = 3003 ] || fail "the offset advances only after the retried batch fully succeeds"
pass "a mid-batch write failure leaves the offset untouched and the batch safely redelivers"

H_MARKER_FAIL="$TMP_ROOT/marker-fail"; new_home "$H_MARKER_FAIL"
MARKER_FAIL_ENV="$TMP_ROOT/marker-fail.env"; write_env_file "$MARKER_FAIL_ENV" "$TOKEN"
mkdir -p "$H_MARKER_FAIL/state/telegram-inbox/3002.json"
marker_fail_status=0
marker_fail_out=$(CURL_STUB_BODY="$FIXTURES/two-text.json" \
  CURL_STUB_OBSTRUCT_PENDING="$H_MARKER_FAIL/state/.telegram-pending-delivery" \
  FM_HOME="$H_MARKER_FAIL" FM_TELEGRAM_ENV_FILE="$MARKER_FAIL_ENV" \
  "$ADAPTER" poll) || marker_fail_status=$?
[ "$marker_fail_status" -ne 0 ] || fail "an obstructed pending marker unexpectedly succeeded: $marker_fail_out"
[ -z "$marker_fail_out" ] || fail "an obstructed pending marker produced output: $marker_fail_out"
assert_present "$H_MARKER_FAIL/state/telegram-inbox/3001.json" \
  "the first message was published before pending-marker persistence failed"
assert_present "$H_MARKER_FAIL/state/.telegram-delivery-receipts/3001.json" \
  "the published message remains durably discoverable after pending-marker failure"
rmdir "$H_MARKER_FAIL/state/.telegram-pending-delivery"
rmdir "$H_MARKER_FAIL/state/telegram-inbox/3002.json"
rm -f -- "$MARKER_FAIL_ENV"
marker_nocred_status=0
marker_nocred_out=$(poll_once "$H_MARKER_FAIL" "$MARKER_FAIL_ENV" "$FIXTURES/two-text.json") \
  || marker_nocred_status=$?
[ "$marker_nocred_status" -eq 0 ] || fail "receipt recovery without credentials did not exit 0"
[ -z "$marker_nocred_out" ] || fail "receipt recovery without credentials produced output: $marker_nocred_out"
assert_present "$H_MARKER_FAIL/state/.telegram-delivery-receipts/3001.json" \
  "credential-free polling must not consume a delivery receipt"
write_env_file "$MARKER_FAIL_ENV" "$TOKEN"
marker_recover_status=0
marker_recover_out=$(poll_once "$H_MARKER_FAIL" "$MARKER_FAIL_ENV" "$FIXTURES/two-text.json") || marker_recover_status=$?
[ "$marker_recover_status" -eq 0 ] || fail "the durable receipt was not recovered: $marker_recover_out"
assert_contains "$marker_recover_out" "message: 1" \
  "the message is eventually reported after pending-marker persistence recovers"
assert_absent "$H_MARKER_FAIL/state/.telegram-delivery-receipts/3001.json" \
  "the durable receipt clears after the message is reported"
pass "a pending-marker write failure cannot hide an already-published message"

# --- a receipt must never resurrect a message firstmate already handled ----
# Same failure the marker-fail case drives: the message is published and its
# durable receipt survives, but the poll exits without reporting. Firstmate,
# woken by an earlier event, then follows its documented contract - read every
# new file under state/telegram-inbox/, act on it, move it into handled/ - so
# by the next poll the live inbox file is gone and only the receipt remains.
# Relinking that receipt would run the captain's command a second time.
H_RESURRECT="$TMP_ROOT/receipt-handled"; new_home "$H_RESURRECT"
RESURRECT_ENV="$TMP_ROOT/receipt-handled.env"; write_env_file "$RESURRECT_ENV" "$TOKEN"
mkdir -p "$H_RESURRECT/state/telegram-inbox/3002.json"
resurrect_setup_status=0
CURL_STUB_BODY="$FIXTURES/two-text.json" \
  CURL_STUB_OBSTRUCT_PENDING="$H_RESURRECT/state/.telegram-pending-delivery" \
  FM_HOME="$H_RESURRECT" FM_TELEGRAM_ENV_FILE="$RESURRECT_ENV" \
  "$ADAPTER" poll >/dev/null || resurrect_setup_status=$?
[ "$resurrect_setup_status" -ne 0 ] || fail "the obstructed pending marker unexpectedly succeeded"
assert_present "$H_RESURRECT/state/telegram-inbox/3001.json" "the first message was published before the failure"
assert_present "$H_RESURRECT/state/.telegram-delivery-receipts/3001.json" "its durable receipt survived the failure"
# Firstmate handles and archives it, exactly as SKILL.md instructs.
mkdir -p "$H_RESURRECT/state/telegram-inbox/handled"
mv "$H_RESURRECT/state/telegram-inbox/3001.json" "$H_RESURRECT/state/telegram-inbox/handled/3001.json"
rmdir "$H_RESURRECT/state/.telegram-pending-delivery"
rmdir "$H_RESURRECT/state/telegram-inbox/3002.json"
resurrect_status=0
resurrect_out=$(poll_once "$H_RESURRECT" "$RESURRECT_ENV" "$FIXTURES/two-text.json") || resurrect_status=$?
assert_absent "$H_RESURRECT/state/telegram-inbox/3001.json" \
  "a handled message must never be relinked back into the live inbox by receipt recovery"
assert_present "$H_RESURRECT/state/telegram-inbox/handled/3001.json" "the handled archive is left intact"
[ "$resurrect_status" -eq 0 ] || fail "the poll after the handled move did not deliver the remaining message: $resurrect_out"
assert_contains "$resurrect_out" "message: 1" \
  "only the genuinely undelivered message is reported, not the already-handled one"
assert_present "$H_RESURRECT/state/telegram-inbox/3002.json" "the second message is delivered on that same poll"
assert_absent "$H_RESURRECT/state/.telegram-delivery-receipts/3001.json" \
  "the handled message's stale receipt is cleared rather than left to retry forever"
pass "receipt recovery never resurrects a message firstmate already handled"

# --- receipt recovery repairs a missing inbox tree instead of wedging ------
# Same published-but-unreported starting point, but the whole telegram-inbox
# tree is gone by the next poll (operator cleanup, an archive rotation that
# took the parent). Recovery runs before the ordinary polling path, so if it
# cannot cope with that the channel is permanently and silently dead: the
# receipt directory survives, every later poll repeats the same failure, and
# the runner discards the child's stderr.
H_NOINBOX="$TMP_ROOT/receipt-noinbox"; new_home "$H_NOINBOX"
NOINBOX_ENV="$TMP_ROOT/receipt-noinbox.env"; write_env_file "$NOINBOX_ENV" "$TOKEN"
mkdir -p "$H_NOINBOX/state/telegram-inbox/3002.json"
noinbox_setup_status=0
CURL_STUB_BODY="$FIXTURES/two-text.json" \
  CURL_STUB_OBSTRUCT_PENDING="$H_NOINBOX/state/.telegram-pending-delivery" \
  FM_HOME="$H_NOINBOX" FM_TELEGRAM_ENV_FILE="$NOINBOX_ENV" \
  "$ADAPTER" poll >/dev/null || noinbox_setup_status=$?
[ "$noinbox_setup_status" -ne 0 ] || fail "the obstructed pending marker unexpectedly succeeded"
assert_present "$H_NOINBOX/state/.telegram-delivery-receipts/3001.json" "the durable receipt survived the failure"
rmdir "$H_NOINBOX/state/.telegram-pending-delivery"
rm -rf "$H_NOINBOX/state/telegram-inbox"
noinbox_status=0
noinbox_out=$(poll_once "$H_NOINBOX" "$NOINBOX_ENV" "$FIXTURES/two-text.json" \
  2>"$TMP_ROOT/receipt-noinbox.err") || noinbox_status=$?
[ "$noinbox_status" -eq 0 ] || fail "a missing inbox tree wedged receipt recovery: status=$noinbox_status"
[ ! -s "$TMP_ROOT/receipt-noinbox.err" ] \
  || fail "receipt recovery crashed on a missing inbox tree: $(cat "$TMP_ROOT/receipt-noinbox.err")"
assert_contains "$noinbox_out" "message: 1" "the recovered message is still reported after the inbox tree is rebuilt"
assert_present "$H_NOINBOX/state/telegram-inbox/3001.json" "recovery rebuilt the inbox and republished the message"
assert_absent "$H_NOINBOX/state/.telegram-delivery-receipts/3001.json" "the receipt clears once its message is reported"
pass "receipt recovery rebuilds a missing inbox tree rather than wedging the channel forever"

# --- an inbox replaced by a symlink is refused, not published through ------
H_SYMINBOX="$TMP_ROOT/receipt-syminbox"; new_home "$H_SYMINBOX"
SYMINBOX_ENV="$TMP_ROOT/receipt-syminbox.env"; write_env_file "$SYMINBOX_ENV" "$TOKEN"
mkdir -p "$H_SYMINBOX/state/telegram-inbox/3002.json"
syminbox_setup_status=0
CURL_STUB_BODY="$FIXTURES/two-text.json" \
  CURL_STUB_OBSTRUCT_PENDING="$H_SYMINBOX/state/.telegram-pending-delivery" \
  FM_HOME="$H_SYMINBOX" FM_TELEGRAM_ENV_FILE="$SYMINBOX_ENV" \
  "$ADAPTER" poll >/dev/null || syminbox_setup_status=$?
[ "$syminbox_setup_status" -ne 0 ] || fail "the obstructed pending marker unexpectedly succeeded"
rmdir "$H_SYMINBOX/state/.telegram-pending-delivery"
rm -rf "$H_SYMINBOX/state/telegram-inbox"
ELSEWHERE="$TMP_ROOT/receipt-syminbox-elsewhere"; mkdir -p "$ELSEWHERE"
ln -s "$ELSEWHERE" "$H_SYMINBOX/state/telegram-inbox"
syminbox_status=0
syminbox_out=$(poll_once "$H_SYMINBOX" "$SYMINBOX_ENV" "$FIXTURES/two-text.json") || syminbox_status=$?
[ "$syminbox_status" -ne 0 ] || fail "recovery published through a symlinked inbox: $syminbox_out"
[ -z "$syminbox_out" ] || fail "a symlinked inbox produced output: $syminbox_out"
assert_absent "$ELSEWHERE/3001.json" "a symlinked inbox must never receive a published claim"
pass "receipt recovery refuses an inbox replaced by a symlink"

# --- a malformed update shape is consumed, not left to wedge the channel ---
# Anything not shaped like the documented API carries no captain text this
# adapter could deliver, so it must be consumed like a non-text update while
# the genuinely valid message in the same batch is still delivered.
H_MALFORMED="$TMP_ROOT/malformed"; new_home "$H_MALFORMED"
MALFORMED_ENV="$TMP_ROOT/malformed.env"; write_env_file "$MALFORMED_ENV" "$TOKEN"
malformed_status=0
malformed_out=$(poll_once "$H_MALFORMED" "$MALFORMED_ENV" "$FIXTURES/malformed-shapes.json" \
  2>"$TMP_ROOT/malformed.err") || malformed_status=$?
[ "$malformed_status" -eq 0 ] || fail "a batch containing malformed shapes lost its valid message: $malformed_out"
[ ! -s "$TMP_ROOT/malformed.err" ] || fail "a malformed shape crashed instead of degrading: $(cat "$TMP_ROOT/malformed.err")"
assert_contains "$malformed_out" "message: 1" "the one genuinely valid message in the batch is still delivered"
assert_present "$H_MALFORMED/state/telegram-inbox/5004.json" "the valid captain message reached the inbox"
assert_absent "$H_MALFORMED/state/telegram-inbox/5001.json" "a non-object message must never become an inbox file"
assert_absent "$H_MALFORMED/state/telegram-inbox/5002.json" "text with an unreadable chat must never be authorized"
assert_absent "$H_MALFORMED/state/telegram-inbox/5003.json" "text with an unreadable sender must never be authorized"
[ "$(cat "$H_MALFORMED/state/.telegram-offset")" = 5005 ] \
  || fail "the malformed batch wedged the offset: $(cat "$H_MALFORMED/state/.telegram-offset" 2>/dev/null)"
pass "malformed update shapes are consumed without crashing or wedging the offset"

H_MALFORMED_U="$TMP_ROOT/malformed-update"; new_home "$H_MALFORMED_U"
MALFORMED_U_ENV="$TMP_ROOT/malformed-update.env"; write_env_file "$MALFORMED_U_ENV" "$TOKEN"
malformed_u_status=0
malformed_u_out=$(poll_once "$H_MALFORMED_U" "$MALFORMED_U_ENV" "$FIXTURES/malformed-update.json" \
  2>"$TMP_ROOT/malformed-update.err") || malformed_u_status=$?
[ "$malformed_u_status" -ne 0 ] || fail "an unaccountable update exited 0 and would have woken firstmate: $malformed_u_out"
[ -z "$malformed_u_out" ] || fail "an unaccountable update produced output: $malformed_u_out"
[ ! -s "$TMP_ROOT/malformed-update.err" ] \
  || fail "an unaccountable update crashed instead of degrading: $(cat "$TMP_ROOT/malformed-update.err")"
assert_absent "$H_MALFORMED_U/state/.telegram-offset" \
  "an update with no readable update_id must never let the offset advance past it"
pass "an update that is not an object blocks its batch cleanly instead of crashing"

# --- HANDOFF: the atomic claim survives a legacy producer mid-write --------
# state/telegram-watch.check.sh (out of scope to modify) writes its own copy
# of an inbox file with a plain in-place `open(path, "w")` - no temp file, no
# rename - so a reader can observe it truncated or partially written. This
# reproduces exactly that shape: a legacy-style writer leaves an update's
# inbox file existing but not yet valid JSON for that update, overlapping
# with this adapter's own poll for a batch that also contains a genuinely new
# update. The whole batch must block (same as any other write failure) rather
# than either fabricating a duplicate delivery or corrupting the legacy
# write, and the genuinely new update must not be lost either.
legacy_write_incomplete() {  # <path>
  printf '{"update_id":' > "$1"  # mid-write: not yet valid JSON
}

legacy_write_complete() {  # <path> <update_id> <text>
  printf '{"update_id": %s, "date": 1, "chat_id": 555, "text": "%s"}' "$2" "$3" > "$1"
}

H_OVERLAP="$TMP_ROOT/overlap"; new_home "$H_OVERLAP"
OVERLAP_ENV="$TMP_ROOT/overlap.env"; write_env_file "$OVERLAP_ENV" "$TOKEN"
mkdir -p "$H_OVERLAP/state/telegram-inbox"
legacy_write_incomplete "$H_OVERLAP/state/telegram-inbox/4001.json"
overlap_status=0
overlap_out=$(poll_once "$H_OVERLAP" "$OVERLAP_ENV" "$FIXTURES/overlap-batch.json") || overlap_status=$?
[ "$overlap_status" -ne 0 ] || fail "a batch overlapping a legacy mid-write exited 0 and would have woken firstmate: $overlap_out"
[ -z "$overlap_out" ] || fail "a batch overlapping a legacy mid-write produced output: $overlap_out"
assert_absent "$H_OVERLAP/state/.telegram-offset" \
  "the offset must not advance while a legacy write for this batch is still incomplete"
assert_absent "$H_OVERLAP/state/telegram-inbox/4002.json" \
  "this adapter must never hardlink over or otherwise disturb a legacy claim it cannot yet trust"
legacy_content_before=$(cat "$H_OVERLAP/state/telegram-inbox/4001.json")
[ "$legacy_content_before" = '{"update_id":' ] \
  || fail "the adapter mutated the legacy producer's still-mid-write file"

# The legacy script finishes its own write. A retried poll must now recognize
# that update as already delivered - no duplicate captain-visible wake for
# it - while still delivering the genuinely new update in the same batch.
legacy_write_complete "$H_OVERLAP/state/telegram-inbox/4001.json" 4001 "already delivered by the legacy script"
overlap_retry_status=0
overlap_retry_out=$(poll_once "$H_OVERLAP" "$OVERLAP_ENV" "$FIXTURES/overlap-batch.json") || overlap_retry_status=$?
[ "$overlap_retry_status" -eq 0 ] || fail "the retried batch did not succeed once the legacy write finished: $overlap_retry_out"
assert_contains "$overlap_retry_out" "message: 1" \
  "only the genuinely new update counts once the legacy-delivered one is recognized"
assert_present "$H_OVERLAP/state/telegram-inbox/4002.json" "the genuinely new update was still delivered"
[ "$(cat "$H_OVERLAP/state/.telegram-offset")" = 4003 ] || fail "the offset advances past the whole resolved batch"
assert_grep 'already delivered by the legacy script' "$H_OVERLAP/state/telegram-inbox/4001.json" \
  "the legacy producer's own completed content survives untouched"
pass "a legacy mid-write blocks the batch without corrupting or duplicating, and resolves once it finishes"

# handled/ takes precedence over the live inbox: an update already archived
# as handled must never be redelivered, even though its live inbox copy is
# gone (the ordinary case once firstmate has processed and moved it).
H_HANDLED="$TMP_ROOT/handled-precedence"; new_home "$H_HANDLED"
HANDLED_ENV="$TMP_ROOT/handled-precedence.env"; write_env_file "$HANDLED_ENV" "$TOKEN"
mkdir -p "$H_HANDLED/state/telegram-inbox/handled"
legacy_write_complete "$H_HANDLED/state/telegram-inbox/handled/4001.json" 4001 "already handled"
handled_status=0
handled_out=$(poll_once "$H_HANDLED" "$HANDLED_ENV" "$FIXTURES/overlap-batch.json") || handled_status=$?
[ "$handled_status" -eq 0 ] || fail "a batch with one already-handled update failed entirely: $handled_out"
assert_contains "$handled_out" "message: 1" "an already-handled update is never redelivered"
assert_absent "$H_HANDLED/state/telegram-inbox/4001.json" \
  "an already-handled update must not be recreated in the live inbox"
assert_present "$H_HANDLED/state/telegram-inbox/4002.json" "the genuinely new update is still delivered"
pass "a handled update is never redelivered even after its live inbox copy is gone"

# --- offset-write failure waits silently for credentials before recovery ---
H_PEND="$TMP_ROOT/pending"; new_home "$H_PEND"
PEND_ENV="$TMP_ROOT/pending.env"; write_env_file "$PEND_ENV" "$TOKEN"
mkdir -p "$H_PEND/state/.telegram-offset"  # obstruct: the offset path is a directory
pend_status=0
pend_out=$(poll_once "$H_PEND" "$PEND_ENV" "$FIXTURES/one-text.json") || pend_status=$?
[ "$pend_status" -ne 0 ] || fail "a poll that could not persist its offset exited 0: $pend_out"
[ -z "$pend_out" ] || fail "a poll that could not persist its offset produced output: $pend_out"
assert_present "$H_PEND/state/telegram-inbox/1001.json" \
  "the message is durably written even though the offset could not be persisted yet"
assert_present "$H_PEND/state/.telegram-pending-delivery" \
  "a pending-delivery record bridges the inbox write and the stalled offset"
rmdir "$H_PEND/state/.telegram-offset"
rm -f -- "$PEND_ENV"  # credentials disappear before the retry
pend_recover_status=0
pend_recover_out=$(poll_once "$H_PEND" "$PEND_ENV" "$FIXTURES/one-text.json") || pend_recover_status=$?
[ "$pend_recover_status" -eq 0 ] || fail "pending-delivery recovery without credentials did not exit 0: $pend_recover_out"
[ -z "$pend_recover_out" ] || fail "pending recovery without credentials produced output: $pend_recover_out"
assert_absent "$H_PEND/state/.telegram-offset" "credential-free recovery must not advance the offset"
assert_present "$H_PEND/state/.telegram-pending-delivery" \
  "credential-free recovery must preserve the pending record"
write_env_file "$PEND_ENV" "$TOKEN"
pend_restored_out=$(poll_once "$H_PEND" "$PEND_ENV" "$FIXTURES/one-text.json")
assert_contains "$pend_restored_out" "message: 1" \
  "the previously-written message is reported once credentials return"
[ "$(cat "$H_PEND/state/.telegram-offset")" = 1002 ] || fail "the offset advances once persistence recovers"
assert_absent "$H_PEND/state/.telegram-pending-delivery" "the pending record clears once reported"
pass "pending recovery stays silent and inert until credentials return"

# --- a confirmed permanent API failure is announced exactly once -----------
# 401 (revoked or rotated token) and 409 (the legacy check-sweep still holding
# this bot's getUpdates) can never resolve by retrying, so each must produce
# one real captured result rather than dying silently forever. Everything else
# non-200 stays on the silent-retry path.
H_BLOCKED="$TMP_ROOT/blocked"; new_home "$H_BLOCKED"
BLOCKED_ENV="$TMP_ROOT/blocked.env"; write_env_file "$BLOCKED_ENV" "$TOKEN"
blocked_status=0
blocked_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json" 401) || blocked_status=$?
[ "$blocked_status" -eq 0 ] || fail "a 401 did not produce a capturable result: status=$blocked_status"
assert_contains "$blocked_out" "blocked: 401" "the permanent failure names its HTTP code"
printf '%s\n' "$blocked_out" > "$TMP_ROOT/blocked-401.result"
assert_contains "$("$ADAPTER" classify "$TMP_ROOT/blocked-401.result")" "blocked" \
  "a permanent-failure result classifies as blocked, not as nothing to do"
blocked_term_status=0
"$ADAPTER" terminal "$TMP_ROOT/blocked-401.result" || blocked_term_status=$?
[ "$blocked_term_status" -ne 0 ] || fail "a permanent failure retired the captain's permanent channel"
repeat_status=0
repeat_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json" 401) || repeat_status=$?
[ "$repeat_status" -ne 0 ] || fail "the same permanent failure woke firstmate a second time: $repeat_out"
[ -z "$repeat_out" ] || fail "an already-announced permanent failure produced output: $repeat_out"
pass "a permanent API failure wakes firstmate exactly once, and never retires the channel"

malformed_recovery_status=0
malformed_recovery_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/malformed-response.json") \
  || malformed_recovery_status=$?
[ "$malformed_recovery_status" -ne 0 ] || fail "a malformed HTTP 200 response was treated as recovery"
[ -z "$malformed_recovery_out" ] || fail "a malformed HTTP 200 response produced output: $malformed_recovery_out"
sticky_401_status=0
sticky_401_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json" 401) || sticky_401_status=$?
[ "$sticky_401_status" -ne 0 ] || fail "a malformed HTTP 200 cleared the sticky 401: $sticky_401_out"
[ -z "$sticky_401_out" ] || fail "the sticky 401 announced twice after malformed HTTP 200: $sticky_401_out"
pass "a malformed HTTP success cannot clear a sticky 401"

rejected_recovery_status=0
rejected_recovery_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/rejected-response.json") \
  || rejected_recovery_status=$?
[ "$rejected_recovery_status" -ne 0 ] || fail "an ok-false HTTP 200 response was treated as recovery"
[ -z "$rejected_recovery_out" ] || fail "an ok-false HTTP 200 response produced output: $rejected_recovery_out"
invalid_update_status=0
invalid_update_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/malformed-update.json") \
  || invalid_update_status=$?
[ "$invalid_update_status" -ne 0 ] || fail "an invalid update batch was treated as recovery"
[ -z "$invalid_update_out" ] || fail "an invalid update batch produced output: $invalid_update_out"
still_sticky_status=0
still_sticky_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json" 401) \
  || still_sticky_status=$?
[ "$still_sticky_status" -ne 0 ] || fail "an unsuccessful batch cleared the sticky 401: $still_sticky_out"
[ -z "$still_sticky_out" ] || fail "the sticky 401 repeated after an unsuccessful batch: $still_sticky_out"
pass "rejected responses and invalid updates cannot clear a sticky 401"

# A different permanent condition is its own announcement.
switch_status=0
switch_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json" 409) || switch_status=$?
[ "$switch_status" -eq 0 ] || fail "a 409 after an announced 401 was swallowed: status=$switch_status"
assert_contains "$switch_out" "blocked: 409" "a different permanent condition announces on its own"
switch_back_status=0
switch_back_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json" 401) || switch_back_status=$?
[ "$switch_back_status" -ne 0 ] || fail "a 409 replaced the sticky 401 marker: $switch_back_out"
[ -z "$switch_back_out" ] || fail "a 409 caused the sticky 401 to announce twice: $switch_back_out"
repeat_409_status=0
repeat_409_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json" 409) || repeat_409_status=$?
[ "$repeat_409_status" -ne 0 ] || fail "a 401 replaced the continuous 409 marker: $repeat_409_out"
[ -z "$repeat_409_out" ] || fail "the continuous 409 announced twice: $repeat_409_out"
# Recovery clears the condition, and the message behind it is still delivered.
recovered_status=0
recovered_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/one-text.json") || recovered_status=$?
[ "$recovered_status" -eq 0 ] || fail "the poll after the blockage cleared failed: $recovered_out"
assert_contains "$recovered_out" "message: 1" "delivery resumes with no operator action beyond fixing the cause"
assert_present "$H_BLOCKED/state/telegram-inbox/1001.json" "the message behind the blockage reached the inbox"
reblock_status=0
reblock_out=$(poll_once "$H_BLOCKED" "$BLOCKED_ENV" "$FIXTURES/empty.json" 401) || reblock_status=$?
[ "$reblock_status" -eq 0 ] || fail "a permanent failure recurring after recovery was swallowed: status=$reblock_status"
assert_contains "$reblock_out" "blocked: 401" "a permanent failure that recurs after recovery announces again"
pass "a cleared blockage resumes delivery and lets a later permanent failure announce again"

# --- lifecycle operations preserve a blocked episode -----------------------
H_REARM="$TMP_ROOT/blocked-rearm"; new_home "$H_REARM"
REARM_ENV="$TMP_ROOT/blocked-rearm.env"; write_env_file "$REARM_ENV" "$TOKEN"
rearm_first_status=0
rearm_first_out=$(poll_once "$H_REARM" "$REARM_ENV" "$FIXTURES/empty.json" 401) || rearm_first_status=$?
[ "$rearm_first_status" -eq 0 ] || fail "the first 401 did not announce: status=$rearm_first_status"
assert_contains "$rearm_first_out" "blocked: 401" "the first 401 announces"
rearm_silent_status=0
rearm_silent_out=$(poll_once "$H_REARM" "$REARM_ENV" "$FIXTURES/empty.json" 401) || rearm_silent_status=$?
[ "$rearm_silent_status" -ne 0 ] || fail "the announced 401 repeated without a lifecycle boundary: $rearm_silent_out"
FM_HOME="$H_REARM" FM_TELEGRAM_ENV_FILE="$REARM_ENV" "$ADAPTER" retire >/dev/null
FM_HOME="$H_REARM" FM_TELEGRAM_ENV_FILE="$REARM_ENV" "$ADAPTER" arm >/dev/null
rearm_status=0
rearm_out=$(poll_once "$H_REARM" "$REARM_ENV" "$FIXTURES/empty.json" 401) || rearm_status=$?
[ "$rearm_status" -ne 0 ] || fail "re-arm cleared the sticky 401 marker: $rearm_out"
[ -z "$rearm_out" ] || fail "re-arm caused the sticky 401 to announce twice: $rearm_out"
FM_HOME="$H_REARM" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null 2>&1 || :
pass "retiring and re-arming cannot clear a sticky 401"

# Retire alone also preserves the continuous 409 episode.
H_RETIRE_CLEAR="$TMP_ROOT/blocked-retire"; new_home "$H_RETIRE_CLEAR"
RETIRE_CLEAR_ENV="$TMP_ROOT/blocked-retire.env"; write_env_file "$RETIRE_CLEAR_ENV" "$TOKEN"
retire_clear_out=$(poll_once "$H_RETIRE_CLEAR" "$RETIRE_CLEAR_ENV" "$FIXTURES/empty.json" 409)
assert_contains "$retire_clear_out" "blocked: 409" "the 409 announces before the retire"
FM_HOME="$H_RETIRE_CLEAR" "$ADAPTER" retire >/dev/null 2>&1 || :
retire_clear_status=0
retire_clear_again=$(poll_once "$H_RETIRE_CLEAR" "$RETIRE_CLEAR_ENV" "$FIXTURES/empty.json" 409) || retire_clear_status=$?
[ "$retire_clear_status" -ne 0 ] || fail "retire cleared the continuous 409 marker: $retire_clear_again"
[ -z "$retire_clear_again" ] || fail "retire caused the continuous 409 to announce twice: $retire_clear_again"
pass "retire preserves a continuous 409 episode"

# A transient status must stay exactly as silent as it always was.
H_TRANSIENT="$TMP_ROOT/transient"; new_home "$H_TRANSIENT"
TRANSIENT_ENV="$TMP_ROOT/transient.env"; write_env_file "$TRANSIENT_ENV" "$TOKEN"
for code in 500 429 403; do
  transient_status=0
  transient_out=$(poll_once "$H_TRANSIENT" "$TRANSIENT_ENV" "$FIXTURES/one-text.json" "$code") || transient_status=$?
  [ "$transient_status" -ne 0 ] || fail "HTTP $code was treated as permanent and woke firstmate: $transient_out"
  [ -z "$transient_out" ] || fail "HTTP $code produced output: $transient_out"
done
transient_recovered_out=$(poll_once "$H_TRANSIENT" "$TRANSIENT_ENV" "$FIXTURES/one-text.json")
assert_contains "$transient_recovered_out" "message: 1" "a transient failure never blocks later delivery"
pass "every non-permanent failure keeps retrying silently, exactly as before"

# --- the bot token never reaches durable output -----------------------------
H_TOKEN="$TMP_ROOT/tokenleak"; new_home "$H_TOKEN"
TOKEN_ENV="$TMP_ROOT/tokenleak.env"; write_env_file "$TOKEN_ENV" "$TOKEN"
CAPTURE="$TMP_ROOT/curl-config-capture.txt"
token_out=$(poll_once "$H_TOKEN" "$TOKEN_ENV" "$FIXTURES/one-text.json" 200 "$CAPTURE")
assert_grep "$TOKEN" "$CAPTURE" "positive control: the real request actually carried the token"
assert_no_grep "$TOKEN" "$H_TOKEN/state/telegram-inbox/1001.json" "the token leaked into the captured inbox message"
assert_no_grep "$TOKEN" "$H_TOKEN/state/.telegram-offset" "the token leaked into the offset file"
case "$token_out" in
  *"$TOKEN"*) fail "the token leaked into the adapter's own stdout: $token_out" ;;
esac
while IFS= read -r f; do
  assert_no_grep "$TOKEN" "$f" "the token leaked into $f"
done < <(find "$H_TOKEN/state" -type f)
pass "the bot token reaches curl alone and never appears in any durable output"

# --- terminal never reports terminal, regardless of what was captured ------
RESULT_MESSAGE="$TMP_ROOT/result-message"
printf 'message: 1\n' > "$RESULT_MESSAGE"
RESULT_NONE="$TMP_ROOT/result-none"
: > "$RESULT_NONE"
term_status=0
"$ADAPTER" terminal "$RESULT_MESSAGE" || term_status=$?
[ "$term_status" -ne 0 ] || fail "terminal reported terminal for a real delivered message"
term_status=0
"$ADAPTER" terminal "$RESULT_NONE" || term_status=$?
[ "$term_status" -ne 0 ] || fail "terminal reported terminal for an empty result"
pass "the Telegram channel's terminal command never reports terminal"

# --- classify reads the fixed marker line -----------------------------------
assert_contains "$("$ADAPTER" classify "$RESULT_MESSAGE")" "message" "classify recognizes a delivered message result"
assert_contains "$("$ADAPTER" classify "$RESULT_NONE")" "none" "classify treats an empty result as none"
pass "classify distinguishes a delivered message from nothing to act on"

# --- end-to-end through the real generic runner -----------------------------
# arm, then let fm-procevent.sh reconcile actually run the poll, capture it,
# and publish a real wake - proving the whole chain, not just the adapter in
# isolation.
H_E2E="$TMP_ROOT/e2e"; new_home "$H_E2E"
E2E_ENV="$TMP_ROOT/e2e.env"; write_env_file "$E2E_ENV" "$TOKEN"
FM_HOME="$H_E2E" FM_TELEGRAM_ENV_FILE="$E2E_ENV" "$ADAPTER" arm >/dev/null
CURL_STUB_BODY="$FIXTURES/one-text.json" FM_HOME="$H_E2E" FM_TELEGRAM_ENV_FILE="$E2E_ENV" \
  "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 50); do [ -e "$H_E2E/state/.wake-queue" ] && break; sleep 0.1; done
[ -e "$H_E2E/state/.wake-queue" ] || fail "reconcile never published a wake for a delivered captain message"
assert_grep 'procevent telegram telegram 1' "$H_E2E/state/.wake-queue" "the published wake carries the adapter, source id, and sequence"
assert_present "$H_E2E/state/telegram-inbox/1001.json" "the real message landed in the inbox through the full runner"
CAPTURED=$(printf '%s/state/procevent-inbox/telegram.1.result' "$H_E2E")
assert_present "$CAPTURED" "the runner durably captured the poll's result"
assert_contains "$(FM_HOME="$H_E2E" "$ADAPTER" classify "$CAPTURED")" "message" "the captured result classifies as a message"
term_status=0
FM_HOME="$H_E2E" "$ADAPTER" terminal "$CAPTURED" || term_status=$?
[ "$term_status" -ne 0 ] || fail "the real captured result retired the channel"
assert_present "$H_E2E/state/procevent/telegram.source" "the source stays armed after a real delivered message"
FM_HOME="$H_E2E" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null
pass "arm, the real runner's reconcile, capture, and publication all work end to end"

# A permanent failure must reach firstmate through that same real chain: the
# runner captures the blocked result, publishes a wake, and leaves the
# captain's permanent channel armed.
H_E2E_BLOCKED="$TMP_ROOT/e2e-blocked"; new_home "$H_E2E_BLOCKED"
E2E_BLOCKED_ENV="$TMP_ROOT/e2e-blocked.env"; write_env_file "$E2E_BLOCKED_ENV" "$TOKEN"
FM_HOME="$H_E2E_BLOCKED" FM_TELEGRAM_ENV_FILE="$E2E_BLOCKED_ENV" "$ADAPTER" arm >/dev/null
CURL_STUB_BODY="$FIXTURES/one-text.json" CURL_STUB_HTTP=401 \
  FM_HOME="$H_E2E_BLOCKED" FM_TELEGRAM_ENV_FILE="$E2E_BLOCKED_ENV" \
  "$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
for _ in $(seq 1 50); do [ -e "$H_E2E_BLOCKED/state/.wake-queue" ] && break; sleep 0.1; done
[ -e "$H_E2E_BLOCKED/state/.wake-queue" ] || fail "a permanent API failure never reached firstmate"
assert_grep 'procevent telegram telegram 1' "$H_E2E_BLOCKED/state/.wake-queue" \
  "the permanent failure is published as an ordinary Telegram wake"
E2E_BLOCKED_CAPTURED=$(printf '%s/state/procevent-inbox/telegram.1.result' "$H_E2E_BLOCKED")
assert_present "$E2E_BLOCKED_CAPTURED" "the runner durably captured the blocked result"
assert_contains "$(FM_HOME="$H_E2E_BLOCKED" "$ADAPTER" classify "$E2E_BLOCKED_CAPTURED")" "blocked" \
  "the captured result tells the handler the channel is blocked"
term_status=0
FM_HOME="$H_E2E_BLOCKED" "$ADAPTER" terminal "$E2E_BLOCKED_CAPTURED" || term_status=$?
[ "$term_status" -ne 0 ] || fail "the captured blocked result retired the channel"
assert_present "$H_E2E_BLOCKED/state/procevent/telegram.source" "the source stays armed through a permanent failure"
FM_HOME="$H_E2E_BLOCKED" "$ROOT/bin/fm-procevent.sh" retire telegram >/dev/null
pass "a permanent API failure wakes firstmate through the real runner and leaves the source armed"

printf 'all fm-procevent-telegram tests passed\n'
