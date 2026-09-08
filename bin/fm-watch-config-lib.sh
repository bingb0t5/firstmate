#!/usr/bin/env bash
# fm-watch-config-lib.sh - safe optional watcher defaults from a home-local file.
#
# config/watch.env is a non-executable, gitignored defaults file for watcher
# cadence and other FM_* pins. It is parsed as KEY=VALUE data, never sourced as
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
    if [ "${!key+x}" != x ]; then
      export "$key=$value"
    fi
  done < "$file"
}
