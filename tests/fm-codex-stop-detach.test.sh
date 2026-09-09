#!/usr/bin/env bash
# Codex Stop-hook detachment contract through the tracked hook registration.
set -u

if ! command -v python3 >/dev/null 2>&1; then
  echo 'skip: python3 is required for portable process inspection and cleanup'
  exit 0
fi

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-stop-detach)
CHILD_PIDS=
. "$(dirname "${BASH_SOURCE[0]}")/codex-stop-detach-helpers.sh"

cleanup_watcher_pids() {
  local rc=$?
  trap - EXIT INT TERM
  codex_stop_cleanup_processes "$TMP_ROOT" || exit 1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_watcher_pids EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

make_codex_case() {
  local name=$1 dir entry
  dir="$TMP_ROOT/$name"
  mkdir -p "$dir/state" "$dir/config" "$dir/bin" "$dir/.codex" "$dir/fakebin"
  for entry in "$ROOT/bin/"*; do
    ln -s "$entry" "$dir/bin/${entry##*/}"
  done
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  cp "$(command -v bash)" "$dir/codex"
  : > "$dir/AGENTS.md"
  printf 'codex-stop-detach\n' > "$dir/.fm-secondmate-home"
  cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows|capture-pane) exit 0 ;;
esac
exit 1
SH
  chmod +x "$dir/fakebin/tmux"
  printf 'export PATH=%q:"$PATH"\n' "$dir/fakebin" > "$dir/bash-env"
  printf '%s\n' "$dir"
}

hook_command() {
  jq -r '.hooks.Stop[0].hooks[0].command' "$1/.codex/hooks.json"
}

run_stop_to_files() {
  local dir=$1 stop
  stop=$(hook_command "$dir")
  (
    cd "$dir" || exit 1
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_CONFIG_OVERRIDE="$dir/config" BASH_ENV="$dir/bash-env" \
      FM_HOME_WAKE_BACKEND=tmux FM_HOME_WAKE_TARGET=detach-test \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$dir/codex" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "{\"stop_hook_active\":false}" | bash -c "$1"
        rc=$?
        printf "%s\n" "$rc" > "$FM_HOME/stop.rc"
        exit "$rc"
      ' _ "$stop"
  ) > "$dir/stop.out" 2> "$dir/stop.err"
}

run_stop_to_pipe() {
  local dir=$1 pipe=$2 stop
  stop=$(hook_command "$dir")
  (
    cd "$dir" || exit 1
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_CONFIG_OVERRIDE="$dir/config" BASH_ENV="$dir/bash-env" \
      FM_HOME_WAKE_BACKEND=tmux FM_HOME_WAKE_TARGET=detach-test \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$dir/codex" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "{\"stop_hook_active\":false}" | bash -c "$1"
        exit $?
      ' _ "$stop"
  ) > "$pipe" 2>&1
}

watcher_pid() {
  sed -n '1p' "$1/state/.watch.lock/pid" 2>/dev/null || true
}

wait_for_watcher() {
  local dir=$1 pid i
  # shellcheck disable=SC2034 # The loop variable only bounds the polling count.
  for i in $(seq 1 100); do
    pid=$(watcher_pid "$dir")
    if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null && [ -e "$dir/state/.last-watcher-beat" ]; then
      printf '%s\n' "$pid"
      return 0
    fi
    sleep 0.1
  done
  return 1
}

count_watchers() {
  local dir=$1
  ps -eo pid=,ppid=,comm=,args= | awk -v path="$dir/bin/fm-watch.sh" '
    { parents[$1] = $2 }
    $3 == "bash" && index($0, path) { watchers[$1] = 1 }
    END {
      for (pid in watchers) {
        parent = parents[pid]
        nested = 0
        while (parent > 1 && parent in parents) {
          if (parent in watchers) { nested = 1; break }
          parent = parents[parent]
        }
        if (!nested) count++
      }
      print count + 0
    }
  '
}

test_detached_start_and_pipe_closure() {
  local dir pipe reader hook_pid start end elapsed watcher sid fd target descriptors
  dir=$(make_codex_case no-watcher)
  printf 'kind=ship\n' > "$dir/state/live.meta"
  pipe="$dir/hook.pipe"
  mkfifo "$pipe"
  cat "$pipe" > "$dir/pipe.out" &
  reader=$!
  CHILD_PIDS="$CHILD_PIDS $reader"
  start=$(codex_stop_milliseconds)
  run_stop_to_pipe "$dir" "$pipe" &
  hook_pid=$!
  CHILD_PIDS="$CHILD_PIDS $hook_pid"
  wait_for_exit "$hook_pid" 50 || fail "Codex Stop hook did not return within 5 seconds"
  end=$(codex_stop_milliseconds)
  elapsed=$((end - start))
  wait_for_exit "$reader" 20 || fail "the hook output pipe stayed open after Stop returned"
  watcher=$(wait_for_watcher "$dir") || fail "detached Stop hook did not leave a healthy watcher"
  sid=$(codex_stop_session "$watcher")
  [ "$sid" = "$watcher" ] || fail "watcher did not lead its own session: pid=$watcher sid=$sid"
  if [ -d "/proc/$watcher/fd" ]; then
    for fd in 0 1 2; do
      target=$(readlink "/proc/$watcher/fd/$fd" 2>/dev/null || true)
      [ "$target" = /dev/null ] || fail "detached watcher fd $fd was not redirected to /dev/null: $target"
    done
    for fd in /proc/"$watcher"/fd/*; do
      target=$(readlink "$fd" 2>/dev/null || true)
      case "$target" in
        *hook.pipe*|*pipe.out*) fail "detached watcher inherited the hook pipe: $fd -> $target" ;;
      esac
    done
  elif command -v lsof >/dev/null 2>&1; then
    descriptors=$(lsof -a -p "$watcher" -Ffn 2>/dev/null) || fail "could not inspect watcher descriptors with lsof"
    for fd in 0 1 2; do
      target=$(printf '%s\n' "$descriptors" | awk -v fd="$fd" '/^f/ { selected = substr($0, 2) == fd } selected && /^n/ { print substr($0, 2) }')
      [ "$target" = /dev/null ] || fail "detached watcher fd $fd was not redirected to /dev/null: $target"
    done
    case "$descriptors" in
      *hook.pipe*|*pipe.out*) fail "detached watcher inherited the hook pipe" ;;
    esac
  else
    printf '%s\n' 'skip: descriptor inspection requires /proc or lsof; hook pipe EOF was checked'
  fi
  [ "$elapsed" -lt 5000 ] || fail "detached Stop hook exceeded its 5-second bound: ${elapsed}ms"
  pass "Codex Stop starts a new-session watcher, closes the hook pipe, and returns in ${elapsed}ms"
}

test_existing_watcher_attaches_without_duplicate() {
  local dir watcher_before watcher_after rc count
  dir=$(make_codex_case healthy-watcher)
  printf 'kind=ship\n' > "$dir/state/live.meta"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$dir/bin/fm-watch.sh" > "$dir/watcher.out" 2> "$dir/watcher.err" &
  CHILD_PIDS="$CHILD_PIDS $!"
  watcher_before=$(wait_for_watcher "$dir") || fail "could not establish the healthy pre-existing watcher"
  run_stop_to_files "$dir"; rc=$?
  [ "$rc" -eq 0 ] || fail "Stop hook failed on a healthy existing watcher: rc=$rc $(cat "$dir/stop.err")"
  watcher_after=$(watcher_pid "$dir")
  [ "$watcher_after" = "$watcher_before" ] || fail "healthy watcher lock was replaced: before=$watcher_before after=$watcher_after"
  count=$(count_watchers "$dir")
  [ "$count" -eq 1 ] || fail "existing-watcher Stop created a duplicate watcher: count=$count"
  pass "Codex Stop attaches to a healthy watcher and returns without a duplicate"
}

run_arm() {
  local dir=$1
  shift
  env -u FM_HOME_WAKE_BACKEND -u FM_HOME_WAKE_TARGET \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$@" "$dir/bin/fm-watch-arm.sh" --detached
}

test_high_inherited_descriptor() {
  local dir
  dir=$(make_codex_case high-descriptor)
  printf 'kind=ship\n' > "$dir/state/live.meta"
  python3 - "$dir" <<'PYTEST'
import os
import resource
import select
import subprocess
import sys
home = sys.argv[1]
soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
if hard != resource.RLIM_INFINITY and hard <= 2048:
    print('skip: hard descriptor limit cannot support fd 2048')
    sys.exit(0)
resource.setrlimit(resource.RLIMIT_NOFILE, (max(soft, 2049), hard))
reader, writer = os.pipe()
os.dup2(writer, 2048, inheritable=True)
os.close(writer)
env = dict(os.environ, FM_HOME=home, FM_ROOT_OVERRIDE=home,
           FM_STATE_OVERRIDE=home + '/state', FM_CONFIG_OVERRIDE=home + '/config',
           FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
env.pop('FM_HOME_WAKE_BACKEND', None)
env.pop('FM_HOME_WAKE_TARGET', None)
try:
    result = subprocess.run([home + '/bin/fm-watch-arm.sh', '--detached'],
                            env=env, pass_fds=(2048,), capture_output=True, text=True, timeout=15)
finally:
    os.close(2048)
assert result.returncode == 0, (result.stdout, result.stderr)
assert select.select([reader], [], [], 2)[0], 'fd 2048 retained the inherited hook pipe'
assert os.read(reader, 1) == b'', 'hook pipe did not reach EOF'
os.close(reader)
pid = int(open(home + '/state/.watch.lock/pid').read())
os.kill(pid, 0)
assert os.getsid(pid) == pid
PYTEST
  [ "$?" -eq 0 ] || fail 'high-numbered inherited hook descriptor stayed open'
  pass 'detached launch closes inherited fd 2048 while its watcher survives'
}

test_prelock_confirmation_failure() {
  local dir rc start elapsed pid
  dir=$(make_codex_case slow-preparation)
  rm "$dir/bin/fm-pr-check-migrate.sh"
  cat > "$dir/bin/fm-pr-check-migrate.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_HOME/preparation.pid"
sleep 60 &
printf '%s\n' "$!" > "$FM_HOME/preparation-child.pid"
wait
SH
  chmod +x "$dir/bin/fm-pr-check-migrate.sh"
  start=$(codex_stop_milliseconds)
  run_arm "$dir" env FM_ARM_CONFIRM_TIMEOUT=1 > "$dir/arm.out" 2>&1
  rc=$?
  elapsed=$(( $(codex_stop_milliseconds) - start ))
  [ "$rc" -ne 0 ] || fail 'slow pre-lock preparation was accepted'
  [ "$elapsed" -lt 6000 ] || fail "pre-lock cancellation exceeded its bound: $elapsed"
  [ -s "$dir/preparation.pid" ] && [ -s "$dir/preparation-child.pid" ] || fail 'slow preparation never ran'
  for pid in "$(cat "$dir/preparation.pid")" "$(cat "$dir/preparation-child.pid")"; do
    is_live_non_zombie "$pid" && fail "confirmation failure leaked preparation pid=$pid"
  done
  [ ! -e "$dir/state/.watch.lock/pid" ] || fail 'failed pre-lock candidate later acquired the watcher lock'
  pass 'confirmation timeout retires pre-lock preparation and descendants'
}

test_fast_completion_identity() {
  local dir rc i
  for i in 1 2 3; do
    dir=$(make_codex_case "fast-completion-$i")
    append_wake "$dir/state" check fast 'check: already queued'
    FM_HOME="$dir" FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_recovery_marker_publish "$STATE/.watcher-down" downtime' _ "$ROOT/bin/fm-wake-lib.sh"
    cat >> "$dir/bash-env" <<'SH'
if [ "${0##*/}" = fm-watch-arm.sh ] && [ "${1:-}" = --detached ]; then
  date() { sleep 0.3; command date "$@"; }
fi
SH
    run_arm "$dir" env BASH_ENV="$dir/bash-env" > "$dir/arm.out" 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || fail "fast queued completion was reported as failure: $(cat "$dir/arm.out")"
    [ -s "$dir/state/.wake-queue" ] || fail 'fast completion consumed queued work'
    grep -qE '^(check: rearm-resurface|watcher: started)' "$dir/arm.out" || fail 'fast completion returned no observable outcome'
  done
  pass 'fast queued completions retain post-exec identity and successful outcomes'
}

test_unmatched_delivery_is_rejected() {
  local dir rc
  dir=$(make_codex_case mismatched-delivery)
  rm "$dir/bin/fm-watch.sh"
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/fm-wake-lib.sh"
. "$SCRIPT_DIR/fm-watch-launch-lib.sh"
fm_watch_launch_begin || exit 1
printf '%s\t%s\t%s\n' "$$" 'different process identity' 'check: forged delivery' > "$STATE/.watch-deliveries.log"
exit 0
SH
  chmod +x "$dir/bin/fm-watch.sh"
  run_arm "$dir" env > "$dir/arm.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail 'a delivery from a mismatched process identity was accepted'
  grep -q 'watcher: FAILED' "$dir/arm.out" || fail 'mismatched delivery failed without an actionable outcome'
  pass 'unmatched delivery records cannot turn an empty completion into success'
}

test_late_completion_handoff() {
  local dir scenario child
  for scenario in wake failure replaced-session rebound; do
    dir=$(make_codex_case "late-$scenario")
    cat > "$dir/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  display-message) case "$*" in *cursor_y*) printf '1\n' ;; *) printf 'codex\n' ;; esac ;;
  capture-pane) printf '╭────╮\n│ %s   │\n╰────╯\n' "$(cat "$FM_HOME/pending" 2>/dev/null)" ;;
  send-keys)
    if [ "${4:-}" = -l ]; then
      printf '%s\n' "$5" > "$FM_HOME/pending"
      printf '%s\n' "$5" >> "$FM_HOME/submissions"
    elif [ "${4:-}" = Enter ]; then
      : > "$FM_HOME/pending"
    fi ;;
esac
exit 0
SH
    chmod +x "$dir/fakebin/tmux"
    cat > "$dir/late-probe.sh" <<'SH'
#!/usr/bin/env bash
set -u
cd "$FM_HOME" || exit 1
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
printf 'kind=ship\n' > "$FM_HOME/state/live.meta"
stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$FM_HOME/.codex/hooks.json")
printf '{"stop_hook_active":false}' | bash -c "$stop" || exit 10
printf 'returned\n' > "$FM_HOME/stop-returned"
sleep 2
watcher=$(cat "$FM_HOME/state/.watch.lock/pid")
case "$1" in
  failure) kill -KILL "$watcher" ;;
  replaced-session)
    printf '1\n' > "$FM_HOME/state/.lock"
    printf 'done: completed after Stop\n' > "$FM_HOME/state/live.status" ;;
  *) printf 'done: completed after Stop\n' > "$FM_HOME/state/live.status" ;;
esac
for ((i=0; i<150; i++)); do
  [ -s "$FM_HOME/submissions" ] && exit 0
  if [ "$1" = replaced-session ] && [ -s "$FM_HOME/state/.watch-deliveries.log" ]; then
    sleep 1
    [ ! -s "$FM_HOME/submissions" ] || exit 12
    exit 0
  fi
  sleep 0.1
done
exit 11
SH
    if [ "$scenario" = rebound ]; then
      run_stop_to_files "$dir" || fail 'could not establish the previous session watcher'
    fi
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
      FM_HOME_WAKE_BACKEND=tmux FM_HOME_WAKE_TARGET=detach-test BASH_ENV="$dir/bash-env" \
      FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$dir/codex" "$dir/late-probe.sh" "$scenario" > "$dir/probe.out" 2>&1 &
    child=$!
    CHILD_PIDS="$CHILD_PIDS $child"
    wait "$child" || fail "late $scenario completion did not hand off correctly: $(cat "$dir/probe.out")"
    [ -s "$dir/stop-returned" ] || fail 'late event occurred before the Stop hook returned'
    [ -s "$dir/state/.wake-queue" ] || fail 'completion callback consumed the queue'
    if [ "$scenario" != replaced-session ]; then
      [ "$(wc -l < "$dir/submissions")" -eq 1 ] || fail 'completion submitted duplicate handling turns'
    fi
  done
  pass 'late wake and SIGKILL failure notify the original session without consuming queued work'
}

test_detached_start_and_pipe_closure
test_existing_watcher_attaches_without_duplicate
test_high_inherited_descriptor
test_prelock_confirmation_failure
test_fast_completion_identity
test_unmatched_delivery_is_rejected
test_late_completion_handoff
