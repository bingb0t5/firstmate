#!/usr/bin/env bash
# fm-home-wake.sh - Codex secondmate home notification callback.
# Usage: fm-home-wake.sh <backend> <target> [notify-json]
#        fm-home-wake.sh <backend> <target> --watcher-complete <launch-dir>
# The endpoint is bound by fm-spawn.sh; a supplied JSON payload must identify
# agent-turn-complete, and --watcher-complete delivers detached watcher completion.
# docs/turnend-guard.md owns the delivery and drain contract.
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
  [ -f "$COMPLETION_DIR/accepted" ] || exit 1
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
home_defer() {
  [ -z "$COMPLETION_DIR" ] && exit 0
  exit 75
}

home_finish() {
  if [ -n "$COMPLETION_DIR" ]; then
    printf '%s\n' "$1" > "$COMPLETION_DIR/notification.tmp.$$" \
      && mv -f "$COMPLETION_DIR/notification.tmp.$$" "$COMPLETION_DIR/notification" || exit 1
  fi
  exit 0
}

fm_root_is_secondmate_home "$FM_HOME" || home_finish superseded
home_session_owned || home_finish superseded
[ ! -e "$STATE/.afk" ] || home_defer

LOCK="$STATE/.home-wake.lock"
fm_lock_try_acquire "$LOCK" || home_defer
OUT=
# shellcheck disable=SC2329 # Registered by the EXIT trap below.
cleanup() {
  [ -z "$OUT" ] || rm -f "$OUT"
  fm_lock_release "$LOCK"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM
home_session_owned || home_finish superseded
[ ! -L "$FM_WAKE_QUEUE" ] || home_defer
[ -s "$FM_WAKE_QUEUE" ] || home_finish settled
FAILURE=0
if [ -n "$COMPLETION_DIR" ] && { [ "$LAUNCH_STATUS" -ne 0 ] || [ -z "$LAUNCH_REASON" ]; }; then
  FAILURE=1
fi
fm_watch_config_load "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/watch.env"
if [ "$FAILURE" -eq 0 ] && ! fm_watcher_lock_unheld "$STATE"; then
  fm_watcher_healthy "$STATE" "$SCRIPT_DIR/fm-watch.sh" "${FM_GUARD_GRACE:-300}" "$FM_HOME" && home_defer
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

home_ready || home_defer
if [ "$FAILURE" -eq 0 ]; then
  OUT=$(mktemp "$STATE/.home-wake-output.XXXXXX") || exit 1
  if ! "$SCRIPT_DIR/fm-watch-checkpoint.sh" --seconds 30 > "$OUT" 2>&1; then
    [ -s "$FM_WAKE_QUEUE" ] || home_finish settled
    cat "$OUT" >&2
    FAILURE=1
  fi
  if [ "$FAILURE" -eq 0 ]; then
    grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$OUT" || home_defer
  fi
fi
home_ready || home_defer
[ -s "$FM_WAKE_QUEUE" ] || home_finish settled
MESSAGE="Queued home wakes are waiting. Run bin/fm-wake-drain.sh first, handle the queued wakes and unread status context, then run the exact WAKE_ACK_REQUIRED acknowledgement command printed by the drain."
if [ "$FAILURE" -eq 1 ]; then
  MESSAGE="Watcher supervision failed. Inspect watcher recovery before relying on unattended supervision. $MESSAGE"
fi
fm_operational_input_encode watcher "$MESSAGE" ENCODED || exit 1
home_ready || home_defer
[ -s "$FM_WAKE_QUEUE" ] || home_finish settled
VERDICT=$(fm_backend_send_text_submit "$BACKEND" "$TARGET" "$ENCODED" 3 0.2 0.2) || VERDICT=unknown
[ "$VERDICT" = empty ] && home_finish delivered
printf 'home wake: submit unconfirmed; durable wakes remain unacknowledged\n' >&2
exit 1
