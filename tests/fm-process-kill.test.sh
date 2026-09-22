#!/usr/bin/env bash
# shellcheck disable=SC1091
# The exact-target process termination guard must reject the incident's
# broad-pattern shape and still terminate an explicitly recorded own PID.
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

setsid sleep 30 &
group_victim=$!
if ! "$GUARD" --signal TERM --group "$group_victim"; then
  kill -KILL "$group_victim" 2>/dev/null || true
  fail 'explicit recorded PGID must be terminable'
fi
if wait "$group_victim"; then
  fail 'terminated process group unexpectedly exited successfully'
fi
pass 'explicit recorded PGID is terminable'

if ! "$GUARD" --signal TERM --pid "$victim"; then
  kill -KILL "$victim" 2>/dev/null || true
  fail 'explicit recorded PID must be terminable'
fi
if wait "$victim"; then
  fail 'terminated process unexpectedly exited successfully'
fi
pass 'explicit recorded PID is terminable'
