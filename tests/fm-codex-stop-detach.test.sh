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

identity_for_pid() {
  local dir=$1 pid=$2
  FM_STATE_OVERRIDE="$dir/state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$pid"
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

test_replacement_session_binding_survives_old_completion() {
  local dir current_dir source_dir current_pid current_identity old_pid old_identity owner_pid owner_identity rc
  dir=$(make_codex_case replacement-binding)
  mkdir -p "$dir/state/.watch.lock"
  sleep 60 &
  current_pid=$!
  CHILD_PIDS="$CHILD_PIDS $current_pid"
  current_identity=$(identity_for_pid "$dir" "$current_pid") \
    || fail "could not identify the current replacement watcher"
  sleep 60 &
  old_pid=$!
  CHILD_PIDS="$CHILD_PIDS $old_pid"
  old_identity=$(identity_for_pid "$dir" "$old_pid") \
    || fail "could not identify the old completion watcher"
  owner_pid=$$
  owner_identity=$(identity_for_pid "$dir" "$owner_pid") \
    || fail "could not identify the completion owner"
  current_dir="$dir/state/.watch-arm-detached.current"
  source_dir="$dir/state/.watch-arm-detached.source"
  mkdir "$current_dir" "$source_dir"
  printf '%s\t%s\n' "$current_pid" "$current_identity" > "$current_dir/identity"
  printf '%s\t%s\n' "$owner_pid" "$owner_identity" > "$current_dir/owner"
  printf '%s\t%s\t%s\t%s\n' "$owner_pid" "$owner_identity" tmux detach-test > "$current_dir/session"
  printf '%s\t%s\n' "$old_pid" "$old_identity" > "$source_dir/identity"
  printf '%s\t%s\n' "$owner_pid" "$owner_identity" > "$source_dir/owner"
  printf '%s\t%s\t1\t\n' "$old_pid" "$old_identity" > "$source_dir/result"
  printf '%s\t%s\t%s\t%s\n' "$old_pid" "$old_identity" tmux old-session > "$source_dir/session"
  : > "$source_dir/accepted"
  printf '%s\n' "$owner_pid" > "$dir/state/.lock"
  printf '%s\n' "$current_pid" > "$dir/state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$dir/state/.watch.lock/fm-home"
  printf '%s\n' "$dir/bin/fm-watch.sh" > "$dir/state/.watch.lock/watcher-path"
  printf '%s\n' "$current_identity" > "$dir/state/.watch.lock/pid-identity"
  printf '%s\n' "$current_dir" > "$dir/state/.watch.lock/watcher-launch"
  touch "$dir/state/.last-watcher-beat"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_GUARD_GRACE=300 "$dir/bin/fm-watch-arm.sh" --detached-complete "$source_dir" > "$dir/completion.out" 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "completion handoff failed: $(cat "$dir/completion.out")"
  [ ! -e "$source_dir" ] || fail "old completion record was not retired"
  [ "$(cat "$current_dir/session")" = "$(printf '%s\t%s\t%s\t%s' "$owner_pid" "$owner_identity" tmux detach-test)" ] \
    || fail "old completion overwrote the current replacement session binding"
  pass "old detached completion preserves the current replacement session binding"
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

test_exec_boundary_cancellation() {
  local dir rc executable
  dir=$(make_codex_case exec-cancellation)
  executable=$(command -v perl)
  cat > "$dir/perl-child" <<'PERL'
use POSIX;
POSIX::setsid() >= 0 or exit 125;
open my $ready, ">", "$ENV{FM_HOME}/candidate.pid" or die $!;
print $ready "$$\n";
close $ready;
until (-f "$ENV{FM_HOME}/exec-release") { select undef, undef, undef, 0.02; }
exec $ARGV[0];
PERL
  printf '#!/usr/bin/env bash\nif [[ "${3:-}" = POSIX::setsid* ]]; then exec %q "$FM_HOME/perl-child" "${4}"; fi\nexec %q "$@"\n' "$executable" "$executable" > "$dir/fakebin/perl"
  executable=$(command -v ps)
  printf '#!/usr/bin/env bash\nif [ "${2:-}" = ppid= ] && [ "${4:-}" = "$(cat "$FM_HOME/candidate.pid" 2>/dev/null)" ]; then\n  touch "$FM_HOME/exec-release"\n  for ((i=0; i<100; i++)); do\n    [ -s "$FM_HOME/post-exec" ] && break\n    sleep 0.02\n  done\nfi\nexec %q "$@"\n' "$executable" > "$dir/fakebin/ps"
  cat >> "$dir/bash-env" <<'SH'
if [ "${0##*/}" = fm-watch.sh ]; then
  printf '%s\n' "$$" > "$FM_HOME/post-exec"
fi
SH
  chmod +x "$dir/fakebin/perl" "$dir/fakebin/ps"
  run_arm "$dir" env BASH_ENV="$dir/bash-env" FM_ARM_CONFIRM_TIMEOUT=1 > "$dir/arm.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail 'pre-exec candidate unexpectedly confirmed'
  [ -s "$dir/post-exec" ] || fail 'cancellation did not cross the candidate exec boundary'
  is_live_non_zombie "$(cat "$dir/candidate.pid")" && fail 'cancellation left the execed candidate stopped or alive'
  pass 'confirmation cancellation retires its child across exec'
}

test_supervisor_start_timeout() {
  local dir rc executable
  dir=$(make_codex_case supervisor-timeout)
  executable=$(command -v mv)
  printf '#!/usr/bin/env bash\ncase "$*" in */owner.tmp*) printf "%%s\n" "$PPID" > "$FM_HOME/supervisor.pid"; sleep 10 ;; esac\nexec %q "$@"\n' "$executable" > "$dir/fakebin/mv"
  chmod +x "$dir/fakebin/mv"
  run_arm "$dir" env BASH_ENV="$dir/bash-env" FM_ARM_CONFIRM_TIMEOUT=1 > "$dir/arm.out" 2>&1
  rc=$?
  [ "$rc" -ne 0 ] || fail 'blocked supervisor unexpectedly confirmed'
  [ -s "$dir/supervisor.pid" ] || fail 'supervisor never reached owner publication'
  is_live_non_zombie "$(cat "$dir/supervisor.pid")" && fail 'launch timeout left its supervisor alive'
  [ ! -e "$dir/state/.watch.lock/pid" ] || fail 'unacknowledged supervisor started a watcher'
  pass 'supervisor timeout prevents unacknowledged watcher startup'
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
  local dir scenario child executable
  local scenarios=(wake failure persistent-failure checkpoint-failure callback-contention replaced-session rebound direct direct-failure direct-stale direct-successor race)
  [ "$#" -eq 0 ] || scenarios=("$@")
  for scenario in "${scenarios[@]}"; do
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
trap 'rc=$?; if [ "$rc" -ne 0 ]; then
  printf "probe failed: rc=%s\n" "$rc"
  for record in "$FM_HOME/state/.watch-cycle-exits.log" "$FM_HOME/state/.watch-deliveries.log" "$FM_HOME/state/.wake-queue" "$FM_HOME/successor.out" "$FM_HOME/state"/.watch-arm-detached.*/notification-output; do
    [ ! -f "$record" ] || { printf "%s\n" "$record"; cat "$record"; }
  done
fi' EXIT
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
printf 'kind=ship\n' > "$FM_HOME/state/live.meta"
if [[ "$1" = direct* ]]; then
  "$FM_HOME/bin/fm-watch.sh" > "$FM_HOME/direct.out" 2>&1 &
  original=$!
  for ((i=0; i<100; i++)); do
    [ -s "$FM_HOME/state/.last-watcher-beat" ] && break
    sleep 0.05
  done
fi
stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$FM_HOME/.codex/hooks.json")
printf '{"stop_hook_active":false}' | bash -c "$stop" || exit 10
if [[ "$1" = direct* ]]; then
  [ "$(cat "$FM_HOME/state/.watch.lock/pid")" = "$original" ] || exit 13
fi
printf 'returned\n' > "$FM_HOME/stop-returned"
sleep 2
watcher=$(cat "$FM_HOME/state/.watch.lock/pid")
case "$1" in
  failure|direct-failure) kill -KILL "$watcher" ;;
  direct-stale)
    kill -STOP "$watcher"
    touch -t 200001010000 "$FM_HOME/state/.last-watcher-beat" ;;
  direct-successor)
    kill -TERM "$watcher"
    wait "$watcher" || true
    FM_WATCH_HANDLING_SUCCESSOR=1 "$FM_HOME/bin/fm-watch.sh" > "$FM_HOME/successor.out" 2>&1 &
    successor=$!
    for ((i=0; i<150; i++)); do
      [ "$(cat "$FM_HOME/state/.watch.lock/pid" 2>/dev/null)" = "$successor" ] && [ -s "$FM_HOME/state/.watch.lock/watcher-launch" ] && break
      sleep 0.1
    done
    [ -s "$FM_HOME/state/.watch.lock/watcher-launch" ] || exit 14
    printf 'done: completed by successor\n' > "$FM_HOME/state/live.status" ;;
  persistent-failure)
    rm "$FM_HOME/bin/fm-pr-check-migrate.sh"
    printf '#!/usr/bin/env bash\nprintf "refused migration\n" > "$FM_HOME/migration-attempt"\nexit 73\n' > "$FM_HOME/bin/fm-pr-check-migrate.sh"
    chmod +x "$FM_HOME/bin/fm-pr-check-migrate.sh"
    kill -KILL "$watcher" ;;
  checkpoint-failure)
    rm "$FM_HOME/bin/fm-pr-check-migrate.sh"
    printf '#!/usr/bin/env bash\nprintf "refused checkpoint migration\\n" > "$FM_HOME/checkpoint-migration-attempt"\nexit 73\n' > "$FM_HOME/bin/fm-pr-check-migrate.sh"
    chmod +x "$FM_HOME/bin/fm-pr-check-migrate.sh"
    printf 'done: completed after Stop\n' > "$FM_HOME/state/live.status" ;;
  callback-contention)
    launch_dir=$(cat "$FM_HOME/state/.watch.lock/watcher-launch")
    kill -STOP "$watcher"
    . "$FM_HOME/bin/fm-wake-lib.sh"
    fm_wake_append check callback-contention 'check: completion during native callback cleanup' || exit 15
    FM_TEST_PAUSE_CALLBACK_CLEANUP=1 "$FM_HOME/bin/fm-home-wake.sh" tmux detach-test > "$FM_HOME/native.out" 2>&1 &
    native=$!
    for ((i=0; i<100; i++)); do
      [ -f "$FM_HOME/native-cleanup-ready" ] && break
      sleep 0.05
    done
    [ -f "$FM_HOME/native-cleanup-ready" ] || exit 16
    kill -CONT "$watcher"
    for ((i=0; i<100; i++)); do
      [ -f "$launch_dir/result" ] && break
      sleep 0.05
    done
    [ -f "$launch_dir/result" ] || exit 17
    sleep 2
    [ -f "$launch_dir/result" ] && [ ! -s "$FM_HOME/submissions" ] || exit 18
    touch "$FM_HOME/native-cleanup-release"
    wait "$native" || exit 19 ;;

  replaced-session)
    printf '1\n' > "$FM_HOME/state/.lock"
    printf 'done: completed after Stop\n' > "$FM_HOME/state/live.status" ;;
  *) printf 'done: completed after Stop\n' > "$FM_HOME/state/live.status" ;;
esac
for ((i=0; i<150; i++)); do
  if [ -s "$FM_HOME/submissions" ]; then
    case "$1" in
      persistent-failure)
        [ ! -e "$FM_HOME/migration-attempt" ] || exit 20
        grep -q 'Watcher supervision failed' "$FM_HOME/submissions" || exit 21 ;;
      checkpoint-failure)
        [ -s "$FM_HOME/checkpoint-migration-attempt" ] || exit 25
        grep -q 'Watcher supervision failed' "$FM_HOME/submissions" || exit 26 ;;
      direct-stale)
        kill -0 "$watcher" || exit 22
        [ "$(cat "$FM_HOME/state/.watch.lock/pid")" = "$watcher" ] || exit 23
        grep -q 'Watcher supervision failed' "$FM_HOME/submissions" || exit 24
        kill -CONT "$watcher"
        kill -TERM "$watcher" ;;
    esac
    exit 0
  fi
  if [ "$1" = replaced-session ] && [ -s "$FM_HOME/state/.watch-deliveries.log" ]; then
    sleep 1
    [ ! -s "$FM_HOME/submissions" ] || exit 12
    exit 0
  fi
  sleep 0.1
done
exit 11
SH
    if [ "$scenario" = callback-contention ]; then
      executable=$(command -v rm)
      printf '#!/usr/bin/env bash\nif [ "${FM_TEST_PAUSE_CALLBACK_CLEANUP:-0}" = 1 ] && [ "${2:-}" = "$FM_HOME/state/.home-wake.lock" ]; then\n  touch "$FM_HOME/native-cleanup-ready"\n  for ((i=0; i<200; i++)); do\n    [ -f "$FM_HOME/native-cleanup-release" ] && break\n    sleep 0.05\n  done\nfi\nexec %q "$@"\n' "$executable" > "$dir/fakebin/rm"
      chmod +x "$dir/fakebin/rm"
    fi
    if [ "$scenario" = race ]; then
      rm "$dir/bin/fm-watch.sh"
      cp "$ROOT/bin/fm-watch.sh" "$dir/bin/fm-watch.sh"
      cat >> "$dir/bash-env" <<'SH'
if [ "${0##*/}" = fm-watch.sh ] && [ -n "${FM_WATCH_LAUNCH_DIR:-}" ]; then
  env -u FM_WATCH_LAUNCH_DIR perl -MPOSIX -e 'POSIX::setsid(); exec $ARGV[0]' "$0" &
  for ((i=0; i<100; i++)); do
    [ -s "$FM_HOME/state/.last-watcher-beat" ] && break
    sleep 0.05
  done
fi
SH
    fi
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

if [ "${1:-}" = --late-completion ]; then
  shift
  test_late_completion_handoff "$@"
  exit
fi
if [ "${1:-}" = --replacement-binding ]; then
  test_replacement_session_binding_survives_old_completion
  exit
fi

test_detached_start_and_pipe_closure
test_existing_watcher_attaches_without_duplicate
test_replacement_session_binding_survives_old_completion
test_high_inherited_descriptor
test_prelock_confirmation_failure
test_exec_boundary_cancellation
test_supervisor_start_timeout
test_fast_completion_identity
test_unmatched_delivery_is_rejected
test_late_completion_handoff
