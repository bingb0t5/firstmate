#!/usr/bin/env bash
# fm-todoist-replies.sh - import pending Todoist captain events into the inbox.
#
# Usage: fm-todoist-replies.sh
#
# Each unseen event is filed as data through `bin/fm-inbox.sh note -`, recorded
# in the durable seen-list, and acknowledged by id. Pending and handled inbox
# notes keyed by todoist-bridge-event-id prevent duplicate filing across crashes.
# Event text is never evaluated as shell.
# Configuration is read from config/todoist-bridge.env without sourcing it.
# An absent bridge configuration is a successful no-op that prints one line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENV_FILE="$CONFIG/todoist-bridge.env"
SEEN_FILE="$STATE/todoist-bridge-replies.seen"
INBOX_BIN="${FM_TODOIST_INBOX_BIN:-$SCRIPT_DIR/fm-inbox.sh}"

die() {
  printf 'fm-todoist-replies: %s\n' "$*" >&2
  exit 1
}

read_setting() { # <name>
  local name=$1 line value
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      "$name="*)
        value=${line#"$name="}
        case "$value" in
          \"*\") value=${value#\"}; value=${value%\"} ;;
          \'*\') value=${value#\'}; value=${value%\'} ;;
        esac
        printf '%s' "$value"
        return 0
        ;;
    esac
  done < "$ENV_FILE"
}

setting() {
  local name=$1 value
  case "$name" in
    TODOIST_BRIDGE_REPLIES_URL) value=${TODOIST_BRIDGE_REPLIES_URL-} ;;
    TODOIST_BRIDGE_ACK_URL) value=${TODOIST_BRIDGE_ACK_URL-} ;;
    TODOIST_BRIDGE_TOKEN) value=${TODOIST_BRIDGE_TOKEN-} ;;
    *) value= ;;
  esac
  if [ -z "$value" ] && [ -r "$ENV_FILE" ]; then
    value=$(read_setting "$name" || true)
  fi
  printf '%s' "$value"
}

if [ ! -r "$ENV_FILE" ] &&
  [ -z "${TODOIST_BRIDGE_REPLIES_URL:-}" ] &&
  [ -z "${TODOIST_BRIDGE_ACK_URL:-}" ] &&
  [ -z "${TODOIST_BRIDGE_TOKEN:-}" ]; then
  printf 'fm-todoist-replies: bridge unconfigured\n'
  exit 0
fi

REPLIES_URL=$(setting TODOIST_BRIDGE_REPLIES_URL)
ACK_URL=$(setting TODOIST_BRIDGE_ACK_URL)
TOKEN=$(setting TODOIST_BRIDGE_TOKEN)
[ -n "$REPLIES_URL" ] && [ -n "$ACK_URL" ] && [ -n "$TOKEN" ] ||
  die "bridge configuration is incomplete"
command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
[ -x "$INBOX_BIN" ] || die "captain inbox is unavailable"

inbox_has_event() { # <event-id>
  local event_id=$1 note dir
  local -a dirs=("$STATE/inbox")
  [ -d "$STATE/inbox/handled" ] && dirs+=("$STATE/inbox/handled")
  for dir in "${dirs[@]}"; do
    [ -d "$dir" ] || continue
    for note in "$dir"/*.note; do
      [ -e "$note" ] || continue
      grep -F -x -q -- "todoist-bridge-event-id: $event_id" "$note" && return 0
    done
  done
  return 1
}

mkdir -p "$STATE"
lock="$STATE/.todoist-bridge-replies.lock"
if ! mkdir "$lock" 2>/dev/null; then
  exit 0
fi
trap 'rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM

tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-todoist-replies.XXXXXX") ||
  die "temporary directory creation failed"
trap 'rm -rf "$tmpdir"; rmdir "$lock" 2>/dev/null || true' EXIT HUP INT TERM

response="$tmpdir/response.json"
events="$tmpdir/events.json"
if ! curl --fail --silent --show-error --max-time "${FM_CHECK_TIMEOUT:-30}" \
  --request GET --header "Authorization: Bearer $TOKEN" "$REPLIES_URL" \
  >"$response" 2>"$tmpdir/curl.error"; then
  die "bridge replies fetch failed"
fi

if ! jq -e '
  if type != "array" then error("pending replies must be an array") else . end
  | all(.[]; (.id != null and (.id | tostring | length > 0)
              and (.card_key | type) == "string"
              and (.kind == "comment" or .kind == "new_card")
              and (.text | type) == "string"
              and (.author | type) == "string"
              and (.at | type) == "string"))
' "$response" >/dev/null 2>"$tmpdir/response.error"; then
  die "bridge replies response is malformed"
fi
jq -c '.' "$response" >"$events" || die "bridge replies response could not be read"

touch "$SEEN_FILE"
while IFS= read -r event; do
  id=$(printf '%s' "$event" | jq -r '.id | tostring')
  if grep -F -x -- "$id" "$SEEN_FILE" >/dev/null 2>&1; then
    ack=$(printf '%s' "$event" | jq -c '{id:.id}')
    if ! printf '%s' "$ack" | curl --fail --silent --show-error \
      --max-time "${FM_CHECK_TIMEOUT:-30}" --request POST \
      --header 'Content-Type: application/json' \
      --header "Authorization: Bearer $TOKEN" --data-binary @- "$ACK_URL" \
      >"$tmpdir/ack.out" 2>"$tmpdir/ack.error"; then
      die "bridge reply acknowledgement failed"
    fi
    continue
  fi

  if inbox_has_event "$id"; then
    printf '%s\n' "$id" >>"$SEEN_FILE" || die "reply seen-list could not be updated"
    ack=$(printf '%s' "$event" | jq -c '{id:.id}')
    if ! printf '%s' "$ack" | curl --fail --silent --show-error \
      --max-time "${FM_CHECK_TIMEOUT:-30}" --request POST \
      --header 'Content-Type: application/json' \
      --header "Authorization: Bearer $TOKEN" --data-binary @- "$ACK_URL" \
      >"$tmpdir/ack.out" 2>"$tmpdir/ack.error"; then
      die "bridge reply acknowledgement failed"
    fi
    continue
  fi

  card_key=$(printf '%s' "$event" | jq -r '.card_key')
  kind=$(printf '%s' "$event" | jq -r '.kind')
  body="$tmpdir/body"
  {
    printf 'todoist-bridge-event-id: %s\n' "$id"
    printf 'todoist %s %s: ' "$card_key" "$kind"
    printf '%s' "$event" | jq -r '.text'
  } >"$body"

  inbox_err="$tmpdir/inbox.error"
  if ! FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$INBOX_BIN" note - <"$body" >"$tmpdir/inbox.out" 2>"$inbox_err"; then
    if grep -F ' is saved at ' "$inbox_err" >/dev/null 2>&1 &&
      grep -F ' but firstmate was NOT woken' "$inbox_err" >/dev/null 2>&1; then
      :
    else
      die "captain inbox filing failed"
    fi
  fi
  printf '%s\n' "$id" >>"$SEEN_FILE" || die "reply seen-list could not be updated"
  ack=$(printf '%s' "$event" | jq -c '{id:.id}')
  if ! printf '%s' "$ack" | curl --fail --silent --show-error \
    --max-time "${FM_CHECK_TIMEOUT:-30}" --request POST \
    --header 'Content-Type: application/json' \
    --header "Authorization: Bearer $TOKEN" --data-binary @- "$ACK_URL" \
    >"$tmpdir/ack.out" 2>"$tmpdir/ack.error"; then
    die "bridge reply acknowledgement failed"
  fi
done < <(jq -c '.[]' "$events")
