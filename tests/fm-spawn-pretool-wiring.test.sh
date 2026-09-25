#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-pretool-wiring)
PAYLOAD='{"tool_input":{"command":"pkill -f tsx"}}'

make_fakebin() {
  local dir=$1 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'EOF'
#!/usr/bin/env bash
case "$*" in *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;; esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; *) : ;; esac
EOF
  chmod +x "$fakebin/tmux"
  fm_fake_exit0 "$fakebin" treehouse claude codex opencode pi pi-signed grok
  cat > "$fakebin/cursor-agent" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in --version) printf 'cursor-agent 1.0\n' ;; esac
EOF
  chmod +x "$fakebin/cursor-agent"
  printf '%s\n' "$fakebin"
}

make_case() {
  local name=$1 harness=$2 id=$3 case_dir home project worktree fakebin
  case_dir="$TMP_ROOT/$name"
  home="$case_dir/home"
  project="$case_dir/project"
  worktree="$case_dir/worktree"
  fakebin=$(make_fakebin "$case_dir/fake")
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'brief\n' > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
  fm_git_worktree "$project" "$worktree" "$name"
  printf '%s\n' "$home|$project|$worktree|$fakebin"
}

spawn_case() {
  local home=$1 project=$2 worktree=$3 fakebin=$4 id=$5 harness=$6
  FM_ROOT_OVERRIDE='' FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_DATA_OVERRIDE="$home/data" FM_PROJECTS_OVERRIDE="$home/projects" \
    FM_CONFIG_OVERRIDE="$home/config" FM_SPAWN_NO_GUARD=1 \
    FM_FAKE_PANE_PATH="$worktree" TMUX='fake,1,0' GROK_HOME="$home/grok" \
    PATH="$fakebin:$PATH" "$SPAWN" "$id" "$project" "$harness" \
    --mode no-mistakes --yolo off 2>&1
}

expect_blocked() {
  local label=$1 command=$2 out status
  out=$(printf '%s' "$PAYLOAD" | sh -c "$command" 2>&1)
  status=$?
  [ "$status" -eq 2 ] || fail "$label did not deny the broad process kill: $out"
  pass "$label denies the broad process kill through its executable hook"
}

test_claude_codex_cursor_and_grok() {
  local harness record home project worktree fakebin id out command status
  for harness in claude codex cursor grok; do
    id="pretool-$harness"
    record=$(make_case "$harness" "$harness" "$id")
    IFS='|' read -r home project worktree fakebin <<EOF
$record
EOF
    if ! out=$(spawn_case "$home" "$project" "$worktree" "$fakebin" "$id" "$harness"); then
      fail "$harness spawn failed: $out"
    fi
    case "$harness" in
      claude)
        command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$worktree/.claude/settings.local.json")
        expect_blocked claude "$command"
        ;;
      codex)
        command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$worktree/.codex/hooks.json")
        expect_blocked codex "$command"
        ;;
      cursor)
        command=$(jq -r '.hooks.preToolUse[0].command' "$worktree/.cursor/hooks.json")
        if out=$(printf '%s' "$PAYLOAD" | sh -c "$command" 2>&1); then
          if ! printf '%s' "$out" | jq -e '.permission == "deny"' >/dev/null 2>&1; then
            fail "cursor did not return its executable deny response: $out"
          fi
        else
          fail "cursor did not return its executable deny response: $out"
        fi
        pass "cursor denies the broad process kill through its executable hook"
        ;;
      grok)
        command=$(jq -r '.hooks.PreToolUse[0].hooks[0].command' "$home/grok/hooks/fm-pretool-check.json")
        if out=$(printf '%s' "$PAYLOAD" | GROK_WORKSPACE_ROOT="$worktree" sh -c "$command" 2>&1); then
          status=0
        else
          status=$?
        fi
        if [ "$status" -ne 2 ] || ! printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1; then
          fail "grok did not deny through its global hook: $out"
        fi
        pass "grok denies the broad process kill through its executable hook"
        ;;
    esac
  done
}

test_opencode_and_pi() {
  local harness record home project worktree fakebin id out
  for harness in opencode pi; do
    id="pretool-$harness"
    record=$(make_case "$harness" "$harness" "$id")
    IFS='|' read -r home project worktree fakebin <<EOF
$record
EOF
    if ! out=$(spawn_case "$home" "$project" "$worktree" "$fakebin" "$id" "$harness"); then
      fail "$harness spawn failed: $out"
    fi
    case "$harness" in
      opencode)
        if ! out=$(FM_PRETOOL_ROOT="$ROOT" PLUGIN="$worktree/.opencode/plugins/fm-fleet-pretool-check.js" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
const hooks = await mod.FmPrimaryPretoolCheck({ worktree: process.cwd() });
try {
  await hooks["tool.execute.before"]({ tool: "bash" }, { args: { command: "pkill -f tsx" } });
  process.exit(1);
} catch (error) {
  process.stdout.write(String(error.message));
}
EOF
); then
          fail "opencode plugin did not block the broad process kill: $out"
        fi
        if ! printf '%s' "$out" | grep -F 'broad-process-kill' >/dev/null; then
          fail "opencode plugin did not block the broad process kill: $out"
        fi
        pass "opencode denies the broad process kill through its executable plugin"
        ;;
      pi)
        if ! out=$(FM_PRETOOL_ROOT="$ROOT" EXT="$home/state/$id.pi-pretool.ts" node --input-type=module <<'EOF'
import { pathToFileURL } from "node:url";
const mod = await import(pathToFileURL(process.env.EXT).href);
const hooks = {};
mod.default({ on: (name, handler) => { hooks[name] = handler; } });
const result = await hooks.tool_call({ type: "tool_call", toolName: "bash", input: { command: "pkill -f tsx" } });
if (!result.block) process.exit(1);
process.stdout.write(result.reason);
EOF
); then
          fail "pi extension did not block the broad process kill: $out"
        fi
        if ! printf '%s' "$out" | grep -F 'broad-process-kill' >/dev/null; then
          fail "pi extension did not block the broad process kill: $out"
        fi
        pass "pi denies the broad process kill through its executable extension"
        ;;
    esac
  done
}

test_hook_wiring_refuses_worktree_symlink_escapes() {
  local harness parent target record home project worktree fakebin id out outside
  for harness in claude codex cursor opencode; do
    id="symlink-$harness"
    record=$(make_case "$id" "$harness" "$id")
    IFS='|' read -r home project worktree fakebin <<EOF
$record
EOF
    outside="$TMP_ROOT/outside-$harness"
    mkdir -p "$outside"
    case "$harness" in
      claude) parent=.claude; target=settings.local.json ;;
      codex) parent=.codex; target=hooks.json ;;
      cursor) parent=.cursor; target=hooks.json ;;
      opencode) parent=.opencode; target=plugins/fm-fleet-pretool-check.js ;;
    esac
    ln -s "$outside" "$worktree/$parent"
    if out=$(spawn_case "$home" "$project" "$worktree" "$fakebin" "$id" "$harness"); then
      fail "$harness accepted a symlinked hook parent: $out"
    fi
    [ ! -e "$outside/$target" ] && [ ! -L "$outside/$target" ] \
      || fail "$harness wrote through a symlinked hook parent"
    pass "$harness refuses a symlinked hook parent"
  done

  id=symlink-grok
  record=$(make_case "$id" grok "$id")
  IFS='|' read -r home project worktree fakebin <<EOF
$record
EOF
  outside="$TMP_ROOT/outside-grok"
  mkdir -p "$outside"
  ln -s "$outside/pretool-root" "$worktree/.fm-grok-pretool-root"
  if out=$(spawn_case "$home" "$project" "$worktree" "$fakebin" "$id" grok); then
    fail "grok accepted a symlinked PreToolUse pointer: $out"
  fi
  [ ! -e "$outside/pretool-root" ] && [ ! -L "$outside/pretool-root" ] \
    || fail "grok wrote through a symlinked PreToolUse pointer"
  pass "grok refuses a symlinked PreToolUse pointer"
}

test_claude_codex_cursor_and_grok
test_opencode_and_pi
test_hook_wiring_refuses_worktree_symlink_escapes

echo "all fm-spawn PreToolUse wiring tests passed"
