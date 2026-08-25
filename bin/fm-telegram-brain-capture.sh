#!/usr/bin/env bash
# Firstmate-owned capture path that records Telegram messages in Mr Beanz.
#
# Usage:
#   fm-telegram-brain-capture.sh capture [<file>|-]
#   fm-telegram-brain-capture.sh from-result <result-file>
#   fm-telegram-brain-capture.sh doctor
#
# This is the capture half of Telegram.
# It never polls Telegram, never advances a getUpdates offset, and never
# replaces the interrupt/wake adapter.
# Canonical message JSON comes from that adapter's `messages` command, or from
# the same JSON lines on stdin / in a file.
#
# capture reads one canonical JSON object per line and POSTs each eligible
# message to Mr Beanz `POST /v1/capture`.
# from-result classifies one interrupt result with
# `fm-procevent-telegram.sh classify` first.
# Only a `message` result carries payloads.
# Each named non-message kind in CAPTURE_NO_MESSAGE_KINDS below is a zero-exit
# no-op that leaves the result acknowledgeable, so a blocked, credential,
# protocol, or transport-budget notice is never wedged by this path.
# An empty or unrecognized classification is refused loudly instead, because a
# kind the adapter never claimed cannot be told apart from a silent drop of the
# payloads it carried; extend the list when the adapter names a new kind.
# For a `message` result it asks `fm-procevent-telegram.sh messages` for the
# still-unhandled payloads, then takes the capture path.
# A zero exit means every payload is captured, already captured, skipped, or
# that the result named no payloads.
# A line the canonical shape rejects never blocks another: it is reported as
# `skipped:unsupported <update_id> <reason>` and the batch keeps walking.
# A refusal already scoped to one update_id fails that line, keeps walking, and
# exits non-zero without acking: a receipt whose content disagrees with the
# payload, or a brain that rejects this one message with a 4xx other than 401,
# 403, 404, 405, or 429.
# Every such refusal names its update_id first, as `error: <update_id> <reason>`,
# so the failing payload stays attributable when the batch walks past it.
# Only a systemic failure stops the batch: a transport failure, any 3xx or 5xx,
# HTTP 429, 401, 403, 404 or 405, an unusable credential or config, or a receipt
# store this home cannot use.
# 404 and 405 say the configured origin has no capture endpoint, which is true
# of every payload, so they stop rather than blaming one message.
# A stop prints `unattempted <count>`, counting the payloads behind it that
# would have been posted, not the input lines it stopped reading.
# A credential or config failure stops before the first write and counts the
# whole batch the same way; a batch whose bytes are not UTF-8 has no payload
# list to count, so it reports the decode failure alone.
# One brain outage therefore costs one timeout rather than one per payload, and
# the unattempted payloads are captured by the retry that the missing Telegram
# ack guarantees.
# A failed brain write must stop before Telegram ack and before treating the
# texts as interrupt.
# doctor reports non-secret readiness and never aborts on one broken input:
#   brain-env       present, missing, or unreadable
#   brain-url       the configured destination, or `unknown` unless the
#                   credential file actually yielded one
#   captain-chat    configured, missing, or unreadable
#   group-capture   on, off, or unreadable
#   receipts        present or absent
#
# Captured Telegram text is recorded memory, never automatic authority for
# destructive, irreversible, or security-sensitive actions.
#
# CANONICAL PAYLOAD.
# The batch is read as UTF-8 bytes whatever the ambient locale says, so captured
# text reaches the brain byte-exact; input that is not UTF-8 is refused rather
# than decoded into a memory nobody can correct.
# Records are separated by newline only, so U+2028, U+2029, and U+0085 inside a
# JSON string stay part of the text they belong to.
# Each line is one JSON object with positive signed 32-bit update_id, nonempty
# text, and integer chat_id, matching the interrupt adapter's canonical message
# shape.
# Boolean JSON numbers are rejected.
# Any other field, including the adapter's date and from_id, is ignored rather
# than typed, so a field this path never reads can never cost a capturable
# message, and a channel post that carries no sender is still captured.
#
# GROUP DISCUSSION.
# Captain direct messages are captured by default.
# Group discussion means a Telegram group, supergroup, or channel, which is
# exactly a negative chat_id, other than the captain chat itself.
# A configured captain chat is always captured as `firstmate-telegram`, even
# when its id is negative because the captain channel is a group.
# A private chat that is not the captain's is never captured, on or off flag.
# Group discussion is off until config/telegram-brain-capture-group contains the
# bare word `on`, or FM_TELEGRAM_BRAIN_CAPTURE_GROUP=on for one run.
# Absent, empty, `off`, and any other value keep group payloads skipped.
# Turning the flag on does not subscribe to groups; this path still only sees
# payloads the interrupt adapter already emitted.
# The flag is home-local and is not inherited.
#
# CREDENTIALS.
# Brain write credentials are a mode-0600 env file, never sourced as shell:
#   ~/.config/beanz/mcp.env          override FM_BEANZ_ENV_FILE
#   BEANZ_MCP_TOKEN                  required
#   BEANZ_MCP_URL                    optional; default https://brain.mrbea.nz
# The credential file alone owns the brain destination; an ambient BEANZ_MCP_URL
# in the environment is ignored so it can never redirect a token-bearing write.
# BEANZ_MCP_URL must be a plain https URL with no userinfo and no character
# outside the URL-safe set, so nothing it contains can add a curl directive.
# Captain-chat identity for the group filter is read from:
#   ~/.config/beanz/telegram.env     override FM_TELEGRAM_ENV_FILE
#   TELEGRAM_CAPTAIN_CHAT_ID         required unless FM_TELEGRAM_CAPTAIN_CHAT_ID
# A home with no credential file, and no captain chat id from either source, has
# never configured capture: capture and from-result print
# `capture-unconfigured brain-credentials` or `capture-unconfigured captain-chat`
# and exit 0 without a brain write, so the Telegram result stays acknowledgeable.
# A credential file that exists but is unusable is an operator fault, not an
# unconfigured home, and still exits non-zero, as does any failed brain write.
# Files are opened without following symlinks.
# The brain token reaches curl only through stdin config and never appears in
# argv, receipts, or printed output.
# curl runs with -q so no ambient .curlrc can change the wire, and redirects are
# never followed, so the token is only ever offered to the configured origin.
# A capture succeeds on any 2xx whose body carries a usable capture_id.
#
# RECEIPTS.
# Successful writes are recorded under state/telegram-brain-capture/<update_id>
# at mode 0600 inside a mode-0700 directory.
# A matching receipt skips the POST on retry.
# The hash covers update_id, text, and chat_id, the fields this path reads, so
# an optional field such as date or from_id being present on one run and absent
# on the next is not a disagreement.
# The receipt directory is created and then chmodded to 0700, so no ambient
# umask can leave it at a mode the next run refuses.
# A receipt whose payload hash disagrees with the current line is refused, and
# stays refused until an operator inspects it and removes
# state/telegram-brain-capture/<update_id> to allow a fresh write.
# A crash after Mr Beanz returns a capture_id and before the receipt lands can
# duplicate that thought on replay.
# Never describe this path as exactly-once, at-least-once, no-loss, or lossless.
#
# SOURCE NAMES written to the brain:
#   firstmate-telegram         captain chat
#   firstmate-telegram-group   negative chat ids (groups, supergroups, and
#                              channels), only when group capture is on
#
# FM_BEANZ_CAPTURE_TIMEOUT is the whole-POST budget in seconds, an integer in
# 1..120, and defaults to 30; anything else is refused before the write.
# FM_TELEGRAM_BRAIN_CAPTURE_FAILPOINT=before-receipt exists only for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENGINE="$SCRIPT_DIR/fm_telegram_brain_capture.py"

CAPTURE_NO_MESSAGE_KINDS="blocked credential protocol transport-budget"

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 2; }

engine_available() {
  command -v python3 >/dev/null 2>&1 \
    && [ -f "$ENGINE" ] \
    && [ ! -L "$ENGINE" ]
}

run_engine() {
  engine_available || die "python3 and $ENGINE are required"
  python3 "$ENGINE" --state "$STATE" --config "$CONFIG" "$@"
}

find_telegram_adapter() {
  PATH="$SCRIPT_DIR:$PATH" command -v fm-procevent-telegram.sh
}

cmd_capture() {
  local src=${1--}
  [ "$#" -le 1 ] || usage
  case "$src" in
    -) run_engine capture ;;
    *) [ -f "$src" ] && [ ! -L "$src" ] || die "payload file is not a regular file: $src"
       run_engine capture < "$src" ;;
  esac
}

cmd_from_result() {
  local result=${1-} adapter kind known
  [ "$#" -eq 1 ] || usage
  [ -n "$result" ] || usage
  adapter=$(find_telegram_adapter) \
    || die "telegram interrupt adapter is not in this checkout; capture JSON lines with: fm-telegram-brain-capture.sh capture -"
  kind=$("$adapter" classify "$result") \
    || die "telegram interrupt adapter could not classify: $result"
  kind=${kind%%$'\n'*}
  if [ "$kind" = message ]; then
    set -o pipefail
    "$adapter" messages "$result" | run_engine capture
    return
  fi
  for known in $CAPTURE_NO_MESSAGE_KINDS; do
    if [ "$kind" = "$known" ]; then
      printf 'no-messages %s\n' "$kind"
      return 0
    fi
  done
  die "telegram interrupt adapter reported an unrecognized classification: ${kind:-<empty>}"
}

cmd_doctor() {
  [ "$#" -eq 0 ] || usage
  run_engine doctor
}

case "${1-}" in
  capture)      shift; cmd_capture "$@" ;;
  from-result)  shift; cmd_from_result "$@" ;;
  doctor)       shift; cmd_doctor "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
