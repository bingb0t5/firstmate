#!/usr/bin/env bash
# fm-home-identity-lib.sh - fail-closed refusal that keeps one firstmate home's
# process out of ANOTHER home's operational surface.
#
# The hazard: FM_HOME selects which home's data/, state/, config/, and projects/
# a command operates on, and every fm-* entrypoint resolves it the same way
# (${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}). A secondmate process whose FM_HOME
# points at a DIFFERENT home therefore operates on that home with full authority
# and no complaint. Two failures of that shape actually happened: a secondmate
# spawned a worker into the PRIMARY home, and a secondmate's memory sweep read
# and rewrote the PRIMARY home's captain and learning records. The existing
# primary-only domain-mate guard in bin/fm-spawn.sh did not stop the first,
# because it asks whether $FM_HOME carries the marker - and under a mispointed
# FM_HOME the answer is the TARGET home's, never the running process's.
#
# This library is the single owner of that refusal and of how a home's identity
# is read for it; bin/fm-home-seed.sh remains the owner of writing the marker. It
# is sourced at the top of the guarded entrypoints and called immediately after
# FM_HOME is resolved, before any state is read for a write, spawned into, or
# steered.
#
# HOME IDENTITY
#
# A firstmate home's identity is the gitignored .fm-secondmate-home marker seeded
# by bin/fm-home-seed.sh: its contents are the mate id, and its ABSENCE is itself
# the identity "primary". A present-but-unsafe marker (a symlink, a directory, an
# empty file, more than one line, or an id outside the registry's own
# [A-Za-z0-9._-] charset) is an error, never a silent fallback to "primary" -
# collapsing an unreadable marker into "primary" is exactly the direction that
# would re-open the hazard.
#
# TWO INDEPENDENT SIGNALS, EITHER OF WHICH REFUSES (fail closed)
#
#   1. code-root. The identity of the home whose bin/ is actually executing
#      (this file's own physical directory, so FM_ROOT_OVERRIDE cannot move it).
#      When that home is a CORROBORATED secondmate and the selected FM_HOME
#      carries a different identity, the process is reaching outside its own
#      home. This is the primary signal: it covers a secondmate reaching the
#      primary home, and it is the only signal that covers a secondmate reaching
#      a SIBLING secondmate's home.
#
#      Corroborated matters, because the identity marker is gitignored and a
#      pooled firstmate task worktree can be re-leased from a retired secondmate
#      home with that home's marker still sitting in it. So the marker alone is
#      not taken as proof: the code root must also carry the .fm-secondmate-parent
#      binding whose local parent registers THAT id at THAT exact path in
#      data/secondmates.md. A retired or leftover marker is registered nowhere
#      and correctly establishes nothing. An unreadable parent or registry leaves
#      the identity uncorroborated rather than assumed, so a broken registry
#      cannot brick a mate - signal 2 still stands behind it.
#
#      A remotely placed home is never corroborated here: its scripts run from
#      that host's separate tracked code root, which carries no identity marker.
#      This option-B boundary therefore does not establish a remote session's
#      own-home provenance or protect a same-host sibling from that session.
#
#   2. launch-binding. FM_PUBLIC_FOLLOWUP_PRIMARY_HOME is the durable env
#      binding bin/fm-spawn.sh stamps into every secondmate agent session,
#      naming that session's PRIMARY home. When the selected FM_HOME
#      canonicalizes to that same path, a secondmate session is operating on the
#      primary home. This covers the gap in signal 1: a secondmate agent that
#      invokes the PRIMARY home's own bin/ by absolute path has a primary code
#      root, so only the session binding still knows what it is.
#
# LIMIT. This is an accidental-misrouting guard, not process provenance. A
# process can unset or alter its inherited environment, leaving only code-root
# protection. Remote sessions likewise lack an authoritative own-home binding:
# their launch binding identifies only the primary home. Stronger provenance is
# out of scope. The marker itself is non-authoritative: it never establishes an
# invoking identity unless the local parent registry corroborates that exact
# code-root path.
#
# DIRECTION. The refusal is deliberately one-way. A PRIMARY home legitimately
# reaches into the secondmate homes it owns - bin/fm-stow-cascade.sh runs each
# mate's own memory accounting under that mate's FM_HOME, bin/fm-backlog-handoff.sh
# files work into a mate's backlog, and `fm-spawn.sh --secondmate` stands a mate
# up - so neither signal fires when the executing home's identity is "primary".
# The primary home's own data is protected from ordinary secondmate execution,
# which is the boundary the incidents crossed.
#
# A home operating on ITSELF is always allowed: its selected canonical path
# must equal the corroborated canonical path of the executing home.
#
# Sourced by bin/fm-spawn.sh, bin/fm-send.sh, bin/fm-startup-memory-budget.sh,
# bin/fm-stow-cascade.sh, and the tests. Sourcing defines functions and resolves
# the executing code root; it pulls in the shared secondmate parent and registry
# parsers and otherwise touches nothing. set -u / set -e safe. The refusal is a hard exit, not a return, because there
# is no safe way to continue an operation aimed at another home.

# The exit code every cross-home refusal uses, distinct from the gate refusal (3)
# and from fm-send's own unconfirmed-submit status (3).
FM_HOME_IDENTITY_EXIT=4

# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$(dirname -- "${BASH_SOURCE[0]}")/fm-secondmate-registry-lib.sh"

FM_HOME_IDENTITY_VALUE=
FM_HOME_IDENTITY_ERROR=
FM_HOME_IDENTITY_SIGNAL=
FM_HOME_IDENTITY_REASON=

# The physical directory of the home whose bin/ is executing. Resolved from this
# file's own location rather than from FM_ROOT/FM_ROOT_OVERRIDE so an env
# override cannot relabel which code root is running.
FM_HOME_IDENTITY_CODE_ROOT=$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P) || FM_HOME_IDENTITY_CODE_ROOT=

# fm_home_identity_canonical <dir>: print <dir> with symlinks resolved, or fail.
fm_home_identity_canonical() {
  local dir=${1-}
  [ -n "$dir" ] || return 1
  CDPATH='' cd -P -- "$dir" 2>/dev/null && pwd -P
}

# fm_home_identity_id_valid <id>: the same id charset data/secondmates.md accepts
# (bin/fm-secondmate-registry-lib.sh).
fm_home_identity_id_valid() {
  local id=${1-}
  case "$id" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# fm_home_identity_read <home-dir>: set FM_HOME_IDENTITY_VALUE to that home's
# identity - "primary" when it carries no marker, otherwise the mate id. Returns
# 1 with FM_HOME_IDENTITY_ERROR set when the marker is present but unsafe.
fm_home_identity_read() {
  local home=${1-} marker id
  FM_HOME_IDENTITY_VALUE=
  FM_HOME_IDENTITY_ERROR=
  if [ -z "$home" ]; then
    FM_HOME_IDENTITY_ERROR='no home directory given'
    return 1
  fi
  marker="$home/.fm-secondmate-home"
  if [ -L "$marker" ]; then
    FM_HOME_IDENTITY_ERROR="home identity marker is a symlink: $marker"
    return 1
  fi
  if [ ! -e "$marker" ]; then
    FM_HOME_IDENTITY_VALUE=primary
    return 0
  fi
  if [ ! -f "$marker" ]; then
    FM_HOME_IDENTITY_ERROR="home identity marker is not a regular file: $marker"
    return 1
  fi
  if [ "$(wc -c < "$marker")" -ne "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ]; then
    FM_HOME_IDENTITY_ERROR="home identity marker contains NUL bytes: $marker"
    return 1
  fi
  id=$(sed -n '1p' "$marker" 2>/dev/null) || id=
  if awk 'NR == 2 { found=1; exit } END { exit !found }' "$marker"; then
    FM_HOME_IDENTITY_ERROR="home identity marker holds more than one id: $marker"
    return 1
  fi
  if ! fm_home_identity_id_valid "$id"; then
    FM_HOME_IDENTITY_ERROR="home identity marker is empty or malformed: $marker"
    return 1
  fi
  FM_HOME_IDENTITY_VALUE=$id
  return 0
}

# fm_home_identity_corroborated_id <home> [expected-parent]: print a secondmate
# id only when the home's own durable parent binding and that parent's registry
# place the same id at the same path. When an expected parent is supplied, its
# canonical path must also equal the home binding's parent.
fm_home_identity_corroborated_id() {
  local home=${1-} expected_parent=${2-} id registry home_key root_key parent_key expected_parent_key
  [ -n "$home" ] || return 1
  fm_home_identity_read "$home" || return 1
  id=$FM_HOME_IDENTITY_VALUE
  [ "$id" != primary ] || return 1

  fm_secondmate_parent_record_parse \
    "$home/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = local ] || return 1
  if [ -n "$expected_parent" ]; then
    parent_key=$(fm_home_identity_canonical "$FM_SECONDMATE_PARENT_HOME") || return 1
    expected_parent_key=$(fm_home_identity_canonical "$expected_parent") || return 1
    [ "$parent_key" = "$expected_parent_key" ] || return 1
  fi
  registry="$FM_SECONDMATE_PARENT_HOME/data/secondmates.md"

  # The registry owns its own lookup, duplicate-id refusal, and path spelling.
  secondmate_registry_line_for_id "$registry" "$id" || return 1
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 0 ] || return 1
  home_key=$(secondmate_registry_path_key "$SECONDMATE_REGISTRY_HOME") || return 1
  root_key=$(secondmate_registry_path_key "$home") || return 1
  [ "$home_key" = "$root_key" ] || return 1
  printf '%s\n' "$id"
}

# fm_home_identity_origin_id: print the secondmate id of the home whose bin/ is
# executing, and return 0, only when that identity is corroborated by the home's
# own durable parent binding and that parent's registry placing the SAME id at
# the SAME path. Returns 1 for a primary code root, for an unreadable or absent
# marker, for a remote parent route, and for any marker the local parent does not
# register at this exact path - a leftover marker in a re-leased pool worktree
# establishes nothing.
fm_home_identity_origin_id() {
  [ -n "$FM_HOME_IDENTITY_CODE_ROOT" ] || return 1
  fm_home_identity_corroborated_id "$FM_HOME_IDENTITY_CODE_ROOT"
}

fm_home_identity_remote_home() {
  local home=${1-} registry=${2-} id home_key registry_key
  [ -n "$registry" ] || return 1
  fm_home_identity_read "$home" || return 1
  id=$FM_HOME_IDENTITY_VALUE
  [ "$id" != primary ] || return 1
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 1
  [ "$FM_SECONDMATE_PARENT_ROUTE" = remote ]
  secondmate_registry_line_for_id "$registry" "$id" || return 1
  [ "$SECONDMATE_REGISTRY_REMOTE" -eq 1 ] || return 1
  if [ -n "$FM_SECONDMATE_PARENT_HOST" ] \
    && [ "$FM_SECONDMATE_PARENT_HOST" != "$SECONDMATE_REGISTRY_HOST" ]; then
    return 1
  fi
  home_key=$(secondmate_registry_path_key "$home") || return 1
  registry_key=$(secondmate_registry_path_key "$SECONDMATE_REGISTRY_HOME") || return 1
  [ "$home_key" = "$registry_key" ]
}

fm_home_identity_surface_is_protected_elsewhere() {
  local target_abs=${1-} override_abs=${2-} surface=${3-} parent_abs= registry probe
  if fm_home_identity_origin_id >/dev/null; then
    parent_abs=$(fm_home_identity_canonical "$FM_SECONDMATE_PARENT_HOME") || return 1
  fi
  registry="${parent_abs:-$target_abs}/data/secondmates.md"
  case "$override_abs" in
    "$parent_abs/$surface"|"$parent_abs/$surface/"*)
      [ -n "$parent_abs" ] && [ "$target_abs" != "$parent_abs" ] && return 0
      ;;
  esac
  probe=$override_abs
  while [ "$probe" != / ]; do
    case "$override_abs" in
      "$probe/$surface"|"$probe/$surface/"*)
        if [ "$probe" != "$target_abs" ]; then
          if { [ -n "$parent_abs" ] \
            && fm_home_identity_corroborated_id "$probe" "$parent_abs" >/dev/null; } \
            || fm_home_identity_remote_home "$probe" "$registry"; then
            return 0
          fi
        fi
        ;;
    esac
    probe=$(dirname -- "$probe")
  done
  return 1
}

fm_home_identity_surface_override() {
  local target=${1-} surface=${2-} override override_name target_abs override_abs
  case "$surface" in
    state) override=${FM_STATE_OVERRIDE:-}; override_name=FM_STATE_OVERRIDE ;;
    data) override=${FM_DATA_OVERRIDE:-}; override_name=FM_DATA_OVERRIDE ;;
    config) override=${FM_CONFIG_OVERRIDE:-}; override_name=FM_CONFIG_OVERRIDE ;;
    projects) override=${FM_PROJECTS_OVERRIDE:-}; override_name=FM_PROJECTS_OVERRIDE ;;
    *) return 1 ;;
  esac
  [ -n "$override" ] || return 1
  target_abs=$(fm_home_identity_canonical "$target") || {
    FM_HOME_IDENTITY_SIGNAL='surface-override'
    FM_HOME_IDENTITY_REASON="the selected home ($target) cannot establish its $surface surface while $override_name selects $override"
    return 0
  }
  override_abs=$(fm_home_identity_canonical "$override") || {
    FM_HOME_IDENTITY_SIGNAL='surface-override'
    FM_HOME_IDENTITY_REASON="$override_name selects an unreadable $surface directory ($override)"
    return 0
  }
  if fm_home_identity_surface_is_protected_elsewhere "$target_abs" "$override_abs" "$surface"; then
    FM_HOME_IDENTITY_SIGNAL='surface-override'
    FM_HOME_IDENTITY_REASON="$override_name selects $override_abs inside another protected home's $surface surface instead of the selected home ($target_abs)"
    return 0
  fi
  return 1
}

fm_home_identity_remote_control_overrides() {
  local selected=${1-} selected_abs state_abs data_abs config_abs remote_home
  [ "${FM_REMOTE_JOB_ACTIVE:-}" = 1 ] || return 1
  [ "${FM_SKIP_SECONDMATE_INHERIT:-}" = 1 ] || return 1
  [ -n "${FM_STATE_OVERRIDE:-}" ] || return 1
  [ -n "${FM_DATA_OVERRIDE:-}" ] || return 1
  [ -n "${FM_CONFIG_OVERRIDE:-}" ] || return 1
  [ -z "${FM_PROJECTS_OVERRIDE:-}" ] || return 1
  selected_abs=$(fm_home_identity_canonical "$selected") || return 1
  state_abs=$(fm_home_identity_canonical "$FM_STATE_OVERRIDE") || return 1
  data_abs=$(fm_home_identity_canonical "$FM_DATA_OVERRIDE") || return 1
  config_abs=$(fm_home_identity_canonical "$FM_CONFIG_OVERRIDE") || return 1
  case "$state_abs" in
    */state/parent-route) remote_home=${state_abs%/state/parent-route} ;;
    *) return 1 ;;
  esac
  remote_home=$(fm_home_identity_canonical "$remote_home") || return 1
  [ "$selected_abs" != "$remote_home" ] || return 1
  [ "$data_abs" = "$remote_home/data/.parent-route" ] || return 1
  [ "$config_abs" = "$remote_home/config" ] || return 1
  fm_home_identity_remote_home "$remote_home" "$selected_abs/data/secondmates.md"
}

# fm_home_identity_cross_home <target-home>: return 0 when this process must NOT
# operate on <target-home>, setting FM_HOME_IDENTITY_SIGNAL (code-root,
# launch-binding, or target-identity for a selected home whose own identity
# cannot be read safely) and FM_HOME_IDENTITY_REASON to the rendered mismatch.
# Returns 1 when the operation is this process's own home, a primary reaching a
# home it owns, or an origin this library cannot establish.
fm_home_identity_cross_home() {
  local target=${1-} target_id origin_id target_abs origin_abs primary_abs
  FM_HOME_IDENTITY_SIGNAL=
  FM_HOME_IDENTITY_REASON=
  [ -n "$target" ] || return 1

  if ! fm_home_identity_read "$target"; then
    FM_HOME_IDENTITY_SIGNAL='target-identity'
    FM_HOME_IDENTITY_REASON="the selected home's identity cannot be read - $FM_HOME_IDENTITY_ERROR"
    return 0
  fi
  target_id=$FM_HOME_IDENTITY_VALUE
  target_abs=$(fm_home_identity_canonical "$target") || target_abs=

  # Signal 1: the executing code root is a corroborated secondmate home whose
  # identity differs from the selected home's.
  if origin_id=$(fm_home_identity_origin_id); then
    origin_abs=$(fm_home_identity_canonical "$FM_HOME_IDENTITY_CODE_ROOT") || origin_abs=
    if [ "$origin_id" != "$target_id" ] \
      || [ -z "$target_abs" ] \
      || [ "$origin_abs" != "$target_abs" ]; then
      FM_HOME_IDENTITY_SIGNAL='code-root'
      FM_HOME_IDENTITY_REASON="this process runs from the '$origin_id' secondmate home ($origin_abs) but FM_HOME selects the '$target_id' home ($target_abs)"
      return 0
    fi
    return 1
  fi

  # Signal 2: a secondmate session's launch binding names the selected home.
  if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
    primary_abs=$(fm_home_identity_canonical "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") || primary_abs=
    if [ -n "$target_abs" ] && [ "$target_abs" = "$primary_abs" ]; then
      FM_HOME_IDENTITY_SIGNAL='launch-binding'
      FM_HOME_IDENTITY_REASON="this secondmate session is bound to the primary home ($primary_abs) and FM_HOME selects that same primary home"
      return 0
    fi
  fi

  return 1
}

# fm_refuse_cross_home <target-home> <operation> [state] [data] [config] [projects]:
# exit FM_HOME_IDENTITY_EXIT with an actionable diagnostic when <target-home>
# belongs to another home or a named override does not resolve inside it. Call
# after FM_HOME is resolved and before anything is written, spawned, or steered.
# A no-op (returns 0) for a same-home operation or for a primary home reaching
# a home it owns.
fm_refuse_cross_home() {
  local target=${1-} operation=${2:-this operation}
  shift 2 || true
  if fm_home_identity_cross_home "$target"; then
    :
  else
    while [ "$#" -gt 0 ]; do
      if fm_home_identity_surface_override "$target" "$1"; then
        break
      fi
      shift
    done
    [ -n "$FM_HOME_IDENTITY_SIGNAL" ] || return 0
  fi
  printf 'error: %s refuses a cross-home operation: %s.\n' \
    "$operation" "$FM_HOME_IDENTITY_REASON" >&2
  printf 'error: a home may only operate on itself; another home - the primary home above all - is read-only from here. Set FM_HOME to this home, or run the operation from the owning home'"'"'s own session. [signal: %s]\n' \
    "$FM_HOME_IDENTITY_SIGNAL" >&2
  exit "$FM_HOME_IDENTITY_EXIT"
}
