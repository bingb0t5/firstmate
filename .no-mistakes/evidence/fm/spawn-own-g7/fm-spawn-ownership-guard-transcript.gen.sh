#!/usr/bin/env bash
# Operator-perspective transcript for the fm-spawn secondmate-ownership guard.
set -u
ROOT=${ROOT:?}
TMP=$(mktemp -d /tmp/fm-own-evidence.XXXXXX)
HOME_DIR="$TMP/firstmate"
PROJ="$TMP/projects"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$PROJ"

FB="$TMP/fakebin"; FAKE="$TMP/fake"; mkdir -p "$FB" "$FAKE"
printf 'claude' > "$FAKE/command"
: > "$FAKE/windows"
cat > "$FB/tmux" <<'SH'
#!/usr/bin/env bash
set -u
D=$FM_FAKE_DIR
case "${1:-}" in
  new-window) printf 'fakewin1\n'; exit 0 ;;
  display-message)
    for a in "$@"; do
      case "$a" in
        *pane_current_command*) cat "$D/command"; printf '\n'; exit 0 ;;
        *pane_current_path*) cat "$D/cwd"; printf '\n'; exit 0 ;;
        *cursor_y*) printf '1\n'; exit 0 ;;
      esac
    done
    printf 'firstmate\n'; exit 0 ;;
  capture-pane) printf 'pane\n'; exit 0 ;;
  list-windows) [ -f "$D/windows" ] && cat "$D/windows"; exit 0 ;;
esac
exit 0
SH
printf '#!/usr/bin/env bash\nexit 0\n' > "$FB/treehouse"
chmod +x "$FB/tmux" "$FB/treehouse"

mkproj() {  # <name> <task-id>
  local p="$PROJ/$1" wt="$TMP/wt-$2"
  mkdir -p "$p"
  git -C "$p" init -q
  git -C "$p" config user.email t@example.invalid
  git -C "$p" config user.name t
  printf 'x\n' > "$p/README.md"
  git -C "$p" add -A && git -C "$p" -c commit.gpgsign=false commit -qm init
  git clone --quiet --bare "$p" "$p.origin.git"
  git -C "$p" remote add origin "file://$(cd "$p.origin.git" && pwd)"
  git -C "$p" worktree add --quiet -b "task-$2" "$wt"
  printf '%s' "$wt" > "$FAKE/cwd"
}

brief() { mkdir -p "$HOME_DIR/data/$1"; printf 'You are a crewmate.\n\n# Definition of done\nDelivery contract: mode=no-mistakes\n' > "$HOME_DIR/data/$1/brief.md"; }

spawn() {
  FM_ROOT_OVERRIDE='' FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_PROJECTS_OVERRIDE="$PROJ" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_BACKEND=tmux FM_FAKE_DIR="$FAKE" TMUX='' \
    PATH="$FB:$PATH" "$ROOT/bin/fm-spawn.sh" "$@" 2>&1
}

show() { printf '\n$ %s\n' "$1"; }

cat > "$HOME_DIR/data/secondmates.md" <<REG
# Second mates

- design - design system (home: $TMP/homes/design; scope: design system, component library; projects: orca-ui, marketing-site; added 2026-06-22)
- triage - incident triage (home: $TMP/homes/triage; scope: incident triage and on-call; projects: projects/orca-ui; added 2026-07-02)
REG
mkdir -p "$TMP/homes/design" "$TMP/homes/triage"

echo "=============================================================="
echo " 1. The registry that states who owns what"
echo "=============================================================="
show "cat \$FM_HOME/data/secondmates.md"
sed "s#$TMP#\$TMP#g" "$HOME_DIR/data/secondmates.md"

echo
echo "=============================================================="
echo " 2. Fresh crewmate spawn into a secondmate-owned project: REFUSED"
echo "=============================================================="
mkproj orca-ui fix-nav-a1; brief fix-nav-a1
show "fm-spawn.sh fix-nav-a1 projects/orca-ui claude --mode no-mistakes --yolo off"
out=$(spawn fix-nav-a1 "$PROJ/orca-ui" claude --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"
show "ls \$FM_HOME/state/"
ls "$HOME_DIR/state/" 2>/dev/null || true
printf '(no fix-nav-a1.meta: the refusal lands before any task record exists)\n'

echo
echo "=============================================================="
echo " 3. Same spawn with the deliberate override: allowed, loud, recorded"
echo "=============================================================="
show "fm-spawn.sh fix-nav-a1 projects/orca-ui claude --mode no-mistakes --yolo off --allow-primary-spawn"
out=$(spawn fix-nav-a1 "$PROJ/orca-ui" claude --mode no-mistakes --yolo off --allow-primary-spawn); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"
show "grep primary_spawn_override \$FM_HOME/state/fix-nav-a1.meta"
grep primary_spawn_override "$HOME_DIR/state/fix-nav-a1.meta" || echo "(none)"

echo
echo "=============================================================="
echo " 4. Unowned project, non-empty registry: warns, then spawns"
echo "=============================================================="
mkproj api-gateway add-rate-b2; brief add-rate-b2
show "fm-spawn.sh add-rate-b2 projects/api-gateway claude --mode no-mistakes --yolo off"
out=$(spawn add-rate-b2 "$PROJ/api-gateway" claude --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"
show "grep -c primary_spawn_override \$FM_HOME/state/add-rate-b2.meta"
grep -c primary_spawn_override "$HOME_DIR/state/add-rate-b2.meta" || true

echo
echo "=============================================================="
echo " 5. A --secondmate spawn is untouched by the guard"
echo "=============================================================="
SM="$TMP/homes/design"
mkdir -p "$SM/state" "$SM/bin" "$SM/data"
printf 'fixture\n' > "$SM/AGENTS.md"
printf 'design\n' > "$SM/.fm-secondmate-home"
printf 'You are a persistent second mate.\n' > "$SM/data/charter.md"
printf '%s' "$SM" > "$FAKE/cwd"
show "fm-spawn.sh design \$TMP/homes/design --secondmate"
out=$(spawn design "$SM" --secondmate); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"

echo
echo "=============================================================="
echo " 6. Misusing the override outside a fresh ship/scout spawn: refused"
echo "=============================================================="
show "fm-spawn.sh design \$TMP/homes/design --secondmate --allow-primary-spawn"
out=$(spawn design "$SM" --secondmate --allow-primary-spawn); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"

echo
echo "=============================================================="
echo " 7. A scout spawn into an owned project refuses the same way"
echo "=============================================================="
mkproj marketing-site look-d4; brief look-d4
show "fm-spawn.sh look-d4 projects/marketing-site claude --scout"
out=$(spawn look-d4 "$PROJ/marketing-site" claude --scout); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"

echo
echo "=============================================================="
echo " 8. --relaunch into an owned project is unaffected by the guard"
echo "=============================================================="
printf 'zsh' > "$FAKE/command"
printf '%s' "$TMP/wt-fix-nav-a1" > "$FAKE/cwd"
printf 'fm-fix-nav-a1\n' > "$FAKE/windows"
show "fm-spawn.sh fix-nav-a1 --relaunch --harness claude"
out=$(spawn fix-nav-a1 --relaunch --harness claude); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"

echo
echo "=============================================================="
echo " 9. A malformed registry line refuses instead of voiding a claim"
echo "=============================================================="
printf -- '- triage - typo entry (home: %s/homes/triage; scope: triage; projects: api-gateway)\n' "$TMP" >> "$HOME_DIR/data/secondmates.md"
mkproj billing-svc doc-c3; brief doc-c3
show "fm-spawn.sh doc-c3 projects/billing-svc claude --mode no-mistakes --yolo off"
out=$(spawn doc-c3 "$PROJ/billing-svc" claude --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"

echo
echo "=============================================================="
echo " 10. No registry at all: the guard is silent and the spawn proceeds"
echo "=============================================================="
rm -f "$HOME_DIR/data/secondmates.md"
show "rm \$FM_HOME/data/secondmates.md && fm-spawn.sh doc-c3 projects/billing-svc claude --mode no-mistakes --yolo off"
printf 'claude' > "$FAKE/command"
printf '%s' "$TMP/wt-doc-c3" > "$FAKE/cwd"
: > "$FAKE/windows"
out=$(spawn doc-c3 "$PROJ/billing-svc" claude --mode no-mistakes --yolo off); rc=$?
printf '%s\n' "$out" | sed "s#$TMP#\$TMP#g"
printf '[exit status: %s]\n' "$rc"

rm -rf "$TMP" /tmp/fm-fix-nav-a1 /tmp/fm-add-rate-b2 /tmp/fm-doc-c3
