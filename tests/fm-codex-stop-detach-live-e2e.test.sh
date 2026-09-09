#!/usr/bin/env bash
# Credentialed end-to-end Codex Stop-hook detachment regression.
set -u

if [ "${FM_CODEX_STOP_DETACH_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_STOP_DETACH_LIVE_E2E=1 to run the real Codex Stop-hook regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}
command -v codex >/dev/null 2>&1 || fail "codex not found"

LAB=$(mktemp -d "$ROOT/.codex-stop-detach-live.XXXXXX")
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
TRANSCRIPT="$LAB/codex.jsonl"
WATCHER_PIDS=
cleanup() {
  for watcher_pid in $WATCHER_PIDS; do
    kill -TERM "$watcher_pid" 2>/dev/null || true
    wait "$watcher_pid" 2>/dev/null || true
  done
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -r "$LAB"
}
trap cleanup EXIT INT TERM

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'codex-stop-live\n' > "$HOME_DIR/.fm-secondmate-home"
printf 'kind=ship\n' > "$HOME_DIR/state/live.meta"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/bin/fm-turnend-guard.sh" "$PROJECT/bin/fm-turnend-guard.sh"
cp "$ROOT/bin/fm-watch-arm.sh" "$PROJECT/bin/fm-watch-arm.sh"

run_codex_turn() {
  local home=$1 output=$2 start end rc
  start=$(date +%s%N)
  (
    cd "$PROJECT" || exit 1
    printf '%s\n' "$$" > "$home/state/.lock"
    export FM_HOME="$home" FM_ROOT_OVERRIDE="$PROJECT" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config"
    exec timeout 55s codex exec \
      --dangerously-bypass-hook-trust \
      --dangerously-bypass-approvals-and-sandbox \
      --skip-git-repo-check \
      -c 'model_reasoning_effort="low"' --json \
      'Reply with exactly OK and do not use tools.'
  ) > "$output" 2>&1
  rc=$?
  end=$(date +%s%N)
  printf '%s %s\n' "$rc" "$(( (end - start) / 1000000 ))"
  return "$rc"
}

watcher_is_healthy() {
  local home=$1 pid
  pid=$(sed -n '1p' "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -e "$home/state/.last-watcher-beat" ]
}

first=$(run_codex_turn "$HOME_DIR" "$TRANSCRIPT") || fail "real Codex Stop turn failed or exceeded its bound: $(tail -20 "$TRANSCRIPT")"
WATCHER_PID=$(sed -n '1p' "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
WATCHER_PIDS="$WATCHER_PID"
watcher_is_healthy "$HOME_DIR" || fail "real Codex Stop did not leave a detached healthy watcher"
watcher_sid=$(ps -o sid= -p "$WATCHER_PID" | tr -d '[:space:]')
[ "$watcher_sid" = "$WATCHER_PID" ] || fail "real Codex watcher does not lead a new session: pid=$WATCHER_PID sid=$watcher_sid"
printf '%s\n' "ok - real Codex no-watcher Stop returned rc=${first%% *} in ${first##* }ms and left watcher pid=$WATCHER_PID sid=$watcher_sid"

before=$WATCHER_PID
second=$(run_codex_turn "$HOME_DIR" "$LAB/codex-second.jsonl") || fail "real Codex Stop with an existing watcher failed: $(tail -20 "$LAB/codex-second.jsonl")"
after=$(sed -n '1p' "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
[ "$after" = "$before" ] || fail "real Codex existing-watcher Stop replaced the watcher: before=$before after=$after"
printf '%s\n' "ok - real Codex existing-watcher Stop returned rc=${second%% *} in ${second##* }ms without replacing pid=$after"

INT_HOME="$LAB/home-interrupt"
mkdir -p "$INT_HOME/state" "$INT_HOME/config"
printf 'codex-stop-live-interrupt\n' > "$INT_HOME/.fm-secondmate-home"
printf 'kind=ship\n' > "$INT_HOME/state/live.meta"
INT_TRANSCRIPT="$LAB/codex-interrupt.jsonl"
setsid bash -c '
  cd "$1" || exit 1
  printf "%s\\n" "$$" > "$2/state/.lock"
  export FM_HOME="$2" FM_ROOT_OVERRIDE="$1" FM_STATE_OVERRIDE="$2/state" FM_CONFIG_OVERRIDE="$2/config"
  exec timeout 55s codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c '\''model_reasoning_effort="low"'\'' --json \
    '\''Reply with exactly OK and do not use tools.'\''
' _ "$PROJECT" "$INT_HOME" > "$INT_TRANSCRIPT" 2>&1 &
interrupt_parent=$!
interrupt_pgid=$(ps -o pgid= -p "$interrupt_parent" | tr -d '[:space:]')
[ "$interrupt_pgid" = "$interrupt_parent" ] || fail "real Codex interrupt probe did not create an isolated parent process group: pid=$interrupt_parent pgid=$interrupt_pgid"
interrupt_watcher=
for _ in $(seq 1 600); do
  interrupt_watcher=$(sed -n '1p' "$INT_HOME/state/.watch.lock/pid" 2>/dev/null || true)
  if [ -n "$interrupt_watcher" ] && watcher_is_healthy "$INT_HOME"; then
    break
  fi
  sleep 0.1
done
if [ -z "$interrupt_watcher" ] || ! watcher_is_healthy "$INT_HOME"; then
  fail "real Codex interrupt probe did not start a healthy watcher: $(tail -20 "$INT_TRANSCRIPT")"
fi
kill -0 "$interrupt_parent" 2>/dev/null || fail "real Codex interrupt probe exited before its parent process group could be interrupted"
kill -TERM -- "-$interrupt_pgid" 2>/dev/null || fail "could not interrupt the real Codex parent process group"
for _ in $(seq 1 50); do
  kill -0 "$interrupt_parent" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$interrupt_parent" 2>/dev/null && fail "real Codex parent process group did not exit after interrupt"
WATCHER_PIDS="$WATCHER_PIDS $interrupt_watcher"
interrupt_sid=$(ps -o sid= -p "$interrupt_watcher" | tr -d '[:space:]')
[ "$interrupt_sid" = "$interrupt_watcher" ] || fail "interrupting the Codex parent group changed the watcher session: pid=$interrupt_watcher sid=$interrupt_sid"
watcher_is_healthy "$INT_HOME" || fail "interrupting the Codex parent group killed the detached watcher"
next=$(run_codex_turn "$INT_HOME" "$LAB/codex-interrupt-next.jsonl") || fail "next real Codex Stop after parent-group interrupt failed or exceeded its bound: $(tail -20 "$LAB/codex-interrupt-next.jsonl")"
next_watcher=$(sed -n '1p' "$INT_HOME/state/.watch.lock/pid" 2>/dev/null || true)
[ "$next_watcher" = "$interrupt_watcher" ] || fail "next real Codex Stop replaced the surviving watcher: before=$interrupt_watcher after=$next_watcher"
printf '%s\n' "ok - interrupting real Codex parent group left watcher pid=$interrupt_watcher sid=$interrupt_sid alive and next Stop returned rc=${next%% *} in ${next##* }ms"
