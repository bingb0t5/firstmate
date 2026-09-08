#!/usr/bin/env bash
set -u
export TMPDIR="$(mktemp -d /tmp/fm-local-test.XXXXXX)"
evidence=/home/rich/.no-mistakes/evidence/01M207MRXNF2QK6WE33CX9F1JE
suite=$1
case "$suite" in
  wake) . tests/wake-helpers.sh ;;
  launch) . tests/lib.sh ;;
esac
capture_and_cleanup() {
  rc=$?
  python3 - "$TMP_ROOT" "$evidence/$suite-behavior.txt" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
with open(sys.argv[2], 'w') as out:
    out.write('Executable integration fixtures: real Firstmate scripts; simulated terminal/backend and Codex engine.\n')
    for p in sorted(root.rglob('*')):
        if p.is_file() and not p.is_symlink() and (p.suffix in ('.out', '.err', '.rc') or p.name in ('.wake-queue', '.watch-cycle-exits.log', 'launch.log', 'tmux.log')):
            data = p.read_text(errors='replace')
            if data:
                out.write('\n$ observed ' + str(p.relative_to(root)) + '\n' + data + '\n')
PY
  fm_test_cleanup
  rmdir "$TMPDIR"
  exit "$rc"
}
trap capture_and_cleanup EXIT
case "$suite" in
  wake) . tests/fm-wake-queue.test.sh --secondmate ;;
  launch) . tests/fm-spawn-dispatch-profile.test.sh --codex-secondmate ;;
esac
