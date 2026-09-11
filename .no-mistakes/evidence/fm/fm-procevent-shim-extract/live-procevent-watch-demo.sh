#!/usr/bin/env bash
# Product-level CLI exercise for fm-procevent arm/reconcile and fm-watch delivery.
set -euo pipefail
ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M27E4697X1ZFPE605XT0BRG3
CASE=/home/rich/.no-mistakes/evidence/01M27E4697X1ZFPE605XT0BRG3/live-procevent-watch-case
rm -rf "$CASE"
mkdir -p "$CASE/home/state" "$CASE/claims"
export FM_HOME="$CASE/home"
export FM_PROCEVENT_CLAIM_ROOT="$CASE/claims"

echo '== arm a process-event source =='
"$ROOT/bin/fm-procevent.sh" arm lavish live-demo -- /bin/sh -c 'printf "session:\n  file: /live-demo.html\n  status: waiting\n"'
echo '== public registration listing =='
"$ROOT/bin/fm-procevent.sh" list
echo '== reconcile starts the registered source =='
"$ROOT/bin/fm-procevent.sh" reconcile
for _ in $(seq 1 80); do
  [ -s "$FM_HOME/state/.wake-queue" ] && break
  sleep 0.1
done
[ -s "$FM_HOME/state/.wake-queue" ]
echo '== durable process-event wake =='
awk -F '\t' '{printf "kind=%s key=%s payload=%s\n", $3, $4, $5}' "$FM_HOME/state/.wake-queue"
echo '== captured source output =='
find "$FM_HOME/state/procevent-inbox" -name 'live-demo.*.result' -type f -exec sh -c 'printf "result=%s\n" "$1"; sed "s/^/  /" "$1"' _ {} \;
echo '== running watcher surfaces the queued result =='
"$ROOT/bin/fm-watch.sh" > "$CASE/watch.out" 2>&1 &
watch_pid=$!
for _ in $(seq 1 80); do
  if ! kill -0 "$watch_pid" 2>/dev/null; then break; fi
  sleep 0.1
done
if kill -0 "$watch_pid" 2>/dev/null; then
  kill -TERM "$watch_pid" 2>/dev/null || true
  wait "$watch_pid" || true
  echo 'watcher did not exit after the queued process-event result' >&2
  exit 1
fi
wait "$watch_pid"
sed 's/^/watch: /' "$CASE/watch.out"
echo '== retire cleanup =='
"$ROOT/bin/fm-procevent.sh" retire live-demo
