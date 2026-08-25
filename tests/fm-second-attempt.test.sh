#!/usr/bin/env bash
# Mechanical second-attempt Sol-spec gate across fm-spawn.sh and fm-control.sh.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-second-attempt-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-control-lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
CONTROL="$ROOT/bin/fm-control.sh"
TMP_ROOT=$(fm_test_tmproot fm-second-attempt)

make_home() {
  local name=$1 home projects fakebin
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/proj" "$fakebin"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$home|$projects/proj|$fakebin"
}

write_brief() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    printf 'Delivery contract: mode=no-mistakes\n'
  } > "$home/data/$id/brief.md"
}

run_spawn() {
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

make_tmux_stub() {
  local fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  send-keys)
    shift
    literal=0
    while [ $# -gt 0 ]; do
      case "$1" in
        -t) shift 2 ;;
        -l) literal=1; shift ;;
        *) break ;;
      esac
    done
    payload=${1:-}
    if [ "$literal" = 1 ]; then
      printf '%s\n' "$payload" >> "$D/literal"
      case "$payload" in
        /exit|/quit)
          printf 'zsh' > "$D/command"
          ;;
        *'encode launch-brief'*)
          cat "$D/becomes" > "$D/command"
          ;;
      esac
    fi
    exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
      esac
    done
    printf 'fakepane\n'; exit 0 ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  cat > "$fb/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fb/sleep"
}

add_ship_task() {
  local dir=$1 id=$2 kind=${3:-ship}
  local home="$dir/home" proj="$dir/proj" wt="$dir/wt"
  fm_git_worktree "$proj" "$wt" "task-$id"
  mkdir -p "$home/data/$id"
  write_brief "$home" "$id"
  {
    echo "window=fmses:fm-$id"
    echo "endpoint_task_id=$id"
    echo "worktree=$wt"
    echo "project=$proj"
    echo "harness=claude"
    echo "kind=$kind"
    [ "$kind" = secondmate ] && echo "home=$wt"
    echo "mode=no-mistakes"
    echo "yolo=off"
    echo "tasktmp=/tmp/fm-$id"
    echo "model=default"
    echo "effort=default"
    echo "spawn_gen=s1.fixture"
  } > "$home/state/$id.meta"
  printf '%s\n' "fm-$id" > "$dir/fake/windows"
  printf '%s' "$wt" > "$dir/fake/cwd"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
}

run_control() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 \
    FM_CONTROL_POLL=0.01 FM_CONTROL_EXIT_WAIT=0.05 FM_CONTROL_LAUNCH_WAIT=0.05 \
    "$CONTROL" "$@" 2>&1
}

run_spawn_case() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" FM_FAKE_DIR="$dir/fake" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux \
    "$SPAWN" "$@" 2>&1
}

new_case() {
  local id=${2:-t1} dir="$TMP_ROOT/$1-$RANDOM"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/fake"
  : > "$dir/fake/literal"
  printf 'claude' > "$dir/fake/command"
  printf 'claude' > "$dir/fake/becomes"
  make_tmux_stub "$dir"
  printf '%s\n' "$dir"
}

test_first_ship_spawn_is_not_blocked_without_a_spec() {
  local rec home proj fakebin out
  rec=$(make_home first-spawn)
  IFS='|' read -r home proj fakebin <<EOF
$rec
EOF
  write_brief "$home" ship-a1
  out=$(run_spawn "$home" "$fakebin" ship-a1 "$proj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "Sol spec" "first ship spawn was blocked by the second-attempt gate"
  assert_not_contains "$out" "second-attempt" "first ship spawn mentioned the second-attempt gate"
  pass "fm-spawn: first ship spawn is not blocked without a Sol spec"
}

test_control_relaunch_refuses_without_a_spec_and_leaves_the_agent() {
  local dir out rc
  dir=$(new_case relaunch-refuse sa1)
  add_ship_task "$dir" sa1
  out=$(run_control "$dir" sa1 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "relaunch without a spec should refuse"
  assert_contains "$out" "no Sol spec at $dir/home/data/sa1/spec.md" \
    "relaunch refusal did not name the owned spec path"
  assert_contains "$out" "commission a Sol spec scout" "relaunch refusal did not name the next legal action"
  assert_contains "$out" "copy its report to $dir/home/data/sa1/spec.md" \
    "relaunch refusal did not name a next action that can clear the gate"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "relaunch refusal stopped the running agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "relaunch refusal sent lifecycle input"
  pass "fm-control: relaunch refuses without a Sol spec and does not replace the agent"
}

test_control_relaunch_proceeds_once_spec_md_exists() {
  local dir out rc
  dir=$(new_case relaunch-allow sa2)
  add_ship_task "$dir" sa2
  mkdir -p "$dir/home/data/sa2"
  printf '# Sol spec\n\nShip it.\n' > "$dir/home/data/sa2/spec.md"
  out=$(run_control "$dir" sa2 relaunch --note "continue with spec"); rc=$?
  expect_code 0 "$rc" "relaunch with a spec should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched sa2" "relaunch with a spec did not complete"
  pass "fm-control: relaunch proceeds once data/<id>/spec.md exists"
}

# A scout deliverable at data/<id>/report.md predates the first implementation
# worker on the scout+promote path (bin/fm-promote.sh flips kind= in place), so
# it must not clear the gate for the promoted ship's second worker.
test_promoted_scout_report_does_not_clear_the_gate() {
  local dir out rc
  dir=$(new_case relaunch-promoted sa5)
  add_ship_task "$dir" sa5
  mkdir -p "$dir/home/data/sa5"
  printf '# scout findings\n\nInvestigation only.\n' > "$dir/home/data/sa5/report.md"
  out=$(run_control "$dir" sa5 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "a pre-implementation scout report should not clear the gate"
  assert_contains "$out" "no Sol spec at $dir/home/data/sa5/spec.md" \
    "promoted-scout relaunch refusal did not name the owned spec path"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "relaunch refusal stopped the running agent"
  pass "fm-control: a pre-implementation data/<id>/report.md does not satisfy the gate"
}

test_spawn_relaunch_refuses_without_a_spec() {
  local dir out rc
  dir=$(new_case spawn-relaunch-refuse sa3)
  add_ship_task "$dir" sa3
  out=$(run_spawn_case "$dir" sa3 --relaunch); rc=$?
  expect_code 1 "$rc" "replacement spawn should refuse without a spec"
  assert_contains "$out" "replacement spawn" "spawn relaunch did not identify itself as a replacement spawn"
  assert_contains "$out" "commission a Sol spec scout" "spawn relaunch did not name the next legal action"
  pass "fm-spawn: --relaunch refuses without a Sol spec"
}

# Same fixture as test_spawn_relaunch_refuses_without_a_spec, differing only in
# kind=, so reaching the later agent-free refusal proves the gate was executed
# and exempted this task rather than never being consulted.
test_secondmate_relaunch_is_unaffected_by_the_gate() {
  local dir out rc
  dir=$(new_case secondmate-relaunch sa4)
  add_ship_task "$dir" sa4 secondmate
  out=$(run_spawn_case "$dir" sa4 --relaunch); rc=$?
  expect_code 1 "$rc" "the fake endpoint should still refuse the secondmate relaunch"
  assert_not_contains "$out" "Sol spec" "secondmate relaunch was blocked by the ship second-attempt gate"
  assert_contains "$out" "positively agent-free" \
    "secondmate relaunch never reached the gate, so the exemption is untested"
  pass "fm-spawn: a secondmate relaunch is exempt from the second-attempt gate"
}

# Trigger 3 through a real executable: the marker outranks the plain relaunch
# reason, so the refusal must name fix round 3.
test_nm_third_fix_round_marker_refuses_through_fm_control() {
  local dir out rc
  dir=$(new_case nm-round-control sa6)
  add_ship_task "$dir" sa6
  printf '3\n' > "$dir/home/state/sa6.nm-third-fix-round"
  out=$(run_control "$dir" sa6 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "a recorded third fix round should refuse the relaunch"
  assert_contains "$out" "fix round 3" "fm-control refusal did not name the third fix round"
  assert_contains "$out" "Sol spec at $dir/home/data/sa6/spec.md" \
    "fm-control marker refusal did not name the owned spec path"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "marker refusal stopped the running agent"
  pass "fm-control: a recorded third fix round refuses the relaunch by name"
}

test_nm_third_fix_round_marker_refuses_without_a_spec() {
  local home meta out rc marker
  home="$TMP_ROOT/nm-fix/home"
  mkdir -p "$home/data/task-nm/state"
  meta="$home/state/task-nm.meta"
  mkdir -p "$home/state"
  {
    echo "kind=ship"
    echo "spawn_gen=s1.nm"
  } > "$meta"
  marker=$(fm_second_attempt_nm_third_fix_round_marker "$home/state" task-nm)
  printf '3\n' > "$marker"
  set +e
  fm_second_attempt_refuse_if_needed "$home/state" "$home/data" task-nm "$meta" relaunch >"$home/out" 2>"$home/err"
  rc=$?
  set -e
  expect_code 1 "$rc" "third fix-round marker should refuse without a spec"
  out=$(cat "$home/err")
  assert_contains "$out" "fix round 3" "marker refusal did not name the third fix round"
  assert_contains "$out" "commission a Sol spec scout" "marker refusal did not name the next legal action"
  printf '# spec\n' > "$home/data/task-nm/spec.md"
  fm_second_attempt_refuse_if_needed "$home/state" "$home/data" task-nm "$meta" relaunch \
    || fail "marker gate should clear once spec.md exists"
  pass "fm-second-attempt-lib: third fix-round marker refuses until a spec exists"
}

test_first_ship_spawn_is_not_blocked_without_a_spec
test_control_relaunch_refuses_without_a_spec_and_leaves_the_agent
test_control_relaunch_proceeds_once_spec_md_exists
test_promoted_scout_report_does_not_clear_the_gate
test_spawn_relaunch_refuses_without_a_spec
test_secondmate_relaunch_is_unaffected_by_the_gate
test_nm_third_fix_round_marker_refuses_through_fm_control
test_nm_third_fix_round_marker_refuses_without_a_spec
echo "# all fm-second-attempt tests passed"
