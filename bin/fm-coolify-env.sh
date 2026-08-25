#!/usr/bin/env bash
# fm-coolify-env.sh - set a Coolify application env var without exposing secrets.
#
# Firstmate invokes this tool; the secret never enters an agent session. Values
# are read through bin/fm-credential-lib.sh (never source/dot), sent to Coolify
# over HTTPS with Authorization in a private header file (never argv), and every
# stdout/stderr byte is filtered through registered redaction patterns.
#
# Usage:
#   fm-coolify-env.sh set <service> <KEY> --value-from <source>
#
# <service> names an entry in the Coolify service registry
# ($FM_COOLIFY_SERVICES_FILE or $BEANZ_CONFIG/coolify-services.env):
#   COOLIFY_SERVICE_<service>=<application-uuid>
#
# --value-from sources (see fm-credential-lib.sh):
#   literal:<text>        non-secret literal
#   env:<file>:<KEY>      KEY from a beanz credential file basename
#   brain:<identity>      token from BRAIN_TOKENS for identity in brain.env
#
# Coolify API (documented at coolify.io/docs/api): PATCH
# /api/v1/applications/{uuid}/envs with JSON {"key","value"}. On HTTP 404 the
# tool POSTs to create the env. COOLIFY_URL and COOLIFY_API_TOKEN come from
# $FM_COOLIFY_ENV_FILE or $BEANZ_CONFIG/coolify.env.
#
# Success prints exactly: ok: <service> <KEY> set
# Failures print a generic reason with no secret material and exit non-zero.
# FM_COOLIFY_TIMEOUT bounds every network call (default 30s); timeouts fail closed.
#
# Environment:
#   FM_BEANZ_CONFIG_DIR        beanz config directory (default ~/.config/beanz)
#   FM_COOLIFY_ENV_FILE        Coolify API credentials file
#   FM_COOLIFY_SERVICES_FILE   service name to application UUID registry
#   FM_COOLIFY_TIMEOUT         hard network bound in seconds (default 30)
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-credential-lib.sh disable=SC1091
. "$SELF_DIR/fm-credential-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh disable=SC1091
. "$SELF_DIR/fm-timeout-lib.sh"

# Secrets must never appear in shell trace output (bash -x).
{ set +x; } 2>/dev/null

fm_credential_redact_init

# The request scratch dir holds the Authorization header and the JSON body, so
# it must not outlive this process on any path, including a signal mid-curl.
COOLIFY_REQUEST_TMPDIR=

coolify_cleanup() {
  [ -n "${COOLIFY_REQUEST_TMPDIR:-}" ] || return 0
  rm -rf "$COOLIFY_REQUEST_TMPDIR"
  COOLIFY_REQUEST_TMPDIR=
}

trap coolify_cleanup EXIT
trap 'coolify_cleanup; exit 130' INT
trap 'coolify_cleanup; exit 143' TERM
trap 'coolify_cleanup; exit 129' HUP

usage() {
  cat <<'EOF'
fm-coolify-env.sh - set a Coolify application environment variable safely.

Usage:
  fm-coolify-env.sh set <service> <KEY> --value-from <source>

Sources for --value-from:
  literal:<text>        non-secret literal value
  env:<file>:<KEY>      read KEY from a beanz credential file (basename only)
  brain:<identity>      token for identity from BRAIN_TOKENS in brain.env

Service registry (COOLIFY_SERVICE_<service>=uuid):
  $FM_COOLIFY_SERVICES_FILE or $BEANZ_CONFIG/coolify-services.env

Coolify credentials (COOLIFY_URL, COOLIFY_API_TOKEN):
  $FM_COOLIFY_ENV_FILE or $BEANZ_CONFIG/coolify.env

Success output: ok: <service> <KEY> set

Environment:
  FM_BEANZ_CONFIG_DIR       override beanz config directory
  FM_COOLIFY_ENV_FILE       override Coolify credential file
  FM_COOLIFY_SERVICES_FILE  override service UUID registry
  FM_COOLIFY_TIMEOUT        network bound in seconds (default 30)
EOF
}

die() {
  fm_credential_safe_die "fm-coolify-env: $1" "${2:-1}"
}

COOLIFY_TIMEOUT=${FM_COOLIFY_TIMEOUT:-30}
case "$COOLIFY_TIMEOUT" in
  ''|*[!0-9]*|0*) COOLIFY_TIMEOUT=30 ;;
esac

coolify_env_file() {
  if [ -n "${FM_COOLIFY_ENV_FILE:-}" ]; then
    printf '%s\n' "$FM_COOLIFY_ENV_FILE"
  else
    printf '%s/coolify.env\n' "$(fm_credential_config_dir)"
  fi
}

coolify_services_file() {
  if [ -n "${FM_COOLIFY_SERVICES_FILE:-}" ]; then
    printf '%s\n' "$FM_COOLIFY_SERVICES_FILE"
  else
    printf '%s/coolify-services.env\n' "$(fm_credential_config_dir)"
  fi
}

service_uuid() {
  local service=$1 registry uuid
  registry=$(coolify_services_file)
  uuid=$(fm_credential_env_get "$registry" "COOLIFY_SERVICE_$service") || return
  [ -n "$uuid" ] || return 1
  printf '%s' "$uuid"
}

normalize_coolify_base() {
  local base=$1
  base=${base%/}
  printf '%s' "$base"
}

coolify_request() {
  fm_credential_xtrace_off
  local method=$1 base=$2 uuid=$3 env_key=$4 env_value=$5 token=$6
  local tmpdir header_file body_file response http_code rc=0
  tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-coolify-env.XXXXXX") || return 1
  COOLIFY_REQUEST_TMPDIR=$tmpdir
  chmod 700 "$tmpdir"
  header_file="$tmpdir/header"
  body_file="$tmpdir/body"
  printf 'Authorization: Bearer %s' "$token" > "$header_file"
  chmod 600 "$header_file"
  fm_credential_json_object "$env_key" "$env_value" > "$body_file" || {
    coolify_cleanup
    return 1
  }
  chmod 600 "$body_file"
  response=$(
    fm_run_timed "$COOLIFY_TIMEOUT" curl -sS \
      -X "$method" \
      -H "@$header_file" \
      -H 'Content-Type: application/json' \
      -d "@$body_file" \
      -w $'\n%{http_code}' \
      "$(normalize_coolify_base "$base")/api/v1/applications/$uuid/envs" \
      2>/dev/null
  ) || rc=$?
  coolify_cleanup
  if [ "$rc" -eq 124 ]; then
    return 124
  fi
  if [ "$rc" -ne 0 ]; then
    return 1
  fi
  http_code=${response##*$'\n'}
  case "$http_code" in
    2??) return 0 ;;
    401|403) return 3 ;;
    404) return 4 ;;
    *) return 1 ;;
  esac
}

cmd_set() {
  fm_credential_xtrace_off
  local service=$1 env_key=$2 value_source=$3
  local cred_file base token uuid value rc
  [ -n "$service" ] && [ -n "$env_key" ] && [ -n "$value_source" ] || die "usage: set <service> <KEY> --value-from <source>" 2

  cred_file=$(coolify_env_file)
  base=$(fm_credential_env_get "$cred_file" COOLIFY_URL) || die "Coolify URL is not configured" 1
  token=$(fm_credential_env_get "$cred_file" COOLIFY_API_TOKEN) || die "Coolify API token is not configured" 1
  fm_credential_redact_register "$token"

  uuid=$(service_uuid "$service") || die "unknown service (check Coolify service registry)" 1

  value=$(fm_credential_resolve_value_from "$value_source") || {
    case "$?" in
      2) die "malformed --value-from source" 1 ;;
      3) die "credential file entry is ambiguous" 1 ;;
      *) die "could not read value source" 1 ;;
    esac
  }
  # literal:<text> is a declared non-secret; registering it would blank the
  # service name, the key, or this program's own name in every later line.
  if fm_credential_source_is_secret "$value_source"; then
    fm_credential_redact_register "$value"
  fi

  coolify_request PATCH "$base" "$uuid" "$env_key" "$value" "$token"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    fm_credential_safe_print 1 "ok: $service $env_key set"
    return 0
  fi
  if [ "$rc" -eq 4 ]; then
    coolify_request POST "$base" "$uuid" "$env_key" "$value" "$token"
    rc=$?
    if [ "$rc" -eq 0 ]; then
      fm_credential_safe_print 1 "ok: $service $env_key set"
      return 0
    fi
  fi
  case "$rc" in
    3) die "Coolify API rejected credentials" 1 ;;
    124) die "Coolify API request timed out" 1 ;;
    *) die "Coolify API request failed" 1 ;;
  esac
}

SUBCMD=
SERVICE=
ENV_KEY=
VALUE_FROM=

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    set)
      [ -z "$SUBCMD" ] || die "only one command may be given" 2
      SUBCMD='set'
      shift
      [ $# -ge 2 ] || die "set requires <service> <KEY>" 2
      SERVICE=$1
      ENV_KEY=$2
      shift 2
      ;;
    --value-from)
      [ $# -ge 2 ] || die "--value-from requires a source" 2
      VALUE_FROM=$2
      shift 2
      ;;
    *)
      die "unknown argument: $1" 2
      ;;
  esac
done

[ -n "$SUBCMD" ] || die "a command is required (try --help)" 2

case "$SUBCMD" in
  set)
    [ -n "$VALUE_FROM" ] || die "set requires --value-from" 2
    cmd_set "$SERVICE" "$ENV_KEY" "$VALUE_FROM"
    ;;
esac
