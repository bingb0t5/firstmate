#!/usr/bin/env bash
# Own browser resources for one Firstmate task incarnation.
#
# Usage:
#   fm-browser-lifecycle.sh axi [--session <name>] -- <chrome-devtools-axi args...>
#   fm-browser-lifecycle.sh launch [--timeout <seconds>] -- <Playwright/Puppeteer command...>
#   fm-browser-lifecycle.sh session-for-task <task-id>
#   fm-browser-lifecycle.sh arm <state> <task-id> <spawn-generation>
#   fm-browser-lifecycle.sh register-axi <state> <task-id> <spawn-generation> <session>
#   fm-browser-lifecycle.sh finalize <state> <task-id> <spawn-generation> <reason>
#   fm-browser-lifecycle.sh finalize-meta <state> <meta> <task-id> <reason>
#
# `axi` and `launch` are worker-facing entry points. Firstmate invokes arm and
# finalize from spawn, control, watcher, and teardown. Browser cleanup is tied
# to those lifecycle transitions; this command never runs a periodic sweep.
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
  session-for-task)
    [ "$#" -eq 1 ] || { usage >&2; exit 2; }
    fm_browser_session_for_task "$1"
    ;;
  arm)
    [ "$#" -eq 3 ] || { usage >&2; exit 2; }
    fm_browser_owner_arm "$1" "$2" "$3"
    ;;
  register-axi)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    fm_browser_owner_register_axi "$1" "$2" "$3" "$4"
    ;;
  finalize)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    fm_browser_owner_finalize "$1" "$2" "$3" "$4"
    ;;
  finalize-meta)
    [ "$#" -eq 4 ] || { usage >&2; exit 2; }
    fm_browser_finalize_meta "$1" "$2" "$3" "$4"
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
