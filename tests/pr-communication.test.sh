#!/usr/bin/env bash
# Public-interface tests for the vendored CEO-overview PR communication gate.
#
# Rules live in scripts/pr-communication/prCommunication.ts (lalo-admin SoT).
# This file drives the checker and drift entrypoints as executables and never
# asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIFT="$ROOT/scripts/pr-communication/check-drift.mjs"
CHECK="$ROOT/scripts/check-pr-communication.ts"
UNIT="$ROOT/scripts/check-pr-communication.test.ts"
FETCH_FIXTURE="$ROOT/tests/fixtures/pr-communication-fetch.mjs"
TEMPLATE="$ROOT/.github/PULL_REQUEST_TEMPLATE.md"

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node is required to run the PR communication gate"
  exit 0
fi

complete_body() {
  cat <<'EOF'
## CEO overview

- **What is changing:** Members can see the status of their submitted requests.
- **Why it matters:** It reduces support messages asking for updates.
- **Customer or business impact:** Members get clearer communication and the team saves time.
- **Risk and rollout:** Low risk. Release through staging and confirm the main request flow.

## Validation

- **Checks passed:** Unit tests and type check.
- **Checks not run:** End-to-end test was not run locally.
- **Evidence and limitations:** Tested with a representative request.

## Module-boundary decision

Current module retained: request status rendering belongs with the existing member request page module.

## Decision needed

No decision required.
EOF
}

incomplete_body() {
  cat <<'EOF'
## Summary
This is a quick change.
EOF
}

test_missing_remote_token_fails_closed() {
  local out rc
  set +e
  out=$(
    env -u PR_COMMUNICATION_SOT_TOKEN \
      -u PR_COMMUNICATION_REQUIRE_REMOTE_SOT \
      GITHUB_TOKEN=ghs_not_a_sot_token GH_TOKEN=ghs_not_a_sot_token \
      node "$DRIFT" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "missing remote credential"
  assert_contains "$out" "Local pin OK" "drift check did not confirm the local SoT pin"
  assert_contains "$out" "PR_COMMUNICATION_SOT_TOKEN is required" \
    "missing remote credential did not explain the fail-closed result"
  pass "missing SOT token fails closed even when GITHUB_TOKEN is set"
}

test_vendored_unit_suite() {
  local out rc
  set +e
  out=$(node --experimental-strip-types --test "$UNIT" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "vendored pr-communication unit suite"
  pass "vendored pr-communication unit suite passes"
}

test_cli_rejects_incomplete_description() {
  local out rc
  set +e
  out=$(
    PR_TITLE='WIP' PR_BODY="$(incomplete_body)" \
      node --experimental-strip-types "$CHECK" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "incomplete PR description"
  assert_contains "$out" "Cannot enter staging until completed:" \
    "incomplete description did not use the proven failure prefix"
  assert_contains "$out" "CEO overview: What is changing" \
    "incomplete description did not require What is changing"
  assert_contains "$out" "CEO overview: Why it matters" \
    "incomplete description did not require Why it matters"
  assert_contains "$out" "CEO overview: Customer or business impact" \
    "incomplete description did not require Customer or business impact"
  assert_contains "$out" "CEO overview: Risk and rollout" \
    "incomplete description did not require Risk and rollout"
  assert_contains "$out" "Decision needed" \
    "incomplete description did not require Decision needed"
  assert_contains "$out" "Module-boundary decision" \
    "incomplete description did not require Module-boundary decision"
  assert_contains "$out" "Validation: Checks passed" \
    "incomplete description did not require Validation: Checks passed"
  pass "CLI fails a non-compliant PR description"
}

test_cli_rejects_untouched_module_boundary_template() {
  local out rc
  set +e
  out=$(
    PR_TITLE='Describe a complete customer-facing change' PR_BODY="$(cat "$TEMPLATE")" \
      node --experimental-strip-types "$CHECK" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "untouched PR template"
  assert_contains "$out" "Module-boundary decision" \
    "untouched template guidance incorrectly satisfied Module-boundary decision"
  pass "CLI rejects untouched module-boundary template guidance"
}

test_transient_remote_failure_uses_local_pin() {
  local mode out rc
  for mode in network 408 429 503; do
    set +e
    out=$(PR_COMMUNICATION_FETCH_FAILURE="$mode" PR_COMMUNICATION_SOT_TOKEN=test-token \
      node --import "$FETCH_FIXTURE" "$DRIFT" 2>&1)
    rc=$?
    set -e
    expect_code 0 "$rc" "transient remote failure ($mode)"
    assert_contains "$out" "Using the verified local pin" \
      "transient remote failure ($mode) did not fall back to the local pin"
  done
  pass "transient remote failures use the local pin"
}

test_required_remote_failure_fails_closed() {
  local out rc
  set +e
  out=$(
    PR_COMMUNICATION_FETCH_FAILURE=503 PR_COMMUNICATION_SOT_TOKEN=test-token \
      PR_COMMUNICATION_REQUIRE_REMOTE_SOT=1 \
      node --import "$FETCH_FIXTURE" "$DRIFT" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "required remote failure"
  assert_contains "$out" "503" "required remote failure did not report its status"
  pass "required remote failures fail closed"
}

test_auth_remote_failure_fails_closed() {
  local mode out rc
  for mode in 401 403 404; do
    set +e
    out=$(PR_COMMUNICATION_FETCH_FAILURE="$mode" PR_COMMUNICATION_SOT_TOKEN=invalid \
      node --import "$FETCH_FIXTURE" "$DRIFT" 2>&1)
    rc=$?
    set -e
    expect_code 1 "$rc" "remote authentication failure ($mode)"
    assert_contains "$out" "$mode" \
      "remote authentication failure ($mode) did not report its status"
  done
  pass "401, 403, and 404 remote failures fail closed"
}

test_cli_accepts_complete_description() {
  local out rc
  set +e
  out=$(
    PR_TITLE='Show members the status of their requests' \
      PR_BODY="$(complete_body)" \
      node --experimental-strip-types "$CHECK" 2>&1
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "complete PR description"
  assert_contains "$out" "PR communication is complete." \
    "complete description did not report success"
  pass "CLI passes a compliant PR description"
}

test_missing_remote_token_fails_closed
test_vendored_unit_suite
test_cli_rejects_incomplete_description
test_cli_rejects_untouched_module_boundary_template
test_cli_accepts_complete_description
test_transient_remote_failure_uses_local_pin
test_required_remote_failure_fails_closed
test_auth_remote_failure_fails_closed
