#!/usr/bin/env bash
# Compose a compliant PR narrative with the existing no-mistakes Pipeline suffix.
# Usage: fm-pr-body-compose.sh <narrative-file> <existing-pr-body-file>
#
# The existing body must contain the exact no-mistakes signature and structured
# pipeline attestation under a "## Pipeline" heading.
set -eu

if [ "$#" -ne 2 ]; then
  echo "usage: $0 <narrative-file> <existing-pr-body-file>" >&2
  exit 2
fi

narrative_file=$1
existing_body_file=$2

if [ ! -r "$narrative_file" ]; then
  echo "error: narrative file is not readable: $narrative_file" >&2
  exit 1
fi

if [ ! -r "$existing_body_file" ]; then
  echo "error: existing PR body file is not readable: $existing_body_file" >&2
  exit 1
fi

if grep -Eq '^## Pipeline[[:space:]]*$' "$narrative_file"; then
  echo "error: narrative file must not contain a ## Pipeline section" >&2
  exit 1
fi

pipeline=$(awk '
  /^## Pipeline[[:space:]]*$/ {
    found = 1
  }
  found {
    print
  }
  END {
    if (!found) {
      exit 1
    }
  }
' "$existing_body_file") || {
  echo "error: existing PR body has no ## Pipeline section" >&2
  exit 1
}

signature='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
attestation_prefix='<!-- no-mistakes-pipeline-attestation:v1 '
if ! printf '%s\n' "$pipeline" | grep -qF -- "$signature"; then
  echo "error: existing PR body Pipeline section has no no-mistakes signature" >&2
  exit 1
fi

if ! printf '%s\n' "$pipeline" | grep -qF -- "$attestation_prefix"; then
  echo "error: existing PR body Pipeline section has no structured attestation" >&2
  exit 1
fi

cat "$narrative_file"
printf '\n\n%s\n' "$pipeline"
