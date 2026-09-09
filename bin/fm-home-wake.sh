#!/usr/bin/env bash
# fm-home-wake.sh - Codex secondmate home notification callback.
# Usage: fm-home-wake.sh <backend> <target> [notify-json]
# The endpoint is bound by fm-spawn.sh; a supplied JSON payload must identify
# agent-turn-complete. docs/turnend-guard.md owns the delivery and drain contract.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-primary-scope-lib.sh
. "$SCRIPT_DIR/fm-primary-scope-lib.sh"
# shellcheck source=bin/fm-session-lock-lib.sh
. "$SCRIPT_DIR/fm-session-lock-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-composer-lib.sh
. "$SCRIPT_DIR/fm-composer-lib.sh"
# shellcheck source=bin/fm-operational-input.sh
. "$SCRIPT_DIR/fm-operational-input.sh"
# shellcheck source=bin/fm-watch-config-lib.sh
. "$SCRIPT_DIR/fm-watch-config-lib.sh"

[ "$#" -ge 2 ] || { printf 'usage: fm-home-wake.sh <backend> <target> [notify-json]\n' >&2; exit 2; }
BACKEND=$1
TARGET=$2
COMPLETION_DIR=
if [ "${3:-}" = --watcher-complete ]; then
  [ "$#" -eq 4 ] || exit 2
  COMPLETION_DIR=$4
  # shellcheck source=bin/fm-watch-launch-lib.sh
  . "$SCRIPT_DIR/fm-watch-launch-lib.sh"
  fm_watch_launch_read "$COMPLETION_DIR" && fm_watch_launch_result "$COMPLETION_DIR" || exit 1
  fm_watch_launch_owner "$COMPLETION_DIR" || exit 1
  fm_watch_launch_session "$COMPLETION_DIR" || exit 1
  [ "$LAUNCH_BACKEND" = "$BACKEND" ] && [ "$LAUNCH_TARGET" = "$TARGET" ] || exit 1
elif [ -n "${3:-}" ]; then
  printf '%s' "$3" | jq -e '.type == "agent-turn-complete"' >/dev/null 2>&1 || exit 0
fi
home_session_owned() {
  if [ -z "$COMPLETION_DIR" ]; then
    fm_session_lock_owned_by_self "$STATE"
    return $?
  fi
  [ "$(cat "$STATE/.lock" 2>/dev/null)" = "$LAUNCH_SESSION_PID" ] || return 1
  [ "$(fm_pid_identity "$LAUNCH_SESSION_PID" 2>/dev/null || true)" = "$LAUNCH_SESSION_IDENTITY" ]
}
fm_root_is_secondmate_home "$FM_HOME" || exit 0
home_session_owned || exit 0
[ ! -e "$STATE/.afk" ] || exit 0
[ -s "$FM_WAKE_QUEUE" ] && [ ! -L "$FM_WAKE_QUEUE" ] || exit 0

LOCK="$STATE/.home-wake.lock"
fm_lock_try_acquire "$LOCK" || exit 0
OUT=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  [ -z "$OUT" ] || rm -f "$OUT"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
fm_watch_config_load "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/watch.env"
if ! fm_watcher_lock_unheld "$STATE"; then
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" && exit 0
  if [ -z "$COMPLETION_DIR" ] \
    || [ "$(cat "$STATE/.watch.lock/pid" 2>/dev/null)" != "$LAUNCH_PID" ] \
    || [ "$(cat "$STATE/.watch.lock/pid-identity" 2>/dev/null)" != "$LAUNCH_IDENTITY" ]; then
    printf 'home wake: watcher ownership unhealthy; durable wakes remain unacknowledged\n' >&2
    exit 1
  fi
fi

home_ready() {
  local pane
  home_session_owned || return 1
  [ ! -e "$STATE/.afk" ] || return 1
  fm_backend_target_exists "$BACKEND" "$TARGET" || return 1
  [ "$(fm_backend_busy_state "$BACKEND" "$TARGET" 2>/dev/null)" != busy ] || return 1
  pane=$(fm_backend_capture "$BACKEND" "$TARGET" 40 2>/dev/null) || return 1
  if printf '%s' "$pane" | grep -v '^[[:space:]]*$' | tail -12 | fm_busy_lines_match codex; then
    return 1
  fi
  [ "$(fm_backend_composer_state "$BACKEND" "$TARGET" 2>/dev/null)" = empty ]
}

home_ready || exit 0
OUT=$(mktemp "$STATE/.home-wake-output.XXXXXX") || exit 1
if ! "$SCRIPT_DIR/fm-watch-checkpoint.sh" --seconds 30 > "$OUT" 2>&1; then
  [ -s "$FM_WAKE_QUEUE" ] || exit 0
  cat "$OUT" >&2
  exit 1
fi
grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" || exit 0
home_ready || exit 0
[ -s "$FM_WAKE_QUEUE" ] || exit 0
MESSAGE="Queued home wakes are waiting. Run bin/fm-wake-drain.sh first, handle the queued wakes and unread status context, then run the exact WAKE_ACK_REQUIRED acknowledgement command printed by the drain."
fm_operational_input_encode watcher "$MESSAGE" ENCODED || exit 1
home_ready || exit 0
[ -s "$FM_WAKE_QUEUE" ] || exit 0
VERDICT=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$ENCODED" 3 0.2 0.2) || VERDICT=unknown
[ "$VERDICT" = empty ] && exit 0
printf 'home wake: submit unconfirmed; durable wakes remain unacknowledged\n' >&2
exit 1
