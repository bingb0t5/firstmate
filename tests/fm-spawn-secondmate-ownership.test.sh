#!/usr/bin/env bash
# Behavior tests for fm-spawn.sh's secondmate project-ownership guard on fresh
# ship and scout spawns. Refusal cases stop before any endpoint exists. Cases
# that must get PAST the guard prove it: the refusing fake backend announces its
# window-creation attempt, which fm-spawn only reaches well after the guard, and
# the override and relaunch cases drive a lifecycle-modelling backend all the way
# to a published state/<id>.meta record.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-secondmate-ownership)

# The refusing backend fails every request, but announces a window-creation
# attempt on stderr. fm-spawn only asks a backend for a window long after the
# ownership guard, so BACKEND_REACHED is a marker no pre-guard exit can print.
BACKEND_REACHED="fake-backend: refusing to create a window"

scaffold_secondmate_home() {  # <path>
  local smhome=$1
  mkdir -p "$smhome/state" "$smhome/bin" "$smhome/data"
  printf '%s\n' 'fixture' > "$smhome/AGENTS.md"
  printf '%s\n' design > "$smhome/.fm-secondmate-home"
  printf '%s\n' 'You are a persistent second mate.' > "$smhome/data/charter.md"
}

make_home() {  # <name> [<secondmate-registry-line>...]
  local name=$1 home projects fakebin smhome
  shift
  home="$TMP_ROOT/$name/home"
  projects="$TMP_ROOT/$name/projects"
  smhome="$TMP_ROOT/$name/smhome"
  fakebin="$TMP_ROOT/$name/bin"
  mkdir -p "$home/data" "$home/state" "$home/config" "$projects/ownedproj" "$projects/freeproj" "$fakebin"
  scaffold_secondmate_home "$smhome"
  cat > "$fakebin/tmux" <<SH
#!/bin/sh
case "\${1:-}" in
  new-window) printf '%s\\n' "$BACKEND_REACHED" >&2 ;;
esac
exit 1
SH
  chmod +x "$fakebin/tmux"
  if [ "$#" -gt 0 ]; then
    printf '%s\n' "$@" > "$home/data/secondmates.md"
  fi
  printf '%s\n' "$home|$projects|$fakebin|$smhome"
}

# A backend that models the pane lifecycle instead of refusing, so a spawn can
# run to a published state/<id>.meta. Shaped after the stub in
# tests/fm-control-relaunch.test.sh: FM_FAKE_DIR/command is the pane's current
# command (the agent-liveness read a relaunch requires) and FM_FAKE_DIR/cwd is
# the worktree treehouse is pretending to have entered.
make_live_backend() {  # <dir> <worktree> <pane-command> [<existing-window>] -> echoes fakebin dir
  local dir=$1 wt=$2 command=$3 window=${4:-}
  local fb="$dir/fakebin" fake="$dir/fake"
  mkdir -p "$fb" "$fake"
  printf '%s' "$command" > "$fake/command"
  printf '%s' "$wt" > "$fake/cwd"
  : > "$fake/windows"
  [ -z "$window" ] || printf '%s\n' "$window" > "$fake/windows"
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  new-window) printf 'fakewin1\n'; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf 'pane\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
  chmod +x "$fb/tmux"
  fm_fake_exit0 "$fb" treehouse
  printf '%s\n' "$fb"
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
    FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_DIR="${FM_FAKE_DIR:-}" \
    TMUX='' PATH="$fakebin:$PATH" \
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
  assert_contains "$out" "registered to secondmate(s) design" "refusal did not name the owning secondmate"
  assert_contains "$out" "--allow-primary-spawn" "refusal did not name the deliberate override"
  assert_absent "$home/state/own-refuse-a1.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: a fresh crewmate spawn into a secondmate-owned project refuses before metadata exists"
}

test_registry_entry_path_forms_state_the_same_ownership_claim() {
  local rec home proj fakebin out status
  rec=$(make_home pathforms \
    "- design - design domain (home: $TMP_ROOT/pathforms/smhome; scope: design domain; projects: projects/ownedproj; added 2026-06-22)" \
    "- triage - triage domain (home: $TMP_ROOT/pathforms/smhome2; scope: triage; projects: $TMP_ROOT/pathforms/projects/ownedproj; added 2026-06-22)")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-path-j1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-path-j1 "$proj/ownedproj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a projects/<name> or absolute-path registry entry should still refuse"
  assert_contains "$out" "registered to secondmate(s) design,triage" \
    "path-form registry entries did not state the same ownership claim as a bare name"
  assert_absent "$home/state/own-path-j1.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: a projects: entry claims its project as a bare name, projects/<name>, or absolute path"
}

test_project_name_whitespace_is_preserved_within_comma_delimited_entries() {
  local rec home proj fakebin out status line
  line="- design - design domain (home: $TMP_ROOT/whitespace/smhome; scope: design domain; projects: My Project, other; added 2026-06-22)"
  rec=$(make_home whitespace "$line")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  mkdir -p "$proj/My Project"
  write_brief "$home" own-space-l1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-space-l1 "$proj/My Project" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a project with whitespace in its basename should refuse"
  assert_contains "$out" "registered to secondmate(s) design" \
    "whitespace within a comma-delimited project entry broke its ownership claim"
  assert_absent "$home/state/own-space-l1.meta" "refused whitespace-project spawn wrote task metadata"
  pass "fm-spawn: whitespace within a comma-delimited project name is preserved"
}

test_projects_field_metacharacter_is_never_expanded_against_the_working_directory() {
  local rec home proj fakebin cwd out status line
  line="- design - design domain (home: $TMP_ROOT/glob/smhome; scope: design domain; projects: owned*; added 2026-06-22)"
  rec=$(make_home glob "$line")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  cwd="$TMP_ROOT/glob/cwd"
  mkdir -p "$cwd"
  : > "$cwd/ownedproj"
  write_brief "$home" own-glob-k1 no-mistakes
  out=$(cd "$cwd" && run_spawn "$home" "$fakebin" own-glob-k1 "$proj/ownedproj" claude --mode no-mistakes --yolo off)
  status=$?
  assert_not_contains "$out" "registered to secondmate" \
    "a projects: glob expanded against the working directory and invented an ownership claim"
  assert_contains "$out" "$BACKEND_REACHED" "the invented ownership claim stopped the spawn before the backend"
  [ "$status" -ne 0 ] || fail "the refusing fake backend should still fail the spawn"
  pass "fm-spawn: a projects: metacharacter is compared literally, never expanded against the caller's cwd"
}

test_refusal_names_every_owner_when_several_claim_the_project() {
  local rec home proj fakebin out status
  rec=$(make_home multiowner \
    "- design - design domain (home: $TMP_ROOT/multiowner/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)" \
    "- triage - triage domain (home: $TMP_ROOT/multiowner/smhome2; scope: triage; projects: ownedproj, other; added 2026-06-22)" \
    "- docs - docs domain (home: $TMP_ROOT/multiowner/smhome3; scope: docs; projects: ownedproj; added 2026-06-22)")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-refuse-a2 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-refuse-a2 "$proj/ownedproj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "multi-owner spawn should exit non-zero"
  assert_contains "$out" "registered to secondmate(s) design,triage,docs" \
    "refusal did not name every owner in one consistently joined list"
  assert_absent "$home/state/own-refuse-a2.meta" "refused spawn wrote task metadata"
  pass "fm-spawn: a refusal names every registered owner the same way at any arity"
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

test_allow_primary_spawn_is_refused_outside_a_fresh_ship_or_scout_spawn() {
  local rec home proj fakebin smhome out status line
  line="- design - design domain (home: $TMP_ROOT/misuse/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home misuse "$line")
  IFS='|' read -r home proj fakebin smhome <<EOF
$rec
EOF
  write_brief "$home" own-misuse-e1 no-mistakes
  fm_write_meta "$home/state/own-misuse-e1.meta" \
    "window=firstmate:fm-own-misuse-e1" \
    "endpoint_task_id=own-misuse-e1" \
    "worktree=$proj/ownedproj" \
    "project=$proj/ownedproj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off"
  out=$(run_spawn "$home" "$fakebin" own-misuse-e1 --relaunch --allow-primary-spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "--relaunch with --allow-primary-spawn should exit non-zero"
  assert_contains "$out" "--allow-primary-spawn applies only to fresh ship or scout spawns" \
    "relaunch did not refuse the misapplied override"

  out=$(run_spawn "$home" "$fakebin" design "$smhome" --secondmate --allow-primary-spawn)
  status=$?
  [ "$status" -ne 0 ] || fail "--secondmate with --allow-primary-spawn should exit non-zero"
  assert_contains "$out" "--allow-primary-spawn applies only to fresh ship or scout spawns" \
    "secondmate spawn did not refuse the misapplied override"
  assert_not_contains "$out" "$BACKEND_REACHED" "the misapplied override still reached the backend"
  pass "fm-spawn: --allow-primary-spawn is refused on --relaunch and --secondmate spawns"
}

test_secondmate_spawn_is_unaffected_by_the_ownership_guard() {
  local rec home proj fakebin smhome out line
  # The home directory's basename is itself on the registry's projects list, so
  # a guard that did not exempt --secondmate would refuse this very spawn.
  smhome="$TMP_ROOT/secondmate/design"
  line="- design - design domain (home: $smhome; scope: design domain; projects: design, ownedproj; added 2026-06-22)"
  rec=$(make_home secondmate "$line")
  IFS='|' read -r home proj fakebin _unused <<EOF
$rec
EOF
  scaffold_secondmate_home "$smhome"
  out=$(run_spawn "$home" "$fakebin" design "$smhome" --secondmate)
  assert_contains "$out" "$BACKEND_REACHED" "secondmate spawn never reached the backend, so it never reached the guard position"
  assert_not_contains "$out" "registered to secondmate" "secondmate spawn hit the crewmate ownership guard"
  assert_not_contains "$out" "--allow-primary-spawn bypasses" "secondmate spawn required the primary override"
  pass "fm-spawn: --secondmate spawns are unaffected by the ownership guard"
}

test_relaunch_is_unaffected_by_the_ownership_guard() {
  local dir home wt fakebin out line
  dir="$TMP_ROOT/own-relaunch-c1"
  home="$dir/home"
  wt="$dir/wt"
  mkdir -p "$home/data/own-relaunch-c1" "$home/state" "$home/config"
  fm_git_worktree "$dir/ownedproj" "$wt" task-own-relaunch-c1
  line="- design - design domain (home: $dir/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  printf '%s\n' "$line" > "$home/data/secondmates.md"
  printf '# brief\n\nDo the thing.\n' > "$home/data/own-relaunch-c1/brief.md"
  fakebin=$(make_live_backend "$dir" "$wt" zsh fm-own-relaunch-c1)
  fm_write_meta "$home/state/own-relaunch-c1.meta" \
    "window=firstmate:fm-own-relaunch-c1" \
    "endpoint_task_id=own-relaunch-c1" \
    "worktree=$wt" \
    "project=$dir/ownedproj" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "tasktmp=/tmp/fm-own-relaunch-c1" \
    "model=default" \
    "effort=default"
  FM_FAKE_DIR="$dir/fake"
  out=$(run_spawn "$home" "$fakebin" own-relaunch-c1 --relaunch --harness claude)
  assert_not_contains "$out" "registered to secondmate" "relaunch hit the crewmate ownership guard"
  assert_contains "$out" "spawned own-relaunch-c1" "relaunch did not complete into its recorded endpoint"
  assert_present "$home/state/own-relaunch-c1.meta" "relaunch did not keep the task record"
  unset FM_FAKE_DIR
  rm -rf /tmp/fm-own-relaunch-c1
  pass "fm-spawn: --relaunch into a secondmate-owned project is unaffected by the ownership guard"
}

test_override_spawn_records_every_bypassed_owner_on_the_task_record() {
  local dir home wt fakebin out status meta
  dir="$TMP_ROOT/own-override-b2"
  home="$dir/home"
  wt="$dir/wt"
  meta="$home/state/own-override-b2.meta"
  mkdir -p "$home/data/own-override-b2" "$home/state" "$home/config"
  fm_git_worktree "$dir/ownedproj" "$wt" task-own-override-b2
  {
    printf -- '- design - design domain (home: %s/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)\n' "$dir"
    printf -- '- triage - triage domain (home: %s/smhome2; scope: triage; projects: ownedproj, other; added 2026-06-22)\n' "$dir"
  } > "$home/data/secondmates.md"
  printf '# brief\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' > "$home/data/own-override-b2/brief.md"
  fakebin=$(make_live_backend "$dir" "$wt" claude)
  FM_FAKE_DIR="$dir/fake"
  out=$(run_spawn "$home" "$fakebin" own-override-b2 "$dir/ownedproj" claude \
    --mode no-mistakes --yolo off --allow-primary-spawn)
  status=$?
  unset FM_FAKE_DIR
  [ "$status" -eq 0 ] || fail "override spawn should complete"$'\n'"$out"
  assert_contains "$out" "--allow-primary-spawn bypasses secondmate ownership" "override did not print a loud notice"
  assert_present "$meta" "override spawn published no task record"
  assert_grep 'primary_spawn_override=1' "$meta" "task record did not record the deliberate override"
  assert_grep 'primary_spawn_override_owners=design,triage' "$meta" \
    "task record did not name every bypassed owner"
  rm -rf /tmp/fm-own-override-b2
  pass "fm-spawn: a deliberate override records every bypassed owner on the task record"
}

test_unowned_project_or_missing_registry_spawns_past_the_guard() {
  local rec home proj fakebin out line
  rec=$(make_home unowned)
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  assert_absent "$home/data/secondmates.md" "the missing-registry fixture wrote a registry"
  write_brief "$home" own-free-d1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-free-d1 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "registered to secondmate" "unowned spawn with no registry hit the ownership guard"
  assert_contains "$out" "$BACKEND_REACHED" "a missing registry stopped the spawn before the backend"
  assert_not_contains "$out" "not on any registered secondmate" "a missing registry warned about registered scopes"

  rec=$(make_home empty-reg)
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  printf '%s\n' '# Second mates' > "$home/data/secondmates.md"
  write_brief "$home" own-free-d3 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-free-d3 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "registered to secondmate" "unowned spawn with an entry-less registry hit the ownership guard"
  assert_contains "$out" "$BACKEND_REACHED" "an entry-less registry stopped the spawn before the backend"
  assert_not_contains "$out" "not on any registered secondmate" "an entry-less registry warned about registered scopes"

  line="- design - design domain (home: $TMP_ROOT/unowned/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home unowned-reg "$line")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-free-d2 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-free-d2 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  assert_not_contains "$out" "registered to secondmate" "unowned spawn with a registry hit the ownership guard"
  assert_contains "$out" "not on any registered secondmate projects: list" "unowned spawn did not warn about registered scopes"
  pass "fm-spawn: unowned projects and missing or entry-less registries pass the ownership guard"
}

test_project_less_secondmate_never_claims_ownership_through_its_scope_text() {
  local rec home proj fakebin out status line
  line="- design - design domain (home: $TMP_ROOT/projectless/smhome; scope: docs, freeproj, release notes; projects: ; added 2026-06-22)"
  rec=$(make_home projectless "$line")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-scope-h1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-scope-h1 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  status=$?
  assert_not_contains "$out" "registered to secondmate" "a project-less secondmate claimed ownership through its scope text"
  assert_contains "$out" "$BACKEND_REACHED" "the spawn was stopped before the backend despite no ownership claim"
  assert_contains "$out" "design (scope: docs, freeproj, release notes)" \
    "the unowned-project warning dropped the scope it exists to surface"
  [ "$status" -ne 0 ] || fail "the refusing fake backend should still fail the spawn"
  pass "fm-spawn: a project-less secondmate's scope text is never an ownership claim"
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

test_nonrecord_registry_line_refuses_instead_of_looking_empty() {
  local rec home proj fakebin out status
  rec=$(make_home malformed-nonrecord "this is not a secondmate registry record")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-malformed-m1 no-mistakes
  out=$(run_spawn "$home" "$fakebin" own-malformed-m1 "$proj/freeproj" claude --mode no-mistakes --yolo off)
  status=$?
  [ "$status" -ne 0 ] || fail "a non-record registry line should exit non-zero"
  assert_contains "$out" "malformed secondmate registry entry" \
    "a non-record registry line was silently treated as an empty registry"
  assert_not_contains "$out" "$BACKEND_REACHED" \
    "a non-record registry line reached the backend instead of failing closed"
  assert_absent "$home/state/own-malformed-m1.meta" \
    "spawn against a non-record registry line wrote task metadata"
  pass "fm-spawn: every non-empty malformed registry line fails closed"
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

test_fresh_scout_spawn_is_guarded_and_overridable_like_a_ship_spawn() {
  local rec home proj fakebin out status line
  line="- design - design domain (home: $TMP_ROOT/scout/smhome; scope: design domain; projects: ownedproj; added 2026-06-22)"
  rec=$(make_home scout "$line")
  IFS='|' read -r home proj fakebin _smhome <<EOF
$rec
EOF
  write_brief "$home" own-scout-i1
  out=$(run_spawn "$home" "$fakebin" own-scout-i1 "$proj/ownedproj" claude --scout)
  status=$?
  [ "$status" -ne 0 ] || fail "owned-project scout spawn should exit non-zero"
  assert_contains "$out" "registered to secondmate(s) design" "scout refusal did not name the owning secondmate"
  assert_not_contains "$out" "$BACKEND_REACHED" "the refused scout spawn still reached the backend"
  assert_absent "$home/state/own-scout-i1.meta" "refused scout spawn wrote task metadata"

  write_brief "$home" own-scout-i2
  out=$(run_spawn "$home" "$fakebin" own-scout-i2 "$proj/ownedproj" claude --scout --allow-primary-spawn)
  assert_contains "$out" "--allow-primary-spawn bypasses secondmate ownership" \
    "scout override did not print a loud notice"
  assert_not_contains "$out" "registered to secondmate" "scout override was blocked by the ownership guard"
  assert_contains "$out" "$BACKEND_REACHED" "the overridden scout spawn never reached the backend"
  pass "fm-spawn: a fresh scout spawn is refused on an owned project and passes with the deliberate override"
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
  assert_contains "$out" "registered to secondmate(s) design" "batch pair did not hit the ownership guard"

  write_brief "$home" own-batch-g2 no-mistakes
  out=$(run_spawn "$home" "$fakebin" "own-batch-g2=$proj/ownedproj" --mode no-mistakes --yolo off --allow-primary-spawn)
  assert_contains "$out" "--allow-primary-spawn bypasses secondmate ownership" \
    "batch dispatch dropped the deliberate override before the per-pair guard"
  assert_not_contains "$out" "registered to secondmate(s) design" "batch pair refused despite the deliberate override"
  pass "fm-spawn: batch dispatch forwards --allow-primary-spawn to every pair"
}

test_fresh_spawn_into_owned_project_refuses_and_writes_no_meta
test_refusal_names_every_owner_when_several_claim_the_project
test_registry_entry_path_forms_state_the_same_ownership_claim
test_project_name_whitespace_is_preserved_within_comma_delimited_entries
test_projects_field_metacharacter_is_never_expanded_against_the_working_directory
test_fresh_scout_spawn_is_guarded_and_overridable_like_a_ship_spawn
test_allow_primary_spawn_override_passes_the_ownership_guard
test_allow_primary_spawn_is_refused_outside_a_fresh_ship_or_scout_spawn
test_secondmate_spawn_is_unaffected_by_the_ownership_guard
test_relaunch_is_unaffected_by_the_ownership_guard
test_override_spawn_records_every_bypassed_owner_on_the_task_record
test_unowned_project_or_missing_registry_spawns_past_the_guard
test_project_less_secondmate_never_claims_ownership_through_its_scope_text
test_unparseable_registry_entry_refuses_instead_of_voiding_ownership
test_nonrecord_registry_line_refuses_instead_of_looking_empty
test_unreadable_registry_symlink_refuses_the_spawn
test_batch_dispatch_carries_the_deliberate_override_to_every_pair
echo "# all fm-spawn-secondmate-ownership tests passed"
