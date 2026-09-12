#!/usr/bin/env bash
# fm-registry-health-check.sh - observe the central automation registry.
#
# Usage:
#   fm-registry-health-check.sh run
#   fm-registry-health-check.sh report
#   fm-registry-health-check.sh arm
#   fm-registry-health-check.sh disarm
#   fm-registry-health-check.sh --help
#
# `run` performs one read-only GET /v1/automations request and prints a stale
# heartbeat wake only when its registry fingerprint has not already been
# reported.
# The fingerprint is manifest_id + last_run_id + health.
# `report` prints every registry row as a compact table and never starts,
# retries, completes, or otherwise operates an automation.
# `arm` creates a trusted watcher shim, and `disarm` removes that shim, its
# trust binding, and the private dedupe record.
#
# The registry contract is automation.registry.v1 from mrbeanz-brains.
# Source freshness is the age of last_success_at, run age is the age of
# last_start_at, heartbeat age is the age of heartbeat_at, and open failures
# are read from an optional open_failures field or derived from failed and
# timeout terminal health.
#
# Registry settings are read from direct environment values first, then from
# FM_AUTOMATION_REGISTRY_ENV_FILE, whose default is $FM_HOME/.env.
# FM_AUTOMATION_REGISTRY_URL or BRAIN_URL is the registry base URL or its
# /v1/automations URL.
# FM_AUTOMATION_REGISTRY_TOKEN or BRAIN_TOKEN is the bearer credential.
# Credential values are held in memory and never printed.
#
# FM_REGISTRY_HEALTH_GRACE_SECS defaults to 60.
# FM_REGISTRY_HEALTH_NOW is a test-only Unix-second clock override.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=registry-health
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.$CHECK_ID"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-registry-health-v1
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
  fm-registry-health-check.sh run       read the registry and alert stale rows
  fm-registry-health-check.sh report    print a compact table of all rows
  fm-registry-health-check.sh arm       register the read-only watcher check
  fm-registry-health-check.sh disarm    remove the watcher check and record
  fm-registry-health-check.sh --help    print this help

Registry settings:
  FM_AUTOMATION_REGISTRY_URL       registry base or /v1/automations URL
  FM_AUTOMATION_REGISTRY_TOKEN     bearer token
  FM_AUTOMATION_REGISTRY_ENV_FILE  .env fallback (default: $FM_HOME/.env)
  FM_REGISTRY_HEALTH_GRACE_SECS    stale grace after cadence (default: 60)
  FM_REGISTRY_HEALTH_NOW           test-only Unix-second clock override

The check only reads GET /v1/automations.
See docs/configuration.md for the operator setup contract.
EOF
}

die_usage() {
  printf 'fm-registry-health-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

ACTION=${1:-run}
case "$ACTION" in
  run|report|arm|disarm) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *) die_usage "unknown action: $ACTION" ;;
esac

GRACE=${FM_REGISTRY_HEALTH_GRACE_SECS:-60}
case "$GRACE" in
  ''|*[!0-9]*) die_usage "FM_REGISTRY_HEALTH_GRACE_SECS must be a whole number" ;;
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
  local url=${REGISTRY_URL%/}
  case "$url" in
    */v1/automations) printf '%s\n' "$url" ;;
    *) printf '%s/v1/automations\n' "$url" ;;
  esac
}

epoch_now() {
  case "${FM_REGISTRY_HEALTH_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_REGISTRY_HEALTH_NOW" ;;
  esac
}

iso_epoch() {
  local value=$1 parsed
  [ -n "$value" ] && [ "$value" != null ] || return 1
  parsed=$(date -u -d "$value" +%s 2>/dev/null) || \
    parsed=$(date -u -j -f '%Y-%m-%dT%H:%M:%S.000Z' "$value" +%s 2>/dev/null) || return 1
  case "$parsed" in
    ''|*[!0-9-]*) return 1 ;;
    *) printf '%s\n' "$parsed" ;;
  esac
}

age_seconds() {
  local value=$1 at now
  at=$(iso_epoch "$value") || {
    printf '%s\n' '?'
    return 0
  }
  now=$(epoch_now)
  if [ "$at" -gt "$now" ]; then
    printf '0s\n'
  else
    printf '%ss\n' "$((now - at))"
  fi
}

age_number() {
  local value=$1 at now
  at=$(iso_epoch "$value") || {
    printf '%s\n' ''
    return 0
  }
  now=$(epoch_now)
  if [ "$at" -gt "$now" ]; then
    printf '0\n'
  else
    printf '%s\n' "$((now - at))"
  fi
}

cadence_seconds() {
  local cadence=${1,,} number unit
  cadence=${cadence#every }
  case "$cadence" in
    ''|manual|on-demand|event-driven) return 1 ;;
  esac
  if [[ "$cadence" =~ ^\*/([0-9]+)[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*[[:space:]]+\*$ ]]; then
    printf '%s\n' "$((BASH_REMATCH[1] * 60))"
    return 0
  fi
  if [[ "$cadence" =~ ^([0-9]+)[[:space:]]*([smhd])$ ]]; then
    number=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}
  elif [[ "$cadence" =~ ^([0-9]+)[[:space:]]*(seconds?|secs?|minutes?|mins?|hours?|hrs?|days?)$ ]]; then
    number=${BASH_REMATCH[1]}
    unit=${BASH_REMATCH[2]}
  else
    return 1
  fi
  case "$unit" in
    s|sec|secs|second|seconds) printf '%s\n' "$number" ;;
    m|min|mins|minute|minutes) printf '%s\n' "$((number * 60))" ;;
    h|hr|hrs|hour|hours) printf '%s\n' "$((number * 3600))" ;;
    d|day|days) printf '%s\n' "$((number * 86400))" ;;
    *) return 1 ;;
  esac
}

json_body=
json_tmpdir=

cleanup_request() {
  [ -z "$json_tmpdir" ] || rm -rf -- "$json_tmpdir"
  json_tmpdir=
  json_body=
}

request_registry() {
  local endpoint
  cleanup_request
  [ -n "$REGISTRY_URL" ] || return 1
  case "$REGISTRY_URL" in
    http://*|https://*) ;;
    *) return 1 ;;
  esac
  command -v curl >/dev/null 2>&1 || return 1
  json_tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-registry-health.XXXXXX") || return 1
  json_body="$json_tmpdir/body"
  endpoint=$(registry_endpoint)
  if [ -n "$REGISTRY_TOKEN" ]; then
    printf 'header = "Authorization: Bearer %s"\n' "$REGISTRY_TOKEN" > "$json_tmpdir/curl.conf" ||
      return 1
    curl --config "$json_tmpdir/curl.conf" -sS --max-time "$REQUEST_TIMEOUT" \
      -o "$json_body" "$endpoint" 2>/dev/null || return 1
  else
    curl -sS --max-time "$REQUEST_TIMEOUT" -o "$json_body" "$endpoint" 2>/dev/null || return 1
  fi
  jq -e . "$json_body" >/dev/null 2>&1 || return 1
}

rows_filter() {
  jq -c '
    if type == "array" then .
    elif (.automations | type) == "array" then .automations
    elif (.result | type) == "array" then .result
    elif (.result.automations | type) == "array" then .result.automations
    else [] end
    | .[]
  ' "$1"
}

row_json() {
  local row=$1
  jq -c '
    (.manifest_id // .id // .automation_id // "unknown") as $id |
    (.owner // "unknown") as $owner |
    (.cadence // "manual") as $cadence |
    (.last_success_at // null) as $fresh |
    (.last_start_at // null) as $run |
    (.heartbeat_at // null) as $heartbeat |
    (.health // "unknown") as $health |
    (.last_run_id // "") as $last_run |
    (.terminal_outcome // null) as $outcome |
    (if (.open_failure_count | type) == "number" then .open_failure_count
     elif (.open_failures | type) == "number" then .open_failures
     elif (.open_failures | type) == "array" then (.open_failures | length)
     elif ($health == "failed" or $health == "timeout" or $outcome == "failed" or $outcome == "timeout") then 1
     else 0 end) as $failures |
    {
      id: ($id | tostring),
      owner: ($owner | tostring),
      cadence: ($cadence | tostring),
      freshness: ($fresh | tostring),
      run: ($run | tostring),
      heartbeat: ($heartbeat | tostring),
      failures: ($failures | tostring),
      health: ($health | tostring),
      terminal_outcome: ($outcome | tostring),
      last_run: ($last_run | tostring)
    }
  ' <<< "$row"
}

table_row() {
  local row=$1 id owner cadence fresh run heartbeat failures health
  id=$(jq -r '.id' <<< "$row")
  owner=$(jq -r '.owner' <<< "$row")
  cadence=$(jq -r '.cadence' <<< "$row")
  fresh=$(age_seconds "$(jq -r '.freshness' <<< "$row")")
  run=$(age_seconds "$(jq -r '.run' <<< "$row")")
  heartbeat=$(age_seconds "$(jq -r '.heartbeat' <<< "$row")")
  failures=$(jq -r '.failures' <<< "$row")
  health=$(jq -r '.health' <<< "$row")
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$owner" "$cadence" "$fresh" "$run" "$heartbeat" "$failures" "$health"
}

report_table() {
  local line output='automation owner cadence source_freshness_age run_age heartbeat_age open_failures health'
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    output="$output"$'\n'"$(table_row "$(row_json "$line")")"
  done < <(rows_filter "$json_body")
  printf '%s\n' "$output"
}

stale_line() {
  local row=$1 id owner cadence heartbeat reference age cadence_age outcome
  id=$(jq -r '.id' <<< "$row")
  owner=$(jq -r '.owner' <<< "$row")
  cadence=$(jq -r '.cadence' <<< "$row")
  heartbeat=$(jq -r '.heartbeat' <<< "$row")
  reference=$heartbeat
  [ "$reference" != null ] && [ -n "$reference" ] || reference=$(jq -r '.run' <<< "$row")
  cadence_age=$(cadence_seconds "$cadence") || return 1
  age=$(age_number "$reference")
  case "$age" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [ "$age" -gt $((cadence_age + GRACE)) ] || return 1
  outcome=$(jq -r '.terminal_outcome' <<< "$row")
  case "$outcome" in
    ''|null) ;;
    *) return 1 ;;
  esac
  [ "$(jq -r '.health' <<< "$row")" = failed ] && return 1
  [ "$(jq -r '.health' <<< "$row")" = timeout ] && return 1
  case "$(jq -r '.last_run' <<< "$row")" in
    ''|null) return 1 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$id" "$owner" "$cadence" "$age" "$(jq -r '.health' <<< "$row")"
}

record_read() {
  RECORD_FINGERPRINTS=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  [ "$(sed -n '1p' "$RECORD" 2>/dev/null)" = "$RECORD_SCHEMA" ] || return 0
  RECORD_FINGERPRINTS=$(sed -n '2p' "$RECORD" 2>/dev/null)
}

record_write() {
  local fingerprints=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID.XXXXXX") || return 1
  if ! printf '%s\n%s\n' "$RECORD_SCHEMA" "$fingerprints" > "$tmp" ||
    ! chmod 0600 "$tmp" || ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

fingerprint_seen() {
  local fingerprint=$1 existing
  existing=$RECORD_FINGERPRINTS
  while [ -n "$existing" ]; do
    case "$existing" in
      *';'*) [ "${existing%%;*}" = "$fingerprint" ] && return 0; existing=${existing#*;} ;;
      *) [ "$existing" = "$fingerprint" ] && return 0; existing= ;;
    esac
  done
  return 1
}

action_run() {
  local line id owner cadence age health fingerprint alert='' retained='' row stale
  load_settings
  record_read
  if ! request_registry; then
    cleanup_request
    [ "$RECORD_FINGERPRINTS" = unavailable ] || printf '%s\n' 'registry health unavailable'
    record_write unavailable || true
    return 0
  fi
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    row=$(row_json "$line") || continue
    stale=$(stale_line "$row" 2>/dev/null) || stale=
    if [ -n "$stale" ]; then
      IFS=$'\t' read -r id owner cadence age health <<< "$stale"
      fingerprint="$id|$(jq -r '.last_run' <<< "$row")|$health"
      if [ -z "$retained" ]; then
        retained=$fingerprint
      else
        retained="$retained;$fingerprint"
      fi
      if ! fingerprint_seen "$fingerprint"; then
        line="$owner's $id has not reported for ${age}s (expected every $cadence)"
        if [ -z "$alert" ]; then
          alert=$line
        else
          alert="$alert; $line"
        fi
      fi
    fi
  done < <(rows_filter "$json_body")
  cleanup_request
  if [ -n "$alert" ]; then
    fm_cap_line_var "$alert" "$MAX_LINE"
    printf '%s\n' "$FM_LINE_CAP_LINE"
  fi
  record_write "$retained" || true
}

action_report() {
  load_settings
  if ! request_registry; then
    cleanup_request
    printf '%s\n' 'registry health unavailable'
    return 0
  fi
  report_table
  cleanup_request
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-registry-health-check.sh.' \
    '# The watcher validates these bytes before execution.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-registry-health-check.sh") run"
}

action_arm() {
  local home tmp want device
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID-check.XXXXXX") || return 1
  want=$(shim_content "$home")
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" ||
    ! fm_pr_private_file_valid "$tmp" 700 "$device" ||
    ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
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
  run) action_run ;;
  report) action_report ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
esac
