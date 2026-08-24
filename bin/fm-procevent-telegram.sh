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
#             sees a Telegram-shaped wake at all. It is safe to arm while
#             state/telegram-watch.check.sh is still registered on the
#             watcher's check sweep - see HANDOFF below for exactly what that
#             overlap does and does not guarantee.
# source-id   The canonical id: always the constant "telegram". This home has
#             at most one Telegram channel, so there is nothing to derive an
#             id from.
# classify    Print what a handler should act on: "message" when the captured
#             result reports at least one newly delivered text message,
#             "none" for anything else (an empty or unrecognized result).
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
# CREDENTIAL. The bot token and captain chat id live as TELEGRAM_BOT_TOKEN and
# TELEGRAM_CAPTAIN_CHAT_ID in ~/.config/beanz/telegram.env (mode exactly 600,
# gitignored, outside this repo; override the path with FM_TELEGRAM_ENV_FILE
# for tests). Both must be nonempty and the file must be exactly private
# (0600; any other mode is treated as unavailable, never read) or the
# credential is unavailable. They are read into memory only; the token
# reaches curl through an inline `-K -` config fed over a pipe (never as a
# literal argv element, so it does not appear in a process listing either),
# and every result this adapter produces is a fixed marker line plus a
# message count - never the token, never the credential file's own bytes.
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
# written, is fetched again next time. A durable pending-delivery record
# bridges inbox persistence and offset advancement so a message that was
# written but whose offset write then failed is still reported, not lost;
# see LOSS LIMITATION for the one window this cannot close. Text from any
# chat other than TELEGRAM_CAPTAIN_CHAT_ID and non-text updates (a photo, a
# sticker, a chat-membership change) are consumed the same way - their ids
# are folded into the advanced offset - but produce no inbox file and never
# count toward "message" below.
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
# update firstmate already handled and archived is never redelivered even
# after its live inbox file is gone.
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
# own capture boundary, which is out of scope here. Never describe this path
# as at-least-once, no-loss, or lossless.
#
# A lost message from the captain is not recoverable at all.
#
# EXIT-CODE CONTRACT for `poll`, precise because the generic runner's own
# capture rule is precise: exit 0 always captures and publishes a wake
# regardless of what (if anything) was printed, and only a NONZERO exit with
# EMPTY stdout leaves the source armed with no capture and no wake at all
# (bin/fm-procevent.sh's own `no-result` path). So:
#   - at least one new text message was durably written: exit 0, stdout is
#     exactly `message: <count>`. This is the only path that wakes firstmate.
#   - no updates at all, only non-text or unauthorized updates, or a
#     transient network or API error: exit 1, no stdout. Silent, no capture,
#     no wake - the runner restarts this poll on its next reconcile pass,
#     which is what keeps latency down to that pass's cadence instead of the
#     check sweep.
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
#     here instead of the zero this command documents - and this script
#     would rather be honest about a narrow, operator-triggered gap than
#     quietly disagree with its own contract. A pending-delivery record is
#     checked and reported before this credential check, so a message
#     already durably written is never stranded behind a later credential
#     change.
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
SOURCE_ID=telegram

POLL_TIMEOUT=${FM_TELEGRAM_POLL_TIMEOUT:-25}
CURL_MAX_TIME=${FM_TELEGRAM_CURL_MAX_TIME:-$((POLL_TIMEOUT + 15))}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,177p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

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
  local env_file token captain_chat_id
  env_file=$(env_file_path)
  token=$(telegram_bot_token "$env_file")
  captain_chat_id=$(telegram_captain_chat_id "$env_file")
  [ -n "$token" ] && [ -n "$captain_chat_id" ]
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

# A durable bridge between "messages are on disk" and "the offset advanced
# past them": written only after every message in a batch is claimed, read
# and reported before anything else on the next poll (even before credential
# validation - see the EXIT-CODE CONTRACT note), and cleared only once its
# count and target offset have both been produced as this poll's result. See
# LOSS LIMITATION for the one crash window this cannot close.
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
  [ ! -L "$PENDING_FILE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.telegram-pending-delivery.XXXXXX") || return 1
  printf '%s %s\n' "$count" "$target" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$PENDING_FILE"
}

report_pending() {
  local pending count target
  pending=$(read_pending) || return 1
  read -r count target <<EOF
$pending
EOF
  write_offset "$target" || return 1
  printf 'message: %s\n' "$count" || return 1
  rm -f -- "$PENDING_FILE" || return 1
  return 0
}

# The blocking child. One getUpdates long poll, then exit; see the header's
# EXIT-CODE CONTRACT for exactly what each outcome means, and HANDOFF for the
# atomic per-update claim this uses to stay safe against the legacy producer.
cmd_poll() {
  [ "$#" -eq 0 ] || usage
  local env_file token captain_chat_id offset body_file rc http_code out highest messages new_offset

  if [ -e "$PENDING_FILE" ] || [ -L "$PENDING_FILE" ]; then
    report_pending
    exit $?
  fi

  env_file=$(env_file_path)
  credential_readable || exit 0
  token=$(telegram_bot_token "$env_file")
  [ -n "$token" ] || exit 0
  captain_chat_id=$(telegram_captain_chat_id "$env_file")
  [ -n "$captain_chat_id" ] || exit 0

  mkdir -p "$INBOX" 2>/dev/null || exit 1
  [ -d "$INBOX" ] && [ ! -L "$INBOX" ] || exit 1

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
  [ "$http_code" = 200 ] || exit 1

  out=$(python3 - "$INBOX" "$body_file" "$captain_chat_id" <<'PY'
import json
import os
import sys

inbox, body_path, captain_chat_id = sys.argv[1], sys.argv[2], sys.argv[3]
os.umask(0o077)

try:
    with open(body_path, "r", encoding="utf-8") as fh:
        updates = json.load(fh)["result"]
    if not isinstance(updates, list):
        raise ValueError("result is not a list")
except Exception:
    sys.exit(1)

if not updates:
    print("HIGHEST=")
    print("MESSAGES=0")
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
        uid = u.get("update_id")
        if not isinstance(uid, int):
            raise ValueError("update_id is not an integer")
        if uid > highest:
            highest = uid
        msg = u.get("message") or u.get("edited_message") or {}
        text = msg.get("text")
        chat_id = (msg.get("chat") or {}).get("id")
        if not text or str(chat_id) != captain_chat_id:
            continue
        dest = os.path.join(inbox, "%d.json" % uid)
        handled = os.path.join(inbox, "handled", "%d.json" % uid)
        if os.path.isfile(handled):
            continue
        payload = {
            "update_id": uid,
            "date": msg.get("date"),
            "chat_id": chat_id,
            "text": text,
        }
        tmp = os.path.join(inbox, ".%d.json.tmp.%d" % (uid, os.getpid()))
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out_fh:
            json.dump(payload, out_fh)
            out_fh.flush()
            os.fchmod(out_fh.fileno(), 0o600)
            os.fsync(out_fh.fileno())
        try:
            # The atomic claim: this either creates the shared name pointing
            # at OUR finished, immutable temp file, or fails because the name
            # is already taken. Either way our own temp name is discarded
            # right after - the shared name is the only thing that matters.
            os.link(tmp, dest)
            claimed_now = True
        except FileExistsError:
            claimed_now = False
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
    sys.exit(1)

print("HIGHEST=%d" % highest)
print("MESSAGES=%d" % messages)
PY
  ) || exit 1

  highest=$(printf '%s\n' "$out" | sed -n 's/^HIGHEST=//p')
  messages=$(printf '%s\n' "$out" | sed -n 's/^MESSAGES=//p')
  case "$messages" in ''|*[!0-9]*) exit 1 ;; esac

  if [ -z "$highest" ]; then
    exit 1
  fi
  case "$highest" in *[!0-9]*) exit 1 ;; esac
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
