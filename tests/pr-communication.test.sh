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

if ! command -v node >/dev/null 2>&1; then
  echo "skip: node is required to run the PR communication gate"
  exit 0
fi

if ! command -v npx >/dev/null 2>&1; then
  echo "skip: npx is required to run the PR communication gate"
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

test_local_pin_passes_without_remote_token() {
  local out rc
  set +e
  out=$(
    env -u PR_COMMUNICATION_SOT_TOKEN -u GITHUB_TOKEN -u GH_TOKEN \
      -u PR_COMMUNICATION_REQUIRE_REMOTE_SOT \
      node "$DRIFT" 2>&1
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "offline drift check"
  assert_contains "$out" "Local pin OK" "drift check did not confirm the local SoT pin"
  pass "local SoT pin passes without a remote token"
}

test_vendored_unit_suite() {
  local out rc
  set +e
  out=$(npx --yes tsx --test "$UNIT" 2>&1)
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
      npx --yes tsx "$CHECK" 2>&1
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

test_cli_accepts_complete_description() {
  local out rc
  set +e
  out=$(
    PR_TITLE='Show members the status of their requests' \
      PR_BODY="$(complete_body)" \
      npx --yes tsx "$CHECK" 2>&1
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "complete PR description"
  assert_contains "$out" "PR communication is complete." \
    "complete description did not report success"
  pass "CLI passes a compliant PR description"
}

test_local_pin_passes_without_remote_token
test_vendored_unit_suite
test_cli_rejects_incomplete_description
test_cli_accepts_complete_description
