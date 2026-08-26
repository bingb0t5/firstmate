#!/usr/bin/env bash
# Resolve the explicit GitHub repository for an ordinary pull request.
# Usage: fm-pr-target.sh <project-directory>
# The project's origin push URL is the delivery target. This deliberately does
# not inspect the default branch, remote order, or an unscoped GitHub command.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT=${1:-}

if [ "$#" -ne 1 ] || [ -z "$PROJECT" ] || [ ! -d "$PROJECT" ]; then
  echo "usage: fm-pr-target.sh <project-directory>" >&2
  exit 2
fi

# shellcheck source=bin/fm-repo-slug-lib.sh
. "$SCRIPT_DIR/fm-repo-slug-lib.sh"

PUSH_URL=$(git -C "$PROJECT" remote get-url --push origin 2>/dev/null) || {
  echo "error: project has no usable origin push URL" >&2
  exit 1
}

if ! fm_repo_slug_parse "$PUSH_URL"; then
  echo "error: origin push URL is not a GitHub repository: $FM_REPO_SLUG_STATUS" >&2
  exit 1
fi

printf '%s\n' "$FM_REPO_SLUG"
