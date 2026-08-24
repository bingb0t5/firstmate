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
#             sees a Telegram-shaped wake at all.
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
# CREDENTIAL. The bot token lives at ~/.config/beanz/telegram.env (mode 600,
# gitignored, outside this repo; override the path with FM_TELEGRAM_ENV_FILE
# for tests). It is read into memory for the one curl call that needs it and
# is never echoed, logged, or written anywhere else: the token reaches curl
# through an inline `-K -` config fed over a pipe (never as a literal argv
# element, so it does not appear in a process listing either), and every
# result this adapter produces is a fixed marker line plus a message count -
# never the token, never the credential file's own bytes.
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
# write in a batch fails, the offset is not advanced at all: the whole batch,
# including messages already written earlier in that same batch, is fetched
# again next time. A duplicate inbox file (same update id, same content) is
# harmless and idempotent; a lost message from the captain is not recoverable
# at all. A non-text update (a photo, a sticker, a chat-membership change) is
# consumed the same way - its id is folded into the advanced offset - but
# produces no inbox file and never counts toward "message" below.
#
# EXIT-CODE CONTRACT for `poll`, precise because the generic runner's own
# capture rule is precise: exit 0 always captures and publishes a wake
# regardless of what (if anything) was printed, and only a NONZERO exit with
# EMPTY stdout leaves the source armed with no capture and no wake at all
# (bin/fm-procevent.sh's own `no-result` path). So:
#   - at least one new text message was durably written: exit 0, stdout is
#     exactly `message: <count>`. This is the only path that wakes firstmate.
#   - no updates at all, or only non-text updates, or a transient network or
#     API error: exit 1, no stdout. Silent, no capture, no wake - the runner
#     restarts this poll on its next reconcile pass, which is what keeps
#     latency down to that pass's cadence instead of the check sweep.
#   - the credential file is absent or unreadable: exit 0, no stdout. This is
#     a deliberate, narrow exception to "nonzero for nothing to report": an
#     unconfigured home never reaches this path at all because `arm` above
#     already refused to register it, so in ordinary operation this exit code
#     is never observed by the runner. It only fires if a credential file
#     present at arm time is later removed or blanked while the source stays
#     armed - an operator-caused edge case, not the steady state. In that
#     narrow window this DOES produce one empty capture and one check wake per
#     restart until credentials are restored or the source is retired; that
#     gap is accepted rather than hidden, because closing it would mean either
#     re-validating credentials on every poll cycle through a side channel
#     `poll` cannot see (arm's own refusal already covers the common case) or
#     silently returning a nonzero exit here instead of the zero this command
#     documents - and this script would rather be honest about a narrow,
#     operator-triggered gap than quietly disagree with its own contract.
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
# Sharing it is deliberate and safe: every message file is named by its
# Telegram update id, so even if both mechanisms ran in the same narrow
# transition window, at most one redundant fetch could occur and every write
# it produced would be idempotent, never a duplicate delivery.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
INBOX="$STATE/telegram-inbox"
OFFSET_FILE="$STATE/.telegram-offset"
SOURCE_ID=telegram

POLL_TIMEOUT=${FM_TELEGRAM_POLL_TIMEOUT:-25}
CURL_MAX_TIME=${FM_TELEGRAM_CURL_MAX_TIME:-$((POLL_TIMEOUT + 15))}

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { sed -n '2,116p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 2; }

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

credential_readable() {
  local f; f=$(env_file_path)
  [ -f "$f" ] && [ ! -L "$f" ] && [ -r "$f" ]
}

credential_available() {
  credential_readable || return 1
  local token; token=$(telegram_bot_token "$(env_file_path)")
  [ -n "$token" ]
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
  [ ! -L "$OFFSET_FILE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.telegram-offset.XXXXXX") || return 1
  printf '%s\n' "$value" > "$tmp" || { rm -f -- "$tmp"; return 1; }
  chmod 0600 "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$OFFSET_FILE"
}

# The blocking child. One getUpdates long poll, then exit; see the header's
# EXIT-CODE CONTRACT for exactly what each outcome means.
cmd_poll() {
  [ "$#" -eq 0 ] || usage
  local env_file token offset body_file rc http_code out highest messages new_offset

  env_file=$(env_file_path)
  credential_readable || exit 0
  token=$(telegram_bot_token "$env_file")
  [ -n "$token" ] || exit 0

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

  out=$(python3 - "$INBOX" "$body_file" <<'PY'
import json
import os
import sys

inbox, body_path = sys.argv[1], sys.argv[2]
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

highest = 0
messages = 0
for u in updates:
    uid = u.get("update_id")
    if not isinstance(uid, int):
        sys.exit(1)
    if uid > highest:
        highest = uid
    msg = u.get("message") or u.get("edited_message") or {}
    text = msg.get("text")
    if not text:
        continue
    payload = {
        "update_id": uid,
        "date": msg.get("date"),
        "chat_id": (msg.get("chat") or {}).get("id"),
        "text": text,
    }
    dest = os.path.join(inbox, "%d.json" % uid)
    tmp = os.path.join(inbox, ".%d.json.tmp" % uid)
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as out_fh:
            json.dump(payload, out_fh)
        os.chmod(tmp, 0o600)
        os.replace(tmp, dest)
    except OSError:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        sys.exit(1)
    messages += 1

print("HIGHEST=%d" % highest)
print("MESSAGES=%d" % messages)
PY
  ) || exit 1

  highest=$(printf '%s\n' "$out" | sed -n 's/^HIGHEST=//p')
  messages=$(printf '%s\n' "$out" | sed -n 's/^MESSAGES=//p')
  case "$messages" in ''|*[!0-9]*) exit 1 ;; esac

  if [ -n "$highest" ]; then
    case "$highest" in *[!0-9]*) exit 1 ;; esac
    new_offset=$((highest + 1))
    write_offset "$new_offset" || exit 1
  fi

  if [ "$messages" -gt 0 ]; then
    printf 'message: %s\n' "$messages"
    exit 0
  fi
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
