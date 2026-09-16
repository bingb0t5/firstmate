#!/usr/bin/env bash
# Browser lifecycle ownership: task-scoped axi bridges and exact direct
# Playwright/Puppeteer-style process groups converge through one finalizer.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BROWSER="$ROOT/bin/fm-browser-lifecycle.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-lifecycle)
mkdir -p "$TMP_ROOT/home" "$TMP_ROOT/state" "$TMP_ROOT/fakebin"
TMP_ROOT=$(cd "$TMP_ROOT" && pwd)
export HOME="$TMP_ROOT/home"
STATE="$TMP_ROOT/state"
# shellcheck source=bin/fm-browser-lifecycle-lib.sh
. "$ROOT/bin/fm-browser-lifecycle-lib.sh"
BRIDGE_PIDS=()
LAUNCH_PIDS=()
BROWSER_GROUP_PIDS=()
WORKER_PIDS=()
DIRECT_CHILD_PID=

cleanup_processes() {
  local pid
  for pid in "${BRIDGE_PIDS[@]:-}" "${LAUNCH_PIDS[@]:-}" \
    "${BROWSER_GROUP_PIDS[@]:-}" "${WORKER_PIDS[@]:-}" "$DIRECT_CHILD_PID"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_processes' EXIT INT TERM

# A real bridge is spawned by chrome-devtools-axi with the launching worker's
# environment, so it carries that worker's FM_BROWSER_* bindings. The fixture
# reproduces exactly that inheritance, because it is the evidence the finalizer
# proves ownership from. <owner-state> and <owner-task> are what the bridge
# itself claims, which the cases below vary independently of its session name.
make_bridge() {  # <session> <owner-state> <owner-task> [spawn-gen]
  local session=$1 owner_state=$2 owner_task=$3 gen=${4:-s1} bridge_dir bridge resolved
  bridge_dir="$HOME/.chrome-devtools-axi/sessions/$session"
  bridge="$TMP_ROOT/fakebin/chrome-devtools-axi-bridge-$session"
  mkdir -p "$bridge_dir"
  resolved=$(cd "$owner_state" && pwd -P)
  cat > "$bridge" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$bridge"
  FM_BROWSER_STATE="$resolved" FM_BROWSER_TASK_ID="$owner_task" \
    FM_BROWSER_SPAWN_GEN="$gen" "$bridge" &
  local pid=$!
  BRIDGE_PIDS+=("$pid")
  printf '{"pid":%s,"port":9230}\n' "$pid" > "$bridge_dir/bridge.pid"
  BRIDGE_PID_RESULT=$pid
}

cat > "$TMP_ROOT/fakebin/chrome-devtools-axi" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s %s\n' "${CHROME_DEVTOOLS_AXI_SESSION:-}" "$*" >> "$FM_BROWSER_LOG"
if [ "${1:-}" != stop ]; then
  exit 42
fi
if [ "${1:-}" = stop ]; then
  pid_file="$HOME/.chrome-devtools-axi/sessions/${CHROME_DEVTOOLS_AXI_SESSION}/bridge.pid"
  pid=$(jq -r '.pid' "$pid_file")
  kill "$pid" 2>/dev/null || true
  rm -f "$pid_file"
fi
SH
chmod +x "$TMP_ROOT/fakebin/chrome-devtools-axi"
export PATH="$TMP_ROOT/fakebin:$PATH"

# A generic process-group fallback may inspect the group, but it must preserve
# the group when any member is browser-like and lacks an exact owner record.
setsid bash -c 'exec -a chrome-devtools-mcp sleep 30 & wait' >/dev/null 2>&1 &
browser_group_pid=$!
BROWSER_GROUP_PIDS+=("$browser_group_pid")
browser_group_pgid=$(ps -o pgid= -p "$browser_group_pid" | tr -d '[:space:]')
if ! fm_browser_process_group_probe "$browser_group_pgid"; then
  fail "browser-like process group was not identified"
fi
kill -- "-$browser_group_pgid" 2>/dev/null || true
wait "$browser_group_pid" 2>/dev/null || true
BROWSER_GROUP_PIDS=()

session_a=$(fm_browser_session_for_task "$STATE" task-a)
session_b=$(fm_browser_session_for_task "$STATE" task-b)
[ "$session_a" != "$session_b" ] || fail "different tasks received the same browser session"
[ "${#session_a}" -le 64 ] || fail "derived browser session exceeded chrome-devtools-axi's limit"

fm_browser_owner_arm "$STATE" task-a s1 >/dev/null
assert_grep "task_id=task-a" "$STATE/task-a.browser/owner" "arm records the owning task"
assert_grep "spawn_gen=s1" "$STATE/task-a.browser/owner" "arm records the owning incarnation"
assert_grep "session=$session_a" "$STATE/task-a.browser/axi.$session_a" "arm reserves the default named session"

if fm_browser_owner_arm "$STATE" task-a s2 >/dev/null 2>&1; then
  fail "arm adopted a different incarnation"
fi

held_session=$(fm_browser_session_for_task "$STATE" task-a held)
make_bridge "$held_session" "$STATE" task-a
held_pid=$BRIDGE_PID_RESULT
if fm_browser_owner_register_axi "$STATE" task-a s1 "$held_session" >/dev/null 2>&1; then
  fail "register-axi adopted an already active bridge"
fi
kill -0 "$held_pid" 2>/dev/null || fail "active foreign browser session was stopped"
kill "$held_pid" 2>/dev/null || true
wait "$held_pid" 2>/dev/null || true

custom_session=$(fm_browser_session_for_task "$STATE" task-a custom)
fm_browser_owner_register_axi "$STATE" task-a s1 "$custom_session"
custom_pid_file="$HOME/.chrome-devtools-axi/sessions/$custom_session/bridge.pid"
make_bridge "$custom_session" "$STATE" task-a
custom_pid=$BRIDGE_PID_RESULT
export FM_BROWSER_LOG="$TMP_ROOT/browser-stop.log"
fm_browser_owner_finalize "$STATE" task-a s1 named-session
assert_grep "$custom_session stop" "$FM_BROWSER_LOG" "finalizer delegates named-session cleanup to chrome-devtools-axi"
assert_absent "$STATE/task-a.browser" "successful named-session cleanup retires ownership records"
wait "$custom_pid" 2>/dev/null || true
kill -0 "$custom_pid" 2>/dev/null && fail "named bridge survived delegated stop"
[ ! -e "$custom_pid_file" ] || fail "stale named bridge PID file survived cleanup"

second_state="$TMP_ROOT/second-state"
mkdir -p "$second_state"
first_home_session=$(fm_browser_session_for_task "$STATE" shared-task)
second_home_session=$(fm_browser_session_for_task "$second_state" shared-task)
[ "$first_home_session" != "$second_home_session" ] || fail "different homes received the same browser session"
fm_browser_owner_arm "$STATE" shared-task h1 >/dev/null
fm_browser_owner_arm "$second_state" shared-task h1 >/dev/null
make_bridge "$first_home_session" "$STATE" shared-task
first_home_pid=$BRIDGE_PID_RESULT
fm_browser_owner_finalize "$second_state" shared-task h1 worker-exit
kill -0 "$first_home_pid" 2>/dev/null || fail "cross-home cleanup stopped an active bridge"
fm_browser_owner_finalize "$STATE" shared-task h1 worker-exit
wait "$first_home_pid" 2>/dev/null || true
kill -0 "$first_home_pid" 2>/dev/null && fail "owning home did not stop its bridge"

# Ownership is proved from the bridge's own process environment, never from its
# session name. Each case below holds the name constant and varies only what the
# bridge claims about itself, so the guarantee survives a name collision.

# Same home, same task, an OLDER incarnation: a relaunch orphan is still ours.
fm_browser_owner_arm "$STATE" relaunch-orphan g2 >/dev/null
relaunch_session=$(fm_browser_session_for_task "$STATE" relaunch-orphan)
make_bridge "$relaunch_session" "$STATE" relaunch-orphan g1
relaunch_pid=$BRIDGE_PID_RESULT
fm_browser_owner_finalize "$STATE" relaunch-orphan g2 worker-exit \
  || fail "a bridge left by an earlier incarnation of this task was not cleaned up"
wait "$relaunch_pid" 2>/dev/null || true
kill -0 "$relaunch_pid" 2>/dev/null && fail "relaunch orphan cleanup left its bridge running"

# Same home, a DIFFERENT task: not ours, so it is preserved.
fm_browser_owner_arm "$STATE" other-owner o1 >/dev/null
other_session=$(fm_browser_session_for_task "$STATE" other-owner)
make_bridge "$other_session" "$STATE" someone-else
other_pid=$BRIDGE_PID_RESULT
if fm_browser_owner_finalize "$STATE" other-owner o1 worker-exit >/dev/null 2>&1; then
  fail "cleanup stopped a bridge that proved it belongs to another task"
fi
kill -0 "$other_pid" 2>/dev/null || fail "a bridge owned by another task was stopped"
assert_present "$STATE/other-owner.browser/axi.$other_session" \
  "an unproven session preserves its ownership record as evidence"
kill "$other_pid" 2>/dev/null || true
wait "$other_pid" 2>/dev/null || true

# A DIFFERENT home holding the exact same session name - the end state a
# namespace collision produces - cannot finalize this home's live bridge.
colliding_state="$TMP_ROOT/colliding-state"
mkdir -p "$colliding_state"
fm_browser_owner_arm "$STATE" collide-task c1 >/dev/null
collide_session=$(fm_browser_session_for_task "$STATE" collide-task)
make_bridge "$collide_session" "$STATE" collide-task
collide_pid=$BRIDGE_PID_RESULT
fm_browser_owner_arm "$colliding_state" collide-task c1 >/dev/null
rm -f -- "$colliding_state/collide-task.browser"/axi.*
printf '%s\n' "version=1" "kind=axi" "task_id=collide-task" "spawn_gen=c1" \
  "session=$collide_session" > "$colliding_state/collide-task.browser/axi.$collide_session"
if fm_browser_owner_finalize "$colliding_state" collide-task c1 worker-exit >/dev/null 2>&1; then
  fail "a colliding session name let another home finalize this home's bridge"
fi
kill -0 "$collide_pid" 2>/dev/null || fail "a colliding session name closed another home's live bridge"

# An unreadable process environment is unprovable, not permission: it preserves.
# FM_PROC_ROOT_OVERRIDE models a host without readable peer environments, which
# is every non-Linux host.
if FM_PROC_ROOT_OVERRIDE="$TMP_ROOT/absent-proc" \
  fm_browser_owner_finalize "$STATE" collide-task c1 worker-exit >/dev/null 2>&1; then
  fail "cleanup stopped a bridge whose ownership could not be proved"
fi
kill -0 "$collide_pid" 2>/dev/null || fail "unprovable ownership stopped a live bridge"

# With the proof readable again, the owning home still cleans up its own bridge.
fm_browser_owner_finalize "$STATE" collide-task c1 worker-exit \
  || fail "the owning home could not clean up its own bridge"
wait "$collide_pid" 2>/dev/null || true
kill -0 "$collide_pid" 2>/dev/null && fail "the owning home did not stop its own bridge"
assert_absent "$STATE/collide-task.browser" "proven cleanup retires the ownership record"

fm_browser_owner_arm "$STATE" worker-exit w1 >/dev/null
worker_session=$(fm_browser_session_for_task "$STATE" worker-exit)
make_bridge "$worker_session" "$STATE" worker-exit
worker_pid=$BRIDGE_PID_RESULT
set +e
fm_browser_worker_run "$STATE" worker-exit w1 -- bash -c 'exit 7'
worker_rc=$?
set -u
expect_code 7 "$worker_rc" "worker exit preserves its command failure"
assert_absent "$STATE/worker-exit.browser" "worker exit retires named browser ownership"
wait "$worker_pid" 2>/dev/null || true
kill -0 "$worker_pid" 2>/dev/null && fail "worker exit left its owned bridge running"

fm_browser_owner_arm "$STATE" abrupt-exit w2 >/dev/null
abrupt_session=$(fm_browser_session_for_task "$STATE" abrupt-exit)
make_bridge "$abrupt_session" "$STATE" abrupt-exit
abrupt_bridge_pid=$BRIDGE_PID_RESULT
fm_browser_worker_run "$STATE" abrupt-exit w2 -- bash -c 'exec sleep 30' &
abrupt_supervisor=$!
for _ in $(seq 1 100); do
  abrupt_child=$(fm_browser_record_field "$STATE/abrupt-exit.browser/owner" worker_child_pid 2>/dev/null || true)
  [ -n "$abrupt_child" ] && break
  sleep 0.01
done
[ -n "${abrupt_child:-}" ] || fail "worker launch did not record its exact child identity"
for _ in $(seq 1 100); do
  [ ! -e "$STATE/.browser-lifecycle-abrupt-exit.lock" ] && break
  sleep 0.01
done
[ ! -e "$STATE/.browser-lifecycle-abrupt-exit.lock" ] || fail "worker launch did not release its ownership lock"
kill -KILL "$abrupt_supervisor" 2>/dev/null || fail "could not simulate abrupt worker-supervisor loss"
wait "$abrupt_supervisor" 2>/dev/null || true
[ "$(fm_browser_owner_worker_state "$STATE" abrupt-exit w2)" = alive ] \
  || fail "an active exact worker child was not preserved after supervisor loss"
kill -KILL "$abrupt_child" 2>/dev/null || fail "could not simulate abrupt worker-child loss"
for _ in $(seq 1 100); do
  [ "$(fm_browser_owner_worker_state "$STATE" abrupt-exit w2)" = gone ] && break
  sleep 0.01
done
[ "$(fm_browser_owner_worker_state "$STATE" abrupt-exit w2)" = gone ] \
  || fail "abrupt loss did not produce exact worker-exit proof"
fm_browser_owner_finalize "$STATE" abrupt-exit w2 worker-exit
wait "$abrupt_bridge_pid" 2>/dev/null || true
kill -0 "$abrupt_bridge_pid" 2>/dev/null && fail "proven abrupt worker loss left its bridge running"

fm_browser_owner_arm "$STATE" signal-exit w3 >/dev/null
signal_session=$(fm_browser_session_for_task "$STATE" signal-exit)
make_bridge "$signal_session" "$STATE" signal-exit
signal_bridge_pid=$BRIDGE_PID_RESULT
fm_browser_worker_run "$STATE" signal-exit w3 -- bash -c 'exec sleep 30' &
signal_supervisor=$!
WORKER_PIDS+=("$signal_supervisor")
for _ in $(seq 1 100); do
  signal_child=$(fm_browser_record_field "$STATE/signal-exit.browser/owner" worker_child_pid 2>/dev/null || true)
  [ -n "$signal_child" ] && break
  sleep 0.01
done
[ -n "${signal_child:-}" ] || fail "worker launch did not record its signal-test child identity"
WORKER_PIDS+=("$signal_child")
for _ in $(seq 1 100); do
  [ ! -e "$STATE/.browser-lifecycle-signal-exit.lock" ] && break
  sleep 0.01
done
[ ! -e "$STATE/.browser-lifecycle-signal-exit.lock" ] || fail "signal-test worker launch did not release its ownership lock"
kill -TERM "$signal_supervisor" 2>/dev/null || fail "could not signal the worker supervisor"
for _ in $(seq 1 100); do
  if kill -0 "$signal_child" 2>/dev/null && kill -0 "$signal_bridge_pid" 2>/dev/null; then
    break
  fi
  sleep 0.01
done
kill -0 "$signal_child" 2>/dev/null || fail "signal interrupted the active worker child"
kill -0 "$signal_bridge_pid" 2>/dev/null || fail "signal cleanup stopped the active bridge"
kill -KILL "$signal_child" 2>/dev/null || fail "could not stop the signal-test worker child"
wait "$signal_supervisor" 2>/dev/null || true
wait "$signal_bridge_pid" 2>/dev/null || true
kill -0 "$signal_bridge_pid" 2>/dev/null && fail "worker termination did not retire its bridge"

# A live PID with the wrong process identity is never treated as a bridge.
$BROWSER --help >/dev/null || fail "browser lifecycle worker interface is unavailable"
fm_browser_owner_arm "$STATE" task-a s2 >/dev/null
foreign_session=$(fm_browser_session_for_task "$STATE" task-a foreign)
mkdir -p "$HOME/.chrome-devtools-axi/sessions/$foreign_session"
sleep 30 & foreign_pid=$!
printf '{"pid":%s,"port":9231}\n' "$foreign_pid" > "$HOME/.chrome-devtools-axi/sessions/$foreign_session/bridge.pid"
if fm_browser_owner_register_axi "$STATE" task-a s2 "$foreign_session" >/dev/null 2>&1; then
  fail "register-axi adopted a live non-bridge PID"
fi
kill -0 "$foreign_pid" 2>/dev/null || fail "foreign process was killed during ownership proof"
kill "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
fm_browser_owner_finalize "$STATE" task-a s2 no-live-bridge

# A browser command failure does not discard its task ownership record; the
# worker-exit finalizer still retires it through the same lifecycle path.
fm_browser_owner_arm "$STATE" task-a s4 >/dev/null
set +e
FM_BROWSER_STATE="$STATE" FM_BROWSER_TASK_ID=task-a FM_BROWSER_SPAWN_GEN=s4 \
  FM_BROWSER_SESSION=default \
  $BROWSER axi --session failed -- open about:blank >/dev/null 2>&1
launch_rc=$?
set -u
expect_code 42 "$launch_rc" "browser command failure is preserved"
fm_browser_owner_finalize "$STATE" task-a s4 worker-exit

# Direct launches are owned only inside the process group created by the
# wrapper, and a command's failure is returned after its resource is retired.
fm_browser_owner_arm "$STATE" task-a s5 >/dev/null
LOCKED_DIRECT_PID_FILE="$TMP_ROOT/locked-direct-child.pid"
export LOCKED_DIRECT_PID_FILE
fm_browser_lock_take "$STATE" task-a || fail "could not stage the direct-launch ownership lock"
set +e
# shellcheck disable=SC2016 # The nested command expands its own environment.
FM_BROWSER_STATE="$STATE" FM_BROWSER_TASK_ID=task-a FM_BROWSER_SPAWN_GEN=s5 \
  $BROWSER launch -- bash -c 'echo $$ > "$LOCKED_DIRECT_PID_FILE"; exec sleep 30' >/dev/null 2>&1
launch_rc=$?
set -u
expect_code 1 "$launch_rc" "direct launch should refuse while its owner is finalizing"
if [ -e "$LOCKED_DIRECT_PID_FILE" ]; then
  locked_direct_pgid=$(ps -o pgid= -p "$(cat "$LOCKED_DIRECT_PID_FILE")" 2>/dev/null | tr -d '[:space:]')
  [ -z "$locked_direct_pgid" ] || kill -KILL -- "-$locked_direct_pgid" 2>/dev/null || true
  fail "direct launch started a browser process before acquiring its ownership lock"
fi
for pending_status in "$STATE/task-a.browser"/.direct-status.*; do
  [ ! -e "$pending_status" ] || fail "direct launch left pending ownership after lock refusal"
done
fm_browser_lock_release "$(fm_browser_lock_dir "$STATE" task-a)"
fm_browser_owner_finalize "$STATE" task-a s5 lock-refusal

fm_browser_owner_arm "$STATE" task-a s3 >/dev/null
set +e
FM_BROWSER_STATE="$STATE" FM_BROWSER_TASK_ID=task-a FM_BROWSER_SPAWN_GEN=s3 \
  $BROWSER launch -- node -e 'process.exit(7)' >/dev/null 2>&1
launch_rc=$?
set -u
expect_code 7 "$launch_rc" "direct command failure is preserved"

# A command can return successfully while leaving its browser child alive;
# successful completion still closes the exact wrapper group before the
# ownership record is retired.
DIRECT_CHILD_PID_FILE="$TMP_ROOT/direct-child.pid"
export DIRECT_CHILD_PID_FILE
# shellcheck disable=SC2016 # The nested command expands its own environment.
FM_BROWSER_STATE="$STATE" FM_BROWSER_TASK_ID=task-a FM_BROWSER_SPAWN_GEN=s3 \
  $BROWSER launch -- bash -c 'sleep 30 & echo $! > "$DIRECT_CHILD_PID_FILE"; exit 0' >/dev/null 2>&1
DIRECT_CHILD_PID=$(cat "$DIRECT_CHILD_PID_FILE")
for _ in 1 2 3 4 5 6 7 8 9 10; do
  kill -0 "$DIRECT_CHILD_PID" 2>/dev/null || break
  sleep 0.1
done
kill -0 "$DIRECT_CHILD_PID" 2>/dev/null && fail "successful direct launch left its browser child alive"

FM_BROWSER_STATE="$STATE" FM_BROWSER_TASK_ID=task-a FM_BROWSER_SPAWN_GEN=s3 \
  $BROWSER launch --timeout 1 -- node -e 'setTimeout(() => {}, 30000)' >/dev/null 2>&1
launch_rc=$?
expect_code 124 "$launch_rc" "explicit direct timeout is preserved"
for record in "$STATE/task-a.browser"/process.*; do
  [ -e "$record" ] && fail "timed-out direct process record survived"
done

FM_BROWSER_STATE="$STATE" FM_BROWSER_TASK_ID=task-a FM_BROWSER_SPAWN_GEN=s3 \
  $BROWSER launch -- node -e 'setTimeout(() => {}, 30000)' >/dev/null 2>&1 &
launch_wrapper=$!
LAUNCH_PIDS+=("$launch_wrapper")
record=
for _ in 1 2 3 4 5 6 7 8 9 10; do
  for candidate in "$STATE/task-a.browser"/process.*; do
    [ -f "$candidate" ] || continue
    record=$candidate
    break
  done
  [ -n "$record" ] && break
  sleep 0.1
done
[ -n "$record" ] || fail "direct launch did not persist an ownership record"
pid=$(awk -F= '$1 == "pid" {print $2}' "$record")
pgid=$(awk -F= '$1 == "pgid" {print $2}' "$record")
identity=$(sed -n 's/^identity=//p' "$record")
status_file=$(sed -n 's/^status_file=//p' "$record")
printf '%s\n' "version=1" "kind=direct" "task_id=task-a" "spawn_gen=s3" \
  "pid=$pid" "identity=wrong-$identity" "pgid=$pgid" "status_file=$status_file" > "$record"
if fm_browser_owner_finalize "$STATE" task-a s3 mismatched-identity >/dev/null 2>&1; then
  fail "finalizer killed a direct process after identity changed"
fi
kill -0 "$pid" 2>/dev/null || fail "identity mismatch did not preserve the direct process"
printf '%s\n' "version=1" "kind=direct" "task_id=task-a" "spawn_gen=s3" \
  "pid=$pid" "identity=$identity" "pgid=$pgid" "status_file=$status_file" > "$record"
fm_browser_owner_finalize "$STATE" task-a s3 worker-exit
wait "$launch_wrapper" 2>/dev/null || true
assert_absent "$STATE/task-a.browser" "worker-exit cleanup retires the exact direct process group"

pass "browser lifecycle ownership, cross-home isolation, and lifecycle cleanup"
