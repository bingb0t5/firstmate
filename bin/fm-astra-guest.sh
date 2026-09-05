#!/usr/bin/env bash
# fm-astra-guest.sh - prepare and serialize the isolated guest Codex/Astra path.
#
# Usage:
#   bin/fm-astra-guest.sh check --manifest <guest-readiness.json>
#   bin/fm-astra-guest.sh prepare --manifest <guest-readiness.json> --project <guest-project>
#   bin/fm-astra-guest.sh pause|resume|status --state-dir <guest-state-dir>
#   bin/fm-astra-guest.sh run --manifest <guest-readiness.json> --state-dir <guest-state-dir> \
#     --client <guest-adapter> (--request <json> | --prompt <text>)
#
# The Python implementation owns the readiness schema, handoff state, exclusive
# input lock, timeout cleanup, and machine-readable result envelope.
set -eu

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
exec python3 "$ROOT/bin/fm-astra-guest.py" "$@"
