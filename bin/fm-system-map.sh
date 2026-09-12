#!/usr/bin/env bash
# fm-system-map.sh - build a redacted system map and fail the daily score when
# declared automation, registry, repository, host, or live n8n reality drifts.
#
# Usage:
#   fm-system-map.sh [check|score]
#   fm-system-map.sh arm
#   fm-system-map.sh disarm
#   fm-system-map.sh --help
#
# `check` and `score` read the operator's local source files, the existing
# automation registry, Engineering Radar's latest weekly report, and the X-05
# n8n comparison. They never schedule or execute an automation.
# `score` always prints a result and exits nonzero when a finding exists.
# `check` deduplicates the notification line used by the normal watcher.
#
# Local source paths are configured with:
#   FM_SYSTEM_MAP_MANIFEST_FILE       default $FM_HOME/config/system-map-manifests.json
#   FM_SYSTEM_MAP_HOST_INVENTORY_FILE default $FM_HOME/config/host-inventory.json
#   FM_SYSTEM_MAP_REPO                default $FM_HOME/projects/mrbeanz-brains
#   FM_ENGINEERING_RADAR_ROOT         default /home/rich/dev/engineering-radar
#   FM_SYSTEM_MAP_N8N_COMPARISON_FILE optional precomputed X-05 JSON
#
# When a comparison fixture is not supplied, the script invokes
# $FM_SYSTEM_MAP_REPO/scripts/n8n-ops.ts through `npx tsx compare`. X-05 reads
# /home/rich/.config/beanz/n8n.env itself; this script never reads or prints it.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=system-map
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.$CHECK_ID"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-system-map-v1

# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-system-map.sh [check]   build the redacted system map
  fm-system-map.sh score     print the daily score and fail on drift
  fm-system-map.sh arm       register the daily map check with the watcher
  fm-system-map.sh disarm    remove the map check and its private record
  fm-system-map.sh --help    print this help

Optional check and score flags:
  --output-json <path>       write the complete JSON map
  --output-markdown <path>   write the human-readable map
  --manifests <path>         declared manifest JSON
  --hosts <path>             host inventory JSON
  --repo <path>              repository containing n8n/*.json exports
  --radar-root <path>        Engineering Radar repository
  --registry-file <path>     registry JSON fixture instead of HTTP
  --n8n-comparison <path>    X-05 comparison JSON fixture instead of running X-05

The daily check uses the existing watcher rather than creating a scheduler.
Registry credentials are resolved from the existing automation registry
environment settings and are never included in the report.
EOF
}

die_usage() {
  printf 'fm-system-map: %s\n' "$1" >&2
  usage >&2
  exit 2
}

ACTION=${1:-check}
case "$ACTION" in
  check|score|arm|disarm) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *) die_usage "unknown action: $ACTION" ;;
esac
shift || true

OUTPUT_JSON=
OUTPUT_MARKDOWN=
MANIFEST_FILE="${FM_SYSTEM_MAP_MANIFEST_FILE:-$FM_HOME/config/system-map-manifests.json}"
HOST_FILE="${FM_SYSTEM_MAP_HOST_INVENTORY_FILE:-$FM_HOME/config/host-inventory.json}"
SYSTEM_REPO="${FM_SYSTEM_MAP_REPO:-$FM_HOME/projects/mrbeanz-brains}"
RADAR_ROOT="${FM_ENGINEERING_RADAR_ROOT:-/home/rich/dev/engineering-radar}"
REGISTRY_FILE=
N8N_COMPARISON_FILE="${FM_SYSTEM_MAP_N8N_COMPARISON_FILE:-}"

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output-json|--output-markdown|--manifests|--hosts|--repo|--radar-root|--registry-file|--n8n-comparison)
      [ "$#" -ge 2 ] || die_usage "$1 requires a path"
      case "$1" in
        --output-json) OUTPUT_JSON=$2 ;;
        --output-markdown) OUTPUT_MARKDOWN=$2 ;;
        --manifests) MANIFEST_FILE=$2 ;;
        --hosts) HOST_FILE=$2 ;;
        --repo) SYSTEM_REPO=$2 ;;
        --radar-root) RADAR_ROOT=$2 ;;
        --registry-file) REGISTRY_FILE=$2 ;;
        --n8n-comparison) N8N_COMPARISON_FILE=$2 ;;
      esac
      shift 2
      ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

if ! command -v jq >/dev/null 2>&1; then
  printf 'fm-system-map: jq is required\n' >&2
  exit 2
fi

INTERVAL=${FM_SYSTEM_MAP_INTERVAL:-86400}
case "$INTERVAL" in
  ''|*[!0-9]*) die_usage "FM_SYSTEM_MAP_INTERVAL must be a whole number" ;;
esac

TMP_ROOT=
cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-system-map.XXXXXX") || exit 1
chmod 0700 "$TMP_ROOT"
MANIFEST_ROWS="$TMP_ROOT/manifests.json"
REGISTRY_ROWS="$TMP_ROOT/registry.json"
HOST_ROWS="$TMP_ROOT/hosts.json"
N8N_RESULT="$TMP_ROOT/n8n.json"
RADAR_JSON="$TMP_ROOT/radar.json"
FINDINGS_FILE="$TMP_ROOT/findings.json"
printf '[]\n' > "$FINDINGS_FILE"

add_finding() {
  local id=$1 source=$2 message=$3
  jq -c --arg id "$id" --arg source "$source" --arg message "$message" \
    '. + [{id:$id,source:$source,severity:"error",message:$message}]' \
    "$FINDINGS_FILE" > "$FINDINGS_FILE.next" &&
    mv -f -- "$FINDINGS_FILE.next" "$FINDINGS_FILE"
}

normalize_manifests() {
  if [ ! -f "$MANIFEST_FILE" ] || [ -L "$MANIFEST_FILE" ]; then
    printf '[]\n' > "$MANIFEST_ROWS"
    add_finding manifests.unavailable manifests "declared manifest file is unavailable"
    return
  fi
  if ! jq -e '
      def rows:
        if type == "array" then .
        elif (.manifests | type) == "array" then .manifests
        else error("expected an array or manifests array")
        end;
      rows | map({
        id:(.manifest_id // .id // ""),
        version:(.manifest_version // .version // ""),
        owner:(.owner // ""),
        cadence:(.cadence // ""),
        host_id:(.host_id // .host // null)
      })
    ' "$MANIFEST_FILE" > "$MANIFEST_ROWS" 2>/dev/null; then
    printf '[]\n' > "$MANIFEST_ROWS"
    add_finding manifests.invalid manifests "declared manifest JSON has an invalid shape"
  fi
}

normalize_hosts() {
  if [ ! -f "$HOST_FILE" ] || [ -L "$HOST_FILE" ]; then
    printf '[]\n' > "$HOST_ROWS"
    add_finding hosts.unavailable hosts "host inventory file is unavailable"
    return
  fi
  if ! jq -e '
      def rows:
        if type == "array" then .
        elif (.hosts | type) == "array" then .hosts
        elif (.inventory | type) == "array" then .inventory
        else error("expected an array, hosts array, or inventory array")
        end;
      rows | map({
        id:(.host_id // .id // .name // ""),
        status:(.status // .health // ""),
        reachable:(if .reachable == false then false else true end)
      })
    ' "$HOST_FILE" > "$HOST_ROWS" 2>/dev/null; then
    printf '[]\n' > "$HOST_ROWS"
    add_finding hosts.invalid hosts "host inventory JSON has an invalid shape"
  fi
}

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
load_registry_settings() {
  local file
  file=$(registry_env_file)
  REGISTRY_URL=$(setting FM_AUTOMATION_REGISTRY_URL FM_AUTOMATION_REGISTRY_URL "$file")
  [ -n "$REGISTRY_URL" ] || REGISTRY_URL=$(setting BRAIN_URL BRAIN_URL "$file")
  REGISTRY_TOKEN=$(setting FM_AUTOMATION_REGISTRY_TOKEN FM_AUTOMATION_REGISTRY_TOKEN "$file")
  [ -n "$REGISTRY_TOKEN" ] || REGISTRY_TOKEN=$(setting BRAIN_TOKEN BRAIN_TOKEN "$file")
  case "$REGISTRY_URL" in *$'\n'*|*$'\r'*) REGISTRY_URL= ;; esac
  case "$REGISTRY_TOKEN" in *$'\n'*|*$'\r'*) REGISTRY_TOKEN= ;; esac
}

registry_endpoint() {
  local url=${REGISTRY_URL%/}
  case "$url" in
    */v1/automations) printf '%s\n' "$url" ;;
    *) printf '%s/v1/automations\n' "$url" ;;
  esac
}

load_registry() {
  if [ -n "$REGISTRY_FILE" ]; then
    if [ -f "$REGISTRY_FILE" ] && [ ! -L "$REGISTRY_FILE" ] &&
      jq -e . "$REGISTRY_FILE" > "$TMP_ROOT/registry-body.json" 2>/dev/null; then
      :
    else
      printf '[]\n' > "$REGISTRY_ROWS"
      add_finding registry.invalid registry "registry fixture is unavailable or invalid"
      return
    fi
  else
    load_registry_settings
    if [ -z "$REGISTRY_URL" ] || ! command -v curl >/dev/null 2>&1; then
      printf '[]\n' > "$REGISTRY_ROWS"
      add_finding registry.unavailable registry "automation registry settings are unavailable"
      return
    fi
    local body="$TMP_ROOT/registry-body.json" code
    if [ -n "$REGISTRY_TOKEN" ]; then
      code=$(curl -sS --max-time "${FM_CHECK_TIMEOUT:-30}" \
        -H "Authorization: Bearer $REGISTRY_TOKEN" \
        -o "$body" -w '%{http_code}' "$(registry_endpoint)" 2>/dev/null) || code=
    else
      code=$(curl -sS --max-time "${FM_CHECK_TIMEOUT:-30}" \
        -o "$body" -w '%{http_code}' "$(registry_endpoint)" 2>/dev/null) || code=
    fi
    case "$code" in
      2[0-9][0-9]) ;;
      *)
        printf '[]\n' > "$REGISTRY_ROWS"
        add_finding registry.unavailable registry "automation registry request was unavailable"
        return
        ;;
    esac
    jq -e . "$body" >/dev/null 2>&1 || {
      printf '[]\n' > "$REGISTRY_ROWS"
      add_finding registry.invalid registry "automation registry response was not valid JSON"
      return
    }
  fi
  if ! jq -e '
      def rows:
        if type == "array" then .
        elif (.automations | type) == "array" then .automations
        elif (.data | type) == "array" then .data
        else error("expected an array, automations array, or data array")
        end;
      rows | map({
        id:(.manifest_id // .id // ""),
        version:(.manifest_version // .version // ""),
        owner:(.owner // ""),
        cadence:(.cadence // ""),
        host_id:(.host_id // .host // null),
        health:(.health // (if
          (.last_terminal_receipt.type // "") == "automation.run.receipt.v1" and
          (.last_terminal_receipt.terminal // false) == true and
          ((.last_terminal_receipt.status // "") | IN("success","succeeded")) and
          (.open_alerts | type) == "array" and (.open_alerts | length) == 0
          then "healthy" else "" end)),
        outcome:(.terminal_outcome // .status // .last_terminal_receipt.status // ""),
        last_success_at:(.last_success_at // null)
      })
    ' "$TMP_ROOT/registry-body.json" > "$REGISTRY_ROWS" 2>/dev/null; then
    printf '[]\n' > "$REGISTRY_ROWS"
    add_finding registry.invalid registry "automation registry response has an invalid shape"
  fi
}

load_n8n_comparison() {
  if [ -n "$N8N_COMPARISON_FILE" ]; then
    if [ -f "$N8N_COMPARISON_FILE" ] && [ ! -L "$N8N_COMPARISON_FILE" ] &&
      jq -e . "$N8N_COMPARISON_FILE" > "$N8N_RESULT" 2>/dev/null; then
      :
    else
      printf '{}\n' > "$N8N_RESULT"
      add_finding n8n.invalid n8n "X-05 n8n comparison fixture is unavailable or invalid"
    fi
  else
    local script="$SYSTEM_REPO/scripts/n8n-ops.ts"
    if [ ! -f "$script" ] || [ -L "$script" ] || ! command -v npx >/dev/null 2>&1; then
      printf '{}\n' > "$N8N_RESULT"
      add_finding n8n.unavailable n8n "X-05 n8n operations script is unavailable"
      return
    fi
    if ! npx --yes tsx "$script" compare --repo "$SYSTEM_REPO" \
      --output-json "$N8N_RESULT" >/dev/null 2>"$TMP_ROOT/n8n-error"; then
      printf '{}\n' > "$N8N_RESULT"
      add_finding n8n.unavailable n8n "X-05 live n8n comparison was unavailable"
    fi
  fi
  if ! jq -e 'type == "object" and (.schema // "") == "n8n.workflow.comparison.v1"' \
    "$N8N_RESULT" >/dev/null 2>&1; then
    add_finding n8n.invalid n8n "X-05 n8n comparison did not return its supported schema"
  fi
}

radar_report=
radar_date=
find_latest_radar_report() {
  local candidate
  for candidate in "$RADAR_ROOT"/reports/weekly-*.md; do
    [ -f "$candidate" ] || continue
    case "$candidate" in
      *weekly-[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9].md)
        if [ -z "$radar_report" ] || [ "$candidate" -nt "$radar_report" ]; then
          radar_report=$candidate
          radar_date=${candidate##*/weekly-}
          radar_date=${radar_date%.md}
        fi
        ;;
    esac
  done
}

load_radar() {
  find_latest_radar_report
  if [ -z "$radar_report" ]; then
    jq -n --arg root "$RADAR_ROOT" \
      '{source:"engineering-radar",root:$root,status:"unavailable",report:null,report_date:null,items:[]}' \
      > "$RADAR_JSON"
    add_finding radar.unavailable radar "Engineering Radar has no weekly report"
    return
  fi
  local report_epoch now_epoch age excerpt items digest
  report_epoch=$(date -d "$radar_date" +%s 2>/dev/null || printf '0')
  case "${FM_SYSTEM_MAP_NOW:-}" in
    ''|*[!0-9]*) now_epoch=$(date +%s) ;;
    *) now_epoch=$FM_SYSTEM_MAP_NOW ;;
  esac
  age=$((now_epoch - report_epoch))
  if [ "$report_epoch" -le 0 ] || [ "$age" -lt 0 ] || [ "$age" -gt 691200 ]; then
    add_finding radar.stale radar "Engineering Radar weekly report is older than the changed-this-week window"
  fi
  excerpt=$(awk 'NR <= 80 { print }' "$radar_report")
  items=$(awk '/^### / { sub(/^### /, ""); print }' "$radar_report" | jq -Rsc 'split("\n") | map(select(length > 0))')
  digest=$(sha256sum "$radar_report" 2>/dev/null | awk '{print $1}')
  jq -n --arg root "$RADAR_ROOT" --arg report "$radar_report" --arg date "$radar_date" \
    --arg digest "$digest" --arg excerpt "$excerpt" --argjson items "$items" \
    '{source:"engineering-radar",root:$root,status:"available",report:$report,report_date:$date,
      report_sha256:$digest,items:$items,excerpt:$excerpt}' > "$RADAR_JSON"
}

repo_export_count=0

validate_manifest_rows() {
  local id version owner
  while IFS=$'\t' read -r id version owner; do
    [ -n "$id" ] || add_finding manifests.missing-id manifests "declared manifest has no identity"
    [ -n "$version" ] || add_finding "manifests.version.$id" manifests "declared manifest $id has no version"
    [ -n "$owner" ] || add_finding "manifests.owner.$id" manifests "declared manifest $id has no owner"
  done < <(jq -r '.[] | [.id,.version,.owner] | @tsv' "$MANIFEST_ROWS")
}

compare_registry() {
  local id version owner cadence host health outcome
  while IFS=$'\t' read -r id version owner cadence host health outcome; do
    [ -n "$id" ] || {
      add_finding registry.missing-id registry "registry outcome has no manifest identity"
      continue
    }
    if ! jq -e --arg id "$id" '.[] | select(.id == $id)' "$MANIFEST_ROWS" >/dev/null; then
      add_finding "registry.extra.$id" registry "registry outcome $id is not declared"
      continue
    fi
    local expected
    expected=$(jq -r --arg id "$id" '.[] | select(.id == $id) | [.version,.owner,.cadence,.host_id // ""] | @tsv' "$MANIFEST_ROWS" | head -n 1)
    local ev eo ec eh
    IFS=$'\t' read -r ev eo ec eh <<< "$expected"
    [ "$version" = "$ev" ] || add_finding "registry.version.$id" registry "registry version for $id disagrees with its declaration"
    [ "$owner" = "$eo" ] || add_finding "registry.owner.$id" registry "registry owner for $id disagrees with its declaration"
    [ "$cadence" = "$ec" ] || add_finding "registry.cadence.$id" registry "registry cadence for $id disagrees with its declaration"
    if [ -n "$eh" ] && [ "$host" != "$eh" ]; then
      add_finding "registry.host.$id" registry "registry host for $id disagrees with its declaration"
    fi
    [ "$health" = healthy ] || add_finding "registry.health.$id" registry "registry outcome $id is not healthy"
    case "$outcome" in
      success|succeeded) ;;
      *) add_finding "registry.outcome.$id" registry "registry outcome $id is not successful" ;;
    esac
  done < <(jq -r '.[] | [.id,.version,.owner,.cadence,(.host_id // ""),.health,.outcome] | @tsv' "$REGISTRY_ROWS")
  while IFS= read -r id; do
    [ -n "$id" ] || continue
    if ! jq -e --arg id "$id" '.[] | select(.id == $id)' "$REGISTRY_ROWS" >/dev/null; then
      add_finding "registry.missing.$id" registry "declared manifest $id has no registry outcome"
    fi
  done < <(jq -r '.[].id' "$MANIFEST_ROWS")
}

compare_hosts() {
  local id status reachable
  while IFS=$'\t' read -r id status reachable; do
    [ -n "$id" ] || add_finding hosts.missing-id hosts "host inventory has an unnamed host"
    case "$status" in
      healthy|online|up|ready|active) ;;
      *) add_finding "hosts.status.$id" hosts "host $id is not healthy" ;;
    esac
    [ "$reachable" = true ] || add_finding "hosts.reachable.$id" hosts "host $id is not reachable"
  done < <(jq -r '.[] | [.id,.status,.reachable] | @tsv' "$HOST_ROWS")
  while IFS=$'\t' read -r id host; do
    [ -n "$host" ] || continue
    if ! jq -e --arg host "$host" '.[] | select(.id == $host)' "$HOST_ROWS" >/dev/null; then
      add_finding "hosts.missing.$id" hosts "declared manifest $id names an absent host $host"
    fi
  done < <(jq -r '.[] | [.id,(.host_id // "")] | @tsv' "$MANIFEST_ROWS")
}

compare_exports_and_live() {
  local export_file
  if [ -d "$SYSTEM_REPO/n8n" ]; then
    for export_file in "$SYSTEM_REPO"/n8n/*.json; do
      [ -f "$export_file" ] || continue
      repo_export_count=$((repo_export_count + 1))
    done
  fi
  [ "$repo_export_count" -gt 0 ] ||
    add_finding exports.unavailable exports "repository has no n8n workflow exports"
  local count committed live
  committed=$(jq -r '.committed_count // -1' "$N8N_RESULT")
  live=$(jq -r '.live_count // -1' "$N8N_RESULT")
  [ "$committed" = "$repo_export_count" ] ||
    add_finding exports.count exports "X-05 committed workflow count disagrees with repository exports"
  count=$(jq -r '.drifted | length' "$N8N_RESULT" 2>/dev/null || printf '%s' -1)
  [ "$count" = 0 ] || add_finding exports.drift exports "X-05 found drifted n8n workflow exports"
  count=$(jq -r '.missing_live | length' "$N8N_RESULT" 2>/dev/null || printf '%s' -1)
  [ "$count" = 0 ] || add_finding live-n8n.missing live-n8n "X-05 found repository workflows missing from live n8n"
  count=$(jq -r '.extra_live | length' "$N8N_RESULT" 2>/dev/null || printf '%s' -1)
  [ "$count" = 0 ] || add_finding live-n8n.extra live-n8n "X-05 found live n8n workflows without repository exports"
  [ "$live" -ge 0 ] 2>/dev/null ||
    add_finding live-n8n.unavailable live-n8n "live n8n workflow inventory is unavailable"
}

write_atomic() {
  local destination=$1 source=$2 directory temporary
  [ -n "$destination" ] || return 0
  directory=$(dirname "$destination")
  mkdir -p "$directory" || return 1
  temporary=$(umask 077; mktemp "$directory/.fm-system-map.XXXXXX") || return 1
  if ! cat "$source" > "$temporary" || ! chmod 0600 "$temporary" ||
    ! mv -f -- "$temporary" "$destination"; then
    rm -f -- "$temporary"
    return 1
  fi
}

write_markdown() {
  local destination=$1 json=$2 status finding_count radar_status
  mkdir -p "$(dirname "$destination")" || return 1
  status=$(jq -r '.score.status' "$json")
  finding_count=$(jq '.findings | length' "$json")
  radar_status=$(jq -r '.changed_this_week.status' "$json")
  {
    printf '# Firstmate system map\n\n'
    printf 'Generated: %s\n\n' "$(jq -r '.generated_at' "$json")"
    printf '## Daily score\n\n%s (%s findings)\n\n' "$status" "$finding_count"
    printf '## Drift report\n\n'
    jq -r '.findings[] | "- [" + .source + "] " + .message' "$json"
    [ "$finding_count" -gt 0 ] || printf '%s\n' '- No drift findings.'
    printf '\n## Changed this week\n\n'
    printf 'Source: Engineering Radar (%s).\n\n' "$radar_status"
    jq -r '.changed_this_week | if .status == "available" then
      "Report: `" + .report + "` (" + .report_date + ").\n\n" +
      (if (.items | length) == 0 then "No material changes were listed." else
        (.items | map("- " + .) | join("\n")) end)
      else "No current weekly report was available." end' "$json"
    printf '\n## Sources\n\n'
    jq -r '.sources | to_entries[] | "- " + .key + ": " + (.value.status // "unknown")' "$json"
  } > "$destination"
}

record_read() {
  RECORD_EPOCH=0
  RECORD_DIGEST=
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 0
  [ "$(sed -n '1p' "$RECORD" 2>/dev/null)" = "$RECORD_SCHEMA" ] || return 0
  RECORD_EPOCH=$(sed -n '2p' "$RECORD" 2>/dev/null)
  RECORD_DIGEST=$(sed -n '3p' "$RECORD" 2>/dev/null)
  case "$RECORD_EPOCH" in ''|*[!0-9]*) RECORD_EPOCH=0 ;; esac
}

record_write() {
  local digest=$1 now temporary
  [ -d "$STATE" ] || return 1
  temporary=$(umask 077; mktemp "$STATE/.$CHECK_ID.XXXXXX") || return 1
  now=$(date +%s)
  if ! printf '%s\n%s\n%s\n' "$RECORD_SCHEMA" "$now" "$digest" > "$temporary" ||
    ! chmod 0600 "$temporary" || ! mv -f -- "$temporary" "$RECORD"; then
    rm -f -- "$temporary"
    return 1
  fi
}

build_report() {
  normalize_manifests
  normalize_hosts
  load_registry
  load_n8n_comparison
  load_radar
  validate_manifest_rows
  compare_registry
  compare_hosts
  compare_exports_and_live

  local generated findings_count status digest
  generated=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  findings_count=$(jq 'length' "$FINDINGS_FILE")
  if [ "$findings_count" -eq 0 ]; then status=pass; else status=fail; fi
  jq -n \
    --arg generated "$generated" \
    --arg status "$status" \
    --argjson findings "$(cat "$FINDINGS_FILE")" \
    --argjson manifests "$(cat "$MANIFEST_ROWS")" \
    --argjson registry "$(cat "$REGISTRY_ROWS")" \
    --argjson hosts "$(cat "$HOST_ROWS")" \
    --slurpfile radar "$RADAR_JSON" \
    --arg repo "$SYSTEM_REPO" \
    --arg manifest_file "$MANIFEST_FILE" \
    --arg host_file "$HOST_FILE" \
    --arg radar_root "$RADAR_ROOT" \
    --argjson n8n "$(cat "$N8N_RESULT")" \
    --argjson export_count "$repo_export_count" \
    '{
      schema:"firstmate.system-map.v1",
      generated_at:$generated,
      score:{status:$status,failed:($status == "fail")},
      sources:{
        declared_manifests:{status:(if ($manifests|length)>0 then "available" else "empty" end),path:$manifest_file,count:($manifests|length)},
        registry_outcomes:{status:(if ($registry|length)>0 then "available" else "empty" end),count:($registry|length)},
        repo_exports:{status:(if $export_count>0 then "available" else "empty" end),path:$repo,count:$export_count},
        host_inventory:{status:(if ($hosts|length)>0 then "available" else "empty" end),path:$host_file,count:($hosts|length)},
        live_n8n_workflows:{status:(if (($n8n.live_count // -1) >= 0) then "available" else "unavailable" end),count:($n8n.live_count // null)}
      },
      declared_manifests:$manifests,
      registry_outcomes:$registry,
      host_inventory:$hosts,
      repo_exports:{path:$repo,count:$export_count,committed_count:($n8n.committed_count // null)},
      live_n8n_workflows:$n8n,
      changed_this_week:$radar[0],
      findings:$findings
    }' > "$TMP_ROOT/report.json"
  digest=$(jq -c '{score,findings,changed_this_week:{status,report_sha256}}' "$TMP_ROOT/report.json" | sha256sum | awk '{print $1}')
  printf '%s\n' "$digest"
}

action_check() {
  local digest status finding_count now
  digest=$(build_report)
  status=$(jq -r '.score.status' "$TMP_ROOT/report.json")
  finding_count=$(jq '.findings | length' "$TMP_ROOT/report.json")
  write_atomic "$OUTPUT_JSON" "$TMP_ROOT/report.json" || return 1
  if [ -n "$OUTPUT_MARKDOWN" ]; then
    write_markdown "$OUTPUT_MARKDOWN" "$TMP_ROOT/report.json" || return 1
  fi
  record_read
  now=$(date +%s)
  if [ "$ACTION" = score ] ||
    [ "$INTERVAL" -eq 0 ] ||
    [ "$RECORD_DIGEST" != "$digest" ] ||
    [ "$RECORD_EPOCH" -eq 0 ] ||
    [ "$now" -lt "$RECORD_EPOCH" ] ||
    [ $((now - RECORD_EPOCH)) -ge "$INTERVAL" ]; then
    printf 'system map: %s (%s findings)\n' "$status" "$finding_count"
  fi
  record_write "$digest" || true
  if [ "$ACTION" = score ]; then
    [ "$status" = pass ]
  else
    return 0
  fi
}

shim_content() {
  local home=$1
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-system-map.sh.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "exec $(printf '%q' "$SCRIPT_DIR/fm-system-map.sh") check"
}

action_arm() {
  local home temporary
  mkdir -p "$STATE" || return 1
  case "$FM_HOME" in
    /*) home=$FM_HOME ;;
    *) home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1 ;;
  esac
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  temporary=$(umask 077; mktemp "$STATE/.$CHECK_ID-check.XXXXXX") || return 1
  if ! shim_content "$home" > "$temporary" || ! chmod 0700 "$temporary"; then
    rm -f -- "$temporary"
    return 1
  fi
  rm -f -- "$CHECK_SHIM" "$CHECK_TRUST"
  mv -f -- "$temporary" "$CHECK_SHIM" || return 1
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

case "$ACTION" in
  check|score) action_check ;;
  arm) action_arm ;;
  disarm) action_disarm ;;
esac
