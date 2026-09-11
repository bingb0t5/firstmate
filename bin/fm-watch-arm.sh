#!/usr/bin/env bash
# Safe, home-scoped (re-)arm of the firstmate watcher, with honest verification.
#
# The watcher (bin/fm-watch.sh) blocks until it has an actionable wake to
# surface, then prints one reason line and exits. While state/.afk exists the
# daemon owns triage and the watcher exits on every wake for the daemon to
# classify. Reliability depends on arming through a mechanism that SURVIVES the
# call and NOTIFIES on exit. The harness-specific foreground and background
# mechanisms are routed by docs/watcher-continuity.md; follow that protocol.
# When it calls for a tracked background task, run this script as its own
# standalone task, never bundled onto the tail of another command.
# NEVER fire it and forget with a shell `&` inside another call: that backgrounded
# child is reaped when the call returns, leaving NO watcher running and a false
# "already running" off the dying process. That exact mistake silently took
# supervision down for ~30 minutes.
# On a harness with a PreToolUse-equivalent hook, bin/fm-arm-pretool-check.sh
# applies the command-position policy before the command runs; see
# docs/arm-pretool-check.md for the blessed tree and deny reason codes. It is a
# pre-execution seatbelt, not a substitute for the verification here.
#
# This script forks the watcher as a tracked child, then VERIFIES the outcome
# before it settles in. It confirms a watcher process is genuinely alive AND the
# liveness beacon (state/.last-watcher-beat) is fresh within FM_GUARD_GRACE (the
# single source of truth, shared with fm-watch.sh and fm-guard.sh), and prints
# exactly one unambiguous status line:
#   watcher: started pid=<N> (beacon fresh)              - it launched one and confirmed it
#   watcher: attached pid=<N> (beacon <age>s)            - a live+fresh successor holds the lock;
#                                                          this arm attaches and follows it
#   watcher: FAILED - no live watcher with a fresh beacon  - could not confirm one
#   watcher: FAILED - cycle ended without an actionable reason
#                                                        - a clean cycle ended with no wake and no
#                                                          verified healthy successor
# It NEVER reports started/attached/healthy off a stale beacon or a dead/reused pid: a
# stale-beacon or dead-pid holder either self-heals (the fresh child steals the
# dead lock per the singleton self-eviction/steal path and is confirmed) or this
# returns the FAILED line. On started it waits the child and propagates the wake
# reason; on attached it stays live across identity-matched successors. A cycle
# that ends with no reason line and no healthy successor is resolved against the
# watcher's identity-bound delivery record: a matching record reports that wake
# and exits 0, and only a cycle that delivered nothing is the typed nonzero
# failure. Neither is ever a clean empty completion. On FAILED it exits non-zero
# so the failure is loud. A live cycle already present means re-arm attaches - do
# not start a second watcher.
# `--detached` is the bounded Stop-hook entry point: it starts the same watcher
# in a new session with all standard and inherited descriptors closed, confirms
# the home lock and fresh beacon, then returns while the watcher continues.
#
# Every observed watcher cycle appends one tab-separated lifecycle record to
# state/.watch-cycle-exits.log. The arm layer owns that bounded ledger; it records
# arm/watcher identities, timestamps, exit/signal classification, beacon age,
# lock identity before and after close, and successor disposition. The separate
# state/.watch-triage.log remains exclusively the watcher's absorbed-wake debug
# log and is never written here.
#
# --restart: stop ONLY this FM_HOME's watcher (the pid recorded in THIS home's
# state/.watch.lock) and own a fresh cycle, or attach if a verified live peer
# wins the singleton while the duplicate child stands down. It
# resolves and signals exactly that pid, so it can never touch another home's
# watcher. NEVER `pkill -f
# bin/fm-watch.sh`: that pattern matches every firstmate home's watcher
# (secondmate homes run the same script) and would kill siblings.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-watch-launch-lib.sh
. "$SCRIPT_DIR/fm-watch-launch-lib.sh"

CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
# shellcheck source=bin/fm-watch-config-lib.sh
. "$SCRIPT_DIR/fm-watch-config-lib.sh"
fm_watch_config_load "$CONFIG/watch.env"

WATCH="$SCRIPT_DIR/fm-watch.sh"
WATCH_LOCK="$STATE/.watch.lock"
BEAT="$STATE/.last-watcher-beat"
# "Fresh" reuses the guard's threshold so there is one definition of liveness.
GRACE=${FM_GUARD_GRACE:-300}
# How long to wait for a freshly forked watcher to acquire the lock and beat.
# Git Bash/MSYS pays a much higher fork cost while the watcher completes its
# required pre-lock migration, so its bounded default covers that cold start.
case "${OSTYPE:-}" in
  msys*|mingw*|cygwin*) ARM_CONFIRM_DEFAULT=30 ;;
  *) ARM_CONFIRM_DEFAULT=10 ;;
esac
CONFIRM_TIMEOUT=${FM_ARM_CONFIRM_TIMEOUT:-$ARM_CONFIRM_DEFAULT}
# Poll interval while attached to an existing healthy watcher.
ATTACH_POLL=${FM_ARM_ATTACH_POLL:-0.5}
CYCLE_LOG="$STATE/.watch-cycle-exits.log"
CYCLE_LOG_LOCK="$STATE/.watch-cycle-exits.lock"
CYCLE_LOG_MAX_BYTES=${FM_WATCH_CYCLE_LOG_MAX_BYTES:-262144}
CYCLE_LOG_KEEP_LINES=${FM_WATCH_CYCLE_LOG_KEEP_LINES:-1000}
ARM_PID=${BASHPID:-$$}
case "$CYCLE_LOG_MAX_BYTES" in ''|*[!0-9]*|0) CYCLE_LOG_MAX_BYTES=262144 ;; esac
case "$CYCLE_LOG_KEEP_LINES" in ''|*[!0-9]*|0) CYCLE_LOG_KEEP_LINES=1000 ;; esac

# The lifecycle ledger is diagnostic evidence, not a supervision dependency.
# Writes are bounded and best-effort so an observability failure cannot stall an
# otherwise healthy watcher cycle.
cycle_clean_field() {
  printf '%s' "$1" | tr '\t\r\n' '   ' | cut -c1-512
}

lock_snapshot() {
  local pid identity
  pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  printf 'pid:%s|identity:%s' "$(cycle_clean_field "${pid:-none}")" "$(cycle_clean_field "${identity:-none}")"
}

WATCH_DELIVERY_LOG="$STATE/.watch-deliveries.log"
WATCH_DELIVERY_LOCK="$STATE/.watch-deliveries.lock"

cycle_active=0
cycle_watcher_pid=none
cycle_watcher_identity=none
cycle_origin=unknown
cycle_started_at=0
cycle_lock_before='pid:none|identity:none'

cycle_begin() {
  cycle_watcher_pid=$1
  cycle_origin=$2
  cycle_watcher_identity=$3
  cycle_started_at=$(date +%s)
  cycle_lock_before=$(lock_snapshot)
  cycle_active=1
}

cycle_refresh_lock_before() {
  [ "$cycle_active" -eq 1 ] || return 0
  if [ "$HEALTHY_PID" = "$cycle_watcher_pid" ] && [ -n "$HEALTHY_IDENTITY" ]; then
    cycle_watcher_identity=$HEALTHY_IDENTITY
  fi
  cycle_lock_before=$(lock_snapshot)
}

cycle_signal_name() {
  local rc=$1 signal_number
  case "$rc" in
    ''|*[!0-9]*) printf 'unknown'; return ;;
  esac
  [ "$rc" -gt 128 ] || { printf 'none'; return; }
  signal_number=$((rc - 128))
  kill -l "$signal_number" 2>/dev/null || printf '%s' "$signal_number"
}

cycle_log_append() {
  local exit_code=$1 signal=$2 reason=$3 successor=$4 ended_at beacon_age lock_after size tmp raw i
  [ "$cycle_active" -eq 1 ] || return 0
  ended_at=$(date +%s)
  beacon_age=$(fm_path_age "$BEAT")
  lock_after=$(lock_snapshot)

  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  printf 'arm_pid=%s\twatcher_pid=%s\torigin=%s\tstarted_at=%s\tended_at=%s\texit_code=%s\tsignal=%s\treason=%s\tbeacon_age=%s\tlock_before=%s\tlock_after=%s\tsuccessor=%s\n' \
    "$ARM_PID" \
    "$(cycle_clean_field "$cycle_watcher_pid")" \
    "$(cycle_clean_field "$cycle_origin")" \
    "$cycle_started_at" \
    "$ended_at" \
    "$(cycle_clean_field "$exit_code")" \
    "$(cycle_clean_field "$signal")" \
    "$(cycle_clean_field "$reason")" \
    "$beacon_age" \
    "$(cycle_clean_field "$cycle_lock_before")" \
    "$(cycle_clean_field "$lock_after")" \
    "$(cycle_clean_field "$successor")" >> "$CYCLE_LOG" 2>/dev/null || true

  size=$(wc -c < "$CYCLE_LOG" 2>/dev/null | tr -d '[:space:]')
  case "$size" in
    ''|*[!0-9]*) ;;
    *)
      if [ "$size" -ge "$CYCLE_LOG_MAX_BYTES" ]; then
        tmp="$CYCLE_LOG.tmp.$ARM_PID"
        raw="$tmp.raw"
        tail -n "$CYCLE_LOG_KEEP_LINES" "$CYCLE_LOG" 2>/dev/null \
          | tail -c "$CYCLE_LOG_MAX_BYTES" > "$raw" 2>/dev/null \
          && awk 'NR > 1 || /^arm_pid=/' "$raw" > "$tmp" 2>/dev/null \
          && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
        rm -f "$tmp" "$raw" 2>/dev/null || true
      fi
      ;;
  esac
  fm_lock_release "$CYCLE_LOG_LOCK"
  cycle_active=0
}

# A persistent adapter passes the arm pid that just closed. Once this new arm
# verifies its watcher, update that predecessor's final record in place so the
# one-record-per-cycle ledger captures the actual successor outcome without an
# extra synthetic lifecycle row.
cycle_mark_predecessor_successor() {
  local successor=$1 predecessor=${FM_WATCH_PREDECESSOR_ARM_PID:-} i tmp
  case "$predecessor" in
    ''|*[!0-9]*) return 0 ;;
  esac
  [ -f "$CYCLE_LOG" ] || return 0
  i=0
  while ! fm_lock_try_acquire "$CYCLE_LOG_LOCK"; do
    [ "$i" -lt 20 ] || return 0
    sleep 0.02
    i=$((i + 1))
  done
  tmp="$CYCLE_LOG.link.$ARM_PID"
  awk -v target="arm_pid=$predecessor" -v replacement="successor=$(cycle_clean_field "$successor")" '
    {
      lines[NR] = $0
      count = split($0, fields, "\t")
      if (fields[1] == target) {
        for (i = 1; i <= count; i += 1) {
          if (fields[i] == "successor=none") last = NR
        }
      }
    }
    END {
      for (i = 1; i <= NR; i += 1) {
        if (i == last) sub(/\tsuccessor=none$/, "\t" replacement, lines[i])
        print lines[i]
      }
    }
  ' "$CYCLE_LOG" > "$tmp" 2>/dev/null && mv -f "$tmp" "$CYCLE_LOG" 2>/dev/null
  rm -f "$tmp" 2>/dev/null || true
  fm_lock_release "$CYCLE_LOG_LOCK"
}

clear_stale_recorded_watcher_lock() {
  local lock_home lock_path lock_identity
  lock_home=$(cat "$WATCH_LOCK/fm-home" 2>/dev/null || true)
  lock_path=$(cat "$WATCH_LOCK/watcher-path" 2>/dev/null || true)
  lock_identity=$(cat "$WATCH_LOCK/pid-identity" 2>/dev/null || true)
  [ "$lock_home" = "$FM_HOME" ] || return 0
  [ "$lock_path" = "$WATCH" ] || return 0
  [ -n "$lock_identity" ] || return 0
  fm_recovery_transition "$STATE/.watcher-down" clear-stale-lock "$WATCH_LOCK" downtime
}

# A watcher is "healthy" iff the lock names a live process that is genuinely THIS
# home's watcher (the identity match guards against a recycled/reused pid) AND the
# liveness beacon is fresh within GRACE. Sets HEALTHY_PID on success. This is the
# single honesty gate: a dead pid, a reused pid, or a stale beacon all fail it, so
# this script can never report a watcher that is not really there.
HEALTHY_PID=
HEALTHY_IDENTITY=
healthy_watcher() {
  HEALTHY_PID=
  HEALTHY_IDENTITY=
  fm_watcher_healthy "$STATE" "$WATCH" "$GRACE" "$FM_HOME" || return 1
  HEALTHY_PID=$FM_WATCHER_HEALTHY_PID
  HEALTHY_IDENTITY=$FM_WATCHER_HEALTHY_IDENTITY
}

report_attached() {
  local age
  age=$(fm_path_age "$BEAT")
  echo "watcher: attached pid=$HEALTHY_PID (beacon ${age}s)"
}

# Give a successor the same bounded confirmation window used for a fresh child.
# Adapter-owned continuations normally win immediately, but the bound avoids a
# false failure when process-close delivery and lock publication cross briefly.
wait_for_healthy_successor() {
  local deadline
  # date(1) exposes whole seconds. Add one rounding second so a timeout of one
  # second cannot collapse to a few milliseconds when called near a boundary.
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  while :; do
    healthy_watcher && return 0
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.2
  done
}

fail_unexplained_cycle() {
  echo "watcher: FAILED - cycle ended without an actionable reason"
  return 1
}

# Launch one watcher in a new session without inheriting the Stop hook's pipe.
# Perl is already a required Firstmate runtime dependency for process-event
# isolation, and POSIX::setsid is available on the Unix platforms this watcher
# supports. The parent writes the exact watcher pid before exiting so the arm
# layer can apply its normal bounded lock/beacon confirmation.
launch_detached_watcher() {
  local launch_dir=$1
  command -v perl >/dev/null 2>&1 || return 1
  perl -MPOSIX -MTime::HiRes=time,sleep -e '
    my ($dir, $script, $timeout) = @ARGV;
    defined(my $pid = fork) or exit 125;
    if ($pid == 0) {
      POSIX::setsid() >= 0 or exit 125;
      my $fds;
      opendir($fds, "/proc/self/fd") || opendir($fds, "/dev/fd") or exit 125;
      my @fds = grep { /^\d+$/ && $_ > 2 } readdir($fds);
      closedir($fds);
      POSIX::close($_) for @fds;
      open STDIN,  "<", "/dev/null" or exit 125;
      open STDOUT, ">", "/dev/null" or exit 125;
      open STDERR, ">", "/dev/null" or exit 125;
      exec $script, "--detached-run", $dir;
      exit 125;
    }
    my $deadline = time + $timeout;
    while (time < $deadline) {
      if (-s "$dir/owner") {
        open my $ready, ">", "$dir/proceed" or exit 125;
        close $ready or exit 125;
        exit 0;
      }
      if (waitpid($pid, POSIX::WNOHANG()) == $pid) {
        exit(-s "$dir/owner" ? 0 : 125);
      }
      sleep 0.02;
    }
    kill "STOP", $pid;
    kill "TERM", -$pid;
    sleep 0.2;
    kill "KILL", -$pid;
    kill "KILL", $pid;
    waitpid $pid, 0;
    exit 125;
  ' "$launch_dir" "$SCRIPT_DIR/fm-watch-arm.sh" "$CONFIRM_TIMEOUT" </dev/null >/dev/null 2>&1
}

# Close a cycle whose reason line this arm could not read against the bounded
# terminal-delivery ledger the watcher publishes before releasing its lock.
close_unobserved_cycle() {
  local i reason clean_identity record_pid record_identity record_reason
  clean_identity=$(printf '%s' "$cycle_watcher_identity" | tr '\t\r\n' '   ')
  i=0
  while ! fm_lock_try_acquire "$WATCH_DELIVERY_LOCK"; do
    [ "$i" -lt 20 ] || {
      fail_unexplained_cycle
      return 1
    }
    sleep 0.02
    i=$((i + 1))
  done
  reason=
  if [ -f "$WATCH_DELIVERY_LOG" ]; then
    while IFS=$'\t' read -r record_pid record_identity record_reason; do
      if [ "$record_pid" = "$cycle_watcher_pid" ] && [ "$record_identity" = "$clean_identity" ]; then
        reason=$record_reason
      fi
    done < "$WATCH_DELIVERY_LOG"
  fi
  fm_lock_release "$WATCH_DELIVERY_LOCK"
  if [ -n "$reason" ]; then
    printf '%s\n' "$reason"
    return 0
  fi
  fail_unexplained_cycle
  return 1
}

# Stay alive across identity-matched healthy holders. If one cycle ends, attach
# to a verified successor. With no successor, report the wake that cycle durably
# delivered, or fail loudly - never a clean empty completion that an adapter could
# mistake for a no-op.
attach_and_wait() {
  local attached_pid=$1 attachment_mode=${2:-follow}
  while :; do
    [ "$attachment_mode" != detached ] || [ "$detached_cancelled" -eq 0 ] || return 1
    if healthy_watcher; then
      if [ "$HEALTHY_PID" != "$attached_pid" ] || [ "$HEALTHY_IDENTITY" != "$cycle_watcher_identity" ]; then
        [ "$attachment_mode" != detached ] || return 3
        cycle_log_append unknown unknown lock-replaced "attached:$HEALTHY_PID"
        attached_pid=$HEALTHY_PID
        cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
        report_attached
      fi
      sleep "$ATTACH_POLL"
      continue
    fi
    if wait_for_healthy_successor; then
      if [ "$attachment_mode" = detached ] && { [ "$HEALTHY_PID" != "$attached_pid" ] || [ "$HEALTHY_IDENTITY" != "$cycle_watcher_identity" ]; }; then
        return 3
      fi
      cycle_log_append unknown unknown attached-cycle-ended "attached:$HEALTHY_PID"
      attached_pid=$HEALTHY_PID
      cycle_begin "$attached_pid" attached "$HEALTHY_IDENTITY"
      report_attached
      continue
    fi
    if close_unobserved_cycle; then
      cycle_log_append unknown unknown attached-delivered-wake none
      return 0
    fi
    cycle_log_append unknown unknown attached-cycle-ended none
    return 1
  done
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_attached_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  cycle_log_append "$rc" "$signal" arm-interrupted none
  exit "$rc"
}

trap 'handle_attached_signal HUP 129' HUP
trap 'handle_attached_signal TERM 143' TERM
trap 'handle_attached_signal INT 130' INT

watch_output_has_wake() {
  local out=$1
  grep -Eq '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null
}

watch_output_reason_type() {
  local out=$1 line
  line=$(grep -E '^(signal:|stale:|check:|heartbeat($|:))' "$out" 2>/dev/null | head -1 || true)
  case "$line" in
    signal:*) printf 'actionable-signal' ;;
    stale:*) printf 'actionable-stale' ;;
    check:*) printf 'actionable-check' ;;
    heartbeat*) printf 'actionable-heartbeat' ;;
    *) printf 'none' ;;
  esac
}

print_watch_output() {
  local out=$1
  [ -s "$out" ] && cat "$out"
}

handling_successor_generation() {
  [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ] || return 0
  fm_recovery_marker_snapshot "$STATE/.watcher-down" || return 1
  case "$FM_RECOVERY_MARKER_TOKEN" in
    pending:downtime:*|pending:handling:*|announced:downtime:*|announced:handling:*) printf '%s' "${FM_RECOVERY_MARKER_TOKEN##*:}" ;;
    acked:*|'') ;;
    *) return 1 ;;
  esac
}

bind_detached_session() {
  local dir=$1 pid identity
  if [ -z "${FM_HOME_WAKE_BACKEND:-}" ] || [ -z "${FM_HOME_WAKE_TARGET:-}" ]; then
    [ "${FM_WATCH_NOTIFY_REQUIRED:-0}" != 1 ] && return 0
    echo "watcher: FAILED - detached Stop requires a bound home notification endpoint; relaunch this secondmate through fm-spawn.sh" >&2
    return 1
  fi
  # shellcheck source=bin/fm-session-lock-lib.sh
  . "$SCRIPT_DIR/fm-session-lock-lib.sh"
  if ! fm_session_lock_owned_by_self "$STATE"; then
    echo "watcher: FAILED - detached notification requires the owning home session" >&2
    return 1
  fi
  pid=$(cat "$STATE/.lock")
  identity=$(fm_pid_identity "$pid") || return 1
  printf '%s\t%s\t%s\t%s\n' "$pid" "$identity" "$FM_HOME_WAKE_BACKEND" "$FM_HOME_WAKE_TARGET" > "$dir/session.tmp.$ARM_PID" \
    && mv -f "$dir/session.tmp.$ARM_PID" "$dir/session"
}

session_binding_is_current() {
  local dir=$1 lock_pid lock_identity
  fm_watch_launch_session "$dir" || return 1
  lock_pid=$(cat "$STATE/.lock" 2>/dev/null || true)
  [ "$lock_pid" = "$LAUNCH_SESSION_PID" ] || return 1
  lock_identity=$(fm_pid_identity "$lock_pid" 2>/dev/null || true)
  [ -n "$lock_identity" ] && [ "$lock_identity" = "$LAUNCH_SESSION_IDENTITY" ]
}

bind_healthy_completion() {
  local source_dir=${1:-} pid=$HEALTHY_PID identity=$HEALTHY_IDENTITY dir lock_dir i=0 created=0 rc=0
  until fm_lock_try_acquire "$STATE/.watch-attach.lock"; do
    [ "$i" -lt 50 ] || return 1
    sleep 0.02
    i=$((i + 1))
  done
  dir=$(cat "$WATCH_LOCK/watcher-launch" 2>/dev/null || true)
  if ! fm_watch_launch_read "$dir" || ! fm_watch_launch_owner "$dir" \
      || [ "$LAUNCH_PID" != "$pid" ] || [ "$LAUNCH_IDENTITY" != "$identity" ]; then
    dir=$(mktemp -d "$STATE/.watch-arm-detached.XXXXXX") || {
      fm_lock_release "$STATE/.watch-attach.lock"
      return 1
    }
    created=1
    printf '%s\t%s\n' "$pid" "$identity" > "$dir/identity" && touch "$dir/attach" || rc=1
  fi
  i=0
  until fm_lock_try_acquire "$dir/handoff.lock"; do
    [ "$i" -lt 50 ] || { rc=1; break; }
    sleep 0.02
    i=$((i + 1))
  done
  if [ "$rc" -eq 0 ]; then
    if [ -n "$source_dir" ]; then
      if session_binding_is_current "$dir"; then
        :
      elif session_binding_is_current "$source_dir"; then
        cat "$source_dir/session" > "$dir/session.tmp.$ARM_PID" \
          && mv -f "$dir/session.tmp.$ARM_PID" "$dir/session" || rc=1
      else
        rc=1
      fi
    else
      bind_detached_session "$dir" || rc=1
    fi
    [ "$rc" -ne 0 ] || touch "$dir/accepted" || rc=1
    if [ "$rc" -eq 0 ] && [ "$created" -eq 1 ]; then
      lock_dir=$(cd "$WATCH_LOCK" 2>/dev/null && pwd -P) || lock_dir=
      if [ -n "$lock_dir" ] && [ "$(cat "$lock_dir/pid-identity" 2>/dev/null || true)" = "$identity" ]; then
        if ! printf '%s\n' "$dir" > "$lock_dir/watcher-launch"; then
          fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$pid" "$FM_HOME" && rc=1
        fi
      fi
      [ "$rc" -ne 0 ] || launch_detached_watcher "$dir" || rc=1
    fi
    fm_lock_release "$dir/handoff.lock"
  fi
  fm_lock_release "$STATE/.watch-attach.lock"
  if [ "$rc" -ne 0 ]; then
    if [ "$created" -eq 1 ]; then
      fm_watch_launch_retire "$dir" && rm -rf "$dir"
    fi
    echo "watcher: FAILED - could not bind existing watcher completion" >&2
  fi
  HEALTHY_PID=$pid
  HEALTHY_IDENTITY=$identity
  return "$rc"
}

mode=arm
handling_generation=
handling_watcher_pid=
case "${1:-}" in
  ''|arm|--arm) mode=arm ;;
  --detached) mode=detached ;;
  --detached-run|--detached-complete)
    [ "$#" -eq 2 ] || exit 2
    mode=${1#--}
    detached_dir=$2
    ;;
  --restart) mode=restart ;;
  --handling-delivered)
    mode=handling-delivered
    handling_generation=${2:-}
    [ "${3:-}" = --watcher-pid ] || { echo "watcher: invalid handling delivery confirmation" >&2; exit 2; }
    handling_watcher_pid=${4:-}
    case "$handling_generation" in ''|*[!A-Za-z0-9._-]*) echo "watcher: invalid recovery generation" >&2; exit 2 ;; esac
    case "$handling_watcher_pid" in ''|*[!0-9]*) echo "watcher: invalid successor watcher pid" >&2; exit 2 ;; esac
    [ "$#" -eq 4 ] || { echo "watcher: unexpected handling delivery arguments" >&2; exit 2; }
    ;;
  *) echo "usage: $(basename "$0") [--detached | --restart | --handling-delivered GENERATION --watcher-pid PID]" >&2; exit 2 ;;
esac

if [ "$mode" = handling-delivered ]; then
  fm_pid_alive "$handling_watcher_pid" \
    && fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$handling_watcher_pid" "$FM_HOME" \
    && fm_recovery_marker_begin_handling "$STATE/.watcher-down" "$handling_generation"
  exit $?
fi

if [ "$mode" = restart ]; then
  # Home-scoped stop: only the watcher pid recorded in THIS home's lock.
  lock_pid=$(cat "$WATCH_LOCK/pid" 2>/dev/null || true)
  if fm_pid_alive "$lock_pid"; then
    if fm_watcher_lock_matches_pid "$STATE" "$WATCH" "$lock_pid" "$FM_HOME"; then
      kill -TERM "$lock_pid" 2>/dev/null || true
      # Wait for it to actually exit before relaunching, so the fresh watcher
      # either takes a released lock or reclaims a now-dead-pid stale lock instead
      # of seeing the dying one as a live holder and no-opping.
      i=0
      while [ "$i" -lt 50 ] && fm_pid_alive "$lock_pid"; do
        sleep 0.1
        i=$((i + 1))
      done
    else
      if ! clear_stale_recorded_watcher_lock; then
        echo "watcher: FAILED - stale watcher recovery state could not be persisted" >&2
        exit 1
      fi
    fi
  fi
fi

# If a genuinely live+fresh watcher already holds the lock, do not start a second
# one - attach to that cycle and wait until it ends so the harness notify fires
# then, not as an immediate empty wake. (--restart skips this: it just stopped
# this home's watcher and wants a fresh one.)
if [ "$mode" = detached ] && healthy_watcher; then
  bind_healthy_completion || exit 1
  report_attached
  exit 0
fi

if [ "$mode" = arm ] && healthy_watcher; then
  cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
  cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
  report_attached
  attach_and_wait "$HEALTHY_PID"
  exit $?
fi

if [ "$mode" = detached-run ]; then
  case "$detached_dir" in "$STATE"/.watch-arm-detached.*) ;; *) exit 1 ;; esac
  case "${detached_dir#"$STATE"/.watch-arm-detached.}" in ''|*/*) exit 1 ;; esac
  [ -d "$detached_dir" ] && [ ! -L "$detached_dir" ] || exit 1
  detached_child=
  detached_cancelled=0
  cancel_detached_child() {
    local parent group
    detached_cancelled=1
    trap '' HUP INT TERM
    [ -n "$detached_child" ] || return 0
    parent=$(ps -o ppid= -p "$detached_child" | tr -d '[:space:]')
    [ "$parent" = "$ARM_PID" ] || return 0
    kill -STOP "$detached_child" 2>/dev/null || return 0
    parent=$(ps -o ppid= -p "$detached_child" | tr -d '[:space:]')
    if [ "$parent" != "$ARM_PID" ]; then
      kill -CONT "$detached_child" 2>/dev/null || true
      return 1
    fi
    group=$(ps -o pgid= -p "$detached_child" | tr -d '[:space:]')
    if [ "$group" = "$detached_child" ]; then
      kill -TERM -- "-$detached_child" 2>/dev/null || true
      sleep 0.2
      kill -KILL -- "-$detached_child" 2>/dev/null || true
    fi
    kill -KILL "$detached_child" 2>/dev/null || true
    wait "$detached_child" 2>/dev/null || true
  }
  trap cancel_detached_child HUP INT TERM
  owner_identity=$(fm_pid_identity "$ARM_PID") || exit 1
  printf '%s\t%s\n' "$ARM_PID" "$owner_identity" > "$detached_dir/owner.tmp" \
    && mv -f "$detached_dir/owner.tmp" "$detached_dir/owner" || exit 1
  ready_deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  until [ -f "$detached_dir/proceed" ]; do
    [ "$detached_cancelled" -eq 0 ] && [ "$(date +%s)" -lt "$ready_deadline" ] || exit 1
    sleep 0.02
  done
  [ "$detached_cancelled" -eq 0 ] || exit 1
  if [ -f "$detached_dir/attach" ]; then
    fm_watch_launch_read "$detached_dir" || exit 1
    cycle_begin "$LAUNCH_PID" attached "$LAUNCH_IDENTITY"
    attach_and_wait "$LAUNCH_PID" detached
    detached_status=$?
    [ "$detached_cancelled" -eq 0 ] || exit 1
    if [ "$detached_status" -eq 3 ]; then
      bind_healthy_completion "$detached_dir" || exit 1
      rm -rf "$detached_dir"
      exit 0
    fi
    detached_child=$cycle_watcher_pid
  else
    FM_WATCH_LAUNCH_DIR="$detached_dir" perl -MPOSIX -e 'POSIX::setsid() >= 0 or exit 125; exec $ARGV[0]; exit 125' "$WATCH" &
    detached_child=$!
    if [ "$detached_cancelled" -eq 1 ]; then cancel_detached_child; fi
    wait "$detached_child"
    detached_status=$?
  fi
  trap '' HUP INT TERM
  WATCH_LAUNCH_PID=$detached_child
  WATCH_LAUNCH_IDENTITY=
  detached_reason=
  if fm_watch_launch_read "$detached_dir"; then
    WATCH_LAUNCH_IDENTITY=$LAUNCH_IDENTITY
    cycle_begin "$LAUNCH_PID" detached "$LAUNCH_IDENTITY"
    if [ "$detached_status" -eq 0 ]; then
      detached_reason=$(close_unobserved_cycle) || detached_reason=
    fi
  fi
  i=0
  until fm_lock_try_acquire "$detached_dir/handoff.lock"; do
    [ "$i" -lt 50 ] || exit 1
    sleep 0.02
    i=$((i + 1))
  done
  if ! fm_watch_launch_record "$detached_dir" "$detached_status" "$detached_reason"; then
    fm_lock_release "$detached_dir/handoff.lock"
    exit 1
  fi
  detached_notify=0
  [ ! -f "$detached_dir/accepted" ] || detached_notify=1
  fm_lock_release "$detached_dir/handoff.lock"
  if [ "$detached_notify" -eq 1 ]; then
    "$SCRIPT_DIR/fm-watch-arm.sh" --detached-complete "$detached_dir"
    exit $?
  fi
  exit 0
fi

if [ "$mode" = detached-complete ]; then
  fm_watch_launch_read "$detached_dir" && fm_watch_launch_result "$detached_dir" || exit 1
  fm_watch_launch_owner "$detached_dir" || exit 1
  [ -f "$detached_dir/accepted" ] || exit 1
  cycle_begin "$LAUNCH_PID" detached "$LAUNCH_IDENTITY"
  if [ "$LAUNCH_STATUS" -eq 0 ] && [ -n "$LAUNCH_REASON" ] && close_unobserved_cycle; then
    cycle_log_append 0 none detached-delivered-wake none
  elif healthy_watcher && { [ "$HEALTHY_PID" != "$LAUNCH_PID" ] || [ "$HEALTHY_IDENTITY" != "$LAUNCH_IDENTITY" ]; }; then
    bind_healthy_completion "$detached_dir" || exit 1
    cycle_log_append "$LAUNCH_STATUS" none detached-lock-race "attached:$HEALTHY_PID"
    rm -rf "$detached_dir"
    exit 0
  else
    cycle_log_append 1 none detached-start-failed none
    fm_wake_append check watcher-failed 'check: watcher failed after detached startup; inspect watcher recovery before relying on unattended supervision' || exit 1
  fi
  if fm_watch_launch_session "$detached_dir"; then
    while :; do
      "$SCRIPT_DIR/fm-home-wake.sh" "$LAUNCH_BACKEND" "$LAUNCH_TARGET" \
        --watcher-complete "$detached_dir" > "$detached_dir/notification-output" 2>&1 || true
      notification=$(cat "$detached_dir/notification" 2>/dev/null || true)
      case "$notification" in
        delivered|settled) break ;;
        superseded) exit 0 ;;
      esac
      sleep 1
    done
  fi
  rm -rf "$detached_dir"
  exit 0
fi

if [ "$mode" = detached ]; then
  cycle_begin none detached none
  trap 'rc=$?; if [ "$rc" -ne 0 ]; then cycle_log_append "$rc" none detached-start-failed none; fi' EXIT
  detached_dir=$(mktemp -d "$STATE/.watch-arm-detached.XXXXXX") || {
    echo "watcher: FAILED - could not prepare detached launch" >&2
    exit 1
  }
  if ! bind_detached_session "$detached_dir"; then
    rm -rf "$detached_dir"
    exit 1
  fi
  deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
  if ! launch_detached_watcher "$detached_dir"; then
    rm -rf "$detached_dir"
    echo "watcher: FAILED - detached launch did not publish a watcher identity" >&2
    exit 1
  fi
  while ! fm_watch_launch_read "$detached_dir"; do
    if [ -f "$detached_dir/result" ] || [ "$(date +%s)" -ge "$deadline" ]; then
      fm_watch_launch_retire "$detached_dir" || exit 1
      rm -rf "$detached_dir"
      echo "watcher: FAILED - detached watcher did not publish its post-exec identity" >&2
      exit 1
    fi
    sleep 0.02
  done
  child=$LAUNCH_PID
  cycle_begin "$child" detached "$LAUNCH_IDENTITY"
  while :; do
    if fm_lock_try_acquire "$detached_dir/handoff.lock"; then
      if [ -f "$detached_dir/result" ]; then
        fm_watch_launch_result "$detached_dir"
        result_rc=$?
        fm_lock_release "$detached_dir/handoff.lock"
        if [ "$result_rc" -eq 0 ] && [ "$LAUNCH_STATUS" -eq 0 ] && [ -n "$LAUNCH_REASON" ] && close_unobserved_cycle; then
          cycle_log_append 0 none detached-delivered-wake none
          rm -rf "$detached_dir"
          exit 0
        fi
        if healthy_watcher; then
          bind_healthy_completion || exit 1
          cycle_log_append 0 none detached-lock-race "attached:$HEALTHY_PID"
          report_attached
          rm -rf "$detached_dir"
          exit 0
        fi
        cycle_log_append 1 none detached-start-failed none
        rm -rf "$detached_dir"
        echo "watcher: FAILED - detached watcher exited before health confirmation" >&2
        exit 1
      fi
      if healthy_watcher; then
        if [ "$HEALTHY_PID" = "$child" ] && [ "$HEALTHY_IDENTITY" = "$LAUNCH_IDENTITY" ]; then
          cycle_refresh_lock_before
          cycle_log_append 0 none detached-start "live:$child"
          if ! touch "$detached_dir/accepted"; then
            fm_lock_release "$detached_dir/handoff.lock"
            break
          fi
          fm_lock_release "$detached_dir/handoff.lock"
          echo "watcher: started pid=$child (beacon fresh) detached"
          exit 0
        fi
        fm_lock_release "$detached_dir/handoff.lock"
        fm_watch_launch_retire "$detached_dir" || exit 1
        bind_healthy_completion || exit 1
        cycle_log_append 0 none detached-lock-race "attached:$HEALTHY_PID"
        report_attached
        rm -rf "$detached_dir"
        exit 0
      fi
      fm_lock_release "$detached_dir/handoff.lock"
    fi
    [ "$(date +%s)" -ge "$deadline" ] && break
    sleep 0.05
  done
  if fm_watch_launch_retire "$detached_dir"; then
    rm -rf "$detached_dir"
  fi
  cycle_log_append 1 none confirmation-timeout none
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
fi

# Start a watcher as a tracked child and confirm it before settling in. The child
# stays our child for its whole life: we wait on it, so killing this arm (the
# harness-tracked task) tears the watcher down too, and the watcher's eventual
# wake exit propagates out so the harness re-notifies firstmate.
child=
child_out=
cleanup_child() {
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
  fi
  if [ -n "$child_out" ]; then
    rm -f "$child_out" 2>/dev/null || true
  fi
}

# shellcheck disable=SC2329 # Invoked indirectly by the signal traps below.
handle_arm_signal() {
  local signal=$1 rc=$2
  trap - HUP TERM INT
  if [ -n "$child" ] && fm_pid_alive "$child"; then
    kill -TERM "$child" 2>/dev/null || true
    wait "$child" 2>/dev/null || true
  fi
  cycle_log_append "$rc" "$signal" arm-interrupted none
  cleanup_child
  exit "$rc"
}

trap 'handle_arm_signal HUP 129' HUP
trap 'handle_arm_signal TERM 143' TERM
trap 'handle_arm_signal INT 130' INT

child_out=$(mktemp "$STATE/.watch-arm-output.XXXXXX") || {
  echo "watcher: FAILED - no live watcher with a fresh beacon"
  exit 1
}
if [ -n "${FM_WATCH_PREDECESSOR_ARM_PID:-}" ]; then
  FM_WATCH_HANDLING_SUCCESSOR=1 "$WATCH" >"$child_out" &
else
  "$WATCH" >"$child_out" &
fi
child=$!
cycle_begin "$child" started "$(fm_pid_identity "$child" 2>/dev/null || true)"
child_done=0

owned_child_finished() {
  local rc=$1 signal reason_type status
  signal=$(cycle_signal_name "$rc")
  if [ "$rc" -eq 0 ] && watch_output_has_wake "$child_out"; then
    reason_type=$(watch_output_reason_type "$child_out")
    cycle_log_append "$rc" "$signal" "$reason_type" none
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    return 0
  fi

  if [ "$rc" -eq 0 ]; then
    if wait_for_healthy_successor; then
      cycle_log_append "$rc" "$signal" unexpected-clean-exit "attached:$HEALTHY_PID"
      print_watch_output "$child_out"
      rm -f "$child_out" 2>/dev/null || true
      child=
      child_out=
      cycle_mark_predecessor_successor "attached:$HEALTHY_PID"
      report_attached
      cycle_begin "$HEALTHY_PID" attached "$HEALTHY_IDENTITY"
      attach_and_wait "$HEALTHY_PID"
      return $?
    fi
    print_watch_output "$child_out"
    rm -f "$child_out" 2>/dev/null || true
    child=
    child_out=
    if close_unobserved_cycle; then
      cycle_log_append "$rc" "$signal" clean-exit-delivered-wake none
      return 0
    fi
    cycle_log_append "$rc" "$signal" unexpected-clean-exit none
    return 1
  fi

  reason_type="nonzero-exit"
  [ "$signal" = none ] || reason_type="signal-exit"
  cycle_log_append "$rc" "$signal" "$reason_type" none
  print_watch_output "$child_out"
  if ! grep -q '^watcher: FAILED' "$child_out" 2>/dev/null; then
    echo "watcher: FAILED - watcher cycle exited $rc without an actionable reason"
  fi
  rm -f "$child_out" 2>/dev/null || true
  child=
  child_out=
  status=$rc
  [ "$status" -gt 0 ] || status=1
  return "$status"
}

# Verify the outcome: poll until this child is the confirmed healthy watcher, or
# until some other watcher legitimately holds the singleton (a startup race), or
# until the child gives up. Only then print the honest line.
# date(1) exposes whole seconds. Keep the configured confirmation budget from
# collapsing when startup begins just before the next second boundary.
deadline=$(( $(date +%s) + CONFIRM_TIMEOUT + 1 ))
while :; do
  if healthy_watcher; then
    if [ "$HEALTHY_PID" = "$child" ]; then
      cycle_refresh_lock_before
      if ! handling_generation=$(handling_successor_generation); then
        cleanup_child
        wait "$child" 2>/dev/null || true
        cycle_log_append 1 none handling-handoff-failed none
        echo "watcher: FAILED - established successor could not inspect handling state"
        exit 1
      fi
      cycle_mark_predecessor_successor "started:$child"
      if [ -n "$handling_generation" ]; then
        echo "watcher: started pid=$child (beacon fresh) recovery-generation=$handling_generation"
      else
        echo "watcher: started pid=$child (beacon fresh)"
      fi
      wait "$child"
      rc=$?
      owned_child_finished "$rc"
      exit $?
    fi
    # Another watcher won the singleton; our child stood down.
    wait "$child"
    rc=$?
    owned_child_finished "$rc"
    exit $?
  fi
  if [ "$child_done" -eq 0 ] && ! fm_pid_alive "$child"; then
    wait "$child"
    rc=$?
    child_done=1
    owned_child_finished "$rc"
    exit $?
  fi
  [ "$(date +%s)" -ge "$deadline" ] && break
  sleep 0.2
done

trap - HUP TERM INT
print_watch_output "$child_out"
cleanup_child
wait "$child" 2>/dev/null
rc=$?
cycle_log_append "$rc" "$(cycle_signal_name "$rc")" confirmation-timeout none
echo "watcher: FAILED - no live watcher with a fresh beacon"
exit 1
