#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016,SC2088
# Behavior tests for the watcher-arm PreToolUse seatbelt (docs/arm-pretool-check.md).
#
# bin/fm-arm-command-policy.mjs is the single owner of command classification.
# This suite drives the stable shell transport through all five harness entry
# forms and asserts the per-harness wiring contract without spawning a harness.
# Empirical harness evidence lives in docs/arm-pretool-check.md.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

CHECK="$ROOT/bin/fm-arm-pretool-check.sh"
POLICY="$ROOT/bin/fm-arm-command-policy.mjs"
export FM_HOME="$ROOT"

# --- full cross-harness acceptance matrix ----------------------------------

MATRIX_IDS=()
MATRIX_EXPECTED=()
MATRIX_COMMANDS=()

matrix_case() {
  MATRIX_IDS+=("$1")
  MATRIX_EXPECTED+=("$2")
  MATRIX_COMMANDS+=("$3")
}

matrix_case A01 allow 'bin/fm-watch-arm.sh'
matrix_case A02 allow './bin/fm-watch-arm.sh --restart'
matrix_case A03 allow 'exec bin/fm-watch-arm.sh'
matrix_case A04 allow 'bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A05 allow 'exec bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A06 allow "$ROOT/bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A07 allow "cd '$ROOT'; exec bin/fm-watch-arm.sh"
matrix_case A08 allow "cd '../firstmate'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A09 allow "export FM_HOME='$ROOT'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A10 allow 'source config/x-mode.env; bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case A11 allow "source 'config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A12 allow "source './config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A13 allow "source '$ROOT/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A14 allow "[ -f 'config/x-mode.env' ] && source 'config/x-mode.env'; exec bin/fm-watch-arm.sh"
matrix_case A15 allow "cd $ROOT && exec bin/fm-watch-arm.sh"
matrix_case A16 allow "export FM_HOME=$ROOT && bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case A17 allow $'source "config/x-mode.env"\nbin/fm-watch-checkpoint.sh --seconds 180'

matrix_case R01 allow "pgrep -fl '/bin/fm-watch.sh' || true"
matrix_case R02 allow "ps aux | rg '/bin/fm-watch.sh'"
matrix_case R03 allow "rg -n 'fm-watch-arm.sh &' docs tests"
matrix_case R04 allow "rg -n 'bin/fm-watch-arm.sh; echo bad' docs"
matrix_case R05 allow "git grep 'fm-watch-checkpoint.sh && echo bad'"
matrix_case R06 allow "sed -n '/fm-watch-checkpoint.sh/p' docs/arm-pretool-check.md"
matrix_case R07 allow 'assert_contains "$content" '\''fm-watch-arm.sh &'\'''
matrix_case R08 allow "printf '%s\\n' 'bin/fm-watch-checkpoint.sh --seconds 180 >/tmp/out'"
matrix_case R09 allow "tmux send-keys -t isolated-pi-lab 'bin/fm-watch-arm.sh &' Enter"
matrix_case R10 allow "tmux send-keys -t isolated-pi-lab \"printf '%s\\n' 'bin/fm-watch-arm.sh &'\"; tmux send-keys -t isolated-pi-lab Enter"
matrix_case R11 allow "python3 -c 'print(\"bin/fm-watch-arm.sh; echo data\")'"
matrix_case R12 allow "bash -lc \"rg -n 'fm-watch-arm.sh &' docs\""
matrix_case R13 allow "echo 'pkill -f fm-watch'"
matrix_case R14 allow "rg -n 'pkill -f fm-watch' docs tests"
matrix_case R15 allow "echo ok # bin/fm-watch-arm.sh &"
matrix_case R16 allow $'# bin/fm-watch-arm.sh &\necho ok'
matrix_case R17 allow "printf '%s\\n' 'fm-watch.sh; a && b || c > out' | sed -n '1p'"
matrix_case R18 allow "sh -c 'tmux send-keys -t lab \"bin/fm-watch-arm.sh &\" Enter'"
matrix_case R19 allow "eval 'printf \"%s\\n\" \"bin/fm-watch-arm.sh &\"'"

matrix_case D01 deny 'bin/fm-watch-arm.sh &'
matrix_case D02 deny 'nohup bin/fm-watch-arm.sh'
matrix_case D03 deny 'bin/fm-watch-arm.sh & disown'
matrix_case D04 deny '(bin/fm-watch-arm.sh) &'
matrix_case D05 deny "bash -lc 'bin/fm-watch-arm.sh &'"
matrix_case D06 deny '$(bin/fm-watch-arm.sh)'
matrix_case D07 deny 'echo "$(bin/fm-watch-checkpoint.sh --seconds 180)"'
matrix_case D08 deny 'cat <(bin/fm-watch-arm.sh)'
matrix_case D09 deny 'bin/fm-watch-arm.sh >/tmp/out'
matrix_case D10 deny 'bin/fm-watch-checkpoint.sh --seconds 180 </dev/null'
matrix_case D11 deny 'bin/fm-watch-arm.sh 2>&1 | head -2'
matrix_case D12 deny 'bin/fm-watch-arm.sh | cat'
matrix_case D13 deny 'bin/fm-watch-checkpoint.sh --seconds 180 | timeout 1 cat'
matrix_case D14 deny 'echo before; bin/fm-watch-arm.sh'
matrix_case D15 deny 'bin/fm-watch-checkpoint.sh --seconds 180; echo after'
matrix_case D16 deny 'true && bin/fm-watch-arm.sh'
matrix_case D17 deny 'bin/fm-watch-checkpoint.sh --seconds 180 || true'
matrix_case D18 deny $'bin/fm-watch-arm.sh\nbin/fm-watch-checkpoint.sh --seconds 180'
matrix_case D19 deny "pkill -f '/bin/fm-watch.sh'"
matrix_case D20 deny "command pkill -f '/bin/fm-watch.sh'"
matrix_case D21 deny "/usr/bin/pkill -f '/bin/fm-watch.sh'"
matrix_case D22 deny "sudo pkill -f '/bin/fm-watch.sh'"
matrix_case D23 deny 'kill "$(pgrep -f '\''/bin/fm-watch.sh'\'')"'
matrix_case D24 deny $'bin/fm-watc\\\nh-arm.sh &'
matrix_case D25 deny 'sudo -u root bin/fm-watch-arm.sh &'
matrix_case D26 deny 'env -u PATH bin/fm-watch-arm.sh &'
matrix_case D27 deny "bash -c \$'bin/fm-watch-arm.sh &'"
matrix_case D28 deny $'bash <<\'EOF\'\nbin/fm-watch-arm.sh &\nEOF'
matrix_case D29 deny "WATCHER='bin/fm-watch-arm.sh &' bash -c 'eval \"\$WATCHER\"'"
matrix_case D30 deny "p=\$(pgrep -f '/bin/fm-watch.sh'); kill \"\$p\""
matrix_case D31 deny "env -S 'bin/fm-watch-arm.sh &'"
matrix_case D32 deny "env --split-string='$ROOT/bin/fm-watch-arm.sh &'"
matrix_case D33 deny 'bin/fm-"watch-arm.sh" &'
matrix_case D34 deny "WATCHER='bin/fm-watch-arm.sh'; \"\$WATCHER\" &"
matrix_case D35 deny "bash -c -- 'bin/fm-watch-arm.sh &'"
matrix_case D36 deny 'bash bin/fm-watch-arm.sh &'
matrix_case D37 deny '. bin/fm-watch-arm.sh &'
matrix_case D38 deny "bash <<< 'bin/fm-watch-arm.sh &'"
matrix_case D39 deny "eval 'true;' 'bin/fm-watch-arm.sh &'"
matrix_case D40 deny 'timeout 30 bin/fm-watch-arm.sh &'
matrix_case D41 deny 'gtimeout 30 bin/fm-watch-arm.sh &'
matrix_case D42 deny 'bin/fm-watch-{arm,checkpoint}.sh &'
matrix_case D43 deny 'bin/fm-watch-arm.sh* &'
matrix_case D44 deny "pattern='fm-watch'; pkill -f \"\$pattern\""
matrix_case D45 deny "p=\$(pgrep -f '/bin/fm-watch.sh'); q=\$p; kill \$q"
matrix_case D46 deny '$FM_HOME/bin/fm-watch-arm.sh &'
matrix_case D47 deny '$HOME/firstmate/bin/fm-watch-arm.sh | cat'
matrix_case D48 deny '~/firstmate/bin/fm-watch-arm.sh &'
matrix_case D49 deny 'bin/fm-watch.sh'
matrix_case D50 deny '$FM_HOME/bin/fm-watch.sh'
matrix_case D51 deny '~/firstmate/bin/fm-watch.sh --restart'
matrix_case D52 deny "bin/fm-\$'\x77'atch-arm.sh &"
matrix_case D53 deny 'bin/fm-$"watch"-arm.sh &'
matrix_case D54 deny 'bin/fm-watch-$"arm".sh &'
matrix_case D55 deny 'while true; do pkill -f fm-watch; done'
matrix_case D56 deny 'for x in 1; do pkill -f fm-watch; done'
matrix_case D57 deny 'case x in x) pkill -f fm-watch ;; esac'
matrix_case D58 deny 'until false; do kill $(pgrep -f fm-watch); done'
matrix_case D59 deny "pkill -f 'tsx server.ts'"
matrix_case D60 deny "pkill -u rich -f 'tsx server.ts'"
matrix_case D61 deny 'pkill node'
matrix_case D62 deny 'killall node'
matrix_case D63 deny "time pkill -f 'tsx server.ts'"
matrix_case D64 deny "nice pkill -f 'tsx server.ts'"
matrix_case D65 deny "ionice pkill -f 'tsx server.ts'"
matrix_case D66 deny "kill \"\$(pgrep -f 'tsx server.ts')\""
matrix_case D67 deny 'kill "`pgrep -f '\''tsx server.ts'\''`"'
matrix_case D68 deny "pgrep -f 'tsx server.ts' | xargs kill"
matrix_case D69 deny "if true; then kill \"\$(pgrep -f 'tsx server.ts')\"; fi"
matrix_case D70 deny "case x in x) kill \"\$(pgrep -f 'tsx server.ts')\" ;; esac"
matrix_case D71 deny "kill \"\$(pgrep node)\""
matrix_case D72 deny "kill \"\$(pidof node)\""
matrix_case D73 deny "printf '%s\\n' 'tsx server.ts' | xargs pkill -f"
matrix_case D74 deny "kill \"\$(ps -C node -o pid=)\""
matrix_case D75 deny "case x in x) kill \"\$(ps -C node -o pid=)\" ;; esac"
matrix_case D76 deny "kill \"\$(ps aux | grep '[n]ode' | awk '{print \$2}')\""
matrix_case D77 deny "kill \"\$(lsof -t -c node)\""
matrix_case D78 deny "printf '%s\\n' 'tsx server.ts' | xargs -n1 pkill -f"
matrix_case D79 deny "pgrep node | xargs -n1 kill"
matrix_case D80 deny "ps aux | rg '[n]ode' | awk '{print \$2}' | xargs kill"
matrix_case D81 deny "printf '%s\\n' x | xargs env pkill -f 'tsx server.ts'"
matrix_case D82 deny "pgrep node | xargs env kill"
matrix_case D83 deny "killer=pkill; \"\$killer\" -f 'tsx server.ts'"
matrix_case D84 deny "printf '%s\\n' x | xargs timeout 5 pkill -f 'tsx server.ts'"
matrix_case D85 deny "printf 'tsx server.ts\\n' | xargs sh -c 'pkill -f \"\$0\"'"
matrix_case D86 deny "p=p; \"\${p}\"kill -f 'tsx server.ts'"
matrix_case D87 deny "sh -c 'pkill -f \"\$0\"'"
matrix_case D88 deny "ps aux | awk '{print \$2}' | xargs kill"
matrix_case D89 deny 'p=p; "${p}"kill 4242'
matrix_case D90 deny "printf 'x\\n' | xargs env -S 'pkill -f \"tsx server.ts\"'"
matrix_case D91 deny "printf 'x\\n' | xargs env --split-string='pkill -f \"tsx server.ts\"'"
matrix_case D92 deny "pgrep node | xargs env -S 'kill'"
matrix_case D93 deny "pgrep node | xargs -n1 sh -c 'kill \"\$0\"'"
matrix_case D94 deny "pgrep node | xargs -n1 sh -c 'if true; then kill \"\$0\"; fi'"
matrix_case D95 deny "pgrep node | xargs -n1 sh -c '(kill \"\$0\")'"
matrix_case D96 deny 'kill -TERM -- -1'
matrix_case D97 deny 'kill 0'
matrix_case D98 deny 'kill -TERM -- -12345'
matrix_case D99 deny 'kill -TERM -1'
matrix_case D100 deny "printf 'x\\n' | xargs kill 0"
matrix_case D101 deny 'target=-1; kill -TERM -- "$target"'
matrix_case D102 deny 'target=0; kill "$target"'
matrix_case D103 deny 'target=4242; kill "$target"'
matrix_case D104 deny 'kill -TERM -- 00'
matrix_case D105 deny 'kill -TERM -- +0'
matrix_case D106 deny 'builtin kill -TERM -- -1'
matrix_case D107 deny "\$(printf pkill) -f 'tsx server.ts'"
matrix_case D108 deny 'builtin -- kill -TERM -- -1'
matrix_case D109 deny "builtin command pkill -f 'tsx server.ts'"
matrix_case D110 deny "builtin eval 'kill -TERM -- -1'"
matrix_case D111 deny 'xargs kill <<< "$(pgrep node)"'
matrix_case D112 deny "p=pk; \"\${p}ill\" -f 'tsx server.ts'"
matrix_case D113 deny "sh -c \"\$(printf '%s' 'pkill -f tsx')\""
matrix_case D114 deny "eval \"\$(printf '%s' 'pkill -f tsx')\""
matrix_case D115 deny 'killall5 -TERM'
matrix_case D116 deny 'skill -KILL -u rich'
matrix_case D117 deny 'fuser -k /tmp'
matrix_case D118 deny "sudo FOO=bar pkill -f 'tsx server.ts'"
matrix_case D119 deny "printf '%s\\n' /tmp | xargs fuser -k"
matrix_case D120 deny "tool=pkill; printf '%s\\n' 'tsx server.ts' | xargs \"\$tool\" -f"
matrix_case D121 deny 'bash ./cleanup'
matrix_case D122 deny 'bash'
matrix_case D123 deny "trap 'pkill -f \"tsx server.ts\"' EXIT"
matrix_case D124 deny 'sh ./cleanup'
matrix_case D125 deny "trap 'echo safe' EXIT"
matrix_case D126 deny 'source ./cleanup'
matrix_case D127 deny '. ./cleanup'
matrix_case D128 deny "printf 'x\\n' | xargs sh ./cleanup"
matrix_case D129 deny 'ps -eo pid= | xargs kill'
matrix_case D130 deny $'.\t./cleanup'
matrix_case D131 deny 'xargs kill < /tmp/pids'
matrix_case D132 deny 'CMD=pkill; ${CMD#\}/unused} -f target'
matrix_case D133 deny '$B/p[k]ill -f target'

matrix_case E01 allow "bin/fm-watch-checkpoint.sh --seconds '180;still-one-arg'"
matrix_case E02 allow "bin/fm-watch-checkpoint.sh --label 'fm-watch-arm.sh; literal argument'"
matrix_case E03 allow 'bin/fm-watch-arm.sh # output > file &'
matrix_case E04 allow $'# setup comment with fm-watch.sh; && >\nsource "config/x-mode.env"\nbin/fm-watch-checkpoint.sh --seconds 180'
matrix_case E05 deny "FM_HOME=$ROOT bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case E06 deny "env FM_HOME=$ROOT bin/fm-watch-arm.sh"
matrix_case E07 deny "source '/tmp/not-firstmate/config/x-mode.env'; bin/fm-watch-checkpoint.sh --seconds 180"
matrix_case E08 deny "bash -lc 'bin/fm-watch-checkpoint.sh --seconds 180'"
matrix_case E09 deny '(bin/fm-watch-checkpoint.sh --seconds 180)'
matrix_case E10 deny "eval 'bin/fm-watch-arm.sh &'"
matrix_case E11 deny "exec bash -lc 'bin/fm-watch-arm.sh &'"
matrix_case E12 deny 'bash -lc "$WATCHER_COMMAND" # fm-watch-arm.sh'
matrix_case E13 allow "printf '%s\\n' 'argument has ; and fm-watch-arm.sh and &&'"
matrix_case E14 deny '$CMD &'
matrix_case E15 allow '$FM_HOME/bin/fm-watch-arm.sh'
matrix_case E16 allow '~/firstmate/bin/fm-watch-checkpoint.sh --seconds 180'
matrix_case E30 deny '$FM_HOME/bin/fm-teardown.sh &'
matrix_case E31 deny '$B/fm-pr-merge.sh task1 https://x/1'
matrix_case E32 deny '$B/ls -la'
matrix_case E33 deny '$DIR/$FILE 12345'
matrix_case E34 deny '$B/pkill foo'
matrix_case E35 deny '(cd "$ROOT" && $B/fm-pr-check.sh task1 https://x/1 | grep something | tail -1); $B/fm-fetch.sh task2 | grep other | tail -2; (cd "$ROOT/sub" && $B/fm-build.sh task3 | tail -2); $B/fm-send.sh task4 "hello there, multi word message"; $B/fm-wake-drain.sh --ack-through 5 --recovery-generation 3'
matrix_case E36 deny '$B/p[k]dir/fm-pr-merge.sh task1 https://x/1'
matrix_case E37 allow '"$B/fm-pr-merge.sh" task1 https://x/1'
matrix_case E38 allow '"$B"/ls -la'
matrix_case E39 allow '(cd "$ROOT" && "$B"/fm-pr-check.sh task1 https://x/1 | grep something | tail -1); "$B"/fm-fetch.sh task2 | grep other | tail -2; (cd "$ROOT/sub" && "$B"/fm-build.sh task3 | tail -2); "$B"/fm-send.sh task4 "hello there, multi word message"; "$B"/fm-wake-drain.sh --ack-through 5 --recovery-generation 3'
matrix_case E40 allow '"$B/p[k]dir"/fm-pr-merge.sh task1 https://x/1'
matrix_case E41 allow 'B="pkill -f target"; "$B"/fm-pr-merge.sh task1'
matrix_case E42 deny 'B="pkill -f target"; $B/fm-pr-merge.sh task1'
matrix_case E17 allow 'for f in 1; do echo fm-watch; done'
matrix_case E18 allow "printf '%s\\n' data | xargs echo pkill"
matrix_case E20 allow "ps aux | awk '{print \$2}'"
matrix_case E21 allow 'kill 4242'
matrix_case E22 allow "printf 'x\\n' | xargs env -S 'echo pkill'"
matrix_case E25 allow 'fuser /tmp'
matrix_case E26 allow "bash -c 'echo safe'"
matrix_case E27 allow "bash <<< 'echo safe'"
matrix_case E28 allow 'source config/x-mode.env'
matrix_case E29 allow 'xargs kill --list < /tmp/pids'
matrix_case E23 allow "pgrep node | xargs -n1 sh -c 'echo \"\$0\"'"
matrix_case E24 allow "pgrep node | xargs -n1 sh -c 'if true; then echo \"\$0\"; fi'"

MATRIX_TMP=$(mktemp -d "${TMPDIR:-/tmp}/fm-arm-policy-matrix.XXXXXX")
FM_TEST_CLEANUP_DIRS+=("$MATRIX_TMP")
trap fm_test_cleanup EXIT

run_matrix_entry() {
  local id=$1 expected=$2 entry=$3 cmd=$4 payload out_file err_file rc
  out_file="$MATRIX_TMP/$id-$entry.out"
  err_file="$MATRIX_TMP/$id-$entry.err"

  case "$entry" in
    codex)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    claude)
      payload=$(jq -cn --arg command "$cmd" '{tool_name:"Bash",tool_input:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" --claude >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    grok)
      payload=$(jq -cn --arg command "$cmd" '{toolName:"run_terminal_command",toolInput:{command:$command}}')
      printf '%s' "$payload" | "$CHECK" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    opencode|pi)
      "$CHECK" --command "$cmd" >"$out_file" 2>"$err_file"
      rc=$?
      ;;
    *)
      fail "unknown matrix entry form: $entry"
      ;;
  esac

  if [ "$expected" = allow ]; then
    [ "$rc" -eq 0 ] || fail "$id via $entry must allow, got exit $rc: $(cat "$err_file")"
    [ ! -s "$out_file" ] || fail "$id via $entry allow must leave stdout empty: $(cat "$out_file")"
    [ ! -s "$err_file" ] || fail "$id via $entry allow must leave stderr empty: $(cat "$err_file")"
    return
  fi

  [ "$rc" -eq 2 ] || fail "$id via $entry must deny, got exit $rc"
  jq -e '.hookSpecificOutput.permissionDecision == "deny" and (.systemMessage | test("\\[(watcher-(background|pipeline|redirection|bundled|nested|direct)|broad-(process|watcher)-kill|unclassifiable-protected-command)\\]"))' "$err_file" >/dev/null 2>&1 \
    || fail "$id via $entry deny must carry a stable reason code on stderr: $(cat "$err_file")"
  if [ "$entry" = claude ]; then
    [ ! -s "$out_file" ] || fail "$id via claude deny must leave stdout empty: $(cat "$out_file")"
  elif [ "$entry" = grok ]; then
    jq -e '.decision == "deny"' "$out_file" >/dev/null 2>&1 \
      || fail "$id via grok deny must carry decision=deny on stdout: $(cat "$out_file")"
  fi
}

test_full_acceptance_matrix() {
  local i entry
  for ((i = 0; i < ${#MATRIX_IDS[@]}; i++)); do
    for entry in codex claude grok opencode pi; do
      run_matrix_entry "${MATRIX_IDS[$i]}" "${MATRIX_EXPECTED[$i]}" "$entry" "${MATRIX_COMMANDS[$i]}"
    done
    pass "matrix ${MATRIX_IDS[$i]}: ${MATRIX_EXPECTED[$i]} through all five entry forms"
  done
}

assert_policy() {
  local id=$1 expected=$2 command=$3 output
  output=$(node "$POLICY" --root "$ROOT" --home "$ROOT" --command "$command") \
    || fail "$id direct policy invocation failed"
  case "$output" in
    "$expected"|"$expected"$'\t'*) : ;;
    *) fail "$id direct policy expected $expected, got: $output" ;;
  esac
  pass "direct policy $id: $expected"
}

test_direct_policy_contract() {
  local heredoc_data heredoc_watcher heredoc_broad_data
  assert_policy direct-data-pkill allow "echo 'pkill -f fm-watch'"
  assert_policy direct-broad-pkill $'deny\tbroad-process-kill' "pkill -f '/bin/fm-watch.sh'"
  assert_policy direct-loop-broad-pkill $'deny\tbroad-process-kill' 'while true; do pkill -f fm-watch; done'
  assert_policy direct-broad-pkill-no-watcher $'deny\tbroad-process-kill' "pkill -f 'tsx server.ts'"
  assert_policy direct-bare-pkill $'deny\tbroad-process-kill' 'pkill node'
  assert_policy direct-killall $'deny\tbroad-process-kill' 'killall node'
  for wrapper in time nice ionice nohup env sudo command exec; do
    assert_policy "direct-broad-pkill-wrapper-$wrapper" $'deny\tbroad-process-kill' "$wrapper pkill -f 'tsx server.ts'"
  done
  assert_policy direct-unresolved-time-option-broad-pkill $'deny\tbroad-process-kill' "/usr/bin/time -o /tmp/timing pkill -f 'tsx server.ts'"
  assert_policy direct-loop-broad-kill-pgrep $'deny\tbroad-process-kill' 'until false; do kill $(pgrep -f fm-watch); done'
  assert_policy direct-loop-no-kill-allowed allow 'for f in 1; do echo fm-watch; done'
  assert_policy direct-unsupported-broad-data allow "if true; then printf '%s\\n' pkill; fi"
  assert_policy direct-unsupported-broad-kill $'deny\tbroad-process-kill' "if true; then pkill -f 'tsx server.ts'; fi"
  assert_policy direct-unsupported-qualified-broad-kill $'deny\tbroad-process-kill' "if true; then /usr/bin/pkill -f 'tsx server.ts'; fi"
  assert_policy direct-unsupported-wrapped-broad-kill $'deny\tbroad-process-kill' "if true; then time pkill -f 'tsx server.ts'; fi"
  assert_policy direct-case-broad-kill $'deny\tbroad-process-kill' "case x in x) pkill -f 'tsx server.ts' ;; esac"
  assert_policy direct-pgrep-substitution-kill $'deny\tbroad-process-kill' "kill \"\$(pgrep -f 'tsx server.ts')\""
  assert_policy direct-pgrep-backtick-kill $'deny\tbroad-process-kill' 'kill "`pgrep -f '\''tsx server.ts'\''`"'
  assert_policy direct-pgrep-xargs-kill $'deny\tbroad-process-kill' "pgrep -f 'tsx server.ts' | xargs kill"
  assert_policy direct-unsupported-pgrep-substitution-kill $'deny\tbroad-process-kill' "if true; then kill \"\$(pgrep -f 'tsx server.ts')\"; fi"
  assert_policy direct-case-pgrep-substitution-kill $'deny\tbroad-process-kill' "case x in x) kill \"\$(pgrep -f 'tsx server.ts')\" ;; esac"
  assert_policy direct-plain-pgrep-substitution-kill $'deny\tbroad-process-kill' "kill \"\$(pgrep node)\""
  assert_policy direct-pidof-substitution-kill $'deny\tbroad-process-kill' "kill \"\$(pidof node)\""
  assert_policy direct-xargs-broad-pkill $'deny\tbroad-process-kill' "printf '%s\\n' 'tsx server.ts' | xargs pkill -f"
  assert_policy direct-ps-name-selector-kill $'deny\tbroad-process-kill' "kill \"\$(ps -C node -o pid=)\""
  assert_policy direct-case-ps-name-selector-kill $'deny\tbroad-process-kill' "case x in x) kill \"\$(ps -C node -o pid=)\" ;; esac"
  assert_policy direct-ps-grep-name-selector-kill $'deny\tbroad-process-kill' "kill \"\$(ps aux | grep '[n]ode' | awk '{print \$2}')\""
  assert_policy direct-lsof-name-selector-kill $'deny\tbroad-process-kill' "kill \"\$(lsof -t -c node)\""
  assert_policy direct-ps-grep-read-only allow "ps aux | grep '[n]ode' | awk '{print \$2}'"
  assert_policy direct-lsof-pid-read-only allow 'lsof -t -p 4242'
  assert_policy direct-xargs-broad-pkill-with-option $'deny\tbroad-process-kill' "printf '%s\\n' 'tsx server.ts' | xargs -n1 pkill -f"
  assert_policy direct-pgrep-xargs-kill-with-option $'deny\tbroad-process-kill' 'pgrep node | xargs -n1 kill'
  assert_policy direct-xargs-data-argument allow "printf '%s\\n' data | xargs echo pkill"
  assert_policy direct-ps-rg-name-selector-xargs-kill $'deny\tbroad-process-kill' "ps aux | rg '[n]ode' | awk '{print \$2}' | xargs kill"
  assert_policy direct-ps-rg-read-only allow "ps aux | rg '[n]ode' | awk '{print \$2}'"
  assert_policy direct-xargs-env-broad-pkill $'deny\tbroad-process-kill' "printf '%s\\n' x | xargs env pkill -f 'tsx server.ts'"
  assert_policy direct-pgrep-xargs-env-kill $'deny\tbroad-process-kill' 'pgrep node | xargs env kill'
  assert_policy direct-literal-dynamic-broad-kill $'deny\tbroad-process-kill' "killer=pkill; \"\$killer\" -f 'tsx server.ts'"
  assert_policy direct-literal-dynamic-safe-command $'deny\tbroad-process-kill' 'runner=echo; "$runner" pkill'
  assert_policy direct-xargs-timeout-broad-pkill $'deny\tbroad-process-kill' "printf '%s\\n' x | xargs timeout 5 pkill -f 'tsx server.ts'"
  assert_policy direct-xargs-shell-broad-pkill $'deny\tbroad-process-kill' "printf 'tsx server.ts\\n' | xargs sh -c 'pkill -f \"\$0\"'"
  assert_policy direct-dynamic-suffix-broad-kill $'deny\tbroad-process-kill' "p=p; \"\${p}\"kill -f 'tsx server.ts'"
  assert_policy direct-dynamic-suffix-numeric-kill $'deny\tbroad-process-kill' 'p=p; "${p}"kill 4242'
  assert_policy direct-literal-exact-pid allow 'kill 4242'
  assert_policy direct-signal-exact-pid allow 'kill -TERM 4242'
  assert_policy direct-broadcast-all $'deny\tbroad-process-kill' 'kill -TERM -- -1'
  assert_policy direct-broadcast-current-group $'deny\tbroad-process-kill' 'kill 0'
  assert_policy direct-broadcast-process-group $'deny\tbroad-process-kill' 'kill -TERM -- -12345'
  assert_policy direct-broadcast-without-terminator $'deny\tbroad-process-kill' 'kill -TERM -1'
  assert_policy direct-xargs-broadcast-current-group $'deny\tbroad-process-kill' "printf 'x\\n' | xargs kill 0"
  assert_policy direct-dynamic-broadcast-all $'deny\tbroad-process-kill' 'target=-1; kill -TERM -- "$target"'
  assert_policy direct-dynamic-broadcast-current-group $'deny\tbroad-process-kill' 'target=0; kill "$target"'
  assert_policy direct-dynamic-exact-pid $'deny\tbroad-process-kill' 'target=4242; kill "$target"'
  assert_policy direct-job-spec-kill $'deny\tbroad-process-kill' 'sleep 60 & kill %?sleep'
  assert_policy direct-broadcast-leading-zero $'deny\tbroad-process-kill' 'kill -TERM -- 00'
  assert_policy direct-broadcast-plus-zero $'deny\tbroad-process-kill' 'kill -TERM -- +0'
  assert_policy direct-builtin-broadcast $'deny\tbroad-process-kill' 'builtin kill -TERM -- -1'
  assert_policy direct-unreadable-dynamic-broad-kill $'deny\tbroad-process-kill' "\$(printf pkill) -f 'tsx server.ts'"
  assert_policy direct-builtin-terminated-broadcast $'deny\tbroad-process-kill' 'builtin -- kill -TERM -- -1'
  assert_policy direct-builtin-command-broad-kill $'deny\tbroad-process-kill' "builtin command pkill -f 'tsx server.ts'"
  assert_policy direct-builtin-eval-broadcast $'deny\tbroad-process-kill' "builtin eval 'kill -TERM -- -1'"
  assert_policy direct-xargs-substitution-selector-kill $'deny\tbroad-process-kill' 'xargs kill <<< "$(pgrep node)"'
  assert_policy direct-dynamic-prefix-broad-kill $'deny\tbroad-process-kill' "p=pk; \"\${p}ill\" -f 'tsx server.ts'"
  assert_policy direct-unreadable-shell-broad-pkill $'deny\tbroad-process-kill' "sh -c \"\$(printf '%s' 'pkill -f tsx')\""
  assert_policy direct-unreadable-shell-stdin-broad-pkill $'deny\tbroad-process-kill' 'payload='"'"'pkill -f tsx'"'"'; bash <<< "$payload"'
  assert_policy direct-unreadable-shell-script $'deny\tbroad-process-kill' 'script=payload; bash "$script"'
  assert_policy direct-unreadable-eval-broad-pkill $'deny\tbroad-process-kill' "eval \"\$(printf '%s' 'pkill -f tsx')\""
  assert_policy direct-killall5 $'deny\tbroad-process-kill' 'killall5 -TERM'
  assert_policy direct-skill-user-selector $'deny\tbroad-process-kill' 'skill -KILL -u rich'
  assert_policy direct-fuser-kill $'deny\tbroad-process-kill' 'fuser -k /tmp'
  assert_policy direct-sudo-environment-broad-pkill $'deny\tbroad-process-kill' "sudo FOO=bar pkill -f 'tsx server.ts'"
  assert_policy direct-xargs-fuser-kill $'deny\tbroad-process-kill' "printf '%s\\n' /tmp | xargs fuser -k"
  assert_policy direct-dynamic-xargs-child $'deny\tbroad-process-kill' "tool=pkill; printf '%s\\n' 'tsx server.ts' | xargs \"\$tool\" -f"
  assert_policy direct-fuser-read-only allow 'fuser /tmp'
  assert_policy direct-command-query-pkill allow 'command -v pkill'
  assert_policy direct-command-query-killall allow 'command -V killall'
  assert_policy direct-command-path-broad-pkill $'deny\tbroad-process-kill' "command -p pkill -f 'tsx server.ts'"
  assert_policy direct-shell-broad-pkill $'deny\tbroad-process-kill' "sh -c 'pkill -f \"\$0\"'"
  assert_policy direct-ps-awk-xargs-kill $'deny\tbroad-process-kill' "ps aux | awk '{print \$2}' | xargs kill"
  assert_policy direct-ps-pid-list-xargs-kill $'deny\tbroad-process-kill' 'ps -eo pid= | xargs kill'
  assert_policy direct-ps-combined-pid-list-xargs-kill $'deny\tbroad-process-kill' 'ps -eo pid=,ppid= | xargs kill'
  assert_policy direct-ps-pid-list-xargs-data allow 'ps -eo pid= | xargs echo'
  assert_policy direct-ps-pid-list-xargs-list allow 'ps -eo pid= | xargs kill --list'
  assert_policy direct-xargs-unreadable-kill-targets $'deny\tbroad-process-kill' 'xargs kill < /tmp/pids'
  assert_policy direct-xargs-kill-list allow 'xargs kill --list < /tmp/pids'
  assert_policy direct-ps-awk-read-only allow "ps aux | awk '{print \$2}'"
  assert_policy direct-xargs-env-split-broad-pkill $'deny\tbroad-process-kill' "printf 'x\\n' | xargs env -S 'pkill -f \"tsx server.ts\"'"
  assert_policy direct-xargs-env-long-split-broad-pkill $'deny\tbroad-process-kill' "printf 'x\\n' | xargs env --split-string='pkill -f \"tsx server.ts\"'"
  assert_policy direct-pgrep-xargs-env-split-kill $'deny\tbroad-process-kill' "pgrep node | xargs env -S 'kill'"
  assert_policy direct-xargs-env-split-data allow "printf 'x\\n' | xargs env -S 'echo pkill'"
  assert_policy direct-pgrep-xargs-shell-kill $'deny\tbroad-process-kill' "pgrep node | xargs -n1 sh -c 'kill \"\$0\"'"
  assert_policy direct-pgrep-xargs-shell-data allow "pgrep node | xargs -n1 sh -c 'echo \"\$0\"'"
  assert_policy direct-pgrep-xargs-nested-shell-kill $'deny\tbroad-process-kill' "pgrep node | xargs -n1 sh -c 'if true; then kill \"\$0\"; fi'"
  assert_policy direct-pgrep-xargs-shell-group-kill $'deny\tbroad-process-kill' "pgrep node | xargs -n1 sh -c '(kill \"\$0\")'"
  assert_policy direct-pgrep-xargs-nested-shell-data allow "pgrep node | xargs -n1 sh -c 'if true; then echo \"\$0\"; fi'"
  assert_policy direct-broad-comment allow $'# killall node\necho ok'
  assert_policy direct-pipeline $'deny\twatcher-pipeline' 'bin/fm-watch-arm.sh | cat'
  assert_policy direct-leading-redirection $'deny\twatcher-redirection' '>/tmp/out bin/fm-watch-arm.sh'
  assert_policy direct-unclassifiable $'deny\tunclassifiable-protected-command' "bin/fm-watch-arm.sh 'unterminated"
  assert_policy direct-unsupported $'deny\tunclassifiable-protected-command' 'if true; then bin/fm-watch-arm.sh; fi'
  assert_policy direct-constructed-payload $'deny\tbroad-process-kill' "WATCHER='bin/fm-watch-arm.sh &'; bash -lc \"\$WATCHER\""
  assert_policy direct-parameter-export allow 'export FM_HOME=${HOME}; bin/fm-watch-checkpoint.sh --seconds 180'
  assert_policy direct-expanded-arm-blessed allow '$FM_HOME/bin/fm-watch-arm.sh'
  assert_policy direct-expanded-arm-background $'deny\twatcher-background' '$FM_HOME/bin/fm-watch-arm.sh &'
  assert_policy direct-expanded-arm-pipeline $'deny\twatcher-pipeline' '$HOME/firstmate/bin/fm-watch-arm.sh | cat'
  assert_policy direct-watch-not-blessed $'deny\twatcher-direct' 'bin/fm-watch.sh'
  assert_policy direct-watch-expanded $'deny\twatcher-direct' '$FM_HOME/bin/fm-watch.sh'
  assert_policy direct-watch-safe-shape $'deny\twatcher-direct' 'cd /tmp; bin/fm-watch.sh'
  # dynamic-executable-basename narrowing (docs/arm-pretool-check.md): a
  # directory-prefix expansion ahead of a literal, non-kill filename is not
  # dynamic-executable risk only when the whole prefix expansion is
  # double-quoted - double quotes rule out field splitting and pathname
  # expansion, so a runtime value with embedded whitespace or glob metacharacters
  # cannot resolve to extra words or a different command. An UNQUOTED prefix
  # expansion still denies even with a literal, known-safe basename, because an
  # attacker-influenced runtime value could field-split into an unrelated
  # command (e.g. B='pkill -f target'; $B/fm-pr-merge.sh runs `pkill -f
  # target/fm-pr-merge.sh`). Only an unresolved filename/basename itself is
  # otherwise dynamic-executable risk.
  assert_policy direct-unquoted-prefix-literal-script $'deny\tbroad-process-kill' '$B/fm-pr-merge.sh task1 https://x/1'
  assert_policy direct-unquoted-prefix-literal-coreutil $'deny\tbroad-process-kill' '$B/ls -la'
  assert_policy direct-quoted-prefix-literal-script allow '"$B/fm-pr-merge.sh" task1 https://x/1'
  assert_policy direct-quoted-prefix-literal-coreutil allow '"$B"/ls -la'
  assert_policy direct-fully-dynamic-program-name $'deny\tbroad-process-kill' '$CMD 12345'
  assert_policy direct-dynamic-filename-component $'deny\tbroad-process-kill' '$DIR/$FILE 12345'
  assert_policy direct-dynamic-prefix-kill-basename $'deny\tbroad-process-kill' '$B/pkill foo'
  assert_policy direct-parameter-expansion-slash-broad-kill $'deny\tbroad-process-kill' 'CMD=pkill; ${CMD#*/} -f target'
  assert_policy direct-parameter-expansion-escaped-brace-broad-kill $'deny\tbroad-process-kill' 'CMD=pkill; ${CMD#\}/unused} -f target'
  assert_policy direct-parameter-expansion-quoted-slash-broad-kill $'deny\tbroad-process-kill' "CMD=pkill; \${CMD#'/'} -f target"
  assert_policy direct-dynamic-glob-basename $'deny\tbroad-process-kill' '$B/p[k]ill -f target'
  assert_policy direct-unquoted-glob-prefix-literal-script $'deny\tbroad-process-kill' '$B/p[k]dir/fm-pr-merge.sh task1 https://x/1'
  assert_policy direct-quoted-glob-prefix-literal-script allow '"$B/p[k]dir"/fm-pr-merge.sh task1 https://x/1'
  assert_policy direct-unquoted-prefix-compound-chain $'deny\tbroad-process-kill' \
    '(cd "$ROOT" && $B/fm-pr-check.sh task1 https://x/1 | grep something | tail -1); $B/fm-fetch.sh task2 | grep other | tail -2; (cd "$ROOT/sub" && $B/fm-build.sh task3 | tail -2); $B/fm-send.sh task4 "hello there, multi word message"; $B/fm-wake-drain.sh --ack-through 5 --recovery-generation 3'
  assert_policy direct-quoted-prefix-compound-chain allow \
    '(cd "$ROOT" && "$B"/fm-pr-check.sh task1 https://x/1 | grep something | tail -1); "$B"/fm-fetch.sh task2 | grep other | tail -2; (cd "$ROOT/sub" && "$B"/fm-build.sh task3 | tail -2); "$B"/fm-send.sh task4 "hello there, multi word message"; "$B"/fm-wake-drain.sh --ack-through 5 --recovery-generation 3'
  # Even with an embedded-whitespace runtime value that would field-split an
  # unquoted prefix into a separate pkill invocation, the quoted form stays
  # a single shell word (worst case: a nonexistent path), so it still allows.
  assert_policy direct-quoted-prefix-embedded-spaces-safe allow 'B="pkill -f target"; "$B"/fm-pr-merge.sh task1'
  assert_policy direct-unquoted-prefix-embedded-spaces-exploit-shape $'deny\tbroad-process-kill' 'B="pkill -f target"; $B/fm-pr-merge.sh task1'
  heredoc_data=$'cat <<\'EOF\'\nbin/fm-watch-arm.sh &\nEOF'
  heredoc_watcher=$'bin/fm-watch-arm.sh <<\'EOF\'\ndata only\nEOF'
  heredoc_broad_data=$'cat <<\'EOF\'\npkill -f tsx\nkillall node\nEOF'
  assert_policy direct-heredoc-data allow "$heredoc_data"
  assert_policy direct-heredoc-watcher $'deny\twatcher-redirection' "$heredoc_watcher"
  assert_policy direct-heredoc-broad-data allow "$heredoc_broad_data"
}

# --- CLI parsing -------------------------------------------------------------

test_command_equals_form() {
  "$CHECK" --command='bin/fm-watch-arm.sh &' >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "--command=<val> form must parse the same as --command <val>"
  pass "--command=<val> equals-form parses correctly"
}

test_background_flag_accepted_and_non_gating() {
  local rc_bg rc_nobg
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' --background true >/dev/null 2>&1
  rc_bg=$?
  "$CHECK" --command 'exec bin/fm-watch-arm.sh' >/dev/null 2>&1
  rc_nobg=$?
  [ "$rc_bg" -eq 0 ] || fail "--background true must not change the allow decision on its own, got exit $rc_bg"
  [ "$rc_bg" -eq "$rc_nobg" ] || fail "--background flag must be accepted without altering the decision"
  pass "--background is accepted for interface parity and is never itself a deny signal"
}

test_unknown_flag_errors() {
  "$CHECK" --bogus-flag >/dev/null 2>&1
  [ "$?" -eq 2 ] || fail "an unrecognized flag must exit non-zero, not silently allow"
  pass "unknown CLI flag is rejected"
}

# --- stdin JSON mode ----------------------------------------------------------

test_stdin_grok_schema_deny() {
  local out rc
  out=$(printf '%s' '{"toolInput":{"command":"bin/fm-watch-arm.sh &","background":false},"toolName":"run_terminal_command"}' | "$CHECK" 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "grok toolInput.command schema must be read and denied, got exit $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 || fail "stdout must carry Grok's {\"decision\":\"deny\",...} shape: $out"
  pass "stdin grok schema (toolInput.command): denied with Grok-shaped stdout JSON"
}

test_stdin_claude_codex_schema_allow() {
  local rc
  printf '%s' '{"tool_input":{"command":"exec bin/fm-watch-arm.sh"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "claude/codex tool_input.command schema must be read and allowed for the blessed shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): blessed shape allowed"
}

test_stdin_claude_codex_schema_deny() {
  local rc
  printf '%s' '{"tool_input":{"command":"bin/fm-watch-arm.sh &"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "claude/codex tool_input.command schema must be denied for the backgrounded shape, got exit $rc"
  pass "stdin claude/codex schema (tool_input.command): backgrounded shape denied"
}

test_stdin_unrelated_command_allowed() {
  local rc
  printf '%s' '{"tool_input":{"command":"ls -la"},"tool_name":"Bash"}' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "an unrelated command must pass through allowed, got exit $rc"
  pass "stdin: unrelated command is a fast allow"
}

test_prefilter_is_strict_superset() {
  local rc
  # A command with no fm-watch substring is fast-allowed by the transport
  # prefilter without ever invoking the classifier.
  "$CHECK" --command 'ls -la /bin && echo done' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a command with no fm-watch substring must be fast-allowed, got exit $rc"
  # A deniable protected execution carries the fm-watch bytes, so the prefilter
  # must delegate to the classifier and the deny must survive.
  "$CHECK" --command 'bin/fm-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a deniable fm-watch command, not fast-allow it, got exit $rc"
  # A broad watcher kill also contains the fm-watch bytes and must still deny.
  "$CHECK" --command "pkill -f '/bin/fm-watch.sh'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a broad watcher kill, not fast-allow it, got exit $rc"
  "$CHECK" --command "pkill -f 'tsx server.ts'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a broad process kill, not fast-allow it, got exit $rc"
  # Obfuscated protected paths lose the literal fm-watch bytes (a line
  # continuation or a quote splits them), yet the classifier reconstructs them.
  # The prefilter normalizes those bytes first, so both must still delegate and
  # deny rather than slip through as a fast allow.
  "$CHECK" --command "$(printf 'bin/fm-watc\\\nh-arm.sh &')" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a line-continuation-split protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/fm-"watch-arm.sh" &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a quote-split protected path, not fast-allow it, got exit $rc"
  # A quoting-decoder marker ($' ANSI-C or $" locale) hides the fm-watch bytes
  # from the cheap byte strip but the classifier reconstructs them, so the
  # prefilter must delegate on the marker rather than fast-allow. Without this
  # the byte strip loses the encoded character and slips the command through.
  "$CHECK" --command "bin/fm-\$'\x77'atch-arm.sh &" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate an ANSI-C-encoded protected path, not fast-allow it, got exit $rc"
  "$CHECK" --command 'bin/fm-$"watch"-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "prefilter must delegate a locale-string-encoded protected path, not fast-allow it, got exit $rc"
  # A command whose invoked filename itself is unresolved must reach the
  # classifier and fail closed even when it is not a watcher reference. A
  # merely dynamic directory-prefix ahead of a literal, known-safe filename
  # (e.g. "$FM_HOME/bin/fm-teardown.sh") is not this case; see E30/E31/E32.
  "$CHECK" --command '$CMD &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 2 ] || fail "a fully dynamic non-watcher executable must be denied, got exit $rc"
  "$CHECK" --command 'echo "$HOME/scratch" && ls -la' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign \$HOME command must still fast-allow, got exit $rc"
  # A benign command that only mentions fm-watch as data still reaches the
  # classifier and is allowed there, proving the prefilter owns no verdict.
  "$CHECK" --command "echo 'pkill -f fm-watch'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "a benign fm-watch-substring command must be classified and allowed, got exit $rc"
  pass "transport prefilter is a strict superset: non-fm-watch fast-allows, every fm-watch and quoting-decoder-marker command reaches the classifier"
}

# --- fail-open ----------------------------------------------------------------

test_failopen_empty_stdin() {
  local rc
  printf '' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "empty stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: empty stdin"
}

test_failopen_garbage_stdin() {
  local rc
  printf 'not json at all {{{' | "$CHECK" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "unparseable stdin must fail open (exit 0), got exit $rc"
  pass "fail-open: unparseable JSON on stdin"
}

test_failopen_missing_jq() {
  local dir fakebin rc real
  dir=$(fm_test_tmproot fm-arm-pretool-check)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  local tool
  for tool in bash grep sed tr; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" bash -c "printf '%s' '{\"tool_input\":{\"command\":\"bin/fm-watch-arm.sh &\"}}' | '$CHECK'" >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing jq must fail open (exit 0) rather than crash-deny, got exit $rc"
  pass "fail-open: missing jq on stdin path"
}

test_failopen_missing_node() {
  local dir fakebin rc real tool
  dir=$(fm_test_tmproot fm-arm-pretool-node)
  fakebin="$dir/fakebin"
  mkdir -p "$fakebin"
  for tool in bash dirname; do
    real=$(command -v "$tool")
    ln -sf "$real" "$fakebin/$tool"
  done
  PATH="$fakebin" "$CHECK" --command 'bin/fm-watch-arm.sh &' >/dev/null 2>&1
  rc=$?
  [ "$rc" -eq 0 ] || fail "missing node must fail open (exit 0), got exit $rc"
  pass "fail-open: missing classifier runtime"
}

# --- --claude output shaping ---------------------------------------------------

test_claude_mode_stdout_empty_on_deny() {
  local out err rc stderr_file
  # Keep stderr capture under TMPDIR so concurrent isolation-proof workers do
  # not share a fixed global /tmp path.
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/fm-arm-pretool-check-claude-stderr.XXXXXX")
  out=$("$CHECK" --claude --command 'bin/fm-watch-arm.sh &' 2>"$stderr_file")
  rc=$?
  err=$(cat "$stderr_file" 2>/dev/null)
  rm -f "$stderr_file"
  [ "$rc" -eq 2 ] || fail "--claude deny must still exit 2, got $rc"
  [ -z "$out" ] || fail "--claude deny must leave stdout EMPTY (Claude Code only honors a stderr-only deny), got: $out"
  printf '%s' "$err" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null 2>&1 \
    || fail "--claude deny must put hookSpecificOutput.permissionDecision=deny on stderr: $err"
  pass "--claude: stdout empty, stderr carries hookSpecificOutput deny JSON"
}

test_default_mode_stdout_has_grok_json_on_deny() {
  local out rc
  out=$("$CHECK" --command 'bin/fm-watch-arm.sh &' 2>/dev/null)
  rc=$?
  [ "$rc" -eq 2 ] || fail "default deny must exit 2, got $rc"
  printf '%s' "$out" | jq -e '.decision == "deny"' >/dev/null 2>&1 \
    || fail "default (non-claude) deny must put Grok's decision JSON on stdout: $out"
  pass "default mode: stdout carries Grok-shaped decision JSON on deny"
}

test_allow_is_silent_both_modes() {
  local out1 out2
  out1=$("$CHECK" --command 'exec bin/fm-watch-arm.sh' 2>&1)
  out2=$("$CHECK" --claude --command 'exec bin/fm-watch-arm.sh' 2>&1)
  [ -z "$out1" ] || fail "default allow must be silent, got: $out1"
  [ -z "$out2" ] || fail "--claude allow must be silent, got: $out2"
  pass "allow is silent on both stdout and stderr in default and --claude mode"
}

# --- harness wiring: each adapter invokes the shared checker -----------------

# --- shellcheck (belt-and-suspenders; CI/CONTRIBUTING.md also runs this) -----
#
# Delegated to bin/fm-lint.sh rather than calling shellcheck directly, because
# that script is the single owner of the lint definition - the file set, the
# pinned version, and the options, including --external-sources. Calling the
# linter directly here would be a second, weaker copy of that definition, and it
# disagreed with the owner the moment this checker sourced a shared library.

test_shellcheck_clean() {
  local out
  command -v shellcheck >/dev/null 2>&1 || { pass "shellcheck not installed, skipping"; return; }
  out=$("$ROOT/bin/fm-lint.sh" "$CHECK" 2>&1)     || fail "bin/fm-arm-pretool-check.sh is not lint-clean under the pinned definition: $out"
  pass "bin/fm-arm-pretool-check.sh is clean under bin/fm-lint.sh"
}

test_full_acceptance_matrix
test_direct_policy_contract
test_command_equals_form
test_background_flag_accepted_and_non_gating
test_unknown_flag_errors
test_stdin_grok_schema_deny
test_stdin_claude_codex_schema_allow
test_stdin_claude_codex_schema_deny
test_stdin_unrelated_command_allowed
test_prefilter_is_strict_superset
test_failopen_empty_stdin
test_failopen_garbage_stdin
test_failopen_missing_jq
test_failopen_missing_node
test_claude_mode_stdout_empty_on_deny
test_default_mode_stdout_has_grok_json_on_deny
test_allow_is_silent_both_modes
test_shellcheck_clean
