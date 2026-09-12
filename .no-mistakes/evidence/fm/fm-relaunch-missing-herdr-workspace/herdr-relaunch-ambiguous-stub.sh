#!/usr/bin/env bash
# Stub-driven: ambiguous workspace presence must refuse relaunch (fail closed).
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29NT66VJN65T2D3YJHC249G"
EVID="/home/rich/.no-mistakes/evidence/01M29NT66VJN65T2D3YJHC249G"
LOG="$EVID/herdr-relaunch-ambiguous-stub.log"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/herdr-relaunch-ambig.XXXXXX")

exec > >(tee "$LOG") 2>&1
trap 'rm -rf "$SCRATCH"' EXIT

# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"

TASK=hr-ambig
HOME_DIR="$SCRATCH/home"
PROJ="$SCRATCH/proj"
WT="$SCRATCH/wt"
FAKE="$SCRATCH/fake"
FB="$SCRATCH/fakebin"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$TASK" "$FAKE" "$FB"
fm_git_worktree "$PROJ" "$WT" "task-$TASK"
printf '# brief\n' > "$HOME_DIR/data/$TASK/brief.md"
printf 'zsh\n' > "$FAKE/command"
printf '%s\n' "$WT" > "$FAKE/cwd"

# tmux stub (minimal)
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
D=$FM_FAKE_DIR
case "${1:-}" in
  display-message)
    for a in "$@"; do
      case "$a" in *pane_current_command*) cat "$D/command"; exit 0 ;; *pane_current_path*) cat "$D/cwd"; exit 0 ;; esac
    done; exit 0 ;;
  has-session) exit 0 ;;
esac
exit 0
SH
chmod +x "$FB/tmux"

# herdr stub: duplicate workspace ids -> unknown presence
cat > "$FB/herdr" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "status --json") printf '{"client":{"version":"0.7.1","protocol":14},"server":{"running":true}}' ;;
  "workspace list") printf '{"result":{"workspaces":[{"workspace_id":"w1"},{"workspace_id":"w1"}]}}' ;;
  "pane get")
    case "${3:-}" in w1:p1) printf '{"error":{"code":"pane_not_found"}}'; exit 1 ;; esac ;;
  *) ;;
esac
SH
chmod +x "$FB/herdr"

{
  echo "window=fake-session:w1:p1"
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
  echo "herdr_session=fake-session"
  echo "herdr_workspace_id=w1"
  echo "herdr_tab_id=w1:t1"
  echo "herdr_pane_id=w1:p1"
} > "$HOME_DIR/state/$TASK.meta"

OUT=$(env PATH="$FB:$PATH" FM_HOME="$HOME_DIR" FM_FAKE_DIR="$FAKE" FM_SPAWN_NO_GUARD=1 \
  HERDR_SESSION=fake-session HERDR_ENV= HERDR_PANE_ID= HERDR_TAB_ID= HERDR_WORKSPACE_ID= \
  "$ROOT/bin/fm-spawn.sh" "$TASK" --relaunch --harness claude 2>&1) || RC=$?
RC=${RC:-0}
echo "$OUT"
[ "$RC" -ne 0 ] || { echo "FAIL: expected refusal"; exit 1; }
echo "$OUT" | grep -Fq "could not be inspected in its recorded Herdr workspace" \
  || { echo "FAIL: wrong error message"; exit 1; }
echo "PASS: ambiguous workspace presence refused relaunch"
exit 0
