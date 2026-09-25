#!/usr/bin/env bash
# shellcheck disable=SC1091
# The exact-target process termination guard must reject the incident's
# broad-pattern shape, refuse a target whose recorded identity does not match
# what is actually running, and still terminate an explicitly recorded own
# PID or PGID whose identity checks out. Every assertion drives the public
# `bin/fm-process-kill.sh` CLI end to end; none inspect source bytes.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GUARD="$ROOT/bin/fm-process-kill.sh"
TMP_ROOT=$(fm_test_tmproot fm-process-kill)
ERR="$TMP_ROOT/error"

if "$GUARD" --pattern 'tsx server.ts' >"$TMP_ROOT/out" 2>"$ERR"; then
  fail 'pattern-based termination must be refused'
fi
grep -F 'pattern/name targets are refused' "$ERR" >/dev/null ||
  fail 'pattern refusal must explain the exact-target requirement'
pass 'broad pattern target is refused'

sleep 30 &
victim=$!
if "$GUARD" --pid "$victim" --group 1 >/dev/null 2>"$ERR"; then
  kill -KILL "$victim" 2>/dev/null || true
  fail 'ambiguous process/group target must be refused'
fi
grep -F 'process and group targets are mutually exclusive' "$ERR" >/dev/null ||
  fail 'ambiguous target refusal must explain the conflicting target modes'
kill -0 "$victim" 2>/dev/null || fail 'ambiguous target refusal must preserve the live process'
pass 'ambiguous target is refused without signaling the process'

for target in 0 00 000; do
  if "$GUARD" --pid "$target" >/dev/null 2>"$ERR"; then
    kill -KILL "$victim" 2>/dev/null || true
    fail "all-zero PID spelling '$target' must be refused"
  fi
  grep -F 'PID must be a positive non-zero integer' "$ERR" >/dev/null ||
    fail "all-zero PID spelling '$target' must explain the refusal"
done
kill -0 "$victim" 2>/dev/null || fail 'all-zero PID refusal must preserve the live process'
pass 'all-zero PID spellings are refused without signaling the process'

for signal in 0 00 000 +0 +00 -0 -000; do
  if "$GUARD" --signal "$signal" --pid "$victim" >/dev/null 2>"$ERR"; then
    kill -KILL "$victim" 2>/dev/null || true
    fail "zero signal spelling '$signal' must be refused"
  fi
  grep -F 'signal must not be zero' "$ERR" >/dev/null ||
    fail "zero signal spelling '$signal' must explain the non-terminating mode"
done
kill -0 "$victim" 2>/dev/null || fail 'zero signal refusal must preserve the live process'
pass 'zero signal spellings are refused without signaling the process'

if "$GUARD" --signal TERM --pid "$victim" >/dev/null 2>"$ERR"; then
  kill -KILL "$victim" 2>/dev/null || true
  fail 'a bare recorded PID without --identity must be refused'
fi
grep -F 'an exact --identity' "$ERR" >/dev/null ||
  fail 'missing-identity refusal must explain that an exact recorded identity is required'
kill -0 "$victim" 2>/dev/null || fail 'missing-identity refusal must preserve the live process'
pass 'a recorded PID without its captured identity is refused without signaling the process'

if "$GUARD" --signal TERM --pid "$victim" --identity 'linux-starttime=1 cmdline-hex=00' >/dev/null 2>"$ERR"; then
  kill -KILL "$victim" 2>/dev/null || true
  fail 'a stale/mismatched --identity must be refused'
fi
grep -F 'no longer matches the live process' "$ERR" >/dev/null ||
  fail 'stale-identity refusal must explain the mismatch'
kill -0 "$victim" 2>/dev/null || fail 'stale-identity refusal must preserve the live process'
pass 'a mismatched recorded identity is refused without signaling the process'

if "$GUARD" --print-identity "$victim" --pid "$victim" >/dev/null 2>"$ERR"; then
  kill -KILL "$victim" 2>/dev/null || true
  fail '--print-identity combined with --pid must be refused'
fi
grep -F 'cannot be combined' "$ERR" >/dev/null ||
  fail 'combined-mode refusal must explain --print-identity is a standalone mode'
pass '--print-identity cannot be combined with a kill-mode flag'

dead_pid=$$
while kill -0 "$dead_pid" 2>/dev/null; do dead_pid=$((dead_pid + 1)); done
if "$GUARD" --print-identity "$dead_pid" >/dev/null 2>"$ERR"; then
  fail '--print-identity for a non-running PID must be refused'
fi
grep -F 'no readable process' "$ERR" >/dev/null ||
  fail 'unreadable-PID refusal must explain nothing was recorded'
pass '--print-identity for a non-running PID is refused'

setsid sleep 30 &
group_victim=$!
group_identity=$("$GUARD" --print-identity "$group_victim") ||
  fail 'capturing the recorded PGID leader identity must succeed for a live process group'
if ! "$GUARD" --signal TERM --group "$group_victim" --identity "$group_identity"; then
  kill -KILL "$group_victim" 2>/dev/null || true
  fail 'a recorded PGID with its matching captured identity must be terminable'
fi
if wait "$group_victim"; then
  fail 'terminated process group unexpectedly exited successfully'
fi
pass 'a recorded PGID whose captured identity matches is terminable'

victim_identity=$("$GUARD" --print-identity "$victim") ||
  fail 'capturing the recorded PID identity must succeed for a live process'
if ! "$GUARD" --signal TERM --pid "$victim" --identity "$victim_identity"; then
  kill -KILL "$victim" 2>/dev/null || true
  fail 'a recorded PID with its matching captured identity must be terminable'
fi
if wait "$victim"; then
  fail 'terminated process unexpectedly exited successfully'
fi
pass 'a recorded PID whose captured identity matches is terminable'
