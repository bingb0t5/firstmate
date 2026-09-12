#!/usr/bin/env bash
# Opt-in credentialed Codex regression proving the continuity changes preserve
# Codex's bounded foreground-checkpoint supervision path.
set -u

if [ "${FM_CODEX_LIVE_E2E:-0}" != 1 ]; then
  echo "skip: set FM_CODEX_LIVE_E2E=1 to run the Codex continuity regression"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

fail() {
  printf 'not ok - %s\n' "$1" >&2
  exit 1
}

command -v codex >/dev/null 2>&1 || fail "codex not found"

LAB="$ROOT/.codex-live-e2e.$$"
PROJECT="$LAB/project"
HOME_DIR="$LAB/fmhome"
TRANSCRIPT="$LAB/codex.jsonl"
RESULT="$LAB/harness-depth.result"
CODEX_VERSION=$(codex --version)

cleanup() {
  rm -rf "$LAB"
}
trap cleanup EXIT

mkdir -p "$LAB"
git clone -q "$ROOT" "$PROJECT"
cp "$ROOT/bin/fm-harness.sh" "$PROJECT/bin/fm-harness.sh"
mkdir -p "$HOME_DIR/state" "$HOME_DIR/config"
mkdir -p "$PROJECT/.codex-live-e2e"
cat > "$PROJECT/.codex-live-e2e/harness-depth.sh" <<'SH'
#!/usr/bin/env bash
# Keep real wrapper processes between this leaf and the installed Codex CLI,
# then call the public detector from one more child process.
set -u
n=$1
if [ "$n" -gt 0 ]; then
  bash "$0" "$((n - 1))"
  exit $?
fi
pid=$$
depth=1
codex_depth=
while [ "$depth" -le 24 ]; do
  comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
  case "$(basename -- "$comm")" in
    *codex*) codex_depth=$depth; break ;;
  esac
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
  [ -n "$pid" ] && [ "$pid" -gt 1 ] || break
  depth=$((depth + 1))
done
if [ -z "$codex_depth" ] || [ "$codex_depth" -lt 8 ] || [ "$codex_depth" -gt 15 ]; then
  printf 'CODEX_ANCESTRY_DEPTH_UNUSABLE=%s\n' "${codex_depth:-missing}"
  exit 1
fi
detected=$(FM_HOME="$FM_HOME" FM_ROOT_OVERRIDE="$FM_ROOT_OVERRIDE" \
  "$FM_ROOT_OVERRIDE/bin/fm-harness.sh")
printf 'CODEX_ANCESTRY_DEPTH=%s\nCODEX_ANCESTRY_RESULT=%s\n' "$codex_depth" "$detected"
printf 'CODEX_ANCESTRY_DEPTH=%s\nCODEX_ANCESTRY_RESULT=%s\n' "$codex_depth" "$detected" \
  > "$FM_CODEX_LIVE_RESULT"
SH
# shellcheck disable=SC2016 # Backticks are literal prompt markup.
PROMPT='Run exactly `bash .codex-live-e2e/harness-depth.sh 6` as one foreground shell call. Then run exactly `bin/fm-watch-checkpoint.sh --seconds 1` as a separate foreground shell call. Do not use a background task and do not run fm-watch-arm.sh. After both return, reply briefly.'

(
  cd "$PROJECT" || exit 1
  printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
  FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$PROJECT" FM_CODEX_LIVE_RESULT="$RESULT" codex exec \
    --dangerously-bypass-hook-trust \
    --dangerously-bypass-approvals-and-sandbox \
    --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' \
    --json \
    "$PROMPT"
) > "$TRANSCRIPT" 2>&1 || fail "Codex credentialed checkpoint turn failed: $(tail -20 "$TRANSCRIPT")"

grep -F 'checkpoint: no actionable wake within 1s' "$TRANSCRIPT" >/dev/null \
  || { printf '# Codex transcript tail:\n' >&2; tail -20 "$TRANSCRIPT" >&2; fail "Codex $CODEX_VERSION transcript omitted the real foreground checkpoint result"; }
grep -Fx 'CODEX_ANCESTRY_RESULT=codex' "$RESULT" >/dev/null \
  || fail "Codex $CODEX_VERSION did not detect itself through the wrapped public detector call"
depth=$(sed -n 's/^CODEX_ANCESTRY_DEPTH=\([0-9][0-9]*\)$/\1/p' "$RESULT")
[ -n "$depth" ] && [ "$depth" -ge 8 ] && [ "$depth" -le 15 ] \
  || { printf '# Codex transcript tail:\n' >&2; tail -20 "$TRANSCRIPT" >&2; fail "Codex $CODEX_VERSION live process depth did not exercise the detector's old miss: ${depth:-missing}"; }
if grep -F 'watcher: started pid=' "$TRANSCRIPT" >/dev/null; then
  fail "Codex switched to the background arm path"
fi

printf 'ok - %s detected Codex from wrapped leaf depth %s and preserved the one-second foreground checkpoint path\n' \
  "$CODEX_VERSION" "$depth"
