#!/usr/bin/env bash
# fm-todoist-publish.sh - publish the firstmate fleet as an fm-board.v1 payload.
#
# Usage: fm-todoist-publish.sh
#
# The command reads the read-only fm-fleet-snapshot.v1 surface, applies the
# Todoist board presentation rules, and POSTs one JSON document to the bridge.
# It reads config/todoist-bridge.env as data, never as shell, and never prints
# the bearer token.
# The optional config/todoist-board-hide file contains one hidden key per line.
# An absent bridge configuration is a successful no-op that prints one line.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
ENV_FILE="$CONFIG/todoist-bridge.env"
HIDE_FILE="$CONFIG/todoist-board-hide"
SNAPSHOT_BIN="${FM_TODOIST_SNAPSHOT_BIN:-$SCRIPT_DIR/fm-fleet-snapshot.sh}"

die() {
  printf 'fm-todoist-publish: %s\n' "$*" >&2
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
    TODOIST_BRIDGE_PUBLISH_URL) value=${TODOIST_BRIDGE_PUBLISH_URL-} ;;
    TODOIST_BRIDGE_TOKEN) value=${TODOIST_BRIDGE_TOKEN-} ;;
    *) value= ;;
  esac
  if [ -z "$value" ] && [ -r "$ENV_FILE" ]; then
    value=$(read_setting "$name" || true)
  fi
  printf '%s' "$value"
}

if [ ! -r "$ENV_FILE" ] && [ -z "${TODOIST_BRIDGE_PUBLISH_URL:-}" ] &&
  [ -z "${TODOIST_BRIDGE_TOKEN:-}" ]; then
  printf 'fm-todoist-publish: bridge unconfigured\n'
  exit 0
fi

PUBLISH_URL=$(setting TODOIST_BRIDGE_PUBLISH_URL)
TOKEN=$(setting TODOIST_BRIDGE_TOKEN)
[ -n "$PUBLISH_URL" ] && [ -n "$TOKEN" ] || die "bridge configuration is incomplete"
command -v jq >/dev/null 2>&1 || die "jq not found"
command -v curl >/dev/null 2>&1 || die "curl not found"
[ -x "$SNAPSHOT_BIN" ] || die "fleet snapshot is unavailable"

mkdir -p "$STATE"
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/fm-todoist-publish.XXXXXX") ||
  die "temporary directory creation failed"
trap 'rm -rf "$tmpdir"' EXIT HUP INT TERM

snapshot="$tmpdir/snapshot.json"
payload="$tmpdir/payload.json"
hide="$tmpdir/hide"

if ! FM_ROOT_OVERRIDE="$FM_ROOT" FM_HOME="$FM_HOME" \
  FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$CONFIG" \
  "$SNAPSHOT_BIN" --json >"$snapshot" 2>"$tmpdir/snapshot.error"; then
  die "fleet snapshot failed"
fi

if [ -r "$HIDE_FILE" ]; then
  awk '
    { sub(/\r$/, ""); sub(/^[[:space:]]+/, ""); sub(/[[:space:]]+$/, "") }
    length > 0 && $0 !~ /^#/ { print }
  ' "$HIDE_FILE" >"$hide"
else
  : >"$hide"
fi

jq -e --rawfile hidden "$hide" '
  .schema == "fm-fleet-snapshot.v1"
  and (.backlog.records | type) == "array"
  and (.tasks | type) == "array"
' "$snapshot" >/dev/null || die "fleet snapshot is malformed"

jq -n \
  --slurpfile snapshot "$snapshot" \
  --rawfile hidden "$hide" '
  def trim: gsub("^[[:space:]]+|[[:space:]]+$"; "");
    def one_line: gsub("[[:space:]]+"; " ") | trim;
    def valid_date:
      test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$")
      and (try ((. + "T00:00:00Z") | fromdateiso8601 | true) catch false);
    def date_value:
      if type == "string" and (try (fromdateiso8601 | true) catch false)
      then .[:10]
      else null
      end;
    def body($row):
      (($row.body_lines // []) | join("\n"));
    def token($body; $name):
      ((try ($body | capture("(?im)(^|[[:space:]])" + $name +
        ":[[:space:]]*(?<v>[0-9]{4}-[0-9]{2}-[0-9]{2})([[:space:]]|$)").v)
       catch null) // null) as $v
      | if ($v != null and ($v | valid_date)) then $v else null end;
    def options($body):
      [$body
       | scan("(?im)^options:[[:space:]]*(?<v>[^\\r\\n]*)")[]
       | splits("[|,]")
       | trim
       | select(length > 0)];
    def default_value($body):
      (try ($body | capture("(?im)^default:[[:space:]]*(?<v>[^\\r\\n]*)").v)
       catch null) as $v
      | if $v == null then null else ($v | trim) end;
    def event($task):
      (($task.hints.last_event_text // "") | gsub("[[:space:]]*\\[[[:space:]]*at=[^]]+\\]"; "") | one_line);
    def merged($backlog; $task):
      (($backlog.completion.verb // "") == "merged")
      or (($backlog.merged // null) != null)
      or (($task.current_state.detail // "") | test("(^|[^[:alpha:]])merged([^[:alpha:]]|$)"; "i"))
      or (($task.hints.last_event_text // "") | test("(^|[^[:alpha:]])merged([^[:alpha:]]|$)"; "i"));
    def worker($task):
      (($task.harness // "") +
       (if ($task.model // "") == "" then "" else " " + $task.model end)
       | .);
    def item($snap; $key; $backlog; $task):
      ($backlog // {}) as $b
      | ($task // {}) as $t
      | (($b.body_lines // []) | join("\n")) as $body
      | ($t.current_state // {}) as $current
      | ($t.pr.url // $b.pr_url // "") as $pr
      | ($b.hold_kind // null) as $hold_kind
      | ($b.hold_reason // null) as $hold_reason
      | ($current.state // "unknown") as $state
      | ($current.source // "none") as $source
      | (if $b.state == "done" then
           (try (($b.completion.date // "") + "T00:00:00Z" | fromdateiso8601) catch null) as $closed
           | (try ($snap.generated[:10] + "T00:00:00Z" | fromdateiso8601) catch null) as $today
           | if ($closed != null and $today != null and (($today - $closed) >= 0 and ($today - $closed) <= (7 * 86400)))
             then "Done this week"
             else "archive"
             end
         elif $hold_kind == "captain" then "Waiting for captain"
         elif $hold_kind != null and $hold_reason != null then "Queued"
         elif $b.state == "queued" then "Queued"
         elif ($state == "done" and $pr != "") then
           if merged($b; $t) then "Done this week" else "Waiting for captain" end
         elif ($source == "run-step") then "Validation"
         else "In progress"
         end) as $base_stage
      | (if (($b.kind // $t.kind // "") == "scout"
             and (($key + " " + ($b.title // "")) | test("review"; "i"))
             and $base_stage == "In progress")
         then "UI review"
         else $base_stage
         end) as $stage
      | (($state == "failed" or $state == "blocked") or ($t.hints.blocked_event // false)) as $blocked
      | (if $hold_kind == "captain" then $hold_reason
         elif $hold_kind != null and $hold_reason != null then
           ("Waiting (" + $hold_kind + "): " + $hold_reason +
            (if $b.hold_until == null then "" else " until " + $b.hold_until end))
         elif $state == "done" and $pr != "" and ($stage == "Waiting for captain") then
           "Ready for the captain merge word"
         elif $source == "run-step" then
           ("Validation " + $state + (if ($current.detail // "") == "" then "" else ": " + $current.detail end))
         elif ($current.detail // "") != "" then $current.detail
         elif $b.state == "queued" then "Queued, not started"
         else ($b.title // $key)
         end) as $reason
      | ([$b.hold_until, token($body; "due")] | map(select(. != null)) | .[0]) as $due
      | token($body; "deadline") as $deadline
      | ({
          key:$key,
          title:($b.title // $key),
          repo:($b.repo // ""),
          kind:($b.kind // $t.kind // ""),
          stage:$stage,
          stage_reason:($reason | one_line),
          status:(($current.detail // $b.title // $key) | one_line),
          last_event:event($t),
          pr_url:$pr,
          worker:worker($t),
          question:(if $hold_kind == "captain" then ($hold_reason // "") else "" end),
          options:(if $hold_kind == "captain" then options($body) else [] end),
          default:(if $hold_kind == "captain" then (default_value($body) // "") else "" end),
          hold_until:($b.hold_until // null),
          due:$due,
          deadline:$deadline,
          blocked:$blocked,
          labels:[]
        })
      | .labels = (
          [(.repo | select(. != "")),
           (if .stage == "Waiting for captain" then "captain" else empty end),
           (if .blocked then "blocked" else empty end)]
          | unique)
      | .;
  ($snapshot[0]) as $s
  | ($hidden | split("\n") | map(select(length > 0))) as $hidden_keys
  | ([ $s.backlog.records[]?
       | select(.structured == true)
       | {key:.id, backlog:.} ]
     + [ $s.tasks[]? | {key:.id, task:.} ])
  | group_by(.key)
  | map(reduce .[] as $part
      ({}; .key = ($part.key // .key)
       | .backlog = ($part.backlog // .backlog)
       | .task = ($part.task // .task))
      | select((.key // "") != "" and ((.key) as $k | ($hidden_keys | index($k) | not)))
      | item($s; .key; .backlog; .task))
  | {
      schema:"fm-board.v1",
      generated:$s.generated,
      items:sort_by(.key)
    }
' "$snapshot" >"$payload" || die "board payload rendering failed"

if ! curl --fail --silent --show-error --max-time "${FM_CHECK_TIMEOUT:-30}" \
  --request POST --header 'Content-Type: application/json' \
  --header "Authorization: Bearer $TOKEN" \
  --data-binary "@$payload" "$PUBLISH_URL" >"$tmpdir/curl.out" 2>"$tmpdir/curl.error"; then
  die "bridge publish failed"
fi
