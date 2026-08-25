#!/usr/bin/env bash
# fm-pending-reply.sh - list still-open pending obligations for this home.
#
# bin/fm-pending-reply-lib.sh owns the record format, create/resolve lifecycle,
# recovery, and escalation. This command is the inspectable listing surface:
# firstmate answers "was this work actually requested or still open" from this
# listing, not from a grep of chats or another task's journal.
#
# Usage:
#   fm-pending-reply.sh list
#       Print every still-open obligation in this home, one
#       TSV line each:
#         corr=<id><TAB>task=<id><TAB>phase=<phase><TAB>created=<epoch><TAB>summary=<text>
#       Sorted by created epoch, then corr id. Prints nothing and exits 0
#       when none are open. A valid answered obligation is omitted; a malformed
#       record that claims phase=resolved remains visible with phase=unknown.
#   fm-pending-reply.sh --help
#
# Environment:
#   FM_HOME              operational home; required, same fail-closed rule as
#                        fm-send (a listing must not silently resolve against
#                        another home).
#   FM_STATE_OVERRIDE    optional state dir (tests).
#
# Exit codes: 0 listed (including empty), 2 usage, 1 missing home/state.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'EOF' >&2
Usage:
  fm-pending-reply.sh list
  fm-pending-reply.sh --help
EOF
  exit 2
}

CMD=${1:-}
case "$CMD" in
  --help|-h)
    cat <<'EOF'
Usage:
  fm-pending-reply.sh list
  fm-pending-reply.sh --help

list  Print every still-open pending obligation in this home.
      Format: corr=<id><TAB>task=<id><TAB>phase=<phase><TAB>created=<epoch><TAB>summary=<text>
      A valid answered obligation is omitted. A malformed record that claims
      phase=resolved remains visible with phase=unknown. Empty listing exits 0.
EOF
    exit 0
    ;;
  list)
    [ "$#" -eq 1 ] || usage
    ;;
  *)
    usage
    ;;
esac

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-pending-reply refuses to list obligations without an explicit firstmate home" >&2
  exit 1
fi
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-pending-reply cannot list this home's obligations" >&2
  exit 1
fi
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-pending-reply cannot list obligations for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# Source after the FM_HOME check: helpers this library pulls in would otherwise
# default FM_HOME to the code root and silently list the wrong home.
# shellcheck source=bin/fm-pending-reply-lib.sh
. "$SCRIPT_DIR/fm-pending-reply-lib.sh"

fm_pending_reply_list_open "$STATE"
