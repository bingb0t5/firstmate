#!/usr/bin/env bash
# fm-release-receipt-check.sh - observe a release and record its deployment and
# migration receipt without starting, restarting, or reconfiguring production.
#
# Usage:
#   fm-release-receipt-check.sh [check] [--spec PATH]
#   fm-release-receipt-check.sh run [--spec PATH] [--timeout SECONDS]
#   fm-release-receipt-check.sh audit [--spec PATH]
#   fm-release-receipt-check.sh arm [--spec PATH]
#   fm-release-receipt-check.sh disarm
#   fm-release-receipt-check.sh --help
#
# The release manifest is JSON. It names an intended commit, one or more
# Coolify or Render targets, and migration names expected in the existing App
# DB ledger. `check` performs one bounded read-only observation and stores a
# redacted receipt in state/.release-receipt. `run` repeats that observation
# until the deployments and migration receipt are verified or the timeout
# expires. `arm` installs the check in the existing watcher.
#
# Provider credential stores:
#   ~/.config/beanz/coolify.env       COOLIFY_URL, COOLIFY_API_TOKEN
#   ~/.config/lalo/render-api.env     RENDER_API_URL, RENDER_API_KEY
# App DB credentials are read from the existing operator environment or the
# existing FM_RELEASE_APP_DB_ENV_FILE; this script never creates a credential
# store. Supported names are SUPABASE_SERVICE_ROLE_KEY, SUPABASE_ACCESS_TOKEN,
# APP_DB_SERVICE_ROLE_KEY, APP_DB_TOKEN, and SUPABASE_KEY.
#
# A target may supply status_url and build_id_url in the manifest. If omitted,
# Coolify uses /api/v1/applications/<app_id> and Render uses
# /v1/services/<service_id>/deploys/<deploy_id>. No deploy or start endpoint is
# ever read or written.
set -u
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CHECK_ID=release-receipt
CHECK_SHIM="$STATE/$CHECK_ID.check.sh"
CHECK_TRUST="$STATE/$CHECK_ID.check-trust"
RECORD="$STATE/.$CHECK_ID"
REGISTER_BIN="$SCRIPT_DIR/fm-check-register.sh"
RECORD_SCHEMA=fm-release-receipt-v1
DEFAULT_PROJECT_REF=evvrlbeilubeggmrhjgs

# shellcheck source=bin/fm-x-lib.sh
. "$SCRIPT_DIR/fm-x-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-check-lib.sh
. "$SCRIPT_DIR/fm-check-lib.sh"

usage() {
  cat <<'EOF'
Usage:
  fm-release-receipt-check.sh [check] [--spec PATH]
                                      observe once and deduplicate an alert
  fm-release-receipt-check.sh run [--spec PATH] [--timeout SECONDS]
                                      wait for deployment and migration receipt
  fm-release-receipt-check.sh audit [--spec PATH]
                                      print the durable release audit
  fm-release-receipt-check.sh arm [--spec PATH]
                                      arm the existing watcher check
  fm-release-receipt-check.sh disarm remove the watcher check and receipt
  fm-release-receipt-check.sh --help print this help

Manifest:
  FM_RELEASE_SPEC_FILE                 default $FM_HOME/config/release-receipt.json
  FM_RELEASE_TIMEOUT_SECS              run timeout, default 900
  FM_RELEASE_POLL_SECS                 run interval, default 10
  FM_RELEASE_APP_DB_ENV_FILE           existing App DB env file, optional
  FM_RELEASE_APP_DB_URL                existing App DB REST base URL
  FM_RELEASE_APP_DB_TOKEN              existing App DB bearer, never printed

The manifest fields are release_id, intended_commit, targets, migrations, and
ledger. A target has provider, app_id or service_id, expected_build_id, and
optional status_url, build_id_url, expected_commit, or deploy_id. A migration
is a string or an object with name and optional commit. The ledger may provide
url, project_ref, name_field, and commit_field.
EOF
}

die_usage() {
  printf 'fm-release-receipt-check: %s\n' "$1" >&2
  usage >&2
  exit 2
}

ACTION=${1:-check}
case "$ACTION" in
  check|run|audit|arm|disarm) ;;
  -h|--help)
    usage
    exit 0
    ;;
  *) die_usage "unknown action: $ACTION" ;;
esac
shift || true

SPEC_FILE="${FM_RELEASE_SPEC_FILE:-$FM_HOME/config/release-receipt.json}"
TIMEOUT_SECS=${FM_RELEASE_TIMEOUT_SECS:-900}
POLL_SECS=${FM_RELEASE_POLL_SECS:-10}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --spec)
      [ "$#" -ge 2 ] || die_usage "--spec requires a path"
      SPEC_FILE=$2
      shift 2
      ;;
    --timeout)
      [ "$#" -ge 2 ] || die_usage "--timeout requires seconds"
      TIMEOUT_SECS=$2
      shift 2
      ;;
    --poll)
      [ "$#" -ge 2 ] || die_usage "--poll requires seconds"
      POLL_SECS=$2
      shift 2
      ;;
    *) die_usage "unknown option: $1" ;;
  esac
done

case "$TIMEOUT_SECS" in
  ''|*[!0-9]*) die_usage "timeout must be a whole number" ;;
esac
case "$POLL_SECS" in
  ''|*[!0-9]*) die_usage "poll interval must be a whole number" ;;
esac

for required in jq curl; do
  command -v "$required" >/dev/null 2>&1 || {
    printf 'fm-release-receipt-check: %s is required\n' "$required" >&2
    exit 2
  }
done

TMP_ROOT=
cleanup() {
  [ -z "$TMP_ROOT" ] || rm -rf -- "$TMP_ROOT"
}
trap cleanup EXIT HUP INT TERM

epoch_now() {
  case "${FM_RELEASE_NOW:-}" in
    ''|*[!0-9]*) date +%s ;;
    *) printf '%s\n' "$FM_RELEASE_NOW" ;;
  esac
}

read_setting() {
  local direct_name=$1 file_name=$2 file=$3 direct=
  eval "direct=\${$direct_name-}"
  if [ -n "$direct" ]; then
    printf '%s' "$direct"
  else
    fmx_env_get "$file_name" "$file"
  fi
}

coolify_env_file() {
  printf '%s\n' "${FM_RELEASE_COOLIFY_ENV_FILE:-${HOME:-}/.config/beanz/coolify.env}"
}

render_env_file() {
  printf '%s\n' "${FM_RELEASE_RENDER_ENV_FILE:-${HOME:-}/.config/lalo/render-api.env}"
}

app_db_env_file() {
  printf '%s\n' "${FM_RELEASE_APP_DB_ENV_FILE:-}"
}

COOLIFY_URL=
COOLIFY_TOKEN=
RENDER_URL=
RENDER_TOKEN=
APP_DB_URL=
APP_DB_TOKEN=

load_credentials() {
  local coolify_file render_file app_file
  coolify_file=$(coolify_env_file)
  render_file=$(render_env_file)
  app_file=$(app_db_env_file)

  COOLIFY_URL=$(read_setting FM_RELEASE_COOLIFY_URL COOLIFY_URL "$coolify_file")
  [ -n "$COOLIFY_URL" ] || COOLIFY_URL=$(read_setting COOLIFY_URL COOLIFY_URL "$coolify_file")
  COOLIFY_TOKEN=$(read_setting FM_RELEASE_COOLIFY_API_TOKEN COOLIFY_API_TOKEN "$coolify_file")
  [ -n "$COOLIFY_TOKEN" ] || COOLIFY_TOKEN=$(read_setting COOLIFY_API_TOKEN COOLIFY_API_TOKEN "$coolify_file")

  RENDER_URL=$(read_setting FM_RELEASE_RENDER_API_URL RENDER_API_URL "$render_file")
  [ -n "$RENDER_URL" ] || RENDER_URL=https://api.render.com
  RENDER_TOKEN=$(read_setting FM_RELEASE_RENDER_API_KEY RENDER_API_KEY "$render_file")

  APP_DB_URL=$(read_setting FM_RELEASE_APP_DB_URL APP_DB_URL "$app_file")
  [ -n "$APP_DB_URL" ] || APP_DB_URL=$(read_setting SUPABASE_URL SUPABASE_URL "$app_file")
  APP_DB_TOKEN=$(read_setting FM_RELEASE_APP_DB_TOKEN APP_DB_TOKEN "$app_file")
  [ -n "$APP_DB_TOKEN" ] || APP_DB_TOKEN=$(read_setting SUPABASE_SERVICE_ROLE_KEY SUPABASE_SERVICE_ROLE_KEY "$app_file")
  [ -n "$APP_DB_TOKEN" ] || APP_DB_TOKEN=$(read_setting SUPABASE_ACCESS_TOKEN SUPABASE_ACCESS_TOKEN "$app_file")
  [ -n "$APP_DB_TOKEN" ] || APP_DB_TOKEN=$(read_setting APP_DB_SERVICE_ROLE_KEY APP_DB_SERVICE_ROLE_KEY "$app_file")
  [ -n "$APP_DB_TOKEN" ] || APP_DB_TOKEN=$(read_setting APP_DB_TOKEN APP_DB_TOKEN "$app_file")
  [ -n "$APP_DB_TOKEN" ] || APP_DB_TOKEN=$(read_setting SUPABASE_KEY SUPABASE_KEY "$app_file")
}

load_spec() {
  [ -f "$SPEC_FILE" ] && [ ! -L "$SPEC_FILE" ] || {
    printf 'release receipt unavailable: manifest is missing\n'
    return 1
  }
  jq -e '
    type == "object" and
    ((.release_id // "") | type == "string" and length > 0) and
    ((.intended_commit // .commit // "") | type == "string" and length > 0) and
    ((.targets // []) | type == "array" and length > 0 and
      all(.[]; (.provider == "coolify" or .provider == "render") and
        ((.expected_build_id // .build_id // "") | type == "string" and length > 0))) and
    ((.migrations // []) | type == "array" and length > 0)
  ' "$SPEC_FILE" >/dev/null 2>&1 || {
    printf 'release receipt unavailable: manifest shape is invalid\n'
    return 1
  }
  SPEC=$(cat "$SPEC_FILE")
}

SPEC=
TMP_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-release-receipt.XXXXXX") || exit 1
chmod 0700 "$TMP_ROOT"

safe_url() {
  case "$1" in
    *'/api/v1/deploy'|*'/api/v1/deploy/'*|*'/api/v1/deploy?'*|*'/start'|*'/start?'*)
      return 1
      ;;
    *) return 0 ;;
  esac
}

RESPONSE_BODY=
RESPONSE_STATUS=
request_get() {
  local url=$1 token=$2 headers=()
  RESPONSE_BODY=
  RESPONSE_STATUS=
  safe_url "$url" || return 2
  RESPONSE_BODY="$TMP_ROOT/response.$RANDOM"
  RESPONSE_STATUS="$TMP_ROOT/status.$RANDOM"
  if [ -n "$token" ]; then
    headers=(-H "Authorization: Bearer $token")
  fi
  if ! curl -sS --max-time "${FM_CHECK_TIMEOUT:-30}" \
      "${headers[@]}" -H 'Accept: application/json' \
      -o "$RESPONSE_BODY" -w '%{http_code}' "$url" >"$RESPONSE_STATUS" 2>/dev/null; then
    return 1
  fi
  RESPONSE_STATUS=$(cat "$RESPONSE_STATUS" 2>/dev/null)
  case "$RESPONSE_STATUS" in
    2[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  [ -s "$RESPONSE_BODY" ] || printf '{}\n' > "$RESPONSE_BODY"
}

json_or_text() {
  local file=$1
  if jq -e . "$file" >/dev/null 2>&1; then
    jq -r '
      if type == "string" then .
      else (.build_id // .buildId // .id // .version // .data.build_id? // "")
      end
    ' "$file" 2>/dev/null | awk 'NF { print; exit }'
  else
    tr -d '[:space:]' < "$file"
  fi
}

first_json_string() {
  local file=$1 filter=$2
  jq -r "$filter" "$file" 2>/dev/null | awk 'NF && $0 != "null" { print; exit }'
}

target_url() {
  local target=$1 provider base app service deploy
  provider=$(jq -r '.provider // ""' <<< "$target")
  case "$provider" in
    coolify)
      base=${COOLIFY_URL%/}
      app=$(jq -r '.app_id // .application_id // ""' <<< "$target")
      [ -n "$base" ] && [ -n "$app" ] || return 1
      printf '%s\n' "$base/api/v1/applications/$app"
      ;;
    render)
      base=${RENDER_URL%/}
      service=$(jq -r '.service_id // ""' <<< "$target")
      deploy=$(jq -r '.deploy_id // ""' <<< "$target")
      [ -n "$base" ] && [ -n "$service" ] || return 1
      if [ -n "$deploy" ]; then
        printf '%s\n' "$base/v1/services/$service/deploys/$deploy"
      else
        printf '%s\n' "$base/v1/services/$service"
      fi
      ;;
    *) return 1 ;;
  esac
}

target_observe() {
  local target=$1 provider url build_url token status_body
  local status commit build expected_commit expected_build failure complete
  provider=$(jq -r '.provider // ""' <<< "$target")
  case "$provider" in
    coolify) token=$COOLIFY_TOKEN ;;
    render) token=$RENDER_TOKEN ;;
    *) printf '{"provider":"unknown","status":"unavailable","complete":false}\n'; return ;;
  esac
  url=$(jq -r '.status_url // empty' <<< "$target")
  [ -n "$url" ] || url=$(target_url "$target" 2>/dev/null) || {
    printf '{"provider":"%s","status":"unavailable","complete":false}\n' "$provider"
    return
  }
  request_get "$url" "$token" || {
    rc=$?
    if [ "$rc" -eq 2 ]; then
      printf '{"provider":"%s","status":"unsafe-url","complete":false,"failure":"unsafe status URL"}\n' "$provider"
    else
      printf '{"provider":"%s","status":"unavailable","complete":false}\n' "$provider"
    fi
    return
  }
  status_body=$RESPONSE_BODY
  status=$(first_json_string "$status_body" '
    [ .status, .state, .deployment_status, .deploymentStatus,
      .latest_deployment.status?, .latestDeployment.status?,
      .deploy.status?, .deployment.status? ] |
    map(select(type == "string")) | map(ascii_downcase) | .[0] // ""
  ')
  commit=$(first_json_string "$status_body" '
    [ .git_commit_sha, .commit_sha, .commit, .gitCommitSha,
      .commit.id?, .git_commit.id?,
      .latest_deployment.commit?, .latest_deployment.commit_sha?,
      .latestDeployment.commit?, .latestDeployment.commit.id?,
      .deploy.commit?, .deploy.commit.id?, .deployment.commit?,
      .deployment.commit.id? ] |
    map(select(type == "string")) | .[0] // ""
  ')
  build=$(first_json_string "$status_body" '
    [ .build_id, .buildId, .build_uuid, .buildUuid, .deployment_id,
      .deployment_uuid, .latest_deployment.build_id?,
      .latestDeployment.build_id?, .deploy.build_id? ] |
    map(select(type == "string")) | .[0] // ""
  ')
  build_url=$(jq -r '.build_id_url // empty' <<< "$target")
  if [ -n "$build_url" ]; then
    request_get "$build_url" "$token" || {
      printf '{"provider":"%s","status":"%s","commit":%s,"build_id":"","complete":false,"failure":"build id unavailable"}\n' \
        "$provider" "$status" "$(jq -Rn --arg v "$commit" '$v')"
      return
    }
    build=$(json_or_text "$RESPONSE_BODY")
  fi
  expected_commit=$(jq -r '.expected_commit // empty' <<< "$target")
  [ -n "$expected_commit" ] || expected_commit=$(jq -r '.intended_commit // .commit' <<< "$SPEC")
  expected_build=$(jq -r '.expected_build_id // .build_id // empty' <<< "$target")
  failure=
  complete=false
  case "$status" in
    running|live|finished|success|succeeded|completed|deployed|healthy)
      complete=true
      ;;
    failed|failure|error|errored|cancelled|canceled|build_failed|crashed|unhealthy|deactivated)
      failure="deployment status $status"
      ;;
    '') failure="deployment status unavailable" ;;
    *) ;;
  esac
  if [ "$complete" = true ] || [ -n "$failure" ]; then
    [ -n "$expected_commit" ] && [ "$commit" = "$expected_commit" ] || {
      [ -n "$commit" ] || failure=${failure:-"deployed commit unavailable"}
      [ -z "$commit" ] || [ "$commit" = "$expected_commit" ] ||
        failure=${failure:-"deployed commit mismatch"}
    }
    [ -n "$expected_build" ] && [ "$build" = "$expected_build" ] || {
      [ -n "$build" ] || failure=${failure:-"deployed build id unavailable"}
      [ -z "$build" ] || [ "$build" = "$expected_build" ] ||
        failure=${failure:-"deployed build id mismatch"}
    }
  fi
  jq -cn \
    --arg provider "$provider" --arg status "$status" --arg commit "$commit" \
    --arg build_id "$build" --arg expected_commit "$expected_commit" \
    --arg expected_build_id "$expected_build" --arg failure "$failure" \
    --argjson complete "$complete" \
    '{provider:$provider,status:$status,commit:$commit,build_id:$build_id,
      expected_commit:$expected_commit,expected_build_id:$expected_build_id,
      complete:$complete,healthy:($complete and $failure == "" and
        $commit == $expected_commit and $build_id == $expected_build_id),
      failure:($failure // "")}'
}

ledger_url() {
  local ledger=$1 url project_ref
  url=$(jq -r '.url // empty' <<< "$ledger")
  [ -n "$url" ] && { printf '%s\n' "$url"; return; }
  project_ref=$(jq -r '.project_ref // empty' <<< "$ledger")
  [ -n "$project_ref" ] || project_ref=$(jq -r '.project_ref // empty' <<< "$SPEC")
  [ -n "$project_ref" ] || project_ref=$DEFAULT_PROJECT_REF
  if [ -n "$APP_DB_URL" ]; then
    url=${APP_DB_URL%/}
  else
    url="https://${project_ref}.supabase.co"
  fi
  printf '%s/rest/v1/lalo_app_migration_ledger?select=*\n' "$url"
}

ledger_rows() {
  local ledger=$1 file url
  file=$(jq -r '.file // empty' <<< "$ledger")
  if [ -n "$file" ]; then
    [ -f "$file" ] && [ ! -L "$file" ] || return 1
    cat "$file"
    return
  fi
  url=$(ledger_url "$ledger")
  request_get "$url" "$APP_DB_TOKEN" || return 1
  cat "$RESPONSE_BODY"
}

migration_observe() {
  local ledger rows name_field commit_field row missing mismatch
  ledger=$(jq -c '.ledger // {}' <<< "$SPEC")
  name_field=$(jq -r '.name_field // "name"' <<< "$ledger")
  commit_field=$(jq -r '.commit_field // "commit_sha"' <<< "$ledger")
  rows=$(ledger_rows "$ledger" 2>/dev/null) || {
    printf '{"state":"unverified","missing":[],"mismatches":[],"failure":"migration ledger unavailable"}\n'
    return
  }
  jq -e 'type == "array"' <<< "$rows" >/dev/null 2>&1 || {
    printf '{"state":"unverified","missing":[],"mismatches":[],"failure":"migration ledger shape invalid"}\n'
    return
  }
  missing=
  mismatch=
  while IFS= read -r expected; do
    [ -n "$expected" ] || continue
    row=$(jq -c --arg field "$name_field" --arg wanted "$expected" '
      [ .[] | select((.[ $field ] // .migration_name // .filename // .version // "") == $wanted) ][0] // empty
    ' <<< "$rows")
    if [ -z "$row" ]; then
      missing="${missing}${missing:+,}$expected"
      continue
    fi
    expected_commit=$(jq -r --arg wanted "$expected" '
      .migrations[] | if type == "string" then
        select(. == $wanted) | ""
      else select((.name // .migration_name // "") == $wanted) | (.commit // "") end
    ' <<< "$SPEC" | awk 'NF { print; exit }')
    if [ -n "$expected_commit" ]; then
      row_commit=$(jq -r --arg field "$commit_field" '.[$field] // .commit // .commit_sha // ""' <<< "$row")
      [ "$row_commit" = "$expected_commit" ] || mismatch="${mismatch}${mismatch:+,}$expected"
    fi
  done < <(jq -r '.migrations[] | if type == "string" then . else (.name // .migration_name // "") end' <<< "$SPEC")
  if [ -n "$missing" ] || [ -n "$mismatch" ]; then
    jq -cn --arg missing "$missing" --arg mismatches "$mismatch" \
      '{state:"unverified",missing:($missing|split(",")|map(select(length>0))),
        mismatches:($mismatches|split(",")|map(select(length>0))),
        failure:"migration receipt incomplete"}'
  else
    printf '%s\n' '{"state":"verified","missing":[],"mismatches":[],"failure":""}'
  fi
}

RESULT=
REPORT=
build_result() {
  local targets migration intended release_id app_state migration_state overall target row
  intended=$(jq -r '.intended_commit // .commit' <<< "$SPEC")
  release_id=$(jq -r '.release_id' <<< "$SPEC")
  targets='[]'
  while IFS= read -r target; do
    row=$(target_observe "$target")
    targets=$(jq -c --argjson row "$row" '. + [$row]' <<< "$targets")
  done < <(jq -c '.targets[]' <<< "$SPEC")
  migration=$(migration_observe)
  migration_state=$(jq -r '.state' <<< "$migration")
  if jq -e 'length > 0 and all(.[]; .healthy == true)' <<< "$targets" >/dev/null 2>&1; then
    app_state=healthy
  elif jq -e 'any(.[]; .failure != "")' <<< "$targets" >/dev/null 2>&1; then
    app_state=mismatch
  else
    app_state=waiting
  fi
  if [ "$app_state" = healthy ] && [ "$migration_state" = verified ]; then
    overall=healthy
  elif [ "$app_state" = mismatch ] || jq -e '.mismatches | length > 0' <<< "$migration" >/dev/null 2>&1; then
    overall=mismatch
  elif [ "$app_state" = healthy ] && [ "$migration_state" = unverified ]; then
    overall=unverified
  else
    overall=waiting
  fi
  RESULT=$(jq -cn --arg schema "$RECORD_SCHEMA" --arg observed_at "$(epoch_now)" \
    --arg release_id "$release_id" --arg intended_commit "$intended" \
    --arg overall "$overall" --arg app "$app_state" \
    --arg migration "$migration_state" --argjson targets "$targets" \
    --argjson receipt "$migration" \
    '{schema:$schema,observed_at:($observed_at|tonumber),release_id:$release_id,
      intended_commit:$intended_commit,overall:$overall,app:$app,
      migration:$migration,targets:$targets,receipt:$receipt}')
  REPORT=$(jq -r '
    if .overall == "healthy" then
      "release receipt: app=healthy migration=verified commit=" + .intended_commit
    elif .overall == "unverified" then
      "release receipt: app=healthy migration=unverified missing=" +
        (if ((.receipt.missing // []) | length) > 0 then
          ((.receipt.missing // []) | join(","))
        else (.receipt.failure // "migration receipt unavailable") end)
    elif .overall == "mismatch" then
      "release receipt: mismatch commit=" + .intended_commit + " " +
        (([.targets[] | select(.failure != "") | .provider + ": " + .failure] +
          ((.receipt.mismatches // []) | map("migration: " + .))) | join("; "))
    else
      "release receipt: waiting for deployment or migration receipt"
    end
  ' <<< "$RESULT")
}

record_read_report() {
  [ -f "$RECORD" ] && [ ! -L "$RECORD" ] || return 1
  jq -r '.report // empty' "$RECORD" 2>/dev/null
}

record_write() {
  local report=$1 tmp
  [ -d "$STATE" ] && [ ! -L "$STATE" ] || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID.XXXXXX") || return 1
  jq --arg report "$report" '. + {report:$report}' <<< "$RESULT" > "$tmp" || {
    rm -f -- "$tmp"
    return 1
  }
  chmod 0600 "$tmp" && mv -f -- "$tmp" "$RECORD"
}

observe_once() {
  load_credentials
  load_spec || return 1
  build_result
  record_write "$REPORT" || true
}

print_result() {
  printf '%s\n' "$REPORT"
}

action_check() {
  local previous
  previous=$(record_read_report 2>/dev/null || true)
  observe_once || return 0
  [ "$REPORT" = "$previous" ] || print_result
  return 0
}

action_audit() {
  observe_once || return 1
  print_result
  jq -c '{release_id,overall,app,migration,intended_commit,targets,receipt}' <<< "$RESULT"
  [ "$(jq -r '.overall' <<< "$RESULT")" = healthy ]
}

action_run() {
  local start now deadline state
  load_credentials
  load_spec || return 1
  start=$(epoch_now)
  deadline=$((start + TIMEOUT_SECS))
  while :; do
    build_result
    record_write "$REPORT" || true
    state=$(jq -r '.overall' <<< "$RESULT")
    case "$state" in
      healthy)
        print_result
        return 0
        ;;
      mismatch)
        print_result
        return 1
        ;;
    esac
    now=$(epoch_now)
    if [ "$now" -ge "$deadline" ]; then
      print_result
      return 1
    fi
    [ "$POLL_SECS" -eq 0 ] || sleep "$POLL_SECS"
  done
}

shim_content() {
  local home=$1 root=$2 spec=${3-}
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    '# Auto-generated by fm-release-receipt-check.sh.' \
    '# The watcher validates these bytes before execution.' \
    "export FM_HOME=$(printf '%q' "$home")" \
    "export FM_RELEASE_SPEC_FILE=$(printf '%q' "$spec")" \
    "exec $(printf '%q' "$root/bin/fm-release-receipt-check.sh") check"
}

action_arm() {
  local home tmp want device
  mkdir -p "$STATE" || return 1
  home=$(CDPATH='' cd -- "$FM_HOME" 2>/dev/null && pwd -P) || return 1
  want=$(shim_content "$home" "$SCRIPT_DIR/.." "$SPEC_FILE")
  device=$(fm_pr_file_device "$STATE") || return 1
  fm_pr_regular_destination_on_device_or_absent "$CHECK_SHIM" "$device" || return 1
  tmp=$(umask 077; mktemp "$STATE/.$CHECK_ID-check.XXXXXX") || return 1
  if ! printf '%s\n' "$want" > "$tmp" || ! chmod 0700 "$tmp" ||
    ! mv -f -- "$tmp" "$CHECK_SHIM"; then
    rm -f -- "$tmp"
    return 1
  fi
  if ! FM_HOME="$home" FM_RELEASE_SPEC_FILE="$SPEC_FILE" "$REGISTER_BIN" "$CHECK_ID" >/dev/null; then
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
  run) action_run ;;
  audit) action_audit ;;
  arm)
    [ -n "$SPEC_FILE" ] || die_usage "spec is required to arm"
    action_arm
    ;;
  disarm) action_disarm ;;
esac
