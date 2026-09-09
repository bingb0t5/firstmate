#!/usr/bin/env bash
# Codex Stop-hook detachment contract through the tracked hook registration.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

TMP_ROOT=$(fm_test_tmproot fm-codex-stop-detach)
WATCHER_PIDS=

cleanup_watcher_pids() {
  local pid
  for pid in $WATCHER_PIDS; do
    kill -TERM "$pid" 2>/dev/null || true
  done
  for pid in $WATCHER_PIDS; do
    wait "$pid" 2>/dev/null || true
  done
  fm_test_cleanup
}
trap cleanup_watcher_pids EXIT INT TERM

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
  ps -eo comm=,args= | awk -v path="$dir/bin/fm-watch.sh" '$1 == "bash" && index($0, path) { count++ } END { print count + 0 }'
}

test_detached_start_and_pipe_closure() {
  local dir pipe reader hook_pid start end elapsed watcher sid fd target
  dir=$(make_codex_case no-watcher)
  printf 'kind=ship\n' > "$dir/state/live.meta"
  pipe="$dir/hook.pipe"
  mkfifo "$pipe"
  cat "$pipe" > "$dir/pipe.out" &
  reader=$!
  start=$(date +%s%N)
  run_stop_to_pipe "$dir" "$pipe" &
  hook_pid=$!
  wait_for_exit "$hook_pid" 50 || fail "Codex Stop hook did not return within 5 seconds"
  end=$(date +%s%N)
  elapsed=$(( (end - start) / 1000000 ))
  wait_for_exit "$reader" 20 || fail "the hook output pipe stayed open after Stop returned"
  watcher=$(wait_for_watcher "$dir") || fail "detached Stop hook did not leave a healthy watcher"
  WATCHER_PIDS="$WATCHER_PIDS $watcher"
  sid=$(ps -o sid= -p "$watcher" | tr -d '[:space:]')
  [ "$sid" = "$watcher" ] || fail "watcher did not lead its own session: pid=$watcher sid=$sid"
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
  [ "$elapsed" -lt 5000 ] || fail "detached Stop hook exceeded its 5-second bound: ${elapsed}ms"
  pass "Codex Stop starts a new-session watcher, closes stdio and hook descriptors, and returns in ${elapsed}ms"
}

test_existing_watcher_attaches_without_duplicate() {
  local dir watcher_before watcher_after rc count
  dir=$(make_codex_case healthy-watcher)
  printf 'kind=ship\n' > "$dir/state/live.meta"
  FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" FM_CONFIG_OVERRIDE="$dir/config" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$dir/bin/fm-watch.sh" > "$dir/watcher.out" 2> "$dir/watcher.err" &
  watcher_before=$(wait_for_watcher "$dir") || fail "could not establish the healthy pre-existing watcher"
  WATCHER_PIDS="$WATCHER_PIDS $watcher_before"
  run_stop_to_files "$dir"; rc=$?
  [ "$rc" -eq 0 ] || fail "Stop hook failed on a healthy existing watcher: rc=$rc $(cat "$dir/stop.err")"
  watcher_after=$(watcher_pid "$dir")
  [ "$watcher_after" = "$watcher_before" ] || fail "healthy watcher lock was replaced: before=$watcher_before after=$watcher_after"
  count=$(count_watchers "$dir")
  [ "$count" -eq 1 ] || fail "existing-watcher Stop created a duplicate watcher: count=$count"
  pass "Codex Stop attaches to a healthy watcher and returns without a duplicate"
}

test_detached_start_and_pipe_closure
test_existing_watcher_attaches_without_duplicate
