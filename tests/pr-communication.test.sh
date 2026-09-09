#!/usr/bin/env bash
# Public-interface tests for the vendored CEO-overview PR communication gate
# and Firstmate's CEO overview quality overlay.
#
# Shared template completeness lives in scripts/pr-communication/prCommunication.ts
# (lalo-admin SoT). Firstmate-specific missing/implementation-intent rules live in
# scripts/pr-communication/firstmateCeoOverview.ts.
# This file drives the checker and drift entrypoints as executables and never
# asserts implementation-source bytes.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

DRIFT="$ROOT/scripts/pr-communication/check-drift.mjs"
CHECK="$ROOT/scripts/check-pr-communication.ts"
FIRSTMATE_CHECK="$ROOT/scripts/check-firstmate-ceo-overview.ts"
UNIT="$ROOT/scripts/check-pr-communication.test.ts"
FIRSTMATE_UNIT="$ROOT/scripts/check-firstmate-ceo-overview.test.ts"
FETCH_FIXTURE="$ROOT/tests/fixtures/pr-communication-fetch.mjs"
TEMPLATE="$ROOT/.github/PULL_REQUEST_TEMPLATE.md"
TRACKED_BODY_DIR="$ROOT/.github/pr-bodies"
EVIDENCE_BODY_DIR="$ROOT/tests/fixtures/pr-communication/bodies"
BODY_COMPOSER="$ROOT/bin/fm-pr-body-compose.sh"
PREFLIGHT="$ROOT/bin/fm-nm-pr-preflight.sh"
NO_MISTAKES_WORKFLOW="$ROOT/.github/workflows/no-mistakes-required.yml"

if ! command -v node >/dev/null 2>&1 || ! command -v python3 >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
  echo "skip: node, python3, and jq are required to run the PR communication gates"
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

pipeline_generated_body() {
  cat <<'EOF'
## Intent

Keep the fleet snapshot working once the fleet outgrows the argument size limit.

## What Changed

- The snapshot hands large payloads to its helper through files instead of one long command line.

## Risk Assessment

Low: the transport changes, the produced document does not.

## Testing

The reproduction, the counterfactual, and the focused regressions all pass.
EOF
}

pipeline_section() {
  cat <<'EOF'

## Pipeline

Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)

<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0000000000000000000000000000000000000000","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->
EOF
}

preflight_case() {
  PF_ROOT=$(fm_test_tmproot fm-pr-preflight)
  mkdir -p "$PF_ROOT/bin"
  fm_git_init_commit "$PF_ROOT/repo"
  git -C "$PF_ROOT/repo" checkout -qb fm/preflight
  {
    complete_body
    printf '\n## What changed technically\n\nRender request status in the existing member page.\n'
  } > "$PF_ROOT/intent.md"
  printf '[]\n' > "$PF_ROOT/pulls.json"
  cat > "$PF_ROOT/bin/gh-axi" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$@" >> "$PF_ROOT/calls"
[ "$1" = api ] && [ "$2" = GET ] && [ "$3" = /repos/o/r/pulls ] || exit 91
host=${GH_HOST:-github.com}
shift 3
while [ "$#" -gt 0 ]; do
  case "$1" in
    --hostname) host=$2; shift ;;
    --hostname=*) host=${1#--hostname=} ;;
  esac
  shift
done
printf '%s\n' "$host" >> "$PF_ROOT/hosts"
if [ "$host" != github.com ]; then
  printf 'api_response:\n  body: W10=\n  truncated: false\n'
  exit 0
fi
[ "${PF_TRANSPORT:-}" != error ] || exit 22
if [ "${PF_TRANSPORT:-}" = malformed ]; then
  printf 'api_response:\n  body: W10=\n  truncated: true\n'
  exit 0
fi
node -e 'const fs=require("node:fs"); console.log("api_response:\n  body: "+Buffer.from(fs.readFileSync(process.env.PF_ROOT+"/pulls.json")).toString("base64")+"\n  truncated: false")'
SH
  chmod +x "$PF_ROOT/bin/gh-axi"
  export PF_ROOT
}

preflight_run() {
  ( cd "$PF_ROOT/repo" && PATH="$PF_ROOT/bin:$PATH" "$PREFLIGHT" \
    --intent-file "$PF_ROOT/intent.md" --repo o/r --head o:fm/preflight ) \
    > "$PF_ROOT/validated.md" 2> "$PF_ROOT/diagnostic"
}

preflight_live_body() {
  local body_file=$1
  node - "$body_file" "$PF_ROOT/pulls.json" <<'JS'
const fs = require('node:fs');
fs.writeFileSync(process.argv[3], JSON.stringify([{
  title: 'Show members their request status', state: 'open',
  body: fs.readFileSync(process.argv[2], 'utf8'),
  base: { repo: { full_name: 'o/r' } },
  head: { ref: 'fm/preflight', sha: '0000000000000000000000000000000000000000', repo: { owner: { login: 'o' } } },
}]));
JS
}

test_preflight_fresh_intent_survives_generated_body() {
  local rc body out
  preflight_case
  preflight_run; rc=$?
  expect_code 0 "$rc" "fresh PR preflight"
  cmp -s "$PF_ROOT/intent.md" "$PF_ROOT/validated.md" || fail "preflight rewrote task intent"
  grep -qx 'head=o:fm/preflight' "$PF_ROOT/calls" || fail "preflight queried the wrong delivery head"
  # This is the public body shape observed from the legacy publisher. The live
  # no-mistakes delivery proof remains a separate integration check, not a fake
  # publisher implementation hidden in CI.
  body=$(printf '## Intent\n\n'; cat "$PF_ROOT/validated.md"; pipeline_generated_body; pipeline_section)
  for checker in "$CHECK" "$FIRSTMATE_CHECK"; do
    out=$(PR_TITLE='Show request status' PR_BODY="$body" node --experimental-strip-types "$checker" 2>&1)
    rc=$?
    expect_code 0 "$rc" "generated legacy wrapper carrying validated intent: $out"
  done
  pass "preflight returns unchanged fresh intent that passes assessment inside the generated wrapper"
}

test_preflight_rejects_bad_intent_before_forge_read() {
  local mode rc
  for mode in legacy forged technical quoted blockquote indented tab_indented oversize; do
    preflight_case
    case "$mode" in
      legacy) pipeline_generated_body > "$PF_ROOT/intent.md" ;;
      forged) pipeline_section >> "$PF_ROOT/intent.md" ;;
      technical) complete_body > "$PF_ROOT/intent.md" ;;
      quoted)
        complete_body > "$PF_ROOT/intent.md"
        # shellcheck disable=SC2016 # Literal Markdown fences, not shell expansion.
        printf '\n```markdown\n## What changed technically\nOnly quoted evidence.\n```\n' >> "$PF_ROOT/intent.md"
        ;;
      blockquote|indented|tab_indented)
        complete_body > "$PF_ROOT/intent.md"
        printf '\n## What changed technically\n\n' >> "$PF_ROOT/intent.md"
        case "$mode" in
          blockquote) printf '> Only quoted evidence.\n' ;;
          indented) printf '    Only quoted evidence.\n' ;;
          tab_indented) printf '\tOnly quoted evidence.\n' ;;
        esac >> "$PF_ROOT/intent.md"
        ;;
      oversize) node -e 'console.log("x".repeat(16001))' >> "$PF_ROOT/intent.md" ;;
    esac
    preflight_run; rc=$?
    expect_code 2 "$rc" "invalid $mode intent"
    assert_absent "$PF_ROOT/calls" "invalid intent reached the forge"
    [ ! -s "$PF_ROOT/validated.md" ] || fail "invalid intent escaped on stdout"
  done
  pass "preflight refuses invalid or reserved authored content before any forge read"
}

test_preflight_stale_body_refuses_until_owner_reconciles() {
  local rc
  preflight_case
  { pipeline_generated_body; pipeline_section; } > "$PF_ROOT/live.md"
  preflight_live_body "$PF_ROOT/live.md"
  preflight_run; rc=$?
  expect_code 2 "$rc" "stale legacy live body with a complete local intent"
  assert_contains "$(cat "$PF_ROOT/diagnostic")" 'existing live PR body' "stale live source was not identified"
  [ ! -s "$PF_ROOT/validated.md" ] || fail "stale live body released intent for delivery"
  # Simulate the owner having reconciled the forge response. The preflight
  # itself is read-only and never manufactures or publishes this fixture.
  "$BODY_COMPOSER" "$PF_ROOT/intent.md" "$PF_ROOT/live.md" > "$PF_ROOT/reconciled.md"
  preflight_live_body "$PF_ROOT/reconciled.md"
  preflight_run; rc=$?
  expect_code 0 "$rc" "reconciled live body"
  cmp -s "$PF_ROOT/intent.md" "$PF_ROOT/validated.md" || fail "recovery changed intent"
  [ "$(grep -c '^GET$' "$PF_ROOT/calls")" -eq 2 ] || fail "preflight did not reread live data on recovery"
  pass "a local sidecar cannot hide stale live prose; owner reconciliation permits a fresh read"
}

test_preflight_refuses_stale_or_forged_pipeline_data() {
  local mode rc
  for mode in stale duplicate quoted missing_signature incomplete malformed_status; do
    preflight_case
    { cat "$PF_ROOT/intent.md"; pipeline_section; } > "$PF_ROOT/live.md"
    case "$mode" in
      stale) sed 's/0000000000000000000000000000000000000000/1111111111111111111111111111111111111111/' "$PF_ROOT/live.md" > "$PF_ROOT/changed.md" ;;
      duplicate) { cat "$PF_ROOT/live.md"; pipeline_section; } > "$PF_ROOT/changed.md" ;;
      quoted) { cat "$PF_ROOT/intent.md"; printf '\n```markdown\n'; pipeline_section; printf '\n```\n'; } > "$PF_ROOT/changed.md" ;;
      missing_signature) sed '/^Updates from /d' "$PF_ROOT/live.md" > "$PF_ROOT/changed.md" ;;
      incomplete) sed 's/"status":"completed"/"status":"pending"/g' "$PF_ROOT/live.md" > "$PF_ROOT/changed.md" ;;
      malformed_status) sed 's/"step":"test","status":"completed"/"step":"test","status":"com`pending`pleted"/' "$PF_ROOT/live.md" > "$PF_ROOT/changed.md" ;;
    esac
    preflight_live_body "$PF_ROOT/changed.md"
    preflight_run; rc=$?
    expect_code 2 "$rc" "$mode pipeline data"
    if [ "$mode" = malformed_status ]; then
      assert_contains "$(cat "$PF_ROOT/diagnostic")" 'lacks completed required pipeline steps' "malformed status did not reach unchanged step validation"
    fi
    [ ! -s "$PF_ROOT/validated.md" ] || fail "$mode pipeline data released intent"
  done
  pass "preflight rejects stale heads, ambiguous or quoted attestations, and incomplete pipeline evidence"
}

test_preflight_preserves_comment_boundaries_and_step_types() {
  local mode rc out
  for mode in embedded_comments early_terminator numeric_step string_step boolean_step null_step array_step; do
    preflight_case
    node - "$PF_ROOT/intent.md" "$PF_ROOT/live.md" "$mode" <<'JS'
const fs = require('node:fs');
const mode = process.argv[4];
const steps = ['review', 'test', 'document'].map(step => ({ step, status: 'completed' }));
const attestation = { head_sha: '0'.repeat(40), steps };
if (mode === 'embedded_comments' || mode === 'early_terminator') {
  attestation.note = ' -->';
  if (mode === 'embedded_comments') steps[1].status = 'com<!--pending-->pleted';
} else {
  const entries = { numeric_step: 0, string_step: 'test', boolean_step: false, null_step: null, array_step: [] };
  steps.unshift(entries[mode]);
}
const json = JSON.stringify(attestation, ['note', 'head_sha', 'steps', 'step', 'status']);
fs.writeFileSync(process.argv[3], fs.readFileSync(process.argv[2], 'utf8') +
  '\n## Pipeline\n\nUpdates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)\n\n' +
  '<!-- no-mistakes-pipeline-attestation:v1 ' + json + ' -->\n');
JS
    preflight_live_body "$PF_ROOT/live.md"
    preflight_run; rc=$?
    expect_code 2 "$rc" "$mode pipeline evidence"
    [ ! -s "$PF_ROOT/validated.md" ] || fail "$mode pipeline evidence released intent"
    case "$mode" in
      null_step) ;;
      *)
        out=$(PR_BODY="$(cat "$PF_ROOT/live.md")" PR_AUTHOR='fixture' PR_NUMBER=0 run_no_mistakes_requirement 2>&1); rc=$?
        [ "$rc" -ne 0 ] || fail "hosted consumer unexpectedly accepted $mode: $out"
        ;;
    esac
  done
  pass "original comment boundaries and object-only steps prevent malformed evidence from authorizing delivery"
}

test_preflight_rejects_quoted_pipeline_evidence() {
  local style evidence prefix suffix rc
  for style in blockquote nested_blockquote indented tab_indented mixed_tab single_backtick double_backtick triple_backtick mixed_backticks; do
    suffix=''
    case "$style" in
      blockquote) prefix='> ' ;;
      nested_blockquote) prefix='   > > ' ;;
      indented) prefix='    ' ;;
      tab_indented) prefix=$(printf '\t') ;;
      mixed_tab) prefix=$(printf '  \t') ;;
      single_backtick) prefix='`'; suffix='`' ;;
      double_backtick) prefix='``'; suffix='``' ;;
      triple_backtick) prefix='```'; suffix='```' ;;
      mixed_backticks) prefix='``example ` '; suffix='``' ;;
    esac
    for evidence in signature attestation both; do
      preflight_case
      {
        cat "$PF_ROOT/intent.md"
        case "$evidence" in
          signature) pipeline_section | sed "/^Updates from /s/.*/$prefix&$suffix/" ;;
          attestation) pipeline_section | sed "/^<!-- no-mistakes-pipeline-attestation:/s/.*/$prefix&$suffix/" ;;
          both) pipeline_section | sed "/^Updates from /s/.*/$prefix&$suffix/; /^<!-- no-mistakes-pipeline-attestation:/s/.*/$prefix&$suffix/" ;;
        esac
      } > "$PF_ROOT/live.md"
      preflight_live_body "$PF_ROOT/live.md"
      preflight_run; rc=$?
      expect_code 2 "$rc" "$style pipeline $evidence"
      assert_contains "$(cat "$PF_ROOT/diagnostic")" 'existing live PR body' "quoted evidence refusal did not identify the live body"
      [ ! -s "$PF_ROOT/validated.md" ] || fail "$style pipeline $evidence released intent"
    done
  done
  preflight_case
  {
    cat "$PF_ROOT/intent.md"
    printf '\n%s\n' 'The `request status` label appears on the member page.'
    pipeline_section
  } > "$PF_ROOT/live.md"
  preflight_live_body "$PF_ROOT/live.md"
  preflight_run; rc=$?
  expect_code 0 "$rc" "inline prose code with unquoted pipeline evidence"
  cmp -s "$PF_ROOT/intent.md" "$PF_ROOT/validated.md" || fail "inline prose code changed validated intent"
  pass "quoted signatures or attestations cannot authorize delivery; inline prose code remains supported"
}

test_preflight_checks_original_quoting_context() {
  local mode rc
  for mode in canonical list_fence ordered_fence multiline_inline multiline_double closed_examples inline_json closed_tilde combined_tilde closed_adjacent combined_adjacent heading_inline heading_plain closed_long_ordered open_long_ordered; do
    preflight_case
    { cat "$PF_ROOT/intent.md"; pipeline_section; } > "$PF_ROOT/live.md"
    node - "$PF_ROOT/live.md" "$mode" <<'JS'
const fs = require('node:fs');
const file = process.argv[2], mode = process.argv[3];
let body = fs.readFileSync(file, 'utf8');
const start = body.indexOf('\n## Pipeline');
if (mode === 'list_fence' || mode === 'ordered_fence') {
  const marker = mode === 'list_fence' ? '-' : '1.';
  const indent = mode === 'list_fence' ? '  ' : '   ';
  body = body.slice(0, start) + '\n' + marker + ' ```\n' +
    body.slice(start + 1).split('\n').map(line => indent + line).join('\n') + '\n' + indent + '```\n';
} else if (mode === 'multiline_inline' || mode === 'multiline_double') {
  const marker = mode === 'multiline_inline' ? '`' : '``';
  body = body.replace(/<!-- no-mistakes-pipeline-attestation:v1 .*? -->/, comment => marker + '\n' + comment + '\n' + marker);
} else if (mode === 'closed_examples') {
  body = body.slice(0, start) + '\n- ```\n  Example code\n  ```\n\n`\nInline example\n`\n' + body.slice(start);
} else if (mode === 'inline_json') {
  body = body.replace('"head_sha":', '"note":"literal `value`", "head_sha":');
} else if (['closed_tilde', 'combined_tilde', 'closed_adjacent', 'combined_adjacent'].includes(mode)) {
  const example = '\n~~~\n`\n~~~\n';
  if (mode.endsWith('_tilde')) body = body.slice(0, start) + example + body.slice(start);
  body = body.replace(/<!-- no-mistakes-pipeline-attestation:v1 .*? -->/, comment =>
    (mode.endsWith('_adjacent') ? example : '') +
    (mode.startsWith('combined_') ? '`\n' + comment + '\n`' : comment));
} else if (mode === 'heading_inline' || mode === 'heading_plain') {
  body = body.replace(/<!-- no-mistakes-pipeline-attestation:v1 .*? -->/, comment =>
    '### Example `\n' + (mode === 'heading_inline' ? '`\n' + comment + '\n`' : comment));
} else if (mode === 'closed_long_ordered' || mode === 'open_long_ordered') {
  body = body.slice(0, start) + '\n10. ```\n    Example `\n' +
    (mode === 'closed_long_ordered' ? '    ```\n' : '') + body.slice(start);
}
fs.writeFileSync(file, body);
JS
    preflight_live_body "$PF_ROOT/live.md"
    preflight_run; rc=$?
    case "$mode" in
      canonical|closed_examples|inline_json|closed_tilde|closed_adjacent|heading_plain|closed_long_ordered)
        expect_code 0 "$rc" "$mode original-context control"
        cmp -s "$PF_ROOT/intent.md" "$PF_ROOT/validated.md" || fail "$mode changed validated intent"
        ;;
      *)
        expect_code 2 "$rc" "$mode quoted attestation"
        [ ! -s "$PF_ROOT/validated.md" ] || fail "$mode quoted attestation released intent"
        assert_contains "$(cat "$PF_ROOT/diagnostic")" 'existing live PR body' "$mode refusal did not identify live evidence"
        ;;
    esac
  done
  pass "original list-fence and multiline inline-code context cannot authorize quoted attestations"
}

test_preflight_requires_original_pipeline_signature() {
  local rc out
  preflight_case
  { cat "$PF_ROOT/intent.md"; pipeline_section; } > "$PF_ROOT/live.md"
  sed 's/Updates from/Up<!-- example -->dates from/' "$PF_ROOT/live.md" > "$PF_ROOT/changed.md"
  preflight_live_body "$PF_ROOT/changed.md"
  preflight_run; rc=$?
  expect_code 2 "$rc" "comment-split pipeline signature"
  [ ! -s "$PF_ROOT/validated.md" ] || fail "reconstructed signature released intent"
  assert_contains "$(cat "$PF_ROOT/diagnostic")" 'no pipeline signature' "reconstructed signature was not refused at the signature check"
  out=$(PR_BODY="$(cat "$PF_ROOT/changed.md")" PR_AUTHOR='fixture' PR_NUMBER=0 run_no_mistakes_requirement 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "hosted consumer unexpectedly accepted a reconstructed signature: $out"
  preflight_live_body "$PF_ROOT/live.md"
  preflight_run; rc=$?
  expect_code 0 "$rc" "original pipeline signature"
  cmp -s "$PF_ROOT/intent.md" "$PF_ROOT/validated.md" || fail "original signature control changed intent"
  pass "only an unchanged original pipeline signature authorizes delivery"
}

test_preflight_pins_github_against_ambient_host() {
  local rc
  preflight_case
  GH_HOST=enterprise.example preflight_run; rc=$?
  expect_code 0 "$rc" "fresh GitHub target with ambient enterprise host"
  incomplete_body > "$PF_ROOT/live.md"
  preflight_live_body "$PF_ROOT/live.md"
  GH_HOST=enterprise.example preflight_run; rc=$?
  expect_code 2 "$rc" "stale GitHub body hidden by empty enterprise response"
  assert_contains "$(cat "$PF_ROOT/diagnostic")" 'existing live PR body' "ambient host bypassed the GitHub body check"
  [ ! -s "$PF_ROOT/validated.md" ] || fail "ambient host released intent for a stale GitHub body"
  { cat "$PF_ROOT/intent.md"; pipeline_section; } > "$PF_ROOT/live.md"
  preflight_live_body "$PF_ROOT/live.md"
  GH_HOST=enterprise.example preflight_run; rc=$?
  expect_code 0 "$rc" "reconciled GitHub body with ambient enterprise host"
  cmp -s "$PF_ROOT/intent.md" "$PF_ROOT/validated.md" || fail "host-bound recovery changed intent"
  [ "$(grep -cx github.com "$PF_ROOT/hosts")" -eq 3 ] || fail "forge queries did not consistently target GitHub"
  pass "ambient GH_HOST cannot hide stale GitHub evidence or block valid GitHub intake"
}

test_preflight_forge_failures_never_mean_no_existing_pr() {
  local mode rc
  for mode in error malformed ambiguous wrong_head invalid_json; do
    preflight_case
    { cat "$PF_ROOT/intent.md"; pipeline_section; } > "$PF_ROOT/live.md"
    preflight_live_body "$PF_ROOT/live.md"
    case "$mode" in
      error|malformed) export PF_TRANSPORT=$mode ;;
      ambiguous) node -e 'const f=require("node:fs"),p=process.argv[1],a=JSON.parse(f.readFileSync(p)); f.writeFileSync(p,JSON.stringify([a[0],a[0]]))' "$PF_ROOT/pulls.json" ;;
      wrong_head) sed 's/fm\/preflight/fm\/other/' "$PF_ROOT/pulls.json" > "$PF_ROOT/changed.json"; mv "$PF_ROOT/changed.json" "$PF_ROOT/pulls.json" ;;
      invalid_json) printf 'invalid' > "$PF_ROOT/pulls.json" ;;
    esac
    preflight_run; rc=$?
    unset PF_TRANSPORT
    expect_code 2 "$rc" "$mode forge response"
    [ ! -s "$PF_ROOT/validated.md" ] || fail "$mode forge response released intent"
  done
  pass "failed, truncated, ambiguous, or mismatched forge data cannot authorize delivery"
}

run_no_mistakes_requirement() {
  local script
  script=$(python3 - "$NO_MISTAKES_WORKFLOW" <<'PY'
import sys

import yaml

with open(sys.argv[1], encoding="utf-8") as workflow_file:
    workflow = yaml.safe_load(workflow_file)
steps = workflow["jobs"]["check"]["steps"]
for step in steps:
    if step.get("name") == "Verify no-mistakes signature in PR body":
        print(step["run"], end="")
        break
else:
    raise SystemExit("no-mistakes signature verifier was not found")
PY
  ) || return $?
  bash -e -c "$script"
}

test_cli_accepts_description_that_keeps_the_pipeline_section() {
  local out rc
  set +e
  out=$(
    PR_TITLE='Show members the status of their requests' \
      PR_BODY="$(complete_body; pipeline_section)" \
      node --experimental-strip-types "$CHECK" 2>&1
  )
  rc=$?
  set -e
  expect_code 0 "$rc" "complete description carrying the no-mistakes Pipeline section"
  assert_contains "$out" "PR communication is complete." \
    "the no-mistakes Pipeline section made a compliant description fail"
  pass "CLI passes a compliant description that keeps the no-mistakes Pipeline section"
}

test_pr_body_composer_preserves_the_pipeline_attestation() {
  local existing body out rc
  existing=$(mktemp "$ROOT/.pr-body-existing.XXXXXX")
  pipeline_section > "$existing"
  body=$("$BODY_COMPOSER" "$TRACKED_BODY_DIR/31.md" "$existing")
  rm -f "$existing"
  assert_contains "$body" \
    '<!-- no-mistakes-pipeline-attestation:v1 {"head_sha":"0000000000000000000000000000000000000000","steps":[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]} -->' \
    "composed PR body changed the existing pipeline attestation"

  set +e
  out=$(PR_TITLE='Fix false supervision alarms' PR_BODY="$body" \
    node --experimental-strip-types "$CHECK" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "composed PR body communication assessment"
  assert_contains "$out" "PR communication is complete." \
    "composed PR body did not preserve the required narrative"

  set +e
  out=$(PR_BODY="$body" PR_AUTHOR='test-author' PR_NUMBER=31 \
    run_no_mistakes_requirement 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "composed PR body no-mistakes attestation assessment"
  assert_contains "$out" "Pipeline step attestation is valid" \
    "composed PR body did not preserve the no-mistakes attestation"
  pass "PR body composer preserves the no-mistakes Pipeline section"
}

test_missing_remote_token_fails_closed() {
  local out rc
  set +e
  out=$(
    env -u PR_COMMUNICATION_SOT_TOKEN -u GITHUB_TOKEN -u GH_TOKEN \
      -u PR_COMMUNICATION_REQUIRE_REMOTE_SOT \
      node "$DRIFT" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "missing remote credential"
  assert_contains "$out" "Local pin OK" "drift check did not confirm the local SoT pin"
  assert_contains "$out" "PR_COMMUNICATION_SOT_TOKEN is required" \
    "missing remote credential did not explain the fail-closed result"
  pass "missing remote credential fails closed after verifying the local pin"
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

test_cli_rejects_pipeline_generated_description() {
  local out rc
  set +e
  out=$(
    PR_TITLE='Keep the fleet board loading for larger fleets' \
      PR_BODY="$(pipeline_generated_body; pipeline_section)" \
      node --experimental-strip-types "$CHECK" 2>&1
  )
  rc=$?
  set -e
  expect_code 1 "$rc" "legacy Intent/What Changed/Risk Assessment/Testing description"
  assert_contains "$out" "CEO overview: What is changing" \
    "legacy headings did not require the CEO overview"
  assert_contains "$out" "Validation: Evidence and limitations" \
    "legacy headings did not require the Validation fields"
  assert_contains "$out" "Module-boundary decision" \
    "legacy headings did not require Module-boundary decision"
  pass "CLI rejects a description that keeps only the legacy narrative headings"
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

test_invalid_token_header_fails_closed() {
  local out rc
  set +e
  out=$(PR_COMMUNICATION_SOT_TOKEN=$'invalid\nheader' node "$DRIFT" 2>&1)
  rc=$?
  set -e
  expect_code 1 "$rc" "invalid token header"
  assert_not_contains "$out" "Using the verified local pin" \
    "invalid token header incorrectly used the local pin"
  pass "invalid token header fails closed"
}

test_tampered_entrypoint_fails_closed() {
  local candidate out rc
  candidate=$(mktemp -d "$ROOT/.pr-communication-candidate.XXXXXX")
  mkdir -p "$candidate/scripts/pr-communication"
  cp "$CHECK" "$candidate/scripts/check-pr-communication.ts"
  cp "$ROOT/scripts/pr-communication/prCommunication.ts" \
    "$candidate/scripts/pr-communication/prCommunication.ts"
  cp "$ROOT/scripts/pr-communication/SOURCE.sha256" \
    "$candidate/scripts/pr-communication/SOURCE.sha256"
  printf '\n// tampered\n' >> "$candidate/scripts/check-pr-communication.ts"
  set +e
  out=$(PR_COMMUNICATION_CANDIDATE_ROOT="${candidate#"$ROOT"/}" \
    PR_COMMUNICATION_SOT_TOKEN=test-token node "$DRIFT" 2>&1)
  rc=$?
  set -e
  rm -rf "$candidate"
  expect_code 1 "$rc" "tampered PR communication entrypoint"
  assert_contains "$out" "entrypoint does not match" \
    "tampered entrypoint did not fail its trusted pin"
  pass "tampered entrypoint fails closed"
}

test_candidate_pin_cannot_authorize_tampered_assessor() {
  local candidate out rc
  candidate=$(mktemp -d "$ROOT/.pr-communication-candidate.XXXXXX")
  mkdir -p "$candidate/scripts/pr-communication"
  cp "$CHECK" "$candidate/scripts/check-pr-communication.ts"
  cp "$ROOT/scripts/pr-communication/prCommunication.ts" \
    "$candidate/scripts/pr-communication/prCommunication.ts"
  printf '\n// tampered\n' >> "$candidate/scripts/pr-communication/prCommunication.ts"
  node -e \
    'const fs=require("node:fs"),c=require("node:crypto"); const p=process.argv[1]; const s=fs.readFileSync(p,"utf8"); const b=s.slice(s.indexOf("\n\n")+2); process.stdout.write(c.createHash("sha256").update(b).digest("hex")+"\n")' \
    "$candidate/scripts/pr-communication/prCommunication.ts" \
    > "$candidate/scripts/pr-communication/SOURCE.sha256"
  set +e
  out=$(PR_COMMUNICATION_CANDIDATE_ROOT="${candidate#"$ROOT"/}" \
    PR_COMMUNICATION_FETCH_FAILURE=503 PR_COMMUNICATION_SOT_TOKEN=test-token \
    node --import "$FETCH_FIXTURE" "$DRIFT" 2>&1)
  rc=$?
  set -e
  rm -rf "$candidate"
  expect_code 1 "$rc" "candidate-controlled assessor pin"
  assert_contains "$out" "does not match trusted SOURCE.sha256" \
    "candidate-controlled pin authorized a tampered assessor"
  pass "candidate pin cannot authorize a tampered assessor"
}

test_remote_sot_authorizes_synchronized_assessor() {
  local candidate body out rc
  candidate=$(mktemp -d "$ROOT/.pr-communication-candidate.XXXXXX")
  mkdir -p "$candidate/scripts/pr-communication"
  cp "$CHECK" "$candidate/scripts/check-pr-communication.ts"
  cp "$ROOT/scripts/pr-communication/prCommunication.ts" \
    "$candidate/scripts/pr-communication/prCommunication.ts"
  printf '\n// synchronized update\n' >> "$candidate/scripts/pr-communication/prCommunication.ts"
  body="$candidate/remote.ts"
  sed '1,/^$/d' "$candidate/scripts/pr-communication/prCommunication.ts" > "$body"
  node -e \
    'const fs=require("node:fs"),c=require("node:crypto"); const p=process.argv[1]; process.stdout.write(c.createHash("sha256").update(fs.readFileSync(p,"utf8")).digest("hex")+"\n")' \
    "$body" > "$candidate/scripts/pr-communication/SOURCE.sha256"
  set +e
  out=$(PR_COMMUNICATION_CANDIDATE_ROOT="${candidate#"$ROOT"/}" \
    PR_COMMUNICATION_FETCH_BODY_PATH="$body" PR_COMMUNICATION_SOT_TOKEN=test-token \
    node --import "$FETCH_FIXTURE" "$DRIFT" 2>&1)
  rc=$?
  set -e
  rm -rf "$candidate"
  expect_code 0 "$rc" "synchronized remote assessor update"
  assert_contains "$out" "Remote SoT matches" \
    "remote SoT did not authorize its synchronized assessor update"
  pass "remote SoT authorizes a synchronized assessor update"
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

test_tracked_pr_bodies_are_accepted() {
  local body_file found=0 out rc
  for body_file in "$TRACKED_BODY_DIR"/*.md; do
    [ -e "$body_file" ] || continue
    found=1
    set +e
    out=$(
      PR_TITLE='Validate a tracked pull request description' \
        PR_BODY="$(cat "$body_file")" \
        node --experimental-strip-types "$CHECK" 2>&1
    )
    rc=$?
    set -e
    expect_code 0 "$rc" "tracked PR body ${body_file#"$ROOT"/}"
    assert_contains "$out" "PR communication is complete." \
      "tracked PR body ${body_file#"$ROOT"/} did not satisfy the executable gate"
  done
  expect_code 1 "$found" "at least one tracked PR body fixture"
  pass "tracked PR body artifacts satisfy the executable communication gate"
}

test_firstmate_unit_suite() {
  local out rc
  set +e
  out=$(node --experimental-strip-types --test "$FIRSTMATE_UNIT" 2>&1)
  rc=$?
  set -e
  expect_code 0 "$rc" "Firstmate CEO overview unit suite"
  pass "Firstmate CEO overview unit suite passes"
}

run_communication_check() {
  local checker=$1 title=$2 body_file=$3
  PR_TITLE="$title" PR_BODY="$(cat "$body_file")" \
    node --experimental-strip-types "$checker" 2>&1
}

test_evidence_bodies_keep_shared_assessor_verdict() {
  local out rc
  set +e
  out=$(run_communication_check "$CHECK" \
    'Harden wake routing and process-event delivery' \
    "$EVIDENCE_BODY_DIR/12-implementation-intent.md")
  rc=$?
  set -e
  expect_code 1 "$rc" "shared assessor on PR 12 shape"
  assert_contains "$out" "CEO overview: What is changing" \
    "shared assessor no longer required a CEO overview on the PR 12 shape"

  set +e
  out=$(run_communication_check "$CHECK" \
    'Gate second implementation attempts on a Sol spec' \
    "$EVIDENCE_BODY_DIR/17-implementation-intent.md")
  rc=$?
  set -e
  expect_code 1 "$rc" "shared assessor on PR 17 shape"
  assert_contains "$out" "CEO overview: What is changing" \
    "shared assessor no longer required a CEO overview on the PR 17 shape"

  set +e
  out=$(run_communication_check "$CHECK" \
    'Add prioritized local task pulling' \
    "$EVIDENCE_BODY_DIR/14-ceo-overview.md")
  rc=$?
  set -e
  expect_code 0 "$rc" "shared assessor on PR 14 shape"
  assert_contains "$out" "PR communication is complete." \
    "shared assessor rejected the PR 14 captain-facing overview"

  set +e
  out=$(run_communication_check "$CHECK" \
    'Serve authenticated fleet snapshot' \
    "$EVIDENCE_BODY_DIR/18-ceo-overview.md")
  rc=$?
  set -e
  expect_code 0 "$rc" "shared assessor on PR 18 shape"
  assert_contains "$out" "PR communication is complete." \
    "shared assessor rejected the PR 18 captain-facing overview"
  pass "shared assessor still fails the Intent shape and passes the CEO overview shape"
}

test_pr12_shape_fails_firstmate_ceo_overview() {
  local out rc
  set +e
  out=$(run_communication_check "$FIRSTMATE_CHECK" \
    'Harden wake routing and process-event delivery' \
    "$EVIDENCE_BODY_DIR/12-implementation-intent.md")
  rc=$?
  set -e
  expect_code 1 "$rc" "PR 12 implementation-intent shape"
  assert_contains "$out" \
    "CEO overview is missing or incomplete; implementation intent is not an acceptable substitute" \
    "PR 12 shape did not fail as a missing CEO overview"
  pass "PR 12 implementation-intent shape fails the Firstmate CEO overview check"
}

test_pr17_shape_fails_firstmate_ceo_overview() {
  local out rc
  set +e
  out=$(run_communication_check "$FIRSTMATE_CHECK" \
    'Gate second implementation attempts on a Sol spec' \
    "$EVIDENCE_BODY_DIR/17-implementation-intent.md")
  rc=$?
  set -e
  expect_code 1 "$rc" "PR 17 implementation-intent shape"
  assert_contains "$out" \
    "CEO overview is missing or incomplete; implementation intent is not an acceptable substitute" \
    "PR 17 shape did not fail as a missing CEO overview"
  pass "PR 17 implementation-intent shape fails the Firstmate CEO overview check"
}

test_pr14_shape_passes_firstmate_ceo_overview() {
  local out rc
  set +e
  out=$(run_communication_check "$FIRSTMATE_CHECK" \
    'Add prioritized local task pulling' \
    "$EVIDENCE_BODY_DIR/14-ceo-overview.md")
  rc=$?
  set -e
  expect_code 0 "$rc" "PR 14 captain-facing overview"
  assert_contains "$out" "Firstmate CEO overview is complete." \
    "PR 14 shape did not pass the Firstmate CEO overview check"
  pass "PR 14 captain-facing overview passes the Firstmate CEO overview check"
}

test_pr18_shape_passes_firstmate_ceo_overview() {
  local out rc
  set +e
  out=$(run_communication_check "$FIRSTMATE_CHECK" \
    'Serve authenticated fleet snapshot' \
    "$EVIDENCE_BODY_DIR/18-ceo-overview.md")
  rc=$?
  set -e
  expect_code 0 "$rc" "PR 18 captain-facing overview"
  assert_contains "$out" "Firstmate CEO overview is complete." \
    "PR 18 shape did not pass the Firstmate CEO overview check"
  pass "PR 18 captain-facing overview passes the Firstmate CEO overview check"
}

test_implementation_only_overview_fails_firstmate_ceo_overview() {
  local out rc
  set +e
  out=$(run_communication_check "$CHECK" \
    'Harden wake routing and process-event delivery' \
    "$EVIDENCE_BODY_DIR/implementation-only-overview.md")
  rc=$?
  set -e
  expect_code 0 "$rc" "shared assessor on implementation-only overview"
  assert_contains "$out" "PR communication is complete." \
    "shared assessor unexpectedly rejected labelled implementation intent"

  set +e
  out=$(run_communication_check "$FIRSTMATE_CHECK" \
    'Harden wake routing and process-event delivery' \
    "$EVIDENCE_BODY_DIR/implementation-only-overview.md")
  rc=$?
  set -e
  expect_code 1 "$rc" "implementation-only CEO overview"
  assert_contains "$out" \
    "CEO overview is only implementation intent; tell the captain what is changing, why it matters, impact, risk, and any decision needed" \
    "implementation-only overview did not fail the Firstmate CEO overview check"
  pass "implementation-only CEO overview fails Firstmate and still satisfies the shared labels"
}

test_tracked_pr_bodies_pass_firstmate_ceo_overview() {
  local body_file found=0 out rc
  for body_file in "$TRACKED_BODY_DIR"/*.md; do
    [ -e "$body_file" ] || continue
    found=1
    set +e
    out=$(
      PR_TITLE='Validate a tracked pull request description' \
        PR_BODY="$(cat "$body_file")" \
        node --experimental-strip-types "$FIRSTMATE_CHECK" 2>&1
    )
    rc=$?
    set -e
    expect_code 0 "$rc" "Firstmate CEO overview for ${body_file#"$ROOT"/}"
    assert_contains "$out" "Firstmate CEO overview is complete." \
      "tracked PR body ${body_file#"$ROOT"/} failed the Firstmate CEO overview check"
  done
  expect_code 1 "$found" "at least one tracked PR body fixture"
  pass "tracked PR body artifacts satisfy the Firstmate CEO overview check"
}

test_preflight_fresh_intent_survives_generated_body
test_preflight_rejects_bad_intent_before_forge_read
test_preflight_stale_body_refuses_until_owner_reconciles
test_preflight_refuses_stale_or_forged_pipeline_data
test_preflight_preserves_comment_boundaries_and_step_types
test_preflight_rejects_quoted_pipeline_evidence
test_preflight_checks_original_quoting_context
test_preflight_requires_original_pipeline_signature
test_preflight_pins_github_against_ambient_host
test_preflight_forge_failures_never_mean_no_existing_pr
test_missing_remote_token_fails_closed
test_vendored_unit_suite
test_firstmate_unit_suite
test_cli_accepts_description_that_keeps_the_pipeline_section
test_pr_body_composer_preserves_the_pipeline_attestation
test_cli_rejects_incomplete_description
test_cli_rejects_pipeline_generated_description
test_cli_rejects_untouched_module_boundary_template
test_cli_accepts_complete_description
test_tracked_pr_bodies_are_accepted
test_evidence_bodies_keep_shared_assessor_verdict
test_pr12_shape_fails_firstmate_ceo_overview
test_pr17_shape_fails_firstmate_ceo_overview
test_pr14_shape_passes_firstmate_ceo_overview
test_pr18_shape_passes_firstmate_ceo_overview
test_implementation_only_overview_fails_firstmate_ceo_overview
test_tracked_pr_bodies_pass_firstmate_ceo_overview
test_transient_remote_failure_uses_local_pin
test_required_remote_failure_fails_closed
test_auth_remote_failure_fails_closed
test_invalid_token_header_fails_closed
test_tampered_entrypoint_fails_closed
test_candidate_pin_cannot_authorize_tampered_assessor
test_remote_sot_authorizes_synchronized_assessor
