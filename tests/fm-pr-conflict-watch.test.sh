#!/usr/bin/env bash
# Tests for fm-pr-conflict-watch.sh merge-conflict detection and dedupe.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

WATCH="$ROOT/bin/fm-pr-conflict-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-conflict-watch)
BASE_PATH=$PATH
JQ_BIN=$(command -v jq) || fail "jq is required for these tests"

fm_git_identity fmtest fmtest@example.invalid

REPO_A=acme/alpha
REPO_B=acme/beta
HEAD_ONE=1111111111111111111111111111111111111111
HEAD_TWO=2222222222222222222222222222222222222222

# The fake stands in for gh-axi 0.1.32. It models the surface that CLI actually
# exposes rather than a convenient one: `pr list` has no --json flag and its
# --fields selector cannot name mergeability, and `api` answers with an axi
# envelope (api_response/body/truncated) rather than with raw JSON. Unknown
# flags are refused with the real VALIDATION_ERROR exit 2, so a watcher that
# reaches for a flag gh-axi does not have fails the suite here instead of
# falling silent in production.
#
# Fixtures are GitHub REST payloads and the requested --jq expression is applied
# to them with the real jq, so the tests exercise the watcher's real query and
# its real envelope decoding rather than a hand-built answer.
make_fake_gh_axi() {
  cat > "$1" <<'SH'
#!/usr/bin/env bash
set -u
fixture="$FM_TEST_PR_CONFLICT_FIXTURE"

die_validation() {
  printf 'error: "%s"\n' "$1"
  printf 'code: VALIDATION_ERROR\n'
  exit 2
}

# gh-axi quotes a scalar as a JSON string literal when it would otherwise be
# ambiguous, and prints it bare when it would not. An empty value is always
# quoted. Numbers and booleans are printed with no envelope at all.
emit_envelope() {
  local body=$1 truncated=$2 quote=0 nl
  nl=$'\n'
  [ -n "$body" ] || quote=1
  case "$body" in
    *:*|*'"'*|*'\'*|*"$nl"*|*"$(printf '\t')"*) quote=1 ;;
  esac
  printf 'api_response:\n'
  if [ "$quote" -eq 1 ]; then
    printf '  body: %s\n' "$(jq -nr --arg v "$body" '$v | tojson')"
  else
    printf '  body: %s\n' "$body"
  fi
  printf '  truncated: %s\n' "$truncated"
}

cmd=${1:-}
shift || true

case "$cmd" in
  pr)
    sub=${1:-}
    shift || true
    case "$sub" in
      list|view) ;;
      *) die_validation "unknown subcommand for gh-axi pr: $sub" ;;
    esac
    while [ "$#" -gt 0 ]; do
      case "$1" in
        --repo|--state|--limit|--base|--head|--author|--assignee|--label) shift 2 ;;
        --draft|--comments|--reviews|--full) shift ;;
        --fields)
          # The real selector exists but cannot name any field this watcher
          # needs, so asking for one is the same refusal the real CLI gives.
          case "$2" in
            *number*|*mergeable*|*headRefOid*|*isDraft*|*title*|*url*)
              die_validation "Unknown field(s); available: body, createdAt, labels, mergedAt, milestone, url" ;;
          esac
          shift 2
          ;;
        -*) die_validation "unknown flag for gh-axi pr $sub: $1" ;;
        *) shift ;;
      esac
    done
    exit 0
    ;;
  api) ;;
  *) die_validation "unknown command: $cmd" ;;
esac

path=
expr=.
full=0
gql=
while [ "$#" -gt 0 ]; do
  case "$1" in
    --jq) expr=$2; shift 2 ;;
    --full) full=1; shift ;;
    --paginate) shift ;;
    --field)
      case "$2" in
        query=*) gql=${2#query=} ;;
      esac
      shift 2
      ;;
    --header|--template|-X) shift 2 ;;
    GET|POST|PUT|PATCH|DELETE|HEAD) shift ;;
    -*) die_validation "unknown flag for gh-axi api: $1" ;;
    *) [ -n "$path" ] || path=$1; shift ;;
  esac
done

[ "$path" = /graphql ] || { printf 'error: "not found"\n' >&2; exit 1; }
[ -n "$gql" ] || die_validation "gh-axi api POST /graphql requires --field query="

owner=$(printf '%s' "$gql" | sed -n 's/.*owner:"\([^"]*\)".*/\1/p')
name=$(printf '%s' "$gql" | sed -n 's/.*name:"\([^"]*\)".*/\1/p')
repo="$owner/$name"
case "$gql" in
  *'pullRequest(number:'*)
    mode=view
    number=$(printf '%s' "$gql" | sed -n 's/.*pullRequest(number:\([0-9]*\)).*/\1/p')
    ;;
  *pullRequests*)
    mode=list
    first=$(printf '%s' "$gql" | sed -n 's/.*first:\([0-9]*\).*/\1/p')
    ;;
  *) die_validation "unsupported graphql document" ;;
esac

slug=${repo//\//__}

# A repository GitHub cannot be read for at the transport level, injected per
# repository: the call itself fails.
case " ${FM_TEST_PR_CONFLICT_FAIL:-} " in
  *" $repo "*)
    printf 'error: "read failed"\n' >&2
    exit 1
    ;;
esac

# A repository burning sweep budget, so the budget-cut path can be reached
# without depending on real network timing.
case " ${FM_TEST_PR_CONFLICT_SLOW:-} " in
  *" $repo "*) sleep "${FM_TEST_PR_CONFLICT_SLOW_SECS:-2}" ;;
esac

doc=$(mktemp) || exit 1
trap 'rm -f -- "$doc"' EXIT

# GraphQL answers an unreadable repository with HTTP 200, a null repository and
# an errors array - not with a transport failure. This is the shape that would
# otherwise be indistinguishable from a repository with no open pull requests.
case " ${FM_TEST_PR_CONFLICT_NOREPO:-} " in
  *" $repo "*)
    printf '{"data":{"repository":null},"errors":[{"type":"NOT_FOUND","message":"Could not resolve to a Repository"}]}\n' > "$doc"
    values=$(jq -c "$expr" "$doc" 2>/dev/null) || { printf 'error: "jq failed"\n' >&2; exit 1; }
    emit_envelope "$(jq -r "$expr" "$doc")" false
    exit 0
    ;;
esac

if [ "$mode" = list ]; then
  file="$fixture/pulls/${slug}.json"
  [ -f "$file" ] || printf '[]\n' > "$file"
  jq -c "{data:{repository:{pullRequests:{nodes:(.[:$first])}}}}" "$file" > "$doc" || exit 1
else
  file="$fixture/pull/${slug}-${number}.json"
  seqfile="$fixture/pull/${slug}-${number}.seq"
  if [ -f "$seqfile" ]; then
    idx=$(cat "$seqfile")
    idx=$((idx + 1))
    printf '%s\n' "$idx" > "$seqfile"
    jq -c "{data:{repository:{pullRequest:(.[$((idx - 1))] // .[-1])}}}" "$file" > "$doc" || exit 1
  elif [ -f "$file" ]; then
    jq -c '{data:{repository:{pullRequest:.}}}' "$file" > "$doc" || exit 1
  else
    printf '{"data":{"repository":{"pullRequest":null}}}\n' > "$doc"
  fi
fi

values=$(jq -c "$expr" "$doc" 2>/dev/null) || { printf 'error: "jq failed"\n' >&2; exit 1; }

# A lone number or boolean is rendered bare by gh-axi, with no envelope at all.
if [ "$(printf '%s\n' "$values" | wc -l)" -eq 1 ]; then
  case "$values" in
    true|false|null|-[0-9]*|[0-9]*)
      printf '%s\n' "$values"
      exit 0
      ;;
  esac
fi

body=$(jq -r "$expr" "$doc" 2>/dev/null) || { printf 'error: "jq failed"\n' >&2; exit 1; }

truncated=false
if [ "${FM_TEST_PR_CONFLICT_TRUNCATE:-0}" = 1 ]; then
  truncated=true
elif [ "$full" -eq 0 ] && [ "${#body}" -gt 200 ]; then
  body=${body:0:200}
  truncated=true
fi

emit_envelope "$body" "$truncated"
exit 0
SH
  chmod +x "$1"
}

make_home() {
  local name=$1 home fakebin fixture
  home="$TMP_ROOT/$name"
  fixture="$home/fixture"
  fakebin="$home/fakebin"
  mkdir -p "$home/state" "$home/data" "$home/projects/alpha" "$home/projects/beta" \
    "$fixture/pulls" "$fixture/pull" "$fakebin"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- alpha - alpha repo (added 2026-08-25)
- beta - beta repo (added 2026-08-25)
MD
  cat > "$home/data/secondmates.md" <<'MD'
# Second mates

- team-a - owns alpha (home: /tmp/team-a; scope: alpha; projects: alpha; added 2026-08-25)
- team-b - owns beta (home: /tmp/team-b; scope: beta; projects: beta; added 2026-08-25)
MD
  git -C "$home/projects/alpha" init -q
  git -C "$home/projects/alpha" remote add origin "https://github.com/$REPO_A.git"
  git -C "$home/projects/beta" init -q
  git -C "$home/projects/beta" remote add origin "https://github.com/$REPO_B.git"
  fm_slug=$(git -C "$ROOT" remote get-url origin 2>/dev/null | sed -n 's#.*github\.com[:/]\([^/]*/[^/]*\)#\1#p' | sed 's#\.git$##')
  make_fake_gh_axi "$fakebin/gh-axi"
  ln -sf "$JQ_BIN" "$fakebin/jq"
  if [ -n "$fm_slug" ]; then
    reset_repo "$home" "$fm_slug"
  fi
  printf '%s\n' "$home"
}

reset_repo() {
  local home=$1 repo=$2 slug
  slug=${repo//\//__}
  printf '[]\n' > "$home/fixture/pulls/${slug}.json"
  rm -f "$home/fixture/pull/${slug}-"*
}

# One open pull request, in the GraphQL node shape the watcher actually reads.
# The list read carries mergeability, so only an UNKNOWN pull request needs a
# per-pull-request fixture as well.
add_pr() {
  local home=$1 repo=$2 number=$3 head=$4 draft=$5 mergeable=$6 title=$7
  local slug lf url
  slug=${repo//\//__}
  url="https://github.com/$repo/pull/$number"
  lf="$home/fixture/pulls/${slug}.json"
  [ -f "$lf" ] || printf '[]\n' > "$lf"
  jq --argjson n "$number" --arg t "$title" --arg u "$url" --arg h "$head" \
    --argjson d "$draft" --arg m "$mergeable" \
    '. + [{number:$n, title:$t, url:$u, headRefOid:$h, isDraft:$d, mergeable:$m}]' "$lf" > "$lf.tmp" \
    && mv "$lf.tmp" "$lf"
  rm -f "$home/fixture/pull/${slug}-${number}.json" \
    "$home/fixture/pull/${slug}-${number}.seq"
}

# A pull request GitHub has not judged yet, plus the scripted sequence of
# rereads that follows it, so lazy mergeability settling part way through can be
# exercised.
add_pr_sequence() {
  local home=$1 repo=$2 number=$3 head=$4 title=$5
  shift 5
  local slug lf vf url m
  slug=${repo//\//__}
  url="https://github.com/$repo/pull/$number"
  lf="$home/fixture/pulls/${slug}.json"
  vf="$home/fixture/pull/${slug}-${number}.json"
  [ -f "$lf" ] || printf '[]\n' > "$lf"
  jq --argjson n "$number" --arg t "$title" --arg u "$url" --arg h "$head" \
    '. + [{number:$n, title:$t, url:$u, headRefOid:$h, isDraft:false, mergeable:"UNKNOWN"}]' "$lf" > "$lf.tmp" \
    && mv "$lf.tmp" "$lf"
  : > "$vf.parts"
  for m in "$@"; do
    # Each entry is "mergeable[:head[:draft]]", so a reread can settle on
    # metadata the listing never carried.
    local state=${m%%:*} h=$head d=false rest
    case "$m" in
      *:*)
        rest=${m#*:}
        h=${rest%%:*}
        case "$rest" in *:*) d=${rest#*:} ;; esac
        ;;
    esac
    jq -nc --arg h "$h" --arg m "$state" --argjson d "$d" \
      '{headRefOid:$h, isDraft:$d, mergeable:$m}' >> "$vf.parts"
  done
  jq -s '.' "$vf.parts" > "$vf"
  rm -f "$vf.parts"
  printf '0\n' > "$home/fixture/pull/${slug}-${number}.seq"
}

view_reads() {
  local home=$1 repo=$2 number=$3 slug
  slug=${repo//\//__}
  cat "$home/fixture/pull/${slug}-${number}.seq"
}

run_check() {
  local home=$1 out=$2
  shift 2
  local status=0
  env FM_CHECK_TIMEOUT=30 FM_PR_CONFLICT_INTERVAL=0 FM_PR_CONFLICT_UNKNOWN_WAIT=0 \
    FM_HOME="$home" FM_ROOT="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_PR_CONFLICT_FIXTURE="$home/fixture" \
    PATH="$home/fakebin:$BASE_PATH" "$@" "$WATCH" >"$out" 2>&1 || status=$?
  expect_code 0 "$status" "check exit"
}

# The fake gh-axi is only useful as a regression net if it refuses what the real
# CLI refuses and answers in the shape the real CLI answers in. Both were
# verified against gh-axi 0.1.32 directly.
test_fake_gh_axi_matches_the_real_cli_contract() {
  local home status=0 out
  home=$(make_home fake-contract)
  out=$(env FM_TEST_PR_CONFLICT_FIXTURE="$home/fixture" PATH="$home/fakebin:$BASE_PATH" \
    gh-axi pr list --repo "$REPO_A" --state open --limit 2 \
    --json number,title,url,headRefOid,isDraft,mergeable 2>&1) || status=$?
  expect_code 2 "$status" "gh-axi has no --json flag and must refuse it"
  assert_contains "$out" "unknown flag for gh-axi pr list: --json" "refusal must name the flag"

  status=0
  out=$(env FM_TEST_PR_CONFLICT_FIXTURE="$home/fixture" PATH="$home/fakebin:$BASE_PATH" \
    gh-axi pr list --repo "$REPO_A" --fields number,mergeable 2>&1) || status=$?
  expect_code 2 "$status" "the real --fields selector cannot name mergeability"

  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken"
  out=$(env FM_TEST_PR_CONFLICT_FIXTURE="$home/fixture" PATH="$home/fakebin:$BASE_PATH" \
    gh-axi api POST /graphql \
    --field query='{ repository(owner:"acme", name:"alpha") { pullRequests(states:OPEN, first:5) { nodes { number mergeable isDraft title url headRefOid } } } }' \
    --jq '[.data.repository.pullRequests.nodes[] | [(.number|tostring), (.mergeable)] | @tsv] | join("\n")' --full 2>&1)
  assert_contains "$out" "api_response:" "a graphql read answers with an axi envelope"
  assert_contains "$out" "truncated: false" "the envelope carries a truncation flag"
  assert_contains "$out" 'body: "7\tCONFLICTING"' \
    "one read carries mergeability for every open pull request"

  # The trap this guards: GraphQL reports an unreadable repository with HTTP
  # 200 and a null repository, which through a plain field selection is
  # byte-identical to a repository with no open pull requests.
  status=0
  out=$(env FM_TEST_PR_CONFLICT_FIXTURE="$home/fixture" \
    FM_TEST_PR_CONFLICT_NOREPO="$REPO_A" PATH="$home/fakebin:$BASE_PATH" \
    gh-axi api POST /graphql \
    --field query='{ repository(owner:"acme", name:"alpha") { pullRequests(states:OPEN, first:5) { nodes { number } } } }' \
    --jq '[.data.repository.pullRequests.nodes[]? | .number] | join(",")' --full 2>&1) || status=$?
  expect_code 0 "$status" "an unresolvable repository still answers 200"
  assert_contains "$out" 'body: ""' \
    "an unresolvable repository is empty, not an error, unless the query guards it"
  pass "the fake gh-axi refuses what gh-axi refuses and answers in its envelope"
}

# The watcher and the bearings snapshot must name the same repository from the
# same remote, so the shared parser they both source is exercised directly here:
# a slug that differed between them would route one pull request two ways.
test_repo_slug_parses_github_remotes() {
  local got
  # shellcheck source=bin/fm-repo-slug-lib.sh
  # shellcheck disable=SC1091
  . "$ROOT/bin/fm-repo-slug-lib.sh"
  local url expected
  while IFS='|' read -r url expected; do
    [ -n "$url" ] || continue
    got=$(fm_repo_slug "$url")
    [ "$got" = "$expected" ] \
      || fail "fm_repo_slug '$url' expected '$expected', got '$got'"
  done <<'CASES'
https://github.com/acme/alpha.git|acme/alpha
https://github.com/acme/alpha|acme/alpha
https://github.com/acme/alpha/|acme/alpha
https://github.com/acme/alpha/pull/12|acme/alpha
git@github.com:acme/alpha.git|acme/alpha
ssh://git@github.com/acme/alpha.git|acme/alpha
ssh://git@github.com:22/acme/alpha.git|acme/alpha
https://gitlab.com/acme/alpha.git|
https://notgithub.com/acme/alpha.git|
https://github.com.evil.example/acme/alpha.git|
git@notgithub.com:acme/alpha.git|
ssh://git@github.com.evil.example:22/acme/alpha.git|
ssh://git@github.com:notaport/acme/alpha.git|
/home/example/projects/alpha|
CASES
  pass "the shared remote parser resolves GitHub slugs and refuses to guess"
}

test_newly_conflicted_wakes() {
  local home out
  home=$(make_home wake-new)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "pr-conflict:" "missing wake prefix"
  assert_contains "$(cat "$out")" "owner-team=team-a" "missing owner team"
  assert_contains "$(cat "$out")" "repo=$REPO_A" "missing repo"
  assert_contains "$(cat "$out")" "number=7" "missing number"
  assert_contains "$(cat "$out")" "head=$HEAD_ONE" "missing head"
  assert_contains "$(cat "$out")" "draft=no" "missing draft flag"
  assert_contains "$(cat "$out")" "title=Broken" "missing title"
  assert_contains "$(cat "$out")" "url=https://github.com/$REPO_A/pull/7" "missing url"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "wake must be one line"
  pass "newly conflicted PR wakes once with routing fields"
}

test_same_head_stays_silent() {
  local home out
  home=$(make_home wake-silent)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "second poll with same head should stay silent: $(cat "$out")"
  pass "same conflicted head stays silent on the next poll"
}

test_new_head_after_force_update_wakes_again() {
  local home out
  home=$(make_home wake-new-head)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first head should wake"
  reset_repo "$home" "$REPO_A"
  add_pr "$home" "$REPO_A" 7 "$HEAD_TWO" false CONFLICTING "Broken again"
  : > "$out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "head=$HEAD_TWO" "force-updated head should wake again"
  pass "new head after force-update wakes again"
}

test_unknown_never_reported() {
  local home out
  home=$(make_home wake-unknown)
  add_pr_sequence "$home" "$REPO_A" 7 "$HEAD_ONE" "Maybe" UNKNOWN UNKNOWN UNKNOWN
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=3
  [ ! -s "$out" ] || fail "persistent unknown mergeability must stay silent: $(cat "$out")"
  # The fake's cursor is how many rereads the check actually made, so a silent
  # run that never reread is not mistaken for the unknown state being handled.
  [ "$(view_reads "$home" "$REPO_A" 7)" = 3 ] \
    || fail "unknown should be reread up to the attempt limit, got $(view_reads "$home" "$REPO_A" 7)"
  pass "persistent unknown mergeability is never reported as conflicted or clean"
}

test_unknown_resolving_to_conflicting_wakes() {
  local home out
  home=$(make_home wake-unknown-conflict)
  add_pr_sequence "$home" "$REPO_A" 7 "$HEAD_ONE" "Maybe" UNKNOWN CONFLICTING
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=3
  assert_contains "$(cat "$out")" "number=7" "a settled conflict must wake"
  assert_contains "$(cat "$out")" "head=$HEAD_ONE" "settled wake carries the head"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=3
  [ ! -s "$out" ] || fail "a settled conflict must stay silent on the next poll: $(cat "$out")"
  pass "unknown mergeability that settles on a conflict wakes once"
}

test_unknown_wake_uses_the_head_the_reread_judged() {
  local home out
  home=$(make_home wake-unknown-head)
  add_pr_sequence "$home" "$REPO_A" 7 "$HEAD_ONE" "Maybe" "CONFLICTING:$HEAD_TWO"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "head=$HEAD_TWO" "the wake must name the head the reread judged"
  assert_not_contains "$(cat "$out")" "head=$HEAD_ONE" "the stale listed head must not label the wake"
  # The next sweep sees the force-updated head as the listed one, and it is the
  # same conflict that already woke, so it must not wake a second time.
  reset_repo "$home" "$REPO_A"
  add_pr "$home" "$REPO_A" 7 "$HEAD_TWO" false CONFLICTING "Maybe"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the reread head must be what was recorded: $(cat "$out")"
  pass "a reread wake is labelled and deduped by the head it judged"
}

# A sweep that finds more conflicts than one line can carry must not record the
# ones it never printed: their heads do not change, so nothing would ever
# re-trigger them and they would be lost for good.
test_conflicts_past_the_line_cap_wake_on_a_later_sweep() {
  local home out i seen='' round total=12 number
  home=$(make_home wake-cap)
  i=1
  while [ "$i" -le "$total" ]; do
    add_pr "$home" "$REPO_A" "$i" "$HEAD_ONE" false CONFLICTING "Conflicted branch $i"
    i=$((i + 1))
  done
  out="$home/out.txt"
  round=0
  while [ "$round" -lt 6 ]; do
    : > "$out"
    run_check "$home" "$out"
    [ -s "$out" ] || break
    [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "every wake must be one line"
    while IFS= read -r number; do
      seen="$seen $number"
    done < <(tr ' ' '\n' < "$out" | sed -n 's/^number=\([0-9][0-9]*\)$/\1/p')
    round=$((round + 1))
  done
  [ "$round" -gt 1 ] || fail "12 conflicts cannot fit in one capped line; expected more than one wake"
  i=1
  while [ "$i" -le "$total" ]; do
    case " $seen " in
      *" $i "*) ;;
      *) fail "conflict $i was never reported across $round wakes" ;;
    esac
    i=$((i + 1))
  done
  [ ! -s "$out" ] || fail "the fleet should fall silent once every conflict has woken"
  pass "conflicts cut by the line cap wake on a later sweep instead of being lost"
}

# The dedupe record is not accumulate-only: a conflict the sweep no longer
# observes is dropped, so the record stays the size of the live conflict set.
# The proof is behavioural - a dropped key cannot suppress the same conflict if
# it comes back.
test_resolved_conflicts_leave_the_record() {
  local home out
  home=$(make_home record-prune)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  reset_repo "$home" "$REPO_A"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a closed pull request must not wake: $(cat "$out")"
  # state/.pr-conflict-watch is this script's own persisted record; its
  # reported keys are the contract being asserted.
  assert_not_contains "$(cat "$home/state/.pr-conflict-watch")" "$HEAD_ONE" \
    "the record must not keep a key for a pull request it no longer sees"
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken"
  : > "$out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "number=7" "a conflict that comes back must wake again"
  pass "keys for conflicts the sweep no longer observes leave the record"
}

# A sweep that discovers no repositories at all read nothing, so it must not be
# taken as proof that the fleet stopped working in the repositories the record
# names. Erasing the record there would re-wake every unchanged conflict as soon
# as discovery recovered.
test_empty_discovery_keeps_the_record() {
  local home out
  home=$(make_home discovery-outage)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  # Discovery yields nothing: no projects.md to read and no firstmate checkout
  # to take an origin from. Both reads fail, exactly as a transient outage would.
  : > "$out"
  run_check "$home" "$out" env FM_DATA_OVERRIDE="$home/data-gone" \
    FM_ROOT_OVERRIDE="$home/root-gone"
  [ ! -s "$out" ] || fail "a sweep that discovered nothing must stay silent: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the unchanged conflict must not wake again after discovery recovers: $(cat "$out")"
  pass "an empty discovery sweep does not erase the dedupe record"
}

# Discovery that reads some repositories and fails on others is partial, not
# empty: a clone whose origin cannot be read this sweep was never inspected, so
# its absence from the discovered set says nothing about whether the fleet still
# works in it.
test_partial_discovery_keeps_the_record() {
  local home out
  home=$(make_home discovery-partial)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  add_pr "$home" "$REPO_B" 9 "$HEAD_TWO" false CONFLICTING "Broken B"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "repo=$REPO_A" "first poll should wake for alpha"
  assert_contains "$(cat "$out")" "repo=$REPO_B" "first poll should wake for beta"
  # The beta clone goes away while the alpha clone still resolves, exactly as a
  # transient unreadable checkout would leave it.
  mv "$home/projects/beta" "$home/projects/beta.away"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a partial discovery sweep must stay silent: $(cat "$out")"
  mv "$home/projects/beta.away" "$home/projects/beta"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the unchanged beta conflict must not wake again after its clone resolves: $(cat "$out")"
  pass "a partial discovery sweep does not erase the unread repository's record"
}

# A registry that cannot be read this sweep enumerates no projects, which is
# indistinguishable from a home that registered none.
test_unreadable_registry_keeps_the_record() {
  local home out
  home=$(make_home discovery-registry-gone)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "repo=$REPO_A" "first poll should wake for alpha"
  mv "$home/data/projects.md" "$home/data/projects.md.away"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a sweep with no readable registry must stay silent: $(cat "$out")"
  mv "$home/data/projects.md.away" "$home/data/projects.md"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the unchanged alpha conflict must not wake again after the registry returns: $(cat "$out")"
  pass "a sweep with an unreadable project registry does not erase the record"
}

# The other side of the same rule: when discovery resolved every project it
# enumerated, a repository missing from the result is one this home genuinely
# stopped working in, and its keys are dropped so the record stays the size of
# the live conflict set.
test_deregistered_project_leaves_the_record() {
  local home out
  home=$(make_home discovery-deregistered)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  add_pr "$home" "$REPO_B" 9 "$HEAD_TWO" false CONFLICTING "Broken B"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "repo=$REPO_B" "first poll should wake for beta"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- alpha - alpha repo (added 2026-08-25)
MD
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "a deregistered project must not wake: $(cat "$out")"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- alpha - alpha repo (added 2026-08-25)
- beta - beta repo (added 2026-08-25)
MD
  : > "$out"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "repo=$REPO_B" \
    "a re-registered project's conflict is a fresh event and must wake again"
  pass "keys for a repository this home stopped working in leave the record"
}

# A run the watcher kills prints and records nothing, so the reread loop has to
# end at the sweep deadline rather than at its attempt count.
test_unknown_rereads_stop_at_the_sweep_deadline() {
  local home out started elapsed
  home=$(make_home unknown-deadline)
  add_pr_sequence "$home" "$REPO_A" 7 "$HEAD_ONE" "Maybe" UNKNOWN
  out="$home/out.txt"
  started=$(date +%s)
  # Ten attempts five seconds apart is 55s of rereads on a one second budget.
  run_check "$home" "$out" env FM_PR_CONFLICT_BUDGET_SECS=1 \
    FM_PR_CONFLICT_UNKNOWN_ATTEMPTS=10 FM_PR_CONFLICT_UNKNOWN_WAIT=5
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 15 ] || fail "the reread loop ran past the sweep deadline: ${elapsed}s"
  [ ! -s "$out" ] || fail "an unsettled pull request must stay silent: $(cat "$out")"
  pass "unknown-mergeability rereads stop at the sweep deadline"
}

test_clean_fleet_is_silent() {
  local home out
  home=$(make_home wake-clean)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false MERGEABLE "Fine"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "clean fleet should print nothing: $(cat "$out")"
  pass "clean fleet output is empty"
}

test_draft_conflicts_are_reported() {
  local home out
  home=$(make_home wake-draft)
  add_pr "$home" "$REPO_B" 3 "$HEAD_ONE" true CONFLICTING "Draft broken"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "draft=yes" "draft conflict must be marked"
  assert_contains "$(cat "$out")" "owner-team=team-b" "draft repo routes to owning team"
  pass "conflicted draft PRs are reported"
}

test_unknown_wake_uses_the_draft_state_the_reread_judged() {
  local home out
  home=$(make_home unknown-draft)
  add_pr_sequence "$home" "$REPO_A" 7 "$HEAD_ONE" "Became draft" \
    "CONFLICTING:$HEAD_ONE:true"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "draft=yes" \
    "a settled reread must replace the listing's stale draft flag"
  pass "lazy mergeability rereads carry their settled draft state"
}

test_failed_output_does_not_acknowledge_the_conflict() {
  local home out status=0
  home=$(make_home output-failure)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Retry delivery"
  env FM_CHECK_TIMEOUT=30 FM_PR_CONFLICT_INTERVAL=0 FM_PR_CONFLICT_UNKNOWN_WAIT=0 \
    FM_HOME="$home" FM_ROOT="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_STATE_OVERRIDE="$home/state" \
    FM_TEST_PR_CONFLICT_FIXTURE="$home/fixture" \
    PATH="$home/fakebin:$BASE_PATH" "$WATCH" >/dev/full 2>/dev/null || status=$?
  [ "$status" -ne 0 ] || fail "a failed wake write must fail the check"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "title=Retry delivery" \
    "a conflict whose wake write failed must retry"
  pass "failed output leaves the conflict unacknowledged"
}

# GitHub blips constantly, so a repository that has only just started failing is
# not worth a wake. It must still not be counted as swept: silence here means
# "no news", and pruning its keys would re-wake every unchanged conflict once
# the read recovered.
test_transient_read_failure_stays_silent_and_keeps_the_record() {
  local home out
  home=$(make_home read-transient)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "repo=$REPO_A" "first poll should wake for alpha"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A"
  [ ! -s "$out" ] || fail "a fresh read failure must stay silent: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A"
  [ ! -s "$out" ] || fail "a still-fresh read failure must stay silent: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "the unchanged conflict must not wake again once reads recover: $(cat "$out")"
  pass "a transient GitHub read failure is silent and leaves the record intact"
}

# A read failure that outlasts the grace is a hole in coverage, and silence
# would be indistinguishable from a clean fleet. It is disclosed once, naming
# the repository and how long it has been unreadable, and it is not a conflict.
test_persistent_read_failure_is_disclosed_once() {
  local home out
  home=$(make_home read-persistent)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  # The conflict is read and recorded first, so the silence after recovery below
  # is the record holding rather than the conflict having never been seen.
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "number=7" "first poll should wake for alpha"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_A" \
    "a persistently unreadable repository must be named"
  assert_contains "$(cat "$out")" "latest-cause=github" \
    "the disclosure must carry the latest failed-attempt cause"
  assert_not_contains "$(cat "$out")" "owner-team=" \
    "a coverage hole is not a routed conflict"
  [ "$(wc -l < "$out" | tr -d '[:space:]')" = 1 ] || fail "the disclosure must be one line"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  [ ! -s "$out" ] || fail "the same hole must be disclosed once, not on every sweep: $(cat "$out")"
  # Once the repository is readable again its conflict is unchanged, so the
  # recovered sweep is silent rather than re-waking it.
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  [ ! -s "$out" ] || fail "a recovered repository must not re-wake its unchanged conflict: $(cat "$out")"
  # A fresh outage after recovery is a new hole and is disclosed again.
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_A" \
    "a hole that reopens after recovery is a new disclosure"
  pass "a persistent GitHub read failure is disclosed once as a coverage hole"
}

# The disclosure is gated on elapsed time, not merely on having failed before:
# repeated failures inside the grace stay silent however many sweeps they span.
test_read_failure_inside_the_grace_stays_silent() {
  local home out i
  home=$(make_home read-grace)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  i=0
  while [ "$i" -lt 3 ]; do
    : > "$out"
    run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
      FM_PR_CONFLICT_UNREAD_GRACE_SECS=86400
    [ ! -s "$out" ] || fail "a failure inside the grace must stay silent: $(cat "$out")"
    i=$((i + 1))
  done
  pass "read failures inside the disclosure grace stay silent"
}

# A body cut off mid-record is not a shorter list of pull requests. Accepting it
# would silently drop the conflicts that fell off the end, so a truncated read
# is a failed read.
test_truncated_read_is_not_read_as_clean() {
  local home out
  home=$(make_home read-truncated)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_TRUNCATE=1 \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_A" \
    "a truncated body must be refused as an unobserved repository"
  assert_contains "$(cat "$out")" "latest-cause=truncated" \
    "a truncated envelope is not a GitHub-root-cause claim"
  assert_not_contains "$(cat "$out")" "number=7" \
    "a truncated read must not be parsed into findings"
  pass "a truncated api body is treated as a failed read, not a short list"
}

# An unreadable repository must not let the sweep count as complete, or it would
# prune keys for repositories it never saw.
test_read_failure_does_not_prune_another_repository() {
  local home out
  home=$(make_home read-no-prune)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  add_pr "$home" "$REPO_B" 9 "$HEAD_TWO" false CONFLICTING "Broken B"
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" "repo=$REPO_B" "first poll should wake for beta"
  # beta is deregistered in the same sweep alpha becomes unreadable. Discovery
  # is complete, but the sweep is not, so beta's keys must survive.
  cat > "$home/data/projects.md" <<'MD'
# Projects

- alpha - alpha repo (added 2026-08-25)
MD
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A"
  cat > "$home/data/projects.md" <<'MD'
# Projects

- alpha - alpha repo (added 2026-08-25)
- beta - beta repo (added 2026-08-25)
MD
  : > "$out"
  run_check "$home" "$out"
  [ ! -s "$out" ] || fail "an incomplete sweep must not have pruned beta's key: $(cat "$out")"
  pass "a sweep with an unreadable repository prunes nothing it did not see"
}

# One read per repository, not one per pull request. The per-PR cost model is
# what exhausted the sweep budget and silently shrank fleet coverage, so the
# call count is asserted directly through a counting shim.
test_one_read_per_repository_carries_mergeability() {
  local home out calls
  home=$(make_home read-cost)
  add_pr "$home" "$REPO_A" 1 "$HEAD_ONE" false MERGEABLE "One"
  add_pr "$home" "$REPO_A" 2 "$HEAD_ONE" false CONFLICTING "Two"
  add_pr "$home" "$REPO_A" 3 "$HEAD_TWO" false MERGEABLE "Three"
  add_pr "$home" "$REPO_A" 4 "$HEAD_TWO" false CONFLICTING "Four"
  mv "$home/fakebin/gh-axi" "$home/fakebin/gh-axi-real"
  cat > "$home/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$home/calls.log"
exec "$home/fakebin/gh-axi-real" "\$@"
SH
  chmod +x "$home/fakebin/gh-axi"
  : > "$home/calls.log"
  out="$home/out.txt"
  run_check "$home" "$out"
  calls=$(wc -l < "$home/calls.log" | tr -d '[:space:]')
  assert_contains "$(cat "$out")" "number=2" "conflicts must still be found"
  assert_contains "$(cat "$out")" "number=4" "conflicts must still be found"
  # Three repositories are discovered (alpha, beta, this firstmate checkout),
  # and none of alpha's four pull requests needs a reread.
  [ "$calls" -le 3 ] \
    || fail "expected one read per repository, got $calls gh-axi calls for 3 repos and 4 pull requests"
  pass "one read per repository carries mergeability for every open pull request"
}

# Only a pull request GitHub has not judged yet costs a further read.
test_only_unknown_pull_requests_are_reread() {
  local home out calls
  home=$(make_home read-unknown-cost)
  add_pr "$home" "$REPO_A" 1 "$HEAD_ONE" false MERGEABLE "One"
  add_pr "$home" "$REPO_A" 2 "$HEAD_ONE" false CONFLICTING "Two"
  add_pr_sequence "$home" "$REPO_A" 3 "$HEAD_TWO" "Three" CONFLICTING
  mv "$home/fakebin/gh-axi" "$home/fakebin/gh-axi-real"
  cat > "$home/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
printf 'call\n' >> "$home/calls.log"
exec "$home/fakebin/gh-axi-real" "\$@"
SH
  chmod +x "$home/fakebin/gh-axi"
  : > "$home/calls.log"
  out="$home/out.txt"
  run_check "$home" "$out"
  calls=$(wc -l < "$home/calls.log" | tr -d '[:space:]')
  assert_contains "$(cat "$out")" "number=3" "the reread conflict must wake"
  # Three repository reads plus exactly one reread for the single UNKNOWN.
  [ "$calls" -le 4 ] \
    || fail "only the UNKNOWN pull request should be reread, got $calls gh-axi calls"
  pass "only pull requests GitHub has not judged yet are reread"
}

# A repository GraphQL cannot resolve answers 200 with a null repository, which
# without a guard is byte-identical to a repository with no open pull requests.
# It must be a read failure, never a clean repository.
test_unresolvable_repository_is_not_read_as_clean() {
  local home out
  home=$(make_home graphql-norepo)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_NOREPO="$REPO_A" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_A" \
    "an unresolvable repository must be disclosed, not read as clean"
  assert_contains "$(cat "$out")" "latest-cause=github" \
    "a GraphQL null repository is a GitHub read failure"
  pass "a GraphQL null repository is a failed read, not an empty one"
}

# A slug is interpolated into a GraphQL document, so one that could break out of
# the string literal is refused rather than sent - and refusing it must leave
# the repository unread rather than silently clean.
test_untrustworthy_slug_is_refused_not_swept() {
  local home out
  home=$(make_home slug-guard)
  git -C "$home/projects/alpha" remote set-url origin \
    'https://github.com/acme/alpha"){id}}}#'
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=project:alpha" \
    "a slug that cannot be trusted in a query must be a local identity gap"
  assert_contains "$(cat "$out")" "latest-cause=invalid-origin" \
    "the cause must be local identity, not GitHub"
  assert_not_contains "$(cat "$out")" "latest-cause=github" \
    "a refused slug must not be blamed on GitHub"
  pass "a slug that is unsafe to interpolate is refused rather than swept"
}

# A sweep that ran out of budget must name the repositories it never reached.
# Saying nothing about them is reporting no conflicts for repositories it never
# looked at.
test_budget_cut_names_the_repositories_not_reached() {
  local home out
  home=$(make_home budget-unreached)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false MERGEABLE "Slow A"
  add_pr "$home" "$REPO_B" 9 "$HEAD_TWO" false CONFLICTING "Broken B"
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_BUDGET_SECS=1 \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0 FM_TEST_PR_CONFLICT_SLOW="$REPO_A" \
    FM_TEST_PR_CONFLICT_SLOW_SECS=2
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_B" \
    "a repository the budget never reached must be named"
  assert_contains "$(cat "$out")" "latest-cause=budget" \
    "the disclosure must name budget as the latest cause"
  pass "a budget-cut sweep names the repositories it never reached"
}

# A local budget timeout and a GitHub read failure are different latest-cause
# values on the same coverage item shape. They must not share a diagnosis.
test_budget_and_github_holes_are_worded_apart() {
  local home out
  home=$(make_home hole-wording-budget)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false MERGEABLE "Slow A"
  add_pr "$home" "$REPO_B" 9 "$HEAD_TWO" false CONFLICTING "Broken B"
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_BUDGET_SECS=1 \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0 FM_TEST_PR_CONFLICT_SLOW="$REPO_A" \
    FM_TEST_PR_CONFLICT_SLOW_SECS=2
  assert_contains "$(cat "$out")" "latest-cause=budget" "a budget cut names budget"
  assert_not_contains "$(cat "$out")" "latest-cause=github" \
    "a sweep that ran out of its own budget must not blame GitHub"
  home=$(make_home hole-wording-github)
  add_pr "$home" "$REPO_B" 9 "$HEAD_TWO" false CONFLICTING "Broken B"
  out="$home/out.txt"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_B" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_B" "a failed read is a coverage hole"
  assert_contains "$(cat "$out")" "latest-cause=github" "a failed read names github as latest-cause"
  assert_not_contains "$(cat "$out")" "latest-cause=budget" \
    "a failed read must not be reported as a budget cut"
  pass "budget holes and GitHub holes are separately worded"
}

# A continuously unobserved target keeps one gap. Cause flaps update latest-cause
# without resetting age, so the gap discloses once at the original opening time.
test_coverage_gap_retains_age_across_cause_flaps() {
  local home out record opened
  home=$(make_home coverage-flap)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_NOW=1000 FM_PR_CONFLICT_UNREAD_GRACE_SECS=30
  [ ! -s "$out" ] || fail "a fresh gap must stay silent inside the grace: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_BUDGET_SECS=1 \
    FM_TEST_PR_CONFLICT_SLOW="$REPO_A" FM_TEST_PR_CONFLICT_SLOW_SECS=2 \
    FM_PR_CONFLICT_NOW=1010 FM_PR_CONFLICT_UNREAD_GRACE_SECS=30
  [ ! -s "$out" ] || fail "a cause change inside the grace must stay silent: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_NOW=1020 FM_PR_CONFLICT_UNREAD_GRACE_SECS=30
  [ ! -s "$out" ] || fail "the same gap must still be silent before the grace: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_BUDGET_SECS=1 \
    FM_TEST_PR_CONFLICT_SLOW="$REPO_A" FM_TEST_PR_CONFLICT_SLOW_SECS=2 \
    FM_PR_CONFLICT_NOW=1030 FM_PR_CONFLICT_UNREAD_GRACE_SECS=30
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_A" \
    "the continuous gap must disclose once the grace elapses"
  assert_contains "$(cat "$out")" "unaccounted-for=30s" \
    "the age must be measured from the original opening time"
  assert_contains "$(cat "$out")" "latest-cause=budget" \
    "the disclosure must carry the latest cause, not the first"
  record=$(sed -n 's/^coverage=//p' "$home/state/.pr-conflict-watch")
  opened=$(printf '%s' "$record" | jq -r --arg id "repo:$REPO_A" \
    'map(select(.target_id == $id)) | .[0].opened_at')
  [ "$opened" = 1000 ] || fail "opened_at must stay 1000 across cause flaps, got $opened"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_NOW=1040 FM_PR_CONFLICT_UNREAD_GRACE_SECS=30
  [ ! -s "$out" ] || fail "a cause change after disclosure must not notify again: $(cat "$out")"
  pass "a continuous coverage gap keeps its age and discloses once"
}

# Recovery closes the gap. A later outage is a new gap that can notify again.
test_coverage_recovery_then_new_outage_notifies_again() {
  local home out
  home=$(make_home coverage-reopen)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_A" "first outage discloses"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  [ ! -s "$out" ] || fail "recovery must close the gap silently: $(cat "$out")"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_A" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_A" \
    "a later outage is a new gap"
  pass "recovery followed by a later outage can notify again"
}

# A malformed origin is a local target. It never reaches GraphQL and must
# round-trip through the coverage JSON even with delimiter characters.
test_malformed_origin_round_trips_as_local_target() {
  local home out record id
  home=$(make_home malformed-origin)
  git -C "$home/projects/alpha" remote set-url origin \
    'https://github.com/acme/al;pha@x" y\z.git'
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=project:alpha" \
    "a malformed origin is a project target, not a repo slug"
  assert_contains "$(cat "$out")" "latest-cause=invalid-origin"
  record=$(sed -n 's/^coverage=//p' "$home/state/.pr-conflict-watch")
  id=$(printf '%s' "$record" | jq -r '.[0].target_id')
  [ "$id" = "project:alpha" ] || fail "coverage JSON must round-trip project:alpha, got $id"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  [ ! -s "$out" ] || fail "the same local gap must disclose once: $(cat "$out")"
  pass "a malformed origin never reaches GraphQL and round-trips as a local target"
}

test_firstmate_origin_failure_causes_are_distinguished() {
  local home root out
  home=$(make_home firstmate-invalid-origin)
  root="$home/firstmate"
  mkdir -p "$root"
  git -C "$root" init -q
  git -C "$root" remote add origin https://gitlab.com/acme/firstmate.git
  out="$home/out.txt"
  run_check "$home" "$out" env FM_ROOT_OVERRIDE="$root" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=source:firstmate-origin" \
    "a rejected firstmate origin must be a source coverage gap"
  assert_contains "$(cat "$out")" "latest-cause=invalid-origin" \
    "a present non-GitHub firstmate origin must be an identity refusal"

  home=$(make_home firstmate-missing-origin)
  root="$home/firstmate"
  mkdir -p "$root"
  git -C "$root" init -q
  out="$home/out.txt"
  run_check "$home" "$out" env FM_ROOT_OVERRIDE="$root" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=source:firstmate-origin" \
    "a missing firstmate origin must be a source coverage gap"
  assert_contains "$(cat "$out")" "latest-cause=discovery" \
    "a failed firstmate origin lookup must remain a discovery failure"
  pass "firstmate origin lookup and identity failures keep distinct causes"
}

test_project_origin_failure_causes_are_distinguished() {
  local home out
  home=$(make_home project-missing-origin)
  git -C "$home/projects/alpha" remote remove origin
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=project:alpha" \
    "a missing project origin must preserve the project target"
  assert_contains "$(cat "$out")" "latest-cause=discovery" \
    "a failed project origin lookup must be a discovery failure"

  home=$(make_home project-invalid-origin)
  git -C "$home/projects/alpha" remote set-url origin \
    https://gitlab.com/acme/alpha.git
  out="$home/out.txt"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=project:alpha" \
    "a rejected project origin must preserve the project target"
  assert_contains "$(cat "$out")" "latest-cause=invalid-origin" \
    "a present non-GitHub project origin must be an identity refusal"
  pass "project origin lookup and identity failures keep distinct causes"
}

# An unreadable projects registry is a source-level gap, not an unnamed sweep.
test_unreadable_registry_is_a_source_coverage_gap() {
  local home out
  home=$(make_home registry-source-gap)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake"
  mv "$home/data/projects.md" "$home/data/projects.md.away"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=source:projects-registry" \
    "an unreadable registry must name the source target"
  assert_contains "$(cat "$out")" "latest-cause=discovery"
  mv "$home/data/projects.md.away" "$home/data/projects.md"
  : > "$out"
  run_check "$home" "$out" env FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  [ ! -s "$out" ] || fail "the unchanged conflict must not wake after the registry returns: $(cat "$out")"
  pass "an unreadable registry is a source-level coverage gap"
}

# Conflicts and coverage events share a line without sharing ledgers.
test_mixed_sweep_does_not_cross_write_ledgers() {
  local home out record
  home=$(make_home mixed-ledgers)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING "Broken A"
  add_pr "$home" "$REPO_B" 9 "$HEAD_TWO" false CONFLICTING "Broken B"
  out="$home/out.txt"
  run_check "$home" "$out"
  [ -s "$out" ] || fail "first poll should wake both conflicts"
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_B" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_B"
  assert_not_contains "$(cat "$out")" "number=7" "alpha's unchanged conflict must stay silent"
  record=$(sed -n 's/^coverage=//p' "$home/state/.pr-conflict-watch")
  printf '%s' "$record" | jq -e --arg id "repo:$REPO_B" \
    'map(select(.target_id == $id)) | length == 1' >/dev/null \
    || fail "beta must have exactly one coverage gap"
  assert_contains "$(cat "$home/state/.pr-conflict-watch")" "$HEAD_ONE" \
    "alpha's conflict key must remain in the reported ledger"
  pass "a mixed sweep keeps conflict and coverage ledgers separate"
}

# A coverage item omitted by the line cap stays undisclosed and is emitted later.
test_coverage_omitted_by_line_cap_is_emitted_later() {
  local home out i
  home=$(make_home coverage-cap)
  i=1
  while [ "$i" -le 12 ]; do
    add_pr "$home" "$REPO_A" "$i" "$HEAD_ONE" false CONFLICTING "Conflicted branch $i"
    i=$((i + 1))
  done
  out="$home/out.txt"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_B" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  if grep -q "coverage-hole target=repo:$REPO_B" "$out"; then
    pass "coverage fit on the first capped line"
    return 0
  fi
  : > "$out"
  run_check "$home" "$out" env FM_TEST_PR_CONFLICT_FAIL="$REPO_B" \
    FM_PR_CONFLICT_UNREAD_GRACE_SECS=0
  assert_contains "$(cat "$out")" "coverage-hole target=repo:$REPO_B" \
    "an omitted coverage item must still be undisclosed and wake later"
  pass "a coverage item omitted by the line cap is emitted later"
}

# Title backslashes are literal. Tabs and newlines become spaces at format time.
test_title_backslash_is_literal() {
  local home out
  home=$(make_home title-backslash)
  add_pr "$home" "$REPO_A" 7 "$HEAD_ONE" false CONFLICTING $'fix regex \\d+\tand\nnewline'
  out="$home/out.txt"
  run_check "$home" "$out"
  assert_contains "$(cat "$out")" 'title=fix regex \d+ and newline' \
    "a title backslash must not be doubled and whitespace must be safe"
  assert_not_contains "$(cat "$out")" 'title=fix regex \\d+' \
    "tsv escaping must not reach the wake line"
  pass "PR titles preserve a literal backslash and safe whitespace"
}

test_arm_registers_check() {
  local home out status=0
  home=$(make_home arm)
  env FM_HOME="$home" FM_ROOT="$ROOT" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_STATE_OVERRIDE="$home/state" \
    PATH="$home/fakebin:$BASE_PATH" "$WATCH" arm >"$home/arm.out" 2>&1 || status=$?
  expect_code 0 "$status" "arm exit"
  assert_present "$home/state/pr-conflict-watch.check.sh" "arm must write check shim"
  assert_present "$home/state/pr-conflict-watch.check-trust" "arm must bind trust"
  FM_STATE_OVERRIDE="$home/state" "$ROOT/bin/fm-check-register.sh" pr-conflict-watch >/dev/null \
    || fail "trust binding must match shim bytes"
  pass "arm writes and registers the watcher check"
}

test_fake_gh_axi_matches_the_real_cli_contract
test_repo_slug_parses_github_remotes
test_newly_conflicted_wakes
test_same_head_stays_silent
test_new_head_after_force_update_wakes_again
test_unknown_never_reported
test_unknown_resolving_to_conflicting_wakes
test_unknown_wake_uses_the_head_the_reread_judged
test_conflicts_past_the_line_cap_wake_on_a_later_sweep
test_resolved_conflicts_leave_the_record
test_empty_discovery_keeps_the_record
test_partial_discovery_keeps_the_record
test_unreadable_registry_keeps_the_record
test_deregistered_project_leaves_the_record
test_unknown_rereads_stop_at_the_sweep_deadline
test_clean_fleet_is_silent
test_draft_conflicts_are_reported
test_unknown_wake_uses_the_draft_state_the_reread_judged
test_failed_output_does_not_acknowledge_the_conflict
test_transient_read_failure_stays_silent_and_keeps_the_record
test_persistent_read_failure_is_disclosed_once
test_read_failure_inside_the_grace_stays_silent
test_truncated_read_is_not_read_as_clean
test_read_failure_does_not_prune_another_repository
test_one_read_per_repository_carries_mergeability
test_only_unknown_pull_requests_are_reread
test_unresolvable_repository_is_not_read_as_clean
test_untrustworthy_slug_is_refused_not_swept
test_budget_cut_names_the_repositories_not_reached
test_budget_and_github_holes_are_worded_apart
test_coverage_gap_retains_age_across_cause_flaps
test_coverage_recovery_then_new_outage_notifies_again
test_malformed_origin_round_trips_as_local_target
test_firstmate_origin_failure_causes_are_distinguished
test_project_origin_failure_causes_are_distinguished
test_unreadable_registry_is_a_source_coverage_gap
test_mixed_sweep_does_not_cross_write_ledgers
test_coverage_omitted_by_line_cap_is_emitted_later
test_title_backslash_is_literal
test_arm_registers_check
