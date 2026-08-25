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
  local dir=$1 id=$2
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
    echo "kind=ship"
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
  assert_contains "$out" "no Sol spec" "relaunch refusal did not name the missing spec"
  assert_contains "$out" "commission a Sol spec scout" "relaunch refusal did not name the next legal action"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "relaunch refusal stopped the running agent"
  [ -z "$(cat "$dir/fake/literal")" ] || fail "relaunch refusal sent lifecycle input"
  pass "fm-control: relaunch refuses without a Sol spec and does not replace the agent"
}

test_control_relaunch_proceeds_once_report_md_exists() {
  local dir out rc
  dir=$(new_case relaunch-allow sa2)
  add_ship_task "$dir" sa2
  mkdir -p "$dir/home/data/sa2"
  printf '# Sol spec\n\nShip it.\n' > "$dir/home/data/sa2/report.md"
  out=$(run_control "$dir" sa2 relaunch --note "continue with spec"); rc=$?
  expect_code 0 "$rc" "relaunch with a spec should succeed"$'\n'"$out"
  assert_contains "$out" "relaunched sa2" "relaunch with a spec did not complete"
  pass "fm-control: relaunch proceeds once data/<id>/report.md exists"
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

test_secondmate_spawn_is_unaffected_by_the_gate() {
  local home fakebin out status smhome
  home="$TMP_ROOT/secondmate/home"
  smhome="$TMP_ROOT/secondmate/smhome"
  fakebin="$TMP_ROOT/secondmate/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$fakebin"
  mkdir -p "$smhome/bin" "$smhome/data"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  printf 'secondmate marker\n' > "$smhome/AGENTS.md"
  mkdir -p "$smhome/bin"
  printf '# charter\n' > "$smhome/data/charter.md"
  printf '.fm-secondmate-home\n' > "$smhome/.fm-secondmate-home" 2>/dev/null || true
  echo "sm-gate" > "$smhome/.fm-secondmate-home"
  {
    echo "window=fmses:fm-sm-gate"
    echo "endpoint_task_id=sm-gate"
    echo "worktree=$smhome"
    echo "harness=claude"
    echo "kind=secondmate"
    echo "home=$smhome"
    echo "spawn_gen=s1.prior"
  } > "$home/state/sm-gate.meta"
  out=$(FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" sm-gate "$smhome" --secondmate 2>&1)
  status=$?
  assert_not_contains "$out" "Sol spec" "secondmate spawn was blocked by the ship second-attempt gate"
  [ "$status" -ne 0 ] || fail "secondmate spawn should still fail only at the fake backend, not the Sol gate"
  pass "fm-spawn: --secondmate launch is unaffected by the second-attempt gate"
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
  printf '# spec\n' > "$home/data/task-nm/report.md"
  fm_second_attempt_refuse_if_needed "$home/state" "$home/data" task-nm "$meta" relaunch \
    || fail "marker gate should clear once report.md exists"
  pass "fm-second-attempt-lib: third fix-round marker refuses until a spec exists"
}

test_first_ship_spawn_is_not_blocked_without_a_spec
test_control_relaunch_refuses_without_a_spec_and_leaves_the_agent
test_control_relaunch_proceeds_once_report_md_exists
test_spawn_relaunch_refuses_without_a_spec
test_secondmate_spawn_is_unaffected_by_the_gate
test_nm_third_fix_round_marker_refuses_without_a_spec
echo "# all fm-second-attempt tests passed"
