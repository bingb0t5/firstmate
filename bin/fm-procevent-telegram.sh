#!/usr/bin/env bash
# Telegram adapter for the generic process-to-event runner.
#
# Usage:
#   fm-procevent-telegram.sh arm
#   fm-procevent-telegram.sh migrate
#   fm-procevent-telegram.sh source-id
#   fm-procevent-telegram.sh classify <result-file>
#   fm-procevent-telegram.sh messages <result-file>
#   fm-procevent-telegram.sh ack <result-file>
#   fm-procevent-telegram.sh doctor
#   fm-procevent-telegram.sh reply <accepted-inbound-update-id> < reply.txt
#   fm-procevent-telegram.sh resolve-migration --blocked-fingerprint <16-hex> \
#     --archive-manifest-sha256 <64-hex> \
#     --acknowledge-delivered '<state-relative-path>=sha256:<64-hex>' ...
#   fm-procevent-telegram.sh export-legacy-offset
#   fm-procevent-telegram.sh terminal <result-file>
#   fm-procevent-telegram.sh retire
#   fm-procevent-telegram.sh poll
#
# arm registers this home's permanent Telegram source.
# It requires one strict credential snapshot from
# ~/.config/beanz/telegram.env (override with FM_TELEGRAM_ENV_FILE), mode 0600,
# containing only TELEGRAM_BOT_TOKEN, TELEGRAM_CAPTAIN_CHAT_ID, and
# TELEGRAM_CAPTAIN_USER_ID.
# A fresh home receives state/telegram/channel.db on its first arm.
# A home with legacy Telegram files must run migrate first.
# Existing malformed state does not prevent registration: poll announces a
# local-state block through the ordinary captured-result path instead of
# leaving the channel silently unregistered.
#
# migrate is the one offline cutover from the former offset, blocked, pending,
# receipt, and telegram-inbox files.
# It first retires the process-event source and refuses while the retiring
# state/telegram-watch.check.sh or any watcher-owned custom-check snapshot
# exists.
# It then refuses, naming each one and changing nothing, while any captured
# legacy Telegram result is still unhandled; that is a recoverable precondition,
# not ambiguous state.
# The archive is built in a marked private staging directory, fsynced, then
# manifest-validated against both a fresh read of its own manifest and the live
# legacy bytes before it is published atomically and sealed ahead of the
# database.
# A refused attempt leaves no database and no published archive.
# A rerun reconciles its own marked archive and database staging and any complete
# orphan archive left by an uncatchable termination, and refuses actionably on
# any unmarked, symlinked, wrongly named, or world-readable leftover instead of
# sweeping it by name, and refuses before archiving anything when state/telegram
# itself is a symlink, the wrong type, or not mode 0700.
# Database publication is a monotonic boundary: once state/telegram/channel.db
# exists its sealed archive is never discarded, and a later fsync, reopen, or
# validation failure reports the concrete condition with both preserved.
# It then copies every old Telegram artifact into a private read-only archive,
# validates the originals without changing or deleting them, and atomically
# publishes the new database.
# Ambiguous old state publishes a blocked migration database instead of
# guessing an offset, retaining a bounded printable cause that names the
# state-relative artifact and that doctor reports.
#
# classify asks the adapter whether a captured result is message, blocked, or
# none.
# A result for an already acknowledged notice classifies as none, so two
# generic captures of one stable adapter notice cannot authorize the message
# twice.
# messages prints the still-unhandled canonical JSON payloads named by one
# message result.
# After acting on every payload, the handler runs ack on that exact result and
# then acknowledges the generic source sequence.
# A crash after the external action but before ack can repeat the action.
# reply accepts text only on stdin and takes only the accepted inbound update id.
# It binds the request to that stored message's strict chat, sender, and
# message identity, and never accepts a caller-supplied destination.
# A durable reservation precedes the send; only a validated response bound to
# that inbound message commits sent. Transport errors, timeouts, malformed
# responses, and uncertain crashes surface delivery-unknown and refuse retry.
# A definite Telegram refusal commits definitely-failed and is not retried.
# Older stored inbound messages without message_id are retained for intake but
# reply refuses them because they cannot prove an in-conversation target.
# One inbound update can have at most one reply, including across restarts and
# concurrent attempts.
#
# doctor validates the database and reports its non-secret state, integrity,
# migration, resolution evidence, and durability settings.
# resolve-migration is the one guarded exit from a blocked migration.
# It requires the exact doctor fingerprint, manifest digest, and complete
# path-plus-payload-digest set, and records operator-acknowledged delivery
# without reading credentials, contacting Telegram, or changing registration.
# export-legacy-offset is the explicit rollback preparation path.
# It writes the current committed offset back to state/.telegram-offset only
# when that cannot move the old format backward.
# retire stops future polls but preserves every database condition and notice.
# terminal never returns success: no result can retire the captain's channel.
#
# The cutover database is built on an unpublished private file: its empty schema
# is created and committed first, then one explicit IMMEDIATE transaction writes
# meta, imported messages, notices, conditions, and the offset together.
# Its rollback journal is private, owned, and reaped from a positively
# identified previous generation, by a fresh arm as well as by a rerun of
# migrate.
# A poll never stages the raw response on disk: curl streams it to a bounded
# in-memory buffer whose exact final newline-plus-three-digit suffix is the only
# status frame accepted, so no termination can leave captain bytes outside the
# store.
# An absent, partial, or interrupted frame is one transport failure and never a
# batch.
#
# TRANSACTION AND VALIDATION.
# bin/fm_procevent_telegram_state.py is the sole reader and writer of live
# Telegram state.
# It validates the complete HTTP response and every update before beginning one
# SQLite transaction.
# A valid transaction stores every newly authorized captain payload, creates
# its stable notice, advances the committed offset, and clears resolved
# conditions together.
# A rejected response creates or preserves a protocol notice but never changes
# the committed offset, API episodes, or message rows.
# The next getUpdates request can use a higher offset only after the transaction
# containing its accepted messages and notice committed.
#
# UPDATE IDENTIFIERS.
# The validator accepts only positive, non-boolean signed 32-bit update_id
# values.
# This matches the current Bot API contract that Update identifiers start at a
# positive number and that unspecified Integer fields fit a signed 32-bit
# value.
# A legacy message that was already acted on migrates as a dedup tombstone whose
# whole identity is that one identifier: it can suppress a later replay of that
# id without a wake or a payload comparison, and never advances the offset by
# itself.
# A legacy message still awaiting delivery must carry coherent text, chat and
# sender identity, and an exact integer date, or the cutover blocks.
# Batches with duplicate identifiers, identifiers below the committed offset,
# or malformed update/message identity shapes are rejected as a whole.
# Contiguous identifiers are not required.
#
# NOTICE AND BLOCKING MODEL.
# A pending notice is always emitted before another network call and remains in
# the database until ack.
# HTTP 401 and 409 are independent sticky episodes.
# Credential loss, malformed protocol input, local database failure, and a
# continuous transport failure also produce blocked results.
# Transient transport and non-401/409 HTTP failures are silent for two polls;
# the third consecutive failure creates one transport-blocked notice.
# FM_TELEGRAM_TRANSIENT_ERROR_BUDGET overrides that positive count.
# One valid typed Telegram success clears API, protocol, and transport episodes
# in the same transaction as its accepted batch.
# Credential restoration clears only the credential episode before polling.
# Neither arm nor retire clears any episode.
# An acknowledged blocked migration closes its database before sleeping for
# FM_TELEGRAM_POLL_TIMEOUT and rechecks until the complete resolution appears;
# it emits no local-state result while parked and never reads credentials or
# contacts Telegram on that path.
# resolve-migration requires --blocked-fingerprint, --archive-manifest-sha256,
# and one or more repeated --acknowledge-delivered path=sha256:digest options.
# The paths and digests must exactly match the sorted blocker records from
# doctor, and a committed repeat returns already-resolved without changing
# registration or delivering historical payloads.
#
# DURABILITY.
# The database uses SQLite rollback journaling, synchronous=FULL, fullfsync=ON,
# foreign keys, an integrity check on every command, and mode 0600 inside a
# mode-0700 state directory.
# A crash during commit therefore exposes the complete old transaction or the
# complete new transaction.
# Deterministic FM_TELEGRAM_FAILPOINT hooks exist only for executable
# crash-boundary tests.
#
# SECRECY AND IDENTITY.
# Credentials are opened once without following symlinks and parsed as strict
# data, never sourced as shell.
# The token reaches curl only through its stdin config and never appears in
# argv, database state, captured results, or message payloads.
# A text is a captain command only when both its chat id and sender id match the
# configured values.
# A text carrying no sender at all, as an anonymous group administrator post
# does, is simply not the captain: it is skipped and consumed with its batch
# rather than rejected as malformed.
#
# LIMITS.
# getUpdates called with offset=N irreversibly confirms every update below N.
# Telegram cannot replay those updates.
# Loss of every authoritative database copy can therefore be unrecoverable.
# Stable notices close the former delete-before-parent-capture window, but the
# generic handled acknowledgement still cannot make an external effect exactly
# once.
# Never describe this path as exactly-once, at-least-once, no-loss, or lossless.
#
# POLL BOUNDS.
# poll is the registered listener command arm publishes, not a command to run
# in a conversational turn.
# Each runner child performs one getUpdates call.
# FM_TELEGRAM_POLL_TIMEOUT defaults to 25 seconds and is capped at 50.
# FM_TELEGRAM_CURL_MAX_TIME defaults to the poll timeout plus 15 seconds and
# must be greater than the Telegram timeout.
# A parked blocked poll validates only the timeout before releasing its
# database connection, and validates the remaining poll settings after
# resolution becomes visible.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENGINE="$SCRIPT_DIR/fm_procevent_telegram_state.py"
SOURCE_ID=telegram
ENGINE_FAILURE_FINGERPRINT=edbf37b8195d22c8

die() { printf 'error: %s\n' "$1" >&2; exit 1; }
usage() { awk 'NR > 1 { if ($0 !~ /^#/) exit; sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; exit 2; }

env_file_path() {
  printf '%s\n' "${FM_TELEGRAM_ENV_FILE:-$HOME/.config/beanz/telegram.env}"
}

engine_available() {
  command -v python3 >/dev/null 2>&1 \
    && [ -f "$ENGINE" ] \
    && [ ! -L "$ENGINE" ]
}

run_engine() {
  engine_available || return 70
  python3 "$ENGINE" --state "$STATE" --credentials "$(env_file_path)" "$@"
}

cmd_source_id() {
  [ "$#" -eq 0 ] || usage
  printf '%s\n' "$SOURCE_ID"
}

cmd_arm() {
  [ "$#" -eq 0 ] || usage
  engine_available \
    || die "Telegram state engine is unavailable; python3 and an unmodified $ENGINE are required"
  run_engine credential-check >/dev/null \
    || die "no valid Telegram credential at $(env_file_path)"
  run_engine arm-state >/dev/null || exit 1
  "$SCRIPT_DIR/fm-procevent.sh" register telegram "$SOURCE_ID" -- \
    "$SCRIPT_DIR/fm-procevent-telegram.sh" poll || exit 1
  printf 'armed: %s\n' "$SOURCE_ID"
}

cmd_migrate() {
  local snapshot retire_output retire_status=0
  [ "$#" -eq 0 ] || usage
  engine_available \
    || die "Telegram state engine is unavailable; python3 and an unmodified $ENGINE are required"
  retire_output=$("$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID" 2>&1) || retire_status=$?
  if [ "$retire_status" -ne 0 ]; then
    die "cannot retire the $SOURCE_ID source before migration: ${retire_output:-exit $retire_status}"
  fi
  if [ -e "$STATE/telegram-watch.check.sh" ] || [ -L "$STATE/telegram-watch.check.sh" ]; then
    die "legacy telegram-watch.check.sh is still registered; deregister it before migration"
  fi
  for snapshot in "$STATE"/.fm-custom-check.*; do
    [ -e "$snapshot" ] || [ -L "$snapshot" ] || continue
    die "a watcher-owned custom-check snapshot is still present; wait for it to finish before migration"
  done
  run_engine migrate
}

cmd_classify() {
  [ "$#" -eq 1 ] || usage
  if ! engine_available; then
    printf 'blocked\n'
    return 0
  fi
  run_engine classify "$1"
}

cmd_messages() {
  [ "$#" -eq 1 ] || usage
  run_engine messages "$1"
}

cmd_ack() {
  [ "$#" -eq 1 ] || usage
  if ! engine_available; then
    printf 'unacknowledgeable: local-state\n'
    return 0
  fi
  run_engine ack "$1"
}

cmd_doctor() {
  [ "$#" -eq 0 ] || usage
  run_engine doctor
}

cmd_reply() {
  [ "$#" -eq 1 ] || usage
  engine_available \
    || die "Telegram state engine is unavailable; python3 and an unmodified $ENGINE are required"
  run_engine reply "$1"
}

cmd_resolve_migration() {
  [ "$#" -gt 0 ] || usage
  run_engine resolve-migration "$@"
}

cmd_export_legacy_offset() {
  [ "$#" -eq 0 ] || usage
  run_engine export-legacy-offset
}

cmd_poll() {
  local rc
  [ "$#" -eq 0 ] || usage
  if ! engine_available; then
    printf 'blocked: local-state fingerprint=%s\n' "$ENGINE_FAILURE_FINGERPRINT"
    return 0
  fi
  python3 "$ENGINE" --state "$STATE" --credentials "$(env_file_path)" poll
  rc=$?
  case "$rc" in
    0) return 0 ;;
    3) return 1 ;;
    *)
      printf 'blocked: local-state fingerprint=%s\n' "$ENGINE_FAILURE_FINGERPRINT"
      return 0
      ;;
  esac
}

cmd_retire() {
  [ "$#" -eq 0 ] || usage
  "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"
}

cmd_terminal() {
  [ "$#" -eq 1 ] || usage
  return 1
}

case "${1-}" in
  ack)                  shift; cmd_ack "$@" ;;
  arm)                  shift; cmd_arm "$@" ;;
  classify)             shift; cmd_classify "$@" ;;
  doctor)               shift; cmd_doctor "$@" ;;
  export-legacy-offset) shift; cmd_export_legacy_offset "$@" ;;
  messages)             shift; cmd_messages "$@" ;;
  migrate)              shift; cmd_migrate "$@" ;;
  poll)                 shift; cmd_poll "$@" ;;
  reply)                shift; cmd_reply "$@" ;;
  resolve-migration)    shift; cmd_resolve_migration "$@" ;;
  retire)               shift; cmd_retire "$@" ;;
  source-id)            shift; cmd_source_id "$@" ;;
  terminal)             shift; cmd_terminal "$@" ;;
  ''|-h|--help|help) usage ;;
  *) die "unknown command: $1" ;;
esac
