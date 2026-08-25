#!/usr/bin/env bash
# End-to-end demo of the fleet PR merge-conflict watcher as an operator sees it:
# arm the check, let the REAL bin/fm-watch.sh poll it on its own cadence, and
# show the wake text that reaches firstmate through the durable wake queue.
#
# GitHub is the only thing faked (a canned gh-axi). Repository discovery,
# owner routing, the check shim + trust binding, the watcher check sweep, the
# wake queue, and the drain are all the production code paths.
set -u
ROOT=${FM_E2E_ROOT:?set FM_E2E_ROOT to the firstmate checkout}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/pr-conflict-e2e.XXXXXX")
HOME_DIR="$WORK/home"
FIXTURE="$HOME_DIR/fixture"
FAKEBIN="$HOME_DIR/fakebin"
TANGLE="$WORK/tangle"
REPO_A=acme/alpha
REPO_B=acme/beta
FM_SLUG=$(git -C "$ROOT" remote get-url origin | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##')
HEAD_ONE=1111111111111111111111111111111111111111
HEAD_TWO=2222222222222222222222222222222222222222

mkdir -p "$HOME_DIR/state" "$HOME_DIR/data" "$HOME_DIR/projects/alpha" "$HOME_DIR/projects/beta" \
  "$FIXTURE/lists" "$FIXTURE/views" "$FAKEBIN" "$TANGLE"

cat > "$HOME_DIR/data/projects.md" <<'MD'
# Projects

- alpha - alpha service (added 2026-08-25)
- beta - beta service (added 2026-08-25)
MD
cat > "$HOME_DIR/data/secondmates.md" <<'MD'
# Second mates

- team-a - owns alpha (home: /tmp/team-a; scope: alpha; projects: alpha; added 2026-08-25)
- team-b - owns beta (home: /tmp/team-b; scope: beta; projects: beta; added 2026-08-25)
MD

for p in alpha beta; do git -C "$HOME_DIR/projects/$p" init -q; done
git -C "$HOME_DIR/projects/alpha" remote add origin "https://github.com/$REPO_A.git"
git -C "$HOME_DIR/projects/beta" remote add origin "https://github.com/$REPO_B.git"

cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
fixture="$FM_E2E_FIXTURE"
repo=; number=; mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    pr) mode=$2; shift 2 ;;
    --repo) repo=$2; shift 2 ;;
    --json|--state) shift ;;
    --limit) shift 2 ;;
    [0-9]*) number=$1; shift ;;
    *) shift ;;
  esac
done
printf 'pr %s --repo %s %s\n' "$mode" "$repo" "$number" >> "$FM_E2E_GHLOG"
slug=${repo//\//__}
case "$mode" in
  list) f="$fixture/lists/${slug}.json"; if [ -f "$f" ]; then cat "$f"; else printf '[]\n'; fi ;;
  view) f="$fixture/views/${slug}-${number}.json"; [ -f "$f" ] && cat "$f" ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/gh-axi"
printf '#!/usr/bin/env bash\nprintf "state: unknown - source: none - e2e fake\\n"\n' > "$FAKEBIN/fm-crew-state.sh"
chmod +x "$FAKEBIN/fm-crew-state.sh"
export FM_E2E_FIXTURE="$FIXTURE"
export FM_E2E_GHLOG="$WORK/gh-calls.log"
: > "$FM_E2E_GHLOG"

list() { local slug=${1//\//__}; printf '%s\n' "$2" > "$FIXTURE/lists/${slug}.json"; }
list "$REPO_A" '[]'; list "$REPO_B" '[]'; list "$FM_SLUG" '[]'

hr() { printf '\n=== %s ===\n' "$1"; }

drain_payload() {  # print what firstmate reads, then acknowledge it
  local err="$WORK/drain.err" seq gen
  FM_ROOT_OVERRIDE="$TANGLE" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-wake-drain.sh" 2> "$err" | cut -f5- | sed 's/^/  | /'
  seq=$(sed -n 's/.*--ack-through \([0-9][0-9]*\) .*/\1/p' "$err")
  gen=$(sed -n 's/.*--recovery-generation \([A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$gen" ] && FM_ROOT_OVERRIDE="$TANGLE" FM_STATE_OVERRIDE="$HOME_DIR/state" \
    "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$gen" >/dev/null 2>&1
  return 0
}

run_watcher() {  # <out> <max-wait-secs>; 0 = woke, 1 = kept supervising
  local out=$1 limit=$2 pid i=0
  ( PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
      FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" FM_POLL=1 FM_CHECK_INTERVAL=1 \
      FM_HEARTBEAT=999999 FM_SIGNAL_GRACE=1 FM_PR_CONFLICT_INTERVAL=0 \
      bash "$ROOT/bin/fm-watch.sh" > "$out" 2>&1 ) &
  pid=$!
  while [ "$i" -lt $((limit * 4)) ]; do
    kill -0 "$pid" 2>/dev/null || { wait "$pid" 2>/dev/null; return 0; }
    sleep 0.25; i=$((i + 1))
  done
  kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
  return 1
}

# One observation round. A watcher restarted after downtime first announces
# "check: rearm-resurface" (a watcher-lifecycle wake, nothing to do with PRs);
# that is consumed and the round is then observed on a warm watcher.
watch_round() {  # <label> <max-wait-secs>
  local label=$1 limit=$2 out before after
  out="$WORK/$label.watch"
  before=$(wc -l < "$FM_E2E_GHLOG")
  if run_watcher "$out" "$limit" && [ "$(cat "$out")" = "check: rearm-resurface" ]; then
    drain_payload >/dev/null
    before=$(wc -l < "$FM_E2E_GHLOG")
    run_watcher "$out" "$limit" || true
  fi
  after=$(wc -l < "$FM_E2E_GHLOG")
  if [ -s "$out" ]; then
    printf 'watcher exited to wake firstmate. reason printed to the supervision loop:\n'
    fold -s -w 100 "$out" | sed 's/^/  | /'
    printf 'what firstmate reads out of the durable wake queue:\n'
    drain_payload
  else
    printf 'no wake: the watcher kept supervising for %ss and printed nothing.\n' "$limit"
  fi
  printf 'GitHub reads this round (gh-axi, bounded by the sweep budget):\n'
  sed -n "$((before + 1)),${after}p" "$FM_E2E_GHLOG" | sort | uniq -c \
    | sed 's/^ *\([0-9][0-9]*\) /  | \1x gh-axi /'
}

hr "1. arm the watcher check (an operator runs this once per home)"
PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" "$ROOT/bin/fm-pr-conflict-watch.sh" arm
ls -l "$HOME_DIR/state" | sed 's/^/  /'
FM_STATE_OVERRIDE="$HOME_DIR/state" "$ROOT/bin/fm-check-register.sh" pr-conflict-watch >/dev/null \
  && printf '  trust binding verifies against the armed shim bytes\n'
printf '  repositories this fleet works in (projects.md clones + firstmate origin): %s, %s, %s\n' \
  "$REPO_A" "$REPO_B" "$FM_SLUG"

hr "2. clean fleet: nothing conflicts, so firstmate is never woken"
watch_round clean 12

hr "3. main moves: two PRs conflict (one a draft) plus one in the firstmate repo"
list "$REPO_A" "[{\"number\":7,\"title\":\"Add retry budget to the worker\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
list "$REPO_B" "[{\"number\":3,\"title\":\"WIP: split the ingest queue\",\"url\":\"https://github.com/$REPO_B/pull/3\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":true,\"mergeable\":\"CONFLICTING\"}]"
list "$FM_SLUG" "[{\"number\":2942,\"title\":\"bound remote job worker supervisor restarts\",\"url\":\"https://github.com/$FM_SLUG/pull/2942\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
watch_round conflict 20

hr "4. the same heads are still conflicting: the fleet stays quiet"
watch_round repeat 12

hr "5. PR 7's head is force-updated and still conflicts: wake again"
list "$REPO_A" "[{\"number\":7,\"title\":\"Add retry budget to the worker\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_TWO\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
watch_round forced 20

hr "6. GitHub has not computed mergeability yet (UNKNOWN): never guessed either way"
list "$REPO_A" "[{\"number\":9,\"title\":\"Lazy mergeability\",\"url\":\"https://github.com/$REPO_A/pull/9\",\"headRefOid\":\"$HEAD_TWO\",\"isDraft\":false,\"mergeable\":\"UNKNOWN\"}]"
list "$REPO_B" '[]'; list "$FM_SLUG" '[]'
printf '%s\n' "{\"mergeable\":\"UNKNOWN\",\"number\":9,\"title\":\"Lazy mergeability\",\"url\":\"https://github.com/$REPO_A/pull/9\",\"headRefOid\":\"$HEAD_TWO\",\"isDraft\":false}" \
  > "$FIXTURE/views/acme__alpha-9.json"
watch_round unknown 12

hr "7. every conflict is resolved upstream: the fleet is quiet again"
list "$REPO_A" '[]'
watch_round resolved 12

hr "8. disarm removes the shim, the trust binding, and the dedupe record"
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-pr-conflict-watch.sh" disarm
printf '  pr-conflict-watch artifacts left in state/: %s\n' \
  "$(ls "$HOME_DIR/state" 2>/dev/null | grep -c 'pr-conflict-watch')"

rm -rf "$WORK"
