#!/usr/bin/env bash
# Install the maintained guest artifacts INSIDE the commissioned VM as astra:
#   /absolute/path/to/firstmate/bin/fm-astra-install.sh
# The four sibling source files must travel together. No credentials/config are
# copied. Existing helper handoff state and the Chrome profile are preserved.
# Infra must also run as guest root after boot: install -d -o astra -g astra -m 0700 /run/astra
# Root may run this installer to do both steps. Installation never publishes readiness.
#   /home/astra/.local/bin/fm-astra-ready refresh
#   /home/astra/.local/bin/fm-astra-ready remove
set -euo pipefail
if [[ "${1:-}" == --help ]]; then
  sed -n '2,10p' "$0"
  exit 0
fi
[[ $# == 0 ]] || { echo 'fm-astra-install: no arguments expected' >&2; exit 2; }
[[ $EUID == 0 || $(id -un) == astra ]] || { echo 'fm-astra-install: guest astra or root required' >&2; exit 2; }
[[ $(getent passwd astra | cut -d: -f6) == /home/astra ]] || { echo 'fm-astra-install: guest astra account required' >&2; exit 2; }
source_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for source in fm-codex-client.py fm-astra-ready.py fm-astra-guest.py fm-astra-guest.sh; do
  [[ -f "$source_dir/$source" && ! -L "$source_dir/$source" ]] || exit 2
done
for directory in /home/astra /home/astra/.local /home/astra/.local/bin /run/astra; do
  [[ ! -L "$directory" ]] || { echo 'fm-astra-install: symlink destination refused' >&2; exit 2; }
done
run_as=()
if [[ $EUID == 0 ]]; then
  install -d -o astra -g astra -m 0700 /home/astra/.local/bin /run/astra
  run_as=(sudo -u astra)
fi
# Join the existing input lock so upgrades cannot interleave a live action group.
"${run_as[@]}" python3 - "$source_dir" <<'PY'
import importlib.util
import os
from pathlib import Path
import shutil
import sys
import tempfile

source = Path(sys.argv[1])
for path in (Path('/home/astra/.local/bin'), Path('/home/astra/.local/share/codex'),
             Path('/home/astra/.local/state/firstmate/astra')):
    if path.is_symlink() or not path.is_dir() or path.stat().st_uid != os.geteuid():
        raise SystemExit('fm-astra-install: unsafe guest directory')
    path.chmod(0o700)
manifest = Path('/home/astra/.local/share/codex/readiness.json')
if manifest.is_symlink() or not manifest.is_file() or manifest.stat().st_uid != os.geteuid():
    raise SystemExit('fm-astra-install: unsafe or missing guest manifest')
manifest.chmod(0o600)
spec = importlib.util.spec_from_file_location('guest_helper', source / 'fm-astra-guest.py')
helper = importlib.util.module_from_spec(spec)
spec.loader.exec_module(helper)
with helper.exclusive_state(Path('/home/astra/.local/state/firstmate/astra')):
    Path('/run/astra/ready').unlink(missing_ok=True)
    for origin, name in (('fm-codex-client.py', 'fm-codex-client'),
                         ('fm-astra-ready.py', 'fm-astra-ready'),
                         ('fm-astra-guest.py', 'fm-astra-guest.py'),
                         ('fm-astra-guest.sh', 'fm-astra-guest.sh')):
        destination = Path('/home/astra/.local/bin') / name
        with tempfile.NamedTemporaryFile(dir=destination.parent, delete=False) as output:
            temporary = Path(output.name)
            try:
                with (source / origin).open('rb') as incoming:
                    shutil.copyfileobj(incoming, output)
                output.flush()
                os.fchmod(output.fileno(), 0o755)
                os.replace(temporary, destination)
            finally:
                temporary.unlink(missing_ok=True)
PY
"${run_as[@]}" /home/astra/.local/bin/fm-astra-ready remove
stat -c '%U:%G %a %n' /home/astra/.local/bin/fm-codex-client /home/astra/.local/bin/fm-astra-ready
if [[ ! -d /run/astra ]]; then
  echo 'fm-astra-install: readiness pending; Infra guest root must run: install -d -o astra -g astra -m 0700 /run/astra' >&2
fi
