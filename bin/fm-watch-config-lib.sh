#!/usr/bin/env bash
# fm-watch-config-lib.sh - safe optional watcher defaults from a home-local file.
#
# config/watch.env is a non-executable, gitignored defaults file for watcher
# numeric watcher pins. It is parsed as KEY=VALUE data, never sourced as
# shell, so a malformed or hostile line cannot run code in the watcher.
# Environment variables already present in the caller win over file values.

fm_watch_config_load() {  # <watch-env-file>
  local file=$1 line key value trimmed
  [ -f "$file" ] && [ ! -L "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%$'\r'}
    trimmed=${line#"${line%%[![:space:]]*}"}
    [ -n "$trimmed" ] || continue
    case "$trimmed" in
      \#*) continue ;;
      export[[:space:]]*) trimmed=${trimmed#export}; trimmed=${trimmed#"${trimmed%%[![:space:]]*}"} ;;
    esac
    case "$trimmed" in
      FM_[A-Za-z0-9_]*=*) ;;
      *) continue ;;
    esac
    key=${trimmed%%=*}
    value=${trimmed#*=}
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    case "$value" in
      \"*\") value=${value#\"}; value=${value%\"} ;;
      \'*\') value=${value#\'}; value=${value%\'} ;;
    esac
    case "$key" in
      FM_*[!A-Za-z0-9_]*|FM_) continue ;;
    esac
    case "$key" in
      FM_ARM_ATTACH_POLL)
        [[ "$value" =~ ^(0|[1-9][0-9]{0,8})([.][0-9]{1,6})?$ ]] || continue
        ;;
      FM_POLL|FM_HEARTBEAT|FM_HEARTBEAT_MAX|FM_CHECK_INTERVAL|FM_CHECK_TIMEOUT|FM_SIGNAL_GRACE|FM_GUARD_GRACE|FM_WATCHER_STALE_GRACE|FM_ARM_CONFIRM_TIMEOUT|FM_WATCH_CYCLE_LOG_MAX_BYTES|FM_WATCH_CYCLE_LOG_KEEP_LINES|FM_STALE_ESCALATE_SECS|FM_BUSY_TURN_MAX_SECS|FM_PAUSE_RESURFACE_SECS|FM_SECONDMATE_WAKE_STALL_SECS|FM_SECONDMATE_WAKE_STALL_GRACE_SECS|FM_GROK_NOTIFY_CADENCE_SECS|FM_PI_BRANCH_CLAIM_CADENCE_SECS|FM_EVENT_CAP_FAIL_MAX|FM_WEDGE_DEMAND_INSPECT_COUNT)
        [[ "$value" =~ ^(0|[1-9][0-9]{0,8})$ ]] || continue
        ;;
      *) continue ;;
    esac
    if [ "${!key+x}" != x ]; then
      export "$key=$value"
    fi
  done < "$file"
}
