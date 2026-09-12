#!/usr/bin/env bash
# Live product demo: SIGKILL the fm_run_timed caller and prove zero sleep helpers remain.
set -u
ROOT="/home/rich/.no-mistakes/worktrees/7ce0540b75f4/01M29X96Q8GBCS5NB92S2S7GWB"
EVID="/home/rich/.no-mistakes/evidence/01M29X96Q8GBCS5NB92S2S7GWB"
. "$ROOT/bin/fm-timeout-lib.sh"

run_one() {
  local label=$1; shift
  local pids_file="$EVID/live-${label}.pids"
  local log="$EVID/live-${label}.log"
  local driver="$EVID/live-${label}-driver.sh"
  rm -f "$pids_file" "$log"
  cat > "$driver" <<'SH'
#!/usr/bin/env bash
set -u
. "$1"
fm_run_timed 60 bash -c '
  printf "%s\n" "$BASHPID" > "$1"
  printf "%s\n" "$(ps -o pgid= -p "$BASHPID" | tr -d "[:space:]")" >> "$1"
  sleep 600 &
  printf "%s\n" "$!" >> "$1"
  wait "$!"
' _ "$2"
SH
  chmod +x "$driver"
  echo "=== LIVE DEMO: $label ===" | tee "$log"
  echo "Mechanism: $(fm_timeout_mechanism)" | tee -a "$log"
  "$@" "$driver" "$ROOT/bin/fm-timeout-lib.sh" "$pids_file" >>"$log" 2>&1 &
  local parent=$!
  echo "Parent PID: $parent" | tee -a "$log"
  for _ in $(seq 1 100); do
    [ -s "$pids_file" ] && [ "$(wc -l < "$pids_file" | tr -d ' ')" -eq 3 ] && break
    sleep 0.02
  done
  if [ ! -s "$pids_file" ]; then
    echo "FAIL: helper never started" | tee -a "$log"
    return 1
  fi
  local shell_pid pgid helper_pid
  shell_pid=$(sed -n '1p' "$pids_file")
  pgid=$(sed -n '2p' "$pids_file")
  helper_pid=$(sed -n '3p' "$pids_file")
  echo "Recorded shell=$shell_pid pgid=$pgid helper=$helper_pid" | tee -a "$log"
  ps -o pid,ppid,pgid,sid,stat,comm -p "$shell_pid,$helper_pid" 2>/dev/null | tee -a "$log" || true
  kill -0 "$helper_pid" 2>/dev/null || { echo "FAIL: helper already dead before kill" | tee -a "$log"; return 1; }
  echo "Sending SIGKILL to parent $parent" | tee -a "$log"
  kill -KILL "$parent"
  wait "$parent" 2>/dev/null || true
  local alive=1 group_count=1
  for _ in $(seq 1 100); do
    alive=0
    while read -r pid; do
      [ -n "$pid" ] || continue
      [ "$pid" = "$pgid" ] && continue
      local stat
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
  echo "Post-kill alive=$alive group_count=$group_count" | tee -a "$log"
  ps -o pid,ppid,pgid,sid,stat,comm -p "$shell_pid,$helper_pid" 2>/dev/null | tee -a "$log" || echo "(processes gone)" | tee -a "$log"
  if [ "$alive" -eq 0 ] && [ "$group_count" -eq 0 ]; then
    echo "PASS: zero real helper descendants after abnormal parent death" | tee -a "$log"
    return 0
  fi
  echo "FAIL: survivors remain" | tee -a "$log"
  return 1
}

rc=0
run_one external-default env || rc=1
run_one pure-bash env FM_TIMEOUT_MECHANISM_OVERRIDE=bash || rc=1

# Perl path via no-timeout PATH fixture
tb=$(mktemp -d)
for tool in bash perl ps sleep kill env sed awk tr; do ln -s "$(command -v "$tool")" "$tb/$tool"; done
run_one perl-fallback env PATH="$tb" || rc=1
rm -rf "$tb"

exit $rc
