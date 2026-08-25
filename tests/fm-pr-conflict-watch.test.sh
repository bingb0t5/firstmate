#!/usr/bin/env bash
# Tests for fm-pr-conflict-watch.sh merge-conflict detection and dedupe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-pr-conflict-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-conflict-watch)
BASE_PATH=$PATH
JQ_BIN=$(command -v jq) || fail "jq is required for these tests"

fm_git_identity fmtest fmtest@example.invalid

REPO_A=acme/alpha
REPO_B=acme/beta
HEAD_ONE=1111111111111111111111111111111111111111
HEAD_TWO=2222222222222222222222222222222222222222

make_home() {
  local name=$1 home fakebin fixture
  home="$TMP_ROOT/$name"
  fixture="$home/fixture"
  fakebin="$home/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/projects/alpha" "$home/projects/beta" \
    "$fixture/lists" "$fixture/views" "$fakebin"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- alpha - alpha repo (added 2026-08-25)
- beta - beta repo (added 2026-08-25)
MD
  cat > "$home/data/secondmates.md" <<'MD'
# Second mates

- team-a - owns alpha (home: /tmp/team-a; scope: alpha; projects: alpha; added 2026-08-25)
- team-b - owns beta (home: /tmp/team-b; scope: beta; projects: beta; added 2026-08-25)
MD
  git -C "$home/projects/alpha" init -q
  git -C "$home/projects/alpha" remote add origin "https://github.com/$REPO_A.git"
  git -C "$home/projects/beta" init -q
  git -C "$home/projects/beta" remote add origin "https://github.com/$REPO_B.git"
  fm_slug=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##')
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -u
fixture="$FM_TEST_PR_CONFLICT_FIXTURE"
repo=
number=
mode=
while [ "$#" -gt 0 ]; do
  case "$1" in
    pr)
      mode=$2
      shift 2
      ;;
    --repo)
      repo=$2
      shift 2
      ;;
    --repo=*)
      repo=${1#--repo=}
      shift
      ;;
    --json|--state)
      shift
      ;;
    --limit)
      shift 2
      ;;
    [0-9]*)
      number=$1
      shift
      ;;
    *)
      shift
      ;;
  esac
done
slug=${repo//\//__}
case "$mode" in
  list)
    file="$fixture/lists/${slug}.json"
    if [ -f "$file" ]; then
      cat "$file"
    else
      printf '[]\n'
    fi
    exit 0
    ;;
  view)
    file="$fixture/views/${slug}-${number}.json"
    seqfile="$fixture/views/${slug}-${number}.seq"
    if [ -f "$seqfile" ]; then
      idx=$(cat "$seqfile")
      idx=$((idx + 1))
      printf '%s\n' "$idx" > "$seqfile"
      jq -c ".[$((idx - 1))]" "$file"
      exit 0
    fi
    if [ -f "$file" ]; then
      cat "$file"
    fi
    exit 0
    ;;
esac
exit 0
SH
  chmod +x "$fakebin/gh-axi"
  ln -sf "$JQ_BIN" "$fakebin/jq"
  if [ -n "$fm_slug" ]; then
    write_list "$home" "$fm_slug" '[]'
  fi
  printf '%s\n' "$home"
}

write_list() {
  local home=$1 repo=$2 json=$3
  slug=${repo//\//__}
  printf '%s\n' "$json" > "$home/fixture/lists/${slug}.json"
}

write_view() {
  local home=$1 repo=$2 number=$3 json=$4
  slug=${repo//\//__}
  printf '%s\n' "$json" > "$home/fixture/views/${slug}-${number}.json"
}

# The fake gh-axi reads a scripted view sequence by array index, so the payloads
# are stored as one JSON array rather than as a stream of objects.
write_view_sequence() {
  local home=$1 repo=$2 number=$3
  slug=${repo//\//__}
  shift 3
  printf '%s\n' "$@" | jq -s '.' > "$home/fixture/views/${slug}-${number}.json"
  printf '0\n' > "$home/fixture/views/${slug}-${number}.seq"
}

run_check() {
  local home=$1 out=$2
  shift 2
  local status=0
  env FM_CHECK_TIMEOUT=30 FM_PR_CONFLICT_INTERVAL=0 FM_PR_CONFLICT_UNKNOWN_WAIT=0 \
    FM_HOME="$home" FM_ROOT="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_PR_CONFLICT_FIXTURE="$home/fixture" \
    PATH="$home/fakebin:$BASE_PATH" "$@" "$WATCH" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

test_newly_conflicted_wakes() {
  local home out
  home=$(make_home wake-new)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Broken\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "pr-conflict:" "missing wake prefix"
  assert_contains "$(cat "$out")" "owner-team=team-a" "missing owner team"
  assert_contains "$(cat "$out")" "repo=$REPO_A" "missing repo"
  assert_contains "$(cat "$out")" "number=7" "missing number"
  assert_contains "$(cat "$out")" "head=$HEAD_ONE" "missing head"
  assert_contains "$(cat "$out")" "draft=no" "missing draft flag"
  assert_contains "$(cat "$out")" "title=Broken" "missing title"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "wake must be one line"
  pass "newly conflicted PR wakes once with routing fields"
}

test_same_head_stays_silent() {
  local home out
  home=$(make_home wake-silent)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Broken\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "second poll with same head should stay silent: $(cat "$out")"
  pass "same conflicted head stays silent on the next poll"
}

test_new_head_after_force_update_wakes_again() {
  local home out
  home=$(make_home wake-new-head)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Broken\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first head should wake"
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Broken again\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_TWO\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  : > "$out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "head=$HEAD_TWO" "force-updated head should wake again"
  pass "new head after force-update wakes again"
}

test_unknown_never_reported() {
  local home out
  home=$(make_home wake-unknown)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"UNKNOWN\"}]"
  write_view_sequence "$home" "$REPO_A" 7 \
    '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","number":7,"title":"Maybe","url":"https://github.com/acme/alpha/pull/7","headRefOid":"1111111111111111111111111111111111111111","isDraft":false}' \
    '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","number":7,"title":"Maybe","url":"https://github.com/acme/alpha/pull/7","headRefOid":"1111111111111111111111111111111111111111","isDraft":false}' \
    '{"mergeable":"UNKNOWN","mergeStateStatus":"UNKNOWN","number":7,"title":"Maybe","url":"https://github.com/acme/alpha/pull/7","headRefOid":"1111111111111111111111111111111111111111","isDraft":false}'
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=3
  [ ! -s "$out" ] || fail "persistent UNKNOWN must stay silent: $(cat "$out")"
  # The fake's cursor is how many rereads the check actually made, so a silent
  # run that never reread is not mistaken for UNKNOWN being handled.
  [ "$(cat "$home/fixture/views/acme__alpha-7.seq")" = 3 ] \
    || fail "UNKNOWN should be reread up to the attempt limit, got $(cat "$home/fixture/views/acme__alpha-7.seq")"
  pass "persistent UNKNOWN is never reported as conflicted or clean"
}

test_unknown_resolving_to_conflicting_wakes() {
  local home out
  home=$(make_home wake-unknown-conflict)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"UNKNOWN\"}]"
  write_view_sequence "$home" "$REPO_A" 7 \
    "{\"mergeable\":\"UNKNOWN\",\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false}" \
    "{\"mergeable\":\"CONFLICTING\",\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false}"
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=3
  assert_contains "$(cat "$out")" "number=7" "settled CONFLICTING must wake"
  assert_contains "$(cat "$out")" "head=$HEAD_ONE" "settled wake carries the head"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=3
  [ ! -s "$out" ] || fail "a settled conflict must stay silent on the next poll: $(cat "$out")"
  pass "UNKNOWN that settles on CONFLICTING wakes once"
}

test_unknown_wake_uses_the_head_the_reread_judged() {
  local home out
  home=$(make_home wake-unknown-head)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"UNKNOWN\"}]"
  write_view "$home" "$REPO_A" 7 \
    "{\"mergeable\":\"CONFLICTING\",\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_TWO\",\"isDraft\":false}"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "head=$HEAD_TWO" "the wake must name the head the reread judged"
  assert_not_contains "$(cat "$out")" "head=$HEAD_ONE" "the stale listed head must not label the wake"
  # The next sweep sees the force-updated head as the listed one, and it is the
  # same conflict that already woke, so it must not wake a second time.
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_TWO\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the reread head must be what was recorded: $(cat "$out")"
  pass "a reread wake is labelled and deduped by the head it judged"
}

# A sweep that finds more conflicts than one line can carry must not record the
# ones it never printed: their heads do not change, so nothing would ever
# re-trigger them and they would be lost for good.
test_conflicts_past_the_line_cap_wake_on_a_later_sweep() {
  local home out i rows='' seen='' round total=12 number
  home=$(make_home wake-cap)
  i=1
  while [ "$i" -le "$total" ]; do
    [ -z "$rows" ] || rows="$rows,"
    rows="$rows{\"number\":$i,\"title\":\"Conflicted branch $i\",\"url\":\"https://github.com/$REPO_A/pull/$i\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}"
    i=$((i + 1))
  done
  write_list "$home" "$REPO_A" "[$rows]"
  out="$home/out.txt"
  round=0
  while [ "$round" -lt 6 ]; do
    : > "$out"
    run_check "$home" "$out"
    [ -s "$out" ] || break
    [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "every wake must be one line"
    while IFS= read -r number; do
      seen="$seen $number"
    done < <(tr ' ' '\n' < "$out" | sed -n 's/^number=\([0-9][0-9]*\)$/\1/p')
    round=$((round + 1))
  done
  [ "$round" -gt 1 ] || fail "12 conflicts cannot fit in one capped line; expected more than one wake"
  i=1
  while [ "$i" -le "$total" ]; do
    case " $seen " in
      *" $i "*) ;;
      *) fail "conflict $i was never reported across $round wakes" ;;
    esac
    i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "the fleet should fall silent once every conflict has woken"
  pass "conflicts cut by the line cap wake on a later sweep instead of being lost"
}

# The dedupe record is not accumulate-only: a conflict the sweep no longer
# observes is dropped, so the record stays the size of the live conflict set.
# The proof is behavioural - a dropped key cannot suppress the same conflict if
# it comes back.
test_resolved_conflicts_leave_the_record() {
  local home out
  home=$(make_home record-prune)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Broken\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  write_list "$home" "$REPO_A" '[]'
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a closed pull request must not wake: $(cat "$out")"
  # state/.pr-conflict-watch is this script's own persisted record; its
  # fm-pr-conflict-watch-v1 shape is the contract being asserted.
  assert_not_contains "$(cat "$home/state/.pr-conflict-watch")" "$HEAD_ONE" \
    "the record must not keep a key for a pull request it no longer sees"
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Broken\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  : > "$out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "number=7" "a conflict that comes back must wake again"
  pass "keys for conflicts the sweep no longer observes leave the record"
}

# A sweep that discovers no repositories at all read nothing, so it must not be
# taken as proof that the fleet stopped working in the repositories the record
# names. Erasing the record there would re-wake every unchanged conflict as soon
# as discovery recovered.
test_empty_discovery_keeps_the_record() {
  local home out
  home=$(make_home discovery-outage)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Broken\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"CONFLICTING\"}]"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  # Discovery yields nothing: no projects.md to read and no firstmate checkout
  # to take an origin from. Both reads fail, exactly as a transient outage would.
  : > "$out"
  run_check "$home" "$out" env FM_DATA_OVERRIDE="$home/data-gone" \
    FM_ROOT_OVERRIDE="$home/root-gone"
  [ ! -s "$out" ] || fail "a sweep that discovered nothing must stay silent: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the unchanged conflict must not wake again after discovery recovers: $(cat "$out")"
  pass "an empty discovery sweep does not erase the dedupe record"
}

# A run the watcher kills prints and records nothing, so the reread loop has to
# end at the sweep deadline rather than at its attempt count.
test_unknown_rereads_stop_at_the_sweep_deadline() {
  local home out started elapsed
  home=$(make_home unknown-deadline)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"UNKNOWN\"}]"
  write_view "$home" "$REPO_A" 7 \
    "{\"mergeable\":\"UNKNOWN\",\"number\":7,\"title\":\"Maybe\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false}"
  out="$home/out.txt"
  started=$(date +%s)
  # Ten attempts five seconds apart is 55s of rereads on a one second budget.
  run_check "$home" "$out" env FM_PR_CONFLICT_BUDGET_SECS=1 \
    FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=10 FM_PR_CONFLICT_UNKNOWN_WAIT=5
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] || fail "the reread loop ran past the sweep deadline: ${elapsed}s"
  [ ! -s "$out" ] || fail "an unsettled pull request must stay silent: $(cat "$out")"
  pass "UNKNOWN rereads stop at the sweep deadline"
}

test_clean_fleet_is_silent() {
  local home out
  home=$(make_home wake-clean)
  write_list "$home" "$REPO_A" "[{\"number\":7,\"title\":\"Fine\",\"url\":\"https://github.com/$REPO_A/pull/7\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":false,\"mergeable\":\"MERGEABLE\"}]"
  write_list "$home" "$REPO_B" '[]'
  out="$home/out.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "clean fleet should print nothing: $(cat "$out")"
  pass "clean fleet output is empty"
}

test_draft_conflicts_are_reported() {
  local home out
  home=$(make_home wake-draft)
  write_list "$home" "$REPO_B" "[{\"number\":3,\"title\":\"Draft broken\",\"url\":\"https://github.com/$REPO_B/pull/3\",\"headRefOid\":\"$HEAD_ONE\",\"isDraft\":true,\"mergeable\":\"CONFLICTING\"}]"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "draft=yes" "draft conflict must be marked"
  assert_contains "$(cat "$out")" "owner-team=team-b" "draft repo routes to owning team"
  pass "conflicted draft PRs are reported"
}

test_arm_registers_check() {
  local home out status=0
  home=$(make_home arm)
  env FM_HOME="$home" FM_ROOT="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_STATE_OVERRIDE="$home/state" \
    PATH="$home/fakebin:$BASE_PATH" "$WATCH" arm >"$home/arm.out" 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/pr-conflict-watch.check.sh" "arm must write check shim"
  assert_present "$home/state/pr-conflict-watch.check-trust" "arm must bind trust"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-check-register.sh" pr-conflict-watch >/dev/null \
    || fail "trust binding must match shim bytes"
  pass "arm writes and registers the watcher check"
}

test_newly_conflicted_wakes
test_same_head_stays_silent
test_new_head_after_force_update_wakes_again
test_unknown_never_reported
test_unknown_resolving_to_conflicting_wakes
test_unknown_wake_uses_the_head_the_reread_judged
test_conflicts_past_the_line_cap_wake_on_a_later_sweep
test_resolved_conflicts_leave_the_record
test_empty_discovery_keeps_the_record
test_unknown_rereads_stop_at_the_sweep_deadline
test_clean_fleet_is_silent
test_draft_conflicts_are_reported
test_arm_registers_check
