#!/usr/bin/env bash
# Check Firstmate PR communication before starting or resuming delivery.
# Usage: fm-nm-pr-preflight.sh --intent-file <file> --repo <owner/repo> --head <owner:branch>
#
# Read-only: assess the exact authored intent and query open GitHub PRs for the
# explicit delivery target through gh-axi. The head branch must be checked out.
# Refuse incomplete intent, reserved pipeline markers, oversized intent, failed
# or ambiguous forge reads, incomplete live bodies, and stale head attestations.
# On success stdout contains ONLY the validated intent, unchanged; diagnostics
# go to stderr. Capture it and pass that value to no-mistakes axi run --intent.
# Existing live descriptions must be reconciled by their owner before retrying;
# this command never edits a PR, generates an attestation, or drives a pipeline.
# This is a structural preflight, not proof of prose accuracy or a replacement
# for hosted checks. The upstream publisher can still rewrite/truncate a body.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
case "${1:-}" in
  -h|--help)
    sed -n '2,/^set -eu/{ /^set -eu/d; s/^# \{0,1\}//; p; }' "$0"
    exit 0
    ;;
esac

exec node --experimental-strip-types "$SCRIPT_DIR/../scripts/check-pr-delivery.ts" "$@"
