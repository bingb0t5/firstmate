#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_tools() { # <world>
  local world=$1 fake
  fake="$world/fakebin"
  mkdir -p "$fake"
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  chmod +x "$fake"/*
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
  : > "$MATE/AGENTS.md"
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

bind_secondmate() { # <local|remote>
  local route=$1
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  if [ "$route" = local ]; then
    cat > "$MATE/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$MAIN
EOF
  else
    cat > "$MATE/.fm-secondmate-parent" <<'EOF'
schema=fm-secondmate-parent.v1
route=remote
EOF
  fi
}

write_child() { # <home> <id> <status> [spawn-gen]
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM}
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=alpha" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1'
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

write_mate_meta() {
  fm_write_secondmate_meta "$MAIN/state/mate.meta" "$MATE"
  printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
  age "$MAIN/state/mate.meta" "$MAIN/state/mate.status"
}

run_reconcile() { # <home> [--startup]
  local home=$1 option=${2:-} crew_state_bin
  crew_state_bin=${FM_INACTIVE_CREW_STATE_BIN:-$WORLD/fakebin/fm-crew-state.sh}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$crew_state_bin" \
    FM_PAUSE_RESURFACE_SECS="${FM_PAUSE_RESURFACE_SECS:-3600}" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" scan ${option:+"$option"}
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

stale_row_count() { # <home>
  awk -F '\t' '$3 == "stale" { n++ } END { print n + 0 }' "$1/state/.wake-queue" 2>/dev/null \
    || printf '0\n'
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

prime_seen() { # <state> <status>
  local state=$1 status=$2 sig
  if [ "$(uname)" = Darwin ]; then sig=$(stat -f '%z:%Fm' "$status"); else sig=$(stat -c '%s:%Y' "$status"); fi
  printf '%s' "$sig" > "$state/.seen-$(basename "$status" | tr '.' '_')"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# The main retains a terminal presentation receipt until the corresponding wake
# is handled and acknowledged.
test_main_direct_terminal_presentation_receipt() {
  local err seq generation
  make_world main-direct; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "main did not queue terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "main did not retain presentation receipt"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "main presentation did not require durable acknowledgement"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "acknowledged presentation did not receive its own receipt"
  pass "main direct terminal presentation has a durable receipt"
}

# A secondmate independently reports a genuinely terminal inactive child.
test_local_secondmate_reports_terminal_child() {
  make_world local; bind_secondmate local; write_child "$MATE" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  grep -Fq 'done [key=inactive-outcome-mate-child-done]:' "$MAIN/state/mate.status" \
    || fail "secondmate did not append its durable parent report"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "secondmate report receipt was not durable"
  pass "secondmate reports its own inactive terminal child"
}

test_local_secondmate_rejects_relative_parent_home() {
  make_world relative-parent; bind_secondmate local
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=relative-parent\n' \
    > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'failed: terminal'
  (cd "$WORLD" && FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
  [ ! -e "$WORLD/relative-parent/state/mate.status" ] \
    || fail "relative parent home received a false durable report"
  [ "$(outcome_count "$MATE" reported)" = 0 ] \
    || fail "relative parent route was recorded as reported"
  [ "$(outcome_count "$MATE" pending)" = 1 ] \
    || fail "failed relative parent route did not retain its pending receipt"
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] \
    || fail "failed relative parent route did not surface a recovery notice"
  pass "relative local parent homes fail closed"
}

# A present invalid identity marker cannot turn a secondmate home into a main
# home. The original child state remains available after the routing alarm.
test_invalid_secondmate_marker_blocks_routing() {
  local kind out target
  for kind in malformed symlink; do
    make_world "invalid-marker-$kind"
    write_child "$MATE" child 'failed: terminal'
    if [ "$kind" = malformed ]; then
      printf '../main\n' > "$MATE/.fm-secondmate-home"
    else
      target="$WORLD/marker-target"
      printf 'mate\n' > "$target"
      ln -s "$target" "$MATE/.fm-secondmate-home"
    fi

    out=$(FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup)
    printf '%s\n' "$out" | grep -Fq 'inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker' \
      || fail "$kind secondmate marker did not surface the blocked terminal obligation"
    [ "$(outcome_count "$MATE" pending)" = 0 ] \
      || fail "$kind secondmate marker created a main-home pending receipt"
    ! grep -Fq 'inactive-outcome:' "$MATE/state/.wake-queue" 2>/dev/null \
      || fail "$kind secondmate marker routed a captain presentation wake"
    [ -f "$MATE/state/child.meta" ] && [ -f "$MATE/state/child.status" ] \
      || fail "$kind secondmate marker lost the terminal obligation"
  done
  pass "invalid secondmate markers block routing and surface the obligation"
}

# A remote child route writes the existing mirror input once even across restarts.
test_remote_parent_reply_is_idempotent() {
  make_world remote; bind_secondmate remote; write_child "$MATE" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  FM_FAKE_CREW_STATE='done' run_reconcile "$MATE" --startup
  [ "$(grep -c 'inactive-outcome-mate-child-done' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "remote parent reply was not restart-idempotent"
  [ "$(outcome_count "$MATE" reported)" = 1 ] || fail "remote parent report receipt missing"
  pass "remote parent-replies mirror input is durable and idempotent"
}

# Reusing a task id creates a separate receipt for the new spawned worker even
# when its terminal state and status text match the retired worker exactly.
test_reused_task_id_reports_each_incarnation() {
  make_world reused-id; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-one
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  rm -f "$MATE/state/child.meta" "$MATE/state/child.status" "$MATE/state/child.turn-ended"
  write_child "$MATE" child 'failed: terminal' spawn-two
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(outcome_count "$MATE" reported)" = 2 ] \
    || fail "reused task id collided with the retired incarnation receipt"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 2 ] \
    || fail "reused task id did not produce an independent parent report"
  pass "reused task ids retain per-incarnation terminal receipts"
}

# Legacy metadata has no generation, so its stable per-spawn temp root preserves
# the same receipt identity across supported atomic metadata rewrites.
test_legacy_metadata_rewrite_keeps_receipt_identity() {
  local meta tmp
  make_world legacy-rewrite; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-old
  meta="$MATE/state/child.meta"
  tmp="$MATE/state/.child.meta.legacy"
  awk '$0 !~ /^spawn_gen=/' "$meta" > "$tmp"
  printf 'tasktmp=/tmp/fm-child\n' >> "$tmp"
  mv "$tmp" "$meta"
  age "$meta"

  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  awk '{ print }' "$meta" > "$tmp"
  mv "$tmp" "$meta"
  age "$meta"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup

  [ "$(outcome_count "$MATE" reported)" = 1 ] \
    || fail "legacy metadata rewrite changed the terminal receipt identity"
  [ "$(grep -c 'inactive-outcome-mate-child-failed' "$MATE/state/parent-replies.status")" = 1 ] \
    || fail "legacy metadata rewrite duplicated the parent report"
  pass "legacy metadata rewrites preserve terminal receipt identity"
}

# Reconciliation snapshots terminal state and incarnation under the same task
# lifecycle lock used by relaunch metadata publication.
test_relaunch_cannot_replace_metadata_during_state_snapshot() {
  local recon_pid update_pid record i
  make_world relaunch-race; bind_secondmate remote
  write_child "$MATE" child 'failed: terminal' spawn-old
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_RACE_WORLD:?}/state-started"
while [ ! -e "$FM_RACE_WORLD/state-release" ]; do sleep 0.05; done
printf 'state: failed · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_RACE_WORLD="$WORLD" run_reconcile "$MATE" --startup &
  recon_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/state-started" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/state-started" ] || fail "reconciliation did not begin its state snapshot"

  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta="$FM_STATE_OVERRIDE/child.meta"
    lock=$(fm_meta_lock_path "$meta")
    fm_lock_acquire_wait "$lock"
    awk '\''{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-new"); print }'\'' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
    printf "working: replacement active\n" > "$FM_STATE_OVERRIDE/child.status"
    : > "$2/meta-updated"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  update_pid=$!
  i=0
  while [ "$i" -lt 10 ] && [ ! -e "$WORLD/meta-updated" ]; do sleep 0.05; i=$((i + 1)); done
  : > "$WORLD/state-release"
  wait "$recon_pid" || fail "reconciliation failed during relaunch race"
  wait "$update_pid" || fail "metadata replacement failed during relaunch race"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.reported' | head -1)
  [ -n "$record" ] || fail "terminal snapshot did not produce a receipt"
  grep -Fxq 'incarnation=spawn-old' "$record" \
    || fail "terminal result was attributed to replacement metadata"
  pass "relaunch cannot replace metadata during terminal snapshot"
}

# Heartbeat backoff state is deliberately irrelevant to the independent cadence.
test_heartbeat_cap_does_not_delay_reconciliation() {
  make_world heartbeat; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  printf '12\n' > "$MAIN/state/.heartbeat-streak"
  : > "$MAIN/state/.last-heartbeat"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "heartbeat cap suppressed inactive terminal reconciliation"
  pass "terminal reconciliation ignores heartbeat backoff state"
}

# Only authoritative terminal states qualify. A captain-held item is excluded too.
test_scan_marker_replaces_symlink_safely() {
  make_world marker; write_child "$MAIN" child 'done: green'
  printf 'preserve me\n' > "$MAIN/state/marker-target"
  ln -s marker-target "$MAIN/state/.inactive-outcome-reconcile"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(cat "$MAIN/state/marker-target")" = 'preserve me' ] \
    || fail "scan marker symlink overwrote its target"
  [ ! -L "$MAIN/state/.inactive-outcome-reconcile" ] \
    || fail "scan marker remained a symlink"
  pass "scan marker replaces a symlink without overwriting its target"
}

test_nonterminal_and_captain_held_states_do_not_report() {
  local state
  for state in working paused parked unknown; do
    make_world "nonterminal-$state"; write_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$state produced a terminal outcome"
  done
  make_world captain-held; write_child "$MAIN" child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "captain-held item was reconciled"
  pass "nonterminal and captain-held workers remain outside inactive terminal reporting"
}

test_post_completion_pause_does_not_report_terminal_outcome() {
  make_world post-completion-pause
  write_child "$MAIN" child 'paused: waiting on an external dependency'
  printf 'done: shipped\npaused: waiting on an external dependency\n' > "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_INACTIVE_CREW_STATE_BIN="$ROOT/bin/fm-crew-state.sh" run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "post-completion pause created a terminal outcome record"
  ! grep -Fq 'inactive-outcome:' "$MAIN/state/.wake-queue" 2>/dev/null \
    || fail "post-completion pause created an inactive terminal wake"
  pass "post-completion pauses remain outside inactive terminal reporting"
}

# The actual watcher poll invokes the helper, while an idle secondmate remains
# exempt from wedge escalation and emits no false wake.
test_watcher_hook_and_idle_secondmate_exemption() {
  local out pid i
  make_world watcher; write_child "$MAIN" child 'done: green'; prime_seen "$MAIN/state" "$MAIN/state/child.status"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='done' "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: inactive-outcome' "$out" || fail "watcher did not surface its reconciliation result"

  make_world idle-secondmate; bind_secondmate local; write_mate_meta; prime_seen "$MAIN/state" "$MAIN/state/mate.status"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$WORLD/idle.out" 2>&1 &
  pid=$!; sleep 2; kill -0 "$pid" 2>/dev/null || fail "idle secondmate watcher exited unexpectedly"; reap "$pid"
  grep -F 'stale:' "$WORLD/idle.out" >/dev/null && fail "idle secondmate was treated as a wedge"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "idle secondmate emitted a false wake"
  pass "watcher hook wakes for terminal loss and preserves idle secondmate exemption"
}

# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'working: state read will stall'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: fake\n'
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled state read exceeded aggregate scan budget (${elapsed}s)"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_full_scan_budget_includes_wake_lock_wait() {
  local holder started elapsed i
  make_world wake-lock; write_child "$MAIN" child 'done: green'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "wake lock holder did not start"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  # The unbounded wake-lock wait is ended by the process-group backstop, which
  # fires one second after the budget; the bound proves the scan cannot ride
  # the 30-second lock hold.
  [ "$elapsed" -le 4 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

test_notice_recovery_does_not_duplicate_wake() {
  local record err seq generation
  make_world notice-recovery; bind_secondmate remote
  printf 'schema=fm-secondmate-parent.v1\nroute=invalid\n' > "$MATE/.fm-secondmate-parent"
  write_child "$MATE" child 'failed: terminal'
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "parent-report failure did not queue one notice"

  record=$(find "$MATE/state/terminal-outcomes" -type f -name '*.pending' | head -1)
  awk '{ sub(/^notice_emitted=1$/, "notice_emitted=0"); print }' "$record" > "$record.tmp"
  mv "$record.tmp" "$record"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 1 ] || fail "recovery duplicated an already queued notice"

  err="$WORLD/drain.err"
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'inactive-reconcile:')" = 0 ] || fail "acknowledged notice was emitted again"
  pass "notice recovery remains idempotent across queue acknowledgement"
}

test_quiet_active_scan_does_not_read_current_state() {
  local now
  make_world quiet-active
  write_child "$MAIN" child 'working: implementation is under way'
  touch "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
printf 'state: working · source: run-step\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  now=$(date +%s)
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_NOW="$now" \
    FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/state-reads" ] || fail "quiet active scan read current state before work was due"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "quiet active scan woke supervision"
  pass "quiet active scans use local evidence without a current-state/model read"
}

# Driven through the real bin/fm-crew-state.sh: a trailing off-contract `note:`
# line is exactly what makes its verdict inconclusive, so a stubbed verdict here
# would assert a pairing the production reader never emits for this log.
test_overdue_active_work_ignores_chatter() {
  local t0
  make_world overdue-chatter
  write_child "$MAIN" child 'working: implementation is under way'
  mkdir -p "$MAIN/projects/child"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf '%s\\n' "\$1" >> "\${FM_STATE_READ_LOG:?}"
exec "$ROOT/bin/fm-crew-state.sh" "\$@"
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  # The working line lands at T0; the first scan observes it well inside the
  # threshold, so the due clock is anchored at T0 and nothing is due yet.
  t0=$(( $(date +%s) - 100 ))
  set_mtime "$t0" "$MAIN/state/child.meta"
  set_mtime "$t0" "$MAIN/state/child.status"
  set_mtime "$t0" "$MAIN/state/child.turn-ended"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_NOW=$((t0 + 10)) \
    FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "work inside the threshold was surfaced early"
  # Chatter at T0+55 is the only later write. A clock that reset on it would see
  # 15s at the next scan; a clock anchored to the working line sees 70s.
  printf 'note: routine check-in chatter\n' >> "$MAIN/state/child.status"
  set_mtime $((t0 + 55)) "$MAIN/state/child.status"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_NOW=$((t0 + 70)) \
    FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  grep -Fq 'active work has no meaningful progress' "$MAIN/state/.wake-queue" \
    || fail "chatter reset the meaningful-progress due clock"
  [ "$(grep -c 'child$' "$WORLD/state-reads" 2>/dev/null || true)" = 1 ] \
    || fail "overdue intervention performed more than one bounded current-state read: $(cat "$WORLD/state-reads" 2>/dev/null || true)"
  pass "overdue active work surfaces through a targeted wake despite chatter"
}

# A done or failed current-state verdict is a terminal outcome, not work that
# stopped making progress, so the terminal path owns it and no stale is queued.
test_terminal_verdict_is_not_surfaced_as_missing_progress() {
  make_world terminal-verdict
  write_child "$MAIN" child 'working: implementation is under way'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: done · source: run-step\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 0 ] \
    || fail "a terminal verdict was surfaced as missing progress: $(cat "$MAIN/state/.wake-queue")"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] \
    || fail "the terminal-outcome path did not own the done verdict"
  pass "a terminal current-state verdict is left to the terminal-outcome path"
}

# A cold cursor left by a dead watcher still anchors a rotating sweep. Even when
# that sweep is truncated before it wraps, the children at or before the cursor
# must still be reached rather than waiting out another whole interval.
test_cold_cursor_sweep_still_wraps_after_a_truncation() {
  make_world cold-cursor
  write_child "$MAIN" a 'done: green'
  write_child "$MAIN" b 'working: quietly under way'
  write_child "$MAIN" c 'working: state read will stall'
  write_child "$MAIN" d 'done: green'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
[ "$1" != c ] || sleep 30
case "$1" in
  a|d) printf 'state: done · source: fake\n' ;;
  *)   printf 'state: working · source: run-step\n' ;;
esac
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  printf 'epoch=1\ncursor=b\n' > "$MAIN/state/.inactive-outcome-reconcile"
  set_mtime "$(( $(date +%s) - 600 ))" "$MAIN/state/.inactive-outcome-reconcile"

  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN"
  ! grep -Fq 'child=a state=done' "$MAIN/state/.wake-queue" 2>/dev/null \
    || fail "the truncated first pass already wrapped back to the earlier child"
  run_reconcile "$MAIN"
  grep -Fq 'child=a state=done' "$MAIN/state/.wake-queue" \
    || fail "the resumed sweep dropped its outstanding wrap segment: $(cat "$MAIN/state/.wake-queue" 2>/dev/null)"
  pass "a truncated cold-cursor sweep still wraps back over its earlier children"
}

# `--help` renders this script's own contract block; a truncated render is the
# defect, and it shows up as output that stops mid-sentence.
test_help_renders_the_whole_contract_block() {
  local out last
  out=$("$RECON" --help) || fail "--help exited non-zero"
  [ -n "$out" ] || fail "--help printed nothing"
  last=$(printf '%s\n' "$out" | grep -v '^[[:space:]]*$' | tail -1)
  case "$last" in
    *.) : ;;
    *) fail "--help output stops mid-sentence: $last" ;;
  esac
  pass "--help renders a complete contract block"
}

# A garbled or failed current-state verdict is not evidence either way, so it
# must be absorbed rather than parsed into a state/source pair and surfaced.
test_unreadable_current_state_is_absorbed() {
  make_world garbled-state
  write_child "$MAIN" child 'working: implementation is under way'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'error: worktree probe failed\n'
exit 1
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 0 ] \
    || fail "a garbled current-state verdict was surfaced as a wedge: $(cat "$MAIN/state/.wake-queue")"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] \
    || fail "a garbled current-state verdict produced a terminal outcome"
  pass "an unreadable current-state verdict is absorbed instead of parsed"
}

# A live attributed run or a busy pane is the evidence crew_absorb_class calls
# provably working. Overdue status evidence alone must not surface it.
test_provably_working_evidence_is_not_overdue() {
  local now src
  for src in run-step pane; do
    make_world "liveness-$src"
    write_child "$MAIN" child 'working: implementation is under way'
    touch "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
    cat > "$WORLD/fakebin/fm-crew-state.sh" <<SH
#!/usr/bin/env bash
printf 'state: working · source: $src\n'
SH
    chmod +x "$WORLD/fakebin/fm-crew-state.sh"
    now=$(date +%s)
    FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
    FM_INACTIVE_RECONCILE_NOW=$((now + 600)) run_reconcile "$MAIN" --startup
    [ "$(stale_row_count "$MAIN")" = 0 ] \
      || fail "source=$src liveness was surfaced as overdue work: $(cat "$MAIN/state/.wake-queue")"
  done
  pass "a live run or busy pane is absorbed instead of surfaced as overdue"
}

test_unresolved_decision_is_routed_once_and_survives_restart() {
  make_world active-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] || fail "unresolved decision was not routed to the owning task"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] || fail "restart duplicated an unresolved decision wake"
  grep -Fq 'unresolved decision key=api-shape' "$MAIN/state/.wake-queue" \
    || fail "decision wake omitted its durable key"
  pass "unresolved decisions route durably without an automatic answer or storm"
}

test_declared_wait_and_parent_boundary_are_respected() {
  make_world active-boundaries
  write_child "$MAIN" child 'paused: waiting for upstream release'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "declared external wait was treated as overdue work"
  bind_secondmate local
  write_mate_meta
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -e "$MAIN/state/active-management/mate" ] \
    || fail "main took active management of a registered secondmate"
  pass "declared waits and the main/secondmate ownership boundary remain intact"
}

# The watcher's own stale row and this due-work path name the same task by its
# backend target, so a task already queued for intervention is never queued a
# second time for a branch or away drain to act on twice.
test_active_intervention_does_not_duplicate_an_existing_wake() {
  local now
  make_world no-duplicate
  fm_write_meta "$MAIN/state/child.meta" \
    'window=firstmate:fm-child' 'backend=orca' 'terminal=orca:child-endpoint' \
    'endpoint_task_id=child' "worktree=$MAIN/projects/child" 'project=alpha' \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' 'spawn_gen=s1'
  printf 'working: implementation is under way\n' > "$MAIN/state/child.status"
  : > "$MAIN/state/child.turn-ended"
  age "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; fm_wake_append stale "$2" "$3"' _ \
    "$ROOT/bin/fm-wake-lib.sh" 'orca:child-endpoint' 'stale: orca:child-endpoint' \
    || fail "could not seed the watcher's own stale row"

  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] \
    || fail "due-work intervention duplicated a queued stale row: $(cat "$MAIN/state/.wake-queue")"

  rm -f "$MAIN/state/.wake-queue"
  rm -rf "$MAIN/state/active-management"
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] || fail "due-work intervention queued no stale row of its own"
  awk -F '\t' '$3 == "stale" { print $4 }' "$MAIN/state/.wake-queue" \
    | grep -Fxq 'orca:child-endpoint' \
    || fail "due-work stale row was not keyed by the backend target: $(cat "$MAIN/state/.wake-queue")"
  pass "due-work intervention keys by backend target and never duplicates a queued row"
}

# The durable state/active-management/<task> record, not the live queue, is what
# holds the alert clock once a drain has acknowledged the row and supervision has
# restarted - and it must not suppress the obligation past its re-alert interval.
test_alert_clock_survives_drain_acknowledgement() {
  local now err seq generation
  local FM_PAUSE_RESURFACE_SECS=120
  make_world alert-clock
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] || fail "unresolved decision was not routed"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] || fail "acknowledgement did not consume the routed row"

  FM_INACTIVE_RECONCILE_NOW=$((now + 60)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "an answered-once decision re-alerted on the scan cadence instead of the re-surface cadence"
  FM_INACTIVE_RECONCILE_NOW=$((now + 119)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 0 ] \
    || fail "the durable alert clock did not survive acknowledgement and restart"
  FM_INACTIVE_RECONCILE_NOW=$((now + 120)) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "an unresolved obligation stayed suppressed past its re-surface interval"
  pass "the decision alert clock survives acknowledgement and re-surfaces on the fleet cadence"
}

# A sweep the aggregate budget truncated resumes on the next ordinary poll
# instead of waiting out another full interval, so the bound is per child.
test_budget_truncated_sweep_resumes_on_the_next_poll() {
  local reads
  make_world truncated-sweep
  write_child "$MAIN" a 'working: state read will stall'
  write_child "$MAIN" b 'done: green'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "${FM_STATE_READ_LOG:?}"
if [ "$1" = a ]; then sleep 30; else printf 'state: done · source: fake\n'; fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  : > "$WORLD/state-reads"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_reconcile "$MAIN" --startup
  ! grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" 2>/dev/null \
    || fail "the truncated sweep already reached the later child"
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_reconcile "$MAIN"
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "a cadence-gated poll refused to resume the truncated sweep"
  # The completed sweep clears the cursor, so the cadence gate re-arms and the
  # next poll must not re-probe anything.
  reads=$(wc -l < "$WORLD/state-reads")
  FM_STATE_READ_LOG="$WORLD/state-reads" FM_INACTIVE_RECONCILE_BUDGET_SECS=1 \
    run_reconcile "$MAIN"
  [ "$(wc -l < "$WORLD/state-reads")" = "$reads" ] \
    || fail "the resumed sweep never completed, so every poll re-enters the scan: $(cat "$WORLD/state-reads")"
  pass "a truncated sweep resumes on the next poll and re-arms the cadence once complete"
}

# status_line_verb ignores leading whitespace when it folds an event, so the
# cheap pre-fold guards must too: an indented event is a real event.
test_indented_status_events_are_not_skipped() {
  local now
  make_world indented-decision
  write_child "$MAIN" child '  needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'child.status')" = 1 ] \
    || fail "an indented needs-decision received no due-work check"

  make_world indented-working
  write_child "$MAIN" child '  working: implementation is under way'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: working · source: status-log\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  now=$(date +%s)
  FM_INACTIVE_RECONCILE_NOW="$now" run_reconcile "$MAIN" --startup
  [ "$(stale_row_count "$MAIN")" = 1 ] \
    || fail "an indented working phase received no due-work check"
  pass "indented status events are folded like any other"
}

# The away-mode daemon re-derives a signal row's actionability from the task's
# own status file, so a row queued here must be one its real classifier
# escalates - and a decision it cannot see must keep its drain surface instead.
test_decision_wake_is_actionable_to_the_away_classifier() {
  local payload decision
  make_world away-decision
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  payload=$(awk -F '\t' '$3 == "signal" { print $5 }' "$MAIN/state/.wake-queue")
  [ -n "$payload" ] || fail "unresolved decision queued no signal row"
  decision=$(PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$MAIN" \
    FM_STATE_OVERRIDE="$MAIN/state" bash -c '. "$1"; classify_signal "${2#signal: }" "$3"' _ \
    "$ROOT/bin/fm-supervise-daemon.sh" "$payload" "$MAIN/state")
  case "$decision" in
    escalate\|*) : ;;
    *) fail "away mode self-handled an unresolved decision instead of escalating: $decision" ;;
  esac

  make_world away-decision-buried
  write_child "$MAIN" child 'needs-decision [key=api-shape]: choose the API shape'
  printf 'working [key=impl]: continuing on the rest while blocked on api-shape\n' \
    >> "$MAIN/state/child.status"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  payload=$(awk -F '\t' '$3 == "signal" { print $5 }' "$MAIN/state/.wake-queue" 2>/dev/null || true)
  [ -z "$payload" ] \
    || fail "queued a decision signal away mode acknowledges without escalating: $payload"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" > "$WORLD/drain.out" 2>/dev/null
  grep -Fq 'api-shape' "$WORLD/drain.out" \
    || fail "buried decision lost its OPEN DECISIONS surface: $(cat "$WORLD/drain.out")"
  pass "decision wakes are only queued where the away classifier escalates them"
}

# A secondmate home applies the same bounded pass to its own direct children, so
# the evidence reaches the actor that owns it instead of being stranded or
# duplicated by the parent's lane.
test_secondmate_active_evidence_reaches_its_owning_actor() {
  make_world routed-active
  bind_secondmate local
  write_mate_meta
  write_child "$MATE" mate-child 'needs-decision [key=scope]: which module first'
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'mate-child.status')" = 1 ] \
    || fail "secondmate evidence never reached its own supervision queue"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "secondmate evidence was queued into the parent's lane"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MATE" --startup
  [ "$(wake_count "$MATE" 'mate-child.status')" = 1 ] || fail "a rescan duplicated the routed report"
  FM_INACTIVE_RECONCILE_NOW=$(date +%s) FM_FAKE_CREW_STATE=working run_reconcile "$MAIN" --startup
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "the parent duplicated the secondmate's routed report"
  pass "secondmate active-management evidence routes once to its owning actor"
}

# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_main_direct_terminal_presentation_receipt
test_local_secondmate_reports_terminal_child
test_local_secondmate_rejects_relative_parent_home
test_invalid_secondmate_marker_blocks_routing
test_remote_parent_reply_is_idempotent
test_reused_task_id_reports_each_incarnation
test_legacy_metadata_rewrite_keeps_receipt_identity
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_post_completion_pause_does_not_report_terminal_outcome
test_watcher_hook_and_idle_secondmate_exemption
test_stalled_state_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_notice_recovery_does_not_duplicate_wake
test_quiet_active_scan_does_not_read_current_state
test_overdue_active_work_ignores_chatter
test_provably_working_evidence_is_not_overdue
test_unreadable_current_state_is_absorbed
test_terminal_verdict_is_not_surfaced_as_missing_progress
test_cold_cursor_sweep_still_wraps_after_a_truncation
test_help_renders_the_whole_contract_block
test_indented_status_events_are_not_skipped
test_unresolved_decision_is_routed_once_and_survives_restart
test_alert_clock_survives_drain_acknowledgement
test_budget_truncated_sweep_resumes_on_the_next_poll
test_decision_wake_is_actionable_to_the_away_classifier
test_secondmate_active_evidence_reaches_its_owning_actor
test_declared_wait_and_parent_boundary_are_respected
test_active_intervention_does_not_duplicate_an_existing_wake
test_reconciliation_never_calls_forge

echo "all inactive reconciliation tests passed"
