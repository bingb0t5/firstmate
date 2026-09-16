#!/usr/bin/env bash
# Behavior tests for fm-pr-check.sh's UI-review-before-PR gate warning
# (AGENTS.md's "UI work" brief contract): loud, non-blocking stderr warning
# when a PR's changed files touch a UI path but its body lacks the required
# "## UI review (local)" section. Never refuses, never affects pr=/pr_head=
# recording or merge-poll arming.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"

PR_CHECK="$ROOT/bin/fm-pr-check.sh"
TMP_ROOT=$(fm_test_tmproot fm-pr-check-ui-warning)
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}

# fm_pr_path_is_ui is a pure classifier; test it directly rather than only
# through the gh-mediated gh-pr-check integration below.
test_ui_path_classifier() {
  local p
  for p in src/App.tsx src/Widget.jsx web/App.vue app.svelte styles/app.css \
    theme.scss theme.sass theme.less index.html index.htm \
    src/ui/button.go src/components/Nav.go app/pages/home.go \
    app/views/index.go frontend/main.go client/app.go styles/theme.go \
    public/index.go; do
    fm_pr_path_is_ui "$p" || fail "expected '$p' to classify as a UI path"
  done
  for p in bin/fm-pr-check.sh tests/fm-pr-check.test.sh README.md \
    docs/architecture.md server/main.go api/handler.go; do
    ! fm_pr_path_is_ui "$p" || fail "expected '$p' to NOT classify as a UI path"
  done
  pass "fm_pr_path_is_ui: pragmatic UI-path classifier matches frontend extensions and directories only"
}

# fakebin/gh emits a fixed changed-file list and PR body driven by env vars,
# reproducing the two `gh pr view --json ...` calls fm-pr-check.sh makes.
make_case() {
  local name=$1 dir fakebin
  dir="$TMP_ROOT/$name"
  fakebin="$dir/fakebin"
  mkdir -p "$dir/home/state" "$dir/home/data" "$dir/wt" "$fakebin" "$dir/root/bin"
  cat > "$dir/root/bin/fm-guard.sh" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$dir/root/bin/fm-guard.sh"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
case " $* " in
  *" headRefOid "*) printf '%s\n' "${FM_TEST_GH_HEAD:-0123456789abcdef0123456789abcdef01234567}" ;;
  *" files "*) printf '%s\n' "${FM_TEST_GH_FILES:-}" ;;
  *" body "*) printf '%s' "${FM_TEST_GH_BODY:-}" ;;
esac
SH
  chmod +x "$fakebin/gh"
  fm_write_meta "$dir/home/state/task-a.meta" \
    "window=firstmate:fm-task-a" \
    "endpoint_task_id=task-a" \
    "worktree=$dir/wt" \
    "project=$dir/project" \
    "kind=ship" \
    "mode=no-mistakes"
  printf '%s\n' "$dir"
}

run_check() {
  local dir=$1
  shift
  FM_ROOT_OVERRIDE="$dir/root" FM_HOME="$dir/home" PATH="$dir/fakebin:$BASE_PATH" \
    "$PR_CHECK" "$@"
}

test_warns_on_ui_touching_pr_missing_section() {
  local dir err
  dir=$(make_case ui-missing-section)
  FM_TEST_GH_FILES=$'src/App.tsx\nREADME.md' FM_TEST_GH_BODY='Just a summary, no review section.' \
    run_check "$dir" task-a https://github.com/o/r/pull/1 > "$dir/stdout" 2> "$dir/stderr" \
    || fail "pr-check should not fail on a UI PR missing the review section"
  err=$(cat "$dir/stderr")
  assert_contains "$err" 'WARNING:' "missing UI review section produced no warning"
  assert_contains "$err" '## UI review (local)' "warning did not name the required section"
  grep -qxF 'pr=https://github.com/o/r/pull/1' "$dir/home/state/task-a.meta" \
    || fail "warning path must still record pr= metadata"
  [ -f "$dir/home/state/task-a.check.sh" ] || fail "warning path must still arm the merge poll"
  pass "fm-pr-check.sh: warns loudly on a UI-touching PR missing the local review section"
}

test_silent_on_ui_touching_pr_with_section() {
  local dir err
  dir=$(make_case ui-with-section)
  FM_TEST_GH_FILES=$'src/App.tsx' \
    FM_TEST_GH_BODY=$'Summary.\n\n## UI review (local)\nverdict: clean\nscreenshots: link' \
    run_check "$dir" task-a https://github.com/o/r/pull/2 > "$dir/stdout" 2> "$dir/stderr" \
    || fail "pr-check should not fail on a compliant UI PR"
  err=$(cat "$dir/stderr")
  assert_not_contains "$err" 'WARNING:' "compliant UI PR unexpectedly warned"
  pass "fm-pr-check.sh: stays silent on a UI-touching PR that already carries the review section"
}

test_silent_on_non_ui_pr_without_section() {
  local dir err
  dir=$(make_case non-ui-no-section)
  FM_TEST_GH_FILES=$'bin/fm-pr-check.sh\ndocs/architecture.md' FM_TEST_GH_BODY='No UI here.' \
    run_check "$dir" task-a https://github.com/o/r/pull/3 > "$dir/stdout" 2> "$dir/stderr" \
    || fail "pr-check should not fail on a non-UI PR"
  err=$(cat "$dir/stderr")
  assert_not_contains "$err" 'WARNING:' "non-UI PR unexpectedly warned about a missing UI review section"
  pass "fm-pr-check.sh: stays silent on a non-UI PR even without a review section"
}

test_ui_path_classifier
test_warns_on_ui_touching_pr_missing_section
test_silent_on_ui_touching_pr_with_section
test_silent_on_non_ui_pr_without_section
