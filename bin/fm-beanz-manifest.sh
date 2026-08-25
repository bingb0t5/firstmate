#!/usr/bin/env bash
# fm-beanz-manifest.sh - generate ~/.config/beanz/README.md from local metadata.
#
# Builds a human-readable credential index listing each service, its credential
# file, each key's purpose, and where to obtain it. The generator never reads
# secret values: only file names, key names, and documentation sidecars.
#
# Sidecar format (<file>.env.beanz), optional per credential file:
#   service=Short service name
#   obtain=Where to create or find these credentials
#   <KEY>=Purpose of this key (one line per key)
#
# Built-in metadata covers known beanz files when no sidecar exists.
#
# Usage:
#   fm-beanz-manifest.sh write [--output PATH]
#
# Default output: <beanz config dir>/README.md
#
# Environment:
#   FM_BEANZ_CONFIG_DIR   beanz config directory (default ~/.config/beanz)
set -u

SELF_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-credential-lib.sh disable=SC1091
. "$SELF_DIR/fm-credential-lib.sh"

usage() {
  cat <<'EOF'
fm-beanz-manifest.sh - generate a beanz credential index README.

Usage:
  fm-beanz-manifest.sh write [--output PATH]

Reads credential file names and key names from FM_BEANZ_CONFIG_DIR (default
~/.config/beanz). Optional <file>.env.beanz sidecars supply service name,
obtain instructions, and per-key purpose lines. Never embeds secret values.

Environment:
  FM_BEANZ_CONFIG_DIR   override beanz config directory
EOF
}

die() {
  printf 'fm-beanz-manifest: %s\n' "$1" >&2
  exit "${2:-1}"
}

builtin_service() {
  case "$1" in
    coolify.env) printf '%s' 'Coolify deployment control' ;;
    mcp.env) printf '%s' 'MrBeanz brain MCP access' ;;
    n8n.env) printf '%s' 'n8n automation API' ;;
    posthog.env) printf '%s' 'PostHog product analytics' ;;
    telegram.env) printf '%s' 'Telegram bot notifications' ;;
    todoist.env) printf '%s' 'Todoist task API' ;;
    brain.env) printf '%s' 'MrBeanz brain static tokens (BRAIN_TOKENS registry)' ;;
    coolify-services.env) printf '%s' 'Coolify application UUID registry (not secret)' ;;
    *) printf '%s' 'Local credential file' ;;
  esac
}

builtin_obtain() {
  case "$1" in
    coolify.env) printf '%s' 'Coolify UI → Keys → API tokens' ;;
    mcp.env) printf '%s' 'Brain deployment / operator provisioning' ;;
    n8n.env) printf '%s' 'n8n instance settings → API' ;;
    posthog.env) printf '%s' 'PostHog → Personal API keys' ;;
    telegram.env) printf '%s' 'Telegram @BotFather and your chat id' ;;
    todoist.env) printf '%s' 'Todoist → Settings → Integrations → Developer' ;;
    brain.env) printf '%s' 'Generate token:identity pairs per mrbeanz-brains COOLIFY.md' ;;
    coolify-services.env) printf '%s' 'Coolify UI → application → UUID' ;;
    *) printf '%s' 'See service documentation' ;;
  esac
}

builtin_key_purpose() {
  local file=$1 key=$2
  case "$file" in
    coolify.env)
      case "$key" in
        COOLIFY_API_TOKEN) printf '%s' 'Bearer token for Coolify API calls' ;;
        COOLIFY_URL) printf '%s' 'Coolify instance base URL (no trailing slash)' ;;
      esac
      ;;
    mcp.env)
      case "$key" in
        BEANZ_MCP_TOKEN) printf '%s' 'Bearer token for brain MCP/REST doors' ;;
      esac
      ;;
    n8n.env)
      case "$key" in
        N8N_API_URL) printf '%s' 'n8n base URL' ;;
        N8N_API_KEY) printf '%s' 'n8n API key' ;;
      esac
      ;;
    posthog.env)
      case "$key" in
        POSTHOG_API_KEY) printf '%s' 'PostHog Personal API key' ;;
        POSTHOG_HOST) printf '%s' 'PostHog host (cloud or self-hosted)' ;;
      esac
      ;;
    telegram.env)
      case "$key" in
        TELEGRAM_BOT_TOKEN) printf '%s' 'Telegram bot token from BotFather' ;;
        TELEGRAM_CAPTAIN_CHAT_ID) printf '%s' 'Chat id for captain notifications' ;;
      esac
      ;;
    todoist.env)
      case "$key" in
        TODOIST_API_TOKEN) printf '%s' 'Todoist REST API token' ;;
      esac
      ;;
    brain.env)
      case "$key" in
        BRAIN_TOKENS) printf '%s' 'Comma-separated token:identity pairs for static brain doors' ;;
      esac
      ;;
    coolify-services.env)
      case "$key" in
        COOLIFY_SERVICE_*) printf '%s' 'Coolify application UUID for the named service' ;;
      esac
      ;;
  esac
}

sidecar_get() {
  local sidecar=$1 field=$2 line value count=0 found=
  [ -f "$sidecar" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      "$field"=*)
        value=${line#"$field="}
        count=$((count + 1))
        found=$value
        ;;
      *=*|*:*)
        continue
        ;;
    esac
  done < "$sidecar"
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$found"
}

sidecar_key_purpose() {
  local sidecar=$1 key=$2 line value count=0 found=
  [ -f "$sidecar" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
      service=*|obtain=*) continue ;;
      "$key"=*)
        value=${line#"$key="}
        count=$((count + 1))
        found=$value
        ;;
    esac
  done < "$sidecar"
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$found"
}

list_env_keys() {
  local file=$1 line key
  [ -f "$file" ] || return 0
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    key=$(fm_credential_assignment_key "$line") || return 1
    printf '%s\n' "$key"
  done < "$file"
}

cmd_write() {
  local output=$1 config_dir env_file base sidecar service obtain key keys purpose
  config_dir=$(fm_credential_config_dir) || die "config directory is not available" 1
  [ -d "$config_dir" ] || die "config directory does not exist" 1
  output=${output:-"$config_dir/README.md"}
  : > "$output" 2>/dev/null || die "cannot write the output path" 1

  {
    printf '# Beanz credential index\n\n'
    printf 'Generated by bin/fm-beanz-manifest.sh. Lists credential files under %s.\n\n' "$config_dir"
    printf 'Secrets stay in their separate files; this index lists names and purposes only.\n\n'
  } > "$output"

  for env_file in "$config_dir"/*.env; do
    [ -e "$env_file" ] || continue
    base=$(basename "$env_file")
    sidecar="$config_dir/$base.beanz"
    service=$(sidecar_get "$sidecar" service 2>/dev/null) || service=$(builtin_service "$base")
    obtain=$(sidecar_get "$sidecar" obtain 2>/dev/null) || obtain=$(builtin_obtain "$base")
    {
      printf '## %s\n\n' "$service"
      printf '| Field | Value |\n'
      printf '| --- | --- |\n'
      printf '| File | %s |\n' "\`$env_file\`"
      printf '| Obtain | %s |\n\n' "$obtain"
    } >> "$output"
    if ! keys=$(list_env_keys "$env_file"); then
      printf 'This file is not a plain list of KEY=value lines, so no keys are listed for it.\n\n' >> "$output"
      continue
    fi
    {
      printf '| Key | Purpose |\n'
      printf '| --- | --- |\n'
    } >> "$output"
    while IFS= read -r key; do
      [ -n "$key" ] || continue
      purpose=$(sidecar_key_purpose "$sidecar" "$key" 2>/dev/null) \
        || purpose=$(builtin_key_purpose "$base" "$key")
      [ -n "$purpose" ] || purpose='(document purpose in a .env.beanz sidecar)'
      printf '| %s | %s |\n' "\`$key\`" "$purpose" >> "$output"
    done <<< "$keys"
    printf '\n' >> "$output"
  done
}

OUTPUT=
SUBCMD=

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    write)
      SUBCMD='write'
      shift
      ;;
    --output)
      [ $# -ge 2 ] || die "--output requires a path" 2
      OUTPUT=$2
      shift 2
      ;;
    *)
      die "unknown argument: $1" 2
      ;;
  esac
done

[ -n "$SUBCMD" ] || die "a command is required (try --help)" 2

case "$SUBCMD" in
  write) cmd_write "$OUTPUT" ;;
esac
