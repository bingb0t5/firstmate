#!/usr/bin/env bash
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=bin/fm-repo-slug-lib.sh
. "$ROOT/bin/fm-repo-slug-lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-repo-slug)
SENTINEL="generated-userinfo-${RANDOM}-${RANDOM}"

parse_case() {
  local label=$1 input=$2 expected_status=$3 expected_slug=$4 rc=0 out err
  out="$TMP_ROOT/$label.out"
  err="$TMP_ROOT/$label.err"
  fm_repo_slug_parse "$input" >"$out" 2>"$err" || rc=$?
  [ ! -s "$out" ] || fail "$label emitted stdout"
  [ ! -s "$err" ] || fail "$label emitted stderr"
  [ "$FM_REPO_SLUG_STATUS" = "$expected_status" ] || fail "$label returned the wrong status"
  [ "$FM_REPO_SLUG" = "$expected_slug" ] || fail "$label returned the wrong slug"
  if [ "$expected_status" = ok ]; then
    expect_code 0 "$rc" "$label success"
    fm_repo_slug_valid "$FM_REPO_SLUG" || fail "$label returned an invalid canonical slug"
  else
    [ "$rc" -ne 0 ] || fail "$label unexpectedly succeeded"
  fi
  assert_not_contains "$FM_REPO_SLUG_STATUS$FM_REPO_SLUG$(cat "$out")$(cat "$err")" "$SENTINEL" \
    "$label retained sensitive input"
}

parse_case https-basic https://github.com/Acme/Alpha.git ok acme/alpha
parse_case https-trailing https://GITHUB.COM/acme/alpha/ ok acme/alpha
parse_case https-userinfo "https://x-access-token:${SENTINEL}@github.com/acme/alpha.git" ok acme/alpha
parse_case https-userinfo-port "https://${SENTINEL}@GitHub.COM:443/acme/alpha" ok acme/alpha
parse_case ssh-basic ssh://git@github.com/acme/alpha.git ok acme/alpha
parse_case ssh-port ssh://git@github.com:22/acme/alpha.git ok acme/alpha
parse_case ssh-userinfo-port "ssh://${SENTINEL}@github.com:2222/acme/alpha/" ok acme/alpha
parse_case scp-user git@github.com:acme/alpha.git ok acme/alpha
parse_case scp-bare github.com:acme/alpha ok acme/alpha
parse_case pull-basic https://github.com/acme/alpha/pull/12 ok acme/alpha
parse_case pull-trailing https://GITHUB.COM/Acme/Alpha/pull/001/ ok acme/alpha

parse_case host-lookalike https://github.com.evil.example/acme/alpha.git unsupported-host ''
parse_case host-prefix https://notgithub.com/acme/alpha.git unsupported-host ''
parse_case host-scp git@github.com.evil.example:acme/alpha.git unsupported-host ''
parse_case transport-http http://github.com/acme/alpha.git unsupported-transport ''
parse_case transport-git git://github.com/acme/alpha.git unsupported-transport ''
parse_case local-path /work/acme/alpha invalid-origin ''
parse_case repeated-userinfo "https://${SENTINEL}@other@github.com/acme/alpha.git" invalid-origin ''
parse_case empty-port https://github.com:/acme/alpha.git invalid-origin ''
parse_case text-port https://github.com:notaport/acme/alpha.git invalid-origin ''
parse_case path-extra https://github.com/acme/alpha/extra invalid-origin ''
parse_case path-double https://github.com/acme//alpha invalid-origin ''
parse_case query https://github.com/acme/alpha.git?token=value invalid-origin ''
parse_case fragment https://github.com/acme/alpha.git#readme invalid-origin ''
parse_case pull-zero https://github.com/acme/alpha/pull/000 invalid-origin ''
parse_case pull-userinfo "https://${SENTINEL}@github.com/acme/alpha/pull/2" invalid-origin ''
parse_case pull-ssh ssh://git@github.com/acme/alpha/pull/2 invalid-origin ''

FM_REPO_SLUG_STATUS=stale
FM_REPO_SLUG=stale/value
fm_repo_slug_parse '' >/dev/null 2>&1 || true
[ "$FM_REPO_SLUG_STATUS" = invalid-origin ] || fail "empty input did not replace stale status"
[ -z "$FM_REPO_SLUG" ] || fail "empty input retained a stale slug"

# The public direct-PR resolver must use the origin push URL explicitly.
# Put upstream first to reproduce the multi-remote topology where an unscoped
# GitHub command would otherwise choose the wrong repository.
project="$TMP_ROOT/multi-remote-project"
mkdir -p "$project"
git -C "$project" init -q
git -C "$project" remote add upstream https://github.com/kunchenguid/firstmate.git
git -C "$project" remote add origin https://github.com/kunchenguid/firstmate.git
git -C "$project" config remote.origin.pushurl https://github.com/bingb0t5/firstmate.git
resolved=$("$ROOT/bin/fm-pr-target.sh" "$project") || fail "direct-PR target resolver refused a valid origin push URL"
[ "$resolved" = bingb0t5/firstmate ] || fail "direct-PR target resolver selected $resolved instead of bingb0t5/firstmate"
[ "$(git -C "$project" remote get-url upstream)" = https://github.com/kunchenguid/firstmate.git ] \
  || fail "resolver test changed the upstream fetch remote"

# A Firstmate clone whose origin push URL was accidentally changed to upstream
# must stop before any ordinary PR publication can reach GitHub.
git -C "$project" config remote.origin.pushurl https://github.com/kunchenguid/firstmate.git
if "$ROOT/bin/fm-pr-target.sh" "$project" >"$TMP_ROOT/forbidden.out" 2>"$TMP_ROOT/forbidden.err"; then
  fail "resolver accepted kunchenguid/firstmate as an ordinary PR target"
fi
assert_grep "ordinary Firstmate PR target must be bingb0t5/firstmate" "$TMP_ROOT/forbidden.err" \
  "resolver did not explain the forbidden upstream target"
git -C "$project" config remote.origin.pushurl https://github.com/another-owner/firstmate.git
if "$ROOT/bin/fm-pr-target.sh" "$project" >"$TMP_ROOT/wrong-fork.out" 2>"$TMP_ROOT/wrong-fork.err"; then
  fail "resolver accepted a non-captain Firstmate fork as an ordinary PR target"
fi
assert_grep "ordinary Firstmate PR target must be bingb0t5/firstmate" "$TMP_ROOT/wrong-fork.err" \
  "resolver did not enforce the captain Firstmate fork"

# Keep a real local upstream fetch/compare path beside the captured GitHub
# publication operation so this guard proves the pull-only remote survives.
upstream_repo="$TMP_ROOT/upstream-fixture.git"
git init --bare -q "$upstream_repo"
seed="$TMP_ROOT/upstream-seed"
git init -q "$seed"
git -C "$seed" config user.email test@example.invalid
git -C "$seed" config user.name "Firstmate Test"
printf '%s\n' upstream >"$seed/README.md"
git -C "$seed" add README.md
git -C "$seed" commit -qm "seed upstream fixture"
git -C "$seed" branch -M main
git -C "$seed" remote add origin "$upstream_repo"
git -C "$seed" push -q origin main
git -C "$project" remote set-url upstream "$upstream_repo"
git -C "$project" fetch -q upstream main
git -C "$project" checkout -q -B fixture-main FETCH_HEAD
printf '%s\n' local-change >>"$project/README.md"
git -C "$project" add README.md
git -C "$project" -c user.email=test@example.invalid -c user.name="Firstmate Test" commit -qm "local change"
if git -C "$project" diff --quiet upstream/main...HEAD; then
  fail "upstream compare did not observe the local change"
fi
git -C "$project" config remote.origin.pushurl https://github.com/bingb0t5/firstmate.git
mkdir -p "$TMP_ROOT/fakebin"
cat >"$TMP_ROOT/fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$FM_TEST_GH_AXI_LOG"
case "$*" in
  "pr create --repo bingb0t5/firstmate"*) printf '%s\n' 'https://github.com/bingb0t5/firstmate/pull/999' ;;
  *) exit 1 ;;
esac
SH
chmod +x "$TMP_ROOT/fakebin/gh-axi"
FM_TEST_GH_AXI_LOG="$TMP_ROOT/gh-axi.log" PATH="$TMP_ROOT/fakebin:$PATH" \
  bash -c '
    set -eu
    repo=$("$1/bin/fm-pr-target.sh" "$2")
    gh-axi pr create --repo "$repo" --title "captured publication" --body "fixture"
  ' _ "$ROOT" "$project" >/dev/null \
  || fail "captured direct-PR publication did not complete through the resolver"
grep -qxF 'pr create --repo bingb0t5/firstmate --title captured publication --body fixture' "$TMP_ROOT/gh-axi.log" \
  || fail "captured publication did not scope gh-axi to the captain fork"
assert_no_grep 'kunchenguid/firstmate' "$TMP_ROOT/gh-axi.log" \
  "captured publication attempted an upstream PR"
git -C "$project" remote get-url upstream >/dev/null \
  || fail "upstream fetch remote was removed"
[ "$(git -C "$project" rev-parse upstream/main)" = "$(git -C "$seed" rev-parse main)" ] \
  || fail "upstream fetch did not preserve the local upstream commit"

pass "GitHub origins are parsed structurally without sensitive retention"
pass "ordinary Firstmate PR resolution rejects upstream and non-captain targets"
pass "captured publication scopes GitHub to the fork while upstream fetch/compare survives"
