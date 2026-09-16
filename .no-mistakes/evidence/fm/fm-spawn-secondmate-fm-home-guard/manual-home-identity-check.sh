#!/usr/bin/env bash
set -euo pipefail

root=$1
case_dir=$(mktemp -d /tmp/fm-home-identity-live.XXXXXX)
trap 'rm -rf "$case_dir"' EXIT
primary="$case_dir/primary"
mate="$case_dir/mate"

make_home() {
  local home=$1 id=${2:-}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$root/AGENTS.md" "$home/AGENTS.md"
  cp -R "$root/bin" "$home/bin"
  printf '7500\n' > "$home/config/startup-memory-budget"
  if [ -n "$id" ]; then
    printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' "$primary" > "$home/.fm-secondmate-parent"
    printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  fi
}

make_home "$primary"
make_home "$mate" mate-a
printf '# Second mates\n\n- mate-a - domain (home: %s; scope: test work; projects: alpha; added 2026-09-16)\n' "$mate" > "$primary/data/secondmates.md"
printf 'kind=crew\nbackend=tmux\nwindow=fm-primary-task\nworktree=%s\n' "$primary" > "$primary/state/primary-task.meta"

set +e
refusal=$(env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_BACKEND=tmux FM_HOME="$primary" "$mate/bin/fm-send.sh" fm-primary-task --inbox-only 'misrouting test' 2>&1)
refusal_rc=$?
set -e
[ "$refusal_rc" -eq 4 ]
[ ! -e "$primary/state/primary-task.inbox" ]
printf 'SCENARIO: mate steering primary through its own bin\nexit=%s\n%s\nprotected_inbox_exists=no\n\n' "$refusal_rc" "$refusal"

mkdir -p "$primary/scratch"
set +e
override=$(env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_BACKEND=tmux FM_HOME="$mate" FM_STATE_OVERRIDE="$primary/scratch/missing-state" "$mate/bin/fm-spawn.sh" worker "$case_dir/project" --mode no-mistakes --yolo off 2>&1)
override_rc=$?
set -e
[ "$override_rc" -eq 4 ]
[ ! -e "$primary/scratch/missing-state" ]
printf 'SCENARIO: mate spawning through a missing state subpath under primary\nexit=%s\n%s\nprotected_subpath_exists=no\n\n' "$override_rc" "$override"

set +e
unrelated=$(env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_BACKEND=tmux FM_HOME="$primary" FM_STATE_OVERRIDE="$case_dir/unrelated-missing-state" "$primary/bin/fm-spawn.sh" worker "$case_dir/project" --mode no-mistakes --yolo off 2>&1)
unrelated_rc=$?
set -e
[ "$unrelated_rc" -ne 4 ]
[ -d "$case_dir/unrelated-missing-state" ]
printf 'SCENARIO: primary uses unrelated missing state override\nexit=%s\n%s\ncross_home_refusal=no\nunrelated_state_created=yes\n' "$unrelated_rc" "$unrelated"
