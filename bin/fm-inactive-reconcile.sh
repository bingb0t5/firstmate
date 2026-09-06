#!/usr/bin/env bash
# fm-inactive-reconcile.sh - bounded active-management and terminal reconciliation.
#
# Usage:
#   fm-inactive-reconcile.sh scan [--startup]
#   fm-inactive-reconcile.sh pending
#   fm-inactive-reconcile.sh acknowledge <fingerprint>
#
# This is an adjunct to the existing watcher poll loop and session-start path,
# not a watcher, daemon, PR poll, or forge client of its own.
# `scan` starts a sweep at most once per FM_INACTIVE_RECONCILE_SECS (default 600,
# valid 60..600) per home, except that --startup performs the same cheap scan
# immediately during a locked session start. The same bounded pass checks active
# work for overdue meaningful progress and retains the older inactive-terminal
# reconciliation, so there is one due-work detector rather than two schedulers.
# Each scan uses an aggregate FM_INACTIVE_RECONCILE_BUDGET_SECS deadline (default
# 10, valid 1..30) and resumes after its last visited child on the next scan.
# Homes with at most 25 direct ordinary active due-work obligations receive this
# bound; a larger home records due-work supervision as unhealthy and surfaces a
# capacity check until the active fleet returns within that bound.
# A sweep the budget truncated leaves its resume cursor recorded, so the watcher
# continues it immediately instead of waiting out another poll interval and the
# bound is per child rather than per scan. State reads share the cadence across
# the direct fleet, preventing one slow child from consuming another child's
# whole due-work window. The cadence clock starts with the
# sweep, so time spent completing a truncated sweep does not extend the next
# due-work interval. A resumed sweep skips the completed segment, while a cold
# cursor left behind by a dead watcher still anchors a full rotating sweep.
# The scan enforces that budget itself through a whole-second deadline, and the
# first due child of every scan is always visited with at least a one-second
# state-read bound: whole-second arithmetic can otherwise round a small budget
# to zero mid-scan, and an invocation that exits having visited nothing would
# advance the durable cursor past a child it never examined. Every later child
# is either given its full per-child share or deferred to the immediate resume,
# so a sweep never skips a child that only ran out of leftover budget.
# A process-group
# kill two seconds after the budget remains as a backstop for a scan wedged in
# an unbounded wait (for example a live-held wake-queue lock), so the clean
# deadline path is not racing its own backstop.
#
# Active management considers only direct ordinary crewmates with an open
# working phase in their append-only status log. Chatter, turn-ended liveness,
# declared external waits, and captain-held transfers are not meaningful
# progress and never reset the due clock. Newly generated status contracts carry
# an event epoch on each meaningful line; legacy lines are due immediately on
# first observation. When the same meaningful working
# evidence remains overdue, it performs one bounded
# fm-crew-state.sh read and queues a task-local stale wake for targeted
# intervention. Unresolved needs-decision/blocked events are folded separately
# and re-surfaced through the same durable task signal without auto-answering.
# Persistent secondmates are never child-scanned by their parent; each secondmate
# home scans its own direct children and reports required action through the
# established parent status route.
#
# The inactive terminal path considers only a direct ordinary crewmate whose
# newest meta, status, or turn-ended mtime is older than that interval and whose
# last status is not captain-held. It then uses fm-crew-state.sh as the sole
# current-state source. Only a done or failed state is suspicious enough to
# create a durable terminal outcome record or wake the supervisor.
# Working, paused, parked, blocked, unknown, persistent secondmates, and
# captain-held work retain their existing supervision semantics.
#
# A terminal-outcomes/<fingerprint>.pending record remains until its upstream
# receipt is durable.
# In a secondmate home, that receipt is an idempotent parent-channel status
# append.
# In a main home, a presentation-stage record is acknowledged by fm-wake-drain
# only after its corresponding inactive-outcome wake is handled.
# A receipt is intentionally independent of .hb-surfaced-* bookkeeping.
#
# New fm-terminal-outcome.v1 receipts contain schema, fingerprint, task_id,
# incarnation, state, outcome_key, origin, phase, pr, created_epoch, and
# notice_emitted; the fingerprint binds the spawn incarnation, task id, terminal
# state, PR text, and sanitized last status.
# Pending atomically becomes reported after parent append or presented after
# main-home acknowledgement. The atomic marker records the sweep start, its
# cursor records the last child visited within the aggregate budget, and its
# origin records where the sweep in flight started, so a resumed sweep still
# owes - and still runs - the wrap segment back over the children at or before
# that origin.
#
# The scan reads only durable local state and fm-crew-state.sh; it never invokes
# gh, gh-axi, curl, fm-pr-check.sh, fm-pr-poll.sh, or a state *.check.sh.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
OUTCOME_DIR="$STATE/terminal-outcomes"
ACTIVE_DIR="$STATE/active-management"
SCAN_MARKER="$STATE/.inactive-outcome-reconcile"
SCAN_LOCK="$STATE/.inactive-outcome-reconcile.lock"
CAPACITY_MARKER="$STATE/.inactive-reconcile-capacity"
BUDGET_MARKER="$STATE/.inactive-reconcile-budget"
CREW_STATE_BIN="${FM_INACTIVE_CREW_STATE_BIN:-$SCRIPT_DIR/fm-crew-state.sh}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$SCRIPT_DIR/fm-secondmate-parent-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"

FM_INACTIVE_RECONCILE_SECS=${FM_INACTIVE_RECONCILE_SECS:-600}
case "$FM_INACTIVE_RECONCILE_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 600\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_SECS" -lt 60 ] || [ "$FM_INACTIVE_RECONCILE_SECS" -gt 600 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_SECS must be a whole number from 60 to 600\n' >&2
  exit 2
fi
# The re-surface cadence for a known-but-unresolved obligation is the fleet's,
# not this scan's: an unanswered decision is re-queued on the same interval
# bin/fm-watch.sh's resurface_absorbed uses, so a decision waiting on an absent
# human does not re-wake firstmate once per scan. Like resurface_absorbed, the
# FIRST re-surface also waits out that interval whenever the per-wake path
# already surfaced the fact; a fact it never surfaced is queued immediately.
PAUSE_RESURFACE_SECS=${FM_PAUSE_RESURFACE_SECS:-$FM_PAUSE_RESURFACE_SECS_DEFAULT}

FM_INACTIVE_RECONCILE_BUDGET_SECS=${FM_INACTIVE_RECONCILE_BUDGET_SECS:-10}
FM_INACTIVE_RECONCILE_MAX_DIRECT_CHILDREN=25
case "$FM_INACTIVE_RECONCILE_BUDGET_SECS" in
  ''|*[!0-9]*|0)
    printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
    exit 2
    ;;
esac
if [ "$FM_INACTIVE_RECONCILE_BUDGET_SECS" -gt 30 ]; then
  printf 'fm-inactive-reconcile: FM_INACTIVE_RECONCILE_BUDGET_SECS must be a whole number from 1 to 30\n' >&2
  exit 2
fi

if [ "$(uname)" = Darwin ]; then
  file_mtime() { stat -f %m "$1" 2>/dev/null; }
else
  file_mtime() { stat -c %Y "$1" 2>/dev/null; }
fi

reconcile_now() {
  case "${FM_INACTIVE_RECONCILE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_INACTIVE_RECONCILE_NOW" ;;
  esac
}

clean_field() {
  printf '%s' "$1" | LC_ALL=C tr '\t\r\n' '   ' | cut -c1-1200
}

valid_id() {
  case "$1" in ''|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

sha256_text() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print substr($1, 1, 32)}'
  elif command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$1" | sha256sum | awk '{print substr($1, 1, 32)}'
  else
    printf '%s' "$1" | cksum | awk '{printf "%08x%08x", $1, $2}'
  fi
}

record_path() { printf '%s/%s.%s\n' "$OUTCOME_DIR" "$1" "$2"; }

record_value() {
  local record=$1 key=$2
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  grep "^${key}=" "$record" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

record_phase_set() {
  local record=$1 phase=$2 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in phase=*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf 'phase=%s\n' "$phase" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

record_field_set() {
  local record=$1 key=$2 value=$3 tmp line
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.record.XXXXXX") || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in "${key}="*) continue ;; esac
    printf '%s\n' "$line" >> "$tmp" || { rm -f "$tmp"; return 1; }
  done < "$record"
  printf '%s=%s\n' "$key" "$value" >> "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record"
}

ensure_record() { # <fingerprint> <task> <incarnation> <state> <outcome-key> <origin> <phase> <pr>
  local fingerprint=$1 task=$2 incarnation=$3 state=$4 outcome_key=$5 origin=$6 phase=$7 pr=$8 tmp
  RECORD_PENDING=$(record_path "$fingerprint" pending)
  RECORD_PRESENTED=$(record_path "$fingerprint" presented)
  RECORD_REPORTED=$(record_path "$fingerprint" reported)
  if [ -f "$RECORD_PRESENTED" ] || [ -f "$RECORD_REPORTED" ]; then
    RECORD_PENDING=
    return 0
  fi
  if [ -f "$RECORD_PENDING" ] && [ ! -L "$RECORD_PENDING" ]; then
    return 0
  fi
  mkdir -p "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  tmp=$(mktemp "$OUTCOME_DIR/.pending.XXXXXX") || return 1
  {
    printf 'schema=fm-terminal-outcome.v1\n'
    printf 'fingerprint=%s\n' "$fingerprint"
    printf 'task_id=%s\n' "$task"
    printf 'incarnation=%s\n' "$incarnation"
    printf 'state=%s\n' "$state"
    printf 'outcome_key=%s\n' "$outcome_key"
    printf 'origin=%s\n' "$origin"
    printf 'phase=%s\n' "$phase"
    printf 'pr=%s\n' "$pr"
    printf 'created_epoch=%s\n' "$(reconcile_now)"
    printf 'notice_emitted=0\n'
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$RECORD_PENDING" || { rm -f "$tmp"; return 1; }
}

mark_reported() { # <record>
  local record=$1 reported
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  reported=${record%.pending}.reported
  mv -f "$record" "$reported"
}

queue_key_exists() { # <key>
  local key=$1 queued
  queued=$(fm_wake_queued_keys check 2>/dev/null || true)
  printf '%s\n' "$queued" | grep -Fx -- "$key" >/dev/null 2>&1
}

queue_notice_once() { # <record> <key> <payload>
  local record=$1 key=$2 payload=$3 notified
  notified=$(record_value "$record" notice_emitted)
  [ "$notified" = 1 ] && return 1
  if queue_key_exists "$key"; then
    record_field_set "$record" notice_emitted 1 || return 2
    return 1
  fi
  fm_wake_append check "$key" "$payload" || return 2
  record_field_set "$record" notice_emitted 1 || return 2
  printf 'actionable: %s\n' "$payload"
  return 0
}

queue_presentation() { # <record> <fingerprint> <payload>
  local record=$1 fingerprint=$2 payload=$3 key
  key="inactive-outcome:$fingerprint"
  if queue_key_exists "$key"; then
    return 1
  fi
  fm_wake_append check "$key" "$payload" || return 2
  printf 'actionable: %s\n' "$payload"
  return 0
}

last_activity_age() { # <meta> <status> <turn-ended>
  local meta=$1 status=$2 turn=$3 now m newest=0 file
  now=$(reconcile_now)
  for file in "$meta" "$status" "$turn"; do
    [ -e "$file" ] || continue
    m=$(file_mtime "$file" 2>/dev/null || true)
    case "$m" in ''|*[!0-9]*) continue ;; esac
    [ "$m" -le "$newest" ] || newest=$m
  done
  [ "$newest" -gt 0 ] || { printf '0\n'; return; }
  if [ "$now" -lt "$newest" ]; then printf '0\n'; else printf '%s\n' $((now - newest)); fi
}

scan_marker_age() {
  local now m
  [ -e "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || { printf '999999\n'; return; }
  now=$(reconcile_now)
  m=$(file_mtime "$SCAN_MARKER" 2>/dev/null || true)
  case "$m" in ''|*[!0-9]*) printf '999999\n'; return ;; esac
  if [ "$now" -lt "$m" ]; then printf '0\n'; else printf '%s\n' $((now - m)); fi
}

scan_marker_cursor() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^cursor=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

scan_marker_origin() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^origin=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

scan_marker_started_epoch() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^started_epoch=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

scan_marker_active_cursor() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 0
  grep '^active_cursor=' "$SCAN_MARKER" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

scan_marker_has_continuation() {
  [ -f "$SCAN_MARKER" ] && [ ! -L "$SCAN_MARKER" ] || return 1
  grep -q '^origin=' "$SCAN_MARKER" 2>/dev/null \
    && grep -q '^started_epoch=' "$SCAN_MARKER" 2>/dev/null
}

# The sweep this marker belongs to started after SCAN_ORIGIN and owes a wrap
# segment over the children at or before it. scan() owns the value; every
# cursor write carries it so a resumed sweep still knows what it has not
# covered yet.
SCAN_ORIGIN=
SCAN_STARTED_EPOCH=
SCAN_ACTIVE_CURSOR=
SCAN_REGULAR_CURSOR=

write_scan_marker() { # <cursor>
  local cursor=$1 marker_tmp
  marker_tmp=$(mktemp "$STATE/.inactive-outcome-reconcile.XXXXXX") || return 1
  {
    printf 'epoch=%s\n' "$(reconcile_now)"
    printf 'started_epoch=%s\n' "$SCAN_STARTED_EPOCH"
    printf 'cursor=%s\n' "$cursor"
    printf 'origin=%s\n' "$SCAN_ORIGIN"
    printf 'active_cursor=%s\n' "$SCAN_ACTIVE_CURSOR"
  } > "$marker_tmp" || { rm -f "$marker_tmp"; return 1; }
  chmod 600 "$marker_tmp" 2>/dev/null || true
  mv -f "$marker_tmp" "$SCAN_MARKER" || { rm -f "$marker_tmp"; return 1; }
}

meta_field() {
  grep "^$2=" "$1" 2>/dev/null | tail -1 | cut -d= -f2- || true
}

meta_incarnation() { # <meta>
  local meta=$1 incarnation identity
  incarnation=$(meta_field "$meta" spawn_gen)
  if valid_id "$incarnation"; then
    printf '%s\n' "$incarnation"
    return
  fi
  identity=$(meta_field "$meta" tasktmp)
  if [ -z "$identity" ]; then
    identity="$(meta_field "$meta" window)|$(meta_field "$meta" worktree)"
  fi
  printf 'legacy-%s\n' "$(sha256_text "$identity")"
}

pr_for_task() { # <meta> <status>
  local pr=$1 status=$2 value
  value=$(meta_field "$pr" pr)
  if [ -z "$value" ] && [ -f "$status" ]; then
    value=$(grep -Eo 'https?://[^[:space:])"]+/pull/[0-9]+' "$status" 2>/dev/null | head -1 || true)
  fi
  clean_field "$value"
}

home_secondmate_id() {
  local marker="$FM_HOME/.fm-secondmate-home" id
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  valid_id "$id" || return 2
  printf '%s\n' "$id"
}

append_once() { # <path> <line>
  local path=$1 line=$2
  [ ! -L "$path" ] || return 1
  mkdir -p "$(dirname "$path")" || return 1
  if grep -Fqx -- "$line" "$path" 2>/dev/null; then
    return 0
  fi
  printf '%s\n' "$line" >> "$path"
}

report_to_parent() { # <self-id> <task> <state> <outcome-key> <fingerprint> <pr>
  local self=$1 task=$2 state=$3 outcome_key=$4 fingerprint=$5 pr=$6 parent_record destination line
  parent_record="$FM_HOME/.fm-secondmate-parent"
  fm_secondmate_parent_record_parse "$parent_record" || return 1
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 1
      destination="$FM_SECONDMATE_PARENT_HOME/state/$self.status"
      ;;
    remote)
      destination="$STATE/parent-replies.status"
      ;;
    *) return 1 ;;
  esac
  line="$state [key=$outcome_key]: inactive terminal child=$task fingerprint=$fingerprint"
  [ -z "$pr" ] || line="$line pr=$pr"
  append_once "$destination" "$line"
}

active_record_path() { # <task>
  printf '%s/%s\n' "$ACTIVE_DIR" "$1"
}

ACTIVE_RECORD_SIGNATURE=
ACTIVE_RECORD_PROGRESS_EPOCH=
ACTIVE_RECORD_DECISION_SIGNATURE=
ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT=
ACTIVE_RECORD_DECISION_ALERT_EPOCH=
ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT=
ACTIVE_RECORD_PROGRESS_ALERT_EPOCH=

active_record_read() { # <record>
  local record=$1 line
  ACTIVE_RECORD_SIGNATURE=
  ACTIVE_RECORD_PROGRESS_EPOCH=
  ACTIVE_RECORD_DECISION_SIGNATURE=
  ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT=
  ACTIVE_RECORD_DECISION_ALERT_EPOCH=
  ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT=
  ACTIVE_RECORD_PROGRESS_ALERT_EPOCH=
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      signature=*) ACTIVE_RECORD_SIGNATURE=${line#signature=} ;;
      progress_epoch=*) ACTIVE_RECORD_PROGRESS_EPOCH=${line#progress_epoch=} ;;
      decision_signature=*) ACTIVE_RECORD_DECISION_SIGNATURE=${line#decision_signature=} ;;
      decision_alert_fingerprint=*) ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT=${line#decision_alert_fingerprint=} ;;
      decision_alert_epoch=*) ACTIVE_RECORD_DECISION_ALERT_EPOCH=${line#decision_alert_epoch=} ;;
      progress_alert_fingerprint=*) ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT=${line#progress_alert_fingerprint=} ;;
      progress_alert_epoch=*) ACTIVE_RECORD_PROGRESS_ALERT_EPOCH=${line#progress_alert_epoch=} ;;
      alert_fingerprint=decision\|*) ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT=${line#alert_fingerprint=} ;;
      alert_fingerprint=progress\|*) ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT=${line#alert_fingerprint=} ;;
      alert_epoch=*)
        [ -z "$ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT" ] || ACTIVE_RECORD_DECISION_ALERT_EPOCH=${line#alert_epoch=}
        [ -z "$ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT" ] || ACTIVE_RECORD_PROGRESS_ALERT_EPOCH=${line#alert_epoch=}
        ;;
    esac
  done < "$record"
}

active_record_write() { # <task> <signature> <progress-epoch> <decision-signature> <decision-alert-fingerprint> <decision-alert-epoch> <progress-alert-fingerprint> <progress-alert-epoch>
  local task=$1 signature=$2 progress_epoch=$3 decision_signature=$4 decision_alert_fingerprint=$5
  local decision_alert_epoch=$6 progress_alert_fingerprint=$7 progress_alert_epoch=$8 tmp record
  valid_id "$task" || return 1
  mkdir -p "$ACTIVE_DIR" || return 1
  [ ! -L "$ACTIVE_DIR" ] || return 1
  record=$(active_record_path "$task")
  [ ! -e "$record" ] || [ ! -L "$record" ] || return 1
  tmp=$(mktemp "$ACTIVE_DIR/.record.XXXXXX") || return 1
  {
    printf 'schema=fm-active-management.v2\n'
    printf 'task_id=%s\n' "$task"
    printf 'signature=%s\n' "$signature"
    printf 'progress_epoch=%s\n' "$progress_epoch"
    printf 'decision_signature=%s\n' "$decision_signature"
    printf 'decision_alert_fingerprint=%s\n' "$decision_alert_fingerprint"
    printf 'decision_alert_epoch=%s\n' "$decision_alert_epoch"
    printf 'progress_alert_fingerprint=%s\n' "$progress_alert_fingerprint"
    printf 'progress_alert_epoch=%s\n' "$progress_alert_epoch"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$record" || { rm -f "$tmp"; return 1; }
}

active_progress_event_epoch() { # <status-line>
  local line=$1 prefix epoch
  prefix=${line%%:*}
  case "$prefix" in
    *'[at='*']'*) ;;
    *) return 1 ;;
  esac
  epoch=${prefix##*"[at="}
  epoch=${epoch%%"]"*}
  case "$epoch" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$epoch"
}

active_progress_epoch() { # <status-line> <fallback>
  local line=$1 fallback=$2 epoch legacy
  if epoch=$(active_progress_event_epoch "$line") && [ "$epoch" -le "$fallback" ]; then
    printf '%s\n' "$epoch"
    return
  fi
  legacy=$((fallback - FM_INACTIVE_RECONCILE_SECS))
  [ "$legacy" -ge 0 ] || legacy=0
  printf '%s\n' "$legacy"
}

active_current_state() { # <id> <timeout>
  local id=$1 timeout=$2 line rc=0
  line=$(fm_run_timed "$timeout" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$CREW_STATE_BIN" "$id" 2>/dev/null) || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  case "$line" in
    state:*"source: "*) printf '%s\n' "$line"; return 0 ;;
  esac
  return 1
}

active_alert_due() { # <previous-fingerprint> <previous-epoch> <fingerprint> <now> <interval>
  local previous=$1 previous_epoch=$2 fingerprint=$3 now=$4 interval=$5
  [ "$previous" != "$fingerprint" ] && return 0
  case "$previous_epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ "$now" -ge "$previous_epoch" ] || return 1
  [ $((now - previous_epoch)) -ge "$interval" ]
}

active_queue_once() { # <kind> <key> <payload>
  local kind=$1 key=$2 payload=$3
  if fm_wake_queued_keys "$kind" 2>/dev/null | grep -Fx -- "$key" >/dev/null 2>&1; then
    return 1
  fi
  fm_wake_append "$kind" "$key" "$payload" || return 2
  printf 'actionable: %s\n' "$payload"
  return 0
}

scan_alert_due() { # <marker> <subject> <now>
  local marker=$1 subject=$2 now=$3 line recorded_subject= recorded_epoch=
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      subject=*) recorded_subject=${line#subject=} ;;
      epoch=*) recorded_epoch=${line#epoch=} ;;
    esac
  done < "$marker"
  [ "$recorded_subject" = "$subject" ] || return 0
  case "$recorded_epoch" in ''|*[!0-9]*) return 0 ;; esac
  [ "$now" -ge "$recorded_epoch" ] || return 1
  [ $((now - recorded_epoch)) -ge "$PAUSE_RESURFACE_SECS" ]
}

scan_alert_record() { # <marker> <subject> <now>
  local marker=$1 subject=$2 now=$3 tmp
  tmp=$(mktemp "$marker.XXXXXX") || return 1
  {
    printf 'schema=fm-inactive-reconcile-alert.v1\n'
    printf 'subject=%s\n' "$subject"
    printf 'epoch=%s\n' "$now"
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$marker" || { rm -f "$tmp"; return 1; }
}

# Both folds below cost one subprocess per status line, so each is reached only
# through a cheap whole-file grep that is a strict superset of the fold's own
# opening rule: a decision record exists only where a needs-decision or blocked
# line does, and an activity phase only where a working line does. A file with
# neither can be skipped without ever consulting the fold.
active_has_decision_event() { # <status-file>
  grep -qE '^[[:space:]]*(needs-decision|blocked)([[:space:]]|[[]|:|$)' "$1" 2>/dev/null
}

active_has_open_working_phase() { # <status-file>
  local rows key verb note
  grep -qE '^[[:space:]]*working([[:space:]]|[[]|:|$)' "$1" 2>/dev/null || return 1
  rows=$(status_open_activities "$1" 2>/dev/null || true)
  while IFS=$'\t' read -r key verb note; do
    [ "$verb" = working ] && return 0
  done <<EOF
$rows
EOF
  return 1
}

direct_meta_has_active_due_work() { # <meta>
  local meta=$1 id kind status decisions
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  id=${meta##*/}; id=${id%.meta}
  valid_id "$id" || return 1
  kind=$(meta_field "$meta" kind)
  [ "$kind" = secondmate ] && return 1
  status="$STATE/$id.status"
  [ -f "$status" ] && [ -r "$status" ] && [ ! -L "$status" ] || return 1
  if active_has_decision_event "$status"; then
    decisions=$(status_open_decisions "$status" 2>/dev/null || true)
    [ -n "$decisions" ] && return 0
  fi
  active_has_open_working_phase "$status"
}

active_oldest_open_progress() { # <status-file> <fallback> -> signature<TAB>epoch<TAB>measured
  local status=$1 fallback=$2 rows key verb note line line_key working_keys='' latest=''
  local epoch event_epoch signature measured best_epoch= best_signature= best_measured=
  rows=$(status_open_activities "$status" 2>/dev/null || true)
  while IFS=$'\t' read -r key verb note; do
    [ "$verb" = working ] || continue
    working_keys="${working_keys}${working_keys:+$'\n'}$key"
  done <<EOF
$rows
EOF
  [ -n "$working_keys" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    [ "$(status_line_verb "$line")" = working ] || continue
    line_key=$(_fm_decision_key "$line") || continue
    case "
$working_keys
" in
      *"
$line_key
"*) ;;
      *) continue ;;
    esac
    latest=$(_fm_decision_drop "$latest" "$line_key")
    [ -n "$latest" ] && latest="${latest}"$'\n'
    latest="${latest}${line_key}"$'\t'"${line}"
  done < "$status"
  while IFS=$'\t' read -r line_key line; do
    [ -n "$line" ] || continue
    epoch=$(active_progress_epoch "$line" "$fallback")
    measured=0
    if event_epoch=$(active_progress_event_epoch "$line") && [ "$event_epoch" -le "$fallback" ]; then
      measured=1
    fi
    if [ -z "$best_epoch" ] || [ "$epoch" -lt "$best_epoch" ]; then
      best_epoch=$epoch
      best_signature=$(sha256_text "$line")
      best_measured=$measured
    fi
  done <<EOF
$latest
EOF
  [ -n "$best_signature" ] || return 0
  printf '%s\t%s\t%s\n' "$best_signature" "$best_epoch" "$best_measured"
}

active_management_locked() { # <id> <meta> <timeout>
  local id=$1 meta=$2 timeout=$3 status turn last_line progress_signature progress_row progress_measured signal_signature turn_signature
  local old_signature progress_epoch decision_rows decision_signature decision_generation decision_count
  local record now last_target decision_alert_epoch decision_alert_fingerprint
  local progress_alert_epoch progress_alert_fingerprint state source age payload queue_rc state_rc
  local status_epoch turn_epoch turn_seen_signature turn_seen_path
  status="$STATE/$id.status"
  [ -f "$status" ] && [ ! -L "$status" ] || return 0
  turn="$STATE/$id.turn-ended"
  signal_signature=$(fm_wake_signal_sig "$status" 2>/dev/null || true)
  turn_signature=$(fm_wake_signal_sig "$turn" 2>/dev/null || true)
  last_line=$(last_status_line "$status")
  decision_rows=
  if active_has_decision_event "$status"; then
    decision_rows=$(status_open_decisions "$status" 2>/dev/null || true)
  fi
  now=$(reconcile_now)
  progress_row=$(active_oldest_open_progress "$status" "$now")
  IFS=$'\t' read -r progress_signature progress_epoch progress_measured <<EOF
$progress_row
EOF
  record=$(active_record_path "$id")
  active_record_read "$record"
  if [ -z "$progress_signature" ] && [ -z "$decision_rows" ]; then
    if [ -n "$ACTIVE_RECORD_SIGNATURE" ] || [ -n "$ACTIVE_RECORD_DECISION_SIGNATURE" ] \
      || [ -n "$ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT" ] || [ -n "$ACTIVE_RECORD_DECISION_ALERT_EPOCH" ] \
      || [ -n "$ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT" ] || [ -n "$ACTIVE_RECORD_PROGRESS_ALERT_EPOCH" ]; then
      active_record_write "$id" '' '' '' '' '' '' '' || return 1
    fi
    return 0
  fi
  old_signature=$ACTIVE_RECORD_SIGNATURE
  if [ "$old_signature" = "$progress_signature" ]; then
    case "$ACTIVE_RECORD_PROGRESS_EPOCH" in ''|*[!0-9]*|0) : ;;
      *) progress_epoch=$ACTIVE_RECORD_PROGRESS_EPOCH ;;
    esac
  fi
  case "$progress_epoch" in ''|*[!0-9]*) progress_epoch=$now ;; esac
  decision_signature=
  decision_generation=
  decision_count=0
  if [ -n "$decision_rows" ]; then
    decision_signature=$(status_text_signature "$decision_rows")
    decision_generation=$(status_decision_generation "$status") || return 1
    decision_count=$(printf '%s\n' "$decision_rows" \
      | awk 'NF { count++ } END { print count + 0 }')
  fi
  decision_alert_fingerprint=$ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT
  decision_alert_epoch=$ACTIVE_RECORD_DECISION_ALERT_EPOCH
  progress_alert_fingerprint=$ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT
  progress_alert_epoch=$ACTIVE_RECORD_PROGRESS_ALERT_EPOCH
  if [ -n "$decision_rows" ]; then
    decision_alert_fingerprint="decision|$decision_generation|$decision_signature"
    if [ "$ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT" != "$decision_alert_fingerprint" ] \
      && status_decision_surfaced_matches "$STATE" "$id" "$decision_generation"; then
      # The per-wake path already showed the captain this exact line, so this
      # first observation only starts the re-surface clock. An obligation the
      # per-wake path never surfaced has no matching marker and is queued below
      # on this same scan.
      decision_alert_epoch=$now
    elif active_alert_due "$ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT" "$ACTIVE_RECORD_DECISION_ALERT_EPOCH" \
      "$decision_alert_fingerprint" "$now" "$PAUSE_RESURFACE_SECS"; then
      # A signal payload is word-split AND pathname-expanded by both away-mode
      # consumers, so it carries only the status path and bounded scalar fields.
      payload="signal: $status (unresolved decisions count=$decision_count fingerprint=$decision_signature generation=$decision_generation)"
      status_epoch=$(file_mtime "$status" 2>/dev/null || true)
      turn_epoch=$(file_mtime "$turn" 2>/dev/null || true)
      turn_seen_path=$(fm_wake_signal_seen_path "$STATE" "$turn")
      turn_seen_signature=$(cat "$turn_seen_path" 2>/dev/null || true)
      queue_rc=0
      active_queue_once signal "$id.status" "$payload" || queue_rc=$?
      if [ "$queue_rc" -eq 0 ]; then
        decision_alert_epoch=$now
        if fm_wake_signal_mark_seen_if_current "$STATE" "$status" "$signal_signature"; then
          status_mark_surfaced "$STATE" "$id" "$last_line" || true
          status_mark_decision_surfaced "$STATE" "$id" "$status" || true
          case "$status_epoch:$turn_epoch" in *[!0-9:]*|:|*:|*:*:*) : ;;
            *)
              if [ -z "$turn_seen_signature" ] && [ "$turn_epoch" -le "$status_epoch" ]; then
                fm_wake_signal_mark_seen_if_current "$STATE" "$turn" "$turn_signature" || true
              fi
              ;;
          esac
        fi
      elif [ "$queue_rc" -eq 2 ]; then
        return 1
      fi
    fi
  else
    decision_alert_fingerprint=
    decision_alert_epoch=
  fi
  if [ -n "$progress_signature" ] \
    && [ "$((now - progress_epoch))" -ge "$FM_INACTIVE_RECONCILE_SECS" ] \
    ; then
    age=$((now - progress_epoch))
    if [ -z "$ACTIVE_STATE_LINE" ]; then
      state_rc=0
      ACTIVE_STATE_LINE=$(active_current_state "$id" "$timeout" 2>/dev/null) || state_rc=$?
      ACTIVE_STATE_PROBE_RC=$state_rc
      [ -n "$ACTIVE_STATE_LINE" ] || ACTIVE_STATE_LINE='state: unknown · source: unavailable'
    fi
    state=${ACTIVE_STATE_LINE#state: }; state=${state%% *}
    source=${ACTIVE_STATE_LINE#*source: }; source=${source%% *}
    # The shared absorb boundary (crew_absorb_class, bin/fm-classify-lib.sh): a
    # live attributed run, a busy pane, and a declared pause are absorbed as
    # mere liveness or a declared wait, and every other reading of an item whose
    # meaningful progress is already overdue is surfaced - the same call the
    # watcher makes for an inconclusive non-terminal stale. A current state this
    # scan could not read is not evidence either way, so a failed or timed-out
    # bounded read absorbs rather than invents a wedge, and a done or failed
    # verdict is a terminal outcome the reconciliation below already owns rather
    # than work that has stopped making progress.
    if [ "$source" != unavailable ] && [ "$state" != 'done' ] && [ "$state" != 'failed' ] \
      && [ "$(crew_absorb_class_of_record "$state|$source")" = none ]; then
      # Keyed by the task's backend target, exactly as every other stale
      # producer keys it, so an already-queued stale row for this task is seen
      # and never duplicated on a non-tmux backend.
      last_target=$(fm_backend_target_of_meta "$meta")
      [ -n "$last_target" ] || last_target=$id
      progress_alert_fingerprint="progress|$progress_signature|$progress_epoch"
      if active_alert_due "$ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT" "$ACTIVE_RECORD_PROGRESS_ALERT_EPOCH" \
        "$progress_alert_fingerprint" "$now" "$PAUSE_RESURFACE_SECS"; then
        if [ "$progress_measured" = 1 ]; then
          payload="stale: $last_target (active work has no meaningful progress for ${age}s)"
        else
          payload="stale: $last_target (active work has no meaningful progress since first observation; no timestamped progress event)"
        fi
        queue_rc=0
        active_queue_once stale "$last_target" "$payload" || queue_rc=$?
        if [ "$queue_rc" -eq 0 ]; then progress_alert_epoch=$now; fi
        [ "$queue_rc" -ne 2 ] || return 1
      fi
    fi
  fi
  if [ "$progress_signature" != "$ACTIVE_RECORD_SIGNATURE" ] \
    || [ "$progress_epoch" != "$ACTIVE_RECORD_PROGRESS_EPOCH" ] \
    || [ "$decision_signature" != "$ACTIVE_RECORD_DECISION_SIGNATURE" ] \
    || [ "$decision_alert_fingerprint" != "$ACTIVE_RECORD_DECISION_ALERT_FINGERPRINT" ] \
    || [ "$decision_alert_epoch" != "$ACTIVE_RECORD_DECISION_ALERT_EPOCH" ] \
    || [ "$progress_alert_fingerprint" != "$ACTIVE_RECORD_PROGRESS_ALERT_FINGERPRINT" ] \
    || [ "$progress_alert_epoch" != "$ACTIVE_RECORD_PROGRESS_ALERT_EPOCH" ]; then
    active_record_write "$id" "$progress_signature" "$progress_epoch" "$decision_signature" \
      "$decision_alert_fingerprint" "$decision_alert_epoch" \
      "$progress_alert_fingerprint" "$progress_alert_epoch" || return 1
  fi
  return 0
}

reconcile_direct_child_locked() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 status turn last age state_line state pr incarnation fingerprint outcome_key payload kind state_rc=0
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 0
  kind=$(meta_field "$meta" kind)
  [ "$kind" = secondmate ] && return 0
  ACTIVE_STATE_LINE=
  ACTIVE_STATE_PROBE_RC=
  status="$STATE/$id.status"
  turn="$STATE/$id.turn-ended"
  last=$(last_status_line "$status")
  active_management_locked "$id" "$meta" "$timeout" || true
  status_line_verb "$last" | grep -Fx captain-held >/dev/null 2>&1 && return 0
  age=$(last_activity_age "$meta" "$status" "$turn")
  if [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ]; then
    if [ "$ACTIVE_STATE_PROBE_RC" = 124 ]; then
      return 3
    elif [ -n "$ACTIVE_STATE_PROBE_RC" ]; then
      state_line=$ACTIVE_STATE_LINE
    else
      state_line=$(fm_run_timed "$timeout" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
        "$CREW_STATE_BIN" "$id" 2>/dev/null) || state_rc=$?
      [ "$state_rc" -ne 124 ] || return 3
      [ -n "$state_line" ] || state_line='state: unknown · source: unavailable'
    fi
    case "$state_line" in
      state:*"source: "*) ACTIVE_STATE_LINE=$state_line ;;
      *) ACTIVE_STATE_LINE='state: unknown · source: unavailable' ;;
    esac
  fi
  # A single child's wake-queue or record write failure is tolerated exactly as
  # the terminal-outcome paths below tolerate theirs: the scan keeps visiting
  # the remaining children and retries this one on its next pass.
  [ "$age" -ge "$FM_INACTIVE_RECONCILE_SECS" ] || return 0
  case "$state_line" in
    'state: done '*) state='done' ;;
    'state: failed '*) state='failed' ;;
    *) return 0 ;;
  esac
  pr=$(pr_for_task "$meta" "$status")
  incarnation=$(meta_incarnation "$meta")
  fingerprint=$(sha256_text "$incarnation|$id|$state|$pr|$(clean_field "$last")")
  if [ -n "$self" ]; then
    outcome_key="inactive-outcome-$self-$id-$state"
  else
    outcome_key="inactive-outcome-main-$id-$state"
  fi
  ensure_record "$fingerprint" "$id" "$incarnation" "$state" "$outcome_key" direct "upstream" "$pr" || return 1
  [ -n "$RECORD_PENDING" ] || return 0
  if [ -n "$self" ]; then
    if report_to_parent "$self" "$id" "$state" "$outcome_key" "$fingerprint" "$pr"; then
      mark_reported "$RECORD_PENDING" || return 1
    else
      payload="inactive terminal outcome needs parent report: child=$id state=$state"
      queue_notice_once "$RECORD_PENDING" "inactive-reconcile:$fingerprint" "$payload" || true
    fi
    return 0
  fi
  record_phase_set "$RECORD_PENDING" presentation || return 1
  payload="inactive terminal outcome awaiting captain presentation: child=$id state=$state"
  [ -z "$pr" ] || payload="$payload pr=$pr"
  queue_presentation "$RECORD_PENDING" "$fingerprint" "$payload" || true
}

reconcile_direct_child() { # <id> <meta> <secondmate-id-or-empty> <timeout>
  local id=$1 meta=$2 self=${3:-} timeout=$4 lock rc=0
  lock=$(fm_meta_lock_path "$meta") || return 1
  fm_lock_acquire_wait "$lock" || return 1
  reconcile_direct_child_locked "$id" "$meta" "$self" "$timeout" || rc=$?
  fm_lock_release "$lock"
  return "$rc"
}

# SCAN_FIRST_VISIT_PENDING is armed by scan() before its passes. The deadline
# below is whole-second arithmetic, so a small budget can quantize to zero
# between the deadline computation and these checks; without the guaranteed
# first visit, such a scan would return 3 having examined no child at all while
# write_scan_marker had already advanced the cursor past the skipped child.
scan_pass() { # <after-cursor> <upper-bound-or-empty> <deadline> <secondmate-id-or-empty>
  local cursor=$1 upper=$2 deadline=$3 self=${4:-} skip_active=${5:-0} meta id remaining share rc first target payload queue_rc alert_now
  local position=$1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ -z "$cursor" ] || [[ "$id" > "$cursor" ]] || continue
    if [ -n "$upper" ] && [[ "$id" > "$upper" ]]; then continue; fi
    [ "$skip_active" -eq 0 ] || ! direct_meta_has_active_due_work "$meta" || continue
    first=0
    if [ "${SCAN_FIRST_VISIT_PENDING:-0}" -eq 1 ]; then
      first=1
      SCAN_FIRST_VISIT_PENDING=0
    fi
    remaining=$((deadline - $(date +%s)))
    if [ "$first" -eq 1 ] && [ "$remaining" -lt 1 ]; then
      remaining=1
    fi
    [ "$remaining" -gt 0 ] || return 3
    share=${SCAN_CHILD_TIMEOUT:-$remaining}
    [ "$remaining" -le "$share" ] || remaining=$share
    SCAN_REGULAR_CURSOR=$id
    write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
    if fm_run_timed $((remaining + 1)) env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_INACTIVE_RECONCILE_SECS="$FM_INACTIVE_RECONCILE_SECS" \
      FM_INACTIVE_RECONCILE_BUDGET_SECS="$FM_INACTIVE_RECONCILE_BUDGET_SECS" \
      FM_INACTIVE_CREW_STATE_BIN="$CREW_STATE_BIN" "$0" _reconcile-child \
      "$id" "$meta" "$self" "$remaining"; then
      position=$id
    else
      rc=$?
      if { [ "$rc" -eq 124 ] || [ "$rc" -eq 3 ]; } \
        && [ "$first" -eq 0 ] && [ "$remaining" -lt "$share" ]; then
        SCAN_REGULAR_CURSOR=$position
        write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
        return 3
      fi
      if [ "$rc" -eq 124 ]; then
        target=$(fm_backend_target_of_meta "$meta")
        [ -n "$target" ] || target=$id
        alert_now=$(reconcile_now)
        if scan_alert_due "$BUDGET_MARKER" "$target" "$alert_now"; then
          payload="check: bounded due-work check exceeded ${remaining}s for $target"
          queue_rc=0
          active_queue_once check inactive-reconcile-budget "$payload" || queue_rc=$?
          [ "$queue_rc" -ne 2 ] || return 1
          scan_alert_record "$BUDGET_MARKER" "$target" "$alert_now" || return 1
        fi
        return 3
      fi
      [ "$rc" -eq 3 ] && return 3
      return "$rc"
    fi
  done
}

scan_active_pass() { # <after-cursor> <upper-bound-or-empty> <deadline> <secondmate-id-or-empty> <timeout>
  local cursor=$1 upper=$2 deadline=$3 self=${4:-} timeout=$5 meta id remaining share rc first target payload queue_rc alert_now
  local position=$1
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    id=$(basename "$meta" .meta)
    valid_id "$id" || continue
    [ -z "$cursor" ] || [[ "$id" > "$cursor" ]] || continue
    if [ -n "$upper" ] && [[ "$id" > "$upper" ]]; then continue; fi
    direct_meta_has_active_due_work "$meta" || continue
    first=0
    if [ "${ACTIVE_SCAN_FIRST_VISIT_PENDING:-0}" -eq 1 ]; then
      first=1
      ACTIVE_SCAN_FIRST_VISIT_PENDING=0
    fi
    remaining=$((deadline - $(date +%s)))
    if [ "$first" -eq 1 ] && [ "$remaining" -lt 1 ]; then
      remaining=1
    fi
    [ "$remaining" -gt 0 ] || return 3
    share=$timeout
    [ "$remaining" -le "$share" ] || remaining=$share
    SCAN_ACTIVE_CURSOR=$id
    write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
    if fm_run_timed $((remaining + 1)) env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
      FM_INACTIVE_RECONCILE_SECS="$FM_INACTIVE_RECONCILE_SECS" \
      FM_INACTIVE_RECONCILE_BUDGET_SECS="$FM_INACTIVE_RECONCILE_BUDGET_SECS" \
      FM_INACTIVE_CREW_STATE_BIN="$CREW_STATE_BIN" "$0" _reconcile-child \
      "$id" "$meta" "$self" "$remaining"; then
      position=$id
    else
      rc=$?
      if { [ "$rc" -eq 124 ] || [ "$rc" -eq 3 ]; } \
        && [ "$first" -eq 0 ] && [ "$remaining" -lt "$share" ]; then
        SCAN_ACTIVE_CURSOR=$position
        write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
        return 3
      fi
      if [ "$rc" -eq 124 ]; then
        target=$(fm_backend_target_of_meta "$meta")
        [ -n "$target" ] || target=$id
        alert_now=$(reconcile_now)
        if scan_alert_due "$BUDGET_MARKER" "$target" "$alert_now"; then
          payload="check: bounded due-work check exceeded ${remaining}s for $target"
          queue_rc=0
          active_queue_once check inactive-reconcile-budget "$payload" || queue_rc=$?
          [ "$queue_rc" -ne 2 ] || return 1
          scan_alert_record "$BUDGET_MARKER" "$target" "$alert_now" || return 1
        fi
        return 3
      fi
      [ "$rc" -eq 3 ] && return 3
      return "$rc"
    fi
  done
}

scan_direct_child_count() {
  local meta id kind line count=0
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] && [ ! -L "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    valid_id "$id" || continue
    kind=''
    while IFS= read -r line || [ -n "$line" ]; do
      case "$line" in kind=*) kind=${line#kind=} ;; esac
    done < "$meta"
    [ "$kind" = secondmate ] && continue
    count=$((count + 1))
  done
  printf '%s\n' "$count"
}

scan_active_due_work_count() {
  local meta count=0
  for meta in "$STATE"/*.meta; do
    direct_meta_has_active_due_work "$meta" && count=$((count + 1))
    [ "$count" -le "$FM_INACTIVE_RECONCILE_MAX_DIRECT_CHILDREN" ] || break
  done
  printf '%s\n' "$count"
}

scan_pending() {
  local cursor origin active_cursor
  cursor=$(scan_marker_cursor)
  if [ -n "$cursor" ]; then
    valid_id "$cursor"
    return
  fi
  origin=$(scan_marker_origin)
  if [ -n "$origin" ] && valid_id "$origin" && scan_marker_has_continuation; then
    return 0
  fi
  active_cursor=$(scan_marker_active_cursor)
  [ -n "$active_cursor" ] && valid_id "$active_cursor"
}

scan() {
  local startup=${1:-0} self='' cursor active_cursor deadline rc=0 marker_rc=0 marker_age cadence_age now child_count direct_child_count active_timeout regular_skip_active=0 candidate_rc=0
  local resuming=0 wrapping=0 legacy_cursor=0
  mkdir -p "$STATE" "$OUTCOME_DIR" || return 1
  [ ! -L "$OUTCOME_DIR" ] || return 1
  cursor=$(scan_marker_cursor)
  valid_id "$cursor" || cursor=''
  SCAN_REGULAR_CURSOR=$cursor
  SCAN_ACTIVE_CURSOR=$(scan_marker_active_cursor)
  valid_id "$SCAN_ACTIVE_CURSOR" || SCAN_ACTIVE_CURSOR=''
  SCAN_ORIGIN=$(scan_marker_origin)
  valid_id "$SCAN_ORIGIN" || SCAN_ORIGIN=''
  SCAN_STARTED_EPOCH=$(scan_marker_started_epoch)
  now=$(reconcile_now)
  marker_age=$(scan_marker_age)
  cadence_age=$marker_age
  if [ -n "$cursor" ] && ! scan_marker_has_continuation; then
    legacy_cursor=1
    SCAN_ORIGIN=
    SCAN_STARTED_EPOCH=
  fi
  case "$SCAN_STARTED_EPOCH" in
    ''|*[!0-9]*) SCAN_STARTED_EPOCH='' ;;
    *)
      if [ "$SCAN_STARTED_EPOCH" -le "$now" ]; then
        cadence_age=$((now - SCAN_STARTED_EPOCH))
      else
        SCAN_STARTED_EPOCH=''
      fi
      ;;
  esac
  if { [ -n "$cursor" ] || [ -n "$SCAN_ORIGIN" ] || [ -n "$SCAN_ACTIVE_CURSOR" ]; } && [ "$legacy_cursor" -eq 0 ] \
    && [ "$marker_age" -lt "$FM_INACTIVE_RECONCILE_SECS" ]; then
    resuming=1
  fi
  if [ "$startup" != 1 ] && [ "$resuming" -eq 0 ] \
    && [ "$legacy_cursor" -eq 0 ] \
    && [ "$cadence_age" -lt "$FM_INACTIVE_RECONCILE_SECS" ]; then
    return 0
  fi
  # A cold cursor anchors a fresh sweep, which keeps the established rotation:
  # this sweep runs from just after it and then wraps back over the rest.
  if [ "$resuming" -eq 1 ]; then
    [ -n "$SCAN_STARTED_EPOCH" ] || SCAN_STARTED_EPOCH=$((now - marker_age))
  else
    SCAN_ORIGIN=$cursor
    SCAN_STARTED_EPOCH=$now
  fi
  # On a resume the after segment can only ever have written a position strictly
  # after the origin, so a position at or before it means that segment is done
  # and only the wrap is outstanding. A fresh sweep starts its cursor AT the
  # origin, which is why this reads the resume flag rather than the order alone.
  if [ "$resuming" -eq 1 ] && [ -n "$SCAN_ORIGIN" ] && ! [[ "$cursor" > "$SCAN_ORIGIN" ]]; then
    wrapping=1
  fi
  write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
  if self=$(home_secondmate_id); then
    :
  else
    marker_rc=$?
    self=''
    if [ "$marker_rc" -ne 1 ]; then
      printf 'actionable: inactive terminal outcomes remain unreconciled: invalid .fm-secondmate-home marker\n'
      return 0
    fi
  fi
  direct_child_count=$(scan_direct_child_count)
  child_count=$(fm_run_timed "$FM_INACTIVE_RECONCILE_BUDGET_SECS" env FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    FM_INACTIVE_RECONCILE_SECS="$FM_INACTIVE_RECONCILE_SECS" \
    FM_INACTIVE_RECONCILE_BUDGET_SECS="$FM_INACTIVE_RECONCILE_BUDGET_SECS" \
    "$0" _active-count) || candidate_rc=$?
  if [ "$candidate_rc" -eq 124 ]; then
    if scan_alert_due "$CAPACITY_MARKER" candidate-evidence "$now"; then
      active_queue_once check inactive-reconcile-capacity \
        "check: due-work candidate evidence exceeded ${FM_INACTIVE_RECONCILE_BUDGET_SECS}s; bounded coverage unavailable" || rc=$?
      [ "$rc" -ne 2 ] || return 1
      rc=0
      scan_alert_record "$CAPACITY_MARKER" candidate-evidence "$now" || return 1
    fi
    SCAN_ACTIVE_CURSOR=''
    write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
    return 0
  fi
  [ "$candidate_rc" -eq 0 ] || return "$candidate_rc"
  case "$child_count" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$child_count" -gt "$FM_INACTIVE_RECONCILE_MAX_DIRECT_CHILDREN" ]; then
    if scan_alert_due "$CAPACITY_MARKER" "children=$child_count" "$now"; then
      active_queue_once check inactive-reconcile-capacity \
        "check: due-work capacity exceeded (${child_count} active direct children; maximum ${FM_INACTIVE_RECONCILE_MAX_DIRECT_CHILDREN})" || rc=$?
      [ "$rc" -ne 2 ] || return 1
      rc=0
      scan_alert_record "$CAPACITY_MARKER" "children=$child_count" "$now" || return 1
    fi
    SCAN_ACTIVE_CURSOR=''
    write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
  elif [ -e "$CAPACITY_MARKER" ] || [ -L "$CAPACITY_MARKER" ]; then
    [ ! -d "$CAPACITY_MARKER" ] || return 1
    rm -f "$CAPACITY_MARKER" || return 1
  fi
  if [ "$direct_child_count" -gt 0 ]; then
    SCAN_CHILD_TIMEOUT=$((FM_INACTIVE_RECONCILE_SECS / direct_child_count - 2))
    [ "$SCAN_CHILD_TIMEOUT" -gt 0 ] || SCAN_CHILD_TIMEOUT=1
    if [ "$SCAN_CHILD_TIMEOUT" -gt "$FM_INACTIVE_RECONCILE_BUDGET_SECS" ]; then
      SCAN_CHILD_TIMEOUT=$FM_INACTIVE_RECONCILE_BUDGET_SECS
    fi
  else
    SCAN_CHILD_TIMEOUT=$FM_INACTIVE_RECONCILE_BUDGET_SECS
  fi
  deadline=$(( $(date +%s) + FM_INACTIVE_RECONCILE_BUDGET_SECS ))
  active_timeout=$FM_INACTIVE_RECONCILE_BUDGET_SECS
  if [ "$child_count" -gt 0 ]; then
    active_timeout=$((FM_INACTIVE_RECONCILE_SECS / child_count - 2))
    [ "$active_timeout" -gt 0 ] || active_timeout=1
    if [ "$active_timeout" -gt "$FM_INACTIVE_RECONCILE_BUDGET_SECS" ]; then
      active_timeout=$FM_INACTIVE_RECONCILE_BUDGET_SECS
    fi
  fi
  if [ "$child_count" -gt 0 ] && [ "$child_count" -le "$FM_INACTIVE_RECONCILE_MAX_DIRECT_CHILDREN" ]; then
    regular_skip_active=1
    ACTIVE_SCAN_FIRST_VISIT_PENDING=1
    if [ -n "$SCAN_ACTIVE_CURSOR" ]; then
      active_cursor=$SCAN_ACTIVE_CURSOR
      scan_active_pass "$active_cursor" '' "$deadline" "$self" "$active_timeout" || rc=$?
      if [ "$rc" -eq 0 ]; then
        scan_active_pass '' "$active_cursor" "$deadline" "$self" "$active_timeout" || rc=$?
      fi
    else
      scan_active_pass '' '' "$deadline" "$self" "$active_timeout" || rc=$?
    fi
    if [ "$rc" -eq 0 ]; then
      SCAN_ACTIVE_CURSOR=''
      write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
    fi
  fi
  [ "$rc" -eq 0 ] || { [ "$rc" -eq 3 ] && return 0; return "$rc"; }
  SCAN_FIRST_VISIT_PENDING=1
  if [ "$wrapping" -eq 0 ]; then
    scan_pass "$cursor" '' "$deadline" "$self" "$regular_skip_active" || rc=$?
    if [ "$rc" -eq 0 ] && [ -n "$SCAN_ORIGIN" ]; then
      cursor=''
      wrapping=1
    fi
  fi
  if [ "$rc" -eq 0 ] && [ "$wrapping" -eq 1 ]; then
    scan_pass "$cursor" "$SCAN_ORIGIN" "$deadline" "$self" "$regular_skip_active" || rc=$?
  fi
  if [ "$rc" -eq 0 ]; then
    SCAN_ORIGIN=''
    SCAN_REGULAR_CURSOR=''
    write_scan_marker "$SCAN_REGULAR_CURSOR" || return 1
  elif [ "$rc" -ne 3 ]; then
    return "$rc"
  fi
}

acknowledge() { # <fingerprint>
  local fingerprint=$1 pending presented phase
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  presented=$(record_path "$fingerprint" presented)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  phase=$(record_value "$pending" phase)
  [ "$phase" = presentation ] || return 0
  mv -f "$pending" "$presented"
}

acknowledge_notice() { # <fingerprint>
  local fingerprint=$1 pending
  case "$fingerprint" in ''|*[!A-Fa-f0-9]*) return 2 ;; esac
  [ -d "$OUTCOME_DIR" ] && [ ! -L "$OUTCOME_DIR" ] || return 1
  pending=$(record_path "$fingerprint" pending)
  [ -f "$pending" ] && [ ! -L "$pending" ] || return 0
  record_field_set "$pending" notice_emitted 1
}

mode=${1:-scan}
case "$mode" in
  scan)
    startup=0
    case "${2:-}" in
      '') ;;
      --startup) startup=1 ;;
      *) printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2; exit 2 ;;
    esac
    # The scan's own whole-second deadline enforces the budget; this outer
    # process-group kill is only the backstop for a scan wedged outside every
    # bounded section (an unbounded lock wait), so it fires two seconds after
    # the deadline instead of racing the clean bounded exit it exists to guard.
    if fm_run_timed $((FM_INACTIVE_RECONCILE_BUDGET_SECS + 2)) "$0" _scan-locked "$startup"; then
      :
    elif [ "$?" -ne 124 ]; then
      exit 1
    fi
    ;;
  _scan-locked)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    scan "$2"
    ;;
  _reconcile-child)
    [ "$#" -eq 5 ] || exit 2
    valid_id "$2" || exit 2
    [ "$3" = "$STATE/$2.meta" ] || exit 2
    [ -z "$4" ] || valid_id "$4" || exit 2
    case "$5" in ''|*[!0-9]*|0) exit 2 ;; esac
    reconcile_direct_child "$2" "$3" "$4" "$5"
    ;;
  _active-count)
    [ "$#" -eq 1 ] || exit 2
    scan_active_due_work_count
    ;;
  pending)
    [ "$#" -eq 1 ] || exit 2
    scan_pending
    ;;
  acknowledge)
    [ "$#" -eq 2 ] || { printf 'usage: fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2; exit 2; }
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge "$2"
    ;;
  acknowledge-notice)
    [ "$#" -eq 2 ] || exit 2
    fm_lock_acquire_wait "$SCAN_LOCK" || exit 1
    trap 'fm_lock_release "$SCAN_LOCK"' EXIT
    acknowledge_notice "$2"
    ;;
  -h|--help)
    sed -n '2,${/^#/!q;s/^# \{0,1\}//;p;}' "$0"
    ;;
  *)
    printf 'usage: fm-inactive-reconcile.sh scan [--startup]\n' >&2
    printf '       fm-inactive-reconcile.sh pending\n' >&2
    printf '       fm-inactive-reconcile.sh acknowledge <fingerprint>\n' >&2
    exit 2
    ;;
esac
