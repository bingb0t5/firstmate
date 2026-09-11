#!/usr/bin/env bash
# fm-secret-parity-check.sh - compare approved deployment secrets without
# exposing secret values, hashes, fingerprints, or value-derived strings.
#
# Usage:
#   fm-secret-parity-check.sh [check|preflight]
#   fm-secret-parity-check.sh arm
#   fm-secret-parity-check.sh disarm
#   fm-secret-parity-check.sh --help
#
# `check` performs one bounded read-only provider sweep. It prints exactly one
# redacted alert line when a new approved tuple is missing or differs, and is
# silent when all approved tuples match or the same finding is still present.
# `preflight` performs the same sweep for release use and exits nonzero when
# any required variable is unavailable, missing, or mismatched.
# `arm` creates state/secret-parity.check.sh and binds its bytes with
# fm-check-register.sh so the normal watcher schedule runs `check`.
# `disarm` removes the private shim, trust binding, and finding record.
#
# Provider credentials are read from the operator's local env stores:
#   ~/.config/beanz/coolify.env       COOLIFY_URL, COOLIFY_API_TOKEN
#   ~/.config/lalo/render-api.env     RENDER_API_KEY
# The files can be changed with FM_SECRET_PARITY_COOLIFY_ENV_FILE and
# FM_SECRET_PARITY_RENDER_ENV_FILE. Each value is resolved from a direct
# environment export first, then from the selected credential file:
# COOLIFY_URL (or FM_SECRET_PARITY_COOLIFY_URL), COOLIFY_API_TOKEN (or
# FM_SECRET_PARITY_COOLIFY_API_TOKEN), and RENDER_API_KEY (or
# FM_SECRET_PARITY_RENDER_API_KEY). The Render API base URL comes from
# FM_SECRET_PARITY_RENDER_API_URL when set, otherwise https://api.render.com.
# No n8n credential-store bearer is read; the n8n assistant bearer is outside
# this check by policy.
#
# The check compares only the approved policy below:
#   BEANBOT_PLATFORM_SYNC_TOKEN: admin-prod, admin-staging, signals, render-llalo
#   LALO_ASSISTANT_API_KEY: admin-prod, render-llalo
#   PLATFORM_SUPABASE_URL: admin-prod, admin-staging, signals, render-llalo
#   PLATFORM_SUPABASE_SERVICE_ROLE_KEY: admin-prod, admin-staging, signals, render-llalo
#   STRIPE_SECRET_KEY, STRIPE_WEBHOOK_SECRET, STRIPE_PAID_BETA_PRICE_ID:
#     admin-prod, render-llalo
#   BRAIN_TOKEN_N8N on n8n must be a member of brain's BRAIN_TOKENS list.
#   signals LALO_APP_API_URL and LALO_DIRECTORY_MATCH_URL are fixed pins.
#
# Coolify applications use /api/v1/applications/<uuid>/envs, and the n8n
# resource is the Coolify service /api/v1/services/kr2enxkgumv2eph6a4i1sibj/envs.
# Coolify values are unwrapped by one matching quote layer before comparison.
# Render uses /v1/services/<id>/env-vars/<key>.
#
# FM_SECRET_PARITY_INTERVAL defaults to 900 seconds; 0 runs every invocation.
# FM_SECRET_PARITY_PROBE_SECS defaults to 15 seconds and accepts 1..60.
# FM_SECRET_PARITY_NOW is a test-only whole-second clock override.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=secret-parity
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.$CHECK_ID"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-secret-parity-v1

# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-secret-parity-check.sh [check]   compare approved deployment secrets
  fm-secret-parity-check.sh preflight refuse an unhealthy release
  fm-secret-parity-check.sh arm       write and register state/secret-parity.check.sh
  fm-secret-parity-check.sh disarm    remove the private shim, trust binding, and record
  fm-secret-parity-check.sh --help    print this help

The operator-home registration path is:
  FM_HOME=/path/to/firstmate-home bin/fm-secret-parity-check.sh arm
The arm action calls bin/fm-check-register.sh for that home; it never creates
private registration artifacts in the repository.

Credential stores:
  FM_SECRET_PARITY_COOLIFY_ENV_FILE  default ~/.config/beanz/coolify.env
  FM_SECRET_PARITY_RENDER_ENV_FILE   default ~/.config/lalo/render-api.env
  FM_SECRET_PARITY_INTERVAL           default 900, or 0 for every run
  FM_SECRET_PARITY_PROBE_SECS         default 15, range 1..60

Direct environment exports override credential-file values when set.
See the script header for COOLIFY_URL, COOLIFY_API_TOKEN, RENDER_API_KEY, the
FM_SECRET_PARITY_* credential aliases, and FM_SECRET_PARITY_RENDER_API_URL.
EOF
}

die_usage() {
  printf 'fm-secret-parity-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

ACTION=${1:-check}
case "$ACTION" in
  check|preflight|arm|disarm) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *) die_usage "unknown action: $ACTION" ;;
esac

INTERVAL=${FM_SECRET_PARITY_INTERVAL:-900}
case "$INTERVAL" in
  ''|*[!0-9]*) die_usage "FM_SECRET_PARITY_INTERVAL must be 0 or a whole number" ;;
esac

PROBE_SECS=${FM_SECRET_PARITY_PROBE_SECS:-15}
case "$PROBE_SECS" in
  ''|*[!0-9]*|0) die_usage "FM_SECRET_PARITY_PROBE_SECS must be a whole number from 1 to 60" ;;
esac
[ "$PROBE_SECS" -le 60 ] || die_usage "FM_SECRET_PARITY_PROBE_SECS must be a whole number from 1 to 60"

PROBE_MIN_SECS=1
CLOCK_ROUNDING_SECS=1
KILL_GRACE_SECS=1

CHECK_TIMEOUT=${FM_CHECK_TIMEOUT:-30}
case "$CHECK_TIMEOUT" in
  ''|*[!0-9]*|0) CHECK_TIMEOUT=30 ;;
esac
BUDGET_MAX=$((CHECK_TIMEOUT - PROBE_MIN_SECS - CLOCK_ROUNDING_SECS - KILL_GRACE_SECS))
[ "$BUDGET_MAX" -ge 1 ] || BUDGET_MAX=1
BUDGET_SECS=$BUDGET_MAX

coolify_env_file() {
  printf '%s\n' "${FM_SECRET_PARITY_COOLIFY_ENV_FILE:-${HOME:-}/.config/beanz/coolify.env}"
}

render_env_file() {
  printf '%s\n' "${FM_SECRET_PARITY_RENDER_ENV_FILE:-${HOME:-}/.config/lalo/render-api.env}"
}

setting() {
  local name=$1 file=$2 direct
  eval "direct=\${$name-}"
  if [ -n "$direct" ]; then
    printf '%s' "$direct"
  else
    fmx_env_get "$name" "$file"
  fi
}

COOLIFY_URL_VALUE=
COOLIFY_TOKEN_VALUE=
RENDER_API_URL_VALUE=
RENDER_TOKEN_VALUE=

load_provider_settings() {
  COOLIFY_URL_VALUE=$(setting FM_SECRET_PARITY_COOLIFY_URL "$(coolify_env_file)")
  [ -n "$COOLIFY_URL_VALUE" ] || COOLIFY_URL_VALUE=$(setting COOLIFY_URL "$(coolify_env_file)")
  COOLIFY_TOKEN_VALUE=$(setting FM_SECRET_PARITY_COOLIFY_API_TOKEN "$(coolify_env_file)")
  [ -n "$COOLIFY_TOKEN_VALUE" ] || COOLIFY_TOKEN_VALUE=$(setting COOLIFY_API_TOKEN "$(coolify_env_file)")
  RENDER_API_URL_VALUE=$(setting FM_SECRET_PARITY_RENDER_API_URL "$(render_env_file)")
  [ -n "$RENDER_API_URL_VALUE" ] || RENDER_API_URL_VALUE=https://api.render.com
  RENDER_TOKEN_VALUE=$(setting FM_SECRET_PARITY_RENDER_API_KEY "$(render_env_file)")
  [ -n "$RENDER_TOKEN_VALUE" ] || RENDER_TOKEN_VALUE=$(setting RENDER_API_KEY "$(render_env_file)")
  [ -n "$COOLIFY_URL_VALUE" ] && [ -n "$COOLIFY_TOKEN_VALUE" ] &&
    [ -n "$RENDER_TOKEN_VALUE" ]
}

epoch_now() {
  case "${FM_SECRET_PARITY_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_SECRET_PARITY_NOW" ;;
  esac
}

real_epoch() { date +%s; }

DEADLINE=0
SWEEP_UNAVAILABLE=0
SWEEP_COMPLETE=0

budget_exhausted() {
  [ "$(real_epoch)" -ge "$DEADLINE" ]
}

budget_allows() {
  budget_exhausted || return 0
  SWEEP_UNAVAILABLE=1
  return 1
}

probe_bound() {
  local left
  left=$((DEADLINE - $(real_epoch)))
  if [ "$left" -lt "$PROBE_MIN_SECS" ]; then
    printf '%s\n' "$PROBE_MIN_SECS"
  elif [ "$left" -lt "$PROBE_SECS" ]; then
    printf '%s\n' "$left"
  else
    printf '%s\n' "$PROBE_SECS"
  fi
}

record_read() {
  RECORD_LAST=
  RECORD_FINDINGS=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  [ "$(sed -n '1p' "$RECORD" 2>/dev/null)" = "$RECORD_SCHEMA" ] || return 0
  RECORD_LAST=$(sed -n '2p' "$RECORD" 2>/dev/null)
  RECORD_FINDINGS=$(sed -n '3p' "$RECORD" 2>/dev/null)
  case "$RECORD_LAST" in
    ''|*[!0-9]*) RECORD_LAST= ;;
  esac
}

record_write() {
  local findings=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID.XXXXXX") || return 1
  if ! printf '%s\n%s\n%s\n' "$RECORD_SCHEMA" "$(epoch_now)" "$findings" > "$tmp" ||
    ! chmod 0600 "$tmp" ||
    ! mv -f -- "$tmp" "$RECORD"; then
    rm -f -- "$tmp"
    return 1
  fi
}

due_for_sweep() {
  [ "$INTERVAL" -eq 0 ] && return 0
  record_read
  [ -n "$RECORD_LAST" ] || return 0
  [ "$(epoch_now)" -ge "$((RECORD_LAST + INTERVAL))" ]
}

# The adapters retain provider payloads only in shell memory. Their callers see
# only PRESENT/ABSENT and the in-memory value, never a payload or diagnostic.
COOLIFY_ADMIN_PROD=
COOLIFY_ADMIN_STAGING=
COOLIFY_SIGNALS=
COOLIFY_BRAIN=
COOLIFY_N8N=

coolify_payload() {
  local kind=$1 id=$2 payload
  payload=$(curl -fsS --max-time "$(probe_bound)" \
    -H "Authorization: Bearer $COOLIFY_TOKEN_VALUE" \
    "$COOLIFY_URL_VALUE/api/v1/$kind/$id/envs" 2>/dev/null) || return 1
  printf '%s' "$payload" | jq -e 'type == "array"' >/dev/null 2>&1 || return 1
  COOLIFY_PAYLOAD=$payload
}

coolify_load() {
  local label=$1
  case "$label" in
    admin-prod)
      if [ -z "$COOLIFY_ADMIN_PROD" ]; then
        coolify_payload applications ga48pn39tt4b9bswgsuaqu7v || return 1
        COOLIFY_ADMIN_PROD=$COOLIFY_PAYLOAD
      fi
      COOLIFY_PAYLOAD=$COOLIFY_ADMIN_PROD
      ;;
    admin-staging)
      if [ -z "$COOLIFY_ADMIN_STAGING" ]; then
        coolify_payload applications o13agfus3ladxv4zpii2x792 || return 1
        COOLIFY_ADMIN_STAGING=$COOLIFY_PAYLOAD
      fi
      COOLIFY_PAYLOAD=$COOLIFY_ADMIN_STAGING
      ;;
    signals)
      if [ -z "$COOLIFY_SIGNALS" ]; then
        coolify_payload applications ywlch69qmlddbx611t6h01dh || return 1
        COOLIFY_SIGNALS=$COOLIFY_PAYLOAD
      fi
      COOLIFY_PAYLOAD=$COOLIFY_SIGNALS
      ;;
    brain)
      if [ -z "$COOLIFY_BRAIN" ]; then
        coolify_payload applications funzds3h0heoscr1h0ppw0ya || return 1
        COOLIFY_BRAIN=$COOLIFY_PAYLOAD
      fi
      COOLIFY_PAYLOAD=$COOLIFY_BRAIN
      ;;
    n8n)
      if [ -z "$COOLIFY_N8N" ]; then
        coolify_payload services kr2enxkgumv2eph6a4i1sibj || return 1
        COOLIFY_N8N=$COOLIFY_PAYLOAD
      fi
      COOLIFY_PAYLOAD=$COOLIFY_N8N
      ;;
    *) return 1 ;;
  esac
}

unwrap_coolify_value() {
  local value=$1 first last
  if [ "${#value}" -ge 2 ]; then
    first=${value%"${value#?}"}
    last=${value#"${value%?}"}
    if [ "$first" = '"' ] && [ "$last" = '"' ]; then
      value=${value:1:${#value}-2}
    elif [ "$first" = "'" ] && [ "$last" = "'" ]; then
      value=${value:1:${#value}-2}
    fi
  fi
  printf '%s' "$value"
}

coolify_env_value() {
  local label=$1 key=$2 row value
  coolify_load "$label" || return 1
  row=$(printf '%s' "$COOLIFY_PAYLOAD" | jq -c --arg key "$key" '
    [ .[] | select(.key == $key) |
      if has("real_value") and .real_value != null then .real_value
      else (.value // "") end ] |
    if length == 0 then {present:false,value:""}
    else {present:(any(.[]; . != "")),value:(map(select(. != ""))[0] // "")} end
  ' 2>/dev/null) || return 1
  PROBE_PRESENT=$(printf '%s' "$row" | jq -r '.present' 2>/dev/null) || return 1
  value=$(printf '%s' "$row" | jq -r '.value' 2>/dev/null) || return 1
  PROBE_VALUE=$(unwrap_coolify_value "$value")
}

render_env_value() {
  local key=$1 response body status row
  response=$(curl -sS --max-time "$(probe_bound)" \
    -H 'Accept: application/json' \
    -H "Authorization: Bearer $RENDER_TOKEN_VALUE" \
    -w $'\n%{http_code}' \
    "$RENDER_API_URL_VALUE/v1/services/srv-d6ndnintskes73ed4hrg/env-vars/$key" \
    2>/dev/null) || return 1
  status=${response##*$'\n'}
  body=${response%$'\n'*}
  case "$status" in
    200)
      row=$(printf '%s' "$body" | jq -c --arg key "$key" '
        if type == "object" and .key == $key then
          {present:((.value // "") != ""),value:(.value // "")}
        elif type == "object" and .envVar.key == $key then
          {present:((.envVar.value // "") != ""),value:(.envVar.value // "")}
        else {present:false,value:""} end
      ' 2>/dev/null) || return 1
      ;;
    404)
      row='{"present":false,"value":""}'
      ;;
    *) return 1 ;;
  esac
  PROBE_PRESENT=$(printf '%s' "$row" | jq -r '.present' 2>/dev/null) || return 1
  PROBE_VALUE=$(printf '%s' "$row" | jq -r '.value' 2>/dev/null) || return 1
}

probe_location() {
  local label=$1 key=$2
  case "$label" in
    admin-prod|admin-staging|signals|brain|n8n)
      coolify_env_value "$label" "$key"
      ;;
    render-llalo)
      render_env_value "$key"
      ;;
    *) return 1 ;;
  esac
}

MISMATCHES=
merge_findings() {
  local prior=$1 current=$2 result='' source entry key seen existing rest
  for source in "$prior" "$current"; do
    rest=$source
    while [ -n "$rest" ]; do
      case "$rest" in
        *'; '*) entry=${rest%%'; '*} ; rest=${rest#*'; '} ;;
        *) entry=$rest ; rest= ;;
      esac
      entry=${entry#"${entry%%[![:space:]]*}"}
      entry=${entry%"${entry##*[![:space:]]}"}
      [ -n "$entry" ] || continue
      key=${entry%% \[*}
      seen=0
      if [ -n "$result" ]; then
        existing=$result
        while [ -n "$existing" ]; do
          case "$existing" in
            *'; '*) existing_entry=${existing%%'; '*} ; existing=${existing#*'; '} ;;
            *) existing_entry=$existing ; existing= ;;
          esac
          existing_entry=${existing_entry#"${existing_entry%%[![:space:]]*}"}
          existing_entry=${existing_entry%"${existing_entry##*[![:space:]]}"}
          [ "${existing_entry%% \[*}" = "$key" ] && seen=1 && break
        done
      fi
      if [ "$seen" -eq 0 ]; then
        if [ -n "$result" ]; then
          result="$result; $entry"
        else
          result=$entry
        fi
      fi
    done
  done
  printf '%s' "$result"
}

append_mismatch() {
  local key=$1
  shift
  local labels
  labels=$*
  if [ -n "$MISMATCHES" ]; then
    MISMATCHES="$MISMATCHES; "
  fi
  MISMATCHES="$MISMATCHES$key [$labels]"
}

compare_secret() {
  local key=$1
  local first_value='' first_set=0 mismatch=0 missing=0 label labels=''
  shift
  for label in "$@"; do
    [ -n "$labels" ] && labels="$labels, "
    labels="$labels$label"
    probe_location "$label" "$key" || {
      if [ "$missing" -eq 1 ] || [ "$mismatch" -eq 1 ]; then
        append_mismatch "$key" "$labels"
      fi
      return 2
    }
    if [ "$PROBE_PRESENT" != true ]; then
      missing=1
    elif [ "$first_set" -eq 0 ]; then
      first_value=$PROBE_VALUE
      first_set=1
    elif [ "$PROBE_VALUE" != "$first_value" ]; then
      mismatch=1
    fi
  done
  [ "$missing" -eq 0 ] && [ "$mismatch" -eq 0 ] || append_mismatch "$key" "$labels"
  return 0
}

token_is_member() {
  local wanted=$1 list=$2 entry token_part
  local old_ifs=$IFS
  IFS=,
  for entry in $list; do
    entry=${entry#"${entry%%[![:space:]]*}"}
    entry=${entry%"${entry##*[![:space:]]}"}
    token_part=${entry%%:*}
    token_part=${token_part#"${token_part%%[![:space:]]*}"}
    token_part=${token_part%"${token_part##*[![:space:]]}"}
    if [ "$token_part" = "$wanted" ]; then
      IFS=$old_ifs
      return 0
    fi
  done
  IFS=$old_ifs
  return 1
}

compare_n8n_token() {
  local n8n_token labels='n8n, brain'
  probe_location n8n BRAIN_TOKEN_N8N || return 2
  [ "$PROBE_PRESENT" = true ] || {
    append_mismatch BRAIN_TOKEN_N8N "$labels"
    return 0
  }
  n8n_token=$PROBE_VALUE
  probe_location brain BRAIN_TOKENS || return 2
  if [ "$PROBE_PRESENT" != true ] || ! token_is_member "$n8n_token" "$PROBE_VALUE"; then
    append_mismatch BRAIN_TOKEN_N8N "$labels"
  fi
}

compare_pin() {
  local label=$1 key=$2 expected=$3 labels
  labels=$label
  probe_location "$label" "$key" || return 2
  if [ "$PROBE_PRESENT" != true ] || [ "$PROBE_VALUE" != "$expected" ]; then
    append_mismatch "$key" "$labels"
  fi
}

finish_sweep() {
  local store
  record_read
  if [ -n "$MISMATCHES" ]; then
    if [ "$MISMATCHES" != "$RECORD_FINDINGS" ]; then
      printf 'secret parity mismatch: %s\n' "$MISMATCHES"
    fi
  elif [ "$SWEEP_UNAVAILABLE" -eq 1 ] && [ -z "$RECORD_FINDINGS" ]; then
    printf '%s\n' 'secret parity check unavailable'
  fi
  if [ "$SWEEP_COMPLETE" -eq 1 ]; then
    store=$MISMATCHES
  elif [ -z "$MISMATCHES" ]; then
    store=$RECORD_FINDINGS
  else
    store=$(merge_findings "$RECORD_FINDINGS" "$MISMATCHES")
  fi
  record_write "$store" || true
}

sweep_step() {
  local rc
  budget_allows "$1" || return 1
  "$@"
  rc=$?
  [ "$rc" -eq 2 ] && SWEEP_UNAVAILABLE=1
  return 0
}

run_sweep() {
  sweep_step compare_secret BEANBOT_PLATFORM_SYNC_TOKEN admin-prod admin-staging signals render-llalo || return 1
  sweep_step compare_secret LALO_ASSISTANT_API_KEY admin-prod render-llalo || return 1
  sweep_step compare_secret PLATFORM_SUPABASE_URL admin-prod admin-staging signals render-llalo || return 1
  sweep_step compare_secret PLATFORM_SUPABASE_SERVICE_ROLE_KEY admin-prod admin-staging signals render-llalo || return 1
  sweep_step compare_secret STRIPE_SECRET_KEY admin-prod render-llalo || return 1
  sweep_step compare_secret STRIPE_WEBHOOK_SECRET admin-prod render-llalo || return 1
  sweep_step compare_secret STRIPE_PAID_BETA_PRICE_ID admin-prod render-llalo || return 1
  sweep_step compare_n8n_token || return 1
  sweep_step compare_pin signals LALO_APP_API_URL \
    https://admin.laloapp.co || return 1
  sweep_step compare_pin signals LALO_DIRECTORY_MATCH_URL \
    https://admin.laloapp.co/api/internal/local-signals/directory-match || return 1

  if [ "$SWEEP_UNAVAILABLE" -eq 0 ]; then
    SWEEP_COMPLETE=1
  fi
}

action_check() {
  due_for_sweep || return 0
  MISMATCHES=
  SWEEP_UNAVAILABLE=0
  SWEEP_COMPLETE=0
  command -v curl >/dev/null 2>&1 || {
    SWEEP_UNAVAILABLE=1
    finish_sweep
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    SWEEP_UNAVAILABLE=1
    finish_sweep
    return 0
  }
  load_provider_settings || {
    SWEEP_UNAVAILABLE=1
    finish_sweep
    return 0
  }

  DEADLINE=$(($(real_epoch) + BUDGET_SECS))
  run_sweep || true
  finish_sweep
  return 0
}

action_preflight() {
  MISMATCHES=
  SWEEP_UNAVAILABLE=0
  SWEEP_COMPLETE=0
  command -v curl >/dev/null 2>&1 || SWEEP_UNAVAILABLE=1
  command -v jq >/dev/null 2>&1 || SWEEP_UNAVAILABLE=1
  if [ "$SWEEP_UNAVAILABLE" -eq 0 ]; then
    load_provider_settings || SWEEP_UNAVAILABLE=1
  fi
  if [ "$SWEEP_UNAVAILABLE" -eq 0 ]; then
    DEADLINE=$(($(real_epoch) + BUDGET_SECS))
    run_sweep || true
  fi
  if [ -n "$MISMATCHES" ]; then
    printf 'secret parity preflight failed: %s\n' "$MISMATCHES"
    return 1
  fi
  if [ "$SWEEP_UNAVAILABLE" -ne 0 ] || [ "$SWEEP_COMPLETE" -ne 1 ]; then
    printf '%s\n' 'secret parity preflight unavailable'
    return 2
  fi
  printf '%s\n' 'secret parity preflight passed'
  return 0
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-secret-parity-check.sh.' \
    '# The watcher validates these bytes before execution.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-secret-parity-check.sh") check"
}

action_arm() {
  local home tmp want device
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  want=$(shim_content "$home")
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID-check.XXXXXX") || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" ||
    ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! FM_HOME="$home" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
    rm -f -- "$CHECK_SHIM"
    return 1
  fi
  printf 'armed: state/%s.check.sh\n' "$CHECK_ID"
}

action_disarm() {
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST" "$RECORD"
  printf 'disarmed: state/%s.check.sh\n' "$CHECK_ID"
}

case "$ACTION" in
  check) action_check ;;
  preflight) action_preflight ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
esac
