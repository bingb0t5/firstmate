#!/usr/bin/env bash
# Focused runner for owner-death timeout regression tests only.
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29X96Q8GBCS5NB92S2S7GWB"
LOG="/home/rich/.no-mistakes/evidence/01M29X96Q8GBCS5NB92S2S7GWB/timeout-regression-output.log"
exec > >(tee "$LOG") 2>&1

echo "=== Focused timeout regression run $(date -Iseconds) ==="
echo "Host default mechanism: $(bash -c ". \"$ROOT/bin/fm-timeout-lib.sh\"; fm_timeout_mechanism")"

PARTIAL=$(mktemp)
sed -n '1,2841p' "$ROOT/tests/fm-session-start.test.sh" > "$PARTIAL"
# Fix lib sourcing: partial lives in /tmp so dirname would be wrong.
sed -i "s|. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/lib.sh\"|. \"$ROOT/tests/lib.sh\"|" "$PARTIAL"
sed -i "s|. \"\$(dirname \"\${BASH_SOURCE\[0\]}\")/wake-helpers.sh\"|. \"$ROOT/tests/wake-helpers.sh\"|" "$PARTIAL"
cat >> "$PARTIAL" <<'TESTS'
test_portable_timeout_escalates_term_resistant_process
test_abnormal_parent_does_not_leave_real_helper_descendants
test_runtime_bound_truncates_loudly_and_exits_zero
echo "# focused timeout regression: all assertions passed"
TESTS

bash "$PARTIAL"
rc=$?
rm -f "$PARTIAL"
exit $rc
