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
command -v python3 >/dev/null 2>&1 || fail "python3 is required for portable process inspection and cleanup"

LAB=$(mktemp -d "$ROOT/.codex-stop-detach-live.XXXXXX")
PROJECT="$LAB/project"
HOME_DIR="$LAB/home"
TRANSCRIPT="$LAB/codex.jsonl"
CHILD_PIDS=
. "$ROOT/tests/codex-stop-detach-helpers.sh"
cleanup() {
  local rc=$?
  trap - EXIT INT TERM
  codex_stop_cleanup_processes "$LAB" || exit 1
  chmod -R u+w "$LAB" 2>/dev/null || true
  rm -r "$LAB"
  exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
printf 'codex-stop-live\n' > "$HOME_DIR/.fm-secondmate-home"
printf 'kind=ship\n' > "$HOME_DIR/state/live.meta"
git clone -q "$ROOT" "$PROJECT"
cp -R "$ROOT/bin/." "$PROJECT/bin/"
codex_stop_install_checkpoint "$PROJECT" || fail "could not install the scratch Stop checkpoint"

run_codex_turn() {
  local home=$1 output=$2 start end rc child
  start=$(codex_stop_milliseconds)
  (
    cd "$PROJECT" || exit 1
    printf '%s\n' "$$" > "$home/state/.lock"
    export FM_HOME_WAKE_BACKEND=tmux FM_HOME_WAKE_TARGET=detach-live-test
    export FM_HOME="$home" FM_ROOT_OVERRIDE="$PROJECT" FM_STATE_OVERRIDE="$home/state" FM_CONFIG_OVERRIDE="$home/config"
    exec timeout 55s codex exec \
      --dangerously-bypass-hook-trust \
      --dangerously-bypass-approvals-and-sandbox \
      --skip-git-repo-check \
      -c 'model_reasoning_effort="low"' --json \
      'Reply with exactly OK and do not use tools.'
  ) > "$output" 2>&1 &
  child=$!
  CHILD_PIDS="$CHILD_PIDS $child"
  wait "$child"
  rc=$?
  end=$(codex_stop_milliseconds)
  TURN_RESULT="$rc $((end - start))"
  return "$rc"
}

watcher_is_healthy() {
  local home=$1 pid
  pid=$(sed -n '1p' "$home/state/.watch.lock/pid" 2>/dev/null || true)
  [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -e "$home/state/.last-watcher-beat" ]
}

run_codex_turn "$HOME_DIR" "$TRANSCRIPT" || fail "real Codex Stop turn failed or exceeded its bound: $(tail -20 "$TRANSCRIPT")"
WATCHER_PID=$(sed -n '1p' "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
first=$TURN_RESULT
watcher_is_healthy "$HOME_DIR" || fail "real Codex Stop did not leave a detached healthy watcher"
watcher_sid=$(codex_stop_session "$WATCHER_PID")
[ "$watcher_sid" = "$WATCHER_PID" ] || fail "real Codex watcher does not lead a new session: pid=$WATCHER_PID sid=$watcher_sid"
printf '%s\n' "ok - real Codex no-watcher Stop returned rc=${first%% *} in ${first##* }ms and left watcher pid=$WATCHER_PID sid=$watcher_sid"

before=$WATCHER_PID
run_codex_turn "$HOME_DIR" "$LAB/codex-second.jsonl" || fail "real Codex Stop with an existing watcher failed: $(tail -20 "$LAB/codex-second.jsonl")"
second=$TURN_RESULT
after=$(sed -n '1p' "$HOME_DIR/state/.watch.lock/pid" 2>/dev/null || true)
[ "$after" = "$before" ] || fail "real Codex existing-watcher Stop replaced the watcher: before=$before after=$after"
printf '%s\n' "ok - real Codex existing-watcher Stop returned rc=${second%% *} in ${second##* }ms without replacing pid=$after"

INT_HOME="$LAB/home-interrupt"
mkdir -p "$INT_HOME/state" "$INT_HOME/config"
printf 'codex-stop-live-interrupt\n' > "$INT_HOME/.fm-secondmate-home"
printf 'kind=ship\n' > "$INT_HOME/state/live.meta"
INT_TRANSCRIPT="$LAB/codex-interrupt.jsonl"
# shellcheck disable=SC2016 # $1 and $2 expand inside the setsid child shell.
setsid bash -c '
  cd "$1" || exit 1
  printf "%s\\n" "$$" > "$2/state/.lock"
  export FM_HOME_WAKE_BACKEND=tmux FM_HOME_WAKE_TARGET=detach-live-test
  export FM_HOME="$2" FM_ROOT_OVERRIDE="$1" FM_STATE_OVERRIDE="$2/state" FM_CONFIG_OVERRIDE="$2/config"
  export FM_CODEX_STOP_CHECKPOINT_HOME="$2"
  printf "%s\n" "$$" > "$2/session-ready.tmp"
  mv "$2/session-ready.tmp" "$2/session-ready"
  exec timeout 55s codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c '\''model_reasoning_effort="low"'\'' --json \
    '\''Reply with exactly OK and do not use tools.'\''
' _ "$PROJECT" "$INT_HOME" > "$INT_TRANSCRIPT" 2>&1 &
interrupt_parent=$!
CHILD_PIDS="$CHILD_PIDS $interrupt_parent"
for _ in $(seq 1 100); do
  [ -s "$INT_HOME/session-ready" ] && break
  kill -0 "$interrupt_parent" 2>/dev/null || fail "real Codex interrupt parent exited before session readiness: $(tail -20 "$INT_TRANSCRIPT")"
  sleep 0.1
done
[ -s "$INT_HOME/session-ready" ] || fail "real Codex interrupt parent did not publish session readiness"
[ "$(cat "$INT_HOME/session-ready")" = "$interrupt_parent" ] || fail "session readiness named a different interrupt parent"
interrupt_pgid=$(ps -o pgid= -p "$interrupt_parent" | tr -d '[:space:]')
[ "$interrupt_pgid" = "$interrupt_parent" ] || fail "real Codex interrupt probe did not create an isolated parent process group: pid=$interrupt_parent pgid=$interrupt_pgid"
for _ in $(seq 1 600); do
  [ -s "$INT_HOME/stop-checkpoint" ] && break
  kill -0 "$interrupt_parent" 2>/dev/null || fail "real Codex exited before reaching its Stop checkpoint: $(tail -20 "$INT_TRANSCRIPT")"
  sleep 0.1
done
[ -s "$INT_HOME/stop-checkpoint" ] || fail "real Codex did not reach its bounded Stop checkpoint: $(tail -20 "$INT_TRANSCRIPT")"
IFS=$'\t' read -r checkpoint_pid checkpoint_rc checkpoint_elapsed < "$INT_HOME/stop-checkpoint"
[ "$checkpoint_rc" -eq 0 ] || fail "the real Stop hook failed before its interrupt checkpoint: rc=$checkpoint_rc $(tail -20 "$INT_TRANSCRIPT")"
[ "$checkpoint_elapsed" -lt 5000 ] || fail "the real Stop hook exceeded its startup bound before the interrupt checkpoint: ${checkpoint_elapsed}ms"
kill -0 "$checkpoint_pid" 2>/dev/null || fail "the scratch hook exited before the interrupt checkpoint was observed"
interrupt_watcher=$(sed -n '1p' "$INT_HOME/state/.watch.lock/pid" 2>/dev/null || true)
watcher_is_healthy "$INT_HOME" || fail "real Codex interrupt checkpoint has no healthy watcher"
kill -0 "$interrupt_parent" 2>/dev/null || fail "real Codex interrupt probe exited before its parent process group could be interrupted"
kill -TERM -- "-$interrupt_pgid" 2>/dev/null || fail "could not interrupt the real Codex parent process group"
for _ in $(seq 1 50); do
  kill -0 "$interrupt_parent" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$interrupt_parent" 2>/dev/null && fail "real Codex parent process group did not exit after interrupt"
interrupt_sid=$(codex_stop_session "$interrupt_watcher")
[ "$interrupt_sid" = "$interrupt_watcher" ] || fail "interrupting the Codex parent group changed the watcher session: pid=$interrupt_watcher sid=$interrupt_sid"
watcher_is_healthy "$INT_HOME" || fail "interrupting the Codex parent group killed the detached watcher"
run_codex_turn "$INT_HOME" "$LAB/codex-interrupt-next.jsonl" || fail "next real Codex Stop after parent-group interrupt failed or exceeded its bound: $(tail -20 "$LAB/codex-interrupt-next.jsonl")"
next=$TURN_RESULT
next_watcher=$(sed -n '1p' "$INT_HOME/state/.watch.lock/pid" 2>/dev/null || true)
[ "$next_watcher" = "$interrupt_watcher" ] || fail "next real Codex Stop replaced the surviving watcher: before=$interrupt_watcher after=$next_watcher"
printf '%s\n' "ok - interrupting real Codex parent group left watcher pid=$interrupt_watcher sid=$interrupt_sid alive and next Stop returned rc=${next%% *} in ${next##* }ms"
