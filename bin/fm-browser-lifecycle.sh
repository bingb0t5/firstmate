#!/usr/bin/env bash
# Own browser resources for one Firstmate task incarnation.
#
# Usage:
#   fm-browser-lifecycle.sh axi [--session <name>] -- <chrome-devtools-axi args...>
#   fm-browser-lifecycle.sh launch [--timeout <seconds>] -- <Playwright/Puppeteer command...>
#
# `axi` and `launch` are worker-facing entry points. Browser cleanup is tied to
# Firstmate's lifecycle transitions; this command never runs a periodic sweep.
set -eu

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=bin/fm-browser-lifecycle-lib.sh
. "$SCRIPT_DIR/fm-browser-lifecycle-lib.sh"

usage() {
  sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

command_name=${1:-}
[ -n "$command_name" ] || { usage >&2; exit 2; }
shift
case "$command_name" in
  axi)
    fm_browser_axi_exec "$@"
    ;;
  launch)
    state=${FM_BROWSER_STATE:-}
    task=${FM_BROWSER_TASK_ID:-}
    generation=${FM_BROWSER_SPAWN_GEN:-}
    [ -n "$state" ] && [ -n "$task" ] && [ -n "$generation" ] || {
      fm_browser_lifecycle_error "direct browser launch requires the task lifecycle environment from fm-spawn"
      exit 1
    }
    fm_browser_direct_launch "$state" "$task" "$generation" "$@"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
