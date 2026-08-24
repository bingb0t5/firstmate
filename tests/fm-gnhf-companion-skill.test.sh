#!/usr/bin/env bash
# Contract regressions for gnhf-companion's declarative metadata and the installed
# GNHF CLI flag surface the skill's brief contract depends on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/gnhf-companion/SKILL.md"

test_skill_frontmatter() {
  assert_present "$SKILL" \
    "gnhf-companion skill file is missing"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse skill metadata"

  python3 - "$SKILL" <<'PY' || fail "gnhf-companion declarative metadata is invalid"
import pathlib
import sys
import yaml

skill_path = pathlib.Path(sys.argv[1])
content = skill_path.read_text(encoding="utf-8")
if not content.startswith("---\n"):
    raise SystemExit("missing frontmatter opener")
try:
    frontmatter, _ = content[4:].split("\n---\n", 1)
except ValueError as error:
    raise SystemExit("missing frontmatter closer") from error

metadata = yaml.safe_load(frontmatter)
expected = {
    "name": "gnhf-companion",
    "user-invocable": False,
    "metadata": {"internal": True},
}
for key, value in expected.items():
    if metadata.get(key) != value:
        raise SystemExit(f"unexpected {key}: {metadata.get(key)!r}")
PY

  pass "gnhf-companion skill carries its required frontmatter"
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

test_skill_frontmatter
test_gnhf_help_flags_live
