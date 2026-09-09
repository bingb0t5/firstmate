#!/usr/bin/env bash

codex_stop_milliseconds() {
  python3 -c 'import time; print(time.monotonic_ns() // 1000000)'
}

codex_stop_session() {
  python3 -c 'import os, sys; print(os.getsid(int(sys.argv[1])))' "$1"
}

codex_stop_cleanup_processes() {
  python3 - "$1" "${CHILD_PIDS:-}" <<'PY'
import os
import signal
import subprocess
import sys
import time

root, children = sys.argv[1:]
children = {int(pid) for pid in children.split()}
excluded = {os.getpid(), os.getppid()}
owned = {}
deadline = time.monotonic() + 8
escalate = time.monotonic() + 4
quiet = 0
while time.monotonic() < deadline:
    output = subprocess.check_output(
        ['ps', '-axo', 'pid=,ppid=,stat=,lstart=,command='], text=True
    )
    processes = {}
    for line in output.splitlines():
        fields = line.split(None, 8)
        if len(fields) != 9:
            continue
        pid, parent = map(int, fields[:2])
        if pid in excluded or fields[2].startswith('Z'):
            continue
        processes[pid] = (parent, tuple(fields[3:8]), fields[8])
    current = {
        pid for pid, (parent, identity, command) in processes.items()
        if owned.get(pid) == identity or root + '/' in command
        or (pid in children and parent == os.getppid())
    }
    while True:
        descendants = {pid for pid, row in processes.items() if row[0] in current}
        expanded = current | descendants
        if expanded == current:
            break
        current = expanded
    if not current:
        quiet += 1
        if quiet == 3:
            sys.exit(0)
    else:
        quiet = 0
    for pid in current:
        owned[pid] = processes[pid][1]
        try:
            os.kill(pid, signal.SIGKILL if time.monotonic() >= escalate else signal.SIGTERM)
        except ProcessLookupError:
            pass
    time.sleep(0.1)
print(f'not ok - test processes did not terminate; retaining {root}', file=sys.stderr)
sys.exit(1)
PY
}
