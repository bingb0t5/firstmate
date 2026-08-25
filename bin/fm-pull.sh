#!/usr/bin/env bash
# Select and claim one eligible local worker task, then compose fm-spawn.
#
# Usage:
#   fm-pull.sh ready [--json]
#   fm-pull.sh start <id> <project-dir> <existing fm-spawn flags...>
#
# This command operates only on the active FM_HOME. `ready` is read-only and
# reports every backlog row with its mechanical eligibility reason. `start`
# holds the home's existing task-set lock while it recomputes attention, checks
# priority order, and creates the tasks-axi In flight reservation. It releases
# that lock only before invoking fm-spawn.sh, whose own fresh-spawn backstop
# recomputes the same local limit while holding the same lock.
#
# A failed spawn with no published metadata intentionally leaves the In flight
# row as an unknown reservation. Retrying the same id resumes that reservation;
# another id cannot consume its slot. Recovery owns proving that an uncertain
# reservation has no endpoint or unlanded work before reopening it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"

# shellcheck source=bin/fm-wake-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-wake-lib.sh"

usage() {
  cat >&2 <<'EOF'
usage: fm-pull.sh ready [--json]
       fm-pull.sh start <id> <project-dir> <existing fm-spawn flags...>
EOF
}

snapshot_local() {
  local config projects
  config=${FM_CONFIG_OVERRIDE:-$FM_HOME/config}
  projects=${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}
  FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    FM_CONFIG_OVERRIDE="$config" FM_PROJECTS_OVERRIDE="$projects" \
    "$SCRIPT_DIR/fm-fleet-snapshot.sh" --local-json
}

task_set_lock=
release_task_set_lock() {
  if [ -n "$task_set_lock" ]; then
    fm_lock_release "$task_set_lock" || true
    task_set_lock=
  fi
}
trap release_task_set_lock EXIT
trap 'exit 1' HUP INT TERM

ready_command() {
  local snapshot
  snapshot=$(snapshot_local) || {
    echo "error: local snapshot could not produce complete pull facts; refusing" >&2
    return 1
  }
  if [ "${1:-}" = --json ]; then
    [ "$#" -eq 1 ] || { usage; return 2; }
    jq -n --argjson snapshot "$snapshot" \
      '{schema:"fm-pull.v1",fm_home:$snapshot.fm_home,generated:$snapshot.generated,
        attention:$snapshot.attention,pull:$snapshot.pull}'
    return 0
  fi
  [ "$#" -eq 0 ] || { usage; return 2; }
  printf 'attention count=%s limit=%s remaining=%s\n' \
    "$(printf '%s' "$snapshot" | jq -r '.attention.count')" \
    "$(printf '%s' "$snapshot" | jq -r '.attention.limit')" \
    "$(printf '%s' "$snapshot" | jq -r '.attention.remaining')"
  printf '%s\n' "$snapshot" | jq -r '
    (.pull.eligible[] |
      "eligible \(.id) priority=\(.priority) since=\(.since // "") kind=\(.kind) title=\(.title)"),
    (.pull.ineligible[] |
      "ineligible \(.id) reason=\(.pull_reason) priority=\(.priority // "") since=\(.since // "") kind=\(.kind // "") title=\(.title)")'
}

start_command() {
  local id project snapshot attention count reservation first row_state brief
  local -a spawn_args
  id=${1:-}
  project=${2:-}
  [ -n "$id" ] && [ -n "$project" ] || { usage; return 2; }
  shift 2
  spawn_args=("$@")
  case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: invalid task id: $id" >&2; return 2 ;; esac
  brief="$DATA/$id/brief.md"
  [ -f "$brief" ] || { echo "error: task $id has no existing brief at $brief" >&2; return 1; }

  task_set_lock=$(fm_task_set_lock_path "$STATE") || {
    echo "error: could not resolve the task-set lock for $STATE" >&2
    return 1
  }
  if ! fm_lock_try_acquire "$task_set_lock"; then
    echo "error: this home's task set is locked by another operation; refusing to pull $id" >&2
    return 1
  fi

  snapshot=$(snapshot_local) || {
    echo "error: local snapshot could not produce complete attention facts; refusing to pull $id" >&2
    return 1
  }
  attention=$(printf '%s' "$snapshot" | jq -c '.attention')
  [ "$(printf '%s' "$attention" | jq -r '.valid')" = true ] || {
    echo "error: local attention facts are invalid; refusing to pull $id" >&2
    return 1
  }
  count=$(printf '%s' "$attention" | jq -r '.count')
  reservation=$(printf '%s' "$attention" | jq -r --arg id "$id" \
    'any(.reservations[]?; .id == $id)')
  row_state=$(printf '%s' "$snapshot" | jq -r --arg id "$id" \
    '[.backlog.records[]? | select(.structured == true and .id == $id) | .state][0] // "missing"')

  if [ "$reservation" = true ]; then
    [ "$row_state" = in_flight ] || {
      echo "error: reservation for $id is not an In flight backlog row; refusing" >&2
      return 1
    }
    echo "resuming unknown reservation $id" >&2
  else
    [ "$row_state" = queued ] || {
      echo "error: task $id is not a queued local task (state: $row_state)" >&2
      return 1
    }
    first=$(printf '%s' "$snapshot" | jq -r '.pull.eligible[0].id // ""')
    [ "$first" = "$id" ] || {
      if [ -n "$first" ]; then
        echo "error: task $id is not first eligible local task; pull $first" >&2
      else
        echo "error: task $id is not eligible for local pull" >&2
      fi
      return 1
    }
    [ "$count" -lt 4 ] || {
      echo "error: local attention limit reached (count=$count limit=4); refusing before backlog mutation" >&2
      return 1
    }
    (cd "$FM_HOME" && tasks-axi start "$id") || {
      echo "error: tasks-axi could not reserve $id; no worker was spawned" >&2
      return 1
    }
  fi

  release_task_set_lock
  if ! FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
    FM_STATE_OVERRIDE="$STATE" FM_DATA_OVERRIDE="$DATA" \
    "$FM_ROOT/bin/fm-spawn.sh" "$id" "$project" "${spawn_args[@]}"; then
    echo "error: spawn for $id failed; its In flight row remains as a visible unknown reservation" >&2
    return 1
  fi
}

case "${1:-}" in
  ready)
    shift
    ready_command "$@"
    ;;
  start)
    shift
    start_command "$@"
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage
    exit 2
    ;;
esac
