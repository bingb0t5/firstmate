#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's secondmate project-ownership guard on fresh
# ship and scout spawns. Every case stops before any endpoint exists: the guard
# runs ahead of backend creation, and a fake tmux that exits non-zero backstops
# cases meant to get past it.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-ownership)

make_home() {  # <name> [<secondmate-registry-line>...]
  local name=$1 home projects fakebin smhome
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  smhome="$TMP_ROOT/$name/secondmate-home"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/ownedproj" "$projects/freeproj" "$fakebin"
  mkdir -p "$smhome/state" "$smhome/bin"
  printf '%s\n' 'fixture' > "$smhome/AGENTS.md"
  printf '%s\n' design > "$smhome/.fm-secondmate-home"
  printf '#!/bin/sh\nexit 1\n' > "$fakebin/tmux"
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/secondmates.md"
  fi
  printf '%s\n' "$home|$projects|$fakebin|$smhome"
}

write_brief() {  # <home> <id> [<mode>]
  local home=$1 id=$2 mode=${3:-}
  mkdir -p "$home/data/$id"
  {
    printf 'You are a crewmate.\n\n# Definition of done\n'
    [ -z "$mode" ] || printf 'Delivery contract: mode=%s\n' "$mode"
  } > "$home/data/$id/brief.md"
}

run_spawn() {  # <home> <fakebin> <spawn-args...>
  local home=$1 fakebin=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$TMP_ROOT/projects-unused" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux PATH="$fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

test_fresh_spawn_into_owned_project_refuses_and_writes_no_meta() {
  local rec home proj fakebin smhome out status line
  line="- design - design domain (home: $TMP_ROOT/refuse/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home refuse "$line")
  IFS='|' read -r home proj fakebin smhome <<EOF
$rec
EOF
  write_brief "$home" own-refuse-a1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-refuse-a1 "$proj/ownedproj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "owned-project spawn should exit non-zero"
  assert_contains "$out" "registered to secondmate design" "refusal did not name the owning secondmate"
  assert_contains "$out" "--allow-primary-spawn" "refusal did not name the deliberate override"
  assert_absent "$home/state/own-refuse-a1.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: a fresh crewmate spawn into a secondmate-owned project refuses before metadata exists"
}

test_allow_primary_spawn_override_passes_the_ownership_guard() {
  local rec home proj fakebin smhome out
  line="- design - design domain (home: $TMP_ROOT/override/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home override "$line")
  IFS='|' read -r home proj fakebin smhome <<EOF
$rec
EOF
  write_brief "$home" own-override-b1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-override-b1 "$proj/ownedproj" claude --mode no-mistakes --yolo off --allow-primary-spawn)
  assert_not_contains "$out" "registered to secondmate" "override spawn was blocked by the ownership guard"
  assert_contains "$out" "--allow-primary-spawn bypasses secondmate ownership" "override did not print a loud notice"
  pass "fm-spawn: --allow-primary-spawn bypasses the ownership guard on an owned project"
}

test_secondmate_spawn_is_unaffected_by_the_ownership_guard() {
  local rec home proj fakebin smhome out
  line="- design - design domain (home: $TMP_ROOT/secondmate/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home secondmate "$line")
  IFS='|' read -r home proj fakebin smhome <<EOF
$rec
EOF
  out=$(run_spawn "$home" "$fakebin" design "$smhome" --secondmate 2>&1)
  assert_not_contains "$out" "registered to secondmate" "secondmate spawn hit the crewmate ownership guard"
  assert_not_contains "$out" "--allow-primary-spawn bypasses" "secondmate spawn required the primary override"
  pass "fm-spawn: --secondmate spawns are unaffected by the ownership guard"
}

test_relaunch_is_unaffected_by_the_ownership_guard() {
  local rec home proj fakebin smhome out status
  line="- design - design domain (home: $TMP_ROOT/relaunch/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home relaunch "$line")
  IFS='|' read -r home proj fakebin smhome <<EOF
$rec
EOF
  mkdir -p "$home/worktrees/owned"
  cat > "$home/state/own-relaunch-c1.meta" <<EOF
window=fm-own-relaunch-c1
endpoint_task_id=own-relaunch-c1
worktree=$home/worktrees/owned
project=$proj/ownedproj
harness=claude
kind=ship
mode=no-mistakes
yolo=off
EOF
  out=$(run_spawn "$home" "$fakebin" own-relaunch-c1 --relaunch claude)
  status=$?
  assert_not_contains "$out" "registered to secondmate" "relaunch hit the crewmate ownership guard"
  [ "$status" -ne 0 ] || fail "relaunch should still fail later on the refusing fake backend"
  pass "fm-spawn: --relaunch is unaffected by the ownership guard"
}

test_unowned_project_or_missing_registry_spawns_past_the_guard() {
  local rec home proj fakebin out
  rec=$(make_home unowned)
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-free-d1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-free-d1 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "registered to secondmate" "unowned spawn with no registry hit the ownership guard"

  line="- design - design domain (home: $TMP_ROOT/unowned/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home unowned-reg "$line")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-free-d2 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-free-d2 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "registered to secondmate" "unowned spawn with a registry hit the ownership guard"
  assert_contains "$out" "not on any registered secondmate projects: list" "unowned spawn did not warn about registered scopes"
  pass "fm-spawn: unowned projects and missing registries pass the ownership guard"
}

test_unparseable_registry_entry_refuses_instead_of_voiding_ownership() {
  local rec home proj fakebin out status good bad
  good="- design - design domain (home: $TMP_ROOT/malformed/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  bad="- triage - typo entry (home: $TMP_ROOT/malformed/smhome2; scope: triage; projects: freeproj)"
  rec=$(make_home malformed "$good" "$bad")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-broken-e1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-broken-e1 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn against an unparseable registry entry should exit non-zero"
  assert_contains "$out" "malformed secondmate registry entry" "refusal did not name the unusable registry record"
  assert_contains "$out" "- triage - typo entry" "refusal did not quote the offending registry line"
  assert_not_contains "$out" "not on any registered secondmate projects: list" \
    "an unresolvable registry still claimed the project is unowned"
  assert_absent "$home/state/own-broken-e1.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: an unparseable registry entry refuses rather than silently voiding its ownership claim"
}

test_unreadable_registry_symlink_refuses_the_spawn() {
  local rec home proj fakebin out status
  rec=$(make_home symlinked)
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  ln -s "$home/data/missing-secondmates.md" "$home/data/secondmates.md"
  write_brief "$home" own-link-f1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-link-f1 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "spawn against an unsafe registry path should exit non-zero"
  assert_contains "$out" "secondmate registry is unavailable or unsafe" "refusal did not name the unsafe registry path"
  assert_absent "$home/state/own-link-f1.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: an unsafe registry path refuses rather than reading as an empty registry"
}

test_batch_dispatch_carries_the_deliberate_override_to_every_pair() {
  local rec home proj fakebin out
  local line
  line="- design - design domain (home: $TMP_ROOT/batch/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home batch "$line")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-batch-g1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" "own-batch-g1=$proj/ownedproj" --mode no-mistakes --yolo off)
  assert_contains "$out" "registered to secondmate design" "batch pair did not hit the ownership guard"

  write_brief "$home" own-batch-g2 no-mistakes
  out=$(run_spawn "$home" "$fakebin" "own-batch-g2=$proj/ownedproj" --mode no-mistakes --yolo off --allow-primary-spawn)
  assert_contains "$out" "--allow-primary-spawn bypasses secondmate ownership" \
    "batch dispatch dropped the deliberate override before the per-pair guard"
  assert_not_contains "$out" "registered to secondmate design" "batch pair refused despite the deliberate override"
  pass "fm-spawn: batch dispatch forwards --allow-primary-spawn to every pair"
}

test_fresh_spawn_into_owned_project_refuses_and_writes_no_meta
test_allow_primary_spawn_override_passes_the_ownership_guard
test_secondmate_spawn_is_unaffected_by_the_ownership_guard
test_relaunch_is_unaffected_by_the_ownership_guard
test_unowned_project_or_missing_registry_spawns_past_the_guard
test_unparseable_registry_entry_refuses_instead_of_voiding_ownership
test_unreadable_registry_symlink_refuses_the_spawn
test_batch_dispatch_carries_the_deliberate_override_to_every_pair
echo "# all fm-spawn-secondmate-ownership tests passed"
