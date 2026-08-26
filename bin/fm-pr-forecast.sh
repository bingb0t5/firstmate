#!/usr/bin/env bash
# Report how the other open GitHub pull requests will merge against a candidate
# before the candidate is merged. This is an internal, read-only helper for
# bin/fm-pr-merge.sh --forecast, not a second merge or conflict control path.
# GitHub metadata is read through gh-axi, all referenced Git objects are fetched
# into a temporary repository, and Git's three-way merge semantics classify each
# open pull request against the current and simulated post-candidate bases.
# Usage: fm-pr-forecast.sh <github-pr-url> [--squash|--merge|--rebase]
set -u
export LC_ALL=C
export GH_PROMPT_DISABLED=1
export GH_NO_UPDATE_NOTIFIER=1
export GIT_TERMINAL_PROMPT=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_AXI="${FM_PR_FORECAST_GH_AXI:-gh-axi}"

# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"

if [ "$#" -lt 1 ] || [ "$#" -gt 2 ] || ! fm_pr_url_parse "$1"; then
  echo "error: forecast requires one canonical GitHub PR URL" >&2
  exit 2
fi
[ "$FM_PR_PROVIDER" = github ] || {
  echo "error: PR conflict forecast is supported for GitHub pull requests only" >&2
  exit 1
}
URL=$FM_PR_URL
PR_OWNER=$FM_PR_OWNER
PR_REPO=$FM_PR_REPO
PR_NUMBER=$FM_PR_NUMBER
METHOD=squash
if [ "$#" -eq 2 ]; then
  case "$2" in
    --squash) METHOD=squash ;;
    --merge) METHOD=merge ;;
    --rebase) METHOD=rebase ;;
    *)
      echo "error: forecast merge method must be --squash, --merge, or --rebase" >&2
      exit 2
      ;;
  esac
fi

command -v jq >/dev/null 2>&1 || {
  echo "error: cannot produce forecast without jq" >&2
  exit 1
}
command -v "$GH_AXI" >/dev/null 2>&1 || {
  echo "error: cannot produce forecast without gh-axi" >&2
  exit 1
}
command -v git >/dev/null 2>&1 || {
  echo "error: cannot produce forecast without git" >&2
  exit 1
}

TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-pr-forecast.XXXXXX") || {
  echo "error: could not create isolated Git forecast repository" >&2
  exit 1
}
cleanup() {
  rm -rf -- "$TMP"
}
trap cleanup EXIT HUP INT TERM

# gh-axi renders successful API results as an axi envelope. The jq expression
# returns base64 so gh-axi cannot reinterpret the JSON payload as TOON. A
# truncated, absent, or malformed body is an unavailable GitHub observation.
GH_API_BODY=
GH_API_READ_CAUSE=
gh_api_json() {
  local query=$1 out line body='' enveloped=0 have_body=0 truncated=false rc=0
  GH_API_BODY=
  GH_API_READ_CAUSE=github
  if ! out=$("$GH_AXI" api POST /graphql --field "query=$query" \
      --jq 'if ((.errors // []) | length) > 0 then error("graphql errors") else @base64 end' \
      --full 2>/dev/null); then
    return 1
  fi
  while IFS= read -r line; do
    case "$line" in
      api_response:) enveloped=1 ;;
      '  body: '*)
        [ "$have_body" -eq 0 ] || continue
        have_body=1
        body=${line#'  body: '}
        ;;
      '  truncated: '*) truncated=${line#'  truncated: '} ;;
    esac
  done <<EOF
$out
EOF
  [ "$truncated" = false ] || {
    GH_API_READ_CAUSE=truncated
    return 1
  }
  if [ "$enveloped" -eq 0 ]; then
    body=$out
  else
    [ "$have_body" -eq 1 ] || return 1
    case "$body" in
      '"'*) body=$(printf '%s' "$body" | jq -r '.' 2>/dev/null) || return 1 ;;
    esac
  fi
  body=$(printf '%s\n' "$body" | base64 -d 2>/dev/null \
    || printf '%s\n' "$body" | base64 -D 2>/dev/null) || return 1
  printf '%s' "$body" | jq -e . >/dev/null 2>&1 || return 1
  GH_API_BODY=$body
}

query_snapshot() {
  local after=$1 after_literal
  if [ -n "$after" ]; then
    case "$after" in
      *[!A-Za-z0-9_+/=-]*) return 1 ;;
    esac
    after_literal=$(jq -rn --arg cursor "$after" '$cursor | tojson')
  else
    after_literal=null
  fi
  gh_api_json "{ repository(owner:\"$PR_OWNER\", name:\"$PR_REPO\") { defaultBranchRef { name target { oid } } pullRequests(states:OPEN, first:100, after:$after_literal) { nodes { number title url isDraft baseRefName baseRefOid headRefName headRefOid headRepository { nameWithOwner } } pageInfo { hasNextPage endCursor } } } }"
}

# Read the complete open set in bounded GraphQL pages. The candidate and every
# comparison PR must be present in the same live observation; a missing page or
# cursor is never silently treated as an empty set.
OPEN_PRS=[]
SNAPSHOT_BASE=
SNAPSHOT_BASE_SHA=
cursor=
seen_cursors=''
while :; do
  query_snapshot "$cursor" || {
    echo "error: GitHub open-PR evidence is unavailable (${GH_API_READ_CAUSE})" >&2
    exit 1
  }
  page=$(printf '%s' "$GH_API_BODY" | jq -c '.data.repository as $r | if ($r | type) != "object" or ($r.defaultBranchRef | type) != "object" or ($r.defaultBranchRef.name | type) != "string" or ($r.defaultBranchRef.target.oid | type) != "string" or ($r.pullRequests | type) != "object" or ($r.pullRequests.nodes | type) != "array" or ($r.pullRequests.pageInfo | type) != "object" then error("incomplete repository result") else {base:$r.defaultBranchRef, prs:$r.pullRequests.nodes, page:$r.pullRequests.pageInfo} end' 2>/dev/null) || {
    echo "error: GitHub open-PR evidence is incomplete" >&2
    exit 1
  }
  base_name=$(printf '%s' "$page" | jq -r '.base.name')
  base_sha=$(printf '%s' "$page" | jq -r '.base.target.oid')
  fm_pr_head_valid "$base_sha" || {
    echo "error: GitHub default-base commit is invalid" >&2
    exit 1
  }
  if [ -z "$SNAPSHOT_BASE" ]; then
    SNAPSHOT_BASE=$base_name
    SNAPSHOT_BASE_SHA=$base_sha
  elif [ "$SNAPSHOT_BASE" != "$base_name" ] || [ "$SNAPSHOT_BASE_SHA" != "$base_sha" ]; then
    echo "error: GitHub default-base evidence changed while reading open PRs" >&2
    exit 1
  fi
  page_prs=$(printf '%s' "$page" | jq -c '.prs')
  OPEN_PRS=$(printf '%s\n%s\n' "$OPEN_PRS" "$page_prs" | jq -sc 'add')
  has_next=$(printf '%s' "$page" | jq -r '.page.hasNextPage | tostring')
  case "$has_next" in
    true|false) ;;
    *)
      echo "error: GitHub open-PR evidence has an invalid page-completeness flag" >&2
      exit 1
      ;;
  esac
  [ "$has_next" = true ] || break
  next_cursor=$(printf '%s' "$page" | jq -r '.page.endCursor // ""')
  [ -n "$next_cursor" ] || {
    echo "error: GitHub open-PR evidence has no continuation cursor" >&2
    exit 1
  }
  case " $seen_cursors " in
    *" $next_cursor "*)
      echo "error: GitHub open-PR evidence repeated a continuation cursor" >&2
      exit 1
      ;;
  esac
  seen_cursors="$seen_cursors $next_cursor"
  cursor=$next_cursor
done

# Validate every field before any Git fetch. This also preserves the PR URL and
# number as the identity shown to the operator rather than trusting a title or
# a task record.
count=$(printf '%s' "$OPEN_PRS" | jq 'length')
[ "$count" -le 10000 ] || {
  echo "error: GitHub open-PR evidence exceeds the forecast bound" >&2
  exit 1
}
seen_numbers=''
candidate_json=
for ((i = 0; i < count; i++)); do
  record=$(printf '%s' "$OPEN_PRS" | jq -c --argjson i "$i" '.[$i]')
  if ! printf '%s' "$record" | jq -e 'type == "object" and (.number | type) == "number" and (.title | type) == "string" and (.url | type) == "string" and (.baseRefName | type) == "string" and (.baseRefOid | type) == "string" and (.headRefOid | type) == "string"' >/dev/null 2>&1; then
    echo "error: GitHub open-PR evidence contains an incomplete record" >&2
    exit 1
  fi
  number=$(printf '%s' "$record" | jq -r '.number // empty')
  title=$(printf '%s' "$record" | jq -r '.title // empty')
  url=$(printf '%s' "$record" | jq -r '.url // empty')
  base_ref=$(printf '%s' "$record" | jq -r '.baseRefName // empty')
  record_base_sha=$(printf '%s' "$record" | jq -r '.baseRefOid // empty')
  head_sha=$(printf '%s' "$record" | jq -r '.headRefOid // empty')
  case "$number" in ''|*[!0-9]*) echo "error: GitHub open-PR evidence has an invalid PR number" >&2; exit 1 ;; esac
  [ "$number" -gt 0 ] || { echo "error: GitHub open-PR evidence has an invalid PR number" >&2; exit 1; }
  case " $seen_numbers " in *" $number "*) echo "error: GitHub open-PR evidence repeated PR #$number" >&2; exit 1 ;; esac
  seen_numbers="$seen_numbers $number"
  expected_url="https://github.com/$PR_OWNER/$PR_REPO/pull/$number"
  if [ -z "$title" ] || [ -z "$url" ] || [ "$url" != "$expected_url" ] \
    || [ -z "$base_ref" ] || [ -z "$record_base_sha" ] \
    || ! fm_pr_head_valid "$record_base_sha" || ! fm_pr_head_valid "$head_sha"; then
    echo "error: GitHub open-PR evidence for #$number is incomplete or has an invalid identity" >&2
    exit 1
  fi
  if [ "$number" -eq "$PR_NUMBER" ]; then
    candidate_json=$record
  fi
done
[ -n "$candidate_json" ] || {
  echo "error: candidate PR is not open in the live GitHub open set" >&2
  exit 1
}
candidate_base_ref=$(printf '%s' "$candidate_json" | jq -r '.baseRefName')
candidate_base_sha=$(printf '%s' "$candidate_json" | jq -r '.baseRefOid')
candidate_head_sha=$(printf '%s' "$candidate_json" | jq -r '.headRefOid')
candidate_url=$(printf '%s' "$candidate_json" | jq -r '.url')
[ "$candidate_url" = "$URL" ] || {
  echo "error: live GitHub candidate identity does not match the requested PR" >&2
  exit 1
}
[ "$candidate_base_ref" = "$SNAPSHOT_BASE" ] && [ "$candidate_base_sha" = "$SNAPSHOT_BASE_SHA" ] || {
  echo "error: candidate PR does not target the observed default base" >&2
  exit 1
}

# The forecast is for the base that this guarded merge would update. PRs aimed
# at another branch or another base commit are not comparable evidence, so the
# whole report is refused instead of mixing incomparable merge tests.
for ((i = 0; i < count; i++)); do
  record=$(printf '%s' "$OPEN_PRS" | jq -c --argjson i "$i" '.[$i]')
  number=$(printf '%s' "$record" | jq -r '.number')
  base_ref=$(printf '%s' "$record" | jq -r '.baseRefName')
  record_base_sha=$(printf '%s' "$record" | jq -r '.baseRefOid')
  [ "$number" -eq "$PR_NUMBER" ] || {
    [ "$base_ref" = "$SNAPSHOT_BASE" ] && [ "$record_base_sha" = "$SNAPSHOT_BASE_SHA" ] || {
      echo "error: open PR #$number targets a different or stale base; forecast unavailable" >&2
      exit 1
    }
  }
done

REPO_URL="https://github.com/$PR_OWNER/$PR_REPO.git"
git -C "$TMP" init -q || { echo "error: could not initialize isolated Git forecast repository" >&2; exit 1; }
git -C "$TMP" remote add origin "$REPO_URL" || { echo "error: could not configure isolated Git forecast repository" >&2; exit 1; }
fetch_ref() {
  local source=$1 destination=$2 expected=$3 label=$4 actual
  if ! git -C "$TMP" fetch --no-tags --quiet origin "$source:$destination" >/dev/null 2>&1; then
    echo "error: Git evidence is unavailable while fetching $label" >&2
    return 1
  fi
  actual=$(git -C "$TMP" rev-parse --verify "$destination^{commit}" 2>/dev/null) || {
    echo "error: Git evidence is unavailable for $label" >&2
    return 1
  }
  [ "$actual" = "$expected" ] || {
    echo "error: Git ref $label resolved to $actual, expected $expected" >&2
    return 1
  }
}
if ! git -C "$TMP" check-ref-format "refs/heads/$SNAPSHOT_BASE" >/dev/null 2>&1; then
  echo "error: GitHub default-base ref name is invalid" >&2
  exit 1
fi
base_ref_name="refs/fm-pr-forecast/base"
fetch_ref "refs/heads/$SNAPSHOT_BASE" "$base_ref_name" "$SNAPSHOT_BASE_SHA" "the default base" || exit 1

for ((i = 0; i < count; i++)); do
  record=$(printf '%s' "$OPEN_PRS" | jq -c --argjson i "$i" '.[$i]')
  number=$(printf '%s' "$record" | jq -r '.number')
  head_sha=$(printf '%s' "$record" | jq -r '.headRefOid')
  fetch_ref "refs/pull/$number/head" "refs/fm-pr-forecast/pr-$number" "$head_sha" "PR #$number" || exit 1
done

merge_state() {
  local base=$1 head=$2 output=$3 rc summary
  if git -C "$TMP" merge-tree --write-tree --messages "$base" "$head" >"$output" 2>&1; then
    MERGE_STATE=clean
    MERGE_EVIDENCE=clean
    return 0
  else
    rc=$?
  fi
  if [ "$rc" -eq 1 ]; then
    summary=$(awk '/^CONFLICT / { gsub(/[[:space:]]+/, " "); if (n++ < 3) { if (s != "") s=s";"; s=s$0 } } END { print s }' "$output")
    MERGE_STATE=conflicted
    MERGE_EVIDENCE=${summary:-conflict reported by git merge-tree}
    return 0
  fi
  MERGE_STATE=unavailable
  MERGE_EVIDENCE=git-merge-tree-failed
  return 1
}

candidate_result="$TMP/candidate-merge"
merge_state "$base_ref_name" "refs/fm-pr-forecast/pr-$PR_NUMBER" "$candidate_result" || {
  echo "error: candidate merge evidence is unavailable" >&2
  exit 1
}
[ "$MERGE_STATE" = clean ] || {
  echo "error: candidate PR is already conflicting with the current base; forecast unavailable" >&2
  exit 1
}
post_base_ref=""
post_tree=$(head -n 1 "$candidate_result")
case "$post_tree" in
  ''|*[!0-9a-f]*) echo "error: Git candidate merge produced no valid result tree" >&2; exit 1 ;;
esac
git -C "$TMP" cat-file -e "$post_tree^{tree}" 2>/dev/null || {
  echo "error: Git candidate merge result tree is unavailable" >&2
  exit 1
}

case "$METHOD" in
  squash|merge)
    parents=(-p "$base_ref_name")
    [ "$METHOD" = merge ] && parents+=(-p "refs/fm-pr-forecast/pr-$PR_NUMBER")
    if ! post_base=$(printf 'firstmate PR conflict forecast\n' | \
        GIT_AUTHOR_NAME='Firstmate forecast' GIT_AUTHOR_EMAIL='firstmate-forecast@invalid' \
        GIT_COMMITTER_NAME='Firstmate forecast' GIT_COMMITTER_EMAIL='firstmate-forecast@invalid' \
        git -C "$TMP" commit-tree "$post_tree" "${parents[@]}" 2>/dev/null); then
      echo "error: could not create isolated post-candidate Git base" >&2
      exit 1
    fi
    post_base_ref=$post_base
    ;;
  rebase)
    merge_base=$(git -C "$TMP" merge-base "$base_ref_name" "refs/fm-pr-forecast/pr-$PR_NUMBER" 2>/dev/null) || {
      echo "error: Git rebase evidence is unavailable" >&2
      exit 1
    }
    rebase_work="$TMP/rebase-work"
    git -C "$TMP" worktree add --detach "$rebase_work" "refs/fm-pr-forecast/pr-$PR_NUMBER" >/dev/null 2>&1 || {
      echo "error: could not create isolated Git rebase worktree" >&2
      exit 1
    }
    if ! git -C "$rebase_work" rebase --onto "$base_ref_name" "$merge_base" >/dev/null 2>&1; then
      echo "error: candidate rebase evidence is unavailable" >&2
      exit 1
    fi
    post_base_ref=$(git -C "$rebase_work" rev-parse --verify HEAD 2>/dev/null) || {
      echo "error: rebased candidate Git evidence is unavailable" >&2
      exit 1
    }
    ;;
esac

RESULTS="$TMP/results"
: > "$RESULTS"
current_count=0
new_count=0
clean_count=0
for ((i = 0; i < count; i++)); do
  record=$(printf '%s' "$OPEN_PRS" | jq -c --argjson i "$i" '.[$i]')
  number=$(printf '%s' "$record" | jq -r '.number')
  [ "$number" -eq "$PR_NUMBER" ] && continue
  title=$(printf '%s' "$record" | jq -r '.title' | tr '\t\r\n' '   ')
  url=$(printf '%s' "$record" | jq -r '.url')
  head_sha=$(printf '%s' "$record" | jq -r '.headRefOid')
  current_output="$TMP/current-$number"
  post_output="$TMP/post-$number"
  merge_state "$base_ref_name" "refs/fm-pr-forecast/pr-$number" "$current_output" || {
    echo "error: current-base Git evidence is unavailable for PR #$number" >&2
    exit 1
  }
  current_state=$MERGE_STATE
  current_evidence=$MERGE_EVIDENCE
  merge_state "$post_base_ref" "refs/fm-pr-forecast/pr-$number" "$post_output" || {
    echo "error: post-candidate Git evidence is unavailable for PR #$number" >&2
    exit 1
  }
  post_state=$MERGE_STATE
  post_evidence=$MERGE_EVIDENCE
  case "$current_state:$post_state" in
    conflicted:*)
      current_count=$((current_count + 1))
      printf 'already-conflicting: pr=%s url=%s head=%s title=%s evidence=current-base-git-merge-tree(%s)\n' \
        "$number" "$url" "$head_sha" "$title" "$current_evidence" >> "$RESULTS"
      ;;
    clean:conflicted)
      new_count=$((new_count + 1))
      printf 'newly-conflicting-after-candidate: pr=%s url=%s head=%s title=%s evidence=post-candidate-git-merge-tree(%s)\n' \
        "$number" "$url" "$head_sha" "$title" "$post_evidence" >> "$RESULTS"
      ;;
    clean:clean)
      clean_count=$((clean_count + 1))
      printf 'still-clean-after-candidate: pr=%s url=%s head=%s title=%s evidence=current-and-post-candidate-git-merge-tree-clean\n' \
        "$number" "$url" "$head_sha" "$title" >> "$RESULTS"
      ;;
    *)
      echo "error: Git merge evidence for PR #$number is incomplete; forecast unavailable" >&2
      exit 1
      ;;
  esac
done

printf 'forecast: candidate=%s candidate-head=%s method=%s current-base=%s current-base-sha=%s post-candidate-base=%s open-prs=%s other-open-prs=%s evidence=fetched-GitHub-refs+git-merge-tree\n' \
  "$URL" "$candidate_head_sha" "$METHOD" "$SNAPSHOT_BASE" "$SNAPSHOT_BASE_SHA" "$post_base_ref" "$count" "$((count - 1))"
printf 'already-conflicting: count=%s\n' "$current_count"
printf 'newly-conflicting-after-candidate: count=%s\n' "$new_count"
printf 'still-clean-after-candidate: count=%s\n' "$clean_count"
cat "$RESULTS"
