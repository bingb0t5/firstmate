#!/usr/bin/env bash
# Public compatibility and malformed-arm CLI exercise.
set -euo pipefail
ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M27E4697X1ZFPE605XT0BRG3
CASE=/home/rich/.no-mistakes/evidence/01M27E4697X1ZFPE605XT0BRG3/live-register-compat-case
rm -rf "$CASE"
mkdir -p "$CASE/home/state" "$CASE/guard-home/state" "$CASE/claims"
echo '== register compatibility spelling =='
FM_HOME="$CASE/home" FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" "$ROOT/bin/fm-procevent.sh" register lavish compat-source -- /bin/printf 'compatibility payload\n'
echo '== registered source runs through the same capture interface =='
FM_HOME="$CASE/home" FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" "$ROOT/bin/fm-procevent.sh" start compat-source
find "$CASE/home/state/procevent-inbox" -name 'compat-source.*.result' -type f -exec sh -c 'printf "captured: "; tr "\n" " " < "$1"; printf "\n"' _ {} \;
echo '== malformed arm is rejected before registration =='
set +e
FM_HOME="$CASE/guard-home" FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" "$ROOT/bin/fm-procevent.sh" arm lavish rejected -- > "$CASE/guard.out" 2>&1
rc=$?
set -e
printf 'exit=%s\n' "$rc"
sed 's/^/error: /' "$CASE/guard.out"
FM_HOME="$CASE/guard-home" FM_PROCEVENT_CLAIM_ROOT="$CASE/claims" "$ROOT/bin/fm-procevent.sh" list
[ "$rc" -ne 0 ]
