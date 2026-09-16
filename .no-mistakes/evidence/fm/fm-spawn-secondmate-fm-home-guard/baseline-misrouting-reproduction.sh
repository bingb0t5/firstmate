#!/usr/bin/env bash
set -euo pipefail

root=$1
case_dir=$(mktemp -d /tmp/fm-home-identity-baseline.XXXXXX)
trap 'rm -rf "$case_dir"' EXIT
primary="$case_dir/primary"
mate="$case_dir/mate"

make_home() {
  local home=$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$root/AGENTS.md" "$home/AGENTS.md"
  cp -R "$root/bin" "$home/bin"
}

make_home "$primary"
make_home "$mate"
printf 'kind=crew\nbackend=tmux\nwindow=fm-primary-task\nworktree=%s\n' "$primary" > "$primary/state/primary-task.meta"
output=$(env -u NO_MISTAKES_GATE FM_GATE_REFUSE_BYPASS=1 FM_BACKEND=tmux FM_HOME="$primary" "$mate/bin/fm-send.sh" fm-primary-task --inbox-only 'baseline misrouting test' 2>&1)
[ -f "$primary/state/primary-task.inbox/001.msg" ]
printf 'BASELINE SCENARIO: mate steering primary through its own bin\nexit=0\n%s\nprotected_inbox_exists=yes\n' "$output"
