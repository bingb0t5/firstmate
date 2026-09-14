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
DIRECT_CHILD_PID=

cleanup_processes() {
  local pid
  for pid in "${BRIDGE_PIDS[@]:-}" "${LAUNCH_PIDS[@]:-}" \
    "${BROWSER_GROUP_PIDS[@]:-}" "$DIRECT_CHILD_PID"; do
    [ -n "$pid" ] || continue
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
}
trap 'cleanup_processes' EXIT INT TERM

make_bridge() {  # <session>
  local session=$1 bridge_dir bridge
  bridge_dir="$HOME/.chrome-devtools-axi/sessions/$session"
  bridge="$TMP_ROOT/fakebin/chrome-devtools-axi-bridge-$session"
  mkdir -p "$bridge_dir"
  cat > "$bridge" <<'SH'
#!/usr/bin/env bash
trap 'exit 0' TERM INT
while :; do sleep 1; done
SH
  chmod +x "$bridge"
  "$bridge" &
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

session_a=$($BROWSER session-for-task task-a)
session_b=$($BROWSER session-for-task task-b)
[ "$session_a" != "$session_b" ] || fail "different tasks received the same browser session"
[ "${#session_a}" -le 64 ] || fail "derived browser session exceeded chrome-devtools-axi's limit"

$BROWSER arm "$STATE" task-a s1 >/dev/null
assert_grep "task_id=task-a" "$STATE/task-a.browser/owner" "arm records the owning task"
assert_grep "spawn_gen=s1" "$STATE/task-a.browser/owner" "arm records the owning incarnation"
assert_grep "session=$session_a" "$STATE/task-a.browser/axi.$session_a" "arm reserves the default named session"

if $BROWSER arm "$STATE" task-a s2 >/dev/null 2>&1; then
  fail "arm adopted a different incarnation"
fi

make_bridge held
held_pid=$BRIDGE_PID_RESULT
if HOME="$HOME" $BROWSER register-axi "$STATE" task-a s1 held >/dev/null 2>&1; then
  fail "register-axi adopted an already active bridge"
fi
kill -0 "$held_pid" 2>/dev/null || fail "active foreign browser session was stopped"

$BROWSER register-axi "$STATE" task-a s1 custom
custom_pid_file="$HOME/.chrome-devtools-axi/sessions/custom/bridge.pid"
make_bridge custom
custom_pid=$BRIDGE_PID_RESULT
export FM_BROWSER_LOG="$TMP_ROOT/browser-stop.log"
FM_BROWSER_AXI_BIN="$TMP_ROOT/fakebin/chrome-devtools-axi" \
  $BROWSER finalize "$STATE" task-a s1 named-session
assert_grep "custom stop" "$FM_BROWSER_LOG" "finalizer delegates named-session cleanup to chrome-devtools-axi"
assert_absent "$STATE/task-a.browser" "successful named-session cleanup retires ownership records"
wait "$custom_pid" 2>/dev/null || true
kill -0 "$custom_pid" 2>/dev/null && fail "named bridge survived delegated stop"
[ ! -e "$custom_pid_file" ] || fail "stale named bridge PID file survived cleanup"

# A live PID with the wrong process identity is never treated as a bridge.
$BROWSER arm "$STATE" task-a s2 >/dev/null
mkdir -p "$HOME/.chrome-devtools-axi/sessions/foreign"
sleep 30 & foreign_pid=$!
printf '{"pid":%s,"port":9231}\n' "$foreign_pid" > "$HOME/.chrome-devtools-axi/sessions/foreign/bridge.pid"
if $BROWSER register-axi "$STATE" task-a s2 foreign >/dev/null 2>&1; then
  fail "register-axi adopted a live non-bridge PID"
fi
kill -0 "$foreign_pid" 2>/dev/null || fail "foreign process was killed during ownership proof"
kill "$foreign_pid" 2>/dev/null || true
wait "$foreign_pid" 2>/dev/null || true
$BROWSER finalize "$STATE" task-a s2 no-live-bridge

# A browser command failure does not discard its task ownership record; the
# worker-exit finalizer still retires it through the same lifecycle path.
$BROWSER arm "$STATE" task-a s4 >/dev/null
set +e
FM_BROWSER_STATE="$STATE" FM_BROWSER_TASK_ID=task-a FM_BROWSER_SPAWN_GEN=s4 \
  FM_BROWSER_SESSION="$session_a" FM_BROWSER_AXI_BIN="$TMP_ROOT/fakebin/chrome-devtools-axi" \
  $BROWSER axi --session failed -- open about:blank >/dev/null 2>&1
launch_rc=$?
set -u
expect_code 42 "$launch_rc" "browser command failure is preserved"
$BROWSER finalize "$STATE" task-a s4 worker-exit

# Direct launches are owned only inside the process group created by the
# wrapper, and a command's failure is returned after its resource is retired.
$BROWSER arm "$STATE" task-a s3 >/dev/null
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
if $BROWSER finalize "$STATE" task-a s3 mismatched-identity >/dev/null 2>&1; then
  fail "finalizer killed a direct process after identity changed"
fi
kill -0 "$pid" 2>/dev/null || fail "identity mismatch did not preserve the direct process"
printf '%s\n' "version=1" "kind=direct" "task_id=task-a" "spawn_gen=s3" \
  "pid=$pid" "identity=$identity" "pgid=$pgid" "status_file=$status_file" > "$record"
$BROWSER finalize "$STATE" task-a s3 worker-exit
wait "$launch_wrapper" 2>/dev/null || true
assert_absent "$STATE/task-a.browser" "worker-exit cleanup retires the exact direct process group"

pass "browser lifecycle ownership and lifecycle cleanup"
