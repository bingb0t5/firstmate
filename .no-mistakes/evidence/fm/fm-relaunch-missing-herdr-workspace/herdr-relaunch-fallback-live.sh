#!/usr/bin/env bash
# Live Herdr relaunch fallback: real herdr server + real fm-spawn, stub harness only.
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29NT66VJN65T2D3YJHC249G"
EVID="/home/rich/.no-mistakes/evidence/01M29NT66VJN65T2D3YJHC249G"
LOG="$EVID/herdr-relaunch-fallback-live.log"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/herdr-relaunch-live.XXXXXX")
SESSION="fm-lab-relaunch-fallback-$$"

exec > >(tee "$LOG") 2>&1

cleanup() {
  rm -rf "$SCRATCH"
  # shellcheck source=/dev/null
  . "$ROOT/tests/herdr-test-safety.sh" 2>/dev/null || true
  herdr_safe_stop_and_delete "$SESSION" 2>/dev/null || true
}
trap cleanup EXIT

command -v herdr >/dev/null || { echo "FAIL: herdr not found"; exit 1; }
command -v jq >/dev/null || { echo "FAIL: jq not found"; exit 1; }

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"

herdr_forget_inherited_pane
export HERDR_SESSION="$SESSION"
fm_herdr_lab_prepare "$SESSION" || { echo "FAIL: lab prepare"; exit 1; }
fm_backend_source herdr || { echo "FAIL: backend source"; exit 1; }

TASK=hr-live
HOME_DIR="$SCRATCH/home"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
FAKE="$SCRATCH/fake"
FB="$SCRATCH/fakebin"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$TASK" "$FAKE"
fm_git_worktree "$PROJ" "$WT" "task-$TASK"
printf '# brief\n\nDo the thing.\n' > "$HOME_DIR/data/$TASK/brief.md"

# Create a real Herdr workspace + task tab, then delete the workspace.
CONTAINER_RAW=$(FM_HOME="$HOME_DIR" fm_backend_herdr_container_ensure "$PROJ" launcher-home) \
  || { echo "FAIL: container_ensure"; exit 1; }
CONTAINER=${CONTAINER_RAW%%$'\t'*}
SEEDED=${CONTAINER_RAW#*$'\t'}
OLD_WS=${CONTAINER#*:}
TASK_IDS=$(FM_HOME="$HOME_DIR" fm_backend_herdr_create_task "$CONTAINER" "fm-$TASK" "$PROJ" "$SEEDED") \
  || { echo "FAIL: create_task"; exit 1; }
read -r OLD_TAB OLD_PANE <<EOF
$TASK_IDS
EOF
echo "Created workspace=$OLD_WS tab=$OLD_TAB pane=$OLD_PANE container=$CONTAINER"

# Delete the workspace so presence becomes dead while meta still references it.
fm_herdr_lab_cli "$SESSION" workspace close "$OLD_WS" >/dev/null \
  || { echo "FAIL: workspace close"; exit 1; }
PRESENCE=$(fm_backend_herdr_workspace_presence_state "$SESSION" "$OLD_WS")
echo "Workspace presence after delete: $PRESENCE"
[ "$PRESENCE" = dead ] || { echo "FAIL: expected dead presence, got $PRESENCE"; exit 1; }

{
  echo "window=$SESSION:$OLD_PANE"
  echo "endpoint_task_id=$TASK"
  echo "worktree=$WT"
  echo "project=$PROJ"
  echo "harness=claude"
  echo "kind=ship"
  echo "mode=no-mistakes"
  echo "yolo=off"
  echo "tasktmp=/tmp/fm-$TASK"
  echo "model=default"
  echo "effort=default"
  echo "backend=herdr"
  echo "herdr_session=$SESSION"
  echo "herdr_workspace_id=$OLD_WS"
  echo "herdr_tab_id=$OLD_TAB"
  echo "herdr_pane_id=$OLD_PANE"
} > "$HOME_DIR/state/$TASK.meta"

# Minimal tmux stub for harness launch; real herdr stays on PATH.
mkdir -p "$FB"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift; literal=0
    while [ $# -gt 0 ]; do case "$1" in -t) shift 2 ;; -l) literal=1; shift ;; *) break ;; esac; done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      case "$payload" in *'encode launch-brief'*) printf 'zsh\n' > "$D/command" ;; esac
    else
      case "$payload" in cd\ *) path=${payload#cd }; path=${path#\'}; path=${path%\'}; printf '%s\n' "$path" > "$D/cwd" ;; esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) printf '%s\n' "$(cat "$D/cwd")"; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  has-session) exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/tmux"
printf 'zsh\n' > "$FAKE/command"
printf '%s\n' "$WT" > "$FAKE/cwd"

OUT=$(env PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$FAKE" FM_SPAWN_NO_GUARD=1 \
  HERDR_SESSION="$SESSION" HERDR_ENV= HERDR_PANE_ID= HERDR_TAB_ID= HERDR_WORKSPACE_ID= \
  "$ROOT/bin/fm-spawn.sh" "$TASK" --relaunch --harness claude 2>&1) || RC=$?
RC=${RC:-0}
echo "--- fm-spawn output ---"
printf '%s\n' "$OUT"
echo "--- end output ---"

[ "$RC" -eq 0 ] || { echo "FAIL: fm-spawn exit $RC"; exit 1; }

NEW_WT=$(grep '^worktree=' "$HOME_DIR/state/$TASK.meta" | tail -1 | cut -d= -f2-)
NEW_WS=$(grep '^herdr_workspace_id=' "$HOME_DIR/state/$TASK.meta" | tail -1 | cut -d= -f2-)
NEW_PANE=$(grep '^herdr_pane_id=' "$HOME_DIR/state/$TASK.meta" | tail -1 | cut -d= -f2-)
echo "After relaunch: worktree=$NEW_WT workspace=$NEW_WS pane=$NEW_PANE"

[ "$NEW_WT" = "$WT" ] || { echo "FAIL: worktree changed"; exit 1; }
[ "$NEW_WS" != "$OLD_WS" ] || { echo "FAIL: workspace not replaced"; exit 1; }
[ -n "$NEW_PANE" ] || { echo "FAIL: no new pane id"; exit 1; }
grep -Fq "missing Herdr workspace $OLD_WS with $NEW_WS" "$HOME_DIR/state/$TASK.status" \
  || { echo "FAIL: fallback status line missing"; cat "$HOME_DIR/state/$TASK.status"; exit 1; }

echo "PASS: live Herdr relaunch fallback succeeded"
exit 0
