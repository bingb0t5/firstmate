# shellcheck shell=bash
# Shared GitHub owner/repo parser.
# Usage: . bin/fm-repo-slug-lib.sh; fm_repo_slug "<url>"
#
# ONE OWNER for turning a GitHub remote or PR URL into its owner/repo slug.
# Two callers need the same answer from the same inputs: the bearings snapshot
# derives candidate repositories from recorded pr= URLs and live worktree
# origins (bin/fm-bearings-snapshot.sh), and the PR conflict watcher derives
# them from project clone origins (bin/fm-pr-conflict-watch.sh). A repository
# that one of them names differently than the other would route the same pull
# request two ways, so the parse lives here rather than in each caller.
#
# Both the https and ssh spellings are accepted, a trailing .git, a trailing
# slash, and a /pull/<n> tail are dropped, and a URL that is not GitHub yields
# the empty string rather than a guess.

fm_repo_slug() {  # <url>
  printf '%s' "$1" | sed -n \
    -e 's#^https://github\.com/\([^/]*/[^/]*\)#\1#p' \
    -e 's#^git@github\.com:\([^/]*/[^/]*\)#\1#p' \
    -e 's#^ssh://git@github\.com/\([^/]*/[^/]*\)#\1#p' \
    -e 's#^ssh://git@github\.com:[0-9][0-9]*/\([^/]*/[^/]*\)#\1#p' \
    | sed 's#\.git$##; s#/pull/.*$##; s#/$##'
}
