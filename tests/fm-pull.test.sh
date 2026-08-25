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

test_lowercase_compatibility_markers_refuse_pull() {
  local home out rc=0
  home=$(make_home lowercase-markers)
  (cd "$home" && tasks-axi add deferred-task "deferred until migration" --kind ship --repo demo --priority 1 >/dev/null)
  (cd "$home" && tasks-axi add unauthorized-task "not authorized by captain" --kind ship --repo demo --priority 1 >/dev/null)
  (cd "$home" && tasks-axi add declined-task "do not chase this" --kind ship --repo demo --priority 1 >/dev/null)
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" ready --json)
  printf '%s' "$out" | jq -e '
    (.pull.eligible | length) == 0
    and ([.pull.ineligible[] | select(.id == "deferred-task" or .id == "unauthorized-task" or .id == "declined-task") | .pull_reason]
      | length == 3 and all(. == "migration_required"))
  ' >/dev/null || fail "lowercase compatibility markers remained pull-eligible: $out"
  mkdir -p "$home/data/deferred-task"
  printf '# brief\n' > "$home/data/deferred-task/brief.md"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start deferred-task "$ROOT" \
    --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "lowercase deferred task was started"
  assert_contains "$out" 'not eligible for local pull' "lowercase deferred start refusal was not explicit"
  assert_grep 'deferred-task' "$home/data/backlog.md" "lowercase deferred refusal removed the queued task"
  assert_absent "$home/state/deferred-task.meta" "lowercase deferred refusal published metadata"
  pass "lowercase compatibility markers remain ineligible for pull"
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

test_unreadable_inventory_fails_closed() {
  local home fifo_home hidden_home linked_home out rc=0
  home=$(make_home unreadable)
  ln -s "$home/state/missing-target" "$home/state/broken.meta"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --local-json)
  printf '%s' "$out" | jq -e '.attention.valid == false' >/dev/null \
    || fail "dangling worker metadata was reported as a complete inventory: $out"
  fifo_home=$(make_home unreadable-fifo)
  mkfifo "$fifo_home/state/broken.meta"
  out=$(FM_HOME="$fifo_home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --local-json)
  printf '%s' "$out" | jq -e '.attention.valid == false' >/dev/null \
    || fail "non-regular worker metadata was reported as a complete inventory: $out"
  linked_home=$(make_home unreadable-linked)
  printf 'kind=ship\n' > "$linked_home/state/worker-record"
  ln -s "$linked_home/state/worker-record" "$linked_home/state/worker.meta"
  out=$(FM_HOME="$linked_home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --local-json)
  printf '%s' "$out" | jq -e '.attention.valid == false' >/dev/null \
    || fail "resolved metadata symlink was reported as a complete inventory: $out"
  hidden_home=$(make_home unreadable-hidden)
  printf 'kind=ship\n' > "$hidden_home/state/.worker.meta"
  mkdir -p "$hidden_home/data/queued-task"
  printf '# brief\n' > "$hidden_home/data/queued-task/brief.md"
  add_task "$hidden_home" queued-task 1
  out=$(FM_HOME="$hidden_home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-fleet-snapshot.sh" --local-json)
  printf '%s' "$out" | jq -e '.attention.valid == false' >/dev/null \
    || fail "hidden metadata identity was omitted from inventory validation: $out"
  rc=0
  out=$(FM_HOME="$hidden_home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start queued-task "$ROOT" \
    --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "pull admitted an inventory containing hidden metadata"
  assert_contains "$out" 'attention facts are invalid' "pull did not fail closed on hidden metadata"
  assert_absent "$hidden_home/state/queued-task.meta" "hidden metadata refusal published task metadata"
  mkdir -p "$home/data/direct" "$home/data/batch"
  printf '# brief\n' > "$home/data/direct/brief.md"
  printf '# brief\n' > "$home/data/batch/brief.md"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" direct "$ROOT" \
    --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "direct spawn admitted an incomplete worker inventory"
  assert_contains "$out" 'attention facts are invalid' "direct spawn did not fail closed on inventory"
  rc=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" \
    "batch=$ROOT" --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "batch spawn admitted an incomplete worker inventory"
  assert_contains "$out" 'attention facts are invalid' "batch child bypassed the inventory guard"
  pass "snapshot, direct spawn, and batch spawn fail closed on incomplete inventory"
}

test_spawn_backstops_refuse_at_four() {
  local home out rc=0
  home=$(make_home spawn-cap)
  write_reservations "$home" 4
  mkdir -p "$home/data/direct-cap" "$home/data/batch-cap"
  printf '# brief\n' > "$home/data/direct-cap/brief.md"
  printf '# brief\n' > "$home/data/batch-cap/brief.md"
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" direct-cap "$ROOT" \
    --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "direct fresh spawn admitted a fifth worker"
  assert_contains "$out" 'attention limit reached' "direct fresh spawn did not enforce the hard-four backstop"
  assert_absent "$home/state/direct-cap.meta" "direct cap refusal published task metadata"
  rc=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" \
    "batch-cap=$ROOT" --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "batch fresh spawn admitted a fifth worker"
  assert_contains "$out" 'attention limit reached' "batch fresh spawn did not enforce the hard-four backstop"
  assert_absent "$home/state/batch-cap.meta" "batch cap refusal published task metadata"
  pass "direct and batch fresh spawn enforce the hard-four backstop"
}

test_same_id_reservation_retry() {
  local home out rc=0
  home=$(make_home retry)
  write_reservations "$home" 3
  mkdir -p "$home/data/retry-task"
  printf '# brief\n' > "$home/data/retry-task/brief.md"
  add_task "$home" retry-task 1
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start retry-task \
    "$home/missing-project" --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "fixture spawn unexpectedly succeeded"
  assert_grep 'retry-task' "$home/data/backlog.md" "failed spawn did not retain its reservation"
  rc=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start retry-task \
    "$home/missing-project" --mode no-mistakes --yolo off --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "retry fixture spawn unexpectedly succeeded"
  assert_contains "$out" 'resuming unknown reservation retry-task' "same-id retry was refused as a fifth worker"
  pass "same-id retries resume their visible reservation"
}

test_two_concurrent_starts_at_three() {
  local home fakebin real_tasks pid_a pid_b inflight i
  home=$(make_home concurrent)
  write_reservations "$home" 3
  for id in a-task b-task; do
    mkdir -p "$home/data/$id"
    printf '# brief\n' > "$home/data/$id/brief.md"
    add_task "$home" "$id" 1
  done
  fakebin=$(fm_fakebin "$home/fake")
  real_tasks=$(command -v tasks-axi)
  cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = start ] && [ "${2:-}" = a-task ]; then
  "$FM_REAL_TASKS_AXI" "$@" || exit $?
  touch "$FM_CONCURRENT_ENTERED"
  while [ ! -f "$FM_CONCURRENT_RELEASE" ]; do sleep 0.01; done
  exit 0
fi
exec "$FM_REAL_TASKS_AXI" "$@"
SH
  chmod +x "$fakebin/tasks-axi"
  PATH="$fakebin:$PATH" FM_REAL_TASKS_AXI="$real_tasks" \
    FM_CONCURRENT_ENTERED="$home/a.entered" FM_CONCURRENT_RELEASE="$home/a.release" \
    FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start a-task \
    "$home/missing-project" --mode no-mistakes --yolo off --harness pi >"$home/a.out" 2>&1 & pid_a=$!
  i=0
  while [ ! -f "$home/a.entered" ] && [ "$i" -lt 500 ]; do sleep 0.01; i=$((i + 1)); done
  [ -f "$home/a.entered" ] || fail "first concurrent start did not reserve while holding the task-set lock"
  FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-pull.sh" start b-task \
    "$home/missing-project" --mode no-mistakes --yolo off --harness pi >"$home/b.out" 2>&1 & pid_b=$!
  wait "$pid_b" 2>/dev/null || true
  touch "$home/a.release"
  wait "$pid_a" 2>/dev/null || true
  inflight=$(awk '/^## In flight/{inside=1;next}/^## /{inside=0} inside && /^- \[ \] (a-task|b-task) /{n++} END{print n+0}' "$home/data/backlog.md")
  [ "$inflight" -eq 1 ] || fail "concurrent starts created $inflight reservations instead of one"
  pass "two concurrent starts at count three reserve only one slot"
}

test_nested_secondmate_refusals() {
  local home peer out rc=0
  home=$(make_home nested)
  peer=$(make_home nested-peer)
  mkdir -p "$home/bin" "$peer/bin"
  printf '# Firstmate\n' > "$home/AGENTS.md"
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
  rc=0
  out=$(FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" "$ROOT/bin/fm-spawn.sh" nested "$home" --secondmate --harness pi 2>&1) || rc=$?
  [ "$rc" -ne 0 ] || fail "nested home spawned a secondmate endpoint for itself"
  assert_contains "$out" 'only the primary home' "same-home nested spawn refusal was not explicit"
  pass "secondmate homes cannot create nested secondmates"
}

test_ready_priority_and_reasons
test_lowercase_compatibility_markers_refuse_pull
test_start_refuses_at_four_before_mutation
test_snapshot_attention_and_local_mode
test_unreadable_inventory_fails_closed
test_spawn_backstops_refuse_at_four
test_same_id_reservation_retry
test_two_concurrent_starts_at_three
test_nested_secondmate_refusals

echo "ALL TESTS PASSED"
