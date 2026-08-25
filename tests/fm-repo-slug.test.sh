#!/usr/bin/env bash
set -u

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

pass "GitHub origins are parsed structurally without sensitive retention"
