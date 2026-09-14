#!/usr/bin/env bash
# Firstmate browser lifecycle ownership contract.
#
# This library is the only Firstmate code that records and closes browser
# resources. A task incarnation owns only the exact named
# chrome-devtools-axi bridge session it reserved, or a direct process group
# started through fm-browser-lifecycle.sh. It never discovers ownership from
# ancestry, parentlessness, a cwd, or elapsed time.
#
# The chrome-devtools-axi bridge remains the owner of its Chrome/MCP children.
# Firstmate proves the session record and bridge PID identity, then delegates
# shutdown to `chrome-devtools-axi stop`; it never signals a Chrome PID.
# Direct Playwright/Puppeteer commands are owned only when this wrapper creates
# their own process group and records the leader identity before waiting.

fm_browser_lifecycle_error() {  # <message>
  echo "browser lifecycle: $1" >&2
  return 1
}

fm_browser_validate_atom() {  # <value>
  case "${1:-}" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  return 0
}

fm_browser_validate_task_id() {  # <task-id>
  local value=${1:-}
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#value}" -le 64 ]
}

fm_browser_validate_session() {  # <session>
  local value=${1:-}
  [ "$value" = default ] && return 0
  case "$value" in
    ''|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
  [ "${#value}" -le 64 ] || return 1
  case "$value" in
    .* )
      case "$value" in
        *[!.]*) ;;
        *) return 1 ;;
      esac
      ;;
  esac
  return 0
}

fm_browser_validate_generation() {  # <spawn-generation>
  fm_browser_validate_atom "$1" && [ "${#1}" -le 128 ]
}

fm_browser_state_namespace() {  # <state>
  local state=$1 resolved
  [ -d "$state" ] && [ ! -L "$state" ] || return 1
  resolved=$(cd "$state" && pwd -P) || return 1
  printf '%s' "$resolved" | cksum | awk '{print $1}'
}

fm_browser_session_for_task() {  # <state> <task-id> [logical-session]
  local state=$1 task=$2 logical=${3:-default} namespace checksum prefix
  fm_browser_validate_task_id "$task" && fm_browser_validate_session "$logical" || return 1
  namespace=$(fm_browser_state_namespace "$state") || return 1
  checksum=$(printf '%s\0%s' "$task" "$logical" | cksum | awk '{print $1}')
  prefix=${task:0:32}
  printf 'fm-%s-%s-%s\n' "$namespace" "$prefix" "$checksum"
}

fm_browser_owner_dir() {  # <state> <task-id>
  fm_browser_validate_task_id "$2" || return 1
  printf '%s/%s.browser' "$1" "$2"
}

fm_browser_lock_dir() {  # <state> <task-id>
  fm_browser_validate_task_id "$2" || return 1
  printf '%s/.browser-lifecycle-%s.lock' "$1" "$2"
}

fm_browser_cleanup_notification_path() {  # <state> <task-id>
  fm_browser_validate_task_id "$2" || return 1
  printf '%s/.browser-cleanup-notified-%s' "$1" "$2"
}

fm_browser_process_identity() {  # <pid>
  local pid=$1 proc_root stat_line starttime value
  local -a stat_fields
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  proc_root=${FM_PROC_ROOT_OVERRIDE:-/proc}
  if [ -r "$proc_root/$pid/stat" ]; then
    stat_line=$(command cat "$proc_root/$pid/stat" 2>/dev/null) || return 1
    read -r -a stat_fields <<< "${stat_line##*)}"
    [ "${#stat_fields[@]}" -ge 20 ] || return 1
    starttime=${stat_fields[19]}
    case "$starttime" in ''|*[!0-9]*) return 1 ;; esac
    printf 'starttime=%s\n' "$starttime"
    return 0
  fi
  value=$(LC_ALL=C ps -p "$pid" -o lstart= 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | awk '{$1=$1; print}')
  [ -n "$value" ] || return 1
  case "$value" in *$'\n'*|*$'\r'*) return 1 ;; esac
  printf 'lstart=%s\n' "$value"
}

fm_browser_process_identity_matches() {  # <pid> <identity>
  local current
  current=$(fm_browser_process_identity "$1") || return 1
  [ "$current" = "$2" ]
}

fm_browser_process_command() {  # <pid>
  local pid=$1 command
  command=$(LC_ALL=C ps -p "$pid" -o command= 2>/dev/null) || return 1
  command=$(printf '%s' "$command" | tr '\n\r' '  ' | awk '{$1=$1; print}')
  [ -n "$command" ] || return 1
  printf '%s\n' "$command"
}

fm_browser_process_pgid() {  # <pid>
  local value
  value=$(ps -o pgid= -p "$1" 2>/dev/null) || return 1
  value=$(printf '%s' "$value" | tr -d '[:space:]')
  case "$value" in ''|*[!0-9]*) return 1 ;; esac
  printf '%s\n' "$value"
}

fm_browser_process_group_probe() {  # <pgid>; 0 browser, 1 none, 2 unknown
  local pgid=$1 listing pid member_pgid probe
  listing=$(ps -eo pid=,pgid= 2>/dev/null) || return 2
  while read -r pid member_pgid; do
    [ "$member_pgid" = "$pgid" ] || continue
    case "$pid" in ''|*[!0-9]*) return 2 ;; esac
    if fm_browser_process_is_browser_like "$pid"; then
      return 0
    else
      probe=$?
      [ "$probe" -eq 1 ] || return 2
    fi
  done <<EOF
$listing
EOF
  return 1
}

fm_browser_axi_state_dir() {  # <session>
  local session=$1 home=${HOME:-}
  fm_browser_validate_session "$session" || return 1
  [ -n "$home" ] || return 1
  if [ "$session" = default ]; then
    printf '%s/.chrome-devtools-axi\n' "$home"
  else
    printf '%s/.chrome-devtools-axi/sessions/%s\n' "$home" "$session"
  fi
}

fm_browser_axi_pid_file() {  # <session>
  printf '%s/bridge.pid\n' "$(fm_browser_axi_state_dir "$1")"
}

fm_browser_axi_pid_value() {  # <session>
  local pid_file
  pid_file=$(fm_browser_axi_pid_file "$1") || return 1
  [ -f "$pid_file" ] && [ ! -L "$pid_file" ] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  jq -er '.pid | numbers' "$pid_file" 2>/dev/null
}

# Prints absent, dead, alive-bridge, alive-foreign, or malformed. A live PID
# is useful only after its command identity is checked; a PID file alone is
# never ownership authority.
fm_browser_axi_pid_state() {  # <session>
  local session=$1 pid_file pid command
  pid_file=$(fm_browser_axi_pid_file "$session") || { printf malformed; return 0; }
  if [ -L "$pid_file" ]; then
    printf malformed
    return 0
  fi
  [ -e "$pid_file" ] || { printf absent; return 0; }
  [ -f "$pid_file" ] || { printf malformed; return 0; }
  command -v jq >/dev/null 2>&1 || { printf malformed; return 0; }
  pid=$(fm_browser_axi_pid_value "$session" 2>/dev/null || true)
  [ -n "$pid" ] || { printf malformed; return 0; }
  case "$pid" in ''|*[!0-9]*|0) printf malformed; return 0 ;; esac
  if ! kill -0 "$pid" 2>/dev/null; then
    printf dead
    return 0
  fi
  command=$(fm_browser_process_command "$pid" 2>/dev/null || true)
  case "${command,,}" in
    *chrome-devtools-axi-bridge*) printf alive-bridge ;;
    *) printf alive-foreign ;;
  esac
}

fm_browser_record_field() {  # <record> <field>
  local record=$1 field=$2
  [ -f "$record" ] && [ ! -L "$record" ] || return 1
  awk -F= -v key="$field" '$1 == key { value=$0; sub(/^[^=]*=/, "", value); print value; found=1 } END { if (!found) exit 1 }' "$record"
}

fm_browser_atomic_record() {  # <path> <lines...>
  local path=$1 tmp line
  shift
  tmp="${path%/*}/.browser-record-tmp.${BASHPID:-$$}.$RANDOM"
  {
    for line in "$@"; do
      printf '%s\n' "$line"
    done
  } > "$tmp" || { rm -f "$tmp"; return 1; }
  chmod 600 "$tmp" 2>/dev/null || true
  mv -f -- "$tmp" "$path" || { rm -f "$tmp"; return 1; }
}

fm_browser_lock_take() {  # <state> <task-id>
  local state=$1 task=$2 lock pid identity current
  lock=$(fm_browser_lock_dir "$state" "$task") || return 1
  mkdir -p "$state" || return 1
  if [ -e "$lock" ] || [ -L "$lock" ]; then
    [ -d "$lock" ] && [ ! -L "$lock" ] || return 1
    pid=$(fm_browser_record_field "$lock/owner-pid" pid 2>/dev/null || true)
    identity=$(fm_browser_record_field "$lock/owner-pid" identity 2>/dev/null || true)
    case "$pid" in ''|*[!0-9]*) return 1 ;; esac
    [ -n "$identity" ] || return 1
    current=$(fm_browser_process_identity "$pid" 2>/dev/null || true)
    if [ "$current" = "$identity" ]; then
      return 1
    fi
    # The recorded owner identity changed or disappeared. That is the only
    # stale-lock recovery permitted; age and parentlessness are not evidence.
    rm -rf -- "$lock" || return 1
  fi
  mkdir "$lock" 2>/dev/null || return 1
  identity=$(fm_browser_process_identity "$$" 2>/dev/null || true)
  [ -n "$identity" ] || { rmdir "$lock" 2>/dev/null || true; return 1; }
  fm_browser_atomic_record "$lock/owner-pid" "pid=$$" "identity=$identity" || {
    rm -rf -- "$lock"
    return 1
  }
  chmod 700 "$lock" 2>/dev/null || true
}

fm_browser_lock_release() {  # <state> <task-id>
  local lock=$1 pid identity current
  # Callers pass the constructed lock path to avoid deriving it from mutable
  # state while releasing.
  [ -d "$lock" ] && [ ! -L "$lock" ] || return 0
  pid=$(fm_browser_record_field "$lock/owner-pid" pid 2>/dev/null || true)
  identity=$(fm_browser_record_field "$lock/owner-pid" identity 2>/dev/null || true)
  [ "$pid" = "$$" ] && [ -n "$identity" ] || return 0
  current=$(fm_browser_process_identity "$$" 2>/dev/null || true)
  [ "$current" = "$identity" ] || return 0
  rm -rf -- "$lock"
}

fm_browser_session_claimed() {  # <state> <session> <owner-dir>
  local state=$1 session=$2 own=$3 dir resource found
  for dir in "$state"/*.browser; do
    [ -d "$dir" ] && [ ! -L "$dir" ] || continue
    [ "$dir" = "$own" ] && continue
    for resource in "$dir"/axi.*; do
      [ -f "$resource" ] && [ ! -L "$resource" ] || continue
      found=$(fm_browser_record_field "$resource" session 2>/dev/null || true)
      if [ "$found" = "$session" ]; then
        return 0
      fi
    done
  done
  return 1
}

fm_browser_owner_matches() {  # <dir> <task-id> <generation>
  local dir=$1 task=$2 generation=$3 owner owner_task owner_gen
  owner="$dir/owner"
  [ -f "$owner" ] && [ ! -L "$owner" ] || return 1
  owner_task=$(fm_browser_record_field "$owner" task_id 2>/dev/null || true)
  owner_gen=$(fm_browser_record_field "$owner" spawn_gen 2>/dev/null || true)
  [ "$owner_task" = "$task" ] && [ "$owner_gen" = "$generation" ]
}

fm_browser_owner_arm() {  # <state> <task-id> <generation>; prints default session
  local state=$1 task=$2 generation=$3 dir lock default_session pid_state
  fm_browser_validate_task_id "$task" || return 1
  fm_browser_validate_generation "$generation" || return 1
  dir=$(fm_browser_owner_dir "$state" "$task") || return 1
  lock=$(fm_browser_lock_dir "$state" "$task") || return 1
  fm_browser_lock_take "$state" "$task" || {
    fm_browser_lifecycle_error "could not reserve task $task's browser ownership record"
    return 1
  }
  if [ -e "$dir" ] || [ -L "$dir" ]; then
    [ -d "$dir" ] && [ ! -L "$dir" ] || {
      fm_browser_lock_release "$lock"
      fm_browser_lifecycle_error "task $task has an unsafe browser ownership path"
      return 1
    }
    if ! fm_browser_owner_matches "$dir" "$task" "$generation"; then
      fm_browser_lock_release "$lock"
      fm_browser_lifecycle_error "task $task already has a different browser incarnation or an unrecognized ownership record"
      return 1
    fi
    default_session=$(fm_browser_record_field "$dir/owner" default_session 2>/dev/null || true)
    fm_browser_validate_session "$default_session" || {
      fm_browser_lock_release "$lock"
      fm_browser_lifecycle_error "task $task's browser ownership record has an invalid session"
      return 1
    }
    fm_browser_lock_release "$lock"
    printf '%s\n' "$default_session"
    return 0
  fi
  default_session=$(fm_browser_session_for_task "$state" "$task") || {
    fm_browser_lock_release "$lock"
    return 1
  }
  if fm_browser_session_claimed "$state" "$default_session" "$dir"; then
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "browser session $default_session is already reserved by another task"
    return 1
  fi
  pid_state=$(fm_browser_axi_pid_state "$default_session")
  case "$pid_state" in
    absent|dead) ;;
    alive-bridge|alive-foreign)
      fm_browser_lock_release "$lock"
      fm_browser_lifecycle_error "browser session $default_session is already active; refusing to adopt it"
      return 1
      ;;
    *)
      fm_browser_lock_release "$lock"
      fm_browser_lifecycle_error "browser session $default_session has an unreadable PID record; refusing to adopt it"
      return 1
      ;;
  esac
  mkdir "$dir" || { fm_browser_lock_release "$lock"; return 1; }
  chmod 700 "$dir" 2>/dev/null || true
  fm_browser_atomic_record "$dir/owner" \
    "version=1" "task_id=$task" "spawn_gen=$generation" \
    "default_session=$default_session" || {
      rm -rf -- "$dir"
      fm_browser_lock_release "$lock"
      return 1
    }
  fm_browser_atomic_record "$dir/axi.$default_session" \
    "version=1" "kind=axi" "task_id=$task" "spawn_gen=$generation" \
    "session=$default_session" || {
      rm -rf -- "$dir"
      fm_browser_lock_release "$lock"
      return 1
    }
  fm_browser_lock_release "$lock"
  printf '%s\n' "$default_session"
}

fm_browser_owner_register_axi() {  # <state> <task-id> <generation> <session>
  local state=$1 task=$2 generation=$3 session=$4 dir lock resource pid_state
  fm_browser_validate_task_id "$task" \
    && fm_browser_validate_generation "$generation" \
    && fm_browser_validate_session "$session" || return 1
  dir=$(fm_browser_owner_dir "$state" "$task") || return 1
  lock=$(fm_browser_lock_dir "$state" "$task") || return 1
  fm_browser_lock_take "$state" "$task" || return 1
  fm_browser_owner_matches "$dir" "$task" "$generation" || {
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "task $task has no matching browser owner for session $session"
    return 1
  }
  resource="$dir/axi.$session"
  if [ -e "$resource" ] || [ -L "$resource" ]; then
    if [ -f "$resource" ] && [ ! -L "$resource" ] \
       && [ "$(fm_browser_record_field "$resource" task_id 2>/dev/null || true)" = "$task" ] \
       && [ "$(fm_browser_record_field "$resource" spawn_gen 2>/dev/null || true)" = "$generation" ]; then
      fm_browser_lock_release "$lock"
      return 0
    fi
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "browser session $session has an unrecognized ownership record"
    return 1
  fi
  if fm_browser_session_claimed "$state" "$session" "$dir"; then
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "browser session $session is already reserved by another task"
    return 1
  fi
  pid_state=$(fm_browser_axi_pid_state "$session")
  case "$pid_state" in
    absent|dead) ;;
    alive-bridge|alive-foreign)
      fm_browser_lock_release "$lock"
      fm_browser_lifecycle_error "browser session $session is already active; refusing to adopt it"
      return 1
      ;;
    *)
      fm_browser_lock_release "$lock"
      fm_browser_lifecycle_error "browser session $session has an unreadable PID record; refusing to adopt it"
      return 1
      ;;
  esac
  fm_browser_atomic_record "$resource" \
    "version=1" "kind=axi" "task_id=$task" "spawn_gen=$generation" \
    "session=$session" || {
      fm_browser_lock_release "$lock"
      return 1
    }
  fm_browser_lock_release "$lock"
}

fm_browser_direct_record_path() {  # <dir> <pid>
  printf '%s/process.%s\n' "$1" "$2"
}

fm_browser_direct_record_remove() {  # <record>
  local record=$1 dir status_file
  dir=${record%/*}
  status_file=$(fm_browser_record_field "$record" status_file 2>/dev/null || true)
  case "$status_file" in
    "$dir"/.direct-status.*) rm -f -- "$status_file" "$status_file.stop" ;;
  esac
  rm -f -- "$record"
}

fm_browser_direct_process_matches() {  # <record>
  local record=$1 pid identity pgid current_pgid
  pid=$(fm_browser_record_field "$record" pid 2>/dev/null || true)
  identity=$(fm_browser_record_field "$record" identity 2>/dev/null || true)
  pgid=$(fm_browser_record_field "$record" pgid 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$pgid" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$identity" ] || return 1
  fm_browser_process_identity_matches "$pid" "$identity" || return 1
  current_pgid=$(fm_browser_process_pgid "$pid" 2>/dev/null || true)
  [ "$current_pgid" = "$pgid" ]
}

fm_browser_stop_direct_record() {  # <record>; exact process-group proof is required
  local record=$1 pid pgid identity current_pgid i
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  pid=$(fm_browser_record_field "$record" pid 2>/dev/null || true)
  identity=$(fm_browser_record_field "$record" identity 2>/dev/null || true)
  pgid=$(fm_browser_record_field "$record" pgid 2>/dev/null || true)
  case "$pid" in ''|*[!0-9]*|0) return 1 ;; esac
  case "$pgid" in ''|*[!0-9]*|0) return 1 ;; esac
  [ -n "$identity" ] || return 1
  if ! fm_browser_direct_process_matches "$record"; then
    if ! kill -0 "$pid" 2>/dev/null && ! kill -0 -- "-$pgid" 2>/dev/null; then
      fm_browser_direct_record_remove "$record"
      return 0
    fi
    # The supervisor's identity is gone. Allow its already-signaled children a
    # bounded grace period, but never signal a surviving group whose leader
    # identity is no longer available as ownership proof.
    i=0
    while kill -0 -- "-$pgid" 2>/dev/null && [ "$i" -lt 20 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    if ! kill -0 -- "-$pgid" 2>/dev/null; then
      fm_browser_direct_record_remove "$record"
      return 0
    fi
    return 1
  fi
  kill -TERM -- "-$pgid" 2>/dev/null || true
  i=0
  while [ "$i" -lt 20 ]; do
    if ! fm_browser_direct_process_matches "$record"; then
      if kill -0 -- "-$pgid" 2>/dev/null; then
        # A child survived after its exact leader vanished. Preserve it rather
        # than guessing that process-group membership still means ownership.
        return 1
      fi
      fm_browser_direct_record_remove "$record"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  if fm_browser_direct_process_matches "$record"; then
    current_pgid=$(fm_browser_process_pgid "$pid" 2>/dev/null || true)
    [ "$current_pgid" = "$pgid" ] || return 1
    kill -KILL -- "-$pgid" 2>/dev/null || true
  fi
  i=0
  while [ "$i" -lt 10 ]; do
    if ! fm_browser_direct_process_matches "$record"; then
      if kill -0 -- "-$pgid" 2>/dev/null; then return 1; fi
      fm_browser_direct_record_remove "$record"
      return 0
    fi
    sleep 0.1
    i=$((i + 1))
  done
  return 1
}

fm_browser_direct_graceful_close() {  # <record>; child has already completed
  local record=$1 status_file stop_file i=0 pgid
  status_file=$(fm_browser_record_field "$record" status_file 2>/dev/null || true)
  [ -n "$status_file" ] || return 1
  stop_file="$status_file.stop"
  : > "$stop_file" || return 1
  while [ "$i" -lt 20 ]; do
    if ! fm_browser_direct_process_matches "$record"; then
      pgid=$(fm_browser_record_field "$record" pgid 2>/dev/null || true)
      if ! kill -0 -- "-$pgid" 2>/dev/null; then
        fm_browser_direct_record_remove "$record"
        return 0
      fi
      return 1
    fi
    sleep 0.1
    i=$((i + 1))
  done
  # A supervisor that ignored its graceful close is still ours only while its
  # original identity matches, so the normal exact-group finalizer may escalate.
  fm_browser_stop_direct_record "$record"
}

fm_browser_direct_launch() {  # <state> <task-id> <generation> [--timeout seconds] -- <command...>
  local state=$1 task=$2 generation=$3 timeout=0 start now pid identity pgid dir lock record rc timed=0
  local status_file result child_done=0
  shift 3
  if [ "${1:-}" = --timeout ]; then
    timeout=${2:-}
    case "$timeout" in ''|*[!0-9]*|0) fm_browser_lifecycle_error "direct browser timeout must be a positive integer"; return 2 ;; esac
    shift 2
  fi
  [ "${1:-}" = -- ] || { fm_browser_lifecycle_error "direct browser launch requires -- before the command"; return 2; }
  shift
  [ "$#" -gt 0 ] || { fm_browser_lifecycle_error "direct browser launch command is empty"; return 2; }
  dir=$(fm_browser_owner_dir "$state" "$task") || return 1
  lock=$(fm_browser_lock_dir "$state" "$task") || return 1
  fm_browser_owner_matches "$dir" "$task" "$generation" || {
    fm_browser_lifecycle_error "direct browser launch has no matching task owner"
    return 1
  }
  command -v setsid >/dev/null 2>&1 || {
    fm_browser_lifecycle_error "setsid is unavailable; refusing an untracked direct browser launch"
    return 1
  }
  status_file="$dir/.direct-status.${BASHPID:-$$}.$RANDOM"
  fm_browser_atomic_record "$status_file" \
    "version=1" "task_id=$task" "spawn_gen=$generation" || return 1
  # Keep a supervisor as the exact process-group leader until the caller has
  # observed the direct command's result and retired the group. This preserves
  # an identity proof even when a Playwright/Puppeteer command exits before its
  # browser child does.
  # shellcheck disable=SC2016 # The supervisor script expands its own positional parameters.
  setsid bash -c '
    status=$1
    shift
    # The supervisor stays alive as the recorded group leader. A lifecycle
    # finalizer may therefore escalate only while this exact identity remains
    # valid, instead of losing the proof when TERM reaches the leader first.
    # Install the supervisor-only trap after launching the direct command so
    # its browser children retain normal TERM handling.
    "$@" &
    child=$!
    trap : TERM INT HUP
    if wait "$child"; then rc=0; else rc=$?; fi
    printf "result=%s\\n" "$rc" >> "$status"
    while [ ! -e "$status.stop" ]; do sleep 1; done
    # Retire every other member of this wrapper-created group, including a
    # browser child that outlived the Playwright/Puppeteer command. The group
    # leader remains until the list is empty, preserving the identity proof.
    passes=0
    while :; do
      ps_output=$(ps -eo pid=,pgid= 2>/dev/null) || { sleep 0.1; continue; }
      members=$(printf "%s\\n" "$ps_output" | awk -v group="$$" "\$2 == group {print \$1}")
      found=0
      while IFS= read -r member; do
        case "$member" in ""|"$$") continue ;; esac
        found=1
        kill -TERM "$member" 2>/dev/null || true
      done <<EOF
$members
EOF
      if [ "$found" = 0 ]; then exit 0; fi
      passes=$((passes + 1))
      if [ "$passes" -ge 20 ]; then
        while IFS= read -r member; do
          case "$member" in ""|"$$") continue ;; esac
          kill -KILL "$member" 2>/dev/null || true
        done <<EOF
$members
EOF
      fi
      sleep 0.1
    done
  ' fm-browser-supervisor "$status_file" "$@" &
  pid=$!
  identity=$(fm_browser_process_identity "$pid" 2>/dev/null || true)
  pgid=$(fm_browser_process_pgid "$pid" 2>/dev/null || true)
  if [ -z "$identity" ] || [ "$pgid" != "$pid" ]; then
    if kill -0 "$pid" 2>/dev/null; then
      fm_browser_lifecycle_error "could not prove the direct browser process group for pid $pid; preserving it for inspection"
      return 1
    fi
    if wait "$pid"; then return 0; else return $?; fi
  fi
  record=$(fm_browser_direct_record_path "$dir" "$pid")
  if [ -e "$record" ] || [ -L "$record" ] || ! fm_browser_lock_take "$state" "$task"; then
    fm_browser_lifecycle_error "could not reserve the direct browser process record for pid $pid"
    return 1
  fi
  if ! fm_browser_atomic_record "$record" \
      "version=1" "kind=direct" "task_id=$task" "spawn_gen=$generation" \
      "pid=$pid" "identity=$identity" "pgid=$pgid" "status_file=$status_file"; then
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "could not persist direct browser ownership for pid $pid"
    return 1
  fi
  fm_browser_lock_release "$lock"
  start=$(date +%s)
  while :; do
    [ -e "$record" ] || { wait "$pid" 2>/dev/null || true; return 143; }
    result=$(fm_browser_record_field "$status_file" result 2>/dev/null || true)
    if ! kill -0 "$pid" 2>/dev/null; then
      fm_browser_stop_direct_record "$record" || {
        fm_browser_lifecycle_error "direct browser supervisor pid $pid exited without a clean result and its exact group could not be retired"
        return 1
      }
      wait "$pid" 2>/dev/null || true
      return 1
    fi
    case "$result" in
      ''|*[!0-9]*) ;;
      *) child_done=1; break ;;
    esac
    if [ "$timeout" -gt 0 ]; then
      now=$(date +%s)
      if [ $((now - start)) -ge "$timeout" ]; then
        timed=1
        fm_browser_stop_direct_record "$record" || {
          fm_browser_lifecycle_error "timed-out direct browser pid $pid could not be stopped from its proven process group"
          return 1
        }
        break
      fi
    fi
    sleep 0.1
  done
  if [ "$timed" = 1 ]; then
    rc=124
  else
    rc=$result
  fi
  if [ "$child_done" = 1 ] && [ -e "$record" ]; then
    fm_browser_direct_graceful_close "$record" || {
      fm_browser_lifecycle_error "direct browser pid $pid exited but its exact owned process group could not be retired"
      return 1
    }
  fi
  wait "$pid" 2>/dev/null || true
  return "$rc"
}

fm_browser_stop_axi_record() {  # <record>; bridge stop is the only Chrome cleanup
  local record=$1 session pid_file state cli bridge_pid bridge_identity current_pid current_identity
  [ -f "$record" ] && [ ! -L "$record" ] || return 0
  session=$(fm_browser_record_field "$record" session 2>/dev/null || true)
  fm_browser_validate_session "$session" || return 1
  pid_file=$(fm_browser_axi_pid_file "$session") || return 1
  state=$(fm_browser_axi_pid_state "$session")
  case "$state" in
    absent)
      return 0
      ;;
    dead)
      # Leave the tool's stale handle in place. The next exact session start
      # can prove the PID is dead and let chrome-devtools-axi replace it; Firstmate
      # must not unlink a path that could be replaced by another bridge.
      return 0
      ;;
    alive-foreign)
      fm_browser_lifecycle_error "browser session $session has a live non-bridge PID; preserving it"
      return 1
      ;;
    malformed)
      fm_browser_lifecycle_error "browser session $session has an unreadable PID record; preserving it"
      return 1
      ;;
    alive-bridge)
      bridge_pid=$(fm_browser_axi_pid_value "$session" 2>/dev/null || true)
      bridge_identity=$(fm_browser_process_identity "$bridge_pid" 2>/dev/null || true)
      current_pid=$(fm_browser_axi_pid_value "$session" 2>/dev/null || true)
      current_identity=$(fm_browser_process_identity "$current_pid" 2>/dev/null || true)
      [ -n "$bridge_pid" ] && [ "$bridge_pid" = "$current_pid" ] \
        && [ -n "$bridge_identity" ] && [ "$bridge_identity" = "$current_identity" ] \
        && [ "$(fm_browser_process_command "$current_pid" 2>/dev/null || true)" = "$(fm_browser_process_command "$bridge_pid" 2>/dev/null || true)" ] || {
        fm_browser_lifecycle_error "browser session $session changed while proving its bridge ownership; preserving it"
        return 1
      }
      cli=$(command -v chrome-devtools-axi 2>/dev/null || true)
      [ -n "$cli" ] || {
        fm_browser_lifecycle_error "chrome-devtools-axi is unavailable to stop owned session $session"
        return 1
      }
      CHROME_DEVTOOLS_AXI_SESSION=$session "$cli" stop >/dev/null 2>&1 || {
        fm_browser_lifecycle_error "chrome-devtools-axi could not stop owned session $session"
        return 1
      }
      case "$(fm_browser_axi_pid_state "$session")" in
        absent|dead) return 0 ;;
        *) fm_browser_lifecycle_error "owned browser session $session remained active after chrome-devtools-axi stop"; return 1 ;;
      esac
      ;;
    *) return 1 ;;
  esac
}

fm_browser_owner_finalize() {  # <state> <task-id> <generation> <reason>
  local state=$1 task=$2 generation=$3 reason=${4:-lifecycle} dir lock entry entry_task entry_gen rc=0
  fm_browser_validate_task_id "$task" \
    && fm_browser_validate_generation "$generation" || return 1
  dir=$(fm_browser_owner_dir "$state" "$task") || return 1
  [ -e "$dir" ] || return 0
  [ -d "$dir" ] && [ ! -L "$dir" ] || {
    fm_browser_lifecycle_error "task $task has an unsafe browser ownership path"
    return 1
  }
  lock=$(fm_browser_lock_dir "$state" "$task") || return 1
  fm_browser_lock_take "$state" "$task" || {
    fm_browser_lifecycle_error "could not reserve task $task's browser cleanup"
    return 1
  }
  if ! fm_browser_owner_matches "$dir" "$task" "$generation"; then
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "browser cleanup for task $task does not match its active incarnation"
    return 1
  fi
  # Preflight all known records before the first stop. Unknown files are kept
  # as evidence instead of allowing a partial cleanup to erase ownership proof.
  for entry in "$dir"/*; do
    [ -e "$entry" ] || continue
    [ -f "$entry" ] && [ ! -L "$entry" ] || { rc=1; break; }
    case "$(basename "$entry")" in
      owner|axi.*|process.*) ;;
      *) rc=1; break ;;
    esac
    entry_task=$(fm_browser_record_field "$entry" task_id 2>/dev/null || true)
    entry_gen=$(fm_browser_record_field "$entry" spawn_gen 2>/dev/null || true)
    [ "$entry_task" = "$task" ] && [ "$entry_gen" = "$generation" ] || { rc=1; break; }
  done
  for entry in "$dir"/.[!.]*; do
    [ -e "$entry" ] || continue
    case "$(basename "$entry")" in
      .direct-status.*) ;;
      *) rc=1; break ;;
    esac
    entry_task=$(fm_browser_record_field "$entry" task_id 2>/dev/null || true)
    entry_gen=$(fm_browser_record_field "$entry" spawn_gen 2>/dev/null || true)
    [ "$entry_task" = "$task" ] && [ "$entry_gen" = "$generation" ] || { rc=1; break; }
  done
  if [ "$rc" -ne 0 ]; then
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "browser cleanup for task $task found an unrecognized or mismatched ownership record"
    return 1
  fi
  for entry in "$dir"/axi.*; do
    [ -e "$entry" ] || continue
    fm_browser_stop_axi_record "$entry" || rc=1
  done
  for entry in "$dir"/process.*; do
    [ -e "$entry" ] || continue
    fm_browser_stop_direct_record "$entry" || rc=1
  done
  if [ "$rc" -ne 0 ]; then
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "browser cleanup for task $task could not prove every owned resource stopped (reason=$reason)"
    return 1
  fi
  rm -f -- "$dir"/axi.* "$dir"/process.* "$dir"/.direct-status.* "$dir/owner"
  rmdir "$dir" 2>/dev/null || {
    fm_browser_lock_release "$lock"
    fm_browser_lifecycle_error "browser cleanup for task $task left unexpected ownership evidence"
    return 1
  }
  rm -f -- "$(fm_browser_cleanup_notification_path "$state" "$task")"
  fm_browser_lock_release "$lock"
}

fm_browser_finalize_meta() {  # <state> <meta> <task-id> <reason>
  local state=$1 meta=$2 task=$3 reason=${4:-lifecycle} generation dir
  dir=$(fm_browser_owner_dir "$state" "$task") || return 1
  if [ ! -e "$dir" ]; then return 0; fi
  generation=$(fm_browser_record_field "$meta" spawn_gen 2>/dev/null || true)
  if [ -z "$generation" ]; then
    fm_browser_lifecycle_error "task $task has browser ownership but no spawn generation in its durable record"
    return 1
  fi
  fm_browser_owner_finalize "$state" "$task" "$generation" "$reason"
}

fm_browser_worker_run() {  # <state> <task-id> <generation> -- <command...>
  local state=$1 task=$2 generation=$3 rc cleaned=0
  shift 3
  [ "${1:-}" = -- ] || return 2
  shift
  [ "$#" -gt 0 ] || return 2
  fm_browser_worker_run_cleanup() {
    [ "$cleaned" = 1 ] || fm_browser_owner_finalize "$state" "$task" "$generation" worker-exit
  }
  trap 'fm_browser_worker_run_cleanup >/dev/null 2>&1 || true' EXIT HUP INT TERM
  "$@"
  rc=$?
  fm_browser_owner_finalize "$state" "$task" "$generation" worker-exit || return 1
  cleaned=1
  trap - EXIT HUP INT TERM
  return "$rc"
}

# Detection only. Teardown uses this to refuse its generic cwd/process-group
# reaper when a browser-like process is not covered by an exact owner record.
fm_browser_process_is_browser_like() {  # <pid>
  local command lower
  command=$(fm_browser_process_command "$1" 2>/dev/null) || return 2
  [ -n "$command" ] || return 2
  lower=${command,,}
  case "$lower" in
    *chrome-devtools-axi*|*chrome-devtools-mcp*|*chrome*|*chromium*|*firefox*|*webkit*|*geckodriver*|*msedge*|*playwright*|*puppeteer*) return 0 ;;
    *) return 1 ;;
  esac
}

fm_browser_axi_exec() {  # [--session <name>] -- <chrome-devtools-axi args...>
  local state=${FM_BROWSER_STATE:-} task=${FM_BROWSER_TASK_ID:-} generation=${FM_BROWSER_SPAWN_GEN:-}
  local logical_session=${FM_BROWSER_SESSION:-default} session cli
  if [ "${1:-}" = --session ]; then
    logical_session=${2:-}
    shift 2
  fi
  [ "${1:-}" = -- ] || { fm_browser_lifecycle_error "axi wrapper requires -- before chrome-devtools-axi arguments"; return 2; }
  shift
  [ "$#" -gt 0 ] || { fm_browser_lifecycle_error "axi wrapper command is empty"; return 2; }
  [ -n "$state" ] && [ -n "$task" ] && [ -n "$generation" ] || {
    fm_browser_lifecycle_error "axi wrapper requires the task lifecycle environment from fm-spawn"
    return 1
  }
  fm_browser_validate_session "$logical_session" || {
    fm_browser_lifecycle_error "axi wrapper received an invalid logical session"
    return 1
  }
  session=$(fm_browser_session_for_task "$state" "$task" "$logical_session") || return 1
  cli=$(command -v chrome-devtools-axi 2>/dev/null || true)
  [ -n "$cli" ] || { fm_browser_lifecycle_error "chrome-devtools-axi is unavailable"; return 1; }
  fm_browser_owner_register_axi "$state" "$task" "$generation" "$session" || return 1
  export CHROME_DEVTOOLS_AXI_SESSION=$session
  exec "$cli" "$@"
}
