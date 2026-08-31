#!/usr/bin/env bash
# Read-only end-to-end reproduction of the Firstmate fleet snapshot ARG_MAX
# outage: build a synthetic parent home whose registered-secondmate payload
# exceeds the host argv threshold, then run
#   bin/fm-fleet-snapshot.sh --json
# exactly as Firstmate Control does, and report exit status / JSON output.
#
# usage: repro-fleet-snapshot-argmax.sh <path-to-fm-fleet-snapshot.sh> <label>
set -u
REPO=${REPO:?set REPO to the firstmate checkout}
PREFIX=$(mktemp)
sed -n '1,134p' "$REPO/tests/fm-fleet-snapshot-view.test.sh" \
  | sed 's#\$(dirname "\${BASH_SOURCE\[0\]}")/lib.sh#'"$REPO"'/tests/lib.sh#' > "$PREFIX"
# shellcheck disable=SC1090
. "$PREFIX"
rm -f "$PREFIX"

SNAPSHOT=$1
LABEL=$2

home=$(make_home "argmax-$LABEL")
: > "$home/data/secondmates.md"
FLEET_COUNT=${FLEET_COUNT:-14}
PAYLOAD_BYTES=${PAYLOAD_BYTES:-180000}
for n in $(seq -w 1 "$FLEET_COUNT"); do
  id="large-secondmate-$n"
  child="$TMP_ROOT/$id"
  mkdir -p "$child/state" "$child/data" "$child/projects" "$child/config" "$child/bin"
  printf '%s\n' "$id" > "$child/.fm-secondmate-home"
  : > "$child/AGENTS.md"
  cat > "$child/data/backlog.md" <<EOF
## In flight

## Queued

## Done
- [x] landed-$id - Landed work (kind: ship) (done 2026-08-01)
EOF
  printf -- '- %s - Registered secondmate (home:%s; scope: alpha; projects: alpha; added 2026-08-01)\n' \
    "$id" "$child" >> "$home/data/secondmates.md"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "project=$child" "harness=codex" "backend=tmux" \
    "kind=secondmate" "mode=secondmate" "home=$child" "projects=alpha"
  {
    printf 'needs-decision [key=gate]: '
    dd if=/dev/zero bs="$PAYLOAD_BYTES" count=1 2>/dev/null | tr '\0' d
    printf '\n'
    printf 'working [key=phase]: '
    dd if=/dev/zero bs="$PAYLOAD_BYTES" count=1 2>/dev/null | tr '\0' x
    printf '\n'
  } > "$home/state/$id.status"
done
fakebin=$(make_fakebin "$home")

VIEW_MODE=${VIEW_MODE:-0}
if [ "$VIEW_MODE" = 1 ]; then
  echo "=== $LABEL: fm-fleet-view.sh (captain's rendered fleet board, $FLEET_COUNT registered secondmates) ==="
  view_out=$(mktemp); view_err=$(mktemp)
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=200000 \
    FM_SNAPSHOT_SECONDMATE_TIMEOUT=20 "$(dirname "$SNAPSHOT")/fm-fleet-view.sh" > "$view_out" 2> "$view_err"
  vrc=$?
  echo "exit status: $vrc"
  echo "stderr: $(head -c 300 "$view_err")"
  echo "--- rendered board (first 40 lines, long payload text truncated to 100 cols) ---"
  head -40 "$view_out" | cut -c1-100
  echo "--- (total rendered lines: $(wc -l < "$view_out" | tr -d " ")) ---"
  rm -f "$view_out" "$view_err"
  exit 0
fi
echo "=== $LABEL: $SNAPSHOT --json ($FLEET_COUNT registered secondmates, ${PAYLOAD_BYTES}B per status payload, host ARG_MAX=$(getconf ARG_MAX)) ==="
out_file=$(mktemp); err_file=$(mktemp)
PATH="$fakebin:$PATH" FM_HOME="$home" \
  FM_SNAPSHOT_PARENT_ACTIVITY_BYTES=200000 FM_SNAPSHOT_SECONDMATE_TIMEOUT=20 \
  "$SNAPSHOT" --json > "$out_file" 2> "$err_file"
rc=$?
echo "exit status: $rc"
echo "stdout bytes: $(wc -c < "$out_file" | tr -d ' ')"
if [ -s "$err_file" ]; then
  echo "stderr (unique lines with counts):"
  sed 's#^[^ ]*: line \([0-9]*\): #  fm-fleet-snapshot.sh line \1: #' "$err_file" | sort | uniq -c | sed 's/^/  /'
else
  echo "stderr: (empty)"
fi
if jq -e . < "$out_file" >/dev/null 2>&1; then
  echo "stdout is valid JSON: yes"
  jq -r '
    "schema: \(.schema)",
    "secondmate_current.records: \(.secondmate_current.records | length) (shown \(.secondmate_current.shown)/\(.secondmate_current.total))",
    "secondmate_landed.records: \(.secondmate_landed.records | length)",
    "largest open-decision summary bytes: \([.secondmate_current.records[].parent_event.open_decisions[].summary | length] | max // 0)",
    "largest activity-scan summary bytes: \([.secondmate_current.records[].parent_event.activity_scan.records[].summary | length] | max // 0)"
  ' < "$out_file"
else
  echo "stdout is valid JSON: no"
  echo "stdout head: $(head -c 200 "$out_file")"
fi
rm -f "$out_file" "$err_file"
echo
