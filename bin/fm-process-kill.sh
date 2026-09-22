#!/usr/bin/env bash
# Exact-target process termination guard.
#
# Shared hosts run several Firstmate homes under one OS user. Never use
# `pkill -f`, `killall`, or another name/pattern-based kill there: a matching
# process belongs to no particular invocation. Call this helper with the
# specifically recorded PID or process-group ID instead. It rejects patterns,
# names, empty targets, non-numeric targets, and ambiguous target selection.
#
# Usage:
#   bin/fm-process-kill.sh --signal TERM --pid 12345
#   bin/fm-process-kill.sh --signal KILL --group 12345
#
# The caller owns recording and validating the PID identity. This helper only
# permits an explicit positive numeric target and performs no process lookup.
set -u

signal=TERM
pid=
group=

usage() {
  cat <<'EOF'
Usage: fm-process-kill.sh [--signal SIGNAL] (--pid PID | --group PGID)

Terminate one explicitly recorded process or process group. Pattern/name
selection is intentionally unsupported; use the recorded PID or PGID from the owning
invocation's state instead.
EOF
}

error() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --signal)
      [ "$#" -gt 1 ] || error '--signal requires a value'
      signal=$2
      shift 2
      ;;
    --pid)
      [ "$#" -gt 1 ] || error '--pid requires a value'
      [ -z "$pid" ] && [ -z "$group" ] || error 'process and group targets are mutually exclusive'
      pid=$2
      shift 2
      ;;
    --group)
      [ "$#" -gt 1 ] || error '--group requires a value'
      [ -z "$pid" ] && [ -z "$group" ] || error 'process and group targets are mutually exclusive'
      group=$2
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --pattern|--name|--match|-f)
      error 'pattern/name targets are refused; provide an exact recorded PID or PGID'
      ;;
    *)
      error "unknown argument or bare target '$1'; provide --pid or --group"
      ;;
  esac
done

case "$signal" in
  ''|*[!A-Za-z0-9_+-]*) error 'signal must be a signal name or number' ;;
esac

case "$signal" in
  *[!0]*) ;;
  *) error 'signal must not be zero' ;;
esac

case "$signal" in
  [+-]*)
    case "${signal#?}" in
      ''|*[!0-9]*) ;;
      *[1-9]*) ;;
      *) error 'signal must not be zero' ;;
    esac
    ;;
esac

if [ -n "$pid" ]; then
  case "$pid" in
    ''|*[!0-9]*) error 'PID must be a positive integer' ;;
  esac
  case "$pid" in
    *[1-9]*) ;;
    *) error 'PID must be a positive non-zero integer' ;;
  esac
  kill -s "$signal" -- "$pid"
  exit $?
fi

if [ -n "$group" ]; then
  case "$group" in
    ''|*[!0-9]*) error 'PGID must be a positive integer' ;;
  esac
  case "$group" in
    *[1-9]*) ;;
    *) error 'PGID must be a positive non-zero integer' ;;
  esac
  kill -s "$signal" -- "-$group"
  exit $?
fi

error 'an exact --pid or --group target is required'
