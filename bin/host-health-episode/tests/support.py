"""Temporary-root-only persistence/deployment support for q27 tests.

Nothing in this module accepts '/' as a root or addresses a live host path directly.
"""

from __future__ import annotations

from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
from typing import Callable, Iterator


class DryRunRefusal(RuntimeError):
    pass


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def map_absolute(temp_root: Path, absolute_path: str) -> Path:
    root = temp_root.resolve()
    if str(root) == "/" or not root.is_dir():
        raise DryRunRefusal("dry-run root must be an existing non-root directory")
    path = Path(absolute_path)
    if not path.is_absolute() or absolute_path == "/":
        raise DryRunRefusal("manifest path must be absolute and non-root")
    mapped = (root / absolute_path.lstrip("/")).resolve()
    if root not in mapped.parents:
        raise DryRunRefusal("mapped path escaped dry-run root")
    return mapped


def atomic_write(path: Path, data: bytes, mode: int = 0o600, fail_stage: str | None = None) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    os.chmod(path.parent, 0o700)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "wb", closefd=True) as stream:
            stream.write(data)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_path, mode)
        if fail_stage == "before_replace":
            raise OSError("synthetic write failure before replace")
        os.replace(temp_path, path)
        directory_fd = os.open(path.parent, os.O_RDONLY)
        try:
            os.fsync(directory_fd)
        finally:
            os.close(directory_fd)
        if fail_stage == "after_replace":
            raise OSError("synthetic write failure after replace")
    finally:
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


@contextmanager
def exclusive_nonblocking(lock_path: Path) -> Iterator[bool]:
    lock_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    acquired = False
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            acquired = True
        except BlockingIOError:
            acquired = False
        yield acquired
    finally:
        if acquired:
            fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)


def admitted_once(
    lock_path: Path,
    counters_path: Path,
    transition: Callable[[], bytes],
) -> bool:
    """Run one synthetic sample/send/migrate/write path only after lock admission."""
    with exclusive_nonblocking(lock_path) as acquired:
        if not acquired:
            return False
        data = transition()
        atomic_write(counters_path, data)
        return True


def _unique_json_object(pairs):
    obj = {}
    for key, value in pairs:
        if key in obj:
            raise DryRunRefusal("duplicate JSON object key")
        obj[key] = value
    return obj


def parse_strict_json(text: str):
    """Parse manifest JSON, refusing duplicate keys and oversized/parser failures."""
    if type(text) is not str:
        raise DryRunRefusal("manifest JSON must be text")
    try:
        return json.loads(text, object_pairs_hook=_unique_json_object)
    except DryRunRefusal:
        raise
    except (
        json.JSONDecodeError,
        UnicodeError,
        ValueError,
        TypeError,
        RecursionError,
        OverflowError,
    ) as exc:
        raise DryRunRefusal("manifest JSON is malformed or unreadable") from exc


def load_manifest(path: Path) -> dict:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as exc:
        raise DryRunRefusal("manifest JSON is unreadable") from exc
    data = parse_strict_json(text)
    if type(data) is not dict:
        raise DryRunRefusal("manifest is not an object")
    return data


def _expected_manifest(host: str) -> dict:
    baseline = "912f99b4433cef07522c81b874e50c7b82b5560d1777495cf53ae20043e7a668"
    probe_guarantees = [
        "execute the staged path, not the active path",
        "do not load sender",
        "do not sample",
        "do not migrate or write state",
        "do not emit a notification",
    ]
    activation_steps = [
        "acquire existing host watcher lock and wait out the old invocation",
        "recheck active baseline and staged candidate hashes under the lock",
        "compare staged bytes with independently accepted bytes",
        "back up source and state under the lock",
        None,
        "release lock without changing the scheduler",
    ]
    rollback = {
        "default_state_policy": "retain migrated state",
        "source": "restore source backup atomically under the same host watcher lock and verify baseline hash",
        "state": "restore only with separate destructive approval under the same lock",
    }
    if host == "lalo-dev":
        source = "/home/rich/.local/bin/host-health-watch"
        staging = "/home/rich/.local/bin/.host-health-watch.q27.new"
        activation_steps[4] = "atomically replace source preserving rich:rich 0700"
        return {
            "account": "rich",
            "activation": {
                "permitted": False,
                "requires": [
                    "independent model acceptance",
                    "fresh baseline hash under watcher lock",
                    "final accepted candidate hash and byte comparison",
                    "successful staged no-send probe",
                    "explicit live activation approval",
                ],
                "steps": activation_steps,
            },
            "baseline_sha256": baseline,
            "canary_order": 1,
            "candidate_sha256": None,
            "config": "/home/rich/.config/host-health-watch.json",
            "host": host,
            "lock": "/home/rich/.local/state/host-health-watch/lock",
            "observation_cycles": 15,
            "probe": {
                "argv": [staging, "--probe-once"],
                "guarantees": probe_guarantees,
                "scope": "direct staged probe only; existing cron can still run baseline",
            },
            "prohibitions": [
                "no live action from this manifest",
                "no scheduler edit",
                "no credential or route change",
                "no service, process, worker, swap, or monitoring-scope change",
                "no state rollback without separate destructive approval",
                "stop before worker-1 on any first-canary failure",
            ],
            "rollback": rollback,
            "scheduler": {
                "account": "rich",
                "cadence": "existing one-minute user crontab",
                "invocation": source,
                "mutation": "forbidden",
            },
            "schema_version": 1,
            "source": {
                "group": "rich",
                "mode": "0700",
                "owner": "rich",
                "path": source,
            },
            "source_backup": "/home/rich/.local/bin/.host-health-watch.q27.baseline.bak",
            "staging": staging,
            "state": "/home/rich/.local/state/host-health-watch/state.json",
            "state_backup": "/home/rich/.local/state/host-health-watch/state.json.q27.pre-activation.bak",
        }
    if host == "worker-1":
        source = "/usr/local/sbin/host-health-watch"
        staging = "/usr/local/sbin/.host-health-watch.q27.new"
        activation_steps[4] = "atomically replace source preserving root:root 0755"
        return {
            "account": "root",
            "activation": {
                "permitted": False,
                "requires": [
                    "recorded successful lalo-dev fifteen-cycle evidence",
                    "independent reviewer concurrence",
                    "fresh worker-1 baseline hash under watcher lock",
                    "final accepted candidate hash and byte comparison",
                    "successful staged no-send probe",
                    "separate explicit worker-1 activation approval",
                ],
                "steps": activation_steps,
            },
            "baseline_sha256": baseline,
            "canary_order": 2,
            "candidate_sha256": None,
            "config": "/root/.config/host-health-watch.json",
            "host": host,
            "lock": "/root/.local/state/host-health-watch/lock",
            "observation_cycles": 15,
            "probe": {
                "argv": [staging, "--probe-once"],
                "guarantees": probe_guarantees,
                "scope": "direct staged probe only; existing cron can still run baseline",
            },
            "prohibitions": [
                "no live action from this manifest",
                "no worker-1 action before accepted lalo-dev evidence and separate approval",
                "no scheduler edit",
                "no credential or route change",
                "no service, process, worker, swap, or monitoring-scope change",
                "no state rollback without separate destructive approval",
            ],
            "rollback": rollback,
            "scheduler": {
                "account": "root",
                "cadence": "existing one-minute root crontab",
                "invocation": source,
                "mutation": "forbidden",
            },
            "schema_version": 1,
            "source": {
                "group": "root",
                "mode": "0755",
                "owner": "root",
                "path": source,
            },
            "source_backup": "/usr/local/sbin/.host-health-watch.q27.baseline.bak",
            "staging": staging,
            "state": "/root/.local/state/host-health-watch/state.json",
            "state_backup": "/root/.local/state/host-health-watch/state.json.q27.pre-activation.bak",
        }
    raise DryRunRefusal("unknown host")


def validate_manifest(manifest: dict) -> None:
    if type(manifest) is not dict:
        raise DryRunRefusal("manifest is not an object")
    host = manifest.get("host")
    if type(host) is not str:
        raise DryRunRefusal("manifest host is missing or wrong-typed")
    expected = _expected_manifest(host)
    actual_bytes = json.dumps(manifest, sort_keys=True, separators=(",", ":"))
    expected_bytes = json.dumps(expected, sort_keys=True, separators=(",", ":"))
    if actual_bytes != expected_bytes:
        raise DryRunRefusal("manifest field, nested schema, type, or host-specific fact drift")


PROBE_EFFECT_KEYS = (
    "sender_import",
    "sample",
    "migration",
    "state_write",
    "notification",
)


class SyntheticDeployment:
    """One host-health plan interpreter restricted to an explicit temp root."""

    def __init__(self, manifest: dict, temp_root: Path):
        validate_manifest(manifest)
        self.manifest = manifest
        self.root = temp_root.resolve()
        if str(self.root) == "/":
            raise DryRunRefusal("live root refused")
        self.effects = {name: 0 for name in PROBE_EFFECT_KEYS}

    def path(self, key: str) -> Path:
        value = self.manifest[key]
        if key == "source":
            value = value["path"]
        return map_absolute(self.root, value)

    def verify_baseline(self) -> None:
        source = self.path("source")
        actual = sha256_bytes(source.read_bytes())
        if actual != self.manifest["baseline_sha256"]:
            raise DryRunRefusal("active baseline hash drift")

    def verify_staged(self) -> None:
        candidate_hash = self.manifest["candidate_sha256"]
        if candidate_hash is None:
            raise DryRunRefusal("no independently accepted candidate hash")
        staged = self.path("staging")
        if sha256_bytes(staged.read_bytes()) != candidate_hash:
            raise DryRunRefusal("staged candidate hash mismatch")

    def compare_reviewed_bytes(self, reviewed: bytes) -> None:
        staged = self.path("staging")
        if staged.read_bytes() != reviewed:
            raise DryRunRefusal("staged bytes differ from reviewed bytes")

    def no_send_probe(self) -> None:
        """Execute the exact staged argv and verify instrumented zero effects."""
        self.verify_staged()
        staged = self.path("staging")
        if staged.stat().st_mode & 0o111 == 0:
            raise DryRunRefusal("staged probe is not executable")
        manifest_argv = self.manifest["probe"]["argv"]
        argv = [str(map_absolute(self.root, manifest_argv[0])), *manifest_argv[1:]]
        if argv != [str(staged), "--probe-once"]:
            raise DryRunRefusal("probe argv does not select exact staged path")
        state = self.path("state")
        before_state = state.read_bytes() if state.exists() else None
        effect_dir = self.root / ".q27-probe-effects"
        if effect_dir.exists():
            raise DryRunRefusal("probe effect directory was not clean")
        environment = {
            "HOME": str(self.root / ".probe-home"),
            "PATH": os.defpath,
            "Q27_EFFECT_DIR": str(effect_dir),
            "Q27_STATE_PATH": str(state),
        }
        try:
            result = subprocess.run(
                argv,
                cwd=self.root,
                env=environment,
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
            )
        except (OSError, subprocess.SubprocessError) as exc:
            raise DryRunRefusal(f"staged probe execution failed: {exc}") from exc
        if result.returncode != 0 or result.stderr:
            raise DryRunRefusal(
                f"staged probe failed: return={result.returncode} stderr={result.stderr!r}"
            )
        try:
            evidence = json.loads(result.stdout)
        except json.JSONDecodeError as exc:
            raise DryRunRefusal("staged probe emitted invalid evidence") from exc
        expected = {
            "effects": {name: 0 for name in PROBE_EFFECT_KEYS},
            "probe": "ok",
        }
        if evidence != expected:
            raise DryRunRefusal("staged probe did not report exact zero effects")
        if effect_dir.exists() and any(effect_dir.iterdir()):
            raise DryRunRefusal("staged probe touched an effect hook")
        after_state = state.read_bytes() if state.exists() else None
        if after_state != before_state:
            raise DryRunRefusal("staged probe changed state")
        if any(self.effects.values()):
            raise DryRunRefusal("probe entered a deployment effect path")

    def inspect_state_migration_under_lock(
        self,
        migrate: Callable[[bytes], bytes],
    ) -> bytes:
        """Inspect deterministic migration separately, without writing state."""
        state = self.path("state")
        before = state.read_bytes()
        with exclusive_nonblocking(self.path("lock")) as acquired:
            if not acquired:
                raise DryRunRefusal("host watcher lock is held")
            first = migrate(before)
            second = migrate(before)
            if type(first) is not bytes or first != second:
                raise DryRunRefusal("state migration inspection is nondeterministic")
            if state.read_bytes() != before:
                raise DryRunRefusal("state migration inspection wrote state")
            return first

    def activate_under_lock(self, reviewed: bytes) -> None:
        if self.manifest["activation"]["permitted"] is not True:
            raise DryRunRefusal("activation lacks explicit approval")
        lock = self.path("lock")
        with exclusive_nonblocking(lock) as acquired:
            if not acquired:
                raise DryRunRefusal("host watcher lock is held")
            self.verify_baseline()
            self.verify_staged()
            self.compare_reviewed_bytes(reviewed)
            source = self.path("source")
            source_backup = self.path("source_backup")
            state = self.path("state")
            state_backup = self.path("state_backup")
            atomic_write(source_backup, source.read_bytes(), int(self.manifest["source"]["mode"], 8))
            if state.exists():
                atomic_write(state_backup, state.read_bytes(), 0o600)
            atomic_write(source, reviewed, int(self.manifest["source"]["mode"], 8))
            self.effects["state_write"] += 1

    def rollback_source_under_lock(self) -> None:
        lock = self.path("lock")
        with exclusive_nonblocking(lock) as acquired:
            if not acquired:
                raise DryRunRefusal("host watcher lock is held")
            backup = self.path("source_backup")
            if sha256_bytes(backup.read_bytes()) != self.manifest["baseline_sha256"]:
                raise DryRunRefusal("backup baseline hash mismatch")
            atomic_write(
                self.path("source"),
                backup.read_bytes(),
                int(self.manifest["source"]["mode"], 8),
            )
            if sha256_bytes(self.path("source").read_bytes()) != self.manifest["baseline_sha256"]:
                raise DryRunRefusal("rollback baseline verification failed")

    def restore_state_under_lock(self, approved: bool) -> None:
        if not approved:
            raise DryRunRefusal("state rollback needs separate destructive approval")
        lock = self.path("lock")
        with exclusive_nonblocking(lock) as acquired:
            if not acquired:
                raise DryRunRefusal("host watcher lock is held")
            atomic_write(self.path("state"), self.path("state_backup").read_bytes(), 0o600)
