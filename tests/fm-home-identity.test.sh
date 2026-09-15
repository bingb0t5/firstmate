#!/usr/bin/env bash
# Behavior tests for the cross-home refusal (bin/fm-home-identity-lib.sh).
#
# FM_HOME selects which home's data/, state/, config/, and projects/ a command
# operates on. A secondmate process whose FM_HOME points at ANOTHER home used to
# operate on that home with full authority: a secondmate spawned a worker into
# the primary home, and a secondmate's memory sweep read and rewrote the primary
# home's captain and learning records. fm-spawn's primary-only domain-mate check
# did not stop the first, because it inspects $FM_HOME - the very value that was
# wrong - rather than the running process.
#
# The refusal fails closed on either of two independent signals:
#   1. code-root     : the home whose bin/ is executing is a SECONDMATE whose
#                      identity differs from the selected FM_HOME's identity.
#                      This is the only signal that covers a SIBLING mate.
#   2. launch-binding: FM_PUBLIC_FOLLOWUP_PRIMARY_HOME (stamped by fm-spawn into
#                      every secondmate agent session) names the PRIMARY home
#                      when it invokes the PRIMARY home's own bin by absolute
#                      path, where signal 1 sees a primary code root.
#
# The refusal is one-way on purpose: a PRIMARY home reaching a mate it owns (the
# fm-stow-cascade shape) must keep working, and each home operating on itself
# must keep working. Both directions are asserted here for every guarded
# interface - fm-spawn, fm-send, fm-startup-memory-budget, fm-stow-cascade.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP=$(fm_test_tmproot fm-home-identity)
TMP=$(cd "$TMP" && pwd -P)

REFUSE_EXIT=4
CROSS_MSG='refuses a cross-home operation'

PRIMARY="$TMP/primary"
MATE="$TMP/mate"
SIBLING="$TMP/sibling"
REGISTRY="$PRIMARY/data/secondmates.md"

# make_home <path> [<mate-id>]: a firstmate home with its OWN bin/, so the
# executing code root is that home rather than the repo under test. A mate id
# also writes the durable parent binding, exactly as bin/fm-home-seed.sh does.
make_home() {
  local home=$1 id=${2:-}
  mkdir -p "$home/data" "$home/state" "$home/config" "$home/projects"
  cp "$ROOT/AGENTS.md" "$home/AGENTS.md"
  cp -R "$ROOT/bin" "$home/bin"
  printf '7500\n' > "$home/config/startup-memory-budget"
  [ -n "$id" ] || return 0
  printf 'schema=fm-secondmate-parent.v1\nroute=local\nparent_home=%s\n' \
    "$PRIMARY" > "$home/.fm-secondmate-parent"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
}

# register <id> <home>: the primary's registry placement that corroborates a
# home's identity marker.
register() {
  printf -- '- %s - domain summary (home: %s; scope: %s work; projects: alpha; added 2026-09-15)\n' \
    "$1" "$2" "$1" >> "$REGISTRY"
}

register_remote() {
  printf -- '- %s - remote domain (host: remote-host; root: /remote/code; home: %s; scope: %s work; projects: alpha; added 2026-09-15)\n' \
    "$1" "$2" "$1" >> "$REGISTRY"
}

make_home "$PRIMARY"
make_home "$MATE" mate-a
make_home "$SIBLING" mate-b
printf '# Second mates\n\n' > "$REGISTRY"
register mate-a "$MATE"
register mate-b "$SIBLING"
printf 'captain preferences, primary home\n' > "$PRIMARY/data/captain.md"
printf 'primary learnings\n' > "$PRIMARY/data/learnings.md"

# record_task <home> <id>: enough metadata for fm-send to resolve a local target.
record_task() {
  printf 'kind=crew\nbackend=tmux\nwindow=fm-%s\nworktree=%s\n' "$2" "$1" \
    > "$1/state/$2.meta"
}
record_task "$PRIMARY" primary-task
record_task "$MATE" mate-task
record_task "$SIBLING" sibling-task

OUT="$TMP/out"
RC=0
# run <home-running-the-bin> <fm-home> <script> [args...]: the whole point of the
# guard is that those first two can disagree, so every case names both.
run() {
  local bin_home=$1 fm_home=$2 script=$3
  shift 3
  RC=0
  FM_BACKEND=tmux FM_HOME="$fm_home" "$bin_home/bin/$script" "$@" \
    >"$OUT" 2>&1 || RC=$?
}

run_surface_override() {
  local bin_home=$1 fm_home=$2 override_name=$3 override_value=$4 script=$5
  shift 5
  RC=0
  env FM_BACKEND=tmux FM_HOME="$fm_home" "${override_name}=${override_value}" \
    "$bin_home/bin/$script" "$@" >"$OUT" 2>&1 || RC=$?
}

assert_refused() {
  local label=$1
  [ "$RC" -eq "$REFUSE_EXIT" ] \
    || fail "$label: expected exit $REFUSE_EXIT, got $RC: $(cat "$OUT")"
  grep -Fq "$CROSS_MSG" "$OUT" \
    || fail "$label: refusal did not name the cross-home operation: $(cat "$OUT")"
}

assert_signal() {
  local label=$1 signal=$2
  grep -Fq "[signal: $signal]" "$OUT" \
    || fail "$label: expected signal $signal: $(cat "$OUT")"
}

assert_ok() {
  local label=$1
  [ "$RC" -eq 0 ] || fail "$label: expected exit 0, got $RC: $(cat "$OUT")"
  grep -Fq "$CROSS_MSG" "$OUT" \
    && fail "$label: a valid same-home run was refused: $(cat "$OUT")"
  return 0
}

assert_not_cross_home() {
  local label=$1
  [ "$RC" -ne "$REFUSE_EXIT" ] \
    || fail "$label: a legitimate home selection exited with the refusal code: $(cat "$OUT")"
  grep -Fq "$CROSS_MSG" "$OUT" \
    && fail "$label: a legitimate home selection was refused: $(cat "$OUT")"
  return 0
}

# --- stow memory operations -------------------------------------------------

test_stow_memory_routing() {
  run "$MATE" "$PRIMARY" fm-startup-memory-budget.sh report
  assert_refused 'stow memory accounting, mate -> primary'
  assert_signal 'stow memory accounting, mate -> primary' code-root
  grep -Fq 'mate-a' "$OUT" \
    || fail 'stow refusal did not name the running home identity'
  grep -Fq "$PRIMARY" "$OUT" \
    || fail 'stow refusal did not name the selected home'
  grep -Fq 'estimated_tokens' "$OUT" \
    && fail 'stow refusal still read the other home s memory accounting'

  run "$MATE" "$SIBLING" fm-startup-memory-budget.sh report
  assert_refused 'stow memory accounting, mate -> sibling mate'
  grep -Fq 'mate-b' "$OUT" \
    || fail 'sibling refusal did not name the selected home identity'

  run "$MATE" "$MATE" fm-startup-memory-budget.sh report
  assert_ok 'stow memory accounting, mate -> its own home'
  grep -Fq 'role=secondmate' "$OUT" || fail 'own-home accounting did not run'

  run "$PRIMARY" "$PRIMARY" fm-startup-memory-budget.sh report
  assert_ok 'stow memory accounting, primary -> its own home'

  # The deliberate, correct cross-home selection the /stow cascade makes.
  RC=0
  FM_ROOT_OVERRIDE="$PRIMARY" FM_HOME="$MATE" FM_STATE_OVERRIDE="$MATE/state" \
    FM_DATA_OVERRIDE="$MATE/data" FM_CONFIG_OVERRIDE="$MATE/config" \
    "$PRIMARY/bin/fm-startup-memory-budget.sh" report >"$OUT" 2>&1 || RC=$?
  assert_ok 'stow memory accounting, primary -> a mate it owns'
  grep -Fq 'role=secondmate' "$OUT" \
    || fail 'primary-owned mate accounting did not run'

  pass 'stow memory accounting refuses another home and keeps valid routing'
}

test_bypass_rejected() {
  RC=0
  FM_HOME_IDENTITY_BYPASS=1 FM_HOME="$PRIMARY" \
    "$MATE/bin/fm-startup-memory-budget.sh" report >"$OUT" 2>&1 || RC=$?
  assert_refused 'an inherited identity bypass, mate -> primary'
  assert_signal 'an inherited identity bypass, mate -> primary' code-root
  grep -Fq 'estimated_tokens' "$OUT" \
    && fail 'an inherited identity bypass still read the primary home'

  pass 'an inherited identity bypass cannot disable the boundary'
}

test_surface_override_routing() {
  record_task "$PRIMARY" override-task

  run_surface_override "$MATE" "$MATE" FM_STATE_OVERRIDE "$PRIMARY/state" \
    fm-send.sh fm-override-task --inbox-only 'override steer'
  assert_refused 'fm-send state override into another home'
  assert_signal 'fm-send state override into another home' surface-override
  [ ! -e "$PRIMARY/state/override-task.inbox" ] \
    || fail 'fm-send followed a state override into another home'
  grep -Fq "protected 'primary' home ($PRIMARY)" "$OUT" \
    || fail 'surface override refusal did not name the protected home identity and path'
  grep -Fq "selected 'mate-a' home ($MATE)" "$OUT" \
    || fail 'surface override refusal did not name the selected home identity and path'

  RC=0
  FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$PRIMARY" FM_HOME="$MATE" \
    FM_STATE_OVERRIDE="$PRIMARY/state" \
    "$PRIMARY/bin/fm-send.sh" fm-primary-task --inbox-only 'absolute primary-bin override steer' \
    >"$OUT" 2>&1 || RC=$?
  assert_refused 'fm-send primary-bin state override into the launch-bound primary'
  assert_signal 'fm-send primary-bin state override into the launch-bound primary' surface-override
  [ ! -e "$PRIMARY/state/primary-task.inbox" ] \
    || fail 'fm-send primary-bin override wrote into the launch-bound primary'

  RC=0
  FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$PRIMARY" FM_HOME="$MATE" \
    FM_STATE_OVERRIDE="$SIBLING/state" \
    "$PRIMARY/bin/fm-send.sh" fm-sibling-task --inbox-only 'absolute primary-bin sibling override steer' \
    >"$OUT" 2>&1 || RC=$?
  assert_refused 'fm-send primary-bin state override into a launch-bound sibling'
  assert_signal 'fm-send primary-bin state override into a launch-bound sibling' surface-override
  [ ! -e "$SIBLING/state/sibling-task.inbox" ] \
    || fail 'fm-send primary-bin override wrote into the launch-bound sibling'
  grep -Fq "protected 'mate-b' home ($SIBLING)" "$OUT" \
    || fail 'surface override refusal did not name the protected sibling identity and path'
  grep -Fq "selected 'mate-a' home ($MATE)" "$OUT" \
    || fail 'surface override refusal did not name the selected sibling-route identity and path'

  run_surface_override "$MATE" "$MATE" FM_DATA_OVERRIDE "$PRIMARY/data" \
    fm-startup-memory-budget.sh report
  assert_refused 'memory accounting data override into another home'
  assert_signal 'memory accounting data override into another home' surface-override
  grep -Fq 'estimated_tokens' "$OUT" \
    && fail 'memory accounting read another home through a data override'

  run_surface_override "$MATE" "$MATE" FM_CONFIG_OVERRIDE "$PRIMARY/config" \
    fm-startup-memory-budget.sh report
  assert_refused 'memory accounting config override into another home'
  assert_signal 'memory accounting config override into another home' surface-override

  run_surface_override "$MATE" "$MATE" FM_DATA_OVERRIDE "$PRIMARY/data" \
    fm-stow-cascade.sh
  assert_refused 'stow cascade data override into another home'
  assert_signal 'stow cascade data override into another home' surface-override

  run_surface_override "$MATE" "$MATE" FM_STATE_OVERRIDE "$PRIMARY/state" \
    fm-stow-cascade.sh
  assert_refused 'stow cascade state override into another home'
  assert_signal 'stow cascade state override into another home' surface-override

  for surface in FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE; do
    case "$surface" in
      FM_STATE_OVERRIDE) value="$PRIMARY/state" ;;
      FM_DATA_OVERRIDE) value="$PRIMARY/data" ;;
      FM_CONFIG_OVERRIDE) value="$PRIMARY/config" ;;
      FM_PROJECTS_OVERRIDE) value="$PRIMARY/projects" ;;
    esac
    run_surface_override "$MATE" "$MATE" "$surface" "$value" \
      fm-spawn.sh 'bad id' "$TMP/proj" --mode no-mistakes --yolo off
    assert_refused "fm-spawn $surface into another home"
    assert_signal "fm-spawn $surface into another home" surface-override
  done

  pass 'surface overrides cannot escape the selected home'
}

test_remote_control_overrides() {
  local remote="$TMP/remote-control"
  make_home "$remote"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-host\n' \
    > "$remote/.fm-secondmate-parent"
  printf 'remote-control\n' > "$remote/.fm-secondmate-home"
  mkdir -p "$remote/state/parent-route" "$remote/data/.parent-route"
  register_remote remote-control "$remote"

  RC=0
  FM_HOME="$PRIMARY" FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_STATE_OVERRIDE="$remote/state/parent-route" \
    FM_DATA_OVERRIDE="$remote/data/.parent-route" \
    FM_CONFIG_OVERRIDE="$remote/config" \
    "$PRIMARY/bin/fm-spawn.sh" 'bad id' "$TMP/proj" --mode no-mistakes --yolo off \
    >"$OUT" 2>&1 || RC=$?
  assert_refused 'untrusted remote control overrides'
  assert_signal 'untrusted remote control overrides' surface-override

  RC=0
  FM_HOME="$PRIMARY" FM_REMOTE_JOB_ACTIVE=1 FM_SKIP_SECONDMATE_INHERIT=1 \
    FM_STATE_OVERRIDE="$remote/state/parent-route" \
    FM_DATA_OVERRIDE="$remote/data/.parent-route" \
    FM_CONFIG_OVERRIDE="$remote/config" \
    "$PRIMARY/bin/fm-spawn.sh" 'bad id' "$TMP/proj" --mode no-mistakes --yolo off \
    >"$OUT" 2>&1 || RC=$?
  assert_not_cross_home 'authenticated remote control overrides'

  local stale="$TMP/recycled-remote"
  make_home "$stale"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-host\n' \
    > "$stale/.fm-secondmate-parent"
  printf 'retired-remote\n' > "$stale/.fm-secondmate-home"
  RC=0
  FM_HOME="$PRIMARY" FM_DATA_OVERRIDE="$stale/data" \
    "$PRIMARY/bin/fm-startup-memory-budget.sh" report >"$OUT" 2>&1 || RC=$?
  assert_not_cross_home 'an uncorroborated remote marker data override'

  printf '# Second mates\n\n' > "$REGISTRY"
  register mate-a "$MATE"
  register mate-b "$SIBLING"

  pass 'remote control accepts only its authenticated endpoint layout'
}

# --- fm-send ----------------------------------------------------------------

test_send_routing() {
  run "$MATE" "$PRIMARY" fm-send.sh fm-primary-task --inbox-only 'cross-home steer'
  assert_refused 'fm-send, mate -> primary'
  assert_signal 'fm-send, mate -> primary' code-root
  [ ! -e "$PRIMARY/state/primary-task.inbox" ] \
    || fail 'fm-send wrote a steering record into the other home before refusing'

  run "$MATE" "$SIBLING" fm-send.sh fm-sibling-task --inbox-only 'sibling steer'
  assert_refused 'fm-send, mate -> sibling mate'
  [ ! -e "$SIBLING/state/sibling-task.inbox" ] \
    || fail 'fm-send wrote a steering record into a sibling home before refusing'

  run "$MATE" "$MATE" fm-send.sh fm-mate-task --inbox-only 'own-home steer'
  assert_ok 'fm-send, mate -> its own home'
  [ -f "$MATE/state/mate-task.inbox/001.msg" ] \
    || fail 'a valid same-home steer did not record its message'

  run "$PRIMARY" "$PRIMARY" fm-send.sh fm-primary-task --inbox-only 'own-home steer'
  assert_ok 'fm-send, primary -> its own home'
  [ -f "$PRIMARY/state/primary-task.inbox/001.msg" ] \
    || fail 'a valid primary steer did not record its message'

  pass 'fm-send refuses another home and keeps valid routing'
}

# --- fm-spawn ---------------------------------------------------------------

test_spawn_routing() {
  # The original incident: a secondmate spawning a domain mate through the
  # primary home. fm-spawn's own primary-only check reads $FM_HOME, so under a
  # mispointed FM_HOME it sees no marker and waves this through.
  run "$MATE" "$PRIMARY" fm-spawn.sh newmate "$SIBLING" --secondmate
  assert_refused 'fm-spawn --secondmate, mate -> primary'
  assert_signal 'fm-spawn --secondmate, mate -> primary' code-root

  run "$MATE" "$PRIMARY" fm-spawn.sh worker "$TMP/proj" --mode no-mistakes --yolo off
  assert_refused 'fm-spawn crewmate, mate -> primary'
  [ ! -e "$PRIMARY/state/worker.meta" ] \
    || fail 'fm-spawn published task metadata into the other home before refusing'
  [ ! -e "$PRIMARY/data/worker" ] \
    || fail 'fm-spawn wrote task data into the other home before refusing'

  local absent_state_primary="$TMP/absent-state-primary"
  make_home "$absent_state_primary"
  rmdir "$absent_state_primary/state"
  run "$MATE" "$absent_state_primary" fm-spawn.sh worker "$TMP/proj" --mode no-mistakes --yolo off
  assert_refused 'fm-spawn, mate -> primary without state'
  [ ! -e "$absent_state_primary/state" ] \
    || fail 'fm-spawn created other-home state before refusing'

  # The pre-existing primary-only domain-mate boundary must still fire on its
  # own terms when a mate correctly names its own home.
  run "$MATE" "$MATE" fm-spawn.sh newmate "$SIBLING" --secondmate
  grep -Fq 'only the primary home may create a domain mate' "$OUT" \
    || fail "the primary-only domain-mate refusal was lost: $(cat "$OUT")"

  # A home naming its own home must get past this guard entirely, whether it is
  # the primary or a corroborated mate spawning its own crewmate; an invalid task
  # id gives a deterministic later failure to compare against.
  run "$PRIMARY" "$PRIMARY" fm-spawn.sh 'bad id' "$TMP/proj" --mode no-mistakes --yolo off
  assert_not_cross_home 'fm-spawn, primary -> its own home'

  run "$MATE" "$MATE" fm-spawn.sh 'bad id' "$TMP/proj" --mode no-mistakes --yolo off
  assert_not_cross_home 'fm-spawn, a corroborated mate -> its own home'

  pass 'fm-spawn refuses another home and preserves the domain-mate boundary'
}

# --- fm-stow-cascade --------------------------------------------------------

test_cascade_routing() {
  run "$MATE" "$PRIMARY" fm-stow-cascade.sh
  assert_refused 'fm-stow-cascade, mate -> primary'
  assert_signal 'fm-stow-cascade, mate -> primary' code-root

  run "$PRIMARY" "$PRIMARY" fm-stow-cascade.sh
  assert_ok 'fm-stow-cascade, primary -> its own home'
  grep -Fq 'secondmate=mate-a' "$OUT" \
    || fail "the primary's own cascade did not enumerate its mate: $(cat "$OUT")"

  pass 'fm-stow-cascade refuses another home and keeps the primary sweep'
}

# --- the launch-binding signal ---------------------------------------------

test_launch_binding_signal() {
  # A secondmate agent that invokes the PRIMARY home's own bin/ by absolute path
  # has a primary code root, so only its session binding still knows what it is.
  RC=0
  FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$PRIMARY" FM_HOME="$PRIMARY" \
    "$PRIMARY/bin/fm-startup-memory-budget.sh" report >"$OUT" 2>&1 || RC=$?
  assert_refused 'launch binding, secondmate session -> primary home'
  assert_signal 'launch binding, secondmate session -> primary home' launch-binding
  grep -Fq 'estimated_tokens' "$OUT" \
    && fail 'the bound session still read the primary home s memory accounting'

  RC=0
  FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$PRIMARY" FM_HOME="$MATE" \
    "$MATE/bin/fm-startup-memory-budget.sh" report >"$OUT" 2>&1 || RC=$?
  assert_ok 'a local secondmate with the earlier binding -> its own home'

  local remote="$TMP/remote"
  make_home "$remote"
  printf 'schema=fm-secondmate-parent.v1\nroute=remote\nparent_host=remote-host\n' \
    > "$remote/.fm-secondmate-parent"
  printf 'remote-a\n' > "$remote/.fm-secondmate-home"

  RC=0
  FM_PUBLIC_FOLLOWUP_PRIMARY_HOME="$PRIMARY" FM_HOME="$remote" \
    "$PRIMARY/bin/fm-startup-memory-budget.sh" report >"$OUT" 2>&1 || RC=$?
  assert_ok 'a remote secondmate with the earlier binding -> its own home'

  pass 'the secondmate session binding refuses its bound primary home'
}

# --- identity marker safety -------------------------------------------------

test_unsafe_identity_marker() {
  local broken="$TMP/broken"
  make_home "$broken"

  ln -s "$MATE/.fm-secondmate-home" "$broken/.fm-secondmate-home"
  run "$broken" "$broken" fm-startup-memory-budget.sh report
  assert_refused 'symlinked identity marker'
  rm -f "$broken/.fm-secondmate-home"

  : > "$broken/.fm-secondmate-home"
  run "$broken" "$broken" fm-startup-memory-budget.sh report
  assert_refused 'empty identity marker'

  printf 'mate-a\nmate-b\n' > "$broken/.fm-secondmate-home"
  run "$broken" "$broken" fm-startup-memory-budget.sh report
  assert_refused 'identity marker holding two ids'

  printf 'mate-a\n\n' > "$broken/.fm-secondmate-home"
  run "$broken" "$broken" fm-startup-memory-budget.sh report
  assert_refused 'identity marker holding an empty second line'

  printf 'mate a/../..\n' > "$broken/.fm-secondmate-home"
  run "$broken" "$broken" fm-startup-memory-budget.sh report
  assert_refused 'identity marker outside the registry id charset'

  printf 'mate\000-a\n' > "$broken/.fm-secondmate-home"
  run "$broken" "$broken" fm-startup-memory-budget.sh report
  assert_refused 'identity marker containing a NUL byte'

  printf 'mate-c\n' > "$broken/.fm-secondmate-home"
  run "$broken" "$broken" fm-startup-memory-budget.sh report
  assert_ok 'a repaired identity marker'

  pass 'an unreadable home identity refuses instead of collapsing to primary'
}

test_registry_id_charset() {
  local dotted="$TMP/dotted-id" long="$TMP/long-id" dotted_id='.mate' long_id
  long_id=$(printf 'a%.0s' {1..129})
  make_home "$dotted" "$dotted_id"
  make_home "$long" "$long_id"
  register "$dotted_id" "$dotted"
  register "$long_id" "$long"

  run "$dotted" "$dotted" fm-startup-memory-budget.sh report
  assert_ok 'a registry-confirmed leading-dot identity'

  run "$long" "$long" fm-startup-memory-budget.sh report
  assert_ok 'a registry-confirmed identity longer than 128 characters'

  pass 'identity markers accept the registry id charset'
}

# --- copied identity markers ------------------------------------------------

test_copied_marker_path() {
  local copied="$TMP/copied"
  make_home "$copied" mate-a

  run "$MATE" "$copied" fm-startup-memory-budget.sh report
  assert_refused 'a copied marker reusing the caller id'
  assert_signal 'a copied marker reusing the caller id' code-root
  grep -Fq 'estimated_tokens' "$OUT" \
    && fail 'a copied marker path was accepted as the caller home'

  pass 'an own-home exception requires the canonical registered path'
}

# --- a leftover marker is not an identity -----------------------------------

test_uncorroborated_marker() {
  # A pooled firstmate task worktree re-leased from a retired secondmate home
  # keeps that home's gitignored marker and parent binding. Nothing registers it
  # at that path any more, so it must establish no identity and refuse nothing.
  local leftover="$TMP/leftover"
  make_home "$leftover" mate-retired

  run "$leftover" "$PRIMARY" fm-startup-memory-budget.sh report
  assert_ok 'a leftover marker no registry corroborates'
  grep -Fq 'estimated_tokens' "$OUT" || fail 'the uncorroborated run did not execute'

  # Registering that exact path is what turns the marker into an identity.
  register mate-retired "$leftover"
  run "$leftover" "$PRIMARY" fm-startup-memory-budget.sh report
  assert_refused 'a registered home reaching the primary'
  assert_signal 'a registered home reaching the primary' code-root

  # A registry that places the same id at a DIFFERENT path corroborates nothing.
  printf '# Second mates\n\n' > "$REGISTRY"
  register mate-a "$MATE"
  register mate-b "$SIBLING"
  register mate-retired "$TMP/somewhere-else"
  run "$leftover" "$PRIMARY" fm-startup-memory-budget.sh report
  assert_ok 'a registry entry pointing at another path'

  printf '# Second mates\n\n' > "$REGISTRY"
  register mate-a "$MATE"
  register mate-b "$SIBLING"
  pass 'only a registry-corroborated marker establishes a home identity'
}

test_stow_memory_routing
test_bypass_rejected
test_surface_override_routing
test_remote_control_overrides
test_send_routing
test_spawn_routing
test_cascade_routing
test_launch_binding_signal
test_unsafe_identity_marker
test_registry_id_charset
test_uncorroborated_marker
test_copied_marker_path
