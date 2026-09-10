#!/usr/bin/env bash
# Resolve the explicit GitHub repository for an ordinary pull request.
# Usage: fm-pr-target.sh <project-directory>
# The project's origin push URL is the delivery target for ordinary PRs.
# Firstmate itself may fetch from kunchenguid/firstmate, but ordinary PRs must
# target bingb0t5/firstmate and an upstream push URL is refused.
# This deliberately does not inspect remote order or an unscoped GitHub command.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=${1:-}

if [ "$#" -ne 1 ] || [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ]; then
  echo "usage: fm-pr-target.sh <project-directory>" >&2
  exit 2
fi

# shellcheck source=bin/fm-repo-slug-lib.sh
. "$SCRIPT_DIR/fm-repo-slug-lib.sh"

FIRSTMATE_UPSTREAM_REPO=kunchenguid/firstmate
FIRSTMATE_DELIVERY_REPO=bingb0t5/firstmate

PUSH_URL=$(git -C "$PROJECT" remote get-url --push origin 2>/dev/null) || {
  echo "error: project has no usable origin push URL" >&2
  exit 1
}

if ! fm_repo_slug_parse "$PUSH_URL"; then
  echo "error: origin push URL is not a GitHub repository: $FM_REPO_SLUG_STATUS" >&2
  exit 1
fi

PUSH_REPO=$FM_REPO_SLUG
FETCH_URL=$(git -C "$PROJECT" remote get-url origin 2>/dev/null || true)
if [ -n "$FETCH_URL" ] && fm_repo_slug_parse "$FETCH_URL"; then
  FETCH_REPO=$FM_REPO_SLUG
else
  FETCH_REPO=
fi
FM_REPO_SLUG=$PUSH_REPO

if [ "$PUSH_REPO" = "$FIRSTMATE_UPSTREAM_REPO" ] \
  || [ "$FETCH_REPO" = "$FIRSTMATE_UPSTREAM_REPO" ] \
  || [ "$FETCH_REPO" = "$FIRSTMATE_DELIVERY_REPO" ]; then
  if [ "$PUSH_REPO" != "$FIRSTMATE_DELIVERY_REPO" ]; then
    echo "error: ordinary Firstmate PR target must be $FIRSTMATE_DELIVERY_REPO, not $PUSH_REPO" >&2
    exit 1
  fi
fi

printf '%s\n' "$FM_REPO_SLUG"
