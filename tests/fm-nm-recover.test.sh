#!/usr/bin/env bash
# Behavioral regressions for the terminal no-mistakes custody recovery helper.
#
# The recoverable fixture is a captured structured status from the archived
# second-attempt failure: the run is terminal, pipeline commits remain private,
# and next_action.code explicitly offers recover_custody. The fake CLI is only a
# transport boundary for that public status/command interface; the real helper
# decides whether the guarded sync command may be invoked.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECOVER="$ROOT/bin/fm-nm-recover.sh"
FIXTURE="$ROOT/tests/fixtures/no-mistakes-custody-recoverable-status.toon"
TMP_ROOT=$(fm_test_tmproot fm-nm-recover)

make_case() {  # <name>
  local name=$1 root repo fakebin
  root="$TMP_ROOT/$name"
  repo="$root/repo"
  fakebin="$root/bin"
  mkdir -p "$fakebin"
  fm_git_init_commit "$repo"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_NM_CALL_LOG"
if [ "${1:-}" = axi ] && [ "${2:-}" = status ]; then
  cat "$FM_NM_FIXTURE"
  exit "${FM_NM_STATUS_RC:-0}"
fi
if [ "${1:-}" = axi ] && [ "${2:-}" = sync ] && [ "${3:-}" = --recover ]; then
  printf 'custody returned; the branch is yours\n'
  exit "${FM_NM_SYNC_RC:-0}"
fi
printf 'unexpected no-mistakes command: %s\n' "$*" >&2
exit 64
SH
  chmod +x "$fakebin/no-mistakes"
  printf '%s|%s|%s\n' "$root" "$repo" "$fakebin"
}

run_recover() {  # <repo> <fakebin> <fixture> <call-log>
  local repo=$1 fakebin=$2 fixture=$3 call_log=$4
  ( cd "$repo" &&
    FM_GATE_REFUSE_BYPASS=1 FM_NM_FIXTURE="$fixture" FM_NM_CALL_LOG="$call_log" \
      PATH="$fakebin:$PATH" "$RECOVER" ) 2>&1
}

# The archived terminal status is enough to select the supported command, and
# the command is the only mutating operation the helper may delegate.
test_recover_custody_uses_the_structured_offer() {
  local rec root repo fakebin log out status
  rec=$(make_case offered)
  IFS='|' read -r root repo fakebin <<EOF
$rec
EOF
  log="$root/calls"
  out=$(run_recover "$repo" "$fakebin" "$FIXTURE" "$log")
  status=$?
  expect_code 0 "$status" "recoverable custody offer should succeed"
  assert_contains "$out" "Applying the guarded no-mistakes custody recovery" \
    "recovery did not announce the guarded operation"
  assert_contains "$out" "custody returned" "successful recovery output was lost"
  grep -qx 'axi status' "$log" || fail "recovery did not read structured axi status first"
  grep -qx 'axi sync --recover' "$log" || fail "recovery did not invoke the guarded sync command"
  pass "fm-nm-recover: recover_custody selects guarded axi sync --recover"
}

# A dirty worktree is the preserved-unlanded-work boundary. The helper refuses
# before even asking the CLI to synchronize, so neither tracked edits nor
# untracked files can be discarded by recovery.
test_recovery_refuses_without_touching_unlanded_work() {
  local rec root repo fakebin log out status
  rec=$(make_case dirty)
  IFS='|' read -r root repo fakebin <<EOF
$rec
EOF
  log="$root/calls"
  printf 'captain work not yet committed\n' >> "$repo/README.md"
  printf 'untracked captain work\n' > "$repo/untracked.txt"
  out=$(run_recover "$repo" "$fakebin" "$FIXTURE" "$log")
  status=$?
  [ "$status" -ne 0 ] || fail "dirty recovery unexpectedly succeeded"
  assert_contains "$out" "unlanded work is present" \
    "dirty recovery did not identify the preserved unlanded work"
  assert_contains "$out" "no files or refs were changed" \
    "dirty recovery did not state its no-change boundary"
  assert_absent "$log" "dirty recovery invoked no-mistakes before refusing"
  grep -Fq 'captain work not yet committed' "$repo/README.md" \
    || fail "dirty recovery altered the tracked unlanded work"
  assert_present "$repo/untracked.txt" "dirty recovery removed an untracked file"
  pass "fm-nm-recover: dirty worktree refuses before any custody mutation"
}

# The reproduced failure predates the supported recovery action in some CLI
# versions. It must become a visible, actionable refusal rather than a silent
# dead end or an improvised history edit.
test_recovery_refuses_an_unoffered_action() {
  local rec root repo fakebin fixture log out status
  rec=$(make_case unsupported)
  IFS='|' read -r root repo fakebin <<EOF
$rec
EOF
  fixture="$root/status.toon"
  sed 's/code: recover_custody/code: inspect_and_reconcile_manually/' "$FIXTURE" > "$fixture"
  log="$root/calls"
  out=$(run_recover "$repo" "$fakebin" "$fixture" "$log")
  status=$?
  [ "$status" -ne 0 ] || fail "unsupported custody action unexpectedly succeeded"
  assert_contains "$out" "next_action.code=inspect_and_reconcile_manually" \
    "unsupported recovery did not name the offered action"
  assert_contains "$out" "leave the branch unchanged" \
    "unsupported recovery did not preserve the branch"
  assert_contains "$out" "no-mistakes axi status" \
    "unsupported recovery omitted its actionable next step"
  grep -qx 'axi status' "$log" || fail "unsupported recovery did not inspect structured status"
  assert_no_grep 'axi sync --recover' "$log" \
    "unsupported recovery invoked sync despite no supported offer"
  pass "fm-nm-recover: unsupported custody state refuses with an actionable next step"
}

# A terminal cancellation can release custody before the branch changes. That
# user-owned state is already safe to continue and must not trigger a recovery
# sync merely because the helper was called.
test_recovery_accepts_already_user_owned_state() {
  local rec root repo fakebin fixture log out status
  rec=$(make_case user-owned)
  IFS='|' read -r root repo fakebin <<EOF
$rec
EOF
  fixture="$root/status.toon"
  cat > "$fixture" <<'EOF'
branch_sync:
  state: user_owned
  changed: false
  local:
    branch: fm/custody-fixture
    clean: true
EOF
  log="$root/calls"
  out=$(run_recover "$repo" "$fakebin" "$fixture" "$log")
  status=$?
  expect_code 0 "$status" "user-owned custody should be a no-op"
  assert_contains "$out" "already user-owned" "user-owned state was not explained"
  grep -qx 'axi status' "$log" || fail "user-owned state did not read structured status"
  assert_no_grep 'axi sync --recover' "$log" \
    "user-owned state unnecessarily invoked custody recovery"
  pass "fm-nm-recover: user-owned terminal state proceeds without synchronization"
}

test_recovery_rejects_failed_status_with_user_owned_output() {
  local rec root repo fakebin fixture log out status
  rec=$(make_case failed-user-owned)
  IFS='|' read -r root repo fakebin <<EOF
$rec
EOF
  fixture="$root/status.toon"
  cat > "$fixture" <<'EOF'
branch_sync:
  state: user_owned
  changed: false
  local:
    branch: fm/custody-fixture
    clean: true
EOF
  log="$root/calls"
  out=$(FM_NM_STATUS_RC=23 run_recover "$repo" "$fakebin" "$fixture" "$log")
  status=$?
  [ "$status" -ne 0 ] || fail "failed status with user-owned partial output unexpectedly succeeded"
  assert_contains "$out" "structured status could not be confirmed (exit 23)" \
    "failed status did not refuse before trusting partial output"
  grep -qx 'axi status' "$log" || fail "failed user-owned status was not queried"
  assert_no_grep 'axi sync --recover' "$log" \
    "failed user-owned status invoked custody recovery"
  pass "fm-nm-recover: failed status cannot authorize user-owned custody"
}

test_recover_custody_uses_the_structured_offer
test_recovery_refuses_without_touching_unlanded_work
test_recovery_refuses_an_unoffered_action
test_recovery_accepts_already_user_owned_state
test_recovery_rejects_failed_status_with_user_owned_output
