#!/usr/bin/env bash
# fm-timeout-lib.sh - the single owner of bounded command execution.
#
# Sourced, never executed. Provides one hard-bound runner so no caller has to
# re-derive the coreutils/BSD/perl selection, and so every bounded call in this
# repo agrees on what "the bound was hit" means.
#
#   fm_timeout_mechanism
#       Prints the mechanism fm_run_timed will use on this host: "timeout",
#       "gtimeout", "perl", or "bash". Set FM_TIMEOUT_MECHANISM_OVERRIDE=bash
#       to force the dependency-free fallback.
#
#   fm_run_timed <seconds> <command> [args...]
#       Runs the command with a hard bound. Exit status is the command's own,
#       except 124, which means the bound was hit (GNU timeout's convention,
#       reproduced by the perl and bash fallbacks).
#
# A non-positive bound is not a bound: `timeout 0` and the perl fallback's
# `alarm 0` both disable the deadline, so callers must reject 0 before calling.
#
# All four mechanisms terminate the whole process GROUP, not just the direct
# child, so a hung grandchild (a vendor CLI spawned by a wrapper script, a git
# fetch spawned by a sweep) cannot outlive the bound. GNU/BSD `timeout` does
# this by default because it does not run the command in the foreground process
# group; the perl fallback does it explicitly with setpgrp plus a negative pid,
# and the bash fallback uses monitor mode to give the bounded child its own
# process group before signaling its negative pid. Each bounded command also
# watches the identity of the process that owns the call and kills that group
# when the owner dies abnormally. A shell EXIT trap cannot provide that
# guarantee after SIGKILL, and process groups alone do not propagate a signal
# sent only to the owner.
set -u

fm_timeout_mechanism() {
  if [ "${FM_TIMEOUT_MECHANISM_OVERRIDE:-}" = bash ]; then
    printf 'bash\n'
  elif command -v timeout >/dev/null 2>&1; then
    printf 'timeout\n'
  elif command -v gtimeout >/dev/null 2>&1; then
    printf 'gtimeout\n'
  elif command -v perl >/dev/null 2>&1; then
    printf 'perl\n'
  else
    printf 'bash\n'
  fi
}

# The command wrapper runs inside the runner-owned process group. It keeps a
# small sentinel in that group so a SIGKILL (or container death) of the caller
# still tears down the real command and every helper it spawned. Linux process
# start time closes the PID-reuse hole; other supported platforms fall back to
# kill -0 because their process tables do not expose an equivalent portable
# identity field. The sentinel ignores TERM long enough to escalate its group
# to KILL, then exits with the rest of the group.
fm_timeout_child() {
  local owner_pid=$1 owner_start=$2 root_pid=$3 root_start=$4 status_file=$5 group watchdog_pid command_rc monitor_parent monitor_pid
  shift 5

  pid_alive() {
    local pid=$1 expected_start=$2 current_start state
    kill -0 "$pid" 2>/dev/null || return 1
    case "$expected_start" in
      '') return 0 ;;
      *)
        [ -r "/proc/$pid/stat" ] || return 1
        current_start=$(awk '{print $22}' "/proc/$pid/stat" 2>/dev/null) || return 1
        state=$(awk '{print $3}' "/proc/$pid/stat" 2>/dev/null) || return 1
        [ "$current_start" = "$expected_start" ] || return 1
        case "$state" in Z*) return 1 ;; esac
        return 0
        ;;
    esac
  }

  owner_alive() {
    pid_alive "$owner_pid" "$owner_start" || return 1
    [ "$root_pid" = "$owner_pid" ] || pid_alive "$root_pid" "$root_start"
  }

  group=$(ps -o pgid= -p "$$" 2>/dev/null | tr -d '[:space:]')
  if [ -n "$group" ] && [ "$group" != "0" ]; then
    monitor_parent=$$
    (
      trap '' HUP INT TERM
      monitor_pid=${BASHPID:-$$}
      while [ "$(ps -o ppid= -p "$monitor_pid" 2>/dev/null | tr -d '[:space:]')" = "$monitor_parent" ] && owner_alive; do
        sleep 0.05
      done
      kill -TERM -- "-$group" 2>/dev/null || true
      sleep 0.2
      kill -KILL -- "-$group" 2>/dev/null || true
    ) &
    watchdog_pid=$!
  else
    watchdog_pid=
  fi

  "$@"
  command_rc=$?
  [ -z "$watchdog_pid" ] || kill -KILL "$watchdog_pid" 2>/dev/null || true
  [ -z "$watchdog_pid" ] || wait "$watchdog_pid" 2>/dev/null || true
  printf '%s\n' "$command_rc" > "$status_file"
  return "$command_rc"
}

fm_timeout_owner_start() {
  case "$(uname -s 2>/dev/null || true)" in
    Linux)
      awk '{print $22}' "/proc/$1/stat" 2>/dev/null || true
      ;;
    *)
      printf '\n'
      ;;
  esac
}

fm_timeout_child_command() {
  # Serialize the function instead of depending on an exported function or a
  # helper file that a caller could replace while a bounded command is running.
  printf '%s\n' "$(declare -f fm_timeout_child); fm_timeout_child \"\$@\""
}

fm_run_bash_timeout() {
  local seconds=$1 command_status deadline_status child_pid watchdog_pid command_rc recorded_rc monitor_was_on=0 owner_pid owner_start root_pid root_start child_code
  shift
  command_status=$(mktemp "${TMPDIR:-/tmp}/fm-bash-timeout-command.XXXXXX" 2>/dev/null) || return 124
  deadline_status="${command_status}.deadline"
  owner_pid=${BASHPID:-$$}
  owner_start=$(fm_timeout_owner_start "$owner_pid")
  root_pid=$$
  root_start=$(fm_timeout_owner_start "$root_pid")
  child_code=$(fm_timeout_child_command)
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m
  (
    set +m
    bash -c "$child_code" _ "$owner_pid" "$owner_start" "$root_pid" "$root_start" "$command_status" "$@"
  ) &
  child_pid=$!
  (
    set +m
    sleep "$seconds"
    printf 'expired\n' > "$deadline_status"
    kill -TERM -- "-$child_pid" 2>/dev/null || true
    sleep 0.2
    kill -KILL -- "-$child_pid" 2>/dev/null || true
    exit 124
  ) &
  watchdog_pid=$!
  [ "$monitor_was_on" -eq 1 ] || set +m

  if wait "$child_pid" 2>/dev/null; then
    command_rc=0
  else
    command_rc=$?
  fi
  if [ -s "$deadline_status" ]; then
    wait "$watchdog_pid" 2>/dev/null || true
    command_rc=124
  else
    kill -TERM -- "-$watchdog_pid" 2>/dev/null || kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    recorded_rc=$(cat "$command_status" 2>/dev/null || true)
    case "$recorded_rc" in ''|*[!0-9]*) ;; *) command_rc=$recorded_rc ;; esac
  fi
  rm -f "$command_status" "$deadline_status" 2>/dev/null || true
  return "$command_rc"
}

fm_run_external_timeout() {
  local runner=$1 seconds=$2 status_file runner_pid runner_rc command_rc owner_pid owner_start root_pid root_start child_code
  shift 2
  status_file=$(mktemp "${TMPDIR:-/tmp}/fm-timeout-status.XXXXXX" 2>/dev/null) || return 124
  owner_pid=${BASHPID:-$$}
  owner_start=$(fm_timeout_owner_start "$owner_pid")
  root_pid=$$
  root_start=$(fm_timeout_owner_start "$root_pid")
  child_code=$(fm_timeout_child_command)
  # Run timeout asynchronously so its pid - also the process-group id created
  # by GNU/BSD timeout without --foreground - remains available for cleanup.
  # A shell wrapper can exit promptly on TERM while one of its descendants
  # ignores TERM; timeout then considers the command finished and does not send
  # its configured KILL. The wrapper's caller-death sentinel handles that
  # leftover group even when this parent is killed abnormally.
  "$runner" -k 1 "$seconds" bash -c "$child_code" _ "$owner_pid" "$owner_start" "$root_pid" "$root_start" "$status_file" "$@" &
  runner_pid=$!
  if wait "$runner_pid"; then
    runner_rc=0
  else
    runner_rc=$?
  fi
  command_rc=$(cat "$status_file" 2>/dev/null || true)
  rm -f "$status_file" 2>/dev/null || true
  case "$command_rc" in
    ''|*[!0-9]*) ;;
    *) [ "$command_rc" -le 255 ] && return "$command_rc" ;;
  esac
  case "$runner_rc" in
    124|137)
      kill -KILL -- "-$runner_pid" 2>/dev/null || true
      return 124
      ;;
    *) return "$runner_rc" ;;
  esac
}

fm_run_perl_timeout() {
  local seconds=$1 owner_pid owner_start root_pid root_start
  shift
  owner_pid=${BASHPID:-$$}
  owner_start=$(fm_timeout_owner_start "$owner_pid")
  root_pid=$$
  root_start=$(fm_timeout_owner_start "$root_pid")
  perl -e '
    my $seconds = shift;
    my $owner_pid = shift;
    my $owner_start = shift;
    my $root_pid = shift;
    my $root_start = shift;
    my $pid = fork;
    die "fork failed" unless defined $pid;
    if (!$pid) {
      setpgrp(0, 0);
      exec @ARGV;
      die "exec failed: $!";
    }
    my $supervisor_pid = $$;
    my $watchdog = fork;
    my $command_status;
    die "fork failed" unless defined $watchdog;
    if (!$watchdog) {
      my $pid_alive = sub {
        my ($pid, $expected_start) = @_;
        return 0 unless kill 0, $pid;
        return 1 unless length $expected_start;
        open my $stat, "<", "/proc/$pid/stat" or return 0;
        my $line = <$stat>;
        close $stat;
        return 0 unless defined $line;
        my @fields = split /\s+/, $line;
        return 0 unless defined $fields[21] && defined $fields[2];
        return $fields[21] eq $expected_start && $fields[2] !~ /^Z/;
      };
      my $owner_alive = sub {
        return 0 unless $pid_alive->($owner_pid, $owner_start);
        return 1 if $root_pid == $owner_pid;
        return $pid_alive->($root_pid, $root_start);
      };
      while (getppid() == $supervisor_pid && $owner_alive->()) {
        select undef, undef, undef, 0.05;
      }
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      kill "KILL", $supervisor_pid if getppid() == $supervisor_pid;
      exit 0;
    }
    local $SIG{ALRM} = sub {
      kill "TERM", -$pid;
      select undef, undef, undef, 0.2;
      kill "KILL", -$pid;
      kill "KILL", $watchdog;
      waitpid $pid, 0;
      waitpid $watchdog, 0;
      exit 124;
    };
    alarm $seconds;
    waitpid $pid, 0;
    $command_status = $?;
    alarm 0;
    kill "KILL", $watchdog;
    waitpid $watchdog, 0;
    exit($command_status >> 8);
  ' "$seconds" "$owner_pid" "$owner_start" "$root_pid" "$root_start" "$@"
}

fm_run_timed() {  # <seconds> <command...>
  local seconds=$1
  shift
  case "$(fm_timeout_mechanism)" in
    timeout) fm_run_external_timeout timeout "$seconds" "$@" ;;
    gtimeout) fm_run_external_timeout gtimeout "$seconds" "$@" ;;
    perl) fm_run_perl_timeout "$seconds" "$@" ;;
    bash) fm_run_bash_timeout "$seconds" "$@" ;;
    *) return 124 ;;
  esac
}
