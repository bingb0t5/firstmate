#!/usr/bin/env bash
# Recover custody of a branch after a terminal no-mistakes run.
#
# Usage: fm-nm-recover.sh
#
# This is a narrow worker-facing wrapper around the no-mistakes recovery command.
# It reads the current structured `axi status` response and invokes
# `no-mistakes axi sync --recover` only when branch_sync.next_action.code is the
# exact supported `recover_custody` action.
#
# A clean worktree is required before recovery so unlanded changes cannot be
# discarded by a branch synchronization. Unsupported, missing, or ambiguous
# status refuses with the next read-only command instead of leaving the worker
# to improvise reset, merge, rebase, force, stash, or discard operations.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"

fm_refuse_if_gate_agent .

usage() {
  cat <<'EOF'
Usage: fm-nm-recover.sh

Read the current structured `no-mistakes axi status` response and apply the
supported custody recovery only when branch_sync.next_action.code is exactly
recover_custody. Refuses dirty, detached, unsupported, or ambiguous states
without changing files or refs.
EOF
}

die() {
  echo "REFUSED: $*" >&2
  exit 2
}

case "${1:-}" in
  '') ;;
  -h|--help) usage; exit 0 ;;
  *) die "usage is fm-nm-recover.sh; no options are accepted" ;;
esac

REPO=$(git rev-parse --show-toplevel 2>/dev/null) \
  || die "the current directory is not a git repository; run no-mistakes axi status there and preserve the branch"
cd "$REPO"

BRANCH=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
[ -n "$BRANCH" ] \
  || die "the repository is detached; run no-mistakes axi status and preserve the exact branch before any follow-up"

DIRTY=$(git status --porcelain=v1 --untracked-files=all 2>/dev/null || true)
[ -z "$DIRTY" ] \
  || die "unlanded work is present on $BRANCH; commit it or inspect it before recovery, and do not reset or discard it (no files or refs were changed)"

STATUS_FILE=$(mktemp "${TMPDIR:-/tmp}/fm-nm-recover.XXXXXX")
# shellcheck disable=SC2329 # Registered by the EXIT, INT, and TERM traps.
cleanup() {
  rm -f "$STATUS_FILE"
}
trap cleanup EXIT INT TERM

STATUS_TIMEOUT=${FM_NM_RECOVER_STATUS_TIMEOUT:-10}
case "$STATUS_TIMEOUT" in
  ''|*[!0-9]*) STATUS_TIMEOUT=10 ;;
esac

set +e
fm_nm_run_bounded "$REPO" "$STATUS_TIMEOUT" axi status >"$STATUS_FILE" 2>&1
STATUS_RC=$?
set -e

# Preserve the structured response in every refusal. It is the evidence the
# worker should return to firstmate when no supported transition is offered.
print_status() {
  if [ -s "$STATUS_FILE" ]; then
    cat "$STATUS_FILE"
  else
    echo "(no structured status response)"
  fi
}

if [ "$STATUS_RC" -ne 0 ]; then
  print_status
  die "structured status could not be confirmed (exit $STATUS_RC); rerun no-mistakes axi status and return its branch_sync object to firstmate"
fi

branch_sync_state() {
  awk '
    /^branch_sync:[[:space:]]*$/ { in_branch=1; next }
    in_branch && /^[^[:space:]]/ { exit }
    in_branch && /^  state:[[:space:]]*/ {
      value=$0
      sub(/^  state:[[:space:]]*/, "", value)
      print value
      exit
    }
  ' "$STATUS_FILE"
}

next_action_code() {
  awk '
    /^branch_sync:[[:space:]]*$/ { in_branch=1; next }
    in_branch && /^[^[:space:]]/ { exit }
    in_branch && /^  next_action:[[:space:]]*$/ { in_action=1; next }
    in_action && /^[^[:space:]]/ { exit }
    in_action && /^    code:[[:space:]]*/ {
      value=$0
      sub(/^    code:[[:space:]]*/, "", value)
      print value
      exit
    }
  ' "$STATUS_FILE"
}

STATE=$(fm_nm_strip_quotes "$(branch_sync_state)")
ACTION=$(fm_nm_strip_quotes "$(next_action_code)")

if [ "$ACTION" = recover_custody ]; then
  echo "Applying the guarded no-mistakes custody recovery for $BRANCH."
  no-mistakes axi sync --recover
  exit $?
fi

if [ "$STATE" = user_owned ]; then
  echo "No custody recovery is needed: structured status says $BRANCH is already user-owned."
  exit 0
fi

print_status
if [ -z "$ACTION" ]; then
  die "structured status did not offer a branch_sync.next_action.code; rerun no-mistakes axi status and return its branch_sync object to firstmate"
fi

die "branch_sync.next_action.code=$ACTION does not offer custody recovery; rerun no-mistakes axi status, follow its help for that state, leave the branch unchanged, and return the status to firstmate"
