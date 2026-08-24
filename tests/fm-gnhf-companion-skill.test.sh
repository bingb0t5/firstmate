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

  local frontmatter_error
  if ! frontmatter_error=$(python3 - "$SKILL" 2>&1 <<'PY'
import pathlib
import sys

lines = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
if not lines or lines[0] != "---":
    raise SystemExit("missing frontmatter opener")
try:
    end = lines.index("---", 1)
except ValueError as error:
    raise SystemExit("missing frontmatter closer") from error

parsed = {}
current_key = None
for line in lines[1:end]:
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    key, separator, value = line.partition(":")
    if line[:1] not in (" ", "\t"):
        if not separator:
            continue
        current_key = key.strip()
        parsed[current_key] = value.strip() or {}
    elif separator and isinstance(parsed.get(current_key), dict):
        parsed[current_key][key.strip()] = value.strip()


def as_bool(value):
    return {"true": True, "false": False}.get(value, value)


nested = parsed.get("metadata")
internal = nested.get("internal") if isinstance(nested, dict) else None

failures = []
if parsed.get("name") != "gnhf-companion":
    failures.append("name is {!r}, expected 'gnhf-companion'".format(parsed.get("name")))
if as_bool(parsed.get("user-invocable")) is not False:
    failures.append(
        "user-invocable is {!r}, expected false".format(parsed.get("user-invocable"))
    )
if as_bool(internal) is not True:
    failures.append("metadata.internal is {!r}, expected true".format(internal))
if failures:
    raise SystemExit("; ".join(failures))
PY
  ); then
    fail "gnhf-companion declarative metadata is invalid: $frontmatter_error"
  fi

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
