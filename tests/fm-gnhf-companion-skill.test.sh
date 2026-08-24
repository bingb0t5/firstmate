#!/usr/bin/env bash
# Behavioral regressions for the gnhf-companion skill's trigger/loading contract
# and the installed GNHF CLI's flag surface the skill's brief contract depends on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/gnhf-companion/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_skill_frontmatter_and_trigger() {
  assert_present "$SKILL" \
    "gnhf-companion skill file is missing"
  assert_grep 'name: gnhf-companion' "$SKILL" \
    "gnhf-companion skill frontmatter lost its name field"
  assert_grep 'user-invocable: false' "$SKILL" \
    "gnhf-companion skill is missing the agent-only user-invocable declaration"
  assert_grep 'internal: true' "$SKILL" \
    "gnhf-companion skill is missing the internal metadata declaration"
  assert_grep 'Hands-Off' "$SKILL" \
    "gnhf-companion skill dropped the Hands-Off mode definition"
  assert_grep 'Companion' "$SKILL" \
    "gnhf-companion skill dropped the Companion mode definition"
  # shellcheck disable=SC2016 # Backticks are literal Markdown, not shell expansion.
  assert_grep '`--current-branch`, never `--worktree`' "$SKILL" \
    "gnhf-companion skill dropped the current-branch-not-worktree isolation rule"

  # shellcheck disable=SC2016 # Backticks are literal Markdown, not shell expansion.
  assert_grep '`gnhf-companion` - load before briefing, steering, or reviewing' "$AGENTS" \
    "AGENTS.md section 13 is missing the gnhf-companion trigger line"

  pass "gnhf-companion skill carries its required frontmatter and AGENTS.md carries its one-line trigger"
}

test_gnhf_help_flags_live() {
  if ! command -v gnhf >/dev/null 2>&1; then
    echo "skip: gnhf is not installed on this machine"
    return 0
  fi

  local help
  help=$(gnhf --help 2>&1) || fail "installed gnhf --help exited non-zero"

  local flag
  for flag in '--agent' '--max-iterations' '--max-tokens' '--max-rate-limit-wait' \
    '--stop-when' '--current-branch' '--worktree' '--push'; do
    printf '%s' "$help" | grep -F -- "$flag" >/dev/null ||
      fail "installed gnhf --help no longer advertises $flag, which gnhf-companion's brief contract assumes"
  done

  pass "installed gnhf --help still exposes every flag gnhf-companion's required brief contract assumes"
}

test_skill_frontmatter_and_trigger
test_gnhf_help_flags_live
