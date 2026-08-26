#!/usr/bin/env bash
# Promote a scout task to a ship task in place: the crewmate keeps its window,
# worktree, and loaded context; only the contract changes. Flips kind= to ship in
# state/<task-id>.meta so fm-teardown.sh applies the full ship-task teardown protection
# again. After promoting, send the crewmate its ship instructions via fm-send.sh
# (inventory scratch state, reset to a clean default-branch base, carry over only
# intended fix changes, create branch fm/<task-id>, implement, then report done
# according to this task's delivery mode).
# A scout records no delivery posture, so promotion is where this task's delivery
# contract is decided: --mode and --yolo are REQUIRED and written into the meta
# alongside the kind= flip. Firstmate resolves both at promotion time, having just
# read the scout's report (AGENTS.md section 7); data/projects.md holds the
# captain's standing posture as context, and this script never looks it up.
# no-mistakes-prod-only is a registry policy rather than a task mode and is refused.
#
# --sol-spec-for <gated-ship-task-id> is the other half of the same scout+promote
# path and promotes an ARTIFACT rather than a task: it installs a Sol spec scout's
# reviewed data/<scout-id>/spec.md at data/<gated-ship-task-id>/spec.md, which is
# the only artifact that clears the second-attempt gate in
# bin/fm-second-attempt-lib.sh. It exists because the gated ship task cannot be
# its own recovery vehicle - fm-brief.sh refuses to scaffold over its existing
# brief - while a fresh scout promoted to ship in place would strand that task's
# worktree, branch, commits, no-mistakes run, and PR. So this mode decides no
# delivery contract and rewrites no meta: the scout stays kind=scout and is torn
# down normally, the gated ship keeps its endpoint and implementation identity,
# and the operator simply repeats the refused relaunch through the existing gate.
# It fails closed before touching anything - the source must be a scout carrying
# its own non-empty spec.md, the target must be a ship task that is actually
# gated, and an existing target spec that differs is refused rather than
# overwritten - and the install itself is an atomic same-directory rename.
# Usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
#        fm-promote.sh <sol-spec-scout-id> --sol-spec-for <gated-ship-task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-public-followup-lib.sh
. "$SCRIPT_DIR/fm-public-followup-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-secondmate-registry-lib.sh
. "$SCRIPT_DIR/fm-secondmate-registry-lib.sh"
# shellcheck source=bin/fm-second-attempt-lib.sh
. "$SCRIPT_DIR/fm-second-attempt-lib.sh"
# shellcheck source=bin/fm-scout-artifact-lib.sh
. "$SCRIPT_DIR/fm-scout-artifact-lib.sh"

USAGE='usage: fm-promote.sh <task-id> --mode <no-mistakes|direct-PR|local-only> --yolo <on|off>
       fm-promote.sh <sol-spec-scout-id> --sol-spec-for <gated-ship-task-id>'
MODE=
YOLO=
SOL_SPEC_FOR=
MODE_SET=0
YOLO_SET=0
SOL_SPEC_FOR_SET=0
POS=()
want_value=
for a in "$@"; do
  if [ -n "$want_value" ]; then
    case "$a" in
      --*) echo "error: --$want_value requires a value" >&2; exit 1 ;;
    esac
    case "$want_value" in
      mode) MODE=$a; MODE_SET=1 ;;
      yolo) YOLO=$a; YOLO_SET=1 ;;
      sol-spec-for) SOL_SPEC_FOR=$a; SOL_SPEC_FOR_SET=1 ;;
    esac
    want_value=
    continue
  fi
  case "$a" in
    --mode) want_value=mode ;;
    --mode=*) MODE=${a#--mode=}; MODE_SET=1 ;;
    --yolo) want_value=yolo ;;
    --yolo=*) YOLO=${a#--yolo=}; YOLO_SET=1 ;;
    --sol-spec-for) want_value=sol-spec-for ;;
    --sol-spec-for=*) SOL_SPEC_FOR=${a#--sol-spec-for=}; SOL_SPEC_FOR_SET=1 ;;
    *) POS+=("$a") ;;
  esac
done
[ -z "$want_value" ] || { echo "error: --$want_value requires a value" >&2; exit 1; }
[ "${#POS[@]}" -ge 1 ] || { echo "$USAGE" >&2; exit 1; }
if [ "$SOL_SPEC_FOR_SET" -eq 1 ]; then
  [ "$MODE_SET" -eq 0 ] && [ "$YOLO_SET" -eq 0 ] || {
    echo "error: --sol-spec-for installs a Sol spec artifact for an existing ship task and decides no delivery contract; drop --mode and --yolo" >&2
    exit 1
  }
else
  [ "$MODE_SET" -eq 1 ] || {
    echo "error: promotion requires --mode <no-mistakes|direct-PR|local-only>; decide it now from the scout's findings and the project's registered posture in data/projects.md" >&2
    exit 1
  }
  [ "$YOLO_SET" -eq 1 ] || {
    echo "error: promotion requires --yolo <on|off>; it is this task's merge authority, not a project lookup" >&2
    exit 1
  }
  case "$MODE" in
    no-mistakes|direct-PR|local-only) ;;
    no-mistakes-prod-only)
      echo "error: no-mistakes-prod-only is a registry policy, not a task mode; classify this task's surface and resolve it to no-mistakes or direct-PR" >&2
      exit 1 ;;
    *) echo "error: --mode must be one of no-mistakes, direct-PR, local-only (got '$MODE')" >&2; exit 1 ;;
  esac
  case "$YOLO" in
    on|off) ;;
    *) echo "error: --yolo must be on or off (got '$YOLO')" >&2; exit 1 ;;
  esac
fi

ID=${POS[0]}
fm_task_id_creation_valid "$ID" || { echo "error: invalid task id" >&2; exit 2; }
if [ "$SOL_SPEC_FOR_SET" -eq 1 ]; then
  fm_task_id_creation_valid "$SOL_SPEC_FOR" || { echo "error: invalid --sol-spec-for task id" >&2; exit 2; }
  [ "$SOL_SPEC_FOR" != "$ID" ] || {
    echo "error: --sol-spec-for names the gated ship task, which is never the Sol spec scout itself" >&2
    exit 1
  }
fi
CONTROL_LOCK="$STATE/.control-$ID.lock"
CONTROL_LOCK_HELD=0
TARGET_LOCK=
TARGET_LOCK_HELD=0
META_LOCK=
META_LOCK_HELD=0
TMP=
promote_cleanup() {
  local status=$?
  [ -z "$TMP" ] || rm -f -- "$TMP" 2>/dev/null || true
  if [ "$META_LOCK_HELD" = 1 ]; then
    META_LOCK_HELD=0
    fm_lock_release "$META_LOCK" || true
  fi
  if [ "$TARGET_LOCK_HELD" = 1 ]; then
    TARGET_LOCK_HELD=0
    fm_lock_release "$TARGET_LOCK" || true
  fi
  if [ "$CONTROL_LOCK_HELD" = 1 ]; then
    CONTROL_LOCK_HELD=0
    fm_lock_release "$CONTROL_LOCK" || true
  fi
  return "$status"
}
trap promote_cleanup EXIT
fm_lock_try_acquire "$CONTROL_LOCK" || {
  echo "error: another lifecycle action is already running for task $ID; nothing was changed" >&2
  exit 1
}
CONTROL_LOCK_HELD=1
"$FM_ROOT/bin/fm-guard.sh" || true
META="$STATE/$ID.meta"
[ -d "$STATE" ] || { echo "error: state dir not found: $STATE" >&2; exit 1; }
HOME_Q=$(printf '%q' "$FM_HOME")

if [ "$SOL_SPEC_FOR_SET" -eq 1 ]; then
  TARGET_LOCK="$STATE/.control-$SOL_SPEC_FOR.lock"
  fm_lock_try_acquire "$TARGET_LOCK" || {
    echo "error: another lifecycle action is already running for task $SOL_SPEC_FOR; nothing was changed" >&2
    exit 1
  }
  TARGET_LOCK_HELD=1
  TARGET_META="$STATE/$SOL_SPEC_FOR.meta"
  [ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
  grep -qx 'kind=scout' "$META" || {
    echo "error: source task $ID is not a scout task (kind=scout not in meta); --sol-spec-for installs a Sol spec scout's own reviewed deliverable" >&2
    exit 1
  }
  SOURCE_SPEC=$(fm_second_attempt_spec_path "$DATA" "$ID")
  { [ -f "$SOURCE_SPEC" ] && [ ! -L "$SOURCE_SPEC" ]; } || {
    echo "error: scout $ID has no Sol spec of its own at $SOURCE_SPEC; only a Sol spec scout that already wrote spec.md can be installed" >&2
    exit 1
  }
  [ -s "$SOURCE_SPEC" ] || { echo "error: the Sol spec at $SOURCE_SPEC is empty; nothing was installed" >&2; exit 1; }
  [ -f "$TARGET_META" ] || { echo "error: no meta for task $SOL_SPEC_FOR at $TARGET_META" >&2; exit 1; }
  grep -qx 'kind=ship' "$TARGET_META" || {
    echo "error: task $SOL_SPEC_FOR is not a ship task (kind=ship not in meta); the second-attempt Sol spec gate applies to ship tasks only" >&2
    exit 1
  }
  TARGET_MARKER=$(fm_second_attempt_nm_third_fix_round_marker "$STATE" "$SOL_SPEC_FOR")
  if ! fm_second_attempt_meta_had_implementation "$TARGET_META" && [ ! -e "$TARGET_MARKER" ]; then
    echo "error: ship task $SOL_SPEC_FOR is not gated - it records no implementation attempt and no no-mistakes fix round - so it needs no installed Sol spec" >&2
    exit 1
  fi
  TARGET_SPEC=$(fm_second_attempt_spec_path "$DATA" "$SOL_SPEC_FOR")
  if [ -e "$TARGET_SPEC" ] || [ -L "$TARGET_SPEC" ]; then
    if [ -f "$TARGET_SPEC" ] && [ ! -L "$TARGET_SPEC" ] && cmp -s "$SOURCE_SPEC" "$TARGET_SPEC"; then
      echo "Sol spec for $SOL_SPEC_FOR already installed at $TARGET_SPEC from scout $ID (unchanged)"
      echo "next: FM_HOME=$HOME_Q bin/fm-control.sh $SOL_SPEC_FOR relaunch --note '<progress so far>'"
      exit 0
    fi
    echo "error: $SOL_SPEC_FOR already has a different Sol spec at $TARGET_SPEC; a reviewed artifact is never overwritten - retire it deliberately first" >&2
    exit 1
  fi
  mkdir -p "$DATA/$SOL_SPEC_FOR" || { echo "error: could not create $DATA/$SOL_SPEC_FOR" >&2; exit 1; }
  TMP="$DATA/$SOL_SPEC_FOR/.spec.md.install.${BASHPID:-$$}"
  cat "$SOURCE_SPEC" > "$TMP" || { echo "error: could not stage the Sol spec at $TMP" >&2; exit 1; }
  mv "$TMP" "$TARGET_SPEC" || { echo "error: could not install the Sol spec at $TARGET_SPEC" >&2; exit 1; }
  TMP=
  fm_scout_deliverable_declare "$DATA" "$SOL_SPEC_FOR" spec.md || {
    echo "error: installed $TARGET_SPEC but could not declare it as $SOL_SPEC_FOR's artifact" >&2
    exit 1
  }
  echo "installed Sol spec for $SOL_SPEC_FOR at $TARGET_SPEC from scout $ID"
  echo "$ID stays a scout and is torn down normally; $SOL_SPEC_FOR keeps its worktree, branch, commits, and PR"
  echo "next: FM_HOME=$HOME_Q bin/fm-control.sh $SOL_SPEC_FOR relaunch --note '<progress so far>'"
  exit 0
fi

META_LOCK=$(fm_meta_lock_path "$META") || exit 1
fm_lock_acquire_wait "$META_LOCK"
META_LOCK_HELD=1
[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
grep -qx 'kind=scout' "$META" || { echo "error: task $ID is not a scout task (kind=scout not in meta)" >&2; exit 1; }

TMP="$STATE/.$ID.meta.promote.${BASHPID:-$$}"
grep -v -e '^kind=' -e '^mode=' -e '^yolo=' "$META" > "$TMP"
{
  echo "kind=ship"
  echo "mode=$MODE"
  echo "yolo=$YOLO"
} >> "$TMP"
mv "$TMP" "$META"
TMP=
fm_lock_release "$META_LOCK"
META_LOCK_HELD=0

echo "promoted $ID to ship mode=$MODE yolo=$YOLO (teardown protection restored)"
echo "next: FM_HOME=$HOME_Q bin/fm-send.sh fm-$ID '<ship instructions for mode=$MODE: review scratch state with git status and git log; reset to a clean default-branch base; carry over only intended fix changes; create branch fm/$ID; implement; report done>'"

promote_print_rechain_hint() {
  local consent_home=$1 work_home=$2 task_id=$3 id prefix
  prefix=
  [ "$consent_home" = "$FM_HOME" ] || prefix="FM_HOME=$(printf '%q' "$consent_home") "
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    [ "$(fm_pf_registry_get "$consent_home/state" "$id" state)" = delivered ] || continue
    echo "next: ${prefix}bin/fm-public-followup.sh rechain <new-obligation-id> --from $id --work-home $work_home --work-id $task_id --expected pr-merged"
  done <<EOF
$(fm_pf_registry_ids_for_work "$consent_home/state" "$work_home" "$task_id")
EOF
}

promote_canonical_home() {
  local home=$1
  case "$home" in /*) ;; *) return 1 ;; esac
  CDPATH='' cd -- "$home" 2>/dev/null && pwd -P
}

promote_resolve_primary_home() {
  local parent=$1 child=$2 mate_id=$3 parent_meta registry meta_home
  fm_pf_home_id_valid "secondmate:$mate_id" || return 1
  parent=$(promote_canonical_home "$parent") || return 1
  child=$(promote_canonical_home "$child") || return 1
  [ "$parent" != "$child" ] || return 1
  parent_meta="$parent/state/$mate_id.meta"
  [ -f "$parent_meta" ] && [ ! -L "$parent_meta" ] || return 1
  [ "$(fmx_meta_get "$parent_meta" kind)" = secondmate ] || return 1
  meta_home=$(fmx_meta_get "$parent_meta" home)
  meta_home=$(CDPATH='' cd -- "$meta_home" 2>/dev/null && pwd -P) || return 1
  [ "$meta_home" = "$child" ] || return 1
  registry="$parent/data/secondmates.md"
  secondmate_registry_validate_bindings "$registry" secondmate_registry_path_key \
    "$mate_id" "$child" || return 1
  printf '%s\n' "$parent"
}

promote_warn_parent_unresolved() {
  echo "warning: could not resolve the consent-holding parent home for secondmate $1; promotion succeeded, but any open public loop must be inspected and rechained from the parent." >&2
}

if [ -f "$FM_HOME/.fm-secondmate-home" ]; then
  PROMOTE_MATE_ID=$(sed -n '1p' "$FM_HOME/.fm-secondmate-home" 2>/dev/null || true)
  PROMOTE_PARENT_RECORD=absent
  PROMOTE_PARENT_ROUTE=
  PROMOTE_DURABLE_PARENT=
  if [ -e "$FM_HOME/.fm-secondmate-parent" ] || [ -L "$FM_HOME/.fm-secondmate-parent" ]; then
    PROMOTE_PARENT_RECORD=invalid
    if fm_secondmate_parent_record_parse "$FM_HOME/.fm-secondmate-parent"; then
      PROMOTE_PARENT_RECORD=valid
      PROMOTE_PARENT_ROUTE=$FM_SECONDMATE_PARENT_ROUTE
      PROMOTE_DURABLE_PARENT=$FM_SECONDMATE_PARENT_HOME
    fi
  fi
  if [ "$PROMOTE_PARENT_RECORD" = invalid ]; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  elif [ "$PROMOTE_PARENT_ROUTE" = local ]; then
    PROMOTE_PARENT_CANDIDATE=${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-$PROMOTE_DURABLE_PARENT}
    PROMOTE_PARENT_BINDINGS_MATCH=1
    if [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
      PROMOTE_LIVE_PARENT=$(promote_canonical_home "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      PROMOTE_RECORDED_PARENT=$(promote_canonical_home "$PROMOTE_DURABLE_PARENT") \
        || PROMOTE_PARENT_BINDINGS_MATCH=0
      if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
          && [ "$PROMOTE_LIVE_PARENT" != "$PROMOTE_RECORDED_PARENT" ]; then
        PROMOTE_PARENT_BINDINGS_MATCH=0
      fi
    fi
    if [ "$PROMOTE_PARENT_BINDINGS_MATCH" = 1 ] \
        && PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$PROMOTE_PARENT_CANDIDATE" "$FM_HOME" "$PROMOTE_MATE_ID"); then
      if fm_pf_relay_active "$PROMOTE_PARENT"; then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      fi
    else
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ "$PROMOTE_PARENT_ROUTE" = remote ]; then
    PROMOTE_HOME_ENV_TOKEN=
    if [ -f "$FM_HOME/.env" ]; then
      PROMOTE_HOME_ENV_TOKEN=$(fmx_env_get FMX_PAIRING_TOKEN "$FM_HOME/.env")
    fi
    if [ -n "$PROMOTE_HOME_ENV_TOKEN" ]; then
      promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
    fi
  elif [ -n "${FM_PUBLIC_FOLLOWUP_PRIMARY_HOME:-}" ]; then
    if fm_pf_relay_active "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME"; then
      if PROMOTE_PARENT=$(promote_resolve_primary_home \
          "$FM_PUBLIC_FOLLOWUP_PRIMARY_HOME" "$FM_HOME" "$PROMOTE_MATE_ID"); then
        promote_print_rechain_hint "$PROMOTE_PARENT" "secondmate:$PROMOTE_MATE_ID" "$ID"
      else
        promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
      fi
    fi
  elif fm_pf_relay_active "$FM_HOME"; then
    promote_warn_parent_unresolved "$PROMOTE_MATE_ID"
  fi
elif fm_pf_relay_active "$FM_HOME"; then
  promote_print_rechain_hint "$FM_HOME" main "$ID"
fi
