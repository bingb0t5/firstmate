#!/usr/bin/env bash
# tests/fm-wake-queue.test.sh - wake-queue losslessness (the queue safety matrix):
# concurrent append/drain, bounded structural enrichment, interruption safety,
# signal catch-up while no watcher runs, stale/check enqueue-before-suppressor
# ordering, atomic double-drain, duplicate collapse, and liveness assertion.
# Nothing is lost and nothing is double-consumed. General watcher/lock liveness
# lives in fm-watcher-lock.test.sh; daemon classification/injection in
# fm-daemon.test.sh.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"

TMP_ROOT=$(fm_test_tmproot fm-wake-tests)
# shellcheck source=tests/codex-stop-detach-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/codex-stop-detach-helpers.sh"

cleanup_wake_processes() {
  local rc=$?
  trap - EXIT INT TERM
  codex_stop_cleanup_processes "$TMP_ROOT" || exit 1
  fm_test_cleanup
  exit "$rc"
}
trap cleanup_wake_processes EXIT
trap 'exit 130' INT
trap 'exit 143' TERM


test_concurrent_append_and_drain() {
  local dir state out1 out2 pids i pid count unique malformed sequence generation
  dir=$(make_case concurrent)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  pids=
  i=1
  while [ "$i" -le 40 ]; do
    append_wake "$state" signal "status-$i" "signal: $state/status-$i.status" &
    pids="$pids $!"
    i=$((i + 1))
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" &
  pids="$pids $!"
  for pid in $pids; do
    wait "$pid" || fail "concurrent append/drain subprocess failed"
  done
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" 2> "$dir/drain-two.err" || fail "final drain failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out2")
  [ "$count" -eq 40 ] || fail "expected final replay of 40 durable records, got $count"
  malformed=$(awk -F '\t' 'NF && NF != 5 { bad++ } END { print bad + 0 }' "$out2")
  [ "$malformed" -eq 0 ] || fail "drained records had malformed fields"
  unique=$(awk -F '\t' 'NF == 5 { keys[$4] = 1 } END { for (k in keys) count++; print count + 0 }' "$out2")
  [ "$unique" -eq 40 ] || fail "expected 40 unique keys, got $unique"
  [ -s "$state/.wake-queue" ] || fail "concurrent drain consumed records before handling acknowledgement"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain-two.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain-two.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "final replay omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "concurrent records could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged concurrent records remained queued"
  pass "concurrent append plus drain preserves durable records through acknowledgement"
}

test_signal_catchup_without_running_watcher() {
  local dir state fakebin out drain_out drain_err status_file sequence generation
  dir=$(make_case signal)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  drain_err="$dir/drain.err"
  status_file="$state/task.status"
  # The durable-queue catch-up contract applies to ACTIONABLE wakes (the always-on
  # watcher can absorb no-verb working: notes when the crew is provably working).
  # Use a captain-relevant verb so the wake is surfaced and the catch-up path is
  # tested.
  printf 'blocked: first\n' > "$status_file"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for first signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "watcher did not print first signal"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" 2> "$drain_err" || fail "drain after first signal failed"
  grep "$(printf '\tsignal\t')" "$drain_out" | grep -F "$status_file" >/dev/null || fail "first signal was not queued"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$drain_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$drain_err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "first signal handling acknowledgement failed"

  printf 'done: second\n' >> "$status_file"
  : > "$out"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for second signal"
  grep -F "signal: $status_file" "$out" >/dev/null || fail "signal written with no watcher was not caught"
  pass "signal written while no watcher runs is caught on next run"
}

test_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stale"
  printf 'idle prompt' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stale.meta"
  # A stale pane sitting on a captain-relevant status is actionable when the crew
  # is not provably working, so give the window one and prime the .seen-* marker
  # to its current signature so the per-poll signal scan does not pre-empt the
  # stale wake with a signal wake.
  printf 'done: ready in branch fm/stale\n' > "$state/stale.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stale.status"); else sig=$(stat -c '%s:%Y' "$state/stale.status"); fi
  printf '%s' "$sig" > "$state/.seen-stale_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for stale pane"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not written"
  pass "stale wake is queued before suppressor state is advanced"
}

# Absorb-only-when-provably-working adds a new actionable wake: a non-terminal stale
# whose crew is NOT provably working is surfaced immediately. That new path must keep
# the queue-safety invariant - enqueue the stale wake BEFORE advancing the .stale-*
# suppressor - so a watcher killed between the two never swallows the surfaced finish.
test_not_working_stale_enqueue_before_suppressor() {
  local dir state fakebin out drain_out capture_file window key pane_hash sig
  dir=$(make_case stale-stopped)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  capture_file="$dir/pane.txt"
  window="test:fm-stopped"
  printf 'idle prompt, finished' > "$capture_file"
  printf 'window=%s\nkind=ship\n' "$window" > "$state/stopped.meta"
  # Non-terminal status (no captain-relevant verb); prime .seen-* so the per-poll
  # signal scan does not pre-empt the stale path.
  printf 'working: implementing\n' > "$state/stopped.status"
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$state/stopped.status"); else sig=$(stat -c '%s:%Y' "$state/stopped.status"); fi
  printf '%s' "$sig" > "$state/.seen-stopped_status"
  key=$(printf '%s' "$window" | tr ':/.' '___')
  pane_hash=$(hash_text "idle prompt, finished")
  printf '%s' "$pane_hash" > "$state/.hash-$key"
  printf '1\n' > "$state/.count-$key"
  # NOT provably working: no running pipeline, idle pane. (make_case installed the
  # fake fm-crew-state.sh the watcher reads via FM_CREW_STATE_BIN.)
  export FM_FAKE_CREW_STATE='state: unknown · source: none · no current-state source available'
  PATH="$fakebin:$PATH" FM_FAKE_TMUX_WINDOW="$window" FM_FAKE_TMUX_CAPTURE="$capture_file" \
    FM_STATE_OVERRIDE="$state" FM_CREW_STATE_BIN="$fakebin/fm-crew-state.sh" \
    FM_STALE_ESCALATE_SECS=999 FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not surface a not-provably-working stale"
  grep -Fx "stale: $window" "$out" >/dev/null || fail "watcher did not print the immediate stale wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after the immediate stale wake failed"
  grep "$(printf '\tstale\t')" "$drain_out" | grep -F "$window" >/dev/null || fail "immediate stale wake was not queued"
  [ "$(cat "$state/.stale-$key" 2>/dev/null || true)" = "$pane_hash" ] || fail "stale suppressor was not advanced after the enqueue"
  unset FM_FAKE_CREW_STATE
  pass "a not-provably-working stale wake is queued before its suppressor is advanced"
}

test_check_output_is_queued() {
  local dir state fakebin out drain_out check_file
  dir=$(make_case check)
  state="$dir/state"
  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  drain_out="$dir/drain.out"
  check_file="$state/task.check.sh"
  printf '%s\n' fm-pr-check-migration-scan-v1 > "$state/.pr-check-migration-scan-v1"
  printf '%s\n' fm-pr-check-migration-v1 > "$state/.pr-check-migration-v1"
  chmod 0600 "$state/.pr-check-migration-scan-v1" "$state/.pr-check-migration-v1"
  cat > "$check_file" <<'SH'
#!/usr/bin/env bash
printf 'merged: https://example.test/pr/1\n'
SH
  chmod 0700 "$check_file"
  FM_STATE_OVERRIDE="$state" "$ROOT/bin/fm-check-register.sh" task >/dev/null \
    || fail "could not register queue custom check"
  PATH="$fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=0 FM_HEARTBEAT=999999 "$WATCH" > "$out" &
  wait_for_exit "$!" 40 || fail "watcher did not exit for check output"
  grep -F "check: $check_file: merged: https://example.test/pr/1" "$out" >/dev/null || fail "watcher did not print check wake"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$drain_out" || fail "drain after check wake failed"
  grep "$(printf '\tcheck\t')" "$drain_out" | grep -F "$check_file" | grep -F 'merged: https://example.test/pr/1' >/dev/null || fail "check wake was not queued"
  [ -e "$state/.last-check" ] || fail "check cadence marker was not written after queue append"
  pass "registered custom check output is queued before cadence suppression"
}

test_atomic_double_drain() {
  local dir state out1 out2 count1 count2 sequence generation leftover
  dir=$(make_case double-drain)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat append failed"
  append_wake "$state" signal task "signal: $state/task.status" || fail "signal append failed"
  append_wake "$state" stale 's:fm-task' 'stale: s:fm-task' || fail "stale append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out1" 2> "$dir/drain-one.err" &
  pid1=$!
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" 2> "$dir/drain-two.err" &
  pid2=$!
  wait "$pid1" || fail "first drain failed"
  wait "$pid2" || fail "second drain failed"
  count1=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out1")
  count2=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out2")
  [ "$count1" -eq 3 ] && [ "$count2" -eq 3 ] \
    || fail "unacknowledged concurrent drains did not replay all three records"
  cmp -s "$out1" "$out2" || fail "concurrent pre-ack replays were not deterministic"
  [ -s "$state/.wake-queue" ] || fail "concurrent drains consumed records before acknowledgement"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/drain-two.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/drain-two.err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "concurrent replay omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "concurrent replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement did not consume replayed records"
  leftover=$(FM_STATE_OVERRIDE="$state" "$DRAIN" | awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }')
  [ "$leftover" -eq 0 ] || fail "acknowledged records replayed again"
  pass "concurrent drains replay until one post-handling acknowledgement consumes records"
}

test_drain_dedupes_obvious_duplicates() {
  local dir state out count
  dir=$(make_case dedupe)
  state="$dir/state"
  out="$dir/drain.out"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "first heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status" || fail "first signal append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "second heartbeat append failed"
  append_wake "$state" signal task.status "signal: $state/task.status $state/task.turn-ended" || fail "second signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" || fail "dedupe drain failed"
  count=$(awk 'NF { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 2 ] || fail "expected 2 deduped records, got $count"
  grep "$(printf '\theartbeat\theartbeat\theartbeat')" "$out" >/dev/null || fail "heartbeat was not preserved"
  grep "$(printf '\tsignal\ttask.status\t')" "$out" | grep -F "$state/task.turn-ended" >/dev/null || fail "latest signal payload was not preserved"
  pass "drain collapses obvious duplicate heartbeat and signal records"
}

# The drain runs at the top of every wake-handling turn, so it also asserts
# watcher liveness via fm-guard.sh: a lapsed re-arm chain then surfaces even on a
# plain drain-and-handle turn that runs no other supervision script. It must warn
# when work is in flight with no live watcher, and stay silent right after a
# normal fire from a live watcher with a fresh beacon, so it never false-alarms.
test_secondmate_foreign_queue_stall_is_one_shot_and_read_only() {
  local dir state sub fakebin out row_before row_after stall_count
  dir=$(make_case secondmate-foreign-stall)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state" "$sub/data" "$sub/bin"
  printf '# Firstmate\n' > "$sub/AGENTS.md"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" > "$sub/state/.wake-queue"
  row_before="$dir/foreign-before"
  row_after="$dir/foreign-after"
  cp "$sub/state/.wake-queue" "$row_before"
  fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' "${FM_FAKE_TMUX_WINDOW:-}" ;;
  capture-pane) cat "${FM_FAKE_TMUX_CAPTURE:-/dev/null}" ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"
  out="$dir/watch.out"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 3 > "$out" 2> "$dir/watch.err" || true
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$out" >/dev/null \
    || fail "an aged foreign row did not wake the parent checkpoint: $(cat "$out"); err=$(cat "$dir/watch.err"); meta=$(cat "$state/mate.meta"); foreign=$(cat "$sub/state/.wake-queue")"
  [ -s "$state/.wake-queue" ] || fail "the parent notification was not durable"
  stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
  [ "$stall_count" -eq 1 ] || fail "the first parent checkpoint did not publish exactly one stall notification"

  cmp -s "$row_before" "$sub/state/.wake-queue" \
    || fail "foreign queue row changed during read-only stall detection"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "parent drain failed after the stall notification"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "parent stall notification could not be acknowledged"

  sleep 1
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$dir/watch-second.out" 2> "$dir/watch-second.err" || true
  [ ! -s "$state/.wake-queue" ] || {
    stall_count=$(grep -c 'secondmate-wake-loop-mate-' "$state/.wake-queue" || true)
    [ "$stall_count" -eq 0 ] || fail "repeated checkpoint re-published the same stall notification"
  }
  cp "$sub/state/.wake-queue" "$row_after"
  cmp -s "$row_before" "$row_after" || fail "foreign queue changed after idempotent re-check"

  : > "$sub/state/.wake-queue"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$dir/watch-empty.out" 2> "$dir/watch-empty.err" || true
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-empty.out" >/dev/null \
    || fail "an empty foreign queue produced a stall notification"

  printf '%s\t8\tcheck\thealthy\tcheck: healthy row\n' "$(date +%s)" > "$sub/state/.wake-queue"
  touch "$sub/state/.last-watcher-beat"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=60 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$dir/watch-healthy.out" 2> "$dir/watch-healthy.err" || true
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch-healthy.out" >/dev/null \
    || fail "a healthy foreign queue produced a stall notification"
  pass "foreign secondmate queue stalls notify once, remain byte-stable, and stay quiet when empty or healthy"
}

# Declared pause rechecks are expected parked work for a secondmate's own
# supervisor. When a mate is busy validating another lane, several such rows can
# accumulate before it can drain them. Before the parent-side filter, each newly
# aged row produced another parent wake-loop warning, even though the rows were
# deliberate long-cadence rechecks. Keep a genuine wedge and a captain-held gate
# in the same queue to prove the filter does not turn the guard off wholesale.
test_secondmate_parked_pause_rechecks_do_not_flood_parent() {
  local dir state sub fakebin out foreign_before now i round
  dir=$(make_case secondmate-parked-rechecks)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  printf 'working: validating another lane\n' > "$state/mate.status"
  prime_status_seen "$state" "$state/mate.status" \
    || fail "could not prime the busy secondmate status signal"
  now=$(( $(date +%s) - 600 ))
  : > "$sub/state/.wake-queue"
  i=1
  while [ "$i" -le 4 ]; do
    printf '%s\t%s\tstale\tfirstmate:fm-parked-%s\tstale: firstmate:fm-parked-%s (paused 3600s, awaiting external - declared pause, rechecked on a long cadence not a wedge; confirm the wait still holds)\n' \
      "$((now - i))" "$i" "$i" "$i" >> "$sub/state/.wake-queue"
    i=$((i + 1))
  done
  fakebin="$dir/fakebin"
  out="$dir/watch.out"

  round=1
  while [ "$round" -le 4 ]; do
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
      FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$out" 2> "$dir/watch-$round.err" || true
    if grep -F 'secondmate wake-loop stalled' "$out" >/dev/null; then
      fail "parked recheck round $round produced a false parent stall warning: $(cat "$out")"
    fi
    [ ! -s "$state/.wake-queue" ] \
      || fail "parked recheck round $round published a false parent wake"
    round=$((round + 1))
  done

  printf '%s\t5\tstale\tfirstmate:fm-wedge-lane\tstale: firstmate:fm-wedge-lane (idle 600s, possible wedge, escalation 1)\n' \
    "$now" >> "$sub/state/.wake-queue"
  printf '%s\t6\tstale\tfirstmate:fm-captain-gate\tstale: firstmate:fm-captain-gate (captain-held 600s, awaiting the captain - verified hold transfer, rechecked on a long cadence not a wedge; answer the held decision or release the hold)\n' \
    "$now" >> "$sub/state/.wake-queue"
  foreign_before="$dir/foreign-before"
  cp "$sub/state/.wake-queue" "$foreign_before"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$out" 2> "$dir/wedge.err" || true
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=5 age=' "$out" >/dev/null \
    || fail "a genuine wedge row behind parked rechecks was skipped: $(cat "$out")"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/wedge-drain.out" 2> "$dir/wedge.err" \
    || fail "the genuine wedge notification could not be drained"
  ack_drain_err "$state" "$dir/wedge.err" \
    || fail "the genuine wedge notification could not be acknowledged"
  cmp -s "$foreign_before" "$sub/state/.wake-queue" \
    || fail "parent observation changed the foreign queue while reporting the wedge"
  awk -F '\t' '$2 != 5' "$sub/state/.wake-queue" > "$dir/foreign-after-wedge" \
    || fail "could not model the mate draining the handled wedge row"
  mv "$dir/foreign-after-wedge" "$sub/state/.wake-queue"
  cp "$sub/state/.wake-queue" "$foreign_before"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$out" 2> "$dir/gate.err" || true
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=6 age=' "$out" >/dev/null \
    || fail "a captain-held decision row behind parked rechecks was skipped: $(cat "$out")"
  cmp -s "$foreign_before" "$sub/state/.wake-queue" \
    || fail "parent stall observation changed the secondmate foreign queue"
  pass "parked pause rechecks stay quiet while genuine wedges and captain-held gates still reach the parent"
}

test_secondmate_stall_marker_rejects_symlink() {
  local dir state sub fakebin marker outside expected
  dir=$(make_case secondmate-stall-marker-symlink)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nhome=%s\n' "$sub" > "$state/mate.meta"
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - 10 ))" > "$sub/state/.wake-queue"
  outside="$dir/outside"
  expected='must remain unchanged'
  printf '%s\n' "$expected" > "$outside"
  marker="$state/.secondmate-wake-stall-mate"
  ln -s "$outside" "$marker"
  fakebin="$dir/fakebin"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  list-windows) printf '%s\n' 'firstmate:fm-mate' ;;
  capture-pane) : ;;
  display-message) printf '0\n' ;;
  *) exit 0 ;;
esac
SH
  chmod +x "$fakebin/tmux"

  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 \
    FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 \
    > "$dir/watch.out" 2> "$dir/watch.err" || true
  [ "$(cat "$outside")" = "$expected" ] || fail "stall marker write followed an unsafe symlink"
  [ -L "$marker" ] || fail "stall marker write replaced rather than rejected an unsafe path"
  [ ! -s "$state/.wake-queue" ] || fail "unsafe stall marker path still published a parent notification"
  pass "secondmate stall markers reject symlinks without touching their targets"
}

test_acknowledged_stall_publication_survives_pre_marker_crash() {
  local dir state sub fakebin out epoch row_before
  dir=$(make_case secondmate-stall-crash)
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state" "$sub/data"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=firstmate:fm-mate\nkind=secondmate\nharness=claude\nbackend=tmux\nhome=%s\n' \
    "$sub" > "$state/mate.meta"
  epoch=$(( $(date +%s) - 10 ))
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$sub/state/.wake-queue"
  row_before="$dir/foreign-before"
  cp "$sub/state/.wake-queue" "$row_before"
  append_wake "$state" check "secondmate-wake-loop-mate-$epoch-7" \
    "check: secondmate wake-loop stalled: mate=mate row=7 age=10s" \
    || fail "could not seed the pre-marker crash publication"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "pre-marker crash publication could not be drained"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "pre-marker crash publication could not be acknowledged"

  fakebin="$dir/fakebin"
  out="$dir/watch.out"
  PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 > "$out" 2> "$dir/watch.err" || true
  ! grep -F 'secondmate wake-loop stalled' "$out" >/dev/null \
    || fail "an acknowledged publication was duplicated after the pre-marker crash state"
  [ ! -s "$state/.wake-queue" ] \
    || fail "the replacement watcher re-published an acknowledged stall notification"
  cmp -s "$row_before" "$sub/state/.wake-queue" \
    || fail "pre-marker crash recovery changed the foreign queue row"
  pass "stall publication acknowledgement closes the pre-marker crash window"
}

test_empty_prefix_mate_preserves_other_mate_receipt() {
  local dir state empty stalled fakebin epoch row_before round
  dir=$(make_case secondmate-prefix-receipt)
  state="$dir/state"
  empty="$dir/ios"
  stalled="$dir/ios-ui"
  mkdir -p "$empty/state" "$stalled/state"
  printf 'ios\n' > "$empty/.fm-secondmate-home"
  printf 'ios-ui\n' > "$stalled/.fm-secondmate-home"
  printf 'window=firstmate:fm-ios\nkind=secondmate\nhome=%s\n' "$empty" > "$state/ios.meta"
  printf 'window=firstmate:fm-ios-ui\nkind=secondmate\nhome=%s\n' "$stalled" > "$state/ios-ui.meta"
  : > "$empty/state/.wake-queue"
  epoch=$(( $(date +%s) - 10 ))
  printf '%s\t9\tcheck\trouted\tcheck: routed row\n' "$epoch" > "$stalled/state/.wake-queue"
  row_before="$dir/foreign-before"
  cp "$stalled/state/.wake-queue" "$row_before"
  append_wake "$state" check "secondmate-wake-loop-ios-ui-$epoch-9" \
    "check: secondmate wake-loop stalled: mate=ios-ui row=9 age=10s" \
    || fail "could not seed the ios-ui stall publication"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err" \
    || fail "ios-ui stall publication could not be drained"
  ack_drain_err "$state" "$dir/drain.err" \
    || fail "ios-ui stall publication could not be acknowledged"

  fakebin="$dir/fakebin"
  round=1
  while [ "$round" -le 2 ]; do
    PATH="$fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$state" FM_FAKE_TMUX_WINDOW='' \
      FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
      FM_SECONDMATE_WAKE_STALL_SECS=1 FM_POLL=1 FM_SIGNAL_GRACE=0 \
      FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 \
      > "$dir/watch-$round.out" 2> "$dir/watch-$round.err" || true
    ! grep -F 'secondmate wake-loop stalled' "$dir/watch-$round.out" >/dev/null \
      || fail "empty ios queue erased ios-ui idempotency on checkpoint $round"
    round=$((round + 1))
  done
  [ ! -s "$state/.wake-queue" ] \
    || fail "overlapping mate ids re-published the acknowledged ios-ui stall"
  cmp -s "$row_before" "$stalled/state/.wake-queue" \
    || fail "overlapping mate receipt checks changed the foreign row"
  pass "empty prefix mate cleanup preserves another mate's stall receipt"
}

set_mtime() {  # <epoch> <file>
  local epoch=$1 f=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$f"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$f"
  fi
}

write_live_branch_owner() {  # <home>
  local home=$1 identity
  identity=$(fm_test_pid_identity $$) || return 1
  printf '%s\n%s\n%s\n%s\n' fm-branch-eligible-owner-v1 "$$" "$identity" "gen1" \
    > "$home/state/.branch-eligible-owner"
}

make_cadence_stall_case() {  # <name> <harness> <age-secs> [<backend> <target>] -> prints dir
  local name=$1 harness=$2 age=$3 backend=${4:-tmux} target=${5:-firstmate:fm-mate} dir state sub
  dir=$(make_case "$name")
  state="$dir/state"
  sub="$dir/secondmate"
  mkdir -p "$sub/state" "$dir/fake-tmux"
  printf 'mate\n' > "$sub/.fm-secondmate-home"
  printf 'window=%s\nkind=secondmate\nharness=%s\nbackend=%s\nhome=%s\n' \
    "$target" "$harness" "$backend" "$sub" > "$state/mate.meta"
  printf '%s\t7\tcheck\trouted\tcheck: routed row\n' "$(( $(date +%s) - age ))" \
    > "$sub/state/.wake-queue"
  printf '%s\n' "$dir"
}

run_cadence_stall_checkpoint() {  # <dir> <out-name>
  local dir=$1 out_name=$2
  mkdir -p "$dir/fake-tmux"
  env -u FM_SECONDMATE_WAKE_STALL_SECS \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 \
    > "$dir/$out_name.out" 2> "$dir/$out_name.err" || true
}

run_cadence_stall_checkpoint_override() {  # <dir> <out-name> <override>
  local dir=$1 out_name=$2 override=$3
  mkdir -p "$dir/fake-tmux"
  FM_SECONDMATE_WAKE_STALL_SECS=$override \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$dir/state" FM_FAKE_TMUX_WINDOW='firstmate:fm-mate' \
    FM_FAKE_TMUX_LOG="$dir/tmux.log" FM_FAKE_TMUX_CAPTURE="$dir/fake-tmux/pane.txt" \
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    "$ROOT/bin/fm-watch-checkpoint.sh" --seconds 2 \
    > "$dir/$out_name.out" 2> "$dir/$out_name.err" || true
}

make_fake_herdr_agent_state() {  # <dir>
  local dir=$1
  cat > "$dir/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
if [ -n "${FM_FAKE_TMUX_LOG:-}" ]; then
  {
    printf 'herdr'
    for arg in "$@"; do printf '\x1f%s' "$arg"; done
    printf '\n'
  } >> "$FM_FAKE_TMUX_LOG"
fi
case "${1:-} ${2:-}" in
  'status --json')
    printf '%s\n' '{"client":{"version":"0.8.2","protocol":19},"server":{"running":true}}'
    ;;
  'agent get')
    printf '{"result":{"agent":{"agent_status":"%s"}}}\n' "${FM_FAKE_HERDR_AGENT_STATUS:-idle}"
    ;;
  *)
    :
    ;;
esac
SH
  chmod +x "$dir/fakebin/herdr"
}

test_codex_busy_secondmate_row_stays_quiet() {
  local dir sub
  dir=$(make_cadence_stall_case codex-busy-row codex 900 herdr default:w1:p2)
  sub="$dir/secondmate"
  make_fake_herdr_agent_state "$dir"
  printf 'Ctrl+c:cancel\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  export FM_FAKE_HERDR_AGENT_STATUS=working
  run_cadence_stall_checkpoint "$dir" watch
  unset FM_FAKE_HERDR_AGENT_STATUS
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch.out" >/dev/null \
    || fail "a busy Codex secondmate row paged the parent: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "a busy Codex secondmate row published a parent stall"
  grep -F $'agent\x1fget\x1fw1:p2' "$dir/tmux.log" >/dev/null 2>&1 \
    || fail "the busy Codex case did not use the recorded Herdr backend-state path: $(cat "$dir/tmux.log" 2>/dev/null)"
  pass "a busy Codex secondmate keeps an aged row quiet while its beacon is fresh"
}

test_codex_busy_stale_beacon_still_pages() {
  local dir sub
  dir=$(make_cadence_stall_case codex-busy-stale codex 1 herdr default:w1:p2)
  sub="$dir/secondmate"
  make_fake_herdr_agent_state "$dir"
  printf 'Ctrl+c:cancel\n' > "$dir/fake-tmux/pane.txt"
  export FM_FAKE_HERDR_AGENT_STATUS=working
  run_cadence_stall_checkpoint "$dir" stale
  unset FM_FAKE_HERDR_AGENT_STATUS
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/stale.out" >/dev/null \
    || fail "a stale-beacon busy Codex row did not page immediately: $(cat "$dir/stale.out"); err=$(cat "$dir/stale.err")"
  pass "a stale beacon still pages immediately even when the recorded Codex state is busy"
}

test_codex_idle_secondmate_uses_idle_cadence_plus_grace() {
  local dir sub
  dir=$(make_cadence_stall_case codex-idle-under codex 620 herdr default:w1:p2)
  sub="$dir/secondmate"
  make_fake_herdr_agent_state "$dir"
  printf 'Ctrl+c:cancel\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" under
  ! grep -F 'secondmate wake-loop stalled' "$dir/under.out" >/dev/null \
    || fail "an idle Codex row paged before the 600-second cadence plus grace"
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "an idle Codex row published a parent stall before the cadence plus grace"

  dir=$(make_cadence_stall_case codex-idle-over codex 640 herdr default:w1:p2)
  sub="$dir/secondmate"
  make_fake_herdr_agent_state "$dir"
  printf 'Ctrl+c:cancel\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" over
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/over.out" >/dev/null \
    || fail "an idle Codex row did not page after the 600-second cadence plus grace: $(cat "$dir/over.out"); err=$(cat "$dir/over.err")"
  pass "an idle Codex secondmate pages only after the 600-second cadence plus grace"
}

test_secondmate_stall_override_precedes_busy_state() {
  local dir sub
  dir=$(make_cadence_stall_case codex-override codex 120 herdr default:w1:p2)
  sub="$dir/secondmate"
  make_fake_herdr_agent_state "$dir"
  mkdir -p "$dir/config"
  printf '# file defaults must not override an explicit environment value\nFM_SECONDMATE_WAKE_STALL_SECS=999\n' > "$dir/config/watch.env"
  printf 'Ctrl+c:cancel\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  export FM_FAKE_HERDR_AGENT_STATUS=working
  run_cadence_stall_checkpoint_override "$dir" watch 1
  unset FM_FAKE_HERDR_AGENT_STATUS
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch.out" >/dev/null \
    || fail "the explicit stall override was suppressed by a busy backend state: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  pass "the explicit secondmate stall override retains precedence over busy state"
}

test_secondmate_watch_env_default_is_loaded_safely() {
  local dir sub
  dir=$(make_cadence_stall_case codex-watch-env codex 120 herdr default:w1:p2)
  sub="$dir/secondmate"
  make_fake_herdr_agent_state "$dir"
  mkdir -p "$dir/config"
  printf "FM_SECONDMATE_WAKE_STALL_SECS=1\nFM_EVIL=\$(touch %s/ran)\n" "$dir" > "$dir/config/watch.env"
  printf 'Ctrl+c:cancel\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" watch
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch.out" >/dev/null \
    || fail "watch.env did not provide the watcher default: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  [ ! -e "$dir/ran" ] || fail "watch.env was executed as shell instead of parsed as data"
  pass "watch.env supplies safe watcher defaults while explicit environment values retain precedence"
}

test_watch_env_rejects_arithmetic_execution() {
  local dir state pid i
  dir=$(make_case watch-env-arithmetic)
  state="$dir/state"
  mkdir -p "$dir/config"
  printf "FM_ARM_CONFIRM_TIMEOUT='a[\$(touch %s/arm-executed)]'\nFM_HEARTBEAT='a[\$(touch %s/heartbeat-executed)]'\nFM_POLL=1\n" \
    "$dir" "$dir" > "$dir/config/watch.env"
  env -u FM_ARM_CONFIRM_TIMEOUT -u FM_HEARTBEAT \
    PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$state" FM_CONFIG_OVERRIDE="$dir/config" \
    "$ROOT/bin/fm-watch-arm.sh" > "$dir/arm.out" 2> "$dir/arm.err" &
  pid=$!
  for i in $(seq 1 100); do
    grep -q 'watcher: started' "$dir/arm.out" && break
    sleep 0.1
  done
  grep -q 'watcher: started' "$dir/arm.out" \
    || { kill "$pid" 2>/dev/null; fail "malformed numeric defaults prevented arm startup: $(cat "$dir/arm.err")"; }
  sleep 2
  append_wake "$state" check numeric-safe 'check: numeric defaults safely consumed'
  wait_for_exit "$pid" 40 || fail "arm failed to deliver after rejecting numeric payloads"
  [ ! -e "$dir/arm-executed" ] && [ ! -e "$dir/heartbeat-executed" ] \
    || fail "watch.env numeric input executed through watcher arithmetic"
  grep -qF 'check: rearm-resurface' "$dir/arm.out" \
    || fail "arm did not signal the queued wake"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"
  grep -qF 'check: numeric defaults safely consumed' "$dir/drain.out" \
    || fail "queued wake did not reach the handling interface"
  printf 'FM_HEARTBEAT=0008\nFM_ARM_ATTACH_POLL=0.25\nFM_BACKEND=herdr\n' > "$dir/config/watch.env"
  bash -c '
    . "$1"
    unset FM_HEARTBEAT FM_ARM_ATTACH_POLL FM_BACKEND
    fm_watch_config_load "$2"
    [ "${FM_HEARTBEAT-unset}" = unset ] && [ "$FM_ARM_ATTACH_POLL" = 0.25 ] && [ "${FM_BACKEND-unset}" = unset ]
  ' _ "$ROOT/bin/fm-watch-config-lib.sh" "$dir/config/watch.env" \
    || fail "numeric watch defaults accepted octal or an unrelated setting"
  pass "real arm and watcher reject executable numeric defaults and preserve supported decimal pins"
}

test_busy_grok_pi_and_live_branch_keep_their_cadence() {
  local dir sub harness
  for harness in grok pi pi-signed codex; do
    dir=$(make_cadence_stall_case "busy-cadence-$harness" "$harness" 400 herdr default:w1:p2)
    sub="$dir/secondmate"
    make_fake_herdr_agent_state "$dir"
    printf 'Ctrl+c:cancel\n' > "$dir/fake-tmux/pane.txt"
    touch "$sub/state/.last-watcher-beat"
    if [ "$harness" = codex ]; then
      write_live_branch_owner "$sub" || fail "could not record live Pi branch ownership"
    fi
    FM_FAKE_HERDR_AGENT_STATUS=working run_cadence_stall_checkpoint "$dir" watch
    grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch.out" >/dev/null \
      || fail "busy $harness bypassed its Grok/Pi cadence: $(cat "$dir/watch.out")"
  done
  pass "busy Grok, Pi, pi-signed, and live branch grants retain their cadence"
}

test_codex_secondmate_stop_arms_and_self_wakes() {
  local dir state cycle rc
  dir=$(make_case codex-secondmate-stop)
  state="$dir/state"
  mkdir -p "$dir/.codex"
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  cp "$(command -v bash)" "$dir/codex"
  # shellcheck disable=SC2016 # PATH expands when the child shell reads BASH_ENV.
  printf 'export PATH=%q:"$PATH"\n' "$dir/fakebin" > "$dir/bash-env"
  ln -s "$ROOT/bin" "$dir/bin"
  : > "$dir/AGENTS.md"
  printf 'mate\n' > "$dir/.fm-secondmate-home"
  # End-user reproduction: a row can already be aged in the secondmate home's
  # queue when Codex reaches its turn boundary. The Stop-owned arm must wake the
  # idle home from that durable row before any parent-side stall observation is
  # involved.
  append_wake "$state" check preexisting-home-row 'check: pre-existing idle home row' \
    || fail "could not seed the secondmate home's pre-existing queue row"
  run_codex_stop_case "$dir" false
  rc=$?
  [ "$rc" -eq 2 ] || fail "an idle Codex secondmate did not wake for its pre-existing home row: rc=$rc $(cat "$dir/stop.err")"
  grep -qF 'check: rearm-resurface' "$dir/stop.err" \
    || fail "the pre-existing home row did not traverse the Stop-owned arm: $(cat "$dir/stop.err")"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/prequeue-drain.out" 2> "$dir/prequeue-drain.err" \
    || fail "could not drain the pre-existing secondmate home row"
  grep -qF 'check: pre-existing idle home row' "$dir/prequeue-drain.out" \
    || fail "the pre-existing home row did not reach the handling interface"
  ack_drain_err "$state" "$dir/prequeue-drain.err" \
    || fail "could not acknowledge the pre-existing secondmate home row"
  [ ! -s "$state/.wake-queue" ] || fail "the pre-existing home row remained after acknowledgement"
  for cycle in 1 2; do
    append_wake "$state" check "home-row-$cycle" "check: idle home row $cycle" \
      || fail "could not queue home work before Stop"
    FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
      run_codex_stop_case "$dir" true
    rc=$?
    [ ! -e "$state/mate.turn-ended" ] || fail "primary Stop published a child marker"
    [ "$rc" = 2 ] || fail "Stop did not request a handling turn: rc=$rc $(cat "$dir/stop.err")"
    grep -qF 'check: rearm-resurface' "$dir/stop.err" \
      || fail "Stop feedback omitted the queued home wake notification: $(cat "$dir/stop.err")"
    [ -s "$state/.wake-queue" ] || fail "Stop consumed the wake before handling acknowledgement"
    printf 'kind=ship\n' > "$state/child.meta"
    # shellcheck disable=SC2016 # The child shell evaluates the command and exit status.
    env -u FM_SUPERVISION_MODEL -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" \
      "$dir/codex" -c '"$1"; rc=$?; exit "$rc"' _ "$DRAIN" > "$dir/drain.out" 2> "$dir/drain.err"
    ! grep -qF 'WATCHER DOWN' "$dir/drain.err" || fail "successful Stop wake falsely paged watcher-down with active child work"
    grep -qF "check: idle home row $cycle" "$dir/drain.out" \
      || fail "home wake did not reach the handling interface"
    ack_drain_err "$state" "$dir/drain.err" || fail "home wake acknowledgement failed"
    [ ! -s "$state/.wake-queue" ] || fail "acknowledged home wake remained queued"
  done
  set_mtime "$(( $(date +%s) - 400 ))" "$state/.last-watcher-beat"
  # shellcheck disable=SC2016 # The child shell evaluates the command and exit status.
  env -u FM_SUPERVISION_MODEL -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" \
    "$dir/codex" -c '"$1"; rc=$?; exit "$rc"' _ "$DRAIN" > "$dir/stale.out" 2> "$dir/stale.err"
  grep -qF 'WATCHER DOWN' "$dir/stale.err" || fail "marked Codex home hid a stale beacon"
  touch "$state/.last-watcher-beat"
  mv "$dir/.fm-secondmate-home" "$dir/marker.saved"
  # shellcheck disable=SC2016 # The child shell evaluates the command and exit status.
  env -u FM_SUPERVISION_MODEL -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" \
    "$dir/codex" -c '"$1"; rc=$?; exit "$rc"' _ "$DRAIN" > "$dir/unmarked.out" 2> "$dir/unmarked.err"
  grep -qF 'WATCHER DOWN' "$dir/unmarked.err" || fail "unmarked Codex home lost its persistent watcher requirement"
  pass "Codex Stop self-wakes remain healthy with active work, while stale and unmarked homes still alarm"
}

make_codex_linked_stale_stop_case() {
  local name=$1 base dir entry stop stale
  base=$(make_case "$name-base")
  dir="$TMP_ROOT/$name-home"
  fm_git_worktree "$base" "$dir" "fm/$name-home"
  mkdir -p "$dir/state" "$dir/fakebin" "$dir/bin" "$dir/.codex"
  cp -R "$base/fakebin/." "$dir/fakebin/"
  for entry in "$ROOT/bin/"*; do
    ln -s "$entry" "$dir/bin/${entry##*/}"
  done
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$dir/.codex/hooks.json")
  stale=${stop/ --codex/}
  [ "$stale" != "$stop" ] || fail "current Codex hook did not carry the explicit mode"
  if ! jq --arg command "$stale" '.hooks.Stop[0].hooks[0] |= (.command = $command | .timeout = 30)' \
    "$dir/.codex/hooks.json" > "$dir/.codex/hooks.json.tmp" ||
    ! mv "$dir/.codex/hooks.json.tmp" "$dir/.codex/hooks.json"; then
    fail "could not install the pre-PR40 Stop command"
  fi
  cp "$(command -v bash)" "$dir/codex"
  # shellcheck disable=SC2016 # PATH expands when the child shell reads BASH_ENV.
  printf 'export PATH=%q:"$PATH"\n' "$dir/fakebin" > "$dir/bash-env"
  : > "$dir/AGENTS.md"
  printf 'mate\n' > "$dir/.fm-secondmate-home"
  printf '%s\n' "$dir"
}

test_codex_stale_hook_linked_secondmate_rearms_and_preserves_wake() {
  local dir state gd gcd rc
  dir=$(make_codex_linked_stale_stop_case codex-stale-linked)
  state="$dir/state"
  gd=$(git -C "$dir" rev-parse --git-dir)
  gcd=$(git -C "$dir" rev-parse --git-common-dir)
  [ "$gd" != "$gcd" ] || fail "stale-hook fixture must be a linked worktree"
  append_wake "$state" check stale-home-row 'check: stale-hook home row' \
    || fail "could not seed the stale-hook home row"

  run_codex_stop_case "$dir" false
  rc=$?
  [ "$rc" -eq 2 ] || fail "stale Codex Stop did not re-arm the linked secondmate home: rc=$rc $(cat "$dir/stop.err")"
  grep -qF 'check: rearm-resurface' "$dir/stop.err" \
    || fail "stale Codex Stop did not foreground the home watcher: $(cat "$dir/stop.err")"
  [ -s "$state/.wake-queue" ] || fail "stale Codex Stop consumed the durable home wake"
  [ ! -e "$state/mate.turn-ended" ] || fail "stale Codex Stop published a child-task marker"
  pass "stale Codex Stop command re-arms a linked secondmate home and preserves its durable wake"
}

test_codex_stale_hook_hands_off_before_deadline_for_delayed_wake() {
  local dir rc scenario=${1:-empty}
  dir=$(make_codex_linked_stale_stop_case "codex-stale-deadline-$scenario")
  # Keep the 35-second delivery beyond the cached Stop deadline, but poll fast
  # enough that the attached arm's successor grace fits the 50-second test wait.
  (
    cd "$dir" || exit 1
    FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_CONFIG_OVERRIDE="$dir/config" BASH_ENV="$dir/bash-env" FM_TEST_WATCHER_SCENARIO="$scenario" \
      FM_POLL=1 \
      "$dir/codex" -s > "$dir/delayed.out" 2> "$dir/delayed.err" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
python3 - <<'PY'
import atexit
import concurrent.futures
import json
import os
from pathlib import Path
import re
import shlex
import signal
import subprocess
import time

home = Path.cwd()
state = home / "state"
hook = json.loads((home / ".codex/hooks.json").read_text())["hooks"]["Stop"][0]["hooks"][0]
assert hook["timeout"] == 30, "fixture must enforce the cached timeout"
queue = state / ".wake-queue"
assert not queue.exists() or not queue.read_bytes(), "fixture must start with an empty queue"
existing = None
transcript = os.environ.get("FM_TEST_TRANSCRIPT") == "1"

def record(label, value):
    if transcript:
        print(f"{label}: {value}", flush=True)

def run(command, seconds, payload=None):
    began = time.monotonic()
    child = subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                             stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = child.communicate(payload, timeout=seconds)
    except BaseException:
        os.killpg(child.pid, signal.SIGTERM)
        try:
            child.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(child.pid, signal.SIGKILL)
            child.communicate()
        raise
    record("command", shlex.join(command))
    record("result", f"exit={child.returncode} elapsed={time.monotonic() - began:.2f}s")
    if out:
        record("stdout", out.rstrip())
    if err:
        record("stderr", err.rstrip())
    return child.returncode, out, err

def watcher_healthy():
    rc, _, _ = run(["bash", "-c", '. bin/fm-wake-lib.sh; fm_watcher_healthy "$STATE" "$FM_HOME/bin/fm-watch.sh" 300 "$FM_HOME"'], 5)
    return rc == 0

if os.environ["FM_TEST_WATCHER_SCENARIO"] == "attached":
    with (home / "existing.out").open("w") as out, (home / "existing.err").open("w") as err:
        existing = subprocess.Popen(["bin/fm-watch.sh"], stdout=out, stderr=err, start_new_session=True)

    def stop_existing():
        if existing.poll() is None:
            os.killpg(existing.pid, signal.SIGTERM)
            try:
                existing.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(existing.pid, signal.SIGKILL)
                existing.wait()

    atexit.register(stop_existing)
    ready_by = time.monotonic() + 10
    while not watcher_healthy():
        assert time.monotonic() < ready_by, "existing watcher failed to become healthy"
        time.sleep(0.1)
    owner = {name: (state / ".watch.lock" / name).read_bytes() for name in ("pid", "pid-identity")}
    assert int(owner["pid"]) == existing.pid, "fixture watcher does not own the lock"
    record("existing watcher identity", owner)

started = time.monotonic()
record("scenario", os.environ["FM_TEST_WATCHER_SCENARIO"])
record("initial queue bytes", queue.stat().st_size if queue.exists() else 0)

def assert_original_watcher():
    if existing is not None:
        assert existing.poll() is None, "legacy checkpoint stopped the existing watcher"
        assert owner == {name: (state / ".watch.lock" / name).read_bytes() for name in owner}, "legacy handoff replaced the existing watcher"
        assert not (home / "existing.out").read_bytes(), "existing watcher emitted a premature wake"

def deliver_late_wake():
    time.sleep(max(0, 31 - (time.monotonic() - started)))
    assert not queue.exists() or not queue.read_bytes(), "wake arrived before the old deadline"
    rc, _, err = run(["bash", "-c", '. bin/fm-wake-lib.sh; fm_watcher_healthy "$STATE" "$FM_HOME/bin/fm-watch.sh" 300 "$FM_HOME"'], 5)
    assert rc == 0, f"foreground continuation has no healthy watcher after the old deadline: {err}"
    assert_original_watcher()
    time.sleep(max(0, 35 - (time.monotonic() - started)))
    rc, _, err = run(["bash", "-c", '. bin/fm-wake-lib.sh; fm_wake_append check delayed-row "check: delayed legacy wake"'], 5)
    assert rc == 0, f"could not publish delayed wake: {err}"

with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
    producer = executor.submit(deliver_late_wake)
    rc, out, err = run(["bash", "-c", hook["command"]], hook["timeout"], '{"stop_hook_active":false}')
    assert rc == 2, f"legacy Stop did not request a continuation: {rc}: {out} {err}"
    assert time.monotonic() - started < hook["timeout"], "legacy Stop exceeded its deadline"
    commands = [line.removeprefix("CODEX_WATCH_CONTINUE: ") for line in err.splitlines()
                if line.startswith("CODEX_WATCH_CONTINUE: ")]
    assert len(commands) == 1, f"legacy Stop omitted its foreground continuation command: {err}"
    command = shlex.split(commands[0])
    assert command == ["bin/fm-watch-checkpoint.sh", "--arm", "--seconds", "180"], command
    assert_original_watcher()
    if existing is not None:
        cycles = [dict(field.split("=", 1) for field in line.split("\t"))
                  for line in (state / ".watch-cycle-exits.log").read_text().splitlines()]
        assert len(cycles) == 1 and cycles[0]["origin"] == "attached", cycles
        assert int(cycles[0]["watcher_pid"]) == existing.pid, cycles
        assert not queue.exists() or not queue.read_bytes(), "attachment invented a wake"
    observed = False
    for _ in range(3):
        rc, out, err = run(command, 50)
        assert rc == 0, f"foreground continuation failed: {rc}: {out} {err}"
        assert any(out.startswith(prefix) or f"\n{prefix}" in out
                   for prefix in ("signal:", "stale:", "check:", "heartbeat")), out
        rc, rows, instructions = run(["bin/fm-wake-drain.sh"], 10)
        assert rc == 0, f"wake drain failed: {instructions}"
        observed = "check: delayed legacy wake" in rows
        if observed:
            assert time.monotonic() - started > hook["timeout"], "wake was not delayed beyond the old deadline"
            assert b"delayed-row" in queue.read_bytes(), "delivery consumed the wake before handling"
            record("queue before acknowledgement", queue.read_text().rstrip())
            (home / "handled.rows").write_text(rows)
        ack = re.search(r"--ack-through ([0-9]+) --recovery-generation ([A-Za-z0-9._-]+)", instructions)
        if ack:
            rc, _, err = run(["bin/fm-wake-drain.sh", "--ack-through", ack[1], "--recovery-generation", ack[2]], 10)
            assert rc == 0, f"handling acknowledgement failed: {err}"
        if observed:
            break
    producer.result()
    assert observed, "foreground checkpoint loop did not deliver the delayed wake"
    assert not queue.read_bytes(), "handled and acknowledged wake remained queued"
    record("queue after acknowledgement bytes", queue.stat().st_size)
    assert not (state / "mate.turn-ended").exists(), "home supervision wrote a child marker"
    record("child turn-ended marker exists", (state / "mate.turn-ended").exists())
    record("watcher cycle ledger", (state / ".watch-cycle-exits.log").read_text().rstrip())
    if existing is not None:
        cycles = [dict(field.split("=", 1) for field in line.split("\t"))
                  for line in (state / ".watch-cycle-exits.log").read_text().splitlines()]
        assert all(row["origin"] == "attached" and int(row["watcher_pid"]) == existing.pid for row in cycles), cycles
        assert cycles[-1]["reason"] == "attached-delivered-wake", cycles
print("cached 30-second Stop handed off to foreground checkpoints and acknowledged the delayed wake")
PY
rc=$?
exit "$rc"
SH
  )
  rc=$?
  if [ "${FM_TEST_TRANSCRIPT:-0}" = 1 ]; then
    cat "$dir/delayed.out"
  fi
  [ "$rc" -eq 0 ] || fail "legacy deadline handoff failed: $(cat "$dir/delayed.err")"
  pass "legacy Stop ($scenario) returns before 30 seconds and its foreground continuation handles a wake after 35 seconds"
}

test_codex_stale_hook_does_not_add_home_behavior_to_primary_or_child() {
  local primary child home rc out stop stale
  primary=$(make_codex_stop_case codex-stale-primary)
  git init -q "$primary"
  git -C "$primary" -c user.name=fmtest -c user.email=fmtest@example.invalid \
    commit -q --allow-empty -m init
  mv "$primary/.fm-secondmate-home" "$primary/marker.saved"
  stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$primary/.codex/hooks.json")
  stale=${stop/ --codex/}
  if ! jq --arg command "$stale" '.hooks.Stop[0].hooks[0].command = $command' \
    "$primary/.codex/hooks.json" > "$primary/.codex/hooks.json.tmp" ||
    ! mv "$primary/.codex/hooks.json.tmp" "$primary/.codex/hooks.json"; then
    fail "could not install the pre-PR40 primary Stop command"
  fi
  printf 'kind=ship\n' > "$primary/state/task.meta"
  run_codex_stop_case "$primary" false
  rc=$?
  [ "$rc" -eq 2 ] || fail "stale hook changed the generic primary guard exit: rc=$rc"
  ! grep -qF 'check: rearm-resurface' "$primary/stop.err" \
    || fail "stale hook added home-only re-arm behavior to an unmarked primary"
  [ ! -e "$primary/state/.watch-cycle-exits.log" ] \
    || fail "stale hook armed a watcher in an unmarked primary"

  home=$(make_codex_linked_stale_stop_case codex-stale-child-parent)
  child="$TMP_ROOT/codex-stale-child"
  git -C "$home" worktree add --quiet -b fm/codex-stale-child "$child"
  mkdir -p "$child/state" "$child/fakebin" "$child/bin" "$child/.codex"
  cp -R "$home/fakebin/." "$child/fakebin/"
  for out in "$ROOT/bin/"*; do
    ln -s "$out" "$child/bin/${out##*/}"
  done
  cp "$home/.codex/hooks.json" "$child/.codex/hooks.json"
  cp "$(command -v bash)" "$child/codex"
  : > "$child/AGENTS.md"
  printf 'kind=ship\n' > "$child/state/task.meta"
  # shellcheck disable=SC2016 # PATH expands when the child shell reads BASH_ENV.
  printf 'export PATH=%q:"$PATH"\n' "$child/fakebin" > "$child/bash-env"
  run_codex_stop_case "$child" false
  rc=$?
  [ "$rc" -eq 0 ] || fail "stale hook changed the child-worktree scope exit: rc=$rc $(cat "$child/stop.err")"
  [ ! -e "$child/state/.watch-cycle-exits.log" ] \
    || fail "stale hook armed a watcher in a child worktree"
  pass "stale Codex hook remains generic in an unmarked primary and inert in a child worktree"
}

test_codex_stale_hook_requires_marked_home_lock() {
  local dir out rc
  dir=$(make_codex_linked_stale_stop_case codex-stale-lockless)
  printf 'kind=ship\n' > "$dir/state/task.meta"
  out=$(printf '{"stop_hook_active":false}' \
    | FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
      bash "$dir/bin/fm-turnend-guard.sh" 2>&1)
  rc=$?
  [ "$rc" -eq 2 ] || fail "lockless stale hook did not fail closed through the generic guard: rc=$rc"
  ! grep -qF 'check: rearm-resurface' <<<"$out" \
    || fail "lockless stale hook entered home-only recovery"
  [ ! -e "$dir/state/.watch-cycle-exits.log" ] \
    || fail "lockless stale hook started a watcher without session ownership"
  pass "stale Codex hook requires both a valid home marker and session-lock ownership"
}

test_no_flag_secondmate_stop_keeps_other_harnesses_generic() {
  local dir harness rc
  for harness in grok pi pi-signed opencode claude kimi; do
    dir=$(make_codex_linked_stale_stop_case "generic-stop-$harness")
    cp "$(command -v bash)" "$dir/$harness"
    (
      cd "$dir" || exit 1
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
        FM_CONFIG_OVERRIDE="$dir/config" BASH_ENV="$dir/bash-env" \
        "$dir/$harness" -s -- "$ROOT" > "$dir/stop.out" 2> "$dir/stop.err" <<'SH'
printf '%s\n' "$$" > "$FM_HOME/state/.lock"
. "$1/bin/fm-session-lock-lib.sh"
fm_session_lock_owned_by_self "$FM_HOME/state" || exit 99
printf '{"stop_hook_active":false}' | bash "$1/bin/fm-turnend-guard.sh"
rc=$?
exit "$rc"
SH
    ) &
    wait_for_exit "$!" 40
    rc=$?
    [ "$rc" -eq 0 ] || fail "$harness no-flag Stop blocked despite an empty home: rc=$rc $(cat "$dir/stop.err")"
    [ ! -e "$dir/state/.watch-cycle-exits.log" ] \
      && [ ! -e "$dir/state/.watch.lock" ] \
      || fail "$harness no-flag Stop armed a Codex home watcher"
    [ ! -s "$dir/stop.err" ] || fail "$harness no-flag Stop emitted unexpected recovery output"
  done
  pass "no-flag Stops from other lock-owning harnesses retain generic home behavior"
}

make_codex_stop_case() {
  local dir entry
  dir=$(make_case "$1")
  mkdir -p "$dir/bin" "$dir/.codex"
  for entry in "$ROOT/bin/"*; do ln -s "$entry" "$dir/bin/${entry##*/}"; done
  cp "$ROOT/.codex/hooks.json" "$dir/.codex/hooks.json"
  cp "$(command -v bash)" "$dir/codex"
  : > "$dir/AGENTS.md"
  printf 'mate\n' > "$dir/.fm-secondmate-home"
  # shellcheck disable=SC2016 # PATH expands when the child shell reads BASH_ENV.
  printf 'export PATH=%q:"$PATH"\n' "$dir/fakebin" > "$dir/bash-env"
  printf '%s\n' "$dir"
}

run_codex_stop_case() {
  local dir=$1 active=$2 stop
  stop=$(jq -r '.hooks.Stop[0].hooks[0].command' "$dir/.codex/hooks.json")
  (
    cd "$dir" || exit 1
    # shellcheck disable=SC2016 # The child shell evaluates this program's variables.
    env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u CURSOR_AGENT -u CURSOR_INVOKED_AS \
      FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$dir/state" \
      FM_CONFIG_OVERRIDE="$dir/config" BASH_ENV="$dir/bash-env" \
      FM_HOME_WAKE_BACKEND=tmux FM_HOME_WAKE_TARGET=codex-stop-test \
      "$dir/codex" -c '
        printf "%s\n" "$$" > "$FM_HOME/state/.lock"
        printf "{\"stop_hook_active\":%s}" "$2" | bash -c "$1"
        rc=$?
        exit "$rc"
      ' _ "$stop" "$active"
  ) > "$dir/stop.out" 2> "$dir/stop.err"
}

test_codex_stop_failure_recovery_is_bounded() {
  local dir state rc before
  dir=$(make_codex_stop_case codex-stop-failure)
  state="$dir/state"
  rm "$dir/bin/fm-watch.sh"
  cat > "$dir/bin/fm-watch.sh" <<'SH'
#!/usr/bin/env bash
. "$FM_TEST_WAKE_LIB"
. "${FM_TEST_WAKE_LIB%/*}/fm-watch-launch-lib.sh"
fm_watch_launch_begin || exit 1
printf 'attempt\n' >> "$FM_HOME/attempts"
if [ -e "$FM_HOME/fail-watch" ]; then
  printf 'watcher: FAILED - injected startup failure\n'
  exit 3
fi
identity=$(fm_pid_identity "$$")
mkdir -p "$FM_HOME/state/.watch.lock"
printf '%s\n' "$$" > "$FM_HOME/state/.watch.lock/pid"
printf '%s\n' "$FM_HOME" > "$FM_HOME/state/.watch.lock/fm-home"
printf '%s\n' "$0" > "$FM_HOME/state/.watch.lock/watcher-path"
printf '%s\n' "$identity" > "$FM_HOME/state/.watch.lock/pid-identity"
touch "$FM_HOME/state/.last-watcher-beat"
printf '%s\t%s\tcheck: completed productive cycle\n' "$$" "$identity" >> "$FM_HOME/state/.watch-deliveries.log"
printf 'check: completed productive cycle\n'
sleep 0.5
SH
  chmod +x "$dir/bin/fm-watch.sh"
  export FM_TEST_WAKE_LIB="$ROOT/bin/fm-wake-lib.sh"
  append_wake "$state" check pending 'check: pending home work'
  cp "$state/.wake-queue" "$dir/queue.before"
  run_codex_stop_case "$dir" false; rc=$?
  [ "$rc" -eq 2 ] || fail "productive first Stop did not continue"
  run_codex_stop_case "$dir" true; rc=$?
  [ "$rc" -eq 2 ] || fail "productive continuation consumed the repair bound"
  : > "$dir/fail-watch"
  before=$(wc -l < "$dir/attempts")
  run_codex_stop_case "$dir" true; rc=$?
  [ "$rc" -eq 2 ] || fail "queued-only startup failure after productive continuation did not request repair"
  [ "$(( $(wc -l < "$dir/attempts") - before ))" -eq 2 ] || fail "startup recovery did not perform two bounded attempts"
  grep -qF 'SUPERVISION RECOVERY REQUIRED' "$dir/stop.err" || fail "repair continuation omitted actionable failure guidance"
  run_codex_stop_case "$dir" true; rc=$?
  [ "$rc" -eq 0 ] || fail "failed repair continuation created an unbounded Stop loop"
  grep -qF 'SUPERVISION RECOVERY EXHAUSTED' "$dir/stop.err" || fail "exhausted recovery silently allowed a blind stop"
  run_codex_stop_case "$dir" false; rc=$?
  [ "$rc" -eq 2 ] || fail "a new user turn could not request bounded recovery"
  rm "$dir/fail-watch"
  run_codex_stop_case "$dir" true; rc=$?
  [ "$rc" -eq 2 ] || fail "successful recovery did not resume productive wakes"
  : > "$dir/fail-watch"
  run_codex_stop_case "$dir" true; rc=$?
  [ "$rc" -eq 2 ] || fail "a productive recovery did not restore the repair continuation"
  cmp -s "$dir/queue.before" "$state/.wake-queue" || fail "arm failures consumed or changed queued-only work"
  pass "Codex queued-only failures retry, request one repair after productive wakes, and exhaust loudly"
}

test_codex_stop_away_keeps_shared_guard() {
  local dir state rc pid i
  dir=$(make_codex_stop_case codex-stop-away)
  state="$dir/state"
  printf 'kind=ship\n' > "$state/child.meta"
  : > "$state/.afk"
  touch "$state/.last-watcher-beat"
  run_codex_stop_case "$dir" false; rc=$?
  [ "$rc" -eq 2 ] || fail "away mode allowed a blind Stop with active work"
  grep -qF 'Away mode owns watcher supervision' "$dir/stop.err" || fail "away recovery lost daemon-specific guidance"
  [ ! -e "$state/.watch-cycle-exits.log" ] || fail "away mode started normal Stop-owned supervision"
  run_codex_stop_case "$dir" true; rc=$?
  [ "$rc" -eq 0 ] || fail "away mode lost its existing one-continuation bound"
  PATH="$dir/fakebin:$PATH" FM_HOME="$dir" FM_ROOT_OVERRIDE="$dir" FM_STATE_OVERRIDE="$state" \
    FM_CONFIG_OVERRIDE="$dir/config" FM_POLL=1 FM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 \
    "$dir/bin/fm-watch.sh" > "$dir/away-watch.out" 2> "$dir/away-watch.err" &
  pid=$!
  for i in $(seq 1 100); do
    [ -e "$state/.watch.lock/pid-identity" ] && break
    sleep 0.1
  done
  run_codex_stop_case "$dir" false; rc=$?
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  [ "$rc" -eq 0 ] || fail "away mode rejected an existing healthy watcher: $(cat "$dir/stop.err")"
  [ ! -e "$state/.watch-cycle-exits.log" ] || fail "healthy away supervision started a duplicate normal arm"
  pass "Codex away Stops retain strict watcher health, daemon recovery guidance, and the existing bound"
}

test_grok_notify_wait_is_not_a_stall() {
  local dir sub
  dir=$(make_cadence_stall_case grok-notify-wait grok 175)
  sub="$dir/secondmate"
  printf 'Waiting for background command\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" watch
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch.out" >/dev/null \
    || fail "a healthy Grok notify wait paged the parent: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "a healthy Grok notify wait published a parent stall row"
  pass "a Grok background-notify wait inside cadence plus grace stays quiet"
}

test_grok_notify_wait_pages_after_cadence() {
  local dir sub
  dir=$(make_cadence_stall_case grok-notify-over grok 250)
  sub="$dir/secondmate"
  printf 'ready>\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" watch
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch.out" >/dev/null \
    || fail "an over-cadence Grok wait did not page: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  pass "a Grok unclaimed row past cadence plus grace pages the parent"
}

test_grok_notify_wait_pages_when_beacon_stale() {
  local dir sub
  dir=$(make_cadence_stall_case grok-stale-beacon grok 120)
  sub="$dir/secondmate"
  printf 'Waiting for background command\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  set_mtime "$(( $(date +%s) - 400 ))" "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" watch
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch.out" >/dev/null \
    || fail "a stale Grok watcher beacon did not page: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  pass "a Grok notify wait with a stale watcher beacon pages the parent"
}

test_pi_branch_claim_window_is_not_a_stall() {
  local dir sub
  dir=$(make_cadence_stall_case pi-claim-wait pi 274)
  sub="$dir/secondmate"
  printf 'ready>\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" watch
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch.out" >/dev/null \
    || fail "a Pi branch claim-window wait paged the parent: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "a Pi branch claim-window wait published a parent stall row"
  pass "a Pi branch actor's unclaimed row inside the claim window stays quiet"
}

test_pi_branch_claim_window_pages_after_cadence() {
  local dir sub
  dir=$(make_cadence_stall_case pi-claim-over pi 400)
  sub="$dir/secondmate"
  printf 'Waiting for background command\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  run_cadence_stall_checkpoint "$dir" watch
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch.out" >/dev/null \
    || fail "an over-window Pi wait did not page: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  pass "a Pi unclaimed row past the claim window plus grace pages the parent"
}

test_pi_branch_claimed_row_is_not_a_stall() {
  local dir sub
  dir=$(make_cadence_stall_case pi-claimed-row pi 400)
  sub="$dir/secondmate"
  printf 'ready>\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  write_live_branch_owner "$sub" || fail "could not record a live Pi branch grant"
  printf '7\n' > "$sub/state/.branch-eligible-rows"
  run_cadence_stall_checkpoint "$dir" watch
  ! grep -F 'secondmate wake-loop stalled' "$dir/watch.out" >/dev/null \
    || fail "a live Pi branch claim paged the parent: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  [ ! -s "$dir/state/.wake-queue" ] \
    || fail "a live Pi branch claim published a parent stall row"
  pass "a row a live Pi branch actor has claimed stays quiet"
}

test_pi_branch_dead_claim_does_not_hide_a_stall() {
  local dir sub
  dir=$(make_cadence_stall_case pi-dead-claim pi 400)
  sub="$dir/secondmate"
  printf 'ready>\n' > "$dir/fake-tmux/pane.txt"
  touch "$sub/state/.last-watcher-beat"
  printf '%s\n%s\n%s\n%s\n' fm-branch-eligible-owner-v1 "1" "dead-identity" "gen1" \
    > "$sub/state/.branch-eligible-owner"
  printf '7\n' > "$sub/state/.branch-eligible-rows"
  run_cadence_stall_checkpoint "$dir" watch
  grep -F 'check: secondmate wake-loop stalled: mate=mate row=7' "$dir/watch.out" >/dev/null \
    || fail "a dead Pi branch grant hid an over-window stall: $(cat "$dir/watch.out"); err=$(cat "$dir/watch.err")"
  pass "a dead Pi branch grant cannot hide an over-window unclaimed row"
}

test_drain_asserts_watcher_liveness() {
  local dir state err identity
  dir=$(make_case drain-liveness)
  state="$dir/state"
  err="$dir/drain.err"
  printf 'window=test:fm-x\nkind=ship\n' > "$state/x.meta"
  FM_STATE_OVERRIDE="$state" "$DRAIN" >/dev/null 2> "$err" || fail "drain failed while asserting liveness"
  grep -F 'WATCHER DOWN' "$err" >/dev/null || fail "drain did not surface the watcher-down banner with work in flight and no live watcher"
  : > "$err"
  identity=$(FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_pid_identity "$2"' _ "$ROOT/bin/fm-wake-lib.sh" "$$") \
    || fail "could not identify the live watcher fixture"
  mkdir "$state/.watch.lock"
  printf '%s\n' "$$" > "$state/.watch.lock/pid"
  printf '%s\n' "$dir" > "$state/.watch.lock/fm-home"
  printf '%s\n' "$WATCH" > "$state/.watch.lock/watcher-path"
  printf '%s\n' "$identity" > "$state/.watch.lock/pid-identity"
  touch "$state/.last-watcher-beat"
  FM_HOME="$dir" FM_STATE_OVERRIDE="$state" FM_GUARD_GRACE=300 "$DRAIN" >/dev/null 2> "$err" \
    || fail "drain failed with a live watcher and fresh beacon"
  if grep -F 'WATCHER DOWN' "$err" >/dev/null; then
    fail "drain false-alarmed with a live watcher and fresh beacon"
  fi
  pass "drain asserts watcher liveness: warns on a lapse, stays silent for a live watcher with a fresh beacon"
}

test_structural_signal_enrichment_preserves_raw_rows() {
  local dir state out expected actual annotation_count outside perl_bin
  dir=$(make_case enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  expected="$dir/expected.out"
  actual="$dir/actual.out"
  outside="$dir/outside-secret"
  printf 'working: first\n\ndone: latest event\n' > "$state/task.status"
  printf 'working: old turn-end context\n' > "$state/turn-only.status"
  printf 'must-not-be-read\n' > "$outside"
  ln -s "$outside" "$state/escape.status"
  perl_bin=$(command -v perl) || fail "perl is required for safe status reads"
  cat > "$dir/fakebin/perl" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = -MFcntl=:DEFAULT ]; then
  for arg in "$@"; do
    if [ "$arg" = "${FM_WAKE_ENRICH_SWAP_PATH:-}" ]; then
      rm -f "$arg"
      ln -s "$FM_WAKE_ENRICH_SWAP_TARGET" "$arg"
      break
    fi
  done
fi
exec "$FM_WAKE_ENRICH_REAL_PERL" "$@"
SH
  chmod +x "$dir/fakebin/perl"

  append_wake "$state" signal task.status "signal: $outside" || fail "direct status wake append failed"
  append_wake "$state" signal task.turn-ended "signal: $outside" || fail "coalesced turn-end wake append failed"
  append_wake "$state" signal turn-only.turn-ended "signal: $outside" || fail "bare turn-end wake append failed"
  append_wake "$state" signal escape.status "signal: $outside" || fail "symlink status wake append failed"
  append_wake "$state" signal arbitrary-key "signal: $outside" || fail "non-status signal wake append failed"
  append_wake "$state" check task.check.sh "check: complete payload" || fail "check wake append failed"
  append_wake "$state" stale test:fm-task "stale: test:fm-task" || fail "stale wake append failed"
  append_wake "$state" heartbeat heartbeat heartbeat || fail "heartbeat wake append failed"

  FM_STATE_OVERRIDE="$state" bash -c '. "$1"; fm_wake_print_deduped "$2"' _ \
    "$ROOT/bin/fm-wake-lib.sh" "$state/.wake-queue" > "$expected"
  PATH="$dir/fakebin:$PATH" FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_SWAP_PATH="$state/task.status" \
    FM_WAKE_ENRICH_SWAP_TARGET="$outside" FM_WAKE_ENRICH_REAL_PERL="$perl_bin" "$DRAIN" > "$out" \
    || fail "structural enrichment drain failed"
  awk -F '\t' 'NF == 5 { print }' "$out" > "$actual"
  cmp -s "$expected" "$actual" || fail "enrichment changed or reordered an authoritative raw row"

  annotation_count=$(grep -c '^wake annotation:' "$out" || true)
  [ "$annotation_count" -eq 1 ] || fail "expected only the unreadable-race-safe status annotation, got $annotation_count"
  if grep -E '^wake annotation:.*: task\.status:' "$out" >/dev/null; then
    fail "replaced status file produced an annotation"
  fi
  grep -F 'latest wake-EVENT observed at drain, not current state; historical / not necessarily the triggering event: turn-only.status:' "$out" >/dev/null \
    || fail "bare turn-end mapping did not carry the historical warning"
  if grep -F 'must-not-be-read' "$out" >/dev/null; then
    fail "drain trusted a payload path or followed an out-of-state status symlink"
  fi
  pass "structural signal enrichment is separate, deduped, home-local, and tier-zero for other wakes"
}

test_enrichment_preserves_all_unread_lines_and_status_file_failures() {
  local dir state out i raw_count expected
  dir=$(make_case complete-enrichment)
  state="$dir/state"
  out="$dir/drain.out"
  awk 'BEGIN { printf "done: "; for (i = 0; i < 20000; i++) printf "x"; printf "\n" }' > "$state/huge.status"
  append_wake "$state" signal huge.status "signal: huge" || fail "huge status wake append failed"
  i=1
  while [ "$i" -le 8 ]; do
    awk -v n="$i" 'BEGIN { printf "working-%d: ", n; for (j = 0; j < 3000; j++) printf "y"; printf "\n" }' > "$state/many-$i.status"
    append_wake "$state" signal "many-$i.status" "signal: many-$i" || fail "many-status wake append failed"
    i=$((i + 1))
  done
  : > "$state/empty.status"
  append_wake "$state" signal empty.status "signal: empty" || fail "empty status wake append failed"
  append_wake "$state" signal missing.status "signal: missing" || fail "missing status wake append failed"
  mkdir "$state/malformed.status"
  append_wake "$state" signal malformed.status "signal: malformed" || fail "malformed status wake append failed"
  printf 'done: unreadable\n' > "$state/unreadable.status"
  chmod 000 "$state/unreadable.status"
  append_wake "$state" signal unreadable.status "signal: unreadable" || fail "unreadable status wake append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "complete enrichment drain failed"
  raw_count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$raw_count" -eq 13 ] || fail "missing, unreadable, malformed, empty, or oversized status input hid a raw row"

  expected="wake annotation: latest wake-EVENT observed at drain, not current state: huge.status: $(cat "$state/huge.status")"
  grep -Fx "$expected" "$out" >/dev/null \
    || fail "the oversized unread status line was truncated or omitted"
  i=1
  while [ "$i" -le 8 ]; do
    expected="wake annotation: latest wake-EVENT observed at drain, not current state: many-$i.status: $(cat "$state/many-$i.status")"
    grep -Fx "$expected" "$out" >/dev/null \
      || fail "readable status many-$i was truncated or omitted"
    i=$((i + 1))
  done
  if grep -E '^wake annotation:.*(truncated|omitted)' "$out" >/dev/null; then
    fail "complete unread annotation output still reported dropped content"
  fi
  if grep -E ': (empty|missing|malformed|unreadable)\.status:' "$out" >/dev/null; then
    fail "missing, unreadable, malformed, or empty status file produced an annotation"
  fi
  pass "every readable unread status line is annotated in full while invalid status files preserve their raw wakes"
}

wait_for_file_text() {  # <file> <fixed-text>
  local file=$1 expected=$2 i=0
  while [ "$i" -lt 100 ]; do
    grep -F "$expected" "$file" >/dev/null 2>&1 && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

test_slow_annotation_does_not_block_append_and_deleted_file_fails_open() {
  local dir state out1 out2 pid
  dir=$(make_case slow-annotation)
  state="$dir/state"
  out1="$dir/drain-one.out"
  out2="$dir/drain-two.out"
  printf 'done: disappears before bounded read\n' > "$state/slow.status"
  append_wake "$state" signal slow.status "signal: slow" || fail "slow status wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=3 "$DRAIN" > "$out1" &
  pid=$!
  wait_for_file_text "$out1" "$(printf '\tsignal\tslow.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "slow drain did not commit its raw row"; }
  printf 'done: appended while first drain annotates\n' > "$state/next.status"
  append_wake "$state" signal next.status "signal: next" || fail "append blocked or failed during annotation"
  kill -0 "$pid" 2>/dev/null || fail "slow annotation finished before the concurrent append proved lock independence"
  rm -f "$state/slow.status"
  wait "$pid" || fail "deleted status file made the committed drain fail"
  grep -F "$(printf '\tsignal\tslow.status\t')" "$out1" >/dev/null || fail "deleted status file hid the committed raw row"
  if grep -F ': slow.status:' "$out1" >/dev/null; then
    fail "status deleted during annotation still produced an annotation"
  fi
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out2" || fail "follow-up drain after concurrent append failed"
  grep -F "$(printf '\tsignal\tnext.status\t')" "$out2" >/dev/null || fail "concurrent append was not left for the next drain"
  pass "slow annotation releases the append lock and a deleted status file fails open"
}

# Per-actor consume (docs/watcher-continuity.md "Per-actor acknowledgement").
# Drives a MIXED queue snapshot - an unacked main-only check row alongside two
# task-local rows the Pi supervision branch was granted - directly against
# the real bin/fm-wake-drain.sh, independent of the Pi SDK. This is the core
# safety property: a scoped actor's ack must never remove a row outside its
# own eligible snapshot, no matter that row's sequence number relative to
# what the actor presents or acks itself. Do not regress it.
test_branch_actor_scoped_ack_never_swallows_a_main_owned_row() {
  local dir state out err sequence generation count
  dir=$(make_case actor-scope)
  state="$dir/state"

  append_wake "$state" check "some-poll.check.sh" "check: some-poll.check.sh: merged" \
    || fail "main-only append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  append_wake "$state" stale "fm-window" "stale: fm-window" || fail "stale append failed"

  # The extension's own job (fm-branch-dispatch.ts) is granting exactly the
  # two task-local rows; this test drives the bash consume contract those
  # sequence numbers gate, independent of the Pi SDK.
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" actor-scope || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish actor-scope 2 3 || fail "branch grant publication failed"

  out="$dir/branch-drain.out"
  err="$dir/branch-drain.err"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err" \
    || fail "branch-scoped drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "branch drain omitted its eligible signal row"
  grep -Fq "$(printf '\tstale\tfm-window\t')" "$out" || fail "branch drain omitted its eligible stale row"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" && fail "branch drain presented the main-owned row"

  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "branch drain omitted its acknowledgement boundary"
  [ "$sequence" -eq 3 ] || fail "branch ack cutoff must be the max ELIGIBLE seq (3), got $sequence"

  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch-scoped ack failed"

  # The core no-swallow property: the main-only row - seq 1, BELOW the
  # branch's own ack cutoff of 3 - must still be there.
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$state/.wake-queue" \
    || fail "branch's scoped ack swallowed a main-owned row below its own cutoff"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    && fail "branch's own eligible signal row was not consumed"
  grep -Fq "$(printf '\tstale\tfm-window\t')" "$state/.wake-queue" \
    && fail "branch's own eligible stale row was not consumed"

  # Main's own later, ordinary (unscoped) drain sees exactly what remains.
  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$out")
  [ "$count" -eq 1 ] || fail "main's later drain should see exactly the one remaining main-owned row: $(cat "$out")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" || fail "main's later drain lost the main-owned row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || fail "main's drain omitted its acknowledgement boundary"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "main's ack failed"
  [ ! -s "$state/.wake-queue" ] || fail "the main-owned row survived main's own ack"

  pass "a branch-actor scoped ack never swallows an unacked main-owned row, and main's later drain sees exactly what remains"
}

test_main_drain_excludes_rows_already_granted_to_branch() {
  local dir state out err sequence generation
  dir=$(make_case main-excludes-branch-grant)
  state="$dir/state"

  append_wake "$state" check "some-poll.check.sh" "check: some-poll.check.sh: merged" \
    || fail "main-only append failed"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" main-excludes || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish main-excludes 2 || fail "branch grant publication failed"

  out="$dir/main-drain.out"
  err="$dir/main-drain.err"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "main drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tcheck\tsome-poll.check.sh\t')" "$out" || fail "main drain omitted its main-owned row"
  ! grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "main drain presented a branch-granted row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ "$sequence" = 1 ] && [ -n "$generation" ] || fail "main acknowledgement did not bind only its presented row"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "main acknowledgement failed"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$state/.wake-queue" \
    || fail "main acknowledgement consumed the branch-granted row"

  out="$dir/branch-drain.out"
  err="$dir/branch-drain.err"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$out" 2> "$err" \
    || fail "branch drain failed: $(cat "$err")"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$out" || fail "branch lost its granted row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "branch acknowledgement left its handled row queued"
  [ ! -e "$state/.branch-eligible-rows" ] || fail "branch acknowledgement retained its completed grant"

  pass "main drain and acknowledgement exclude an active branch grant"
}

test_branch_grant_refuses_rows_already_claimed_by_main() {
  local dir state rc
  dir=$(make_case branch-refuses-main-claim)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" \
    || fail "main presentation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" branch-refuses || fail "branch owner activation failed"
  rc=0
  FM_STATE_OVERRIDE="$state" "$GRANT" publish branch-refuses 1 || rc=$?
  [ "$rc" -eq 3 ] || fail "branch grant did not report the existing main ownership: rc=$rc"
  [ ! -e "$state/.branch-eligible-rows" ] || fail "refused branch grant published an ownership snapshot"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/main.out" \
    || fail "the main owner did not present its claimed row"

  pass "branch grant cannot take a row already claimed by main"
}

test_actor_filter_precedes_same_key_deduplication() {
  local dir state main_sequence main_generation branch_sequence branch_generation
  dir=$(make_case actor-dedup-order)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: branch version" || fail "branch row append failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$$" actor-dedup || fail "branch owner activation failed"
  FM_STATE_OVERRIDE="$state" "$GRANT" publish actor-dedup 1 || fail "branch grant publication failed"
  append_wake "$state" signal "task-a.status" "signal: main version" || fail "main row append failed"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main drain failed"
  [ "$(awk -F '\t' '$3 == "signal" { print $2 }' "$dir/main.out")" = 2 ] \
    || fail "main did not present its same-key claimed row"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" > "$dir/branch.out" 2> "$dir/branch.err" \
    || fail "branch drain failed"
  [ "$(awk -F '\t' '$3 == "signal" { print $2 }' "$dir/branch.out")" = 1 ] \
    || fail "global deduplication hid the branch's older same-key row"

  main_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  main_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  branch_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/branch.err")
  branch_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/branch.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$main_sequence" --recovery-generation "$main_generation" \
    || fail "main same-key acknowledgement failed"
  FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" --ack-through "$branch_sequence" --recovery-generation "$branch_generation" \
    || fail "branch same-key acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "same-key actor rows remained stranded"

  pass "actor ownership filtering precedes same-key deduplication"
}

test_main_reclaims_a_grant_whose_branch_owner_exited() {
  local dir state owner sequence generation
  dir=$(make_case stale-branch-owner)
  state="$dir/state"

  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "signal append failed"
  sleep 30 &
  owner=$!
  FM_STATE_OVERRIDE="$state" "$GRANT" activate "$owner" stale-owner || {
    kill "$owner" 2>/dev/null || true
    fail "branch owner activation failed"
  }
  FM_STATE_OVERRIDE="$state" "$GRANT" publish stale-owner 1 || {
    kill "$owner" 2>/dev/null || true
    fail "branch grant publication failed"
  }
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/main.out" 2> "$dir/main.err" || fail "main reclaim drain failed"
  grep -Fq "$(printf '\tsignal\ttask-a.status\t')" "$dir/main.out" \
    || fail "main did not reclaim the dead branch owner's row"
  [ ! -e "$state/.branch-eligible-rows" ] && [ ! -e "$state/.branch-eligible-owner" ] \
    || fail "dead branch ownership evidence survived reclaim"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/main.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/main.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "reclaimed row acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "reclaimed branch row remained queued"

  pass "main reclaims rows granted to an exited branch owner"
}

# A branch-actor drain or ack without a snapshot is a wiring bug, never
# "nothing eligible": it must refuse loudly rather than silently draining or
# acking nothing.
test_branch_actor_without_eligible_snapshot_refuses() {
  local dir state
  dir=$(make_case actor-no-snapshot)
  state="$dir/state"
  append_wake "$state" signal "task-a.status" "signal: task-a" || fail "append failed"
  if FM_STATE_OVERRIDE="$state" FM_SUPERVISION_ACTOR=branch "$DRAIN" >/dev/null 2>"$dir/err"; then
    fail "a branch-actor drain with no eligible-row snapshot must refuse, not silently drain"
  fi
  grep -q "no branch-eligible row snapshot" "$dir/err" || fail "the refusal did not name the missing snapshot: $(cat "$dir/err")"
  [ -s "$state/.wake-queue" ] || fail "the refused drain must leave the queue untouched"
  pass "a branch-actor drain with no eligible-row snapshot refuses loudly instead of draining nothing"
}

test_wake_publish_requires_atomic_recovery_evidence() {
  local dir state fakebin real_mv rc out
  dir=$(make_case wake-publish-recovery-evidence)
  state="$dir/state"
  fakebin="$dir/fakebin"
  real_mv=$(command -v mv) || fail "could not locate mv for recovery publication fixture"
  printf 'pending:handling:existing\n' > "$state/.watcher-down"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_PUBLISH_MARKER:-}" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_PUBLISH_MARKER="$state/.watcher-down" \
    append_wake "$state" signal task.status "signal: publish failure"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery publication failure allowed wake append to succeed"
  [ "$(cat "$state/.watcher-down")" = 'pending:handling:existing' ] \
    || fail "failed atomic publication erased existing recovery evidence"
  [ ! -s "$state/.wake-queue" ] \
    || fail "wake became durable before its recovery evidence"

  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" \
    append_wake "$state" signal task.status "signal: recovered retry" \
    || fail "wake retry did not publish durable recovery evidence"
  out="$dir/drain.out"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" \
    || fail "wake retry did not drain"
  grep -F "signal: recovered retry" "$out" >/dev/null \
    || fail "retried wake was not recovered by the durable drain"
  pass "wake append publishes atomic recovery evidence before durable rows"
}

test_legacy_generationless_wake_is_adopted() {
  local dir state row sequence generation
  dir=$(make_case legacy-generationless-wake)
  state="$dir/state"
  row=$(printf '1700000000\t7\tcheck\tlegacy-process-event\tcheck: legacy process-event')
  printf '%s\n' "$row" > "$state/.wake-queue"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "generation-less legacy wake could not be adopted"
  grep -F "$row" "$dir/first.out" >/dev/null \
    || fail "adopted legacy wake was not presented"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/first.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/first.err")
  [ "$sequence" = 7 ] && [ -n "$generation" ] \
    || fail "legacy wake adoption omitted its generation-bound acknowledgement"
  [ "$(cat "$state/.watcher-down" 2>/dev/null || true)" = "pending:handling:$generation" ] \
    || fail "legacy wake was not adopted into durable handling recovery"

  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "unacknowledged adopted wake could not be re-drained"
  grep -F "$row" "$dir/replay.out" >/dev/null \
    || fail "unacknowledged adopted wake was lost"
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" \
    || fail "adopted legacy wake could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged legacy wake remained queued"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/after-ack.out" 2> "$dir/after-ack.err" \
    || fail "post-acknowledgement legacy drain failed"
  ! grep -F "$row" "$dir/after-ack.out" >/dev/null \
    || fail "acknowledged legacy wake was consumed more than once"
  pass "wake drain: generation-less legacy wakes are adopted and acknowledged"
}

# Pin the recovery acknowledgement contract from docs/watcher-continuity.md at
# the queue-library boundary.
test_stale_recovery_generation_cannot_touch_a_newer_episode() {
  local dir state first_err replay_err sequence generation handling_marker
  local newer_marker newer_sequence newer_generation rc
  dir=$(make_case stale-recovery-generation)
  state="$dir/state"

  append_wake "$state" check first 'check: first generation' \
    || fail "first generation wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/first.out" 2> "$dir/first.err" \
    || fail "first generation drain failed"
  first_err="$dir/first.err"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$first_err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$first_err")
  [ -n "$sequence" ] && [ -n "$generation" ] \
    || fail "first drain did not emit a generation-bound acknowledgement"

  append_wake "$state" check second 'check: same episode' \
    || fail "first same-episode wake append failed"
  append_wake "$state" check third 'check: same episode again' \
    || fail "second same-episode wake append failed"
  handling_marker=$(cat "$state/.watcher-down")
  [ "${handling_marker##*:}" = "$generation" ] \
    || fail "repeated publications replaced the outstanding recovery generation"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/handled-ack.out" 2> "$dir/handled-ack.err" \
    || fail "a publication during handling invalidated the printed acknowledgement"
  ! grep "$(printf '\tcheck\tfirst\t')" "$state/.wake-queue" >/dev/null \
    || fail "the handled row was not consumed"
  grep "$(printf '\tcheck\tsecond\t')" "$state/.wake-queue" >/dev/null \
    || fail "a row above the acknowledged sequence was consumed"
  grep "$(printf '\tcheck\tthird\t')" "$state/.wake-queue" >/dev/null \
    || fail "the second row above the acknowledged sequence was consumed"
  case "$(cat "$state/.watcher-down")" in
    pending:*) ;;
    *) fail "an episode with rows still queued was retired" ;;
  esac

  # Retire that episode, then let a genuinely newer one open.
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/replay.out" 2> "$dir/replay.err" \
    || fail "remaining wake could not be re-drained"
  replay_err="$dir/replay.err"
  grep "$(printf '\tcheck\tsecond\t')" "$dir/replay.out" >/dev/null \
    || fail "remaining wake did not re-surface"
  grep "$(printf '\tcheck\tthird\t')" "$dir/replay.out" >/dev/null \
    || fail "second remaining wake did not re-surface"
  newer_sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$replay_err")
  newer_generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$replay_err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$newer_sequence" \
    --recovery-generation "$newer_generation" \
    || fail "the handled episode could not be acknowledged"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledgement left durable wakes queued"

  append_wake "$state" check fourth 'check: newer recovery generation' \
    || fail "newer generation wake append failed"
  newer_marker=$(cat "$state/.watcher-down")
  [ "${newer_marker##*:}" != "$generation" ] \
    || fail "a retired episode did not open a new recovery generation"

  rc=0
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" \
    --recovery-generation "$generation" > "$dir/stale-ack.out" 2> "$dir/stale-ack.err" || rc=$?
  [ "$rc" -eq 0 ] \
    || fail "a stale acknowledgement failed instead of degrading safely: $(cat "$dir/stale-ack.err")"
  if ! grep -F 'WAKE_ACK_REQUIRED' "$dir/stale-ack.err" >/dev/null \
    || ! grep -F 're-run' "$dir/stale-ack.err" >/dev/null; then
    fail "a stale acknowledgement did not name its own remedy: $(cat "$dir/stale-ack.err")"
  fi
  [ "$(cat "$state/.watcher-down")" = "$newer_marker" ] \
    || fail "a stale acknowledgement retired the newer recovery episode"
  grep "$(printf '\tcheck\tfourth\t')" "$state/.wake-queue" >/dev/null \
    || fail "a stale acknowledgement consumed the newer durable wake"
  pass "wake drain: a stale acknowledgement cannot retire or consume a newer recovery episode"
}

test_recovery_ack_failure_is_reported() {
  local dir state fakebin real_mv rc generation
  dir=$(make_case recovery-ack-failure)
  state="$dir/state"
  fakebin="$dir/fakebin"
  real_mv=$(command -v mv) || fail "could not locate mv for recovery acknowledgement fixture"
  printf 'pending:handling:fixture\n' > "$state/.watcher-down"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$dir/initial.out" 2> "$dir/initial.err" \
    || fail "initial recovery drain failed"
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through 0 --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/initial.err")
  [ -n "$generation" ] || fail "initial recovery drain omitted its generation"
  cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
last=${!#}
if [ "$last" = "${FM_TEST_ACK_MARKER:-}" ]; then
  exit 1
fi
exec "$FM_TEST_REAL_MV" "$@"
SH
  chmod +x "$fakebin/mv"

  set +e
  PATH="$fakebin:$PATH" FM_TEST_REAL_MV="$real_mv" FM_TEST_ACK_MARKER="$state/.watcher-down" \
    FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 0 --recovery-generation "$generation" \
      > "$dir/drain.out" 2> "$dir/drain.err"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "recovery acknowledgement failure was reported as success"
  grep -F 'recovery episode could not be retired safely' "$dir/drain.err" >/dev/null \
    || fail "recovery acknowledgement failure had no explicit diagnostic"
  grep -F 'WAKE_ACK_REQUIRED' "$dir/drain.err" >/dev/null \
    || fail "recovery acknowledgement failure did not name its own remedy"
  [ "$(cat "$state/.watcher-down")" = "pending:handling:$generation" ] \
    || fail "failed acknowledgement corrupted the pending recovery marker"

  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through 0 --recovery-generation "$generation" \
    > "$dir/retry.out" 2> "$dir/retry.err" \
    || fail "recovery acknowledgement did not succeed on retry"
  [ "$(cat "$state/.watcher-down")" = "acked:handling:$generation" ] \
    || fail "successful retry did not acknowledge pending recovery state"
  pass "wake drain: recovery acknowledgement failures are explicit and retryable"
}

test_interruption_before_and_after_raw_commit() {
  local dir state before_out after_out replay_out empty_out pid rc count i sequence generation
  dir=$(make_case interruption)
  state="$dir/state"
  before_out="$dir/before.out"
  after_out="$dir/after.out"
  replay_out="$dir/replay.out"
  empty_out="$dir/empty.out"
  printf 'done: interruption fixture\n' > "$state/task.status"
  append_wake "$state" signal task.status "signal: task" || fail "pre-commit interruption wake append failed"

  FM_STATE_OVERRIDE="$state" FM_WAKE_DRAIN_TEST_DELAY_BEFORE_COMMIT=5 "$DRAIN" > "$before_out" &
  pid=$!
  i=0
  while [ "$i" -lt 100 ] && [ ! -e "$state/.wake-queue.lock" ]; do
    sleep 0.05
    i=$((i + 1))
  done
  [ -e "$state/.wake-queue.lock" ] || { kill "$pid" 2>/dev/null || true; fail "pre-commit drain never entered its serialized read boundary"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain before raw commitment"
  set +e
  wait "$pid"
  rc=$?
  set -e
  [ "$rc" -ne 0 ] || fail "pre-commit interruption unexpectedly succeeded"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$replay_out" 2> "$dir/replay.err" || fail "restored pre-commit wake did not drain"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$replay_out")
  [ "$count" -eq 1 ] || fail "pre-commit interruption lost or duplicated the durable row"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/replay.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/replay.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "pre-commit replay acknowledgement failed"

  append_wake "$state" signal task.status "signal: task after commit" || fail "post-commit interruption wake append failed"
  FM_STATE_OVERRIDE="$state" FM_WAKE_ENRICH_TEST_DELAY=5 "$DRAIN" > "$after_out" &
  pid=$!
  wait_for_file_text "$after_out" "$(printf '\tsignal\ttask.status\t')" \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain did not print its raw row"; }
  [ -s "$state/.wake-queue" ] \
    || { kill "$pid" 2>/dev/null || true; fail "post-commit drain consumed its raw row before handling acknowledgement"; }
  kill -TERM "$pid" 2>/dev/null || fail "could not interrupt drain after raw presentation"
  set +e
  wait "$pid"
  set -e
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$empty_out" 2> "$dir/after-replay.err" \
    || fail "drain after post-presentation interruption failed"
  count=$(awk -F '\t' 'NF == 5 { count++ } END { print count + 0 }' "$empty_out")
  [ "$count" -eq 1 ] || fail "interrupted handling did not replay its durable row exactly once"
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$dir/after-replay.err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$dir/after-replay.err")
  FM_STATE_OVERRIDE="$state" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" \
    || fail "post-interruption replay acknowledgement failed"
  [ ! -s "$state/.wake-queue" ] || fail "acknowledged interrupted wake remained durable"
  pass "interruptions preserve durable rows until post-handling acknowledgement"
}

# The guarded self-announced status append (fm_wake_status_append_self_announced)
# and the seen-signature gate it shares with the watcher's signal scan. Both
# directions of the dedup contract are pinned through the real library
# functions: a fully announced file plus the home's own bookkeeping close stays
# announced (no wake), while ANY unannounced byte - a pending foreign line, a
# missing marker, a later different note - reads as wake-worthy.
test_self_announced_append_guards() {
  local dir state status
  dir=$(make_case self-announced-append)
  state="$dir/state"
  status="$state/t.status"

  run_wake_lib() {
    FM_STATE_OVERRIDE="$state" bash -c '
      . "$1"; shift; "$@"
    ' _ "$ROOT/bin/fm-wake-lib.sh" "$@"
  }

  # FIRST status change: a fresh file with no marker is unannounced (wakes).
  printf 'working: first line\n' > "$status"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a never-announced status file read as already announced"

  # Prime the marker to current (the watcher just surfaced/absorbed everything).
  prime_status_seen "$state" "$status" || fail "could not prime the seen marker"

  # A self-announced bookkeeping close on a fully announced file is suppressed.
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: closed by this home' \
    || fail "self-announced append on an announced file was not suppressed (rc=$?)"
  grep -Fq 'resolved [key=k1]: answered: closed by this home' "$status" \
    || fail "the suppressed close was not appended"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    || fail "the self-announced close left unannounced bytes behind"

  # A later DIFFERENT note from any other writer still wakes.
  printf 'needs-decision [key=k2]: a new decision\n' >> "$status"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a later different note on the same task read as already announced"

  # With that foreign line pending, a bookkeeping close must NOT advance the
  # marker over it: the close appends but the file stays wake-worthy.
  local rc=0
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    'resolved [key=k1]: answered: second close' || rc=$?
  [ "$rc" -eq 1 ] || fail "a close over pending foreign bytes did not fail toward waking (rc=$rc)"
  grep -Fq 'resolved [key=k1]: answered: second close' "$status" \
    || fail "the fail-toward-waking close was not appended"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    && fail "a close over pending foreign bytes swallowed the pending wake"

  # UTF-8 close on an announced file: byte accounting must hold for multibyte.
  prime_status_seen "$state" "$status" || fail "could not re-prime the seen marker"
  run_wake_lib fm_wake_status_append_self_announced "$state" "$status" \
    "$(printf 'resolved [key=k2]: answered: caf\xc3\xa9 rentr\xc3\xa9e')" \
    || fail "a multibyte self-announced close was not suppressed (rc=$?)"
  run_wake_lib fm_wake_signal_seen_current "$state" "$status" \
    || fail "multibyte byte accounting broke the self-announce guard"

  pass "self-announced appends suppress only their own bytes and fail toward waking"
}

# A trap that fires inside a lock's critical section abandons the holding
# frame, and the exit path then re-acquires the same lock (a TERM inside a
# recovery-marker section is the reproduced case: the watcher's reap wedged
# forever spinning against its own pid). The same-process re-acquire must
# reclaim the abandoned hold, while a SUBSHELL still waits on its parent's
# live hold exactly as before.
test_self_held_lock_reclaims_instead_of_deadlocking() {
  local dir state rc
  dir=$(make_case self-held-lock)
  state="$dir/state"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$2/.fixture.lock"
    fm_lock_acquire_wait "$lock" || exit 10
    fm_lock_try_acquire "$lock" || exit 11
    fm_lock_release "$lock"
    [ ! -e "$lock" ] && [ ! -L "$lock" ] || exit 12
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" || rc=$?
  [ "$rc" -eq 0 ] || fail "self-held lock was not reclaimed cleanly (rc=$rc)"
  rc=0
  FM_STATE_OVERRIDE="$state" bash -c '
    . "$1"
    lock="$2/.fixture2.lock"
    fm_lock_acquire_wait "$lock" || exit 10
    ( fm_lock_try_acquire "$lock" && exit 13; exit 0 ) || exit 13
    fm_lock_release "$lock"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$state" || rc=$?
  [ "$rc" -eq 0 ] || fail "a subshell reclaimed its parent's live hold (rc=$rc)"
  pass "an abandoned same-process lock hold is reclaimed; a parent's live hold is not"
}

# Drain-time historical annotation staleness: a turn-ended-only wake row must
# not present an already-announced status line as a new update, while a status
# file with unannounced bytes keeps its annotation and a direct status row is
# always annotated. Driven through the real drain executable.
test_historical_annotation_skips_announced_status() {
  local dir state out err
  dir=$(make_case historical-annotation)
  state="$dir/state"
  out="$dir/drain.out"
  err="$dir/drain.err"

  printf 'working: long scout still going\n' > "$state/scout.status"
  prime_status_seen "$state" "$state/scout.status" \
    || fail "could not prime the scout seen marker"
  : > "$state/scout.turn-ended"
  append_wake "$state" signal scout.turn-ended "signal: $state/scout.turn-ended" \
    || fail "turn-ended wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "drain failed"
  if grep -F 'scout.status: working: long scout still going' "$out" >/dev/null; then
    fail "a fully announced status line was replayed as a historical annotation"
  fi
  grep -F 'scout.turn-ended' "$out" >/dev/null \
    || fail "suppressing the stale annotation dropped the turn-ended wake row itself"
  ack_drain_err "$state" "$err" || fail "could not acknowledge the first drain"

  # Unannounced status bytes: the historical annotation is genuinely new
  # information and must stay.
  printf 'working: fresh unannounced progress\n' >> "$state/scout.status"
  : > "$state/scout.turn-ended"
  append_wake "$state" signal scout.turn-ended "signal: $state/scout.turn-ended" \
    || fail "second turn-ended wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "second drain failed"
  grep -F 'historical / not necessarily the triggering event: scout.status: working: fresh unannounced progress' "$out" >/dev/null \
    || fail "an unannounced status line lost its historical annotation"
  ack_drain_err "$state" "$err" || fail "could not acknowledge the second drain"

  # A direct status row is the announcement itself and is always annotated,
  # even when the seen marker already covers the file.
  printf 'done: scout finished\n' >> "$state/scout.status"
  prime_status_seen "$state" "$state/scout.status" \
    || fail "could not prime the marker for the direct-row leg"
  append_wake "$state" signal scout.status "signal: $state/scout.status" \
    || fail "direct status wake append failed"
  FM_STATE_OVERRIDE="$state" "$DRAIN" > "$out" 2> "$err" || fail "third drain failed"
  grep -F 'scout.status: done: scout finished' "$out" >/dev/null \
    || fail "a direct status row lost its annotation"
  pass "historical annotations replay nothing already announced and keep everything new"
}

run_codex_stop_tests() {
  test_codex_stale_hook_linked_secondmate_rearms_and_preserves_wake
  test_codex_stale_hook_hands_off_before_deadline_for_delayed_wake
  test_codex_stale_hook_hands_off_before_deadline_for_delayed_wake attached
  test_codex_stale_hook_does_not_add_home_behavior_to_primary_or_child
  test_codex_stale_hook_requires_marked_home_lock
  test_no_flag_secondmate_stop_keeps_other_harnesses_generic
  test_codex_secondmate_stop_arms_and_self_wakes
  test_codex_stop_failure_recovery_is_bounded
  test_codex_stop_away_keeps_shared_guard
}

run_secondmate_review_tests() {
  test_watch_env_rejects_arithmetic_execution
  run_codex_stop_tests
  test_busy_grok_pi_and_live_branch_keep_their_cadence
  test_grok_notify_wait_is_not_a_stall
  test_grok_notify_wait_pages_after_cadence
  test_grok_notify_wait_pages_when_beacon_stale
  test_pi_branch_claim_window_is_not_a_stall
  test_pi_branch_claim_window_pages_after_cadence
  test_pi_branch_claimed_row_is_not_a_stall
  test_pi_branch_dead_claim_does_not_hide_a_stall
  test_codex_busy_secondmate_row_stays_quiet
  test_codex_busy_stale_beacon_still_pages
  test_codex_idle_secondmate_uses_idle_cadence_plus_grace
  test_secondmate_stall_override_precedes_busy_state
  test_secondmate_watch_env_default_is_loaded_safely
}

if [ "${1:-}" = --codex-stop ]; then
  run_codex_stop_tests
  exit
fi

if [ "${1:-}" = --secondmate ]; then
  run_secondmate_review_tests
  exit
fi

test_self_held_lock_reclaims_instead_of_deadlocking
test_secondmate_foreign_queue_stall_is_one_shot_and_read_only
test_secondmate_parked_pause_rechecks_do_not_flood_parent
test_secondmate_stall_marker_rejects_symlink
test_acknowledged_stall_publication_survives_pre_marker_crash
test_empty_prefix_mate_preserves_other_mate_receipt
run_secondmate_review_tests
test_self_announced_append_guards
test_historical_annotation_skips_announced_status
test_concurrent_append_and_drain
test_signal_catchup_without_running_watcher
test_stale_enqueue_before_suppressor
test_not_working_stale_enqueue_before_suppressor
test_check_output_is_queued
test_atomic_double_drain
test_drain_dedupes_obvious_duplicates
test_drain_asserts_watcher_liveness
test_structural_signal_enrichment_preserves_raw_rows
test_enrichment_preserves_all_unread_lines_and_status_file_failures
test_slow_annotation_does_not_block_append_and_deleted_file_fails_open
test_branch_actor_scoped_ack_never_swallows_a_main_owned_row
test_main_drain_excludes_rows_already_granted_to_branch
test_branch_grant_refuses_rows_already_claimed_by_main
test_actor_filter_precedes_same_key_deduplication
test_main_reclaims_a_grant_whose_branch_owner_exited
test_branch_actor_without_eligible_snapshot_refuses
test_wake_publish_requires_atomic_recovery_evidence
test_legacy_generationless_wake_is_adopted
test_stale_recovery_generation_cannot_touch_a_newer_episode
test_recovery_ack_failure_is_reported
test_interruption_before_and_after_raw_commit
