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
# conflicts each sweep still observes, so it cannot grow without bound.
#
# GitHub is read through `gh-axi api`, which answers with an axi envelope rather
# than raw JSON. GitHub computes mergeability lazily and omits it from the pull
# request list endpoint entirely, so each open pull request is resolved by its
# own read. A read that returns null mergeability is never treated as clean or
# conflicted; the check polls with short waits until the state settles or stays
# unknown.
#
# A repository GitHub cannot be read for is not silence about a clean fleet. A
# transient failure is ignored, but one that outlasts
# FM_PR_CONFLICT_UNREAD_GRACE_SECS is disclosed once as a hole in coverage, and
# any failed read stops the sweep counting as complete.
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

record_epoch_now() { date +%s; }

real_epoch() { date +%s; }

DEADLINE=0
REPORTED_KEYS=
RECORD_EPOCH=0
FINDING_TEXTS=()
FINDING_KEYS=()
FINDING_LINE=
FINDING_LINE_KEYS=
FINDING_OMITTED=0
DISCOVERED_REPOS=
REPO_OWNER_MAP=
PROJECT_OWNER_MAP=
FIRSTMATE_SLUG=
SWEPT_REPOS=
SEEN_KEYS=
UNREAD_MAP=
UNREAD_PENDING=
SWEEP_COMPLETE=1
DISCOVERY_COMPLETE=1
RESOLVED_STATE=
RESOLVED_HEAD=

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

# A finding is queued together with the dedupe key that would suppress its
# repeat, and that key is recorded only once the finding survives the line cap.
# A finding cut from the printed line was never reported, so recording it would
# silence that conflict for good: its head does not change, so no later sweep
# re-triggers it.
queue_finding() {
  local text
  text=$(printf '%s' "$1" | tr '\t\r\n' '   ')
  FINDING_TEXTS+=("$text")
  FINDING_KEYS+=("${2:-}")
}

# Fill the line in queue order up to <reserve> characters short of the cap, and
# collect the keys of exactly the findings that fit. The first finding is always
# taken, so a single over-long finding still reports something - the title is
# the only unbounded field and it is last, so the final cut takes that tail -
# rather than leaving the sweep permanently silent.
build_finding_line() {
  local reserve=$1 total i text key candidate room
  FINDING_LINE=
  FINDING_LINE_KEYS=
  FINDING_OMITTED=0
  total=${#FINDING_TEXTS[@]}
  room=$((MAX_LINE - reserve))
  i=0
  while [ "$i" -lt "$total" ]; do
    text=${FINDING_TEXTS[$i]}
    key=${FINDING_KEYS[$i]}
    if [ -z "$FINDING_LINE" ]; then
      candidate="$FINDING_PREFIX$text"
    else
      candidate="$FINDING_LINE; $text"
    fi
    if [ "$i" -eq 0 ] || [ "${#candidate}" -le "$room" ]; then
      FINDING_LINE=$candidate
      [ -z "$key" ] || FINDING_LINE_KEYS="${FINDING_LINE_KEYS:+$FINDING_LINE_KEYS;}$key"
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

firstmate_repo_slug() {
  local url
  url=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null) || return 1
  fm_repo_slug "$url"
}

# A registry that cannot be read enumerates nothing, which reads exactly like a
# home that registered no projects. The difference matters to record pruning, so
# the unreadable case is reported as a failure rather than as an empty list.
project_names() {
  [ -r "$DATA/projects.md" ] || return 1
  awk '$1 == "-" && $2 != "" { print $2 }' "$DATA/projects.md"
}

resolve_project_repo() {
  local project=$1 dir url slug
  dir="$PROJECTS/$project"
  [ -d "$dir" ] || return 1
  url=$(git -C "$dir" remote get-url origin 2>/dev/null) || return 1
  slug=$(fm_repo_slug "$url")
  [ -n "$slug" ] || return 1
  printf '%s\n' "$slug"
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

# Repositories and their owning targets are derived together, once per sweep, so
# neither the origin remotes nor the registry are re-read per repository while
# the same budget is paying for GitHub probes.
discover_repos() {
  local project slug owner names
  DISCOVERED_REPOS=
  REPO_OWNER_MAP=
  DISCOVERY_COMPLETE=1
  load_project_owners
  FIRSTMATE_SLUG=$(firstmate_repo_slug 2>/dev/null) || FIRSTMATE_SLUG=
  [ -n "$FIRSTMATE_SLUG" ] || DISCOVERY_COMPLETE=0
  # An unread registry leaves every project repository unnamed, so the firstmate
  # origin still resolving does not make this discovery complete.
  names=$(project_names 2>/dev/null) || { names=; DISCOVERY_COMPLETE=0; }
  while IFS= read -r project; do
    [ -n "$project" ] || continue
    # A project whose clone or origin cannot be read names no slug, so the sweep
    # cannot tell which repository went unread. That leaves the whole discovery
    # partial rather than this one entry skippable.
    slug=$(resolve_project_repo "$project" 2>/dev/null) || { DISCOVERY_COMPLETE=0; continue; }
    case " $DISCOVERED_REPOS " in
      *" $slug "*) continue ;;
    esac
    if [ -n "$FIRSTMATE_SLUG" ] && [ "$slug" = "$FIRSTMATE_SLUG" ]; then
      owner=$MAIN_OWNER
    else
      owner=$(owner_for_project "$project") || owner=
      [ -n "$owner" ] || owner=$MAIN_OWNER
    fi
    DISCOVERED_REPOS="$DISCOVERED_REPOS $slug"
    REPO_OWNER_MAP="$REPO_OWNER_MAP$slug $owner
"
  done <<EOF
$names
EOF
  if [ -n "$FIRSTMATE_SLUG" ]; then
    case " $DISCOVERED_REPOS " in
      *" $FIRSTMATE_SLUG "*) ;;
      *)
        DISCOVERED_REPOS="$DISCOVERED_REPOS $FIRSTMATE_SLUG"
        REPO_OWNER_MAP="$REPO_OWNER_MAP$FIRSTMATE_SLUG $MAIN_OWNER
"
        ;;
    esac
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
  local line first=1
  RECORD_EPOCH=0
  REPORTED_KEYS=
  UNREAD_MAP=
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
      unread=*) unread_load "${line#unread=}" ;;
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
    printf 'unread=%s\n' "$(unread_serialize)"
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

# A repository whose GitHub read fails is remembered as unread across sweeps:
# the epoch its reads started failing, and whether that hole has been disclosed
# yet. GitHub blips constantly, so a failure that has not yet outlasted
# FM_PR_CONFLICT_UNREAD_GRACE_SECS stays silent - waking on every transient
# error is noise. A failure that does outlast it is a real hole in coverage and
# is said once, naming the repository and how long it has been unreadable. It
# is not a conflict, and it is never recorded as one.
#
# Either way the sweep is no longer complete: a sweep that could not read
# everything must not be able to prune keys for repositories it never saw.
unread_set() {
  local repo=$1 first=$2 disclosed=$3 out='' line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%% *}" = "$repo" ] && continue
    out="$out$line
"
  done <<EOF
$UNREAD_MAP
EOF
  UNREAD_MAP="$out$repo $first $disclosed
"
}

repo_read_ok() {
  local repo=$1 out='' line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    [ "${line%% *}" = "$repo" ] && continue
    out="$out$line
"
  done <<EOF
$UNREAD_MAP
EOF
  UNREAD_MAP=$out
}

repo_read_failed() {
  local repo=$1 entry first disclosed now elapsed
  SWEEP_COMPLETE=0
  now=$(record_epoch_now)
  entry=$(map_lookup "$UNREAD_MAP" "$repo") || entry=
  first=${entry%% *}
  disclosed=${entry##* }
  case "$first" in ''|*[!0-9]*) first=$now ;; esac
  case "$disclosed" in 1) disclosed=1 ;; *) disclosed=0 ;; esac
  elapsed=0
  [ "$now" -gt "$first" ] && elapsed=$((now - first))
  if [ "$disclosed" -eq 0 ] && [ "$elapsed" -ge "$UNREAD_GRACE" ]; then
    # Marked as said only once it survives into the printed line, so a
    # disclosure dropped by the line cap is repeated on a later sweep instead
    # of being silently counted as delivered.
    queue_finding "unread repo=$repo for ${elapsed}s - GitHub reads failing, conflict coverage has a hole"
    UNREAD_PENDING="${UNREAD_PENDING:+$UNREAD_PENDING }$repo"
  fi
  unread_set "$repo" "$first" "$disclosed"
}

unread_serialize() {
  local out='' line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    # shellcheck disable=SC2086 # deliberate split into repo, epoch, disclosed
    set -- $line
    [ "$#" -eq 3 ] || continue
    out="${out:+$out;}$1@$2@$3"
  done <<EOF
$UNREAD_MAP
EOF
  printf '%s\n' "$out"
}

unread_load() {
  local raw=$1 part repo first disclosed
  UNREAD_MAP=
  while IFS= read -r part; do
    [ -n "$part" ] || continue
    repo=${part%%@*}
    part=${part#*@}
    first=${part%%@*}
    disclosed=${part#*@}
    [ -n "$repo" ] || continue
    case "$first" in ''|*[!0-9]*) continue ;; esac
    case "$disclosed" in 0|1) ;; *) continue ;; esac
    UNREAD_MAP="$UNREAD_MAP$repo $first $disclosed
"
  done < <(list_parts "$raw" ';')
}

# A repository this fleet no longer works in cannot go on holding an unread
# entry, but absence from a partial discovery is a failed read rather than
# proof it was dropped - the same rule the conflict keys are pruned under.
unread_prune() {
  local out='' line repo
  [ "$DISCOVERY_COMPLETE" -eq 1 ] || return 0
  [ -n "$DISCOVERED_REPOS" ] || return 0
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    repo=${line%% *}
    case " $DISCOVERED_REPOS " in
      *" $repo "*) out="$out$line
" ;;
    esac
  done <<EOF
$UNREAD_MAP
EOF
  UNREAD_MAP=$out
}

unread_confirm_disclosed() {
  local line=$1 repo entry first
  for repo in $UNREAD_PENDING; do
    [ -n "$repo" ] || continue
    case "$line" in
      *"unread repo=$repo for "*) ;;
      *) continue ;;
    esac
    entry=$(map_lookup "$UNREAD_MAP" "$repo") || continue
    first=${entry%% *}
    unread_set "$repo" "$first" 1
  done
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
  local path=$1 query=$2 out line body='' have_body=0 truncated=false enveloped=0
  out=$(gh_bounded api "$path" --jq "$query" --full 2>/dev/null) || return 2
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
  done <<EOF
$out
EOF
  # A scalar that needs no envelope is printed bare, so an unenveloped read is
  # passed through rather than treated as a parse failure.
  if [ "$enveloped" -eq 0 ]; then
    printf '%s\n' "$out"
    return 0
  fi
  [ "$truncated" = false ] || return 2
  [ "$have_body" -eq 1 ] || return 2
  case "$body" in
    '"'*) body=$(printf '%s' "$body" | jq -r '.' 2>/dev/null) || return 2 ;;
  esac
  printf '%s\n' "$body"
}

# One tab-separated record per open pull request: number, head SHA, draft flag,
# url, title. The REST list endpoint does not carry mergeability at all, so the
# state each pull request is judged on comes from the per-pull-request read
# below rather than from this page.
pr_list_records() {
  local repo=$1
  gh_api "/repos/$repo/pulls?state=open&per_page=$PR_LIMIT" \
    '[.[] | [(.number|tostring), (.head.sha // ""), (.draft|tostring), (.html_url // ""), ((.title // "") | gsub("[\t\r\n]"; " "))] | @tsv] | join("\n")'
}

# mergeable, head SHA, draft flag, url, title for one pull request. REST
# reports lazily computed mergeability as true, false, or null, where null is
# the not-yet-computed state this check must never read as an answer.
pr_view_record() {
  local repo=$1 number=$2
  gh_api "/repos/$repo/pulls/$number" \
    '[(.mergeable|tostring), (.head.sha // ""), (.draft|tostring), (.html_url // ""), ((.title // "") | gsub("[\t\r\n]"; " "))] | @tsv'
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
  local repo=$1 number=$2 attempt=0 record mergeable head
  RESOLVED_STATE=unknown
  RESOLVED_HEAD=
  while :; do
    if budget_exhausted; then
      RESOLVED_STATE=unknown
      return 0
    fi
    record=$(pr_view_record "$repo" "$number") || return 2
    IFS=$'\t' read -r mergeable head _ <<EOF
$record
EOF
    case "$mergeable" in
      true)
        RESOLVED_STATE=clean
        RESOLVED_HEAD=$head
        return 0
        ;;
      false)
        RESOLVED_STATE=conflicted
        RESOLVED_HEAD=$head
        return 0
        ;;
      null|'')
        attempt=$((attempt + 1))
        if [ "$attempt" -ge "$UNKNOWN_ATTEMPTS" ]; then
          RESOLVED_STATE=unknown
          return 0
        fi
        if [ $((DEADLINE - $(real_epoch))) -le $((UNKNOWN_WAIT + PROBE_MIN_SECS)) ]; then
          RESOLVED_STATE=unknown
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
  local repo=$1 owner_team=$2 records count=0
  local number head draft url title key state
  budget_exhausted && return 1
  records=$(pr_list_records "$repo") || { repo_read_failed "$repo"; return 0; }
  while IFS=$'\t' read -r number head draft url title; do
    [ -n "$number" ] || continue
    count=$((count + 1))
    budget_exhausted && return 1
    [ -n "$head" ] || continue
    seen_key "$(conflict_key "$repo" "$number" "$head")"
    # Mergeability is absent from the list page, so every open pull request is
    # resolved through its own read. A read that fails leaves this repository
    # unswept rather than silently clean.
    pr_mergeable_resolved "$repo" "$number" || { repo_read_failed "$repo"; return 0; }
    state=$RESOLVED_STATE
    if [ -n "$RESOLVED_HEAD" ] && [ "$RESOLVED_HEAD" != "$head" ]; then
      record_remove_key "$(conflict_key "$repo" "$number" "$head")"
      head=$RESOLVED_HEAD
      seen_key "$(conflict_key "$repo" "$number" "$head")"
    fi
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
    queue_finding "$(format_finding "$owner_team" "$repo" "$number" "$head" "$draft" "$url" "$title")" "$key"
  done <<EOF
$records
EOF
  # Reaching here means every read this repository needed succeeded, so a
  # repository that had been failing is no longer an unread hole.
  repo_read_ok "$repo"
  # Only a page that was not itself cut short by PR_LIMIT can be read as the
  # repository's whole open set, which is what pruning its stale keys relies on.
  if [ "$count" -lt "$PR_LIMIT" ]; then
    SWEPT_REPOS="$SWEPT_REPOS $repo"
  fi
  return 0
}

action_check() {
  local repo owner_team line now notice
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
    queue_finding "sweep budget ${BUDGET_CUT_FROM}s cut to ${BUDGET_SECS}s to stay inside the watcher check timeout of ${CHECK_TIMEOUT}s"
  fi

  discover_repos
  for repo in $DISCOVERED_REPOS; do
    [ -n "$repo" ] || continue
    if budget_exhausted; then
      SWEEP_COMPLETE=0
      break
    fi
    owner_team=$(owner_for_repo "$repo")
    evaluate_repo "$repo" "$owner_team" || { SWEEP_COMPLETE=0; break; }
  done

  line=
  if [ "${#FINDING_TEXTS[@]}" -gt 0 ]; then
    build_finding_line 0
    if [ "$FINDING_OMITTED" -gt 0 ]; then
      # Reserve the widest the disclosure can be, so the second pass cannot be
      # invalidated by the count it is making room for.
      notice="; ${#FINDING_TEXTS[@]} more omitted (line cap)"
      build_finding_line "${#notice}"
      if [ "$FINDING_OMITTED" -gt 0 ]; then
        FINDING_LINE="$FINDING_LINE; $FINDING_OMITTED more omitted (line cap)"
      fi
    fi
    # A last cut through the shared rule, so an over-long single finding ends
    # with the same visible truncation marker the digests use.
    fm_cap_line_var "$FINDING_LINE" "$MAX_LINE"
    line=$FM_LINE_CAP_LINE
  fi

  unread_confirm_disclosed "$line"
  record_prune
  unread_prune
  record_add_keys "$FINDING_LINE_KEYS"

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
