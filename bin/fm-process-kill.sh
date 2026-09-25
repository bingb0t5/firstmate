#!/usr/bin/env bash
# Exact-target process termination guard.
#
# Shared hosts run several Firstmate homes under one OS user. Never use
# `pkill -f`, `killall`, `killall5`, `skill`, or `fuser -k` there: matching a
# name, pattern, or resource belongs to no particular invocation. Call this
# helper with the PID or PGID the caller itself recorded, plus the identity
# fingerprint it captured for that same target at record time. It rejects
# patterns, names, empty targets, non-numeric targets, ambiguous target
# selection, and a target whose live identity no longer matches what the
# caller recorded - the same PID-reuse discipline bin/fm-wake-lib.sh's
# fm_pid_identity, bin/fm-teardown.sh's task_process_identity, and
# bin/fm-browser-lifecycle-lib.sh's fm_browser_process_identity already apply
# elsewhere in this repo. The fingerprint format is intentionally identical to
# fm_pid_identity, so a caller that already computed one when it recorded the
# PID or PGID can pass it straight through unchanged.
#
# Usage:
#   identity=$(bin/fm-process-kill.sh --print-identity 12345)  # capture at record time
#   bin/fm-process-kill.sh --signal TERM --pid 12345 --identity "$identity"
#   bin/fm-process-kill.sh --signal KILL --group 12345 --identity "$identity"
#
# `--identity` must be the exact fingerprint the caller captured for that PID
# (or, for `--group`, for the process-group leader whose PID equals the PGID)
# at the moment it recorded the target - never a value read from any other
# source or supplied without ever having observed the live process. A
# mismatch means the recorded process is gone and something else, possibly
# an unrelated sibling worktree's process, now holds that PID or PGID; the
# helper refuses to signal it rather than trust a bare caller-supplied number.
# Identity matching only defends against PID or PGID reuse after a genuine
# record-time capture. It does not prove that the caller started or owns the
# target, so callers must invoke `--print-identity` only for a PID or PGID
# they just recorded through their own process-management flow, never an
# arbitrary or probed target.
# Identity verification and signaling are separate operations. A verified
# PID or PGID can exit and be reused by an unrelated process between the
# identity check and signal. This narrows the pre-existing no-identity-check
# window but does not eliminate it; closing it requires an atomic OS-backed
# handle such as a Linux pidfd, which is outside this helper's scope.
set -u

signal=TERM
pid=
group=
identity=
print_identity=

usage() {
  cat <<'EOF'
Usage: fm-process-kill.sh --print-identity PID
       fm-process-kill.sh [--signal SIGNAL] (--pid PID | --group PGID) --identity IDENTITY

Terminate one explicitly recorded process or process group. Pattern/name
selection is intentionally unsupported; use the recorded PID or PGID from the
owning invocation's state instead.

--print-identity PID prints that PID's current identity fingerprint so a
caller can capture it at record time. --identity IDENTITY must equal the
target's live fingerprint at kill time (the PGID leader's fingerprint for
--group); a mismatch is refused without signaling anything. Identity matching
only defends against target reuse after genuine record-time capture; it does
not prove the caller started or owns a target. Only call --print-identity for
a PID or PGID the caller just recorded through its own process-management
flow, never an arbitrary or probed target.
Identity verification and signaling are separate operations, so a verified
PID or PGID can exit and be reused by an unrelated process between the
identity check and signal. This narrows the pre-existing no-identity-check
window but does not eliminate it; closing it requires an atomic OS-backed
handle such as a Linux pidfd, which is outside this helper's scope.
EOF
}

error() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

require_positive_int() {  # <label> <value>
  local label=$1 value=$2
  case "$value" in
    ''|*[!0-9]*) error "$label must be a positive integer" ;;
  esac
  case "$value" in
    *[1-9]*) ;;
    *) error "$label must be a positive non-zero integer" ;;
  esac
}

# Uses the fm_pid_identity format from bin/fm-wake-lib.sh so identities
# captured by either implementation compare equal. Kept as its own copy
# rather than sourced: this helper must stay a dependency-free, side-effect-
# free primitive callable from any context, matching the existing per-
# subsystem copies in fm-teardown.sh and fm-browser-lifecycle-lib.sh.
process_identity() {  # <pid>
  local pid=$1 out stat_line starttime cmdline_hex identity_key uname_out
  local -a stat_fields
  if [ -r "/proc/$pid/stat" ] && [ -r "/proc/$pid/cmdline" ]; then
    stat_line=$(command cat "/proc/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in
      ''|*[!0-9]*) return 1 ;;
    esac
    cmdline_hex=$(od -An -v -tx1 "/proc/$pid/cmdline" 2>/dev/null | tr -d '[:space:]') || return 1
    [ -n "$cmdline_hex" ] || return 1
    uname_out=$(uname 2>/dev/null || echo unknown)
    identity_key=proc-starttime
    [ "$uname_out" != Linux ] || identity_key=linux-starttime
    printf '%s=%s cmdline-hex=%s\n' "$identity_key" "$starttime" "$cmdline_hex"
    return 0
  fi
  out=$(LC_ALL=C ps -p "$pid" -o lstart= -o command= 2>/dev/null) || return 1
  [ -n "$out" ] || return 1
  printf '%s\n' "$out" | sed 's/^[[:space:]]*//'
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
    --identity)
      [ "$#" -gt 1 ] || error '--identity requires a value'
      [ -z "$identity" ] || error '--identity may be supplied only once'
      identity=$2
      shift 2
      ;;
    --print-identity)
      [ "$#" -gt 1 ] || error '--print-identity requires a PID value'
      [ -z "$print_identity" ] || error '--print-identity may be supplied only once'
      print_identity=$2
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

if [ -n "$print_identity" ]; then
  [ -z "$pid" ] && [ -z "$group" ] && [ -z "$identity" ] ||
    error '--print-identity cannot be combined with --pid, --group, or --identity'
  require_positive_int PID "$print_identity"
  process_identity "$print_identity" || error 'no readable process with that PID; nothing to record'
  exit 0
fi

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
  require_positive_int PID "$pid"
  [ -n "$identity" ] || error 'an exact --identity captured at record time is required to verify PID ownership'
  current=$(process_identity "$pid" 2>/dev/null) || error 'recorded PID is no longer running or cannot be verified'
  [ "$current" = "$identity" ] ||
    error 'recorded PID identity no longer matches the live process; refusing to signal a possibly reused PID'
  kill -s "$signal" -- "$pid"
  exit $?
fi

if [ -n "$group" ]; then
  require_positive_int PGID "$group"
  [ -n "$identity" ] || error 'an exact --identity captured at record time is required to verify PGID ownership'
  current=$(process_identity "$group" 2>/dev/null) || error 'recorded PGID leader is no longer running or cannot be verified'
  [ "$current" = "$identity" ] ||
    error 'recorded PGID leader identity no longer matches the live process; refusing to signal a possibly reused PGID'
  kill -s "$signal" -- "-$group"
  exit $?
fi

error 'an exact --pid or --group target is required'
