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
PROMOTE="$ROOT/bin/fm-promote.sh"
TMP_ROOT=$(fm_test_tmproot fm-second-attempt)
# A completed relaunch reaches bin/fm-spawn.sh's per-task scratch, which is a
# fixed /tmp/fm-<id> path outside this suite's root, so track and remove every
# one the fixtures can produce (same contract as tests/fm-control-relaunch.sh).
TASK_TMPS=()

second_attempt_cleanup() {
  local d
  for d in "${TASK_TMPS[@]:-}"; do
    [ -n "$d" ] && rm -rf "$d"
  done
  fm_test_cleanup
}
trap second_attempt_cleanup EXIT
trap 'second_attempt_cleanup; exit 130' INT
trap 'second_attempt_cleanup; exit 143' TERM

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
  TASK_TMPS+=("/tmp/fm-$id")
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

run_promote() {
  local dir=$1
  shift
  env PATH="$dir/fakebin:$PATH" FM_HOME="$dir/home" \
    FM_STATE_OVERRIDE="$dir/home/state" FM_DATA_OVERRIDE="$dir/home/data" \
    "$PROMOTE" "$@" 2>&1
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
    "relaunch refusal did not name the accepted spec path"
  assert_contains "$out" "commission a Sol spec scout under a fresh task id" \
    "relaunch refusal did not direct a fresh Sol spec scout task id"
  assert_contains "$out" "fm-promote.sh <new-scout-id> --sol-spec-for sa1" \
    "relaunch refusal did not name the artifact install that clears this task's gate"
  assert_contains "$out" "sa1 keeps its worktree, branch, commits, and PR" \
    "relaunch refusal did not say the gated task's work is preserved"
  assert_not_contains "$out" "fm-brief.sh sa1" \
    "relaunch refusal prescribed re-scaffolding the gated task id, which fm-brief.sh refuses"
  assert_contains "$out" "do not treat report.md as the spec" \
    "relaunch refusal did not reject the ordinary scout artifact"
  assert_contains "$out" "do not guess a model" \
    "relaunch refusal did not prohibit guessing the Sol scout model"
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

# A scout report can survive promotion, but only the task-owned spec artifact
# clears the implementation gate.
test_scout_report_does_not_clear_the_gate() {
  local dir out rc
  dir=$(new_case relaunch-promoted sa5)
  add_ship_task "$dir" sa5
  mkdir -p "$dir/home/data/sa5"
  printf '# Sol spec\n\nImplementation constraints.\n' > "$dir/home/data/sa5/report.md"
  out=$(run_control "$dir" sa5 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "a scout report must not clear the ship gate"
  assert_contains "$out" "no Sol spec at $dir/home/data/sa5/spec.md" \
    "relaunch with only report.md did not identify the required spec artifact"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "report-only refusal stopped the running agent"
  pass "fm-control: data/<id>/report.md does not satisfy the Sol-spec gate"
}

test_spawn_relaunch_refuses_without_a_spec() {
  local dir out rc
  dir=$(new_case spawn-relaunch-refuse sa3)
  add_ship_task "$dir" sa3
  out=$(run_spawn_case "$dir" sa3 --relaunch); rc=$?
  expect_code 1 "$rc" "replacement spawn should refuse without a spec"
  assert_contains "$out" "replacement spawn" "spawn relaunch did not identify itself as a replacement spawn"
  assert_contains "$out" "commission a Sol spec scout under a fresh task id" \
    "spawn relaunch refusal did not direct a fresh Sol spec scout task id"
  assert_contains "$out" "fm-promote.sh <new-scout-id> --sol-spec-for sa3" \
    "spawn relaunch refusal did not name the artifact install that clears this task's gate"
  assert_not_contains "$out" "fm-brief.sh sa3" \
    "spawn relaunch refusal prescribed re-scaffolding the gated task id"
  pass "fm-spawn: --relaunch refuses without a Sol spec"
}

test_scout_relaunch_is_ungated_after_an_existing_attempt() {
  local dir out rc
  dir=$(new_case scout-relaunch-refuse sa10)
  add_ship_task "$dir" sa10 scout
  out=$(run_control "$dir" sa10 relaunch --note "replace implementation attempt"); rc=$?
  expect_code 0 "$rc" "scout relaunch should remain ungated"$'\n'"$out"
  assert_contains "$out" "relaunched sa10" "ungated scout relaunch did not complete"
  assert_not_contains "$out" "Sol spec" "scout relaunch was blocked by the ship-only gate"
  pass "fm-control: scout relaunch after an existing attempt remains ungated"
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
  assert_contains "$out" "$dir/home/data/sa6/spec.md" \
    "fm-control marker refusal did not name the accepted spec path"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "marker refusal stopped the running agent"
  pass "fm-control: a recorded third fix round refuses the relaunch by name"
}

# The real lifecycle executable must derive the marker from the task's
# attributed no-mistakes run. A pre-created marker would only prove the
# consumer, not the automatic transition that the validation path requires.
test_nm_third_fix_round_is_recorded_automatically() {
  local dir wt branch head out rc marker
  dir=$(new_case nm-round-automatic sa11)
  add_ship_task "$dir" sa11
  wt="$dir/wt"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD)
  head=$(git -C "$wt" rev-parse --short HEAD)
  cat > "$dir/fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
cat <<'STATUS'
run:
  id: fixture-run
  branch: $branch
  status: fixing
  head: $head
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,fixing,1s,now,123,fix 3
STATUS
EOF
  chmod +x "$dir/fakebin/no-mistakes"
  marker="$dir/home/state/sa11.nm-third-fix-round"
  [ ! -e "$marker" ] || fail "automatic-round fixture unexpectedly started with a marker"
  out=$(run_control "$dir" sa11 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "an attributed third fix round should refuse the relaunch"
  assert_contains "$out" "fix round 3" \
    "automatic third-round refusal did not name the observed round"
  [ "$(cat "$marker")" = 3 ] || fail "automatic transition did not persist the observed third fix round"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "automatic third-round refusal stopped the running agent"
  pass "fm-control: an attributed no-mistakes third fix round is recorded and refuses automatically"
}

# The attributed status can list several concurrently fixing steps. The gate must
# attribute the highest qualifying round it observed, across every round label
# no-mistakes emits, rather than whichever row happens to come first.
test_nm_fix_round_attribution_takes_the_highest_active_round() {
  local dir wt branch head out rc marker
  dir=$(new_case nm-round-highest sa13)
  add_ship_task "$dir" sa13
  wt="$dir/wt"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD)
  head=$(git -C "$wt" rev-parse --short HEAD)
  cat > "$dir/fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
cat <<'STATUS'
run:
  id: fixture-run
  branch: $branch
  status: fixing
  head: $head
  active_steps[2]{step,status,active_for,last_activity,agent_pid,round}:
    review,fixing,1s,now,123,fix 1
    test,fixing,4s,now,124,auto-fix 4
STATUS
EOF
  chmod +x "$dir/fakebin/no-mistakes"
  marker="$dir/home/state/sa13.nm-third-fix-round"
  out=$(run_control "$dir" sa13 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "the highest attributed fix round should refuse the relaunch"
  [ "$(cat "$marker" 2>/dev/null)" = 4 ] \
    || fail "attribution did not record the highest active fix round"
  assert_contains "$out" "fix round 4" \
    "refusal did not name the highest observed fix round"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "highest-round refusal stopped the running agent"
  pass "fm-control: fix-round attribution takes the highest active round, not the first row"
}

# The round label comes from a producer outside this repo, so a value wider than
# the shell's integers must still be attributed rather than aborting `[ -ge ]`
# and silently reading as "below round 3".
test_nm_fix_round_attribution_survives_an_out_of_range_round() {
  local dir wt branch head out rc marker
  dir=$(new_case nm-round-huge sa14)
  add_ship_task "$dir" sa14
  wt="$dir/wt"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD)
  head=$(git -C "$wt" rev-parse --short HEAD)
  cat > "$dir/fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
cat <<'STATUS'
run:
  id: fixture-run
  branch: $branch
  status: fixing
  head: $head
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    test,fixing,4s,now,124,fix 99999999999999999999
STATUS
EOF
  chmod +x "$dir/fakebin/no-mistakes"
  marker="$dir/home/state/sa14.nm-third-fix-round"
  out=$(run_control "$dir" sa14 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "an out-of-range attributed fix round should still refuse"
  assert_not_contains "$out" "integer expression expected" \
    "an out-of-range round leaked a shell arithmetic error into the operator output"
  [ "$(cat "$marker" 2>/dev/null)" = 99999999999999999999 ] \
    || fail "an out-of-range fix round was not attributed at all"
  assert_contains "$out" "reached no-mistakes fix round 99999999999999999999" \
    "refusal did not report the out-of-range round it read"
  pass "fm-control: an out-of-range fix round is attributed instead of failing open"
}

# Scout lifecycle calls are exempt from the implementation gate itself, so an
# attributed validation status must not leave implementation-gate state behind.
test_nm_third_fix_round_does_not_mark_a_scout() {
  local dir wt branch head out rc marker
  dir=$(new_case nm-round-scout sa12)
  add_ship_task "$dir" sa12 scout
  wt="$dir/wt"
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD)
  head=$(git -C "$wt" rev-parse --short HEAD)
  cat > "$dir/fakebin/no-mistakes" <<EOF
#!/usr/bin/env bash
cat <<'STATUS'
run:
  id: fixture-run
  branch: $branch
  status: fixing
  head: $head
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    review,fixing,1s,now,123,fix 3
STATUS
EOF
  chmod +x "$dir/fakebin/no-mistakes"
  marker="$dir/home/state/sa12.nm-third-fix-round"
  out=$(run_control "$dir" sa12 relaunch --note "continue scouting"); rc=$?
  expect_code 0 "$rc" "an attributed third fix round must not gate a scout"$'\n'"$out"
  assert_not_contains "$out" "Sol spec" "scout relaunch was blocked by the implementation gate"
  [ ! -e "$marker" ] || fail "scout relaunch persisted ship-only third-round state"
  pass "fm-control: an attributed no-mistakes third fix round leaves scouts exempt"
}

# The no-mistakes side owns the marker payload, so a `touch`-style marker with
# no parseable round must still refuse rather than standing the gate down - and
# must report what it observed instead of asserting a round it never read.
test_nm_third_fix_round_marker_with_no_payload_refuses() {
  local dir out rc
  dir=$(new_case nm-round-empty sa7)
  add_ship_task "$dir" sa7
  : > "$dir/home/state/sa7.nm-third-fix-round"
  out=$(run_control "$dir" sa7 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "an unparseable third fix-round marker should refuse"
  assert_contains "$out" "$dir/home/state/sa7.nm-third-fix-round" \
    "unreadable marker refusal did not name the marker it read"
  assert_contains "$out" "could not be read" \
    "unreadable marker refusal did not say the round was unreadable"
  assert_not_contains "$out" "reached no-mistakes fix round 3" \
    "an unreadable marker was reported as a round the gate never read"
  [ "$(cat "$dir/fake/command")" = claude ] || fail "marker refusal stopped the running agent"
  pass "fm-control: an unreadable third fix-round marker refuses without claiming a round"
}

# A payload naming a round below the threshold is read, not guessed at, so it
# must not be reported as the unreadable case either.
test_nm_non_numeric_marker_payload_refuses_without_claiming_a_round() {
  local dir out rc
  dir=$(new_case nm-round-json sa9)
  add_ship_task "$dir" sa9
  printf '{"round": 1}\n' > "$dir/home/state/sa9.nm-third-fix-round"
  out=$(run_control "$dir" sa9 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "a non-numeric third fix-round marker should refuse"
  assert_contains "$out" "could not be read" \
    "non-numeric marker refusal did not say the round was unreadable"
  assert_not_contains "$out" "reached no-mistakes fix round 3" \
    "a non-numeric marker was reported as a round the gate never read"
  pass "fm-control: a non-numeric fix-round payload refuses without claiming a round"
}

# A marker recording a round below the threshold is the one payload that stands
# the marker gate down; the plain relaunch reason then owns the refusal.
test_nm_first_fix_round_marker_does_not_claim_the_third_round() {
  local dir out rc
  dir=$(new_case nm-round-first sa8)
  add_ship_task "$dir" sa8
  printf '1\n' > "$dir/home/state/sa8.nm-third-fix-round"
  out=$(run_control "$dir" sa8 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "the relaunch still refuses without a spec"
  assert_not_contains "$out" "fix round 3" "a round-1 marker was reported as the third fix round"
  assert_not_contains "$out" "could not be read" "a readable round-1 marker was reported as unreadable"
  assert_contains "$out" "relaunch of ship task sa8" "round-1 marker did not fall through to the relaunch reason"
  pass "fm-control: a marker below round 3 does not claim the third-fix-round reason"
}

# The documented recovery, end to end: the gated ship keeps its endpoint and
# worktree while a fresh Sol spec scout's artifact is installed for it, and the
# very relaunch that was refused then proceeds.
test_sol_spec_install_from_a_fresh_scout_clears_the_gated_relaunch() {
  local dir out rc scout_meta wt_before
  dir=$(new_case sol-spec-install sa15)
  add_ship_task "$dir" sa15
  wt_before=$(grep '^worktree=' "$dir/home/state/sa15.meta")

  out=$(run_control "$dir" sa15 relaunch --note "try again"); rc=$?
  expect_code 1 "$rc" "the gated relaunch should refuse before the spec is installed"

  scout_meta="$dir/home/state/sa15-spec.meta"
  printf 'window=fmses:fm-sa15-spec\nkind=scout\nworktree=%s\n' "$dir/wt" > "$scout_meta"
  mkdir -p "$dir/home/data/sa15-spec"
  printf '# Sol spec\n\nImplementation constraints for sa15.\n' > "$dir/home/data/sa15-spec/spec.md"

  out=$(run_promote "$dir" sa15-spec --sol-spec-for sa15); rc=$?
  expect_code 0 "$rc" "installing a fresh scout's Sol spec for the gated task should succeed"$'\n'"$out"
  assert_contains "$out" "bin/fm-control.sh sa15 relaunch" \
    "the install did not hand back the original task's own relaunch"
  cmp -s "$dir/home/data/sa15-spec/spec.md" "$dir/home/data/sa15/spec.md" \
    || fail "the installed Sol spec does not match the scout's reviewed deliverable"
  assert_grep 'kind=scout' "$scout_meta" "the install changed the scout's own contract"
  [ "$(grep '^worktree=' "$dir/home/state/sa15.meta")" = "$wt_before" ] \
    || fail "the install disturbed the gated task's worktree binding"

  out=$(run_control "$dir" sa15 relaunch --note "continue with the Sol spec"); rc=$?
  expect_code 0 "$rc" "the same relaunch should proceed once the Sol spec is installed"$'\n'"$out"
  assert_contains "$out" "relaunched sa15" "the previously gated relaunch did not complete"
  pass "fm-promote --sol-spec-for: a fresh scout's spec clears the original task's gate in place"
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
  fm_second_attempt_refuse_if_needed "$home/state" "$home/data" task-nm "$meta" relaunch \
    >"$home/out" 2>"$home/err"
  rc=$?
  expect_code 1 "$rc" "third fix-round marker should refuse without a spec"
  out=$(cat "$home/err")
  assert_contains "$out" "fix round 3" "marker refusal did not name the third fix round"
  assert_contains "$out" "commission a Sol spec scout under a fresh task id" \
    "marker refusal did not direct a fresh Sol spec scout task id"
  assert_not_contains "$out" "fm-brief.sh task-nm" \
    "marker refusal prescribed re-scaffolding the gated task id"
  printf '# spec\n' > "$home/data/task-nm/spec.md"
  fm_second_attempt_refuse_if_needed "$home/state" "$home/data" task-nm "$meta" relaunch \
    || fail "marker gate should clear once spec.md exists"
  pass "fm-second-attempt-lib: third fix-round marker refuses until a spec exists"
}

test_first_ship_spawn_is_not_blocked_without_a_spec
test_control_relaunch_refuses_without_a_spec_and_leaves_the_agent
test_control_relaunch_proceeds_once_spec_md_exists
test_scout_report_does_not_clear_the_gate
test_spawn_relaunch_refuses_without_a_spec
test_scout_relaunch_is_ungated_after_an_existing_attempt
test_secondmate_relaunch_is_unaffected_by_the_gate
test_nm_third_fix_round_marker_refuses_through_fm_control
test_nm_third_fix_round_is_recorded_automatically
test_nm_fix_round_attribution_takes_the_highest_active_round
test_nm_fix_round_attribution_survives_an_out_of_range_round
test_nm_third_fix_round_does_not_mark_a_scout
test_nm_third_fix_round_marker_with_no_payload_refuses
test_nm_non_numeric_marker_payload_refuses_without_claiming_a_round
test_nm_first_fix_round_marker_does_not_claim_the_third_round
test_sol_spec_install_from_a_fresh_scout_clears_the_gated_relaunch
test_nm_third_fix_round_marker_refuses_without_a_spec
echo "# all fm-second-attempt tests passed"
