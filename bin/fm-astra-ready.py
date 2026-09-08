#!/usr/bin/env python3
"""Publish or withdraw the guest marker, using the existing helper input lock.

Usage (inside the VM, as astra):
  /home/astra/.local/bin/fm-astra-ready refresh
  /home/astra/.local/bin/fm-astra-ready remove

Install with fm-astra-install.sh. Fixed paths deliberately prevent a privileged
publisher from following arbitrary operator-supplied manifest/marker locations.
Refresh removes stale readiness before checking components, auth and a real
gpt-6-astra screenshot turn. It never accepts a supplied smoke receipt.
"""
from __future__ import annotations

import hashlib
import importlib.util
from importlib.machinery import SourceFileLoader
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time
import uuid


def module(name, path):
    spec = importlib.util.spec_from_loader(name, SourceFileLoader(name, str(path)))
    loaded = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(loaded)
    return loaded


BIN = Path(__file__).resolve().parent
client = module('astra_client', BIN / ('fm-codex-client' if (BIN / 'fm-codex-client').exists() else 'fm-codex-client.py'))
helper = module('astra_helper', BIN / 'fm-astra-guest.py')
MANIFEST = client.HOME / '.local/share/codex/readiness.json'
ADAPTER = client.HOME / '.local/bin/fm-codex-client'


def atomic(path, value):
    with tempfile.NamedTemporaryFile(mode='w', encoding='utf-8', dir=path.parent,
                                     prefix='.' + path.name + '.', delete=False) as output:
        temporary = Path(output.name)
        try:
            os.fchmod(output.fileno(), 0o600)
            json.dump(value, output, ensure_ascii=False, sort_keys=True)
            output.write('\n')
            output.flush()
            os.fsync(output.fileno())
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def safe_paths():
    client.identity()
    paths = [MANIFEST.parent, client.STATE]
    if client.MARKER.parent.exists() or client.MARKER.parent.is_symlink():
        paths.append(client.MARKER.parent)
    for path in paths:
        if not path.is_dir() or path.is_symlink() or path.stat().st_uid != os.geteuid():
            client.fail('unsafe_publication_directory')
        if path.stat().st_mode & 0o022:
            client.fail('unsafe_publication_directory')
    if MANIFEST.is_symlink() or client.MARKER.is_symlink():
        client.fail('unsafe_publication_file')
    if MANIFEST.exists() and (MANIFEST.stat().st_uid != os.geteuid() or MANIFEST.stat().st_mode & 0o022):
        client.fail('unsafe_manifest')


def refresh(doc):
    client.preflight()
    doc['credential_status'] = 'available'
    # Check every published component, including future additive component paths.
    for name, path in doc.get('components', {}).items():
        if not isinstance(path, str) or not Path(path).is_absolute() or not Path(path).exists():
            client.fail('published_component_missing_' + name if name.isidentifier() else 'published_component_missing')
    expected = {'vm.guest_user': 'astra', 'desktop.display': ':1',
                'desktop.browser_profile': str(client.PROFILE),
                'readiness.marker': str(client.MARKER),
                'readiness.astra_identifier': client.MODEL,
                'components.client_adapter': str(ADAPTER),
                'components.cua_repl': str(client.VENDOR / 'cua_repl'),
                'components.node_repl': str(client.VENDOR / 'node_repl'),
                'reachability.authenticated': True, 'reachability.public': False}
    if any(helper.get_field(doc, key) != value for key, value in expected.items()):
        client.fail('manifest_identity_mismatch')
    if (not ADAPTER.is_file() or ADAPTER.is_symlink() or not os.access(ADAPTER, os.X_OK)
            or ADAPTER.stat().st_uid != os.geteuid() or ADAPTER.stat().st_mode & 0o022):
        client.fail('unsafe_or_nonexecutable_adapter')
    digest = hashlib.sha256(ADAPTER.read_bytes()).hexdigest()
    request_id = str(uuid.uuid4())
    env = dict(os.environ, **client.environment(request_id))
    request = {'protocol': 1, 'request_id': request_id, 'operation': 'smoke', 'model': client.MODEL}
    with helper.client_process([str(ADAPTER)], env) as process:
        try:
            out, _ = process.communicate(json.dumps(request).encode('utf-8') + b'\n', timeout=120)
        except subprocess.TimeoutExpired:
            client.fail('smoke_timeout')
        try:
            result = json.loads(out.decode('utf-8'))
        except (ValueError, UnicodeError):
            client.fail('smoke_invalid_response')
        if (process.returncode or not isinstance(result, dict) or result.get('ok') is not True
                or result.get('model') != client.MODEL or result.get('request_id') != request_id
                or result.get('screenshot_observed') is not True or result.get('actions_completed') != 0):
            client.fail('exact_model_desktop_smoke_failed')
    if hashlib.sha256(ADAPTER.read_bytes()).hexdigest() != digest:
        client.fail('adapter_changed_during_smoke')
    return {'schema': 1, 'state': 'ready', 'model': client.MODEL, 'screenshot_observed': True,
            'adapter_sha256': digest, 'verified_at': int(time.time()), 'request_id': request_id,
            'scope': 'native-desktop', 'dom_cdp_supported': False}


def main():
    if len(sys.argv) != 2 or sys.argv[1] not in ('refresh', 'remove'):
        print(__doc__, file=sys.stderr)
        return 2
    doc = None
    try:
        safe_paths()
        with helper.exclusive_state(client.STATE) as (state, _):
            # A crash or failed refresh must leave no authoritative ready marker.
            client.MARKER.unlink(missing_ok=True)
            doc = helper.validate_manifest(MANIFEST, require_ready=False)
            doc['readiness']['state'] = 'pending'
            doc['readiness'].pop('verification', None)
            doc['readiness']['pending_condition'] = 'refresh_in_progress'
            doc['credential_status'] = 'pending'
            atomic(MANIFEST, doc)
            try:
                if sys.argv[1] == 'remove':
                    client.fail('operator_removed')
                if not client.MARKER.parent.exists():
                    client.fail('missing_runtime_directory')
                if state['mode'] != 'active':
                    client.fail('human_takeover_active')
                receipt = refresh(doc)
            except client.Refusal as exc:
                doc['readiness']['pending_condition'] = str(exc)
                if str(exc) == 'missing_auth':
                    doc['credential_status'] = 'captain-assistance-required'
                atomic(MANIFEST, doc)
                raise
            doc['readiness'].pop('pending_condition', None)
            doc['readiness']['state'] = 'ready'
            doc['readiness']['verification'] = receipt
            doc['credential_status'] = 'available'
            try:
                atomic(MANIFEST, doc)
                atomic(client.MARKER, receipt)
            except Exception:
                doc['readiness']['state'] = 'pending'
                doc['readiness']['pending_condition'] = 'publication_failed'
                doc['readiness'].pop('verification', None)
                atomic(MANIFEST, doc)
                raise
        print(json.dumps({'state': 'ready', 'model': client.MODEL, 'marker': str(client.MARKER)}))
        return 0
    except client.Refusal as exc:
        print(json.dumps({'state': 'pending', 'condition': str(exc)}))
        return 0 if str(exc) == 'operator_removed' else 3
    except Exception:
        print(json.dumps({'state': 'pending', 'condition': 'publication_failed'}))
        return 3


if __name__ == '__main__':
    sys.stdout.reconfigure(encoding='utf-8')
    sys.stderr.reconfigure(encoding='utf-8')
    raise SystemExit(main())
