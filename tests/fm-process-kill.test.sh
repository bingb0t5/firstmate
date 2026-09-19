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

if ! "$GUARD" --signal TERM --pid "$victim"; then
  kill -KILL "$victim" 2>/dev/null || true
  fail 'explicit recorded PID must be terminable'
fi
if wait "$victim"; then
  fail 'terminated process unexpectedly exited successfully'
fi
pass 'explicit recorded PID is terminable'

# Keep the repository audit executable: a future broad kill in bin/ must fail
# this focused suite instead of relying on a reviewer to notice it.
if grep -RInE '(^|[;&|[:space:]])(pkill|killall)([[:space:]]|$)' bin --include='*.sh' \
  | sed -E 's/^[[:space:]]*#.*$//; s/[[:space:]]+#.*$//' | grep -q .; then
  fail 'bin scripts must not introduce raw pkill or killall commands'
fi
pass 'bin audit contains no raw broad kill commands'
