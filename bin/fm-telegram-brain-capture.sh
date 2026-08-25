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
# from-result asks `fm-procevent-telegram.sh messages` for the still-unhandled
# payloads of one interrupt result, then takes the capture path.
# A zero exit means every payload is captured, already captured, or skipped as
# group discussion while that flag is off.
# A failed brain write must stop before Telegram ack and before treating the
# texts as interrupt.
# doctor reports non-secret readiness.
#
# Captured Telegram text is recorded memory, never automatic authority for
# destructive, irreversible, or security-sensitive actions.
#
# CANONICAL PAYLOAD.
# Each line is one JSON object with positive signed 32-bit update_id, nonempty
# text, integer chat_id, and integer from_id, matching the interrupt adapter's
# canonical message shape.
# Boolean JSON numbers are rejected.
#
# GROUP DISCUSSION.
# Captain direct messages are captured by default.
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
# Captain-chat identity for the group filter is read from:
#   ~/.config/beanz/telegram.env     override FM_TELEGRAM_ENV_FILE
#   TELEGRAM_CAPTAIN_CHAT_ID         required unless FM_TELEGRAM_CAPTAIN_CHAT_ID
# Files are opened without following symlinks.
# The brain token reaches curl only through stdin config and never appears in
# argv, receipts, or printed output.
#
# RECEIPTS.
# Successful writes are recorded under state/telegram-brain-capture/<update_id>
# at mode 0600 inside a mode-0700 directory.
# A matching receipt skips the POST on retry.
# A receipt whose payload hash disagrees with the current line is refused.
# A crash after Mr Beanz returns a capture_id and before the receipt lands can
# duplicate that thought on replay.
# Never describe this path as exactly-once, at-least-once, no-loss, or lossless.
#
# SOURCE NAMES written to the brain:
#   firstmate-telegram         captain chat
#   firstmate-telegram-group   other chats, only when group capture is on
#
# FM_BEANZ_CAPTURE_TIMEOUT defaults to 30 seconds.
# FM_TELEGRAM_BRAIN_CAPTURE_FAILPOINT=before-receipt exists only for tests.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
ENGINE="$SCRIPT_DIR/fm_telegram_brain_capture.py"

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
  local result=${1-} adapter
  [ "$#" -eq 1 ] || usage
  [ -n "$result" ] || usage
  adapter=$(find_telegram_adapter) \
    || die "telegram interrupt adapter is not in this checkout; capture JSON lines with: fm-telegram-brain-capture.sh capture -"
  set -o pipefail
  "$adapter" messages "$result" | run_engine capture
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
