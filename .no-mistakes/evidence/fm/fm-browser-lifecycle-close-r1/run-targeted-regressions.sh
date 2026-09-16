#!/usr/bin/env bash
# Focused regression execution for the lifecycle files changed by this branch.
set -u

ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M2KY50B7PWS448F9CDC2399F
EVIDENCE=/home/rich/.no-mistakes/evidence/01M2KY50B7PWS448F9CDC2399F
TMPDIR=$(mktemp -d /tmp/fm-gate-targeted.XXXXXX)
export TMPDIR
LOG="$EVIDENCE/targeted-regressions.log"
DONE="$EVIDENCE/targeted-regressions.done"
rm -f -- "$DONE"
exec >"$LOG" 2>&1

overall=0
for test_file in \
  tests/fm-browser-lifecycle.test.sh \
  tests/fm-teardown-endpoint-safety.test.sh \
  tests/fm-control-relaunch.test.sh \
  tests/fm-brief.test.sh; do
  "$ROOT/$test_file"
  rc=$?
  printf '%s exit=%s\n' "$test_file" "$rc"
  [ "$rc" -eq 0 ] || overall=1
done
printf 'targeted_regressions_overall=%s\n' "$overall"
: > "$DONE"
exit "$overall"
