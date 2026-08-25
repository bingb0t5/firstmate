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
# after the first wake.
#
# GitHub computes mergeability lazily. A single read that returns UNKNOWN is
# never treated as clean or conflicted; the check polls with short waits until
# the state settles or stays unknown.
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
RECORD_SCHEMA=fm-pr-conflict-watch-v1
GH_AXI=${FM_PR_CONFLICT_GH_AXI:-gh-axi}
MAX_LINE=1000
MAIN_OWNER=main

# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
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
FINDINGS=

emit_finding() {
  local text
  text=$(printf '%s' "$1" | tr '\t\r\n' '   ')
  if [ -z "$FINDINGS" ]; then
    FINDINGS=$text
  else
    FINDINGS="$FINDINGS; $text"
  fi
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

repo_slug() {
  printf '%s' "$1" | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##; s#/pull/.*$##; s#/$##'
}

firstmate_repo_slug() {
  local url
  url=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null) || return 1
  repo_slug "$url"
}

project_names() {
  [ -f "$DATA/projects.md" ] || return 0
  awk '$1 == "-" && $2 != "" { print $2 }' "$DATA/projects.md"
}

resolve_project_repo() {
  local project=$1 dir url slug
  dir="$PROJECTS/$project"
  [ -d "$dir" ] || return 1
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  slug=$(repo_slug "$url")
  [ -n "$slug" ] || return 1
  printf '%s\n' "$slug"
}

discover_repos() {
  local project slug repos='' fm_slug
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    slug=$(resolve_project_repo "$project" 2>/dev/null) || continue
    case " $repos " in
      *" $slug "*) ;;
      *) repos="$repos $slug" ;;
    esac
  done < <(project_names)
  fm_slug=$(firstmate_repo_slug 2>/dev/null) || fm_slug=
  if [ -n "$fm_slug" ]; then
    case " $repos " in
      *" $fm_slug "*) ;;
      *) repos="$repos $fm_slug" ;;
    esac
  fi
  for slug in $repos; do
    [ -n "$slug" ] || continue
    printf '%s\n' "$slug"
  done
}

trim_field() {
  local value=$1
  value=${value#"${value%%[![:space:]]*}"}
  value=${value%"${value##*[![:space:]]}"}
  printf '%s\n' "$value"
}

owner_for_project() {
  local project=$1 reg line id projects part
  reg="$DATA/secondmates.md"
  [ -f "$reg" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "- "*)
        secondmate_registry_parse_line "$line" || continue
        id=$SECONDMATE_REGISTRY_ID
        projects=$SECONDMATE_REGISTRY_PROJECTS
        IFS=',' read -r -a _parts <<< "$projects"
        for part in "${_parts[@]}"; do
          part=$(trim_field "$part")
          [ "$part" = "$project" ] || continue
          printf '%s\n' "$id"
          return 0
        done
        ;;
    esac
  done < "$reg"
  return 1
}

owner_for_repo() {
  local repo=$1 project slug owner fm_slug
  fm_slug=$(firstmate_repo_slug 2>/dev/null) || fm_slug=
  if [ -n "$fm_slug" ] && [ "$repo" = "$fm_slug" ]; then
    printf '%s\n' "$MAIN_OWNER"
    return 0
  fi
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    slug=$(resolve_project_repo "$project" 2>/dev/null) || continue
    [ "$slug" = "$repo" ] || continue
    owner=$(owner_for_project "$project" 2>/dev/null) || owner=
    if [ -n "$owner" ]; then
      printf '%s\n' "$owner"
    else
      printf '%s\n' "$MAIN_OWNER"
    fi
    return 0
  done < <(project_names)
  printf '%s\n' "$MAIN_OWNER"
}

conflict_key() {
  local repo=$1 number=$2 head=$3
  printf '%s#%s#%s' "$repo" "$number" "$head"
}

record_read() {
  local line first=1
  RECORD_EPOCH=0
  REPORTED_KEYS=
  [ -f "$RECORD" ] || return 0
  while IFS= read -r line; do
    if [ "$first" = 1 ]; then
      first=0
      [ "$line" = "$RECORD_SCHEMA" ] || return 0
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

record_remove_key() {
  local key=$1 out='' part
  IFS=';' read -r -a _parts <<< "$REPORTED_KEYS"
  for part in "${_parts[@]}"; do
    [ -n "$part" ] || continue
    [ "$part" = "$key" ] && continue
    if [ -z "$out" ]; then
      out=$part
    else
      out="$out;$part"
    fi
  done
  REPORTED_KEYS=$out
}

json_field() {
  local json=$1 query=$2
  command -v jq >/dev/null 2>&1 || return 1
  printf '%s' "$json" | jq -er "$query" 2>/dev/null
}

pr_mergeable_resolved() {
  local repo=$1 number=$2 mergeable='' attempt=0 json
  while :; do
    json=$(gh_bounded pr view "$number" --repo "$repo" \
      --json mergeable,mergeStateStatus,number,title,url,headRefOid,isDraft 2>/dev/null) || return 2
    mergeable=$(json_field "$json" '.mergeable // "UNKNOWN"') || return 2
    case "$mergeable" in
      MERGEABLE) printf 'clean\n'; return 0 ;;
      CONFLICTING) printf 'conflicted\n'; return 0 ;;
      UNKNOWN)
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$UNKNOWN_ATTEMPTS" ]; then
          printf 'unknown\n'
          return 0
        fi
        [ "$UNKNOWN_WAIT" -eq 0 ] || sleep "$UNKNOWN_WAIT"
        ;;
      *) printf 'unknown\n'; return 0 ;;
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
  local repo=$1 owner_team=$2 json count i row number title head draft url mergeable key resolved
  budget_exhausted && return 1
  json=$(gh_bounded pr list --repo "$repo" --state open --limit "$PR_LIMIT" \
    --json number,title,url,headRefOid,isDraft,mergeable 2>/dev/null) || return 0
  [ -n "$json" ] || json='[]'
  count=$(json_field "$json" 'length' 2>/dev/null) || return 0
  i=0
  while [ "$i" -lt "$count" ]; do
    budget_exhausted && return 1
    row=$(json_field "$json" ".[$i]" 2>/dev/null) || { i=$((i + 1)); continue; }
    number=$(json_field "$row" '.number') || { i=$((i + 1)); continue; }
    title=$(json_field "$row" '.title // ""') || title=
    url=$(json_field "$row" '.url // ""') || url=
    head=$(json_field "$row" '.headRefOid // ""') || head=
    draft=$(json_field "$row" '.isDraft // false') || draft=false
    mergeable=$(json_field "$row" '.mergeable // "UNKNOWN"') || mergeable=UNKNOWN
    i=$((i + 1))
    [ -n "$head" ] || continue
    key=$(conflict_key "$repo" "$number" "$head")
    case "$mergeable" in
      MERGEABLE)
        record_remove_key "$key"
        continue
        ;;
      CONFLICTING) ;;
      UNKNOWN)
        resolved=$(pr_mergeable_resolved "$repo" "$number") || continue
        case "$resolved" in
          conflicted) ;;
          clean)
            record_remove_key "$key"
            continue
            ;;
          *) continue ;;
        esac
        ;;
      *) continue ;;
    esac
    record_has_key "$key" && continue
    emit_finding "$(format_finding "$owner_team" "$repo" "$number" "$head" "$draft" "$url" "$title")"
    record_add_key "$key"
  done
  return 0
}

action_check() {
  local repo owner_team line now
  if ! command -v jq >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v "$GH_AXI" >/dev/null 2>&1; then
    return 0
  fi

  record_read
  now=$(record_epoch_now)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] \
    && [ "$now" -ge "$RECORD_EPOCH" ] && [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi

  DEADLINE=$(($(real_epoch) + BUDGET_SECS))

  if [ -n "$BUDGET_CUT_FROM" ]; then
    emit_finding "sweep budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
  fi

  while IFS= read -r repo; do
    [ -n "$repo" ] || continue
    budget_exhausted && break
    owner_team=$(owner_for_repo "$repo")
    evaluate_repo "$repo" "$owner_team" || break
  done < <(discover_repos)

  line=
  if [ -n "$FINDINGS" ]; then
    fm_cap_line_var "pr-conflict: $FINDINGS" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  if [ -n "$line" ]; then
    printf '%s\n' "$line"
  fi
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
