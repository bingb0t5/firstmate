#!/usr/bin/env bash
# fm-automation-health-check.sh - publish a compact health rollup for the
# automations registered with the brain registry without exposing credentials.
#
# Usage:
#   fm-automation-health-check.sh [check]
#   fm-automation-health-check.sh start <stream>
#   fm-automation-health-check.sh heartbeat <stream> <run-id>
#   fm-automation-health-check.sh complete <stream> <run-id> <success|failure>
#   fm-automation-health-check.sh arm
#   fm-automation-health-check.sh disarm
#   fm-automation-health-check.sh --help
#
# `check` reads GET /v1/automations and emits one deduplicated line containing
# source freshness, queue age, last successful run age, retry count, open-alert
# count, and receipt status for every stream.
# A stream is green only when its registry projection has an explicit terminal
# automation.run.receipt.v1 with status success and no open alerts.
# The registry owns scheduling and execution; this script never starts n8n or
# creates a second scheduler for a host-local check such as secret-parity.
#
# The registry projection fields are:
#   id, source_freshness_age_seconds, queue_age_seconds,
#   last_success_age_seconds, retry_count, open_alerts, last_terminal_receipt.
# `last_terminal_receipt` must contain type, terminal=true, and status=success.
# The lifecycle actions use POST /v1/automations/<stream>/{start,heartbeat,complete}.
#
# Registry credentials are read from direct environment values first, then from
# FM_AUTOMATION_REGISTRY_ENV_FILE (default $FM_HOME/.env):
# FM_AUTOMATION_REGISTRY_URL or BRAIN_URL, and
# FM_AUTOMATION_REGISTRY_TOKEN or BRAIN_TOKEN.
# Credential values are held in memory for curl only and are never printed.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=automation-health
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.$CHECK_ID"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-automation-health-v1
MAX_LINE=1800

# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-automation-health-check.sh [check]   report registered automation health
  fm-automation-health-check.sh start <stream>
                                           start one registered automation run
  fm-automation-health-check.sh heartbeat <stream> <run-id>
                                           heartbeat one active run
  fm-automation-health-check.sh complete <stream> <run-id> <success|failure>
                                           complete one run with a terminal receipt
  fm-automation-health-check.sh arm        register the health poll with the watcher
  fm-automation-health-check.sh disarm     remove the health poll and its record
  fm-automation-health-check.sh --help     print this help

Registry settings:
  FM_AUTOMATION_REGISTRY_URL       registry base or /v1/automations URL
  FM_AUTOMATION_REGISTRY_TOKEN     bearer token
  FM_AUTOMATION_REGISTRY_ENV_FILE  .env file fallback (default: $FM_HOME/.env)
  FM_AUTOMATION_HEALTH_INTERVAL    seconds between reports (default: 300)
  FM_CHECK_TIMEOUT                  request bound (default: 30)

The registry response must contain an `automations` array (or be an array).
Each projection reports the fields documented in the script header.
EOF
}

die_usage() {
  printf 'fm-automation-health-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

ACTION=${1:-check}
case "$ACTION" in
  check|start|heartbeat|complete|arm|disarm) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *) die_usage "unknown action: $ACTION" ;;
esac

INTERVAL=${FM_AUTOMATION_HEALTH_INTERVAL:-300}
case "$INTERVAL" in
  ''|*[!0-9]*) die_usage "FM_AUTOMATION_HEALTH_INTERVAL must be a whole number" ;;
esac

REQUEST_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$REQUEST_TIMEOUT" in
  ''|*[!0-9]*|0) REQUEST_TIMEOUT=30 ;;
esac

registry_env_file() {
  printf '%s\n' "${FM_AUTOMATION_REGISTRY_ENV_FILE:-$FM_HOME/.env}"
}

setting() {
  local direct_name=$1 file_name=$2 file=$3 direct=
  eval "direct=\${$direct_name-}"
  if [ -n "$direct" ]; then
    printf '%s' "$direct"
  else
    fmx_env_get "$file_name" "$file"
  fi
}

REGISTRY_URL=
REGISTRY_TOKEN=

load_settings() {
  local file
  file=$(registry_env_file)
  REGISTRY_URL=$(setting FM_AUTOMATION_REGISTRY_URL FM_AUTOMATION_REGISTRY_URL "$file")
  [ -n "$REGISTRY_URL" ] || REGISTRY_URL=$(setting BRAIN_URL BRAIN_URL "$file")
  REGISTRY_TOKEN=$(setting FM_AUTOMATION_REGISTRY_TOKEN FM_AUTOMATION_REGISTRY_TOKEN "$file")
  [ -n "$REGISTRY_TOKEN" ] || REGISTRY_TOKEN=$(setting BRAIN_TOKEN BRAIN_TOKEN "$file")
  case "$REGISTRY_URL" in
    *$'\n'*|*$'\r'*) REGISTRY_URL= ;;
  esac
  case "$REGISTRY_TOKEN" in
    *$'\n'*|*$'\r'*) REGISTRY_TOKEN= ;;
  esac
}

registry_endpoint() {
  local url=$REGISTRY_URL
  url=${url%/}
  case "$url" in
    */v1/automations) printf '%s\n' "$url" ;;
    *) printf '%s/v1/automations\n' "$url" ;;
  esac
}

registry_base() {
  local url=$REGISTRY_URL
  url=${url%/}
  case "$url" in
    */v1/automations) printf '%s\n' "${url%/v1/automations}" ;;
    *) printf '%s\n' "$url" ;;
  esac
}

stream_valid() {
  [ "$#" -eq 1 ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

run_id_valid() {
  [ "$#" -eq 1 ] || return 1
  [[ "$1" =~ ^[A-Za-z0-9._:-]+$ ]]
}

json_body=
json_code=
json_tmpdir=

cleanup_request() {
  [ -z "$json_tmpdir" ] || rm -rf -- "$json_tmpdir"
  json_tmpdir=
  json_body=
  json_code=
}

request() {
  local method=$1 endpoint=$2 body=${3-} code
  cleanup_request
  [ -n "$REGISTRY_URL" ] || return 2
  command -v curl >/dev/null 2>&1 || return 2
  json_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-automation-health.XXXXXX") || return 2
  json_body="$json_tmpdir/body"
  json_code="$json_tmpdir/code"
  if [ -n "$body" ]; then
    printf '%s' "$body" > "$json_tmpdir/request" || {
      cleanup_request
      return 2
    }
  fi
  if [ "$method" = GET ]; then
    if [ -n "$REGISTRY_TOKEN" ]; then
      curl -sS --max-time "$REQUEST_TIMEOUT" \
        -H "Authorization: Bearer $REGISTRY_TOKEN" \
        -o "$json_body" -w '%{http_code}' "$(registry_endpoint)" >"$json_code" 2>/dev/null
    else
      curl -sS --max-time "$REQUEST_TIMEOUT" \
        -o "$json_body" -w '%{http_code}' "$(registry_endpoint)" >"$json_code" 2>/dev/null
    fi
  else
    if [ -n "$REGISTRY_TOKEN" ]; then
      curl -sS --max-time "$REQUEST_TIMEOUT" -X "$method" \
        -H 'Content-Type: application/json' \
        -H "Authorization: Bearer $REGISTRY_TOKEN" \
        --data-binary "@$json_tmpdir/request" \
        -o "$json_body" -w '%{http_code}' \
        "$(registry_base)/v1/automations/$endpoint" >"$json_code" 2>/dev/null
    else
      curl -sS --max-time "$REQUEST_TIMEOUT" -X "$method" \
        -H 'Content-Type: application/json' \
        --data-binary "@$json_tmpdir/request" \
        -o "$json_body" -w '%{http_code}' \
        "$(registry_base)/v1/automations/$endpoint" >"$json_code" 2>/dev/null
    fi
  fi
  code=$(cat "$json_code" 2>/dev/null)
  case "$code" in
    2[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  jq -e . "$json_body" >/dev/null 2>&1 || return 1
  return 0
}

record_read() {
  RECORD_EPOCH=0
  RECORD_REPORTED=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  [ "$(sed -n '1p' "$RECORD" 2>/dev/null)" = "$RECORD_SCHEMA" ] || return 0
  RECORD_EPOCH=$(sed -n '2p' "$RECORD" 2>/dev/null)
  case "$RECORD_EPOCH" in
    ''|*[!0-9]*) RECORD_EPOCH=0 ;;
  esac
  RECORD_REPORTED=$(sed -n '3p' "$RECORD" 2>/dev/null)
}

record_write() {
  local report=$1 tmp now
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID.XXXXXX") || return 1
  now=$(date +%s)
  if ! printf '%s\n%s\n%s\n' "$RECORD_SCHEMA" "$now" "$report" > "$tmp" ||
    ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

age_value() {
  case "$1" in
    ''|null|*[!0-9]*) printf '?\n' ;;
    *) printf '%ss\n' "$1" ;;
  esac
}

projection_line() {
  jq -r '
    def rows:
      if type == "array" then .
      elif (.automations | type) == "array" then .automations
      else empty
      end;
    def value($a; $b): if ($a | type) == "number" then $a elif ($b | type) == "number" then $b else null end;
    rows[] |
    (.id // .stream // .slug // .name // "") as $raw_id |
    (if $raw_id != "" then $raw_id else "unknown" end) as $id |
    (value(.source_freshness_age_seconds; .source.freshness_age_seconds)) as $fresh |
    (value(.queue_age_seconds; .queue.age_seconds)) as $queue |
    (value(.last_success_age_seconds; .last_success.age_seconds)) as $last |
    (.retry_count // .retries // .last_run.retry_count) as $retries |
    (.open_alerts // .alerts) as $alerts |
    (.last_terminal_receipt // .last_receipt // .last_run.receipt) as $receipt |
    [
      $id,
      (if ($fresh | type) == "number" then (($fresh|floor)|tostring) else "?" end),
      (if ($queue | type) == "number" then (($queue|floor)|tostring) else "?" end),
      (if ($last | type) == "number" then (($last|floor)|tostring) else "?" end),
      (if ($retries | type) == "number" then (($retries|floor)|tostring) else "?" end),
      (if ($alerts | type) == "array" then (($alerts|length)|tostring) else "?" end),
      (if ($receipt | type) == "object"
          and ($receipt.type // "") == "automation.run.receipt.v1"
          and ($receipt.terminal // false) == true
          and (($receipt.status // "") == "success" or ($receipt.status // "") == "succeeded")
        then "ok" else "missing" end),
      (if $raw_id != "" then "1" else "0" end)
    ] | @tsv
  ' "$1"
}

format_rollup() {
  local body=$1 rows line id fresh queue last retries alerts receipt
  local overall=green report='automation health:'
  rows=$(projection_line "$body" 2>/dev/null) || return 1
  if [ -z "$rows" ]; then
    report='green automation health:'
    fm_cap_line_var "$report" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
    return 0
  fi
  while IFS=$'\t' read -r id fresh queue last retries alerts receipt id_valid; do
    id=$(printf '%s' "$id" | tr '\t\r\n' '   ')
    case "$id" in
      *[!A-Za-z0-9._:-]*) return 1 ;;
    esac
    line=$(printf ' %s{fresh=%s queue=%s last=%s retries=%s alerts=%s receipt=%s};' \
      "$id" "$(age_value "$fresh")" "$(age_value "$queue")" \
      "$(age_value "$last")" "$retries" "$alerts" "$receipt")
    report=$report$line
    if [ "$id_valid" != 1 ] || [ "$fresh" = '?' ] || [ "$queue" = '?' ] \
      || [ "$last" = '?' ] || [ "$retries" = '?' ] || [ "$alerts" = '?' ] \
      || [ "$receipt" != ok ] || [ "$alerts" != 0 ]; then
      overall=red
    fi
  done <<< "$rows"
  report="$overall $report"
  fm_cap_line_var "$report" "$MAX_LINE"
  printf '%s\n' "$FM_LINE_CAP_LINE"
}

action_check() {
  local report now
  load_settings
  record_read
  now=$(date +%s)
  if [ "$INTERVAL" -ne 0 ] && [ "$RECORD_EPOCH" -gt 0 ] &&
    [ "$now" -ge "$RECORD_EPOCH" ] &&
    [ $((now - RECORD_EPOCH)) -lt "$INTERVAL" ]; then
    return 0
  fi
  if [ -z "$REGISTRY_URL" ] || ! request GET ''; then
    cleanup_request
    report='automation health: unavailable'
  else
    report=$(format_rollup "$json_body" 2>/dev/null) || report='automation health: unavailable'
    cleanup_request
  fi
  if [ "$report" != "$RECORD_REPORTED" ]; then
    printf '%s\n' "$report"
  fi
  record_write "$report" || true
}

action_lifecycle() {
  local action=$1 stream=$2 run_id=${3-} status=${4-} payload response returned
  load_settings
  stream_valid "$stream" || die_usage "stream must contain only letters, digits, dot, underscore, colon, or dash"
  case "$action" in
    start)
      payload=$(jq -cn --arg stream "$stream" '{stream:$stream}') ;;
    heartbeat)
      run_id_valid "$run_id" || die_usage "run-id must contain only letters, digits, dot, underscore, colon, or dash"
      payload=$(jq -cn --arg run_id "$run_id" '{run_id:$run_id}') ;;
    complete)
      run_id_valid "$run_id" || die_usage "run-id must contain only letters, digits, dot, underscore, colon, or dash"
      case "$status" in success|failure) ;; *) die_usage "completion status must be success or failure" ;; esac
      payload=$(jq -cn --arg run_id "$run_id" --arg status "$status" \
        '{run_id:$run_id,receipt:{type:"automation.run.receipt.v1",terminal:true,status:$status}}') ;;
  esac
  if ! request POST "$stream/$action" "$payload"; then
    cleanup_request
    printf 'automation %s unavailable\n' "$action" >&2
    return 1
  fi
  response=$(cat "$json_body")
  cleanup_request
  case "$action" in
    start)
      returned=$(jq -r '.run_id // .run.id // .id // empty' <<< "$response")
      run_id_valid "$returned" || {
        printf 'automation start returned no run id\n' >&2
        return 1
      }
      printf 'automation started: stream=%s run=%s\n' "$stream" "$returned" ;;
    heartbeat) printf 'automation heartbeat: stream=%s run=%s\n' "$stream" "$run_id" ;;
    complete) printf 'automation completed: stream=%s run=%s status=%s\n' "$stream" "$run_id" "$status" ;;
  esac
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-automation-health-check.sh.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-automation-health-check.sh") check"
}

action_arm() {
  local home tmp
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID-check.XXXXXX") || return 1
  if ! shim_content "$home" > "$tmp" || ! chmod 0700 "$tmp"; then
    rm -f -- "$tmp"
    return 1
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  mv -f -- "$tmp" "$CHECK_SHIM" || return 1
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

trap cleanup_request EXIT HUP INT TERM

case "$ACTION" in
  check) action_check ;;
  start|heartbeat|complete)
    [ "$#" -ge 2 ] || die_usage "$ACTION requires a stream"
    action_lifecycle "$ACTION" "$2" "${3-}" "${4-}" ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
esac
