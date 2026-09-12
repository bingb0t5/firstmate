#!/usr/bin/env bash
# Focused live regression for fm-timeout-lib owner-death cleanup.
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29X96Q8GBCS5NB92S2S7GWB"
EVIDENCE="/home/rich/.no-mistakes/evidence/01M29X96Q8GBCS5NB92S2S7GWB"
# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
BASE_PATH=${FM_TEST_BASE_PATH:-/usr/bin:/bin:/usr/sbin:/sbin}
TMP_ROOT=$(fm_test_tmproot fm-timeout-regression)
trap fm_test_cleanup EXIT

make_no_timeout_toolbin() {
  local dir=$1 tb="$1/notimeoutbin" tool real
  mkdir -p "$tb"
  for tool in bash perl ps sleep kill env sed awk tr; do
    real=$(command -v "$tool" || true)
    [ -n "$real" ] || fail "missing tool for no-timeout path: $tool"
    ln -s "$real" "$tb/$tool"
  done
  printf '%s\n' "$tb"
}

test_abnormal_parent_does_not_leave_real_helper_descendants() {
  local driver="$TMP_ROOT/abnormal-parent-driver.sh" pids_file parent helper_pid shell_pid pgid
  local mode label alive=0 stat comm group_count perl_toolbin mechanism
  perl_toolbin=$(make_no_timeout_toolbin "$TMP_ROOT/abnormal-parent-perl-fixture")
  mechanism=$(PATH="$perl_toolbin" bash -c ". \"$ROOT/bin/fm-timeout-lib.sh\"; fm_timeout_mechanism")
  [ "$mechanism" = perl ] || fail "no-timeout PATH fixture did not select perl mechanism (got $mechanism)"
  cat > "$driver" <<'SH'
#!/usr/bin/env bash
set -u
. "$1"
fm_run_timed 30 bash -c '
  shell_pid=$BASHPID
  printf "%s\n" "$shell_pid" > "$1"
  printf "%s\n" "$(ps -o pgid= -p "$shell_pid" | tr -d '"'"'[:space:]'"'"')" >> "$1"
  sleep 600 &
  helper_pid=$!
  printf "%s\n" "$helper_pid" >> "$1"
  wait "$helper_pid"
' _ "$2"
SH
  chmod +x "$driver"

  for mode in default bash perl; do
    pids_file="$TMP_ROOT/abnormal-parent-$mode.pids"
    if [ "$mode" = default ]; then
      label=external
      env_args=()
    elif [ "$mode" = bash ]; then
      label=pure-bash
      env_args=(FM_TIMEOUT_MECHANISM_OVERRIDE=bash)
    else
      label=perl
      env_args=(PATH="$perl_toolbin")
    fi
    env "${env_args[@]}" "$driver" "$ROOT/bin/fm-timeout-lib.sh" "$pids_file" >"$TMP_ROOT/abnormal-parent-$mode.out" 2>&1 &
    parent=$!
    for _ in {1..100}; do
      [ -s "$pids_file" ] && [ "$(wc -l < "$pids_file" | tr -d ' ')" -eq 3 ] && break
      sleep 0.02
    done
    [ -s "$pids_file" ] || fail "$label timeout did not start the real helper fixture"
    shell_pid=$(sed -n '1p' "$pids_file")
    pgid=$(sed -n '2p' "$pids_file")
    helper_pid=$(sed -n '3p' "$pids_file")
    comm=$(ps -o comm= -p "$helper_pid" 2>/dev/null | tr -d ' ')
    [ "$comm" = sleep ] || fail "$label timeout fixture did not observe a real sleep helper (comm=$comm)"
    kill -0 "$helper_pid" 2>/dev/null || fail "$label timeout helper exited before the abnormal-parent kill"
    kill -KILL "$parent"
    wait "$parent" 2>/dev/null || true
    alive=1
    group_count=1
    for _ in {1..100}; do
      alive=0
      while read -r pid; do
        [ -n "$pid" ] || continue
        [ "$pid" = "$pgid" ] && continue
        stat=$(ps -o stat= -p "$pid" 2>/dev/null | tr -d '[:space:]')
        case "$stat" in
          ''|Z*) ;;
          *) alive=1 ;;
        esac
      done < "$pids_file"
      group_count=$(ps -eo pgid= | awk -v group="$pgid" '$1 == group { count++ } END { print count + 0 }')
      [ "$alive" -eq 0 ] && [ "$group_count" -eq 0 ] && break
      sleep 0.02
    done
    {
      echo "=== $label path ==="
      echo "mechanism=$(env "${env_args[@]}" bash -c ". \"$ROOT/bin/fm-timeout-lib.sh\"; fm_timeout_mechanism" 2>/dev/null || echo n/a)"
      echo "parent_pid=$parent shell_pid=$shell_pid helper_pid=$helper_pid pgid=$pgid"
      echo "alive_after_kill=$alive group_count_after_kill=$group_count"
      echo "result=$([ "$alive" -eq 0 ] && [ "$group_count" -eq 0 ] && echo PASS || echo FAIL)"
    } >> "$EVIDENCE/abnormal-parent-evidence.txt"
    [ "$alive" -eq 0 ] && [ "$group_count" -eq 0 ] || {
      fail "$label timeout left a real helper descendant or process-group member after its parent was SIGKILLed"
    }
  done
  pass "abnormal parent death reaps real helper descendants through external, pure-Bash, and perl timeout paths"
}

test_portable_timeout_escalates_term_resistant_process() {
  local fakebin="$TMP_ROOT/portable-kill-after" driver status=0
  mkdir -p "$fakebin"
  cat > "$fakebin/timeout" <<'SH'
#!/usr/bin/env bash
exec perl -e '
  my $pid = fork;
  die "fork failed" unless defined $pid;
  if (!$pid) { setpgrp(0, 0); exec @ARGV }
  local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid $pid, 0; exit 99 };
  alarm 5;
  waitpid $pid, 0;
  exit($? >> 8);
' "$@"
SH
  chmod +x "$fakebin/timeout"
  driver="$TMP_ROOT/portable-kill-after-driver.sh"
  cat > "$driver" <<'SH'
#!/usr/bin/env bash
. "$1"
shift
fm_run_timed 1 "$@"
SH
  chmod +x "$driver"
  perl -e '
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) { setpgrp(0, 0); exec @ARGV }
    local $SIG{ALRM} = sub { kill "KILL", -$pid; waitpid $pid, 0; exit 99 };
    alarm 5;
    waitpid $pid, 0;
    exit($? >> 8);
  ' env PATH="$fakebin:$BASE_PATH" "$driver" "$ROOT/bin/fm-timeout-lib.sh" \
    perl -e '$SIG{TERM} = "IGNORE"; sleep 600' || status=$?
  expect_code 124 "$status" "portable timeout TERM-resistant escalation"
  status=0
  env PATH="$fakebin:$BASE_PATH" "$driver" "$ROOT/bin/fm-timeout-lib.sh" \
    bash -c 'exit 137' || status=$?
  expect_code 137 "$status" "natural command exit 137"
  pass "the portable timeout path force-kills a command that ignores TERM"
}

: > "$EVIDENCE/abnormal-parent-evidence.txt"
echo "fm_timeout_mechanism default: $(bash -c ". \"$ROOT/bin/fm-timeout-lib.sh\"; fm_timeout_mechanism")" | tee "$EVIDENCE/timeout-mechanism.txt"
test_abnormal_parent_does_not_leave_real_helper_descendants
test_portable_timeout_escalates_term_resistant_process
echo "ALL FOCUSED TESTS PASSED" | tee -a "$EVIDENCE/abnormal-parent-evidence.txt"
