#!/usr/bin/env bash
# fm-credential-lib.sh - safe credential read, transport, and output redaction.
#
# Sourced, never executed. Owns every path that touches a secret in firstmate's
# credential tools: parse credential files without sourcing them, resolve
# --value-from sources, build HTTP bodies without argv secrets, and filter every
# user-visible byte through registered redaction patterns.
#
#   fm_credential_config_dir
#       Prints the beanz config directory (FM_BEANZ_CONFIG_DIR or
#       $HOME/.config/beanz).
#
#   fm_credential_redact_register <value>
#       Registers a literal substring that must never appear on stdout, stderr,
#       or in fm_credential_safe_* output on any later path in this process.
#       The register is an in-process shell variable: no secret is ever written
#       to disk, so nothing survives the process and nothing needs cleaning up.
#       A registration made inside a command substitution dies with that
#       subshell, so callers must register in the shell that will do the
#       printing.
#
#   fm_credential_safe_print <stream> <text>
#       Writes redacted text to stream 1 (stdout) or 2 (stderr).
#
#   fm_credential_safe_die <message> [exit-code]
#       Redacted stderr message and exit (default 1).
#
#   fm_credential_assignment_key <line>
#       Prints the key of a well-formed <IDENTIFIER>=<value> line and exits 0;
#       exits 1 for anything else. The single owner of "is this line an
#       assignment" for every parser in these tools, so a continuation line or
#       binary noise cannot be mistaken for a key by one reader and rejected by
#       another.
#
#   fm_credential_env_get <file> <KEY>
#       Reads exactly one KEY=value assignment from a credential file using
#       line-at-a-time parsing (never source/dot). Exit 0 and prints the value
#       on success; exit 1 when the key is missing or duplicated; exit 2 when
#       the file contains an ambiguous non-assignment line, or when the
#       assignment itself is ambiguous (quoted value, embedded carriage
#       return). Quoted and CRLF forms are rejected rather than guessed: this
#       library does not implement shell dequoting, so passing them through
#       would silently transmit the wrong credential.
#
#   fm_credential_brain_token_for_identity <BRAIN_TOKENS> <identity>
#       Returns the token for identity from a comma-separated token:identity
#       registry (documented in mrbeanz-brains src/config.ts). Exit 1 when no
#       unique match exists.
#
#   fm_credential_resolve_value_from <source>
#       Resolves --value-from sources:
#         literal:<text>          non-secret literal (may contain colons)
#         env:<file>:<KEY>        KEY from the beanz config dir
#         brain:<identity>        token from BRAIN_TOKENS in brain.env
#       Prints the resolved value on stdout. Redaction is the caller's job:
#       this runs inside a command substitution, so it cannot register anything
#       in the caller's shell. Pair it with fm_credential_source_is_secret.
#       Exit 1 when the value cannot be found, 2 when the source spec itself is
#       malformed, 3 when the credential file was readable but its content is
#       ambiguous (see fm_credential_env_get).
#
#   fm_credential_source_is_secret <source>
#       Exit 0 when a --value-from source yields secret material that must be
#       redacted, exit 1 for literal:<text>, which the contract defines as a
#       non-secret value and which must stay printable.
#
#   fm_credential_json_object <key> <value>
#       Prints a JSON object {"key":...,"value":...} with proper escaping.
#       Values are taken from positional args; callers must not pass secrets on
#       the argv of a child if avoidable - this runs in-process via python3 -c
#       with env vars FM_CREDENTIAL_JSON_KEY and FM_CREDENTIAL_JSON_VALUE.
set -u

if [ -n "${FM_CREDENTIAL_LIB_SOURCED:-}" ]; then
  return 0
fi
FM_CREDENTIAL_LIB_SOURCED=1

FM_CREDENTIAL_REDACT_PATTERNS=

fm_credential_xtrace_off() {
  { set +x; } 2>/dev/null
}

fm_credential_config_dir() {
  if [ -n "${FM_BEANZ_CONFIG_DIR:-}" ]; then
    printf '%s\n' "$FM_BEANZ_CONFIG_DIR"
  else
    printf '%s\n' "${HOME:?}/.config/beanz"
  fi
}

fm_credential_redact_init() {
  FM_CREDENTIAL_REDACT_PATTERNS=
}

fm_credential_redact_register() {
  fm_credential_xtrace_off
  local value=$1
  [ -n "$value" ] || return 0
  FM_CREDENTIAL_REDACT_PATTERNS="${FM_CREDENTIAL_REDACT_PATTERNS:-}$value"$'\n'
}

fm_credential_redact_apply() {
  fm_credential_xtrace_off
  local text=$1
  [ -n "${FM_CREDENTIAL_REDACT_PATTERNS:-}" ] || {
    printf '%s' "$text"
    return 0
  }
  FM_CREDENTIAL_REDACT_INPUT=$text \
    FM_CREDENTIAL_REDACT_LIST=$FM_CREDENTIAL_REDACT_PATTERNS python3 - <<'PY'
import os

text = os.environ.get("FM_CREDENTIAL_REDACT_INPUT", "")
raw = os.environ.get("FM_CREDENTIAL_REDACT_LIST", "")
patterns = [line for line in raw.split("\n") if line]
for pattern in sorted(patterns, key=len, reverse=True):
    text = text.replace(pattern, "[redacted]")
print(text, end="")
PY
}

fm_credential_safe_print() {
  local stream=$1 text=$2 redacted
  redacted=$(fm_credential_redact_apply "$text")
  if [ "$stream" = 2 ]; then
    printf '%s\n' "$redacted" >&2
  else
    printf '%s\n' "$redacted"
  fi
}

fm_credential_safe_die() {
  fm_credential_safe_print 2 "$1"
  exit "${2:-1}"
}

fm_credential_basename_ok() {
  local name=$1
  case "$name" in
    '' | */* | *..*) return 1 ;;
    *.env) return 0 ;;
    *) return 1 ;;
  esac
}

fm_credential_assignment_key() {
  local line=$1 key=${1%%=*} service
  [ "$key" != "$line" ] || return 1
  case "$key" in
    COOLIFY_SERVICE_*)
      service=${key#COOLIFY_SERVICE_}
      case "$service" in
        '' | *[!A-Za-z0-9_]*) return 1 ;;
      esac
      ;;
    [A-Z]* )
      case "$key" in
        *[!A-Z0-9_]*) return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
  printf '%s' "$key"
}

fm_credential_env_get() {
  fm_credential_xtrace_off
  local file=$1 key=$2 line line_key count=0 value=
  [ -f "$file" ] && [ -r "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      ''|'#'*) continue ;;
    esac
    line_key=$(fm_credential_assignment_key "$line") || return 2
    [ "$line_key" = "$key" ] || continue
    value=${line#"$key="}
    case "$value" in
      '"'* | "'"* | *$'\r'*) return 2 ;;
    esac
    count=$((count + 1))
  done < "$file"
  [ "$count" -eq 1 ] || return 1
  printf '%s' "$value"
}

fm_credential_brain_token_for_identity() {
  fm_credential_xtrace_off
  local raw=$1 identity=$2 entry pair token id matches=0 found=
  [ -n "$identity" ] || return 1
  raw=${raw//[$'\t\r\n']/}
  while [ -n "$raw" ]; do
    entry=${raw%%,*}
    raw=${raw#"$entry"}
    raw=${raw#,}
    pair=${entry#"${entry%%[![:space:]]*}"}
    pair=${pair%"${pair##*[![:space:]]}"}
    [ -n "$pair" ] || continue
    case "$pair" in
      *:*)
        token=${pair%%:*}
        id=${pair#*:}
        id=${id#"${id%%[![:space:]]*}"}
        id=${id%"${id##*[![:space:]]}"}
        token=${token%"${token##*[![:space:]]}"}
        token=${token#"${token%%[![:space:]]*}"}
        ;;
      *) return 2 ;;
    esac
    [ -n "$token" ] && [ -n "$id" ] || return 2
    if [ "$id" = "$identity" ]; then
      matches=$((matches + 1))
      found=$token
    fi
  done
  [ "$matches" -eq 1 ] || return 1
  printf '%s' "$found"
}

fm_credential_read_rc() {
  case "$1" in
    2) return 3 ;;
    *) return 1 ;;
  esac
}

fm_credential_resolve_value_from() {
  fm_credential_xtrace_off
  local source=$1 config_dir file_path key raw token
  config_dir=$(fm_credential_config_dir) || return 1
  case "$source" in
    literal:*)
      raw=${source#literal:}
      [ -n "$raw" ] || return 2
      printf '%s' "$raw"
      return 0
      ;;
    env:*)
      file_path=${source#env:}
      key=${file_path##*:}
      file_path=${file_path%:"$key"}
      fm_credential_basename_ok "$file_path" || return 2
      [ -n "$key" ] || return 2
      file_path="$config_dir/$file_path"
      raw=$(fm_credential_env_get "$file_path" "$key") || {
        fm_credential_read_rc "$?"
        return
      }
      printf '%s' "$raw"
      return 0
      ;;
    brain:*)
      key=${source#brain:}
      [ -n "$key" ] || return 2
      file_path="$config_dir/brain.env"
      raw=$(fm_credential_env_get "$file_path" BRAIN_TOKENS) || {
        fm_credential_read_rc "$?"
        return
      }
      token=$(fm_credential_brain_token_for_identity "$raw" "$key") || return 1
      printf '%s' "$token"
      return 0
      ;;
    *)
      return 2
      ;;
  esac
}

fm_credential_source_is_secret() {
  case "$1" in
    literal:*) return 1 ;;
    *) return 0 ;;
  esac
}

fm_credential_json_object() {
  fm_credential_xtrace_off
  local obj_key=$1 obj_value=$2
  FM_CREDENTIAL_JSON_KEY=$obj_key FM_CREDENTIAL_JSON_VALUE=$obj_value python3 - <<'PY'
import json, os, sys

key = os.environ.get("FM_CREDENTIAL_JSON_KEY", "")
value = os.environ.get("FM_CREDENTIAL_JSON_VALUE", "")
sys.stdout.write(json.dumps({"key": key, "value": value}))
PY
}
