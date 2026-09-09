#!/usr/bin/env bash
# Run from the supplied worktree. Uses real git repositories and the existing fake-run harness.
python3 - <<'SETUP'
from pathlib import Path
import subprocess
root = Path.cwd()
base = root / 'bin/.test-phase-base-crew-state.sh'
base.write_bytes(subprocess.check_output(['git', 'show', '1b670148d987147261d8617e5194c35dab54302e:bin/fm-crew-state.sh']))
base.chmod(0o755)
source = (root / 'tests/fm-crew-state.test.sh').read_text()
(root / 'tests/.test-phase-harness.sh').write_text(source.split('\ntest_active_run_is_authoritative\n')[0])
SETUP
. tests/.test-phase-harness.sh
trap 'fm_test_cleanup; rm -f "$ROOT/tests/.test-phase-harness.sh" "$ROOT/bin/.test-phase-base-crew-state.sh"' EXIT
export GIT_AUTHOR_DATE='2026-09-08T10:00:00Z' GIT_COMMITTER_DATE='2026-09-08T10:00:00Z'
printf 'Regression assertion against pre-fix classifier (expected failure):\n'
(TMP_ROOT="$TMP_ROOT/pre-fix"; CREW_STATE="$ROOT/bin/.test-phase-base-crew-state.sh"; test_active_same_branch_unavailable_pipeline_head_outranks_historical_failure)
rc=$?
[ "$rc" = 1 ] || fail 'regression must fail before the fix'
printf '\nRegression assertion against target classifier:\n'
test_active_same_branch_unavailable_pipeline_head_outranks_historical_failure

printf '\nPublic CLI and persisted reconciliation behavior:\n'
for version in base target; do
  reset_fakes
  d=$(new_case "e2e-$version")
  id=lalo-launch-offers-member-billing
  branch=fm/member-billing
  make_repo_on_branch "$d/wt" "$branch"
  local_head=$FM_FAKE_RUN_HEAD
  make_fakebin "$d" >/dev/null
  mkdir -p "$d/data" "$d/config"
  fm_write_meta "$d/state/$id.meta" "window=fm:fm-$id" "worktree=$d/wt" 'kind=ship' 'harness=claude' 'spawn_gen=test-live-run'
  printf 'working: member billing validation in progress\n' > "$d/state/$id.status"
  touch -d '5 minutes ago' "$d/state/$id.meta" "$d/state/$id.status"
  FM_FAKE_RUN_HEAD=44b15c94
  git -C "$d/wt" rev-parse --verify "${FM_FAKE_RUN_HEAD}^{commit}" >/dev/null 2>&1 && fail 'pipeline head unexpectedly present'
  FM_FAKE_AXI_STATUS="$(run_parked "$branch")"
  FM_FAKE_RUNS_LIST="failed    $branch ${local_head:0:8}  2026-09-08 10:00"
  CREW_STATE="$ROOT/bin/fm-crew-state.sh"
  [ "$version" = base ] && CREW_STATE="$ROOT/bin/.test-phase-base-crew-state.sh"
  printf '\n%s: task=%s local_HEAD=%s pipeline_HEAD=%s (unavailable)\n' "$version" "$id" "$local_head" "$FM_FAKE_RUN_HEAD"
  printf 'fake no-mistakes axi status:\n%s\nfake no-mistakes runs:\n%s\n' "$FM_FAKE_AXI_STATUS" "$FM_FAKE_RUNS_LIST"
  printf '$ bin/fm-crew-state.sh %s\n' "$id"
  out=$(run_crew_state "$d" "$id")
  printf '%s\n' "$out"
  printf '$ bin/fm-inactive-reconcile.sh scan --startup\n'
  PATH="$d/fakebin:$PATH" FM_HOME="$d" FM_STATE_OVERRIDE="$d/state" FM_DATA_OVERRIDE="$d/data" FM_CONFIG_OVERRIDE="$d/config" FM_INACTIVE_CREW_STATE_BIN="$CREW_STATE" FM_INACTIVE_RECONCILE_SECS=60 "$ROOT/bin/fm-inactive-reconcile.sh" scan --startup || fail 'scan failed'
  printf 'Persisted terminal records:\n'
  records=$(find "$d/state/terminal-outcomes" -type f 2>/dev/null || true)
  if [ -n "$records" ]; then
    while IFS= read -r file; do cat "$file"; done <<< "$records"
  else printf '(none)\n'; fi
  if [ "$version" = base ]; then
    assert_contains "$out" 'state: failed' 'base exposes historical failure'
    [ -n "$records" ] || fail 'base must demonstrate false terminal notice'
  else
    assert_contains "$out" 'state: parked' 'target keeps current run'
    [ -z "$records" ] || fail 'target emitted false terminal notice'
  fi
 done

printf '\nActive-only exception matrix through public CLI:\n'
reset_fakes
d=$(new_case active-matrix)
make_repo_on_branch "$d/wt" fm/matrix
make_fakebin "$d" >/dev/null
fm_write_meta "$d/state/matrix.meta" 'window=fm:fm-matrix' "worktree=$d/wt" 'kind=ship' 'harness=claude'
printf 'working: current local stage\n' > "$d/state/matrix.status"
arm_idle_record "$d/state" matrix
CREW_STATE="$ROOT/bin/fm-crew-state.sh"
for status in running fixing ci awaiting_approval fix_review completed failed cancelled passed checks-passed; do
  FM_FAKE_AXI_STATUS=$(printf 'run:\n  id: "01RUN"\n  branch: fm/matrix\n  status: %s\n  head: "44b15c94"\n  findings: none\n' "$status")
  out=$(run_crew_state "$d" matrix)
  printf '%s => %s\n' "$status" "$out"
  case "$status" in
    running|fixing|ci|awaiting_approval|fix_review) assert_contains "$out" 'source: run-step' 'active unavailable-head run accepted' ;;
    *) assert_contains "$out" 'source: status-log' 'terminal unavailable-head run rejected' ;;
  esac
 done
printf '\nAdjacent head safety and proven descendant path:\n'
test_historical_same_branch_rewritten_head_not_current
test_active_run_descendant_fix_head_remains_current
test_local_advanced_past_run_head_invalidates
test_missing_run_head_falls_back_to_current_state
