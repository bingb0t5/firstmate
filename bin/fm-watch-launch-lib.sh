#!/usr/bin/env bash
# Shared detached watcher launch helpers for fm-watch-arm.sh and fm-home-wake.sh.
# docs/watcher-continuity.md owns the arm-layer launch records; docs/turnend-guard.md
# owns the Stop-side detached contract.

fm_watch_launch_record() {
  local dir=$1 status=$2 reason=$3 tmp
  tmp="$dir/result.tmp.${BASHPID:-$$}"
  printf '%s\t%s\t%s\t%s\n' "$WATCH_LAUNCH_PID" "$WATCH_LAUNCH_IDENTITY" "$status" "$reason" > "$tmp" \
    && mv -f "$tmp" "$dir/result"
}

fm_watch_launch_begin() {
  WATCH_LAUNCH_DIR=$FM_WATCH_LAUNCH_DIR
  unset FM_WATCH_LAUNCH_DIR
  WATCH_LAUNCH_PID=${BASHPID:-$$}
  WATCH_LAUNCH_IDENTITY=$(fm_pid_identity "$WATCH_LAUNCH_PID") || return 1
  printf '%s\t%s\n' "$WATCH_LAUNCH_PID" "$WATCH_LAUNCH_IDENTITY" > "$WATCH_LAUNCH_DIR/identity.tmp" \
    && mv -f "$WATCH_LAUNCH_DIR/identity.tmp" "$WATCH_LAUNCH_DIR/identity"
}

fm_watch_launch_read() {
  local dir=$1
  case "$dir" in "$STATE"/.watch-arm-detached.*) ;; *) return 1 ;; esac
  case "${dir#"$STATE"/.watch-arm-detached.}" in ''|*/*) return 1 ;; esac
  [ -d "$dir" ] && [ ! -L "$dir" ] || return 1
  [ -s "$dir/identity" ] || return 1
  IFS=$'\t' read -r LAUNCH_PID LAUNCH_IDENTITY < "$dir/identity" || return 1
  case "$LAUNCH_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$LAUNCH_IDENTITY" ]
}

fm_watch_launch_result() {
  local dir=$1 pid identity
  # shellcheck disable=SC2034 # LAUNCH_REASON is consumed by the calling owner.
  IFS=$'\t' read -r pid identity LAUNCH_STATUS LAUNCH_REASON < "$dir/result" || return 1
  [ "$pid" = "$LAUNCH_PID" ] && [ "$identity" = "$LAUNCH_IDENTITY" ] || return 1
  case "$LAUNCH_STATUS" in ''|*[!0-9]*) return 1 ;; esac
}

fm_watch_launch_owner() {
  local dir=$1
  [ -s "$dir/owner" ] || return 1
  IFS=$'\t' read -r LAUNCH_OWNER_PID LAUNCH_OWNER_IDENTITY < "$dir/owner" || return 1
  case "$LAUNCH_OWNER_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$LAUNCH_OWNER_IDENTITY" ] || return 1
  [ "$(fm_pid_identity "$LAUNCH_OWNER_PID" 2>/dev/null || true)" = "$LAUNCH_OWNER_IDENTITY" ]
}

fm_watch_launch_retire() {
  local dir=$1 i
  fm_watch_launch_owner "$dir" || return 0
  kill -TERM "$LAUNCH_OWNER_PID" 2>/dev/null || return 0
  for ((i = 0; i < 20; i++)); do
    fm_watch_launch_owner "$dir" || return 0
    sleep 0.1
  done
  return 1
}

fm_watch_launch_session() {
  local dir=$1
  [ -s "$dir/session" ] || return 1
  IFS=$'\t' read -r LAUNCH_SESSION_PID LAUNCH_SESSION_IDENTITY LAUNCH_BACKEND LAUNCH_TARGET < "$dir/session" || return 1
  case "$LAUNCH_SESSION_PID" in ''|*[!0-9]*) return 1 ;; esac
  [ -n "$LAUNCH_SESSION_IDENTITY" ] && [ -n "$LAUNCH_BACKEND" ] && [ -n "$LAUNCH_TARGET" ]
}
