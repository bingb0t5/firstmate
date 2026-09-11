#!/usr/bin/env bash
# Product-level remote-reply adapter arm exercise; arming does not contact SSH.
set -euo pipefail
ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M27E4697X1ZFPE605XT0BRG3
CASE=/home/rich/.no-mistakes/evidence/01M27E4697X1ZFPE605XT0BRG3/live-remote-reply-arm-case
rm -rf "$CASE"
mkdir -p "$CASE/home/state" "$CASE/home/data" "$CASE/claims"
printf '%s\n' '- ios - iOS delivery (host: remote.example; root: /opt/firstmate; home: /var/fm; scope: iOS work; projects: alpha; added 2026-08-02)' > "$CASE/home/data/secondmates.md"
export FM_HOME="$CASE/home"
export FM_PROCEVENT_CLAIM_ROOT="$CASE/claims"
echo '== arm a configured remote-reply source =='
"$ROOT/bin/fm-procevent-remote-reply.sh" arm ios
echo '== generic runner sees the remote source =='
"$ROOT/bin/fm-procevent.sh" list
echo '== retirement =='
"$ROOT/bin/fm-procevent-remote-reply.sh" retire ios
"$ROOT/bin/fm-procevent.sh" list
