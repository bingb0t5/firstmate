#!/usr/bin/env bash
# tests/host-health-episode.test.sh - offline host-health episode model.
#
# Drives the package's public Python contract: 39 unit/integration tests,
# 12/12 mutations, and the bounded enumerator. Nothing here reads a live host,
# credential, sender, schedule, or network path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }

PKG="$ROOT/bin/host-health-episode"
[ -d "$PKG" ] || fail "missing episode package: $PKG"
[ -f "$PKG/oracle.py" ] || fail "missing episode oracle: $PKG/oracle.py"

cd "$PKG" || fail "could not enter $PKG"

if ! python3 -m unittest discover -s tests -q; then
  fail "host-health episode unit/integration tests failed"
fi
pass "host-health episode unit/integration tests (39) passed"

mutation_out=$(python3 mutation_runner.py) || fail "host-health episode mutation runner failed"
printf '%s\n' "$mutation_out" | python3 -c '
import json, sys
evidence = json.load(sys.stdin)
if evidence.get("verdict") != "pass" or evidence.get("score") != "12/12":
    raise SystemExit(f"mutation verdict {evidence.get(\"verdict\")!r} score {evidence.get(\"score\")!r}")
' || fail "host-health episode mutations were not 12/12"
pass "host-health episode mutations 12/12"

enum_out=$(python3 enumerate_sequences.py) || fail "host-health episode enumeration failed"
printf '%s\n' "$enum_out" | python3 -c '
import json, sys
evidence = json.load(sys.stdin)
steps = evidence.get("actual_steps")
coverage = evidence.get("transition_coverage") or {}
if evidence.get("verdict") != "pass":
    raise SystemExit(f"enumeration verdict {evidence.get(\"verdict\")!r}")
if steps != 18089427:
    raise SystemExit(f"enumeration steps {steps!r}, expected 18089427")
if coverage.get("hit") != 40 or coverage.get("defined") != 40:
    raise SystemExit(f"transition coverage {coverage!r}")
if coverage.get("missing") or coverage.get("unexpected"):
    raise SystemExit(f"transition id mismatch {coverage!r}")
' || fail "host-health episode enumeration did not match the accepted bound"
pass "host-health episode enumeration 18089427 steps, 40/40 transitions"
