#!/usr/bin/env bash
# Run from the tested worktree. All forge responses below are local test fixtures.
set -u
ROOT=$PWD
EVIDENCE=/home/rich/.no-mistakes/evidence/01M22GZ81RRY8SM8EP64BHY2C2
export TMPDIR="$ROOT/.test-tmp"
mkdir -p "$TMPDIR"
# Reuse the repository's fixture builders; execute cases below rather than the full suite.
eval "$(python3 - <<'LOAD'
from pathlib import Path
s=Path('tests/pr-communication.test.sh').read_text().split('\ntest_preflight_fresh_intent_survives_generated_body\n')[0]
s=s.replace('. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"', '. "$ROOT/tests/lib.sh"')
print(s)
LOAD
)"
export GITHUB_STEP_SUMMARY=''
exec > "$EVIDENCE/preflight-transcript.txt" 2>&1
printf 'Local public-CLI verification at %s\n' "$(git rev-parse HEAD)"
printf 'Forge boundary: deterministic gh-axi GET fixture; no live PR, publication, or hosted CI changes.\n'
printf 'Machine data uses the existing suite fixture, never a published attestation.\n'
record() {
  local name=$1 expected=$2 rc before after destination
  destination="$EVIDENCE/$name"
  mkdir -p "$destination"
  before=$(sha256sum "$PF_ROOT/intent.md" "$PF_ROOT/pulls.json")
  preflight_run; rc=$?
  after=$(sha256sum "$PF_ROOT/intent.md" "$PF_ROOT/pulls.json")
  [ "$before" = "$after" ] || fail 'preflight mutated input fixture'
  [ -z "$(git -C "$PF_ROOT/repo" status --porcelain)" ] || fail 'preflight mutated repository'
  expect_code "$expected" "$rc" "$name"
  if [ "$rc" = 0 ]; then
    cmp -s "$PF_ROOT/intent.md" "$PF_ROOT/validated.md" || fail 'intent bytes changed'
  else
    [ ! -s "$PF_ROOT/validated.md" ] || fail 'refusal emitted intent'
  fi
  cp "$PF_ROOT/intent.md" "$destination/authored-intent.md"
  cp "$PF_ROOT/pulls.json" "$destination/forge-response.json"
  cp "$PF_ROOT/validated.md" "$destination/stdout.md"
  cp "$PF_ROOT/diagnostic" "$destination/stderr.txt"
  printf '\nCASE: %s\n' "$name"
  printf '$ %s --intent-file <fixture>/intent.md --repo o/r --head o:fm/preflight\n' "$PREFLIGHT"
  printf 'exit=%s; stdout_bytes=%s; intent/forge/repository unchanged\n' "$rc" "$(wc -c < "$PF_ROOT/validated.md" | tr -d ' ')"
  cat "$PF_ROOT/diagnostic"
  if [ "$rc" = 0 ]; then printf 'stdout is byte-identical to authored-intent.md\n'; fi
}
assess_body() {
  local file=$1 expected=$2 checker rc
  for checker in "$CHECK" "$FIRSTMATE_CHECK"; do
    printf '\n$ PR_TITLE="Show request status" PR_BODY=<%s> node --experimental-strip-types %s\n' "$file" "$checker"
    PR_TITLE='Show request status' PR_BODY="$(cat "$file")" node --experimental-strip-types "$checker"
    rc=$?
    printf 'assessor exit=%s\n' "$rc"
    expect_code "$expected" "$rc" 'public assessor'
  done
}
preflight_case
record fresh-intent 0
# The existing regression constructs the observed publisher shape with Testing details.
test_preflight_fresh_intent_survives_generated_body
record generated-testing-details 0
cp "$PF_ROOT/live.md" "$EVIDENCE/generated-pr-body.md"
assess_body "$PF_ROOT/live.md" 0
preflight_case
{ pipeline_generated_body; pipeline_section; } > "$PF_ROOT/live.md"
preflight_live_body "$PF_ROOT/live.md"
record stale-live-body 2
"$BODY_COMPOSER" "$PF_ROOT/intent.md" "$PF_ROOT/live.md" > "$PF_ROOT/reconciled.md"
preflight_live_body "$PF_ROOT/reconciled.md"
record owner-reconciled-body 0
assess_body "$PF_ROOT/reconciled.md" 0
sed 's/0000000000000000000000000000000000000000/1111111111111111111111111111111111111111/' "$PF_ROOT/reconciled.md" > "$PF_ROOT/stale-head.md"
preflight_live_body "$PF_ROOT/stale-head.md"
record stale-head 2
preflight_case
sed '/^- \*\*What is changing:/i What is changing: pending' "$PF_ROOT/intent.md" > "$PF_ROOT/earlier.md"
cp "$PF_ROOT/earlier.md" "$PF_ROOT/intent.md"
record original-stale-line 2
assess_body "$PF_ROOT/intent.md" 1
# Replay R18 before and after the fix using identical authored bytes.
BASELINE="$TMPDIR/before-r18"
mkdir -p "$BASELINE/bin"
cp -R "$ROOT/scripts" "$BASELINE/scripts"
cp "$ROOT/bin/fm-nm-pr-preflight.sh" "$BASELINE/bin/"
git show fed6ede^:scripts/check-pr-delivery.ts > "$BASELINE/scripts/check-pr-delivery.ts"
CURRENT_PREFLIGHT=$PREFLIGHT
for mode in decimal-space empty-image; do
  preflight_case
  {
    complete_body
    printf '\n## What changed technically\n\n'
    if [ "$mode" = decimal-space ]; then printf '&#32;\n'; else printf '![](image.png)\n'; fi
  } > "$PF_ROOT/intent.md"
  PREFLIGHT="$BASELINE/bin/fm-nm-pr-preflight.sh"
  record "before-r18-$mode" 0
  PREFLIGHT=$CURRENT_PREFLIGHT
  record "after-r18-$mode" 2
  printf '\n&#82;ender request status in the existing member page.\n' >> "$PF_ROOT/intent.md"
  record "prose-control-$mode" 0
done
printf '\nAll evidence-producing assertions passed.\n'
