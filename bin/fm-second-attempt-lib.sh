#!/usr/bin/env bash
# fm-second-attempt-lib.sh - fail-closed Sol-spec gate for second+ implementation workers.
#
# Fable change 1 (2026-08-25): a ship task's second implementation worker, or any
# later one, must not start until a Sol spec artifact exists for that task.
# Prose in AGENTS.md is not the safeguard; these entrypoints refuse mechanically.
#
# Accepted Sol-spec artifacts:
#   data/<id>/report.md (the existing scout deliverable)
#   data/<id>/spec.md   (the task's owned spec path)
# The gate reuses scout+promote and introduces no new control plane.
#
# Triggers (any one with a missing spec refuses):
#   1. bin/fm-control.sh <id> relaunch on a ship or scout that already published
#      spawn_gen=
#   2. bin/fm-spawn.sh <id> --relaunch on the same condition (replacement worker)
#   3. state/<id>.nm-third-fix-round present before another implementation
#      worker starts (no-mistakes should write this marker when a validation run
#      enters its third fix round; until that integration ships, firstmate
#      refuses on the recorded marker alone). The marker's payload is not owned
#      by this repo, so presence gates: only a payload that parses as a round
#      number strictly below 3 stands the gate down, and an empty or
#      unrecognized payload refuses rather than guessing it meant "not yet".
#      That refusal says the round could not be read and names the marker; it
#      never asserts a round number this repo did not actually read.
#
# Exemptions (callers must still skip secondmate spawns):
#   - First implementation worker (no spawn_gen= in meta yet)
#   - Recovery that does not start another implementation worker
#
# Refusal names both missing artifact paths and the next legal action -
# commission a Sol spec scout for this task; it never guesses a model.
#
# Sourced by bin/fm-control.sh and bin/fm-spawn.sh. No side effects on source.

# shellcheck source=bin/fm-backend.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend.sh"

# fm_second_attempt_spec_path <data-dir> <task-id>
# The task-owned artifact path, alongside the existing scout report path.
fm_second_attempt_spec_path() {
  printf '%s/%s/spec.md' "${1%/}" "$2"
}

# fm_second_attempt_spec_present <data-dir> <task-id>
fm_second_attempt_spec_present() {
  local spec report
  spec=$(fm_second_attempt_spec_path "$1" "$2")
  report="${1%/}/$2/report.md"
  [ -f "$report" ] || [ -f "$spec" ]
}

# fm_second_attempt_meta_had_implementation <meta-path>
# A published spawn_gen= means at least one implementation worker already ran.
fm_second_attempt_meta_had_implementation() {
  local meta=$1
  [ -n "$meta" ] && [ -f "$meta" ] || return 1
  [ -n "$(fm_meta_get "$meta" spawn_gen)" ]
}

# fm_second_attempt_nm_third_fix_round_marker <state-dir> <task-id>
fm_second_attempt_nm_third_fix_round_marker() {
  printf '%s/%s.nm-third-fix-round' "${1%/}" "$2"
}

# fm_second_attempt_nm_fix_round_state <state-dir> <task-id>
# Prints nothing. Always sets FM_SECOND_ATTEMPT_NM_MARKER_STATE to exactly one
# of:
#   absent      no marker file
#   below       payload read as a round number strictly below 3
#   reached     payload read as a round number of 3 or more
#   unreadable  marker present, payload not a round number this repo can read
# Only `below` stands the gate down. `unreadable` is deliberately gate-active -
# the producer lives outside this repo, so an unrecognized payload must not
# silently stand a fail-closed gate down - but it stays a distinct state so the
# refusal can report what was actually observed.
fm_second_attempt_nm_fix_round_state() {
  local marker round
  FM_SECOND_ATTEMPT_NM_MARKER_STATE=absent
  marker=$(fm_second_attempt_nm_third_fix_round_marker "$1" "$2")
  [ -f "$marker" ] || return 0
  FM_SECOND_ATTEMPT_NM_MARKER_STATE=unreadable
  round=$(tr -d '[:space:]' < "$marker" 2>/dev/null || true)
  case "$round" in
    ''|*[!0-9]*) return 0 ;;
  esac
  while [ "${#round}" -gt 1 ] && [ "${round#0}" != "$round" ]; do
    round=${round#0}
  done
  if [ "${#round}" -gt 1 ] || [ "$round" -ge 3 ]; then
    FM_SECOND_ATTEMPT_NM_MARKER_STATE=reached
  else
    FM_SECOND_ATTEMPT_NM_MARKER_STATE=below
  fi
}

# fm_second_attempt_gate_reason <state-dir> <data-dir> <task-id> <meta-path> <trigger>
# Prints nothing. Always sets FM_SECOND_ATTEMPT_GATE_REASON to exactly one of
# none, relaunch, replacement_spawn, nm_third_fix_round, or
# nm_fix_round_unreadable, and read the gate only from that variable: a command
# substitution around this call captures an empty string, which matches no label
# and would read as an inactive gate.
fm_second_attempt_gate_reason() {
  local state=$1 data=$2 id=$3 meta=$4 trigger=$5 kind
  FM_SECOND_ATTEMPT_GATE_REASON=none
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  case "$kind" in
    ship|scout) ;;
    *) return 0 ;;
  esac
  fm_second_attempt_nm_fix_round_state "$state" "$id"
  case "$FM_SECOND_ATTEMPT_NM_MARKER_STATE" in
    reached)
      FM_SECOND_ATTEMPT_GATE_REASON=nm_third_fix_round
      return 0
      ;;
    unreadable)
      FM_SECOND_ATTEMPT_GATE_REASON=nm_fix_round_unreadable
      return 0
      ;;
  esac
  case "$trigger" in
    relaunch|replacement_spawn)
      if fm_second_attempt_meta_had_implementation "$meta"; then
        FM_SECOND_ATTEMPT_GATE_REASON=$trigger
      fi
      ;;
  esac
}

# fm_second_attempt_refuse_if_needed <state-dir> <data-dir> <task-id> <meta-path> <trigger>
# Returns 1 after printing a concrete refusal to stderr when the gate is active
# and the spec is absent; returns 0 otherwise. Callers own the exit.
fm_second_attempt_refuse_if_needed() {
  local state=$1 data=$2 id=$3 meta=$4 trigger=$5
  local reason spec report next marker kind task_kind
  fm_second_attempt_gate_reason "$state" "$data" "$id" "$meta" "$trigger"
  reason=$FM_SECOND_ATTEMPT_GATE_REASON
  [ "$reason" != none ] || return 0
  fm_second_attempt_spec_present "$data" "$id" && return 0
  spec=$(fm_second_attempt_spec_path "$data" "$id")
  report="${data%/}/$id/report.md"
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  task_kind="$kind task"
  next="commission a Sol spec scout for this task before starting another implementation worker; do not guess a model"
  case "$reason" in
    relaunch)
      echo "error: relaunch of $task_kind $id refused - no Sol spec at $report or $spec; $next" >&2
      ;;
    replacement_spawn)
      echo "error: replacement spawn for $task_kind $id refused - no Sol spec at $report or $spec; $next" >&2
      ;;
    nm_third_fix_round)
      echo "error: $task_kind $id reached no-mistakes fix round 3 without a Sol spec at $report or $spec; $next" >&2
      ;;
    nm_fix_round_unreadable)
      marker=$(fm_second_attempt_nm_third_fix_round_marker "$state" "$id")
      echo "error: $task_kind $id has a no-mistakes fix-round marker at $marker whose round could not be read, and no Sol spec at $report or $spec; $next" >&2
      ;;
    *)
      echo "error: $task_kind $id refused - no Sol spec at $report or $spec; $next" >&2
      ;;
  esac
  return 1
}
