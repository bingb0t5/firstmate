#!/usr/bin/env bash
# fm-pr-conflict-watch.sh - detect open PR merge conflicts across the fleet.
#
# Usage:
#   fm-pr-conflict-watch.sh [check]
#   fm-pr-conflict-watch.sh arm
#   fm-pr-conflict-watch.sh disarm
#   fm-pr-conflict-watch.sh --help
#
# `check` prints one line when a newly conflicted open PR is found and prints
# nothing otherwise. `arm` writes state/pr-conflict-watch.check.sh and binds
# its bytes with fm-check-register.sh so the watcher polls on its normal
# cadence. `disarm` removes the shim, trust binding, and dedupe record.
#
# Repositories come from data/projects.md project clones under projects/, plus
# this firstmate checkout's own origin remote. Owning targets come from
# data/secondmates.md project lists, with the firstmate repository mapped to
# main. Nothing is hardcoded to a fleet-specific name.
#
# Dedupe keys are owner/repo, PR number, and head SHA. A force-updated head that
# conflicts again is a new event; the same conflict on the same head stays silent
# after the first wake. A key is recorded only for a conflict that reached the
# printed line, so conflicts cut by the line cap are disclosed as omitted and
# wake on a later sweep instead of being silenced. The record is cut back to the
# conflicts observed in the repositories whose whole open set the sweep read. A
# repository whose open page was cut short by FM_PR_CONFLICT_PR_LIMIT keeps its
# keys instead, because a conflict missing from a partial page is unread rather
# than resolved, so such a repository's keys do accumulate across sweeps.
#
# GitHub is read through `gh-axi api`, which answers with an axi envelope rather
# than raw JSON. One GraphQL read per repository carries the bounded open-PR page,
# its mergeability, and completeness metadata, so sweep cost scales with
# repositories rather than with pull requests. A page with a successor is an
# unobserved coverage gap, never a complete open set. GitHub computes mergeability
# lazily, and a read that comes back UNKNOWN is never treated as clean or
# conflicted; only that pull request is reread, with short waits, until the state
# settles or stays unknown.
#
# Coverage is a separate ledger from conflicts. A conflict is a positive
# observation keyed by repository, pull request number, and head SHA. A coverage
# gap is an absence of a trustworthy observation keyed by a stable target, with
# an opening time, latest cause, and delivery state. Cause is diagnostic
# metadata on that gap: changing it never resets age and never opens a second
# gap. A transient gap stays silent; one that outlasts
# FM_PR_CONFLICT_UNREAD_GRACE_SECS is disclosed once as a coverage-hole, not as
# a conflict. Sweep completeness is derived from per-target outcomes.
#
# Detection and routing only: this script never resolves conflicts.
set -u
export LC_ALL=C
export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
RECORD="$STATE/.pr-conflict-watch"
CHECK_ID=pr-conflict-watch
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-pr-conflict-watch-v2
RECORD_SCHEMA_V1=fm-pr-conflict-watch-v1
GH_AXI=${FM_PR_CONFLICT_GH_AXI:-gh-axi}
MAX_LINE=1000
FINDING_PREFIX='pr-conflict: '
MAIN_OWNER=main

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-repo-slug-lib.sh
. "$SCRIPT_DIR/fm-repo-slug-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-pr-conflict-watch.sh [check]   report newly conflicted open PRs (silent when clear)
  fm-pr-conflict-watch.sh arm       write and register state/pr-conflict-watch.check.sh
  fm-pr-conflict-watch.sh disarm    remove the check shim, trust binding, and record
  fm-pr-conflict-watch.sh --help    print this help

Repositories are derived from data/projects.md clones under projects/ plus this
firstmate checkout's origin remote. Owning targets are derived from
data/secondmates.md project lists, with the firstmate repository mapped to main.

Arm once per home. The watcher polls on its normal FM_CHECK_INTERVAL cadence.
See docs/configuration.md for tuning knobs.
EOF
}

die_usage() {
  printf 'fm-pr-conflict-watch: %s\n' "$1" >&2
  usage >&2
  exit 2
}

INTERVAL=${FM_PR_CONFLICT_INTERVAL:-300}
case "$INTERVAL" in
  ''|*[!0-9]*)
    printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$INTERVAL" -ne 0 ] && { [ "$INTERVAL" -lt 60 ] || [ "$INTERVAL" -gt 86400 ]; }; then
  printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_INTERVAL must be 0 or a whole number from 60 to 86400\n' >&2
  exit 2
fi

PROBE_SECS=${FM_PR_CONFLICT_PROBE_SECS:-5}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_PROBE_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$PROBE_SECS" -gt 30 ]; then
  printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_PROBE_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

BUDGET_SECS=${FM_PR_CONFLICT_BUDGET_SECS:-20}
case "$BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
    exit 2
    ;;
esac
if [ "$BUDGET_SECS" -gt 120 ]; then
  printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_BUDGET_SECS must be a whole number from 1 to 120\n' >&2
  exit 2
fi

UNKNOWN_ATTEMPTS=${FM_PR_CONFLICT_UNKNOWN_ATTEMPTS:-3}
case "$UNKNOWN_ATTEMPTS" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_UNKNOWN_ATTEMPTS must be a whole number from 1 to 10\n' >&2
    exit 2
    ;;
esac
if [ "$UNKNOWN_ATTEMPTS" -gt 10 ]; then
  printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_UNKNOWN_ATTEMPTS must be a whole number from 1 to 10\n' >&2
  exit 2
fi

UNREAD_GRACE=${FM_PR_CONFLICT_UNREAD_GRACE_SECS:-1800}
case "$UNREAD_GRACE" in
  ''|*[!0-9]*)
    printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_UNREAD_GRACE_SECS must be a whole number from 0 to 86400\n' >&2
    exit 2
    ;;
esac
if [ "$UNREAD_GRACE" -gt 86400 ]; then
  printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_UNREAD_GRACE_SECS must be a whole number from 0 to 86400\n' >&2
  exit 2
fi

UNKNOWN_WAIT=${FM_PR_CONFLICT_UNKNOWN_WAIT:-1}
case "$UNKNOWN_WAIT" in
  ''|*[!0-9]*)
    printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_UNKNOWN_WAIT must be a whole number from 0 to 5\n' >&2
    exit 2
    ;;
esac
if [ "$UNKNOWN_WAIT" -gt 5 ]; then
  printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_UNKNOWN_WAIT must be a whole number from 0 to 5\n' >&2
  exit 2
fi

PR_LIMIT=${FM_PR_CONFLICT_PR_LIMIT:-30}
case "$PR_LIMIT" in
  ''|*[!0-9]*|0)
    printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_PR_LIMIT must be a whole number from 1 to 100\n' >&2
    exit 2
    ;;
esac
if [ "$PR_LIMIT" -gt 100 ]; then
  printf 'fm-pr-conflict-watch: FM_PR_CONFLICT_PR_LIMIT must be a whole number from 1 to 100\n' >&2
  exit 2
fi

PROBE_MIN_SECS=1
CLOCK_ROUNDING_SECS=1
KILL_GRACE_SECS=1

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
BUDGET_CUT_FROM=
if [ "$BUDGET_SECS" -gt "$BUDGET_MAX" ]; then
  BUDGET_CUT_FROM=$BUDGET_SECS
  BUDGET_SECS=$BUDGET_MAX
fi

# FM_PR_CONFLICT_NOW is a test hook that freezes coverage-gap age without
# changing the wall-clock sweep budget. It is not an operator knob.
record_epoch_now() {
  case "${FM_PR_CONFLICT_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_PR_CONFLICT_NOW" ;;
  esac
}

real_epoch() { date +%s; }

DEADLINE=0
REPORTED_KEYS=
RECORD_EPOCH=0
FINDING_KINDS=()
FINDING_IDS=()
FINDING_TEXTS=()
FINDING_KEYS=()
FINDING_LINE=
FINDING_DELIVERED=
FINDING_OMITTED=0
EXPECTED_TARGETS=
TARGET_REPO_MAP=
TARGET_OWNER_MAP=
TARGET_CAUSE_MAP=
DISCOVERED_REPOS=
REPO_OWNER_MAP=
PROJECT_OWNER_MAP=
FIRSTMATE_SLUG=
FIRSTMATE_CAUSE=
PROJECT_SLUG=
PROJECT_CAUSE=
SWEPT_REPOS=
SEEN_KEYS=
OBSERVED_TARGETS=
COVERAGE_JSON='[]'
LAST_READ_CAUSE=
GH_API_BODY=
ATTEMPT_CAUSE=
SWEEP_COMPLETE=1
DISCOVERY_COMPLETE=1
RESOLVED_STATE=
RESOLVED_HEAD=
RESOLVED_DRAFT=
RUNTIME_JQ_OPENED=0
RUNTIME_JQ_DISCLOSED=0
RUNTIME_GH_OPENED=0
RUNTIME_GH_DISCLOSED=0

# Split a delimited accumulator into one part per line. `read -r -a` is not used
# anywhere here because expanding a declared-but-empty array under `set -u` is a
# fatal unbound-variable error on bash 3.2, and an empty record is the normal
# state of a clean fleet.
list_parts() {
  local rest=$1 sep=$2 part
  while [ -n "$rest" ]; do
    part=${rest%%"$sep"*}
    if [ "$part" = "$rest" ]; then
      rest=
    else
      rest=${rest#*"$sep"}
    fi
    [ -n "$part" ] || continue
    printf '%s\n' "$part"
  done
}

# A notification is queued as kind, identity, text, and optional conflict key.
# Delivery acknowledgement uses those identities, never a substring of the
# rendered line: a coverage item omitted by the cap stays undisclosed, and a
# conflict omitted by the cap is not recorded as reported.
queue_item() {
  local kind=$1 id=$2 text=$3
  text=$(printf '%s' "$text" | tr '\t\r\n' '   ')
  FINDING_KINDS+=("$kind")
  FINDING_IDS+=("$id")
  FINDING_TEXTS+=("$text")
  FINDING_KEYS+=("${4:-}")
}

# Fill the line in queue order up to <reserve> characters short of the cap, and
# collect the identities of exactly the items that fit. The first item is always
# taken, so a single over-long finding still reports something.
build_finding_line() {
  local reserve=$1 total i text kind id key candidate room
  FINDING_LINE=
  FINDING_DELIVERED=
  FINDING_OMITTED=0
  total=${#FINDING_TEXTS[@]}
  room=$((MAX_LINE - reserve))
  i=0
  while [ "$i" -lt "$total" ]; do
    kind=${FINDING_KINDS[$i]}
    id=${FINDING_IDS[$i]}
    text=${FINDING_TEXTS[$i]}
    key=${FINDING_KEYS[$i]}
    if [ -z "$FINDING_LINE" ]; then
      candidate="$FINDING_PREFIX$text"
    else
      candidate="$FINDING_LINE; $text"
    fi
    if [ "$i" -eq 0 ] || [ "${#candidate}" -le "$room" ]; then
      FINDING_LINE=$candidate
      FINDING_DELIVERED="${FINDING_DELIVERED}${kind}	${id}	${key}
"
    else
      FINDING_OMITTED=$((FINDING_OMITTED + 1))
    fi
    i=$((i + 1))
  done
}

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

probe_bound() {
  local left
  left=$((DEADLINE - $(real_epoch)))
  if [ "$left" -lt "$PROBE_MIN_SECS" ]; then
    printf '%s\n' "$PROBE_MIN_SECS"
  elif [ "$left" -lt "$PROBE_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$PROBE_SECS"
  fi
}

gh_bounded() {
  fm_run_timed "$(probe_bound)" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 "$GH_AXI" "$@"
}

firstmate_repo_resolve() {
  local url
  FIRSTMATE_SLUG=
  FIRSTMATE_CAUSE=discovery
  url=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null) || return 1
  if ! fm_repo_slug_parse "$url"; then
    FIRSTMATE_CAUSE=$FM_REPO_SLUG_STATUS
    return 1
  fi
  FIRSTMATE_SLUG=$FM_REPO_SLUG
  FIRSTMATE_CAUSE=
}

# A registry that cannot be read enumerates nothing, which reads exactly like a
# home that registered no projects. The difference matters to record pruning, so
# the unreadable case is reported as a failure rather than as an empty list.
project_names() {
  [ -r "$DATA/projects.md" ] || return 1
  awk '$1 == "-" && $2 != "" { print $2 }' "$DATA/projects.md"
}

resolve_project_repo() {
  local project=$1 dir url
  PROJECT_SLUG=
  PROJECT_CAUSE=discovery
  dir="$PROJECTS/$project"
  [ -d "$dir" ] || return 1
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  if ! fm_repo_slug_parse "$url"; then
    PROJECT_CAUSE=$FM_REPO_SLUG_STATUS
    return 1
  fi
  PROJECT_SLUG=$FM_REPO_SLUG
  PROJECT_CAUSE=
}

trim_field() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

# The registry is read once per sweep into a project -> owning secondmate map.
# First registration wins, which is the order a linear scan of the file would
# have answered in.
load_project_owners() {
  local reg line id rest part
  PROJECT_OWNER_MAP=
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*) ;;
      *) continue ;;
    esac
    secondmate_registry_parse_line "$line" || continue
    id=$SECONDMATE_REGISTRY_ID
    rest=$SECONDMATE_REGISTRY_PROJECTS
    while IFS= read -r part; do
      part=$(trim_field "$part")
      [ -n "$part" ] || continue
      case "$part" in *[[:space:]]*) continue ;; esac
      case "
$PROJECT_OWNER_MAP" in
        *"
$part "*) continue ;;
      esac
      PROJECT_OWNER_MAP="$PROJECT_OWNER_MAP$part $id
"
    done < <(list_parts "$rest" ',')
  done < "$reg"
}

map_lookup() {
  local map=$1 key=$2 line
  while IFS= read -r line; do
    [ "${line%% *}" = "$key" ] || continue
    printf '%s\n' "${line#* }"
    return 0
  done <<EOF
$map
EOF
  return 1
}

owner_for_project() {
  map_lookup "$PROJECT_OWNER_MAP" "$1"
}

target_known() {
  local id=$1
  case "
$EXPECTED_TARGETS" in
    *"
$id
"*) return 0 ;;
  esac
  return 1
}

# Stable coverage targets are defined before any GitHub read. A valid repository
# is repo:<owner/repo>. A registered project that cannot resolve to a valid
# repository is project:<name>. A source that fails before any repository can be
# named is source:projects-registry or source:firstmate-origin. Unvalidated
# origin strings are never persistence keys and never GraphQL values.
add_target() {
  local id=$1 repo=${2:-} owner=${3:-} cause=${4:-}
  target_known "$id" && return 0
  EXPECTED_TARGETS="$EXPECTED_TARGETS$id
"
  [ -z "$repo" ] || TARGET_REPO_MAP="$TARGET_REPO_MAP$id $repo
"
  [ -z "$owner" ] || TARGET_OWNER_MAP="$TARGET_OWNER_MAP$id $owner
"
  [ -z "$cause" ] || TARGET_CAUSE_MAP="$TARGET_CAUSE_MAP$id $cause
"
}

add_repo_target() {
  local slug=$1 owner=$2
  fm_repo_slug_valid "$slug" || return 1
  case " $DISCOVERED_REPOS " in
    *" $slug "*) return 0 ;;
  esac
  DISCOVERED_REPOS="$DISCOVERED_REPOS $slug"
  REPO_OWNER_MAP="$REPO_OWNER_MAP$slug $owner
"
  add_target "repo:$slug" "$slug" "$owner"
}

# Repositories and their owning targets are derived together, once per sweep, so
# neither the origin remotes nor the registry are re-read per repository while
# the same budget is paying for GitHub probes.
discover_targets() {
  local project slug owner names
  EXPECTED_TARGETS=
  TARGET_REPO_MAP=
  TARGET_OWNER_MAP=
  TARGET_CAUSE_MAP=
  DISCOVERED_REPOS=
  REPO_OWNER_MAP=
  DISCOVERY_COMPLETE=1
  load_project_owners
  if ! firstmate_repo_resolve; then
    DISCOVERY_COMPLETE=0
    add_target source:firstmate-origin '' '' "$FIRSTMATE_CAUSE"
  else
    gap_close source:firstmate-origin
  fi
  if names=$(project_names 2>/dev/null); then
    gap_close source:projects-registry
  else
    names=
    DISCOVERY_COMPLETE=0
    add_target source:projects-registry '' '' discovery
  fi
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    if ! resolve_project_repo "$project"; then
      DISCOVERY_COMPLETE=0
      add_target "project:$project" '' '' "$PROJECT_CAUSE"
      continue
    fi
    slug=$PROJECT_SLUG
    gap_close "project:$project"
    if [ -n "$FIRSTMATE_SLUG" ] && [ "$slug" = "$FIRSTMATE_SLUG" ]; then
      owner=$MAIN_OWNER
    else
      owner=$(owner_for_project "$project") || owner=
      [ -n "$owner" ] || owner=$MAIN_OWNER
    fi
    add_repo_target "$slug" "$owner"
  done <<EOF
$names
EOF
  if [ -n "$FIRSTMATE_SLUG" ]; then
    add_repo_target "$FIRSTMATE_SLUG" "$MAIN_OWNER"
  fi
}

owner_for_repo() {
  local owner
  owner=$(map_lookup "$REPO_OWNER_MAP" "$1") || owner=
  [ -n "$owner" ] || owner=$MAIN_OWNER
  printf '%s\n' "$owner"
}

conflict_key() {
  local repo=$1 number=$2 head=$3
  printf '%s#%s#%s' "$repo" "$number" "$head"
}

record_read() {
  local line first=1 schema=
  RECORD_EPOCH=0
  REPORTED_KEYS=
  COVERAGE_JSON='[]'
  RUNTIME_JQ_OPENED=0
  RUNTIME_JQ_DISCLOSED=0
  RUNTIME_GH_OPENED=0
  RUNTIME_GH_DISCLOSED=0
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      schema=$line
      case "$schema" in
        "$RECORD_SCHEMA"|"$RECORD_SCHEMA_V1") ;;
        *) return 0 ;;
      esac
      continue
    fi
    case "$line" in
      epoch=*)
        line=${line#epoch=}
        case "$line" in
          ''|*[!0-9]*) RECORD_EPOCH=0 ;;
          *) RECORD_EPOCH=$line ;;
        esac
        ;;
      reported=*) REPORTED_KEYS=${line#reported=} ;;
      coverage=*)
        line=${line#coverage=}
        if ! command -v jq >/dev/null 2>&1; then
          COVERAGE_JSON=$line
        elif printf '%s' "$line" | jq -e 'type == "array"' >/dev/null 2>&1; then
          COVERAGE_JSON=$line
        fi
        ;;
      runtime-jq=*)
        line=${line#runtime-jq=}
        RUNTIME_JQ_OPENED=${line%%,*}
        RUNTIME_JQ_DISCLOSED=${line#*,}
        ;;
      runtime-gh-axi=*)
        line=${line#runtime-gh-axi=}
        RUNTIME_GH_OPENED=${line%%,*}
        RUNTIME_GH_DISCLOSED=${line#*,}
        ;;
      unread=*) ;;
    esac
  done < "$RECORD"
}

record_write() {
  local reported=$1 tmp
  tmp=$(mktemp "$RECORD.XXXXXX" 2>/dev/null) || return 1
  chmod 0600 "$tmp" 2>/dev/null || { rm -f -- "$tmp"; return 1; }
  {
    printf '%s\n' "$RECORD_SCHEMA"
    printf 'epoch=%s\n' "$(record_epoch_now)"
    printf 'reported=%s\n' "$reported"
    printf 'coverage=%s\n' "$COVERAGE_JSON"
    printf 'runtime-jq=%s,%s\n' "$RUNTIME_JQ_OPENED" "$RUNTIME_JQ_DISCLOSED"
    printf 'runtime-gh-axi=%s,%s\n' "$RUNTIME_GH_OPENED" "$RUNTIME_GH_DISCLOSED"
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$RECORD" || { rm -f -- "$tmp"; return 1; }
}

record_has_key() {
  local key=$1
  case ";$REPORTED_KEYS;" in
    *";$key;"*) return 0 ;;
  esac
  return 1
}

record_add_key() {
  local key=$1
  record_has_key "$key" && return 0
  if [ -z "$REPORTED_KEYS" ]; then
    REPORTED_KEYS=$key
  else
    REPORTED_KEYS="$REPORTED_KEYS;$key"
  fi
}

record_add_keys() {
  local part
  while IFS= read -r part; do
    record_add_key "$part"
  done < <(list_parts "$1" ';')
}

record_remove_key() {
  local key=$1 out='' part
  while IFS= read -r part; do
    [ "$part" = "$key" ] && continue
    out="${out:+$out;}$part"
  done < <(list_parts "$REPORTED_KEYS" ';')
  REPORTED_KEYS=$out
}

# One continuous coverage gap per target. Cause is the latest failed attempt,
# not the gap's identity: gap_touch keeps opened_at and disclosed, and a cause
# change never resets age. JSON round-trips target ids that contain the
# characters a delimiter packing could not.
coverage_text() {
  local id=$1 repo=$2 elapsed=$3 cause=$4
  if [ -n "$repo" ]; then
    printf 'coverage-hole target=%s repo=%s unaccounted-for=%ss latest-cause=%s' \
      "$id" "$repo" "$elapsed" "$cause"
  else
    printf 'coverage-hole target=%s unaccounted-for=%ss latest-cause=%s' \
      "$id" "$elapsed" "$cause"
  fi
}

gap_touch() {
  local id=$1 cause=$2 repo=${3:-} now opened disclosed elapsed next
  now=$(record_epoch_now)
  next=$(printf '%s' "$COVERAGE_JSON" | jq -c \
    --arg id "$id" --arg cause "$cause" --arg repo "$repo" --argjson now "$now" '
    (map(select(.target_id == $id)) | .[0]) as $g |
    if $g == null then
      . + [{
        target_id: $id,
        repo: (if $repo == "" then null else $repo end),
        opened_at: $now,
        last_attempt_at: $now,
        latest_cause: $cause,
        disclosed: 0
      }]
    else
      map(if .target_id == $id then
        .last_attempt_at = $now
        | .latest_cause = $cause
        | .repo = (if $repo == "" then .repo else $repo end)
      else . end)
    end
  ' 2>/dev/null) || return 1
  COVERAGE_JSON=$next
  opened=$(printf '%s' "$COVERAGE_JSON" | jq -r --arg id "$id" \
    'map(select(.target_id == $id)) | .[0].opened_at // empty')
  disclosed=$(printf '%s' "$COVERAGE_JSON" | jq -r --arg id "$id" \
    'map(select(.target_id == $id)) | .[0].disclosed // 0')
  case "$opened" in ''|*[!0-9]*) opened=$now ;; esac
  case "$disclosed" in 1) disclosed=1 ;; *) disclosed=0 ;; esac
  elapsed=0
  [ "$now" -gt "$opened" ] && elapsed=$((now - opened))
  if [ "$disclosed" -eq 0 ] && [ "$elapsed" -ge "$UNREAD_GRACE" ]; then
    [ -n "$repo" ] || repo=$(printf '%s' "$COVERAGE_JSON" | jq -r --arg id "$id" \
      'map(select(.target_id == $id)) | .[0].repo // empty')
    [ "$repo" = null ] && repo=
    queue_item coverage "$id" "$(coverage_text "$id" "$repo" "$elapsed" "$cause")"
  fi
}

gap_close() {
  local id=$1 next
  next=$(printf '%s' "$COVERAGE_JSON" | jq -c --arg id "$id" \
    'map(select(.target_id != $id))' 2>/dev/null) || return 0
  COVERAGE_JSON=$next
}

coverage_mark_disclosed() {
  local id=$1 next
  next=$(printf '%s' "$COVERAGE_JSON" | jq -c --arg id "$id" \
    'map(if .target_id == $id then .disclosed = 1 else . end)' 2>/dev/null) || return 0
  COVERAGE_JSON=$next
}

runtime_gap_touch() {
  local tool=$1 now opened disclosed elapsed id
  now=$(record_epoch_now)
  case "$tool" in
    jq)
      opened=$RUNTIME_JQ_OPENED
      disclosed=$RUNTIME_JQ_DISCLOSED
      id=source:runtime-jq
      ;;
    gh-axi)
      opened=$RUNTIME_GH_OPENED
      disclosed=$RUNTIME_GH_DISCLOSED
      id=source:runtime-gh-axi
      ;;
  esac
  case "$opened" in ''|*[!0-9]*) opened=0 ;; esac
  case "$disclosed" in 1) ;; *) disclosed=0 ;; esac
  [ "$opened" -gt 0 ] || opened=$now
  elapsed=0
  [ "$now" -gt "$opened" ] && elapsed=$((now - opened))
  case "$tool" in
    jq) RUNTIME_JQ_OPENED=$opened ;;
    gh-axi) RUNTIME_GH_OPENED=$opened ;;
  esac
  if [ "$disclosed" -eq 0 ] && [ "$elapsed" -ge "$UNREAD_GRACE" ]; then
    queue_item dependency "$id" \
      "$(coverage_text "$id" '' "$elapsed" dependency-missing)"
  fi
}

runtime_gap_close() {
  case "$1" in
    jq) RUNTIME_JQ_OPENED=0; RUNTIME_JQ_DISCLOSED=0 ;;
    gh-axi) RUNTIME_GH_OPENED=0; RUNTIME_GH_DISCLOSED=0 ;;
  esac
}

runtime_mark_disclosed() {
  case "$1" in
    source:runtime-jq) RUNTIME_JQ_DISCLOSED=1 ;;
    source:runtime-gh-axi) RUNTIME_GH_DISCLOSED=1 ;;
  esac
}

# Gaps for targets complete discovery no longer expects are closed. Absence
# from a partial discovery is a failed read, not proof the target was dropped.
coverage_prune() {
  local next
  [ "$DISCOVERY_COMPLETE" -eq 1 ] || return 0
  next=$(printf '%s' "$COVERAGE_JSON" | jq -c --arg targets "$EXPECTED_TARGETS" '
    ($targets | split("\n") | map(select(. != ""))) as $ids |
    map(select(.target_id as $t | $ids | index($t) != null))
  ' 2>/dev/null) || return 0
  COVERAGE_JSON=$next
}

ack_delivered() {
  local kind id key
  while IFS=$'\t' read -r kind id key; do
    [ -n "$kind" ] || continue
    case "$kind" in
      conflict) [ -z "$key" ] || record_add_key "$key" ;;
      coverage) coverage_mark_disclosed "$id" ;;
      dependency) runtime_mark_disclosed "$id" ;;
    esac
  done <<EOF
$FINDING_DELIVERED
EOF
}

deliver_findings() {
  local line='' notice=''
  if [ "${#FINDING_TEXTS[@]}" -gt 0 ]; then
    build_finding_line 0
    if [ "$FINDING_OMITTED" -gt 0 ]; then
      notice="; ${#FINDING_TEXTS[@]} more omitted (line cap)"
      build_finding_line "${#notice}"
      if [ "$FINDING_OMITTED" -gt 0 ]; then
        FINDING_LINE="$FINDING_LINE; $FINDING_OMITTED more omitted (line cap)"
      fi
    fi
    fm_cap_line_var "$FINDING_LINE" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi
  [ -z "$line" ] || printf '%s\n' "$line" || return 1
  ack_delivered
}

sweep_complete_from_outcomes() {
  local id
  [ "$DISCOVERY_COMPLETE" -eq 1 ] || return 1
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    case " $OBSERVED_TARGETS " in
      *" $id "*) ;;
      *) return 1 ;;
    esac
  done <<EOF
$EXPECTED_TARGETS
EOF
  return 0
}

mark_observed() {
  local id=$1
  case " $OBSERVED_TARGETS " in
    *" $id "*) return 0 ;;
  esac
  OBSERVED_TARGETS="$OBSERVED_TARGETS $id"
  gap_close "$id"
}

# Every open pull request this sweep read is remembered, so the record can be
# cut back to the live conflict set instead of accumulating one key per head
# forever. A repository whose whole open-PR page was read keeps only the keys
# that page carried; a repository the sweep did not finish keeps all of its
# keys, because absence there means unread rather than resolved. Keys for
# repositories this fleet no longer works in are dropped only when discovery
# read the project registry, resolved every project it enumerated, and the sweep
# then reached every repository discovery named. A discovery that could not read
# the registry, or that skipped a project whose clone or origin could not be
# read - including the degenerate case where it resolved nothing at all - left
# behind an unread repository it cannot even name, so absence from its
# repository set is a failed read rather than proof the fleet stopped working in
# those repositories.
seen_key() {
  local key=$1
  case ";$SEEN_KEYS;" in
    *";$key;"*) return 0 ;;
  esac
  SEEN_KEYS="${SEEN_KEYS:+$SEEN_KEYS;}$key"
}

record_prune() {
  local out='' part repo
  while IFS= read -r part; do
    repo=${part%%#*}
    case " $SWEPT_REPOS " in
      *" $repo "*)
        case ";$SEEN_KEYS;" in
          *";$part;"*) ;;
          *) continue ;;
        esac
        ;;
      *)
        if [ "$SWEEP_COMPLETE" -eq 1 ] && [ "$DISCOVERY_COMPLETE" -eq 1 ] \
          && [ -n "$DISCOVERED_REPOS" ]; then
          case " $DISCOVERED_REPOS " in
            *" $repo "*) ;;
            *) continue ;;
          esac
        fi
        ;;
    esac
    out="${out:+$out;}$part"
  done < <(list_parts "$REPORTED_KEYS" ';')
  REPORTED_KEYS=$out
}

# gh-axi has no --json flag and never emits raw JSON. An API read is rendered as
# an axi envelope:
#
#   api_response:
#     body: <value>
#     truncated: <true|false>
#
# The body is a YAML-ish scalar: bare when the value needs no quoting, and a
# JSON string literal when it contains a colon, a quote, a backslash, a tab, or
# a newline. Every query below asks jq for a single string, which is the shape
# that always arrives inside the envelope, so a quoted body is decoded back
# through jq rather than unescaped by hand.
#
# A truncated body is refused instead of parsed. Cutting a record set mid-line
# would read as a shorter list of pull requests, which is silence about the
# ones that were dropped - the same failure this envelope layer exists to stop.
gh_api() {
  local query=$1
  shift
  local out line body='' have_body=0 truncated=false enveloped=0 rc=0
  LAST_READ_CAUSE=
  GH_API_BODY=
  out=$(gh_bounded api "$@" --jq "$query" --full 2>/dev/null) || rc=$?
  while IFS= read -r line; do
    case "$line" in
      'api_response:') enveloped=1 ;;
      '  body: '*)
        [ "$have_body" -eq 0 ] || continue
        have_body=1
        body=${line#'  body: '}
        ;;
      '  truncated: '*) truncated=${line#'  truncated: '} ;;
    esac
  done < <(printf '%s\n' "$out")
  if [ "$truncated" != false ]; then
    LAST_READ_CAUSE=truncated
    return 2
  fi
  if [ "$rc" -ne 0 ]; then
    LAST_READ_CAUSE=github
    return 2
  fi
  if [ "$enveloped" -eq 0 ]; then
    GH_API_BODY=$out
    return 0
  fi
  [ "$have_body" -eq 1 ] || { LAST_READ_CAUSE=github; return 2; }
  case "$body" in
    '"'*) body=$(printf '%s' "$body" | jq -r '.' 2>/dev/null) || { LAST_READ_CAUSE=github; return 2; } ;;
  esac
  GH_API_BODY=$body
}

# GraphQL answers with HTTP 200 and a null repository when the repository cannot
# be read, which through a plain field selection is byte-identical to a
# repository with no open pull requests. Both guards below therefore fail the jq
# program, which fails the gh-axi call, which is an unobserved GitHub outcome -
# an unreadable repository must never arrive as a clean one.
GQL_GUARD='if ((.errors // []) | length) > 0 then error("graphql errors") '

# Compact JSON array of open pull requests. Title bytes are preserved; tabs and
# newlines are sanitized only when formatting the wake line. A single read per
# repository carries mergeability, so only UNKNOWN pull requests cost a further
# read.
pr_list_records() {
  local repo=$1 owner name
  fm_repo_slug_valid "$repo" || { LAST_READ_CAUSE=invalid-origin; return 2; }
  owner=${repo%%/*}
  name=${repo#*/}
  LAST_READ_CAUSE=
  gh_api "${GQL_GUARD}elif (.data.repository.pullRequests.nodes | type) != \"array\" or (.data.repository.pullRequests.pageInfo.hasNextPage | type) != \"boolean\" then error(\"incomplete repository result\") else ({records: [.data.repository.pullRequests.nodes[] | {number, headRefOid: (.headRefOid // \"\"), isDraft, mergeable: (.mergeable // \"UNKNOWN\"), url: (.url // \"\"), title: (.title // \"\")}], hasNextPage: .data.repository.pullRequests.pageInfo.hasNextPage}) | tojson end" \
    POST /graphql --field "query={ repository(owner:\"$owner\", name:\"$name\") { pullRequests(states:OPEN, first:$PR_LIMIT) { nodes { number mergeable isDraft title url headRefOid } pageInfo { hasNextPage } } } }"
}

# Mergeability, head SHA and draft flag for one pull request, used only to
# reread a pull request whose mergeability GitHub had not computed yet.
pr_view_record() {
  local repo=$1 number=$2 owner name
  fm_repo_slug_valid "$repo" || { LAST_READ_CAUSE=invalid-origin; return 2; }
  owner=${repo%%/*}
  name=${repo#*/}
  LAST_READ_CAUSE=
  gh_api "${GQL_GUARD}elif (.data.repository.pullRequest | type) != \"object\" then error(\"no pull request\") else (.data.repository.pullRequest | {mergeable: (.mergeable // \"UNKNOWN\"), headRefOid: (.headRefOid // \"\"), isDraft}) | tojson end" \
    POST /graphql --field "query={ repository(owner:\"$owner\", name:\"$name\") { pullRequest(number:$number) { mergeable headRefOid isDraft } } }"
}

# Resolve one pull request's lazily computed mergeability into RESOLVED_STATE,
# with the head RESOLVED_STATE describes in RESOLVED_HEAD - the read that
# settled the state is also what names the head it was settled for, so a head
# force-updated between the list and this read is reported under the SHA that
# was actually judged.
#
# The retry loop is bounded by the sweep deadline as well as by the attempt
# count: overrunning FM_CHECK_TIMEOUT gets the process group killed, and this
# check prints and records only at the end, so an overrun sweep loses every
# finding it made and repeats that loss on every poll. An unsettled read stays
# unknown, which is silent, and never becomes clean or conflicted.
pr_mergeable_resolved() {
  local repo=$1 number=$2 attempt=0 record mergeable head draft
  RESOLVED_STATE=unknown
  RESOLVED_HEAD=
  RESOLVED_DRAFT=
  while :; do
    if budget_exhausted; then
      RESOLVED_STATE=unknown
      LAST_READ_CAUSE=budget
      return 0
    fi
    pr_view_record "$repo" "$number" || return 2
    record=$GH_API_BODY
    mergeable=$(printf '%s' "$record" | jq -r '.mergeable // "UNKNOWN"' 2>/dev/null) || return 2
    head=$(printf '%s' "$record" | jq -r '.headRefOid // ""' 2>/dev/null) || return 2
    draft=$(printf '%s' "$record" | jq -r '.isDraft | tostring' 2>/dev/null) || return 2
    case "$mergeable" in
      MERGEABLE)
        RESOLVED_STATE=clean
        RESOLVED_HEAD=$head
        RESOLVED_DRAFT=$draft
        return 0
        ;;
      CONFLICTING)
        RESOLVED_STATE=conflicted
        RESOLVED_HEAD=$head
        RESOLVED_DRAFT=$draft
        return 0
        ;;
      UNKNOWN|'')
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$UNKNOWN_ATTEMPTS" ]; then
          RESOLVED_STATE=unknown
          return 0
        fi
        if [ $((DEADLINE - $(real_epoch))) -le $((UNKNOWN_WAIT + PROBE_MIN_SECS)) ]; then
          RESOLVED_STATE=unknown
          LAST_READ_CAUSE=budget
          return 0
        fi
        [ "$UNKNOWN_WAIT" -eq 0 ] || sleep "$UNKNOWN_WAIT"
        ;;
      *)
        RESOLVED_STATE=unknown
        return 0
        ;;
    esac
  done
}

format_finding() {
  local owner_team=$1 repo=$2 number=$3 head=$4 draft=$5 url=$6 title=$7
  local draft_label=no
  [ "$draft" = true ] && draft_label=yes
  title=$(printf '%s' "$title" | tr '\t\r\n' '   ')
  printf 'owner-team=%s repo=%s number=%s head=%s draft=%s url=%s title=%s' \
    "$owner_team" "$repo" "$number" "$head" "$draft_label" "$url" "$title"
}

evaluate_repo() {
  local repo=$1 owner_team=$2 result records has_next n i
  local number head draft mergeable url title key state
  ATTEMPT_CAUSE=
  budget_exhausted && { ATTEMPT_CAUSE=budget; return 1; }
  if ! pr_list_records "$repo"; then
    budget_exhausted && { ATTEMPT_CAUSE=budget; return 1; }
    ATTEMPT_CAUSE=${LAST_READ_CAUSE:-github}
    return 1
  fi
  result=$GH_API_BODY
  records=$(printf '%s' "$result" | jq -c '.records' 2>/dev/null) || { ATTEMPT_CAUSE=github; return 1; }
  has_next=$(printf '%s' "$result" | jq -r '.hasNextPage' 2>/dev/null) || { ATTEMPT_CAUSE=github; return 1; }
  n=$(printf '%s' "$records" | jq 'length' 2>/dev/null) || { ATTEMPT_CAUSE=github; return 1; }
  i=0
  while [ "$i" -lt "$n" ]; do
    budget_exhausted && { ATTEMPT_CAUSE=budget; return 1; }
    number=$(printf '%s' "$records" | jq -r --argjson i "$i" '.[$i].number | tostring')
    head=$(printf '%s' "$records" | jq -r --argjson i "$i" '.[$i].headRefOid // ""')
    draft=$(printf '%s' "$records" | jq -r --argjson i "$i" '.[$i].isDraft | tostring')
    mergeable=$(printf '%s' "$records" | jq -r --argjson i "$i" '.[$i].mergeable // "UNKNOWN"')
    url=$(printf '%s' "$records" | jq -r --argjson i "$i" '.[$i].url // ""')
    title=$(printf '%s' "$records" | jq -r --argjson i "$i" '.[$i].title // ""')
    i=$((i + 1))
    [ -n "$number" ] && [ "$number" != null ] || continue
    [ -n "$head" ] || continue
    seen_key "$(conflict_key "$repo" "$number" "$head")"
    case "$mergeable" in
      MERGEABLE) state=clean ;;
      CONFLICTING) state=conflicted ;;
      *)
        if ! pr_mergeable_resolved "$repo" "$number"; then
          budget_exhausted && { ATTEMPT_CAUSE=budget; return 1; }
          ATTEMPT_CAUSE=${LAST_READ_CAUSE:-github}
          return 1
        fi
        state=$RESOLVED_STATE
        [ -z "$RESOLVED_DRAFT" ] || draft=$RESOLVED_DRAFT
        if [ -n "$RESOLVED_HEAD" ] && [ "$RESOLVED_HEAD" != "$head" ]; then
          record_remove_key "$(conflict_key "$repo" "$number" "$head")"
          head=$RESOLVED_HEAD
          seen_key "$(conflict_key "$repo" "$number" "$head")"
        fi
        ;;
    esac
    key=$(conflict_key "$repo" "$number" "$head")
    case "$state" in
      conflicted) ;;
      clean)
        record_remove_key "$key"
        continue
        ;;
      *) continue ;;
    esac
    record_has_key "$key" && continue
    queue_item conflict "$key" "$(format_finding "$owner_team" "$repo" "$number" "$head" "$draft" "$url" "$title")" "$key"
  done
  budget_exhausted && { ATTEMPT_CAUSE=budget; return 1; }
  if [ "$has_next" = true ]; then
    ATTEMPT_CAUSE=truncated
    return 1
  fi
  mark_observed "repo:$repo"
  SWEPT_REPOS="$SWEPT_REPOS $repo"
  return 0
}

action_check() {
  local id repo owner_team now cut cause jq_present=1 gh_present=1 runtime_recovered=0
  record_read
  command -v jq >/dev/null 2>&1 || jq_present=0
  command -v "$GH_AXI" >/dev/null 2>&1 || gh_present=0
  FINDING_KINDS=()
  FINDING_IDS=()
  FINDING_TEXTS=()
  FINDING_KEYS=()
  if [ "$jq_present" -eq 0 ] || [ "$gh_present" -eq 0 ]; then
    if [ "$jq_present" -eq 0 ]; then
      runtime_gap_touch jq
    else
      runtime_gap_close jq
    fi
    if [ "$gh_present" -eq 0 ]; then
      runtime_gap_touch gh-axi
    else
      runtime_gap_close gh-axi
    fi
    deliver_findings || { record_write "$REPORTED_KEYS" || true; return 1; }
    record_write "$REPORTED_KEYS" || true
    return 0
  fi
  [ "$RUNTIME_JQ_OPENED" = 0 ] || runtime_recovered=1
  [ "$RUNTIME_GH_OPENED" = 0 ] || runtime_recovered=1
  runtime_gap_close jq
  runtime_gap_close gh-axi
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    [ "$runtime_recovered" -eq 0 ] || record_write "$REPORTED_KEYS" || true
    return 0
  fi

  DEADLINE=$(($(real_epoch) + BUDGET_SECS))
  OBSERVED_TARGETS=
  SWEPT_REPOS=
  SEEN_KEYS=
  if [ -n "$BUDGET_CUT_FROM" ]; then
    queue_item notice budget-cut "sweep budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
  fi

  discover_targets
  cut=0
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    repo=$(map_lookup "$TARGET_REPO_MAP" "$id") || repo=
    cause=$(map_lookup "$TARGET_CAUSE_MAP" "$id") || cause=
    case "$id" in
      source:*|project:*)
        gap_touch "$id" "${cause:-discovery}" "$repo"
        continue
        ;;
    esac
    if [ "$cut" -eq 1 ] || budget_exhausted; then
      cut=1
      gap_touch "$id" budget "$repo"
      continue
    fi
    owner_team=$(owner_for_repo "$repo")
    if ! evaluate_repo "$repo" "$owner_team"; then
      if [ "${ATTEMPT_CAUSE:-}" = budget ]; then
        cut=1
      fi
      gap_touch "$id" "${ATTEMPT_CAUSE:-github}" "$repo"
    fi
  done <<EOF
$EXPECTED_TARGETS
EOF

  if sweep_complete_from_outcomes; then
    SWEEP_COMPLETE=1
  else
    SWEEP_COMPLETE=0
  fi

  if ! deliver_findings; then
    record_prune
    coverage_prune
    record_write "$REPORTED_KEYS" || true
    return 1
  fi
  record_prune
  coverage_prune
  record_write "$REPORTED_KEYS" || true
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-pr-conflict-watch.sh - PR merge conflict poll shim.' \
    '# The watcher validates these bytes, then dispatches the trusted check script.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-pr-conflict-watch.sh") check"
}

SHIM_WRITE_TMP=

shim_write() {
  local want=$1 device tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  if [ -e "$CHECK_SHIM" ] && [ "$(fm_pr_file_mode "$CHECK_SHIM")" = 700 ] \
    && [ "$(cat "$CHECK_SHIM" 2>/dev/null)" = "$want" ]; then
    return 0
  fi
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-conflict-watch-check.XXXXXX" 2>/dev/null) || return 1
  SHIM_WRITE_TMP=$tmp
  if ! printf '%s\n' "$want" > "$tmp" \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  if ! fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" \
    || ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    SHIM_WRITE_TMP=
    return 1
  fi
  SHIM_WRITE_TMP=
  fm_pr_private_file_valid "$CHECK_SHIM" 700 "$device"
}

shim_backup() {
  local device tmp
  device=$(fm_pr_file_device "$STATE") || return 1
  [ -n "$device" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.fm-pr-conflict-watch-check.XXXXXX" 2>/dev/null) || return 1
  if ! cat "$CHECK_SHIM" > "$tmp" 2>/dev/null \
    || ! chmod 0700 "$tmp" \
    || ! fm_pr_private_file_valid "$tmp" 700 "$device"; then
    rm -f -- "$tmp"
    return 1
  fi
  printf '%s\n' "$tmp"
}

ARM_BACKUP=

arm_rollback() {
  [ -z "$SHIM_WRITE_TMP" ] || rm -f -- "$SHIM_WRITE_TMP"
  SHIM_WRITE_TMP=
  if [ -n "$ARM_BACKUP" ]; then
    mv -f -- "$ARM_BACKUP" "$CHECK_SHIM" 2>/dev/null || rm -f -- "$ARM_BACKUP"
    ARM_BACKUP=
    if fm_custom_check_registered "$STATE" "$CHECK_ID"; then
      return 0
    fi
  fi
  rm -f -- "$CHECK_SHIM"
}

arm_interrupted() {
  arm_rollback
  printf 'fm-pr-conflict-watch: arming was interrupted, so state/%s.check.sh is not armed\n' "$CHECK_ID" >&2
  exit 1
}

action_arm() {
  local want home
  if ! command -v jq >/dev/null 2>&1; then
    printf 'fm-pr-conflict-watch: jq is required\n' >&2
    return 1
  fi
  if ! command -v "$GH_AXI" >/dev/null 2>&1; then
    printf 'fm-pr-conflict-watch: %s is required\n' "$GH_AXI" >&2
    return 1
  fi
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *)
      home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || {
        printf 'fm-pr-conflict-watch: cannot resolve FM_HOME %s\n' "$FM_HOME" >&2
        return 1
      }
      ;;
  esac
  want=$(shim_content "$home")
  ARM_BACKUP=
  if [ -f "$CHECK_SHIM" ] && [ ! -L "$CHECK_SHIM" ]; then
    ARM_BACKUP=$(shim_backup) || {
      printf 'fm-pr-conflict-watch: could not save the existing %s\n' "$CHECK_SHIM" >&2
      return 1
    }
  fi
  trap arm_interrupted HUP INT TERM
  if ! shim_write "$want"; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-pr-conflict-watch: could not write %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    trap - HUP INT TERM
    arm_rollback
    printf 'fm-pr-conflict-watch: could not register %s\n' "$CHECK_SHIM" >&2
    return 1
  fi
  trap - HUP INT TERM
  [ -z "$ARM_BACKUP" ] || rm -f -- "$ARM_BACKUP"
  ARM_BACKUP=
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
  return 0
}

case "${1:-check}" in
  check) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
  -h|--help) usage ;;
  *) die_usage "unknown action: $1" ;;
esac
