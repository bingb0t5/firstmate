#!/usr/bin/env bash
# Pull, priority, attention, and nested-domain safety contracts.
set -u
# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-pull)

make_home() {
  local home=$TMP_ROOT/$1
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
  printf '%s\n' "$home"
}

add_task() {
  local home=$1 id=$2 priority=$3 kind=${4:-ship}
  (cd "$home" && tasks-axi add "$id" "$id title" --kind "$kind" --repo demo --priority "$priority" >/dev/null)
}

write_reservations() {
  local home=$1 count=$2 i
  {
    printf '## In flight\n'
    i=1
    while [ "$i" -le "$count" ]; do
      printf -- '- [ ] reservation-%s - reserved (kind: ship) (priority: 1)\n' "$i"
      i=$((i + 1))
    done
    printf '## Queued\n## Done\n'
  } > "$home/data/backlog.md"
}

test_ready_priority_and_reasons() {
  local home out
  home=$(make_home ready)
  add_task "$home" low 4
  add_task "$home" urgent 0
  add_task "$home" normal 2
  (cd "$home" && tasks-axi add missing "missing title" --kind ship --repo demo >/dev/null)
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" ready --json)
  printf '%s' "$out" | jq -e '
    .schema == "fm-pull.v1"
    and [.pull.eligible[].id] == ["urgent", "normal", "low"]
    and ([.pull.ineligible[] | select(.id == "missing") | .pull_reason] == ["missing_priority"])
  ' >/dev/null || fail "ready did not apply mechanical priority order and missing-priority refusal: $out"
  pass "ready orders by priority and exposes missing-priority rows"
}

test_start_refuses_at_four_before_mutation() {
  local home out rc=0
  home=$(make_home cap)
  write_reservations "$home" 4
  mkdir -p "$home/data/fifth"
  printf '# brief\n' > "$home/data/fifth/brief.md"
  (cd "$home" && tasks-axi add fifth "fifth title" --kind ship --repo demo --priority 1 >/dev/null)
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" \
    start fifth "$ROOT" --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "start succeeded at the hard-four limit"
  assert_contains "$out" 'attention limit reached' "start did not report the hard-four refusal"
  assert_grep 'fifth' "$home/data/backlog.md" "refused start changed the queued backlog"
  assert_absent "$home/state/fifth.meta" "refused start published metadata"
  pass "start refuses a fifth worker before backlog or launch side effects"
}

test_snapshot_attention_and_local_mode() {
  local home out
  home=$(make_home attention)
  write_reservations "$home" 4
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --local-json)
  printf '%s' "$out" | jq -e '.local == true and .attention.limit == 4 and .attention.count == 4 and .attention.remaining == 0 and (.secondmate_current | not)' >/dev/null \
    || fail "local snapshot did not expose bounded attention facts: $out"
  pass "local snapshot reports attention without cross-home aggregation"
}

test_nested_secondmate_refusals() {
  local home peer out rc=0
  home=$(make_home nested)
  peer=$(make_home nested-peer)
  mkdir -p "$peer/bin"
  printf '# Firstmate\n' > "$peer/AGENTS.md"
  printf 'child\n' > "$peer/.fm-secondmate-home"
  printf 'nested\n' > "$home/.fm-secondmate-home"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-home-seed.sh" child - --no-projects 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "nested home seed succeeded"
  assert_contains "$out" 'only the primary home' "nested seed refusal was not explicit"
  rc=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" child "$peer" --secondmate --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "nested secondmate spawn succeeded"
  assert_contains "$out" 'only the primary home' "nested spawn refusal was not explicit"
  pass "secondmate homes cannot create nested secondmates"
}

test_ready_priority_and_reasons
test_start_refuses_at_four_before_mutation
test_snapshot_attention_and_local_mode
test_nested_secondmate_refusals

echo "ALL TESTS PASSED"
