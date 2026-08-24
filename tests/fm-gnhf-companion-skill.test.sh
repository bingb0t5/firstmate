#!/usr/bin/env bash
# Contract regressions for gnhf-companion's declarative metadata and the installed
# GNHF CLI flag surface the skill's brief contract depends on.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SKILL="$ROOT/.agents/skills/gnhf-companion/SKILL.md"
AGENTS="$ROOT/AGENTS.md"

test_skill_frontmatter_and_trigger() {
  assert_present "$SKILL" \
    "gnhf-companion skill file is missing"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to parse skill metadata"

  python3 - "$SKILL" "$AGENTS" <<'PY' || fail "gnhf-companion declarative metadata or trigger is invalid"
import pathlib
import sys

skill_path = pathlib.Path(sys.argv[1])
agents_path = pathlib.Path(sys.argv[2])
lines = skill_path.read_text(encoding="utf-8").splitlines()
if not lines or lines[0] != "---":
    raise SystemExit("missing frontmatter opener")
try:
    end = lines.index("---", 1)
except ValueError as error:
    raise SystemExit("missing frontmatter closer") from error

metadata = {}
section = None
for line in lines[1:end]:
    if not line.strip() or line.startswith("  ") and section != "metadata":
        continue
    if line == "metadata:":
        section = "metadata"
        metadata[section] = {}
        continue
    if section == "metadata" and line.startswith("  "):
        key, value = line.strip().split(":", 1)
        metadata[section][key] = value.strip() == "true"
        continue
    section = None
    if ":" in line:
        key, value = line.split(":", 1)
        value = value.strip()
        metadata[key] = {"true": True, "false": False}.get(value, value)

expected = {
    "name": "gnhf-companion",
    "user-invocable": False,
    "metadata": {"internal": True},
}
for key, value in expected.items():
    if metadata.get(key) != value:
        raise SystemExit(f"unexpected {key}: {metadata.get(key)!r}")

trigger = "- `gnhf-companion` - load before briefing, steering, or reviewing a crewmate's use of the installed GNHF tool for bounded autonomous iteration inside its own task worktree."
agents_lines = agents_path.read_text(encoding="utf-8").splitlines()
start = agents_lines.index("## 13. Agent-only reference skills")
end = next((i for i in range(start + 1, len(agents_lines)) if agents_lines[i].startswith("## ")), len(agents_lines))
if agents_lines[start + 1:end].count(trigger) != 1:
    raise SystemExit("section 13 must contain the exact gnhf-companion trigger once")
PY

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
