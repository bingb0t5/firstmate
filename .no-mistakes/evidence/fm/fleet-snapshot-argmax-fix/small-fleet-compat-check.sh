#!/usr/bin/env bash
# Small-fleet compatibility check: run the pre-fix and post-fix fleet snapshot
# against the SAME read-only fixture home and diff the emitted document, so any
# schema, ordering, truncation, or content change introduced by the ARG_MAX
# transport fix would show up as a diff.
set -u
REPO=${REPO:?}
PREFIX=$(mktemp)
sed -n '1,134p' "$REPO/tests/fm-fleet-snapshot-view.test.sh" \
  | sed 's#\$(dirname "\${BASH_SOURCE\[0\]}")/lib.sh#'"$REPO"'/tests/lib.sh#' > "$PREFIX"
# shellcheck disable=SC1090
. "$PREFIX"; rm -f "$PREFIX"

home=$(make_home compat); write_fixture "$home"; fakebin=$(make_fakebin "$home")
run() {  # <script> <outfile>
  PATH="$fakebin:$PATH" FM_HOME="$home" "$1" --json > "$2" 2>"$2.err"
  printf 'exit=%s bytes=%s\n' "$?" "$(wc -c < "$2" | tr -d ' ')"
}
before=$(mktemp); after=$(mktemp)
echo "pre-fix  ($1):  $(run "$1" "$before")"
echo "post-fix ($2): $(run "$2" "$after")"
# Normalize only wall-clock stamps; everything else must match byte for byte.
norm() { jq -S . < "$1" | sed -E -e 's/"(observed_at|generated_at|checked_at|generated|at)": *"[^"]*"/"\1":"<ts>"/g' -e 's/"age_seconds": *[0-9]+/"age_seconds":<age>/g'; }
if diff <(norm "$before") <(norm "$after") > /tmp/compat.diff 2>&1; then
  echo "RESULT: post-fix snapshot is byte-identical to pre-fix on the small fixture fleet (timestamps normalized)"
else
  echo "RESULT: documents differ:"; head -60 /tmp/compat.diff
fi
echo "key ordering check (raw, unsorted top-level keys):"
echo "  pre-fix : $(jq -r 'keys_unsorted | join(",")' < "$before")"
echo "  post-fix: $(jq -r 'keys_unsorted | join(",")' < "$after")"
echo "task row order:"
echo "  pre-fix : $(jq -r '[.tasks[].id] | join(",")' < "$before")"
echo "  post-fix: $(jq -r '[.tasks[].id] | join(",")' < "$after")"
rm -f "$before" "$after" "$before.err" "$after.err" /tmp/compat.diff
