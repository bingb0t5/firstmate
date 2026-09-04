#!/usr/bin/env bash
# End-to-end demonstration of the dead-worker declared-pause fix, driving the
# REAL bin/fm-watch.sh + bin/fm-wake-drain.sh from a given repo root against a
# tmux-backed pane whose agent has exited.
#
# Usage: dead-worker-pause-demo.sh <repo-root> <label> <scenario>
#   scenario: dead-completed | dead-parked | live-gate | secondmate-held
#
# Prints the captain-facing wake drain after each long-cadence supervision
# round: exactly what firstmate is woken with.
set -u
ROOT=$1; LABEL=$2; SCENARIO=$3
WORK=$(mktemp -d "${TMPDIR:-/tmp}/fm-pause-demo.XXXXXX")
trap 'rm -rf "$WORK"' EXIT
STATE="$WORK/state"; BIN="$WORK/fakebin"
mkdir -p "$STATE" "$BIN"

cat > "$BIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  list-windows) [ -n "${FM_FAKE_TMUX_WINDOW:-}" ] && printf '%s\n' "${FM_FAKE_TMUX_WINDOW#*:}"; exit 0 ;;
  capture-pane) [ -n "${FM_FAKE_TMUX_CAPTURE:-}" ] && cat "$FM_FAKE_TMUX_CAPTURE"; exit 0 ;;
  display-message) case "$*" in *pane_current_command*) printf '%s\n' "${FM_FAKE_TMUX_CURRENT_COMMAND:-}"; exit 0 ;; esac ;;
esac
exit 1
SH
cat > "$BIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
set -u
printf '%s\n' "${FM_FAKE_CREW_STATE:-state: unknown · source: none · fake default}"
SH
chmod +x "$BIN/tmux" "$BIN/fm-crew-state.sh"

file_mtime() { stat -c %Y "$1" 2>/dev/null; }
set_mtime() { touch -t "$(date -d "@$1" +%Y%m%d%H%M.%S)" "$2"; }
seen_sig() { stat -c '%s:%Y' "$1" 2>/dev/null; }
hash_text() { printf '%s' "$1" | md5sum | cut -d' ' -f1; }
reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }
wait_poll_cycle() {
  local pid=$1 limit=${2:-300} beat first now i=0
  beat="$STATE/.last-watcher-beat"; rm -f "$beat"; first=""
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 1
    first=$(file_mtime "$beat"); [ -n "$first" ] && break; sleep 0.1; i=$((i+1)); done
  while [ "$i" -lt "$limit" ]; do kill -0 "$pid" 2>/dev/null || return 1
    now=$(file_mtime "$beat"); [ -n "$now" ] && [ "$now" != "$first" ] && return 0; sleep 0.1; i=$((i+1)); done
  return 1
}

WINDOW="fleet:fm-shipping-lane"
KEY=$(printf '%s' "$WINDOW" | tr ':/.' '___')
PANE="$WORK/pane.txt"
STATUSF="$STATE/shipping-lane.status"

case "$SCENARIO" in
  dead-completed)
    KIND=ship; CURRENT='state: done · source: run-step · run completed'
    PANE_CMD=zsh
    STATUS_LINE='paused: held per captain while an external decision is pending'
    PANE_TEXT='idle bare shell after agent exit' ;;
  dead-parked)
    KIND=ship; CURRENT='state: parked · source: run-step · captain decision pending'
    PANE_CMD=zsh
    STATUS_LINE='paused: waiting on the validation authority gate'
    PANE_TEXT='idle bare shell at parked authority gate' ;;
  live-gate)
    KIND=ship; CURRENT='state: paused · source: status-log · waiting on the upstream vendor release'
    PANE_CMD=claude
    STATUS_LINE='paused: waiting on the upstream vendor release'
    PANE_TEXT='claude worker still resident, awaiting an outside dependency' ;;
  secondmate-held)
    KIND=secondmate; CURRENT='state: unknown · source: none · endpoint liveness deliberately not read'
    PANE_CMD=zsh
    STATUS_LINE='captain-held [key=route]: tracked by held-decision-route'
    PANE_TEXT='secondmate endpoint pane' ;;
  undeclared-stuck)
    KIND=ship; CURRENT='state: working · source: run-step · implementing'
    PANE_CMD=claude
    STATUS_LINE='working: implementing the adapter'
    PANE_TEXT='pane frozen mid-step, no output advancing' ;;
  *) echo "unknown scenario $SCENARIO" >&2; exit 2 ;;
esac

printf '%s\n' "$PANE_TEXT" > "$PANE"
printf 'window=%s\nkind=%s\nharness=grok\nbackend=tmux\n' "$WINDOW" "$KIND" > "$STATE/shipping-lane.meta"
printf '%s\n' "$STATUS_LINE" > "$STATUSF"
set_mtime "$(( $(date +%s) - 500 ))" "$STATUSF"
printf '%s' "$(seen_sig "$STATUSF")" > "$STATE/.seen-shipping-lane_status"
printf '%s' "$(hash_text "$PANE_TEXT")" > "$STATE/.hash-$KEY"
printf '1\n' > "$STATE/.count-$KEY"

echo "############################################################"
echo "# $LABEL"
echo "# scenario : $SCENARIO"
echo "# window   : $WINDOW  (kind=$KIND, backend=tmux)"
echo "# pane     : foreground command '$PANE_CMD'"
echo "# status   : $STATUS_LINE"
echo "# crew     : $CURRENT"
echo "############################################################"

TOTAL=0
for round in 1 2 3 4 5 6; do
  # Age the long-cadence throttle and churn the pane hash: this is the incident
  # condition, each re-arm looked like a fresh stale pane.
  [ -e "$STATE/.paused-resurfaced-$KEY" ] && set_mtime "$(( $(date +%s) - 500 ))" "$STATE/.paused-resurfaced-$KEY"
  printf '%s (cursor blink %s)\n' "$PANE_TEXT" "$round" > "$PANE"
  PATH="$BIN:$PATH" FM_FAKE_TMUX_WINDOW="$WINDOW" FM_FAKE_TMUX_CAPTURE="$PANE" \
    FM_FAKE_TMUX_CURRENT_COMMAND="$PANE_CMD" FM_FAKE_CREW_STATE="$CURRENT" \
    FM_STATE_OVERRIDE="$STATE" FM_CREW_STATE_BIN="$BIN/fm-crew-state.sh" \
    FM_PAUSE_RESURFACE_SECS=240 FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$ROOT/bin/fm-watch.sh" >/dev/null 2>&1 &
  pid=$!
  # Wait for a real classification outcome this round: either the watcher exits
  # on an actionable wake, or it records an absorb in the triage log.
  before=$( { wc -c < "$STATE/.watch-triage.log"; } 2>/dev/null || echo 0)
  i=0
  while [ "$i" -lt 200 ]; do
    kill -0 "$pid" 2>/dev/null || break
    now=$( { wc -c < "$STATE/.watch-triage.log"; } 2>/dev/null || echo 0)
    [ "$now" != "$before" ] && break
    sleep 0.1; i=$((i + 1))
  done
  reap "$pid"

  # What the captain actually sees on this supervision round.
  err="$STATE/.demo-drain.err"
  out=$(FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" 2>"$err" || true)
  rows=$(printf '%s\n' "$out" | awk -F'\t' 'NF>=5 && $1 ~ /^[0-9]+$/' | wc -l | tr -d ' ')
  TOTAL=$((TOTAL + rows))
  printf '\n--- supervision round %s (pane hash changed, %ss past the long cadence) ---\n' "$round" 240
  if [ "$rows" -gt 0 ]; then
    printf '%s\n' "$out" | awk -F'\t' 'NF>=5 && $1 ~ /^[0-9]+$/ {print "  CAPTAIN WOKEN >> " $5}'
  else
    echo "  (no actionable wake: watcher absorbed this round)"
  fi
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation \([A-Za-z0-9._-]*\)$/\1 \2/p' "$err")
  if [ -n "$seq" ]; then
    # shellcheck disable=SC2086
    FM_STATE_OVERRIDE="$STATE" "$ROOT/bin/fm-wake-drain.sh" --ack-through ${seq% *} --recovery-generation ${seq#* } >/dev/null 2>&1 || true
  fi
  rm -f "$err"
done

echo
echo "RESULT [$LABEL / $SCENARIO]: $TOTAL actionable stale wake(s) delivered to the captain over 6 rounds"
wedge="$STATE/.stale-since-$KEY"
if [ -e "$wedge" ]; then
  echo "  wedge detection: ARMED (.stale-since-$KEY present, age $(( $(date +%s) - $(file_mtime "$wedge") ))s)"
else
  echo "  wedge detection: not armed for this lane"
fi
echo "  triage log:"
tail -6 "$STATE/.watch-triage.log" 2>/dev/null | sed 's/^/    /'
echo
