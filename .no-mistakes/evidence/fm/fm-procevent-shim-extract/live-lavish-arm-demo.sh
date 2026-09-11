#!/usr/bin/env bash
# Product-level adapter arm exercise using the installed lavish-axi CLI.
set -euo pipefail
ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M27E4697X1ZFPE605XT0BRG3
CASE=/home/rich/.no-mistakes/evidence/01M27E4697X1ZFPE605XT0BRG3/live-lavish-arm-case
rm -rf "$CASE"
mkdir -p "$CASE/home/state" "$CASE/claims"
printf '<main>Live adapter arm evidence</main>\n' > "$CASE/review.html"
export FM_HOME="$CASE/home"
export FM_PROCEVENT_CLAIM_ROOT="$CASE/claims"
echo '== arm a real Lavish adapter artifact =='
"$ROOT/bin/fm-procevent-lavish.sh" arm "$CASE/review.html"
echo '== generic runner sees the adapter registration =='
"$ROOT/bin/fm-procevent.sh" list
id=$("$ROOT/bin/fm-procevent-lavish.sh" source-id "$CASE/review.html")
echo '== adapter retirement =='
"$ROOT/bin/fm-procevent-lavish.sh" retire "$CASE/review.html"
"$ROOT/bin/fm-procevent.sh" list
