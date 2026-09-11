#!/usr/bin/env bash
# Product-level when-adapter arm and outcome exercise.
set -euo pipefail
ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M27E4697X1ZFPE605XT0BRG3
CASE=/home/rich/.no-mistakes/evidence/01M27E4697X1ZFPE605XT0BRG3/live-when-arm-case
rm -rf "$CASE"
mkdir -p "$CASE/home/state" "$CASE/claims"
export FM_HOME="$CASE/home"
export FM_PROCEVENT_CLAIM_ROOT="$CASE/claims"
echo '== arm a stable condition and action =='
"$ROOT/bin/fm-procevent-when.sh" arm deploy-ready --interval 0.1 --stable 1 --condition true --action /bin/echo 'deployed'
echo '== reconcile executes the condition source =='
"$ROOT/bin/fm-procevent.sh" reconcile
for _ in $(seq 1 80); do
  result=$(find "$FM_HOME/state/procevent-inbox" -name 'when-deploy-ready.*.result' -type f -print -quit 2>/dev/null || true)
  [ -n "$result" ] && break
  sleep 0.1
done
[ -n "${result:-}" ]
echo '== durable fired outcome =='
sed 's/^/  /' "$result"
for _ in $(seq 1 80); do
  [ ! -e "$FM_HOME/state/procevent/when-deploy-ready.source" ] && break
  sleep 0.1
done
[ ! -e "$FM_HOME/state/procevent/when-deploy-ready.source" ]
for _ in $(seq 1 80); do
  [ ! -e "$FM_HOME/state/procevent/when-deploy-ready.source" ] && break
  sleep 0.1
done
[ ! -e "$FM_HOME/state/procevent/when-deploy-ready.source" ]
echo '== terminal source has retired =='
"$ROOT/bin/fm-procevent.sh" list
