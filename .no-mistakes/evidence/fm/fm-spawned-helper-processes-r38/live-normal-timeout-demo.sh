#!/usr/bin/env bash
# Live product demo: normal timeout exit codes and TERM->KILL escalation preserved.
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29X96Q8GBCS5NB92S2S7GWB"
EVID="/home/rich/.no-mistakes/evidence/01M29X96Q8GBCS5NB92S2S7GWB"
LOG="$EVID/live-normal-timeout.log"
. "$ROOT/bin/fm-timeout-lib.sh"

exec > >(tee "$LOG") 2>&1
echo "=== LIVE normal timeout behavior $(date -Iseconds) ==="
echo "Default mechanism: $(fm_timeout_mechanism)"

# Natural exit 137 preserved
status=0
fm_run_timed 5 bash -c 'exit 137' || status=$?
echo "Natural exit 137 -> status=$status (expect 137)"
[ "$status" -eq 137 ] || exit 1

# TERM-resistant process gets 124 on default external path
status=0
fm_run_timed 1 perl -e '$SIG{TERM}="IGNORE"; sleep 600' || status=$?
echo "TERM-resistant 1s bound -> status=$status (expect 124)"
[ "$status" -eq 124 ] || exit 1

# Bash fallback same contracts
status=0
FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 2 bash -c 'exit 137' || status=$?
echo "Bash fallback exit 137 -> status=$status (expect 137)"
[ "$status" -eq 137 ] || exit 1

status=0
FM_TIMEOUT_MECHANISM_OVERRIDE=bash fm_run_timed 1 perl -e '$SIG{TERM}="IGNORE"; sleep 600' || status=$?
echo "Bash fallback TERM-resistant -> status=$status (expect 124)"
[ "$status" -eq 124 ] || exit 1

echo "PASS: normal timeout exit-status and escalation behavior preserved"
