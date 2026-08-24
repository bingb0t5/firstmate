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
printf '%s' "${CURL_STUB_HTTP:-200}"
exit "${CURL_STUB_EXIT:-0}"
SH
chmod +x "$FAKEBIN/curl"

export PATH="$FAKEBIN:$PATH"

FIXTURES="$TMP_ROOT/fixtures"
mkdir -p "$FIXTURES"
TOKEN=SEKRIT-TEST-TOKEN-7f3a9c
CAPTAIN_CHAT_ID=555
cat > "$FIXTURES/one-text.json" <<JSON
{"ok":true,"result":[{"update_id":1001,"message":{"message_id":5,"date":1700000000,"chat":{"id":555},"text":"ahoy from the captain"}}]}
JSON
cat > "$FIXTURES/two-text.json" <<JSON
{"ok":true,"result":[{"update_id":3001,"message":{"date":1,"chat":{"id":555},"text":"first message"}},{"update_id":3002,"message":{"date":2,"chat":{"id":555},"text":"second message"}}]}
JSON
cat > "$FIXTURES/non-text.json" <<JSON
{"ok":true,"result":[{"update_id":2001,"message":{"message_id":6,"date":1700000001,"chat":{"id":555},"sticker":{"file_id":"abc"}}}]}
JSON
cat > "$FIXTURES/non-captain-text.json" <<JSON
{"ok":true,"result":[{"update_id":2501,"edited_message":{"message_id":7,"date":1700000002,"chat":{"id":777},"text":"untrusted sender"}}]}
JSON
cat > "$FIXTURES/empty.json" <<JSON
{"ok":true,"result":[]}
JSON

new_home() { mkdir -p "$1/state"; }

write_env_file() {  # <path> <token> [captain-chat-id]
  mkdir -p "$(dirname "$1")"
  printf 'TELEGRAM_BOT_TOKEN=%s\nTELEGRAM_CAPTAIN_CHAT_ID=%s\n' "$2" "${3:-$CAPTAIN_CHAT_ID}" > "$1"
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
printf 'TELEGRAM_BOT_TOKEN=%s\n' "$TOKEN" > "$NOCHAT_ENV"
chmod 600 "$NOCHAT_ENV"
nochat_status=0
nochat_out=$(FM_HOME="$H_NOCHAT" FM_TELEGRAM_ENV_FILE="$NOCHAT_ENV" \
  "$ADAPTER" arm 2>&1) || nochat_status=$?
[ "$nochat_status" -ne 0 ] || fail "arm succeeded without a captain chat id"
assert_contains "$nochat_out" "no readable Telegram credential" "arm explains the incomplete credential"
assert_absent "$H_NOCHAT/state/procevent/telegram.source" "arm registered a source without a captain chat id"
pass "arm refuses to register without a captain chat id"

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

# --- overlap with the retiring check-sweep producer is idempotent ----------
# Represent the home-local producer through its persisted public contract: an
# update-id-keyed inbox file and the shared offset advanced past that update.
# A stale batch reaching the new adapter during handoff must not create a
# second delivery or wake.
H_HANDOFF="$TMP_ROOT/handoff"; new_home "$H_HANDOFF"
HANDOFF_ENV="$TMP_ROOT/handoff.env"; write_env_file "$HANDOFF_ENV" "$TOKEN"
mkdir -p "$H_HANDOFF/state/telegram-inbox"
printf '%s\n' '{"update_id":1001,"date":1700000000,"chat_id":555,"text":"ahoy from the captain"}' \
  > "$H_HANDOFF/state/telegram-inbox/1001.json"
chmod 0600 "$H_HANDOFF/state/telegram-inbox/1001.json"
printf '1002\n' > "$H_HANDOFF/state/.telegram-offset"
handoff_status=0
handoff_out=$(poll_once "$H_HANDOFF" "$HANDOFF_ENV" "$FIXTURES/one-text.json") || handoff_status=$?
[ "$handoff_status" -ne 0 ] || fail "an update already delivered by the legacy producer would have woken firstmate twice"
[ -z "$handoff_out" ] || fail "an update already delivered by the legacy producer produced another result: $handoff_out"
[ "$(find "$H_HANDOFF/state/telegram-inbox" -maxdepth 1 -name '1001.json' -type f | wc -l | tr -d ' ')" = 1 ] || \
  fail "overlapping consumers produced more than one inbox delivery for one update id"
[ "$(cat "$H_HANDOFF/state/.telegram-offset")" = 1002 ] || fail "the adapter regressed the shared handoff offset"
pass "the legacy producer and adapter overlap without duplicate delivery"

# --- a handled update is never delivered or counted again ------------------
mkdir -p "$H_MSG/state/telegram-inbox/handled"
mv "$H_MSG/state/telegram-inbox/1001.json" "$H_MSG/state/telegram-inbox/handled/1001.json"
printf '1001\n' > "$H_MSG/state/.telegram-offset"
duplicate_status=0
duplicate_out=$(poll_once "$H_MSG" "$MSG_ENV" "$FIXTURES/one-text.json") || duplicate_status=$?
[ "$duplicate_status" -ne 0 ] || fail "a handled update exited 0 and would have woken firstmate twice"
[ -z "$duplicate_out" ] || fail "a handled update produced a second delivery result: $duplicate_out"
assert_absent "$H_MSG/state/telegram-inbox/1001.json" "a handled update was recreated in the live inbox"
assert_present "$H_MSG/state/telegram-inbox/handled/1001.json" "the handled update was disturbed"
[ "$(cat "$H_MSG/state/.telegram-offset")" = 1002 ] || fail "the offset did not consume the handled update"
pass "a handled update is consumed without a duplicate delivery"

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

# --- an empty long-poll result is equally silent ----------------------------
H_EMPTY="$TMP_ROOT/empty"; new_home "$H_EMPTY"
EMPTY_ENV="$TMP_ROOT/empty.env"; write_env_file "$EMPTY_ENV" "$TOKEN"
empty_status=0
empty_out=$(poll_once "$H_EMPTY" "$EMPTY_ENV" "$FIXTURES/empty.json") || empty_status=$?
[ "$empty_status" -ne 0 ] || fail "an empty long-poll result exited 0 and would have woken firstmate"
[ -z "$empty_out" ] || fail "an empty long-poll result produced output: $empty_out"
assert_absent "$H_EMPTY/state/.telegram-offset" "an empty long-poll result has nothing to advance the offset past"
pass "an empty long-poll result is silent and advances nothing"

# --- write-before-offset-advance: a mid-batch write failure is recoverable --
# Requirement: a message is durably on disk BEFORE the offset advances past
# it, and a write failure leaves the offset untouched so the whole batch is
# safely re-delivered. The obstruction here is a real filesystem failure - a
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
rmdir "$H_FAIL/state/telegram-inbox/3002.json"
recover_status=0
recover_out=$(poll_once "$H_FAIL" "$FAIL_ENV" "$FIXTURES/two-text.json") || recover_status=$?
[ "$recover_status" -eq 0 ] || fail "the retried batch did not succeed once the obstruction was removed: $recover_out"
assert_contains "$recover_out" "message: 2" "the retried batch reports both previously unwoken messages"
assert_present "$H_FAIL/state/telegram-inbox/3002.json" "the second message is written once the obstruction clears"
[ "$(cat "$H_FAIL/state/.telegram-offset")" = 3003 ] || fail "the offset advances only after the retried batch fully succeeds"
pass "a mid-batch write failure leaves the offset untouched and the batch safely redelivers"

# --- offset failure preserves the pending wake across poll invocations ------
H_OFFSET_FAIL="$TMP_ROOT/offsetfail"; new_home "$H_OFFSET_FAIL"
OFFSET_FAIL_ENV="$TMP_ROOT/offsetfail.env"; write_env_file "$OFFSET_FAIL_ENV" "$TOKEN"
mkdir "$H_OFFSET_FAIL/state/.telegram-offset"
offset_fail_status=0
offset_fail_out=$(poll_once "$H_OFFSET_FAIL" "$OFFSET_FAIL_ENV" "$FIXTURES/one-text.json") || offset_fail_status=$?
[ "$offset_fail_status" -ne 0 ] || fail "an offset write failure exited 0"
[ -z "$offset_fail_out" ] || fail "an offset write failure reported a wake before preserving the offset"
assert_present "$H_OFFSET_FAIL/state/telegram-inbox/1001.json" "the inbox write did not precede the offset failure"
assert_present "$H_OFFSET_FAIL/state/.telegram-pending-delivery" "the offset failure lost its pending wake"
rmdir "$H_OFFSET_FAIL/state/.telegram-offset"
rm "$OFFSET_FAIL_ENV"
offset_recover_status=0
offset_recover_out=$(poll_once "$H_OFFSET_FAIL" "$OFFSET_FAIL_ENV" "$FIXTURES/empty.json") || offset_recover_status=$?
[ "$offset_recover_status" -eq 0 ] || fail "the pending wake did not recover without credentials"
assert_contains "$offset_recover_out" "message: 1" "recovery did not report the already-written message"
[ "$(cat "$H_OFFSET_FAIL/state/.telegram-offset")" = 1002 ] || fail "recovery did not advance the preserved target offset"
assert_absent "$H_OFFSET_FAIL/state/.telegram-pending-delivery" "recovery did not clear the reported pending wake"
pass "an offset write failure recovers its wake without credentials"

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

printf 'all fm-procevent-telegram tests passed\n'
