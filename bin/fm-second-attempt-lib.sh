#!/usr/bin/env bash
# fm-second-attempt-lib.sh - fail-closed Sol-spec gate for second+ implementation workers.
#
# Contract: a ship task whose durable record already carries spawn_gen= must
# not relaunch or start a replacement until a Sol spec exists for that task.
# Prose in AGENTS.md is not the safeguard; these entrypoints refuse mechanically.
#
# Accepted Sol-spec artifact:
#   data/<id>/spec.md   (the task's owned spec path)
# The gate reuses scout+promote and introduces no new control plane.
#
# Triggers (any one with a missing spec refuses):
#   1. bin/fm-control.sh <id> relaunch on a ship that already published
#      spawn_gen=
#   2. bin/fm-spawn.sh <id> --relaunch on the same condition (replacement worker)
#   3. Before another implementation worker starts, the lifecycle entrypoint
#      reads the task worktree's attributed no-mistakes status and records
#      state/<id>.nm-third-fix-round when an active fix round is 3 or later.
#      no-mistakes labels that column `fix <n>`, `auto-fix <n>`, or
#      `auto-fix <n>/<limit>`; all three are read, and the round is always <n>,
#      never the retry <limit>. `round <n>` execution rounds are not fix rounds
#      and are deliberately not matched.
#      The marker also remains a durable fail-closed handoff if no-mistakes is
#      no longer running. Only a payload that parses as a round
#      number strictly below 3 stands the gate down, and an empty or
#      unrecognized payload refuses rather than guessing it meant "not yet".
#      That refusal says the round could not be read and names the marker; it
#      never asserts a round number this repo did not actually read.
#
# Exemptions (callers must still skip secondmate spawns):
#   - First implementation worker (no spawn_gen= in meta yet)
#   - Recovery that does not start another implementation worker
#
# Refusal names the missing artifact path and the next legal action. The gated
# task id is not the scaffolding vehicle: bin/fm-brief.sh refuses to scaffold
# over an existing brief, and every gated task has one. So the refusal directs a
# fresh Sol spec scout task id, which writes its own data/<new-id>/spec.md, and
# then bin/fm-promote.sh <new-id> --sol-spec-for <gated-id> installs that
# reviewed artifact at the gated task's own spec path. The gated task keeps its
# worktree, branch, commits, no-mistakes run, and PR, and the refused action is
# simply repeated. It never guesses a model.
#
# Sourced by bin/fm-control.sh and bin/fm-spawn.sh. No side effects on source.

# shellcheck source=bin/fm-backend.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-backend.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-nm-run-lib.sh"

# fm_second_attempt_spec_path <data-dir> <task-id>
# The task-owned artifact path, alongside the existing scout report path.
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
# A published spawn_gen= means at least one worker incarnation already ran.
fm_second_attempt_meta_had_implementation() {
  local meta=$1
  [ -n "$meta" ] && [ -f "$meta" ] || return 1
  [ -n "$(fm_meta_get "$meta" spawn_gen)" ]
}

# fm_second_attempt_nm_third_fix_round_marker <state-dir> <task-id>
fm_second_attempt_nm_third_fix_round_marker() {
  printf '%s/%s.nm-third-fix-round' "${1%/}" "$2"
}

# fm_second_attempt_round_gt <a> <b>
# Both arguments are digit strings with leading zeros already stripped. `[ -gt ]`
# aborts with "integer expression expected" on a value wider than the shell's
# integers, and the round is produced outside this repo, so ordering is decided
# by digit count first and only then lexically - never by shell arithmetic.
fm_second_attempt_round_gt() {
  local a=$1 b=$2
  [ "${#a}" -eq "${#b}" ] || { [ "${#a}" -gt "${#b}" ]; return; }
  [ "$a" \> "$b" ]
}

# fm_second_attempt_round_reached <round>
# True when a normalized digit string is 3 or more, without arithmetic on a
# value this repo did not produce: anything with two or more digits is >= 10.
fm_second_attempt_round_reached() {
  local round=$1
  case "$round" in ''|*[!0-9]*) return 1 ;; esac
  [ "${#round}" -gt 1 ] || [ "$round" -ge 3 ]
}

# fm_second_attempt_sync_nm_fix_round <state-dir> <task-id> <meta-path>
# Observe the existing no-mistakes status interface at the implementation
# lifecycle chokepoint. Only a run attributed to this task's branch and code
# identity may publish the durable marker. Query failure and older output are
# non-events: the ordinary second-attempt gate still applies independently.
fm_second_attempt_sync_nm_fix_round() {
  local state=$1 id=$2 meta=$3 wt out branch run_branch run_head rows row rest round best marker tmp
  marker=$(fm_second_attempt_nm_third_fix_round_marker "$state" "$id")
  [ ! -e "$marker" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  wt=$(fm_meta_get "$meta" worktree)
  [ -n "$wt" ] && [ -d "$wt" ] || return 0
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || return 0
  out=$(fm_nm_run "$wt" 3 axi status)
  [ -n "$out" ] || return 0
  run_branch=$(fm_nm_strip_quotes "$(fm_nm_field "$out" branch)")
  run_head=$(fm_nm_strip_quotes "$(fm_nm_field "$out" head)")
  [ "$run_branch" = "$branch" ] || return 0
  fm_nm_head_matches_worktree "$wt" "$run_head" || return 0
  rows=$(printf '%s\n' "$out" \
    | grep -E '^[[:space:]]*[^,]+,[[:space:]]*"?fixing"?,.*,[[:space:]]*"?(auto-)?fix[[:space:]]+[0-9]+(/[0-9]+)?"?[[:space:]]*$')
  [ -n "$rows" ] || return 0
  best=
  while IFS= read -r row; do
    [ -n "$row" ] || continue
    rest=${row##*,}
    rest=$(fm_nm_strip_quotes "$rest")
    round=${rest##*[[:space:]]}
    round=${round%%/*}
    case "$round" in ''|*[!0-9]*) continue ;; esac
    while [ "${#round}" -gt 1 ] && [ "${round#0}" != "$round" ]; do
      round=${round#0}
    done
    [ -z "$best" ] || fm_second_attempt_round_gt "$round" "$best" || continue
    best=$round
  done <<EOF
$rows
EOF
  [ -n "$best" ] || return 0
  fm_second_attempt_round_reached "$best" || return 0
  mkdir -p "$state" || return 0
  tmp="$marker.tmp.$$"
  ( umask 077; printf '%s\n' "$best" > "$tmp" ) || { rm -f -- "$tmp"; return 0; }
  mv -f -- "$tmp" "$marker" || { rm -f -- "$tmp"; return 0; }
}

# fm_second_attempt_nm_fix_round_state <state-dir> <task-id>
# Prints nothing. Always sets FM_SECOND_ATTEMPT_NM_MARKER_STATE to exactly one
# of:
#   absent      no marker file
#   below       payload read as a round number strictly below 3
#   reached     payload read as a round number of 3 or more
#   unreadable  marker present, payload not a round number this repo can read
# FM_SECOND_ATTEMPT_NM_MARKER_ROUND carries the round actually read for `below`
# and `reached`, and is empty otherwise, so a refusal reports the observed round
# rather than restating the threshold.
# Only `below` stands the gate down. `unreadable` is deliberately gate-active -
# the producer lives outside this repo, so an unrecognized payload must not
# silently stand a fail-closed gate down - but it stays a distinct state so the
# refusal can report what was actually observed.
fm_second_attempt_nm_fix_round_state() {
  local marker round
  FM_SECOND_ATTEMPT_NM_MARKER_STATE=absent
  FM_SECOND_ATTEMPT_NM_MARKER_ROUND=
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
  FM_SECOND_ATTEMPT_NM_MARKER_ROUND=$round
  if fm_second_attempt_round_reached "$round"; then
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
  [ "$kind" = ship ] || return 0
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
  local reason spec next marker kind task_kind round
  kind=$(fm_meta_get "$meta" kind)
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 0
  fm_second_attempt_sync_nm_fix_round "$state" "$id" "$meta"
  fm_second_attempt_gate_reason "$state" "$data" "$id" "$meta" "$trigger"
  reason=$FM_SECOND_ATTEMPT_GATE_REASON
  [ "$reason" != none ] || return 0
  fm_second_attempt_spec_present "$data" "$id" && return 0
  spec=$(fm_second_attempt_spec_path "$data" "$id")
  task_kind="$kind task"
  next="commission a Sol spec scout under a fresh task id (fm-brief.sh <new-scout-id> <repo> --scout --sol-spec), let that scout write its own data/<new-scout-id>/spec.md, then install it for this task with fm-promote.sh <new-scout-id> --sol-spec-for $id and repeat this action; $id keeps its worktree, branch, commits, and PR, do not treat report.md as the spec and do not guess a model"
  case "$reason" in
    relaunch)
      echo "error: relaunch of $task_kind $id refused - no Sol spec at $spec; $next" >&2
      ;;
    replacement_spawn)
      echo "error: replacement spawn for $task_kind $id refused - no Sol spec at $spec; $next" >&2
      ;;
    nm_third_fix_round)
      round=${FM_SECOND_ATTEMPT_NM_MARKER_ROUND:-3}
      echo "error: $task_kind $id reached no-mistakes fix round $round without a Sol spec at $spec; $next" >&2
      ;;
    nm_fix_round_unreadable)
      marker=$(fm_second_attempt_nm_third_fix_round_marker "$state" "$id")
      echo "error: $task_kind $id has a no-mistakes fix-round marker at $marker whose round could not be read, and no Sol spec at $spec; $next" >&2
      ;;
    *)
      echo "error: $task_kind $id refused - no Sol spec at $spec; $next" >&2
      ;;
  esac
  return 1
}
