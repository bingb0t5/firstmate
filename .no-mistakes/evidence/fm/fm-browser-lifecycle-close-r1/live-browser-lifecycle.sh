#!/usr/bin/env bash
# Product-level Linux validation of ownership proof with a real chrome-devtools-axi bridge.
set -euo pipefail

ROOT=/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M2KY50B7PWS448F9CDC2399F
EVIDENCE=/home/rich/.no-mistakes/evidence/01M2KY50B7PWS448F9CDC2399F
WORK=$(mktemp -d "$ROOT/.live-browser-lifecycle.XXXXXX")
HOME="$WORK/home"
STATE_A="$WORK/state-a"
STATE_B="$WORK/state-b"
export HOME

# shellcheck source=bin/fm-browser-lifecycle-lib.sh
. "$ROOT/bin/fm-browser-lifecycle-lib.sh"

cleanup() {
  local task generation
  for task_generation in live-task:live-gen worker-complete:complete-gen worker-failure:failure-gen abrupt-worker:abrupt-gen; do
    task=${task_generation%%:*}
    generation=${task_generation#*:}
    if [ -d "$STATE_A/$task.browser" ]; then
      fm_browser_owner_finalize "$STATE_A" "$task" "$generation" test-cleanup >/dev/null 2>&1 || true
    fi
  done
  rm -rf -- "$WORK"
}
trap cleanup EXIT INT TERM

mkdir -p "$HOME" "$STATE_A" "$STATE_B"

session=$(fm_browser_owner_arm "$STATE_A" live-task live-gen)
printf 'derived_session=%s\n' "$session"

FM_BROWSER_STATE="$STATE_A" FM_BROWSER_TASK_ID=live-task FM_BROWSER_SPAWN_GEN=live-gen \
  "$ROOT/bin/fm-browser-lifecycle.sh" axi -- \
  open 'data:text/html,<main style="font-family:system-ui"><h1>Firstmate browser lifecycle</h1><p>Real bridge ownership validation</p></main>'

FM_BROWSER_STATE="$STATE_A" FM_BROWSER_TASK_ID=live-task FM_BROWSER_SPAWN_GEN=live-gen \
  "$ROOT/bin/fm-browser-lifecycle.sh" axi -- screenshot "$EVIDENCE/live-browser-lifecycle.png"

bridge_pid=$(fm_browser_axi_pid_value "$session")
printf 'bridge_pid=%s\n' "$bridge_pid"
fm_browser_bridge_owned_by "$bridge_pid" "$STATE_A" live-task
printf 'owning_bridge_env=proved\n'
tr '\0' '\n' < "/proc/$bridge_pid/environ" | \
  awk -F= '$1 == "FM_BROWSER_STATE" || $1 == "FM_BROWSER_TASK_ID" {print $0}'

# Simulate the exact shared-session collision outcome: a second home owns a
# local record for the same global session name, while the live bridge proves
# it was launched by the first home.
fm_browser_owner_arm "$STATE_B" live-task live-gen >/dev/null
rm -f -- "$STATE_B/live-task.browser"/axi.*
cp "$STATE_A/live-task.browser/axi.$session" "$STATE_B/live-task.browser/axi.$session"
if fm_browser_owner_finalize "$STATE_B" live-task live-gen cross-home-attempt; then
  printf 'cross_home_result=UNEXPECTED_STOP\n' >&2
  exit 1
fi
kill -0 "$bridge_pid"
[ -f "$HOME/.chrome-devtools-axi/sessions/$session/bridge.pid" ]
printf 'cross_home_result=refused_bridge_survived\n'

fm_browser_owner_finalize "$STATE_A" live-task live-gen owning-worker-exit
for _ in $(seq 1 50); do
  case "$(fm_browser_axi_pid_state "$session")" in
    absent|dead) break ;;
  esac
  sleep 0.1
done
case "$(fm_browser_axi_pid_state "$session")" in
  absent|dead) ;;
  *) printf 'owner_cleanup_result=bridge_still_active\n' >&2; exit 1 ;;
esac
[ ! -e "$STATE_A/live-task.browser" ]
printf 'owner_cleanup_result=bridge_stopped_owner_retired\n'

# Run the lifecycle primitive against additional real bridges so completion,
# failure, and an abrupt worker loss all exercise the same ownership close.
run_worker_case() { # <task> <generation> <worker-command...>
  local task=$1 generation=$2 session_case rc
  shift 2
  session_case=$(fm_browser_owner_arm "$STATE_A" "$task" "$generation")
  FM_BROWSER_STATE="$STATE_A" FM_BROWSER_TASK_ID="$task" FM_BROWSER_SPAWN_GEN="$generation" \
    "$ROOT/bin/fm-browser-lifecycle.sh" axi -- open 'data:text/html,<p>worker lifecycle case</p>' >/dev/null
  set +e
  ( fm_browser_worker_run "$STATE_A" "$task" "$generation" -- "$@" )
  rc=$?
  set -e
  case "$task:$rc" in
    worker-complete:0|worker-failure:7) ;;
    *) printf 'worker_case=%s unexpected_exit=%s\n' "$task" "$rc" >&2; exit 1 ;;
  esac
  case "$(fm_browser_axi_pid_state "$session_case")" in
    absent|dead) ;;
    *) printf 'worker_case=%s bridge_still_active\n' "$task" >&2; exit 1 ;;
  esac
  [ ! -e "$STATE_A/$task.browser" ]
  printf 'worker_case=%s bridge_stopped_owner_retired\n' "$task"
}

run_worker_case worker-complete complete-gen bash -c 'exit 0'
run_worker_case worker-failure failure-gen bash -c 'exit 7'

abrupt_session=$(fm_browser_owner_arm "$STATE_A" abrupt-worker abrupt-gen)
FM_BROWSER_STATE="$STATE_A" FM_BROWSER_TASK_ID=abrupt-worker FM_BROWSER_SPAWN_GEN=abrupt-gen \
  "$ROOT/bin/fm-browser-lifecycle.sh" axi -- open 'data:text/html,<p>abrupt lifecycle case</p>' >/dev/null
fm_browser_worker_run "$STATE_A" abrupt-worker abrupt-gen -- bash -c 'exec sleep 30' &
abrupt_supervisor=$!
for _ in $(seq 1 50); do
  abrupt_child=$(fm_browser_record_field "$STATE_A/abrupt-worker.browser/owner" worker_child_pid 2>/dev/null || true)
  [ -n "$abrupt_child" ] && break
  sleep 0.1
done
[ -n "${abrupt_child:-}" ]
kill -KILL "$abrupt_supervisor"
wait "$abrupt_supervisor" 2>/dev/null || true
[ "$(fm_browser_owner_worker_state "$STATE_A" abrupt-worker abrupt-gen)" = alive ]
kill -KILL "$abrupt_child"
for _ in $(seq 1 50); do
  [ "$(fm_browser_owner_worker_state "$STATE_A" abrupt-worker abrupt-gen)" = gone ] && break
  sleep 0.1
done
[ "$(fm_browser_owner_worker_state "$STATE_A" abrupt-worker abrupt-gen)" = gone ]
fm_browser_owner_finalize "$STATE_A" abrupt-worker abrupt-gen proven-abrupt-worker-exit
case "$(fm_browser_axi_pid_state "$abrupt_session")" in
  absent|dead) ;;
  *) printf 'abrupt_worker_case=bridge_still_active\n' >&2; exit 1 ;;
esac
[ ! -e "$STATE_A/abrupt-worker.browser" ]
printf 'abrupt_worker_case=bridge_stopped_after_exact_death\n'
