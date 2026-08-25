#!/usr/bin/env bash
# fm-second-attempt-lib.sh - fail-closed Sol-spec gate for second+ implementation workers.
#
# Fable change 1 (2026-08-25): a ship task's second implementation worker, or any
# later one, must not start until a Sol spec artifact exists for that task.
# Prose in AGENTS.md is not the safeguard; these entrypoints refuse mechanically.
#
# Spec artifact - exactly one owned path:
#   data/<id>/spec.md
# data/<id>/report.md is deliberately NOT accepted: it is the scout deliverable
# for the same task id (bin/fm-brief.sh), and bin/fm-promote.sh flips kind=scout
# to kind=ship in place, so a pre-implementation scout report would otherwise
# clear this gate without any Sol spec pass ever happening. Placing the spec is
# an ordinary file copy (a Sol spec scout's report copied to data/<id>/spec.md);
# there is no new control plane for it.
#
# Triggers (any one with a missing spec refuses):
#   1. bin/fm-control.sh <id> relaunch on a ship that already published spawn_gen=
#   2. bin/fm-spawn.sh <id> --relaunch on the same condition (replacement worker)
#   3. state/<id>.nm-third-fix-round present with value >= 3 before another
#      implementation worker starts (no-mistakes should write this marker when a
#      validation run enters its third fix round; until that integration ships,
#      firstmate refuses on the recorded marker alone)
#
# Exemptions (callers must still skip secondmate spawns):
#   - First implementation worker (no spawn_gen= in meta yet)
#   - kind=scout (investigation, not implementation)
#   - Recovery that does not start another implementation worker
#
# Refusal names the missing data/<id>/spec.md path and the next legal action -
# commission a Sol spec scout for this task and copy its report to that path; it
# never guesses a model.
#
# Sourced by bin/fm-control.sh and bin/fm-spawn.sh. No side effects on source.

# shellcheck source=bin/fm-backend.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend.sh"

# fm_second_attempt_spec_path <data-dir> <task-id>
# The one artifact this gate owns. Never data/<id>/report.md, which on the
# scout+promote path predates the first implementation attempt.
fm_second_attempt_spec_path() {
  printf '%s/%s/spec.md' "${1%/}" "$2"
}

# fm_second_attempt_spec_present <data-dir> <task-id>
fm_second_attempt_spec_present() {
  local spec
  spec=$(fm_second_attempt_spec_path "$1" "$2")
  [ -f "$spec" ]
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

# fm_second_attempt_nm_fix_round_gate_active <state-dir> <task-id>
# True when the durable third-fix-round marker is present with value >= 3.
fm_second_attempt_nm_fix_round_gate_active() {
  local marker round
  marker=$(fm_second_attempt_nm_third_fix_round_marker "$1" "$2")
  [ -f "$marker" ] || return 1
  round=$(tr -d '[:space:]' < "$marker" 2>/dev/null || true)
  case "$round" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$round" -ge 3 ]
}

# fm_second_attempt_gate_reason <state-dir> <data-dir> <task-id> <meta-path> <trigger>
# Prints one of: none, relaunch, replacement_spawn, nm_third_fix_round. Sets
# FM_SECOND_ATTEMPT_GATE_REASON on match.
fm_second_attempt_gate_reason() {
  local state=$1 data=$2 id=$3 meta=$4 trigger=$5 kind
  FM_SECOND_ATTEMPT_GATE_REASON=none
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 0
  if fm_second_attempt_nm_fix_round_gate_active "$state" "$id"; then
    FM_SECOND_ATTEMPT_GATE_REASON=nm_third_fix_round
    return 0
  fi
  case "$trigger" in
    relaunch|replacement_spawn)
      if fm_second_attempt_meta_had_implementation "$meta"; then
        FM_SECOND_ATTEMPT_GATE_REASON=$trigger
      fi
      ;;
  esac
}

# fm_second_attempt_refuse_if_needed <state-dir> <data-dir> <task-id> <meta-path> <trigger>
# Exits 1 with a concrete refusal when the gate is active and the spec is absent.
fm_second_attempt_refuse_if_needed() {
  local state=$1 data=$2 id=$3 meta=$4 trigger=$5
  local reason spec next
  fm_second_attempt_gate_reason "$state" "$data" "$id" "$meta" "$trigger"
  reason=$FM_SECOND_ATTEMPT_GATE_REASON
  [ "$reason" != none ] || return 0
  fm_second_attempt_spec_present "$data" "$id" && return 0
  spec=$(fm_second_attempt_spec_path "$data" "$id")
  next="commission a Sol spec scout for this task and copy its report to $spec before starting another implementation worker"
  case "$reason" in
    relaunch)
      echo "error: relaunch of ship task $id refused - no Sol spec at $spec; $next" >&2
      ;;
    replacement_spawn)
      echo "error: replacement spawn for ship task $id refused - no Sol spec at $spec; $next" >&2
      ;;
    nm_third_fix_round)
      echo "error: ship task $id reached no-mistakes fix round 3 without a Sol spec at $spec; $next" >&2
      ;;
    *)
      echo "error: ship task $id refused - no Sol spec at $spec; $next" >&2
      ;;
  esac
  return 1
}
