#!/usr/bin/env bash
# Manual live hook-path reproduction (tracked Stop hook, scratch home)
set -euo pipefail
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M28FY7F56FRXG76KKPTEPHJ8"
LAB=$(mktemp -d "$ROOT/.codex-stop-live-repro.XXXXXX")
cleanup() { rm -rf "$LAB"; }
trap cleanup EXIT
mkdir -p "$LAB/state" "$LAB/config" "$LAB/bin" "$LAB/.codex" "$LAB/fakebin"
for e in "$ROOT/bin/"*; do ln -s "$e" "$LAB/bin/${e##*/}"; done
cp "$ROOT/.codex/hooks.json" "$LAB/.codex/hooks.json"
: > "$LAB/AGENTS.md"
printf 'codex-stop-live-repro\n' > "$LAB/.fm-secondmate-home"
cat > "$LAB/fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in list-windows|capture-pane) exit 0 ;; esac; exit 1
SH
chmod +x "$LAB/fakebin/tmux"
STOP=$(jq -r '.hooks.Stop[0].hooks[0].command' "$LAB/.codex/hooks.json")
printf 'kind=ship\n' > "$LAB/state/live.meta"
PIPE="$LAB/hook.pipe"
mkfifo "$PIPE"
( cat "$PIPE" > "$LAB/pipe.out" ) &
READER=$!
START=$(python3 -c 'import time; print(time.monotonic_ns()//1000000)')
(
  cd "$LAB"
  printf '%s\n' "$$" > "$LAB/state/.lock"
  env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_HOME="$LAB" FM_ROOT_OVERRIDE="$LAB" FM_STATE_OVERRIDE="$LAB/state" \
    FM_CONFIG_OVERRIDE="$LAB/config" PATH="$LAB/fakebin:$PATH" \
    FM_HOME_WAKE_BACKEND=tmux FM_HOME_WAKE_TARGET=live-repro \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    bash -c 'printf "{\"stop_hook_active\":false}" | bash -c "$1"' _ "$STOP"
) > "$PIPE" 2>"$LAB/stop.err"
END=$(python3 -c 'import time; print(time.monotonic_ns()//1000000)')
ELAPSED=$((END - START))
wait "$READER" 2>/dev/null || true
WATCHER=$(sed -n '1p' "$LAB/state/.watch.lock/pid" 2>/dev/null || true)
SID=$(python3 -c 'import os,sys; print(os.getsid(int(sys.argv[1])))' "$WATCHER" 2>/dev/null || echo n/a)
{
  echo "=== Codex Stop hook live reproduction ==="
  echo "elapsed_ms=$ELAPSED"
  echo "watcher_pid=$WATCHER"
  echo "watcher_sid=$SID"
  echo "sid_is_session_leader=$([ "$SID" = "$WATCHER" ] && echo yes || echo no)"
  echo "pipe_closed=$([ ! -s "$LAB/pipe.out" ] && echo yes || echo no)"
  echo "watcher_alive=$([ -n "$WATCHER" ] && kill -0 "$WATCHER" 2>/dev/null && echo yes || echo no)"
  echo "beat_exists=$([ -e "$LAB/state/.last-watcher-beat" ] && echo yes || echo no)"
  if [ -d "/proc/$WATCHER/fd" ]; then
    for fd in 0 1 2; do echo "fd${fd}=$(readlink /proc/$WATCHER/fd/$fd 2>/dev/null || echo missing)"; done
  fi
  echo "--- stop.err (last 5 lines) ---"
  tail -5 "$LAB/stop.err" 2>/dev/null || true
} 
