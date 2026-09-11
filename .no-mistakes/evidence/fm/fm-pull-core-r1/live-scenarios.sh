#!/usr/bin/env bash
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M27QXWPS5380C600P58RS94J"
EVID="/home/rich/.no-mistakes/evidence/01M27QXWPS5380C600P58RS94J"
# shellcheck source=/dev/null
. "$ROOT/tests/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/tests/secondmate-helpers.sh"

log_scenario() {
  local name=$1 out rc
  out="$EVID/scenario-${name}.log"
  shift
  {
    echo "=== SCENARIO: $name ==="
    echo "=== $(date -Iseconds) ==="
    "$@"
    rc=$?
    echo "=== EXIT: $rc ==="
  } >"$out" 2>&1
}

setup_handoff_homes() {
  local tag=$1
  local home sub
  home=$(fm_test_tmproot "live-${tag}-main")
  sub=$(fm_test_tmproot "live-${tag}-sub")
  mkdir -p "$home/data" "$home/state" "$sub/data" "$sub/state"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml" "$sub/.tasks.toml"
  seed_secondmate_home_marker "$sub" design
  sub=$(cd "$sub" && pwd -P)
  printf -- '- design - feature work (home: %s; scope: feature work; projects: alpha; added 2026-07-09)\n' "$sub" >"$home/data/secondmates.md"
  cat >"$home/state/design.meta" <<EOF
window=firstmate:fm-design
kind=secondmate
harness=claude
backend=tmux
home=$sub
worktree=$sub
EOF
  printf '## Queued\n\n## Done\n' >"$sub/data/backlog.md"
  printf '%s %s\n' "$home" "$sub"
}

# untyped reservation cap
home=$(fm_test_tmproot live-untyped)
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
cat >"$home/data/backlog.md" <<'EOF'
## In flight
- [ ] reservation-1 - reserved (kind: ship) (priority: 1)
- [ ] reservation-2 - reserved (kind: ship) (priority: 1)
- [ ] reservation-3 - reserved (kind: ship) (priority: 1)
- [ ] untyped-reservation - reserved without kind metadata (priority: 1)
## Queued
## Done
EOF
mkdir -p "$home/data/fifth" && echo '# brief' >"$home/data/fifth/brief.md"
( cd "$home" && tasks-axi add fifth "fifth title" --kind ship --repo demo --priority 1 >/dev/null )
log_scenario untyped-cap env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start fifth "$ROOT" --mode no-mistakes --yolo off --harness pi --backend tmux || true

# same-id retry
home=$(fm_test_tmproot live-retry)
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
cat >"$home/data/backlog.md" <<'EOF'
## In flight
- [ ] reservation-1 - reserved (kind: ship) (priority: 1)
- [ ] reservation-2 - reserved (kind: ship) (priority: 1)
- [ ] reservation-3 - reserved (kind: ship) (priority: 1)
## Queued
## Done
EOF
mkdir -p "$home/data/retry-task" && echo '# brief' >"$home/data/retry-task/brief.md"
( cd "$home" && tasks-axi add retry-task "retry title" --kind ship --repo demo --priority 1 >/dev/null )
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start retry-task "$home/missing-project" --mode no-mistakes --yolo off --harness pi --backend tmux >"$EVID/scenario-retry-1.log" 2>&1 || true
log_scenario retry-resume env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start retry-task "$home/missing-project" --mode no-mistakes --yolo off --harness pi --backend tmux || true

# partial inventory
home=$(fm_test_tmproot live-partial)
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects/visible"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
cat >"$home/data/backlog.md" <<'EOF'
## In flight
- [ ] visible-ship - Structured with meta (repo: alpha) (kind: ship) (since 2026-07-11)
## Queued
## Done
EOF
fm_write_meta "$home/state/visible-ship.meta" \
  "window=firstmate:fm-visible-ship" "worktree=$home/projects/visible" \
  "project=alpha" "harness=codex" "kind=ship" "mode=ship"
echo 'working: visible' >"$home/state/visible-ship.status"
ln -s "$home/state/missing-target" "$home/state/broken.meta"
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --secondmate-home-summary >"$EVID/scenario-partial-summary.json" 2>&1
mkdir -p "$home/data/admit-task" && echo '# brief' >"$home/data/admit-task/brief.md"
( cd "$home" && tasks-axi add admit-task "admit" --kind ship --repo demo --priority 1 >/dev/null )
log_scenario partial-inventory-pull env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start admit-task "$ROOT" --mode no-mistakes --yolo off --harness pi --backend tmux || true

# spawn hard-four
home=$(fm_test_tmproot live-spawn-cap)
mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
cat >"$home/data/backlog.md" <<'EOF'
## In flight
- [ ] reservation-1 - reserved (kind: ship) (priority: 1)
- [ ] reservation-2 - reserved (kind: ship) (priority: 1)
- [ ] reservation-3 - reserved (kind: ship) (priority: 1)
- [ ] reservation-4 - reserved (kind: ship) (priority: 1)
## Queued
## Done
EOF
mkdir -p "$home/data/direct-cap" && echo '# brief' >"$home/data/direct-cap/brief.md"
log_scenario spawn-hard-four env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" direct-cap "$ROOT" --mode no-mistakes --yolo off --harness pi --backend tmux || true

read -r home sub < <(setup_handoff_homes handoff)
cat >"$home/data/backlog.md" <<'EOF'
## In flight
- [ ] live-blocker - active blocker (repo: alpha) (kind: ship) (priority: 2)
## Queued
- [ ] dep-task - routed work blocked-by: live-blocker (repo: alpha) (kind: ship) (priority: 1)
## Done
EOF
cp "$home/data/backlog.md" "$home/backlog.before"
log_scenario inflight-blocker-handoff env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-handoff.sh" design dep-task || true

read -r home sub < <(setup_handoff_homes conflict)
cat >"$home/data/backlog.md" <<'EOF'
## Queued
- [ ] conflict-item - dual priority (repo: alpha) (kind: ship) (priority: 2), priority: 9
## Done
EOF
log_scenario conflicting-priority-handoff env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-handoff.sh" design conflict-item || true

read -r home sub < <(setup_handoff_homes routed)
cat >"$home/data/backlog.md" <<'EOF'
## Queued
- [ ] routed-blocker - blocker already at destination (repo: alpha) (kind: ship) (priority: 2)
- [ ] routed-dependent - routed work blocked-by: routed-blocker (repo: alpha) (kind: ship) (priority: 1)
## Done
EOF
env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-handoff.sh" design routed-blocker >"$EVID/scenario-routed-blocker.log" 2>&1
log_scenario routed-dependent-handoff env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-handoff.sh" design routed-dependent || true

read -r home sub < <(setup_handoff_homes closure-priority)
cat >"$home/data/backlog.md" <<'EOF'
## Queued
- [ ] closure-blocker - missing migration priority (repo: alpha) (kind: ship)
- [ ] closure-dependent - routed work blocked-by: closure-blocker (repo: alpha) (kind: ship) (priority: 1)
## Done
EOF
log_scenario closure-priority-handoff env FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-backlog-handoff.sh" design closure-dependent || true

echo "ALL LIVE SCENARIOS COMPLETE"
