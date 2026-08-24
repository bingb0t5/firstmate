#!/usr/bin/env bash
# Telegram adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-telegram.sh arm
#   fm-procevent-telegram.sh source-id
#   fm-procevent-telegram.sh classify <result-file>
#   fm-procevent-telegram.sh terminal <result-file>
#   fm-procevent-telegram.sh retire
#
# arm         Register this home's single Telegram source with the runner.
#             Refuses when no readable credential file exists (see below), so
#             an unconfigured home never gets a registered source and never
#             sees a Telegram-shaped wake at all. Before arming, deregister
#             state/telegram-watch.check.sh and wait for any in-flight legacy
#             invocation to finish - see HANDOFF below.
# source-id   The canonical id: always the constant "telegram". This home has
#             at most one Telegram channel, so there is nothing to derive an
#             id from.
# classify    Print what a handler should act on: "message" when the captured
#             result reports at least one newly delivered text message,
#             "blocked" when it reports a confirmed permanent API failure
#             (see PERMANENT FAILURE), "none" for anything else (an empty or
#             unrecognized result).
# terminal    NEVER exits 0. The captain's Telegram channel is permanent: no
#             captured result - not an error, not silence, not a message -
#             may retire this source. Every other adapter in this runner can
#             end; this one is the one exception, and that is deliberate.
# retire      The explicit operator path. Nothing here ever calls this on
#             itself; only a human decision to stop the channel does.
#
# This adapter is deliberately thin. It owns only what is specific to
# Telegram: canonical source identity, the argv of the blocking child (a
# single `getUpdates` long poll per invocation), and how to read a completed
# result. Ownership, durable capture, publication, and restart recovery all
# belong to bin/fm-procevent.sh; this script never touches the wake queue or
# the claim/ownership machinery directly.
#
# `answers` is deliberately NOT implemented. Mapping a Telegram message onto a
# captain-held decision key is a separate problem: guessing at it would feed
# the keyed-answer intake something the captain did not clearly, structurally
# say. A Telegram message is prose, not a decision-card submission. Likewise
# `self-announcing` and `autohandle` are not implemented - nothing here
# applies a message on the captain's behalf, so the runner's default
# publish-and-leave-for-the-handler order is exactly right.
#
# CREDENTIAL. The bot token, captain chat id, and captain user id live as
# TELEGRAM_BOT_TOKEN, TELEGRAM_CAPTAIN_CHAT_ID, and TELEGRAM_CAPTAIN_USER_ID
# in ~/.config/beanz/telegram.env (mode exactly 600, gitignored, outside this
# repo; override the path with FM_TELEGRAM_ENV_FILE for tests). All three
# must be nonempty and the file must be exactly private (0600; any other mode
# is treated as unavailable, never read) or the credential is unavailable.
# They are read into memory only; the token reaches curl through an inline
# `-K -` config fed over a pipe (never as a literal argv element, so it does
# not appear in a process listing either), and every result this adapter
# produces is a fixed marker line plus a message count - never the token,
# never the credential file's own bytes.
#
# CAPTAIN IDENTITY is the sender, not the room. TELEGRAM_CAPTAIN_USER_ID is
# the captain's own Telegram user id, and a message is only ever treated as a
# captain command when its `from.id` matches it. The chat id alone is not an
# identity: if TELEGRAM_CAPTAIN_CHAT_ID names a group, every member of that
# group can put text into it, and trusting the chat would hand any of them
# the captain's authority over firstmate. Both must match - the right sender,
# in the expected chat - or the update is consumed like any other
# unauthorized traffic. TELEGRAM_CAPTAIN_USER_ID is required, not optional:
# without it there is no sender to check against, so `arm` refuses to
# register the source at all rather than fall back to chat-only trust.
#
# THE BLOCKING CHILD is this script's own `poll` subcommand (internal; not
# listed above because arm is the only supported way to register it). Each
# invocation runs exactly one Telegram `getUpdates` long poll and then exits,
# so the runner captures a result and restarts it - the same run-to-completion
# shape as every other adapter here, not a persistent daemon.
#
# WRITE-BEFORE-OFFSET is the one invariant this adapter cannot compromise on.
# Telegram permanently deletes updates once `getUpdates` is called with a
# higher offset, and there is no way to rewind and replay them - this was
# proven by accident while wiring up the original check-sweep version of this
# channel. So every text message is durably written under
# state/telegram-inbox/ BEFORE the offset file advances past it, and if any
# update in a batch cannot be resolved (a write fails, or an existing claim
# for it is not yet a complete payload - see HANDOFF), the whole batch's
# offset does not advance: every update in it, including ones already
# written, is fetched again next time. A per-update durable delivery receipt
# is reserved before its inbox claim is published and is only ever relinked
# into the live inbox after the same `handled/` check the claim path makes,
# so recovery can never resurrect a message firstmate already handled. An
# aggregate pending-delivery record bridges those claims to reporting and
# offset advancement. This keeps a published claim discoverable even if the
# aggregate record or offset cannot yet be written; see LOSS LIMITATION for
# the one window this cannot close. Text from any chat other than
# TELEGRAM_CAPTAIN_CHAT_ID, text from any sender other than
# TELEGRAM_CAPTAIN_USER_ID, non-text updates (a photo, a sticker, a
# chat-membership change), and updates whose message, chat, or sender is not
# shaped like the documented API are consumed the same way - their ids are
# folded into the advanced offset - but produce no inbox file and never count
# toward "message" below.
#
# HANDOFF. state/telegram-watch.check.sh, the retiring home-local check-sweep
# script, is a second, independent producer into this same inbox that cannot
# be modified (out of scope) and does not know this adapter exists. Its own
# write is a plain in-place `open(path, "w")` with no temp file and no
# rename, so a reader can observe it mid-write. This adapter therefore claims
# each update id atomically at the delivery boundary rather than checking
# then writing: it writes its own complete, fsynced payload to a private temp
# file first, then hardlinks that finished temp file onto the shared
# `<update_id>.json` name. The hardlink either succeeds - this adapter is the
# first and only claimant, and the message counts as newly delivered - or
# fails with the name already taken, in which case this adapter never
# hardlinks to whatever is already there (that would risk linking a still-
# mutable inode the legacy script has not finished writing). Instead it reads
# and parses that existing file: a complete, well-formed payload means some
# other claimant already delivered this exact update and this poll must
# no-op on it (never a second captain-visible wake for the same message), and
# anything else - not yet valid JSON, wrong update id - means a claimant is
# still mid-write, and this update blocks the whole batch's offset exactly
# like a failed write, so an unadvanced retry gives that write time to
# finish. `handled/<update_id>.json` is also checked before claiming, so an
# update already archived when that check occurs is not redelivered after its
# live inbox file is gone. See LOSS LIMITATION for the concurrent-move race.
# This closes the specific hazard the atomic claim exists for: two producers
# racing on one update id can never produce two different captain-visible
# deliveries, and this adapter never trusts a payload the legacy script might
# still be truncating or rewriting. It does NOT make true simultaneous
# overlap free: if the legacy script's own in-flight `getUpdates` call
# returns the same batch, it still runs its own independent write-and-report
# path and can still produce its own separate wake through the check sweep,
# which this adapter has no way to see or suppress. Only ensuring no legacy
# invocation is genuinely in flight - not merely deregistering it, which
# stops future invocations but not one already inside `getUpdates` - closes
# that window; deregister the check, then let one full check-sweep interval
# pass (or confirm no such process is running) before arming.
#
# LOSS LIMITATION, stated plainly. The poll prints its result and clears the
# pending-delivery record before it exits, while the parent runner can
# durably capture output only after that exit. A crash after the clear but
# before the runner's capture can therefore strand an already-offset message
# without a wake. The unlink is not directory-fsynced, so power loss before
# the filesystem commits it can instead resurrect the marker and repeat a
# captured wake. No adapter-local transaction can close this source-side
# handoff window, and closing it would mean changing bin/fm-procevent.sh's
# own capture boundary, which is out of scope here. A partial-batch result
# deliberately leaves the offset unchanged so Telegram returns the batch
# again. On that retry, firstmate can move an inbox file into `handled/`
# after this adapter checks that archive path but before it links the retried
# claim into the now-vacant inbox path. That race recreates the same update,
# counts it as new, and can produce a duplicate wake. Closing it requires a
# shared acknowledgement-and-claim boundary that this adapter does not have.
# Never describe this path as exactly-once, at-least-once, no-loss, or
# lossless.
#
# A lost message from the captain is not recoverable at all.
#
# PERMANENT FAILURE. Most non-200 responses are transient - a 5xx, a rate
# limit, a network blip - and the right answer for those is exactly what this
# adapter has always done: stay silent and retry on the next reconcile pass.
# Two are not transient. A 401 means the bot token was revoked or rotated and
# no amount of retrying will authenticate it, and a 409 means another
# `getUpdates` (in practice the retiring state/telegram-watch.check.sh) holds
# this bot's long poll and this adapter will never see an update while it
# does. Retrying either forever in silence lets the captain's primary channel
# away from the terminal die invisibly while Telegram discards the undelivered
# updates behind it. So each of those two codes, and only those two, produces
# exactly one durable `blocked: <code>` result - a real capture and a real
# wake through the ordinary path above, nothing new - recorded independently
# by code in state/.telegram-blocked so each condition is announced once
# rather than on every poll. A 401 remains sticky across 409 responses and
# explicit arm or retire operations. A 409 remains announced across other
# failures during the same unresolved overlap. Only a valid, parsed Telegram
# success clears these episode markers, so a later occurrence can announce
# again.
# The channel is never retired over this: `terminal` still never exits 0, the
# source stays armed, and an operator fixing the token or stopping the legacy
# sweep resumes delivery with no further action. The signal shares the same
# source-side window as LOSS LIMITATION above: it is printed before the
# runner can capture it, so a crash in that gap loses the announcement, and
# the marker then suppresses a repeat until the condition clears and recurs.
#
# EXIT-CODE CONTRACT for `poll`, precise because the generic runner's own
# capture rule is precise: exit 0 always captures and publishes a wake
# regardless of what (if anything) was printed, and only a NONZERO exit with
# EMPTY stdout leaves the source armed with no capture and no wake at all
# (bin/fm-procevent.sh's own `no-result` path). So:
#   - at least one new text message was durably written: exit 0, stdout is
#     exactly `message: <count>`. This is the only path that wakes firstmate.
#   - a confirmed permanent API failure not yet announced (HTTP 401 or 409;
#     see PERMANENT FAILURE): exit 0, stdout is exactly `blocked: <code>`.
#     This wakes firstmate exactly once per occurrence of the condition.
#   - no updates at all, only non-text or unauthorized updates, an already-
#     announced permanent failure, or a transient network or API error (any
#     other non-200): exit 1, no stdout. Silent, no capture, no wake - the
#     runner restarts this poll on its next reconcile pass, which is what
#     keeps latency down to that pass's cadence instead of the check sweep.
#   - the credential file is absent, unreadable, incomplete, or not exactly
#     mode 600: exit 0, no stdout. This is a deliberate, narrow exception to
#     "nonzero for nothing to report": an unconfigured home never reaches
#     this path at all because `arm` above already refused to register it,
#     so in ordinary operation this exit code is never observed by the
#     runner. It only fires if a credential file present at arm time is
#     later removed, blanked, or has its permissions loosened while the
#     source stays armed - an operator-caused edge case, not the steady
#     state. In that narrow window this DOES produce one empty capture and
#     one check wake per restart until credentials are restored or the
#     source is retired; that gap is accepted rather than hidden, because
#     closing it would mean either re-validating credentials on every poll
#     cycle through a side channel `poll` cannot see (arm's own refusal
#     already covers the common case) or silently returning a nonzero exit
#     here instead of the zero this command documents. Pending delivery and
#     receipt recovery also wait behind this credential gate, so this outcome
#     is always silent and makes no state changes.
#
# POLL TIMEOUT. Telegram's `getUpdates` `timeout` parameter accepts up to
# roughly 50 seconds before the API itself becomes unreliable about honoring
# it. This adapter uses FM_TELEGRAM_POLL_TIMEOUT (default 25) well inside that
# range, so a captain message during an open poll is delivered in seconds
# while an idle poll still yields control back to the runner every 25 seconds
# for the next reconcile-driven restart - the mechanism that keeps this
# channel responsive between individual long-poll windows. curl's own
# --max-time (FM_TELEGRAM_CURL_MAX_TIME, default poll timeout + 15) bounds the
# whole call comfortably past the requested long-poll window so a slow network
# round trip cannot make this child outlive the runner's expectations, without
# masking a poll that is legitimately still waiting.
#
# OFFSET FILE. state/.telegram-offset - the same file and convention the
# home-local state/telegram-watch.check.sh check-sweep script already uses.
# Sharing it preserves continuity across the handoff; HANDOFF above owns
# exactly what sharing it does and does not make safe.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INBOX="$STATE/telegram-inbox"
OFFSET_FILE="$STATE/.telegram-offset"
PENDING_FILE="$STATE/.telegram-pending-delivery"
RECEIPT_DIR="$STATE/.telegram-delivery-receipts"
BLOCKED_FILE="$STATE/.telegram-blocked"
SOURCE_ID=telegram

POLL_TIMEOUT=${FM_TELEGRAM_POLL_TIMEOUT:-25}
CURL_MAX_TIME=${FM_TELEGRAM_CURL_MAX_TIME:-$((POLL_TIMEOUT + 15))}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 2; }

env_file_path() {
  printf '%s\n' "${FM_TELEGRAM_ENV_FILE:-$HOME/.config/beanz/telegram.env}"
}

# Read TELEGRAM_BOT_TOKEN out of the credential file into this process's
# memory only. Never printed anywhere except this function's own stdout,
# which every caller captures straight into a shell variable and never echoes
# back out.
telegram_bot_token() {  # <env-file>
  (
    TELEGRAM_BOT_TOKEN=
    set -a
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1
    set +a
    printf '%s' "${TELEGRAM_BOT_TOKEN:-}"
  )
}

telegram_captain_chat_id() {  # <env-file>
  (
    TELEGRAM_CAPTAIN_CHAT_ID=
    set -a
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1
    set +a
    printf '%s' "${TELEGRAM_CAPTAIN_CHAT_ID:-}"
  )
}

# The captain's own Telegram user id. Sender identity, not room membership,
# is what authorizes a message as a captain command; see CAPTAIN IDENTITY.
telegram_captain_user_id() {  # <env-file>
  (
    TELEGRAM_CAPTAIN_USER_ID=
    set -a
    # shellcheck disable=SC1090
    . "$1" >/dev/null 2>&1
    set +a
    printf '%s' "${TELEGRAM_CAPTAIN_USER_ID:-}"
  )
}

credential_readable() {
  local f mode
  f=$(env_file_path)
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ] || return 1
  if [ "$(uname)" = Darwin ]; then
    mode=$(stat -f %Lp "$f" 2>/dev/null) || return 1
  else
    mode=$(stat -c %a "$f" 2>/dev/null) || return 1
  fi
  [ "$mode" = 600 ]
}

credential_available() {
  credential_readable || return 1
  local env_file token captain_chat_id captain_user_id
  env_file=$(env_file_path)
  token=$(telegram_bot_token "$env_file")
  captain_chat_id=$(telegram_captain_chat_id "$env_file")
  captain_user_id=$(telegram_captain_user_id "$env_file")
  [ -n "$token" ] && [ -n "$captain_chat_id" ] && [ -n "$captain_user_id" ]
}

cmd_source_id() {
  [ "$#" -eq 0 ] || usage
  printf '%s\n' "$SOURCE_ID"
}

cmd_arm() {
  [ "$#" -eq 0 ] || usage
  credential_available || die "no readable Telegram credential at $(env_file_path)"
  "$SCRIPT_DIR/fm-procevent.sh" register telegram "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-telegram.sh" poll || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"
}

# Never exits 0. See the header: this source must never retire itself.
cmd_terminal() {
  [ "$#" -eq 1 ] || usage
  return 1
}

cmd_classify() {
  local file=${1-}
  [ -n "$file" ] || usage
  [ -f "$file" ] && [ ! -L "$file" ] || die "result file does not exist: $file"
  case "$(sed -n '1p' "$file" 2>/dev/null)" in
    message:*) printf 'message\n' ;;
    blocked:*) printf 'blocked\n' ;;
    *)         printf 'none\n' ;;
  esac
}

read_offset() {
  local v
  if [ -f "$OFFSET_FILE" ] && [ ! -L "$OFFSET_FILE" ]; then
    v=$(cat "$OFFSET_FILE" 2>/dev/null)
  fi
  case "${v:-}" in ''|*[!0-9]*) printf '0\n' ;; *) printf '%s\n' "$v" ;; esac
}

write_offset() {  # <value>
  local value=$1 tmp
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$STATE" 2>/dev/null || return 1
  [ ! -e "$OFFSET_FILE" ] || [ -f "$OFFSET_FILE" ] || return 1
  [ ! -L "$OFFSET_FILE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.telegram-offset.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$OFFSET_FILE"
}

# The inbox is a precondition of every path that publishes a claim into it,
# including receipt recovery, which runs before the ordinary polling path
# reaches this. A validated, existing directory here is what keeps a missing
# or replaced inbox tree a self-repairing condition instead of a permanent,
# silent wedge.
ensure_inbox() {
  mkdir -p "$INBOX" 2>/dev/null || return 1
  [ -d "$INBOX" ] && [ ! -L "$INBOX" ]
}

blocked_present() {  # <http-code>
  local code=$1 line
  [ -f "$BLOCKED_FILE" ] && [ ! -L "$BLOCKED_FILE" ] || return 1
  while IFS= read -r line; do
    [ "$line" = "$code" ] && return 0
  done < "$BLOCKED_FILE"
  return 1
}

write_blocked() {  # <http-code>
  local code=$1 tmp existing_401=0 existing_409=0
  case "$code" in 401|409) ;; *) return 1 ;; esac
  mkdir -p "$STATE" 2>/dev/null || return 1
  [ ! -e "$BLOCKED_FILE" ] || [ -f "$BLOCKED_FILE" ] || return 1
  [ ! -L "$BLOCKED_FILE" ] || return 1
  blocked_present 401 && existing_401=1
  blocked_present 409 && existing_409=1
  tmp=$(umask 077; mktemp "$STATE/.telegram-blocked.XXXXXX") || return 1
  {
    [ "$existing_401" -eq 0 ] || printf '401\n'
    [ "$existing_409" -eq 0 ] || printf '409\n'
    if { [ "$code" = 401 ] && [ "$existing_401" -eq 0 ]; } \
      || { [ "$code" = 409 ] && [ "$existing_409" -eq 0 ]; }; then
      printf '%s\n' "$code"
    fi
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$BLOCKED_FILE"
}

clear_blocked() {
  [ -e "$BLOCKED_FILE" ] || [ -L "$BLOCKED_FILE" ] || return 0
  rm -f -- "$BLOCKED_FILE"
}

# One announcement per occurrence of each permanent condition: the code is
# recorded first so repeats stay silent, and only a valid parsed poll clears
# all resolved conditions.
# See PERMANENT FAILURE.
report_blocked() {  # <http-code>
  local code=$1
  blocked_present "$code" && return 1
  write_blocked "$code" || return 1
  printf 'blocked: %s\n' "$code"
}

# A durable bridge between "messages are on disk" and "the offset advanced
# past them": written after a complete batch or after any partial delivery,
# read and reported after credential validation on the next poll, and cleared only
# once its count and target offset have both been produced as this poll's
# result. Per-update receipts recover this record if its write fails. See LOSS
# LIMITATION for the one crash window this cannot close.
read_pending() {
  local count target extra
  [ -f "$PENDING_FILE" ] && [ ! -L "$PENDING_FILE" ] || return 1
  read -r count target extra < "$PENDING_FILE" || return 1
  case "$count" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  [ -z "$extra" ] || return 1
  printf '%s %s\n' "$count" "$target"
}

write_pending() {  # <count> <target-offset>
  local count=$1 target=$2 tmp
  case "$count" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$target" in ''|*[!0-9]*) return 1 ;; esac
  mkdir -p "$STATE" 2>/dev/null || return 1
  [ ! -e "$PENDING_FILE" ] || [ -f "$PENDING_FILE" ] || return 1
  [ ! -L "$PENDING_FILE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.telegram-pending-delivery.XXXXXX") || return 1
  printf '%s %s\n' "$count" "$target" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$PENDING_FILE"
}

clear_receipts() {
  local receipt
  [ -e "$RECEIPT_DIR" ] || return 0
  [ -d "$RECEIPT_DIR" ] && [ ! -L "$RECEIPT_DIR" ] || return 1
  for receipt in "$RECEIPT_DIR"/*.json; do
    [ -e "$receipt" ] || continue
    [ -f "$receipt" ] && [ ! -L "$receipt" ] || return 1
    rm -f -- "$receipt" || return 1
  done
  rmdir "$RECEIPT_DIR" 2>/dev/null || :
}

recover_receipts() {
  local count offset
  [ -d "$RECEIPT_DIR" ] && [ ! -L "$RECEIPT_DIR" ] || return 1
  ensure_inbox || return 1
  count=$(python3 - "$SCRIPT_DIR" "$RECEIPT_DIR" "$INBOX" <<'PY'
import glob
import json
import os
import sys

script_dir, receipt_dir, inbox = sys.argv[1], sys.argv[2], sys.argv[3]
sys.path.insert(0, script_dir)
from fm_procevent_telegram_validation import valid_update_id


def publish(receipt, dest):
    # The inbox tree can disappear between polls (operator cleanup, an
    # archive rotation that takes the parent). Recreating it and retrying is
    # what keeps that a recoverable condition rather than an exception that
    # exits this recovery, and the whole channel, permanently.
    try:
        os.link(receipt, dest)
    except FileNotFoundError:
        os.makedirs(inbox, exist_ok=True)
        os.link(receipt, dest)


os.makedirs(inbox, exist_ok=True)
count = 0
for receipt in glob.glob(os.path.join(receipt_dir, "*.json")):
    with open(receipt, "r", encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        sys.exit(1)
    uid = data.get("update_id")
    if not valid_update_id(uid) or not data.get("text"):
        sys.exit(1)
    # Same archive check the claim loop makes, for the same reason: firstmate
    # may have handled and archived this update between the poll that
    # published it and this recovery, and relinking it into the live inbox
    # would make the captain's command run a second time.
    handled = os.path.join(inbox, "handled", "%d.json" % uid)
    if os.path.isfile(handled):
        os.unlink(receipt)
        continue
    dest = os.path.join(inbox, "%d.json" % uid)
    try:
        publish(receipt, dest)
    except FileExistsError:
        with open(dest, "r", encoding="utf-8") as fh:
            existing = json.load(fh)
        if existing.get("update_id") != uid or not existing.get("text"):
            sys.exit(1)
    count += 1
if count:
    dir_fd = os.open(inbox, os.O_RDONLY)
    try:
        os.fsync(dir_fd)
    finally:
        os.close(dir_fd)
print(count)
PY
  ) || return 1
  case "$count" in
    0)
      rmdir "$RECEIPT_DIR" 2>/dev/null || return 1
      return 2
      ;;
    ''|*[!0-9]*) return 1 ;;
  esac
  offset=$(read_offset)
  write_pending "$count" "$offset" || return 1
  report_pending
}

report_pending() {
  local pending count target
  pending=$(read_pending) || return 1
  read -r count target <<EOF
$pending
EOF
  write_offset "$target" || return 1
  clear_receipts || return 1
  rm -f -- "$PENDING_FILE" || return 1
  printf 'message: %s\n' "$count" || return 1
  return 0
}

# The blocking child. One getUpdates long poll, then exit; see the header's
# EXIT-CODE CONTRACT for exactly what each outcome means, and HANDOFF for the
# atomic per-update claim this uses to stay safe against the legacy producer.
cmd_poll() {
  [ "$#" -eq 0 ] || usage
  local env_file token captain_chat_id captain_user_id offset body_file rc http_code out highest messages batch_error new_offset

  env_file=$(env_file_path)
  credential_readable || exit 0
  token=$(telegram_bot_token "$env_file")
  [ -n "$token" ] || exit 0
  captain_chat_id=$(telegram_captain_chat_id "$env_file")
  [ -n "$captain_chat_id" ] || exit 0
  captain_user_id=$(telegram_captain_user_id "$env_file")
  [ -n "$captain_user_id" ] || exit 0

  if [ -e "$PENDING_FILE" ] || [ -L "$PENDING_FILE" ]; then
    report_pending
    exit $?
  fi

  if [ -e "$RECEIPT_DIR" ] || [ -L "$RECEIPT_DIR" ]; then
    recover_receipts
    rc=$?
    [ "$rc" -eq 2 ] || exit "$rc"
  fi

  ensure_inbox || exit 1
  mkdir -p "$RECEIPT_DIR" 2>/dev/null || exit 1
  [ -d "$RECEIPT_DIR" ] && [ ! -L "$RECEIPT_DIR" ] || exit 1

  offset=$(read_offset)

  body_file=$(mktemp "${TMPDIR:-/tmp}/fm-telegram-poll.XXXXXX") || exit 1
  trap 'rm -f -- "$body_file"' EXIT

  rc=0
  http_code=$(
    printf 'url = "https://api.telegram.org/bot%s/getUpdates?offset=%s&timeout=%s"\n' \
      "$token" "$offset" "$POLL_TIMEOUT" \
      | curl -s -o "$body_file" -w '%{http_code}' --max-time "$CURL_MAX_TIME" -K - 2>/dev/null
  ) || rc=$?
  token=''
  [ "$rc" -eq 0 ] || exit 1
  case "$http_code" in
    200) ;;
    401|409)
      report_blocked "$http_code"
      exit $?
      ;;
    *) exit 1 ;;
  esac
  out=$(python3 - "$SCRIPT_DIR" "$STATE" "$INBOX" "$RECEIPT_DIR" "$body_file" "$captain_chat_id" "$captain_user_id" <<'PY'
import json
import os
import sys

script_dir, state, inbox, receipt_dir, body_path, captain_chat_id, captain_user_id = (
    sys.argv[1],
    sys.argv[2],
    sys.argv[3],
    sys.argv[4],
    sys.argv[5],
    sys.argv[6],
    sys.argv[7],
)
os.umask(0o077)
sys.path.insert(0, script_dir)
from fm_procevent_telegram_validation import valid_update_id

state_fd = os.open(state, os.O_RDONLY)
try:
    os.fsync(state_fd)
finally:
    os.close(state_fd)

try:
    with open(body_path, "r", encoding="utf-8") as fh:
        response = json.load(fh)
    if not isinstance(response, dict) or response.get("ok") is not True:
        raise ValueError("response is not a successful Telegram result")
    updates = response.get("result")
    if not isinstance(updates, list):
        raise ValueError("result is not a list")
except Exception:
    sys.exit(1)

if not updates:
    print("HIGHEST=")
    print("MESSAGES=0")
    print("ERROR=0")
    sys.exit(0)


def existing_claim_is_complete(path, uid):
    # A complete payload from ANY claimant (this adapter's own earlier write,
    # or the legacy producer once it has finished) is trustworthy and means
    # this update was already delivered. Anything else - unparseable JSON, a
    # missing update_id, a mismatched update_id - means a claimant, most
    # likely the legacy producer's own in-place non-atomic write, has not
    # finished yet. Never treat that as delivered and never overwrite it.
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except (OSError, ValueError):
        return False
    if not isinstance(data, dict):
        return False
    return data.get("update_id") == uid and bool(data.get("text"))


highest = 0
messages = 0
try:
    for u in updates:
        if not isinstance(u, dict):
            raise ValueError("update is not an object")
        uid = u.get("update_id")
        if not valid_update_id(uid):
            raise ValueError("update_id is outside the supported integer range")
        if uid > highest:
            highest = uid
        # Every container below is type-checked before it is read. A payload
        # shaped unlike the documented API carries no captain text this
        # adapter could deliver, so it is consumed like any other non-text or
        # unauthorized update rather than raising and wedging the offset on a
        # batch that can never resolve.
        msg = u.get("message") or u.get("edited_message")
        if not isinstance(msg, dict):
            continue
        text = msg.get("text")
        if not isinstance(text, str) or not text:
            continue
        chat = msg.get("chat")
        sender = msg.get("from")
        if not isinstance(chat, dict) or not isinstance(sender, dict):
            continue
        chat_id = chat.get("id")
        sender_id = sender.get("id")
        if str(chat_id) != captain_chat_id or str(sender_id) != captain_user_id:
            continue
        dest = os.path.join(inbox, "%d.json" % uid)
        handled = os.path.join(inbox, "handled", "%d.json" % uid)
        if os.path.isfile(handled):
            continue
        payload = {
            "update_id": uid,
            "date": msg.get("date"),
            "chat_id": chat_id,
            "from_id": sender_id,
            "text": text,
        }
        tmp = os.path.join(inbox, ".%d.json.tmp.%d" % (uid, os.getpid()))
        receipt = os.path.join(receipt_dir, "%d.json" % uid)
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out_fh:
            json.dump(payload, out_fh)
            out_fh.flush()
            os.fchmod(out_fh.fileno(), 0o600)
            os.fsync(out_fh.fileno())
        receipt_created = False
        try:
            os.link(tmp, receipt)
            receipt_created = True
            receipt_dir_fd = os.open(receipt_dir, os.O_RDONLY)
            try:
                os.fsync(receipt_dir_fd)
            finally:
                os.close(receipt_dir_fd)
            os.link(receipt, dest)
            claimed_now = True
        except FileExistsError:
            claimed_now = False
            if receipt_created:
                os.unlink(receipt)
        except OSError:
            if receipt_created:
                os.unlink(receipt)
            raise
        finally:
            os.unlink(tmp)
        if claimed_now:
            dir_fd = os.open(inbox, os.O_RDONLY)
            try:
                os.fsync(dir_fd)
            finally:
                os.close(dir_fd)
            messages += 1
            continue
        if not existing_claim_is_complete(dest, uid):
            raise OSError("existing claim for update %d is not yet a complete payload" % uid)
        # A losing duplicate path: someone else's complete payload already
        # claimed this update id, so this poll no-ops on it rather than
        # producing a second captain-visible delivery.
except (OSError, ValueError):
    print("HIGHEST=")
    print("MESSAGES=%d" % messages)
    print("ERROR=1")
    sys.exit(0)

print("HIGHEST=%d" % highest)
print("MESSAGES=%d" % messages)
print("ERROR=0")
PY
  ) || exit 1

  highest=$(printf '%s\n' "$out" | sed -n 's/^HIGHEST=//p')
  messages=$(printf '%s\n' "$out" | sed -n 's/^MESSAGES=//p')
  batch_error=$(printf '%s\n' "$out" | sed -n 's/^ERROR=//p')
  rmdir "$RECEIPT_DIR" 2>/dev/null || :
  case "$messages" in ''|*[!0-9]*) exit 1 ;; esac
  case "$batch_error" in 0|1) ;; *) exit 1 ;; esac
  case "$highest" in *[!0-9]*) exit 1 ;; esac

  if [ "$batch_error" -eq 1 ]; then
    if [ "$messages" -gt 0 ]; then
      write_pending "$messages" "$offset" || exit 1
    fi
    exit 1
  fi

  clear_blocked || exit 1
  if [ -z "$highest" ]; then
    exit 1
  fi
  new_offset=$((highest + 1))

  if [ "$messages" -gt 0 ]; then
    write_pending "$messages" "$new_offset" || exit 1
    report_pending
    exit $?
  fi

  write_offset "$new_offset" || exit 1
  exit 1
}

case "${1-}" in
  arm)       shift; cmd_arm "$@" ;;
  retire)    shift; cmd_retire "$@" ;;
  poll)      shift; cmd_poll "$@" ;;
  source-id) shift; cmd_source_id "$@" ;;
  classify)  shift; cmd_classify "$@" ;;
  terminal)  shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
