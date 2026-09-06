from __future__ import annotations

import copy
import fcntl
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import oracle
from tests import support


PACKAGE = Path(__file__).resolve().parents[1]
MANIFESTS = PACKAGE / "deployment-manifests"


def synthetic_probe_bytes() -> bytes:
    source = f'''#!{sys.executable}
import json
import os
from pathlib import Path
import sys

keys = {support.PROBE_EFFECT_KEYS!r}
effects = {{name: 0 for name in keys}}

def hit(name):
    effects[name] += 1
    root = Path(os.environ["Q27_EFFECT_DIR"])
    root.mkdir(parents=True, exist_ok=True)
    (root / name).write_text("effect", encoding="utf-8")

def load_sender(): hit("sender_import")
def sample(): hit("sample")
def migrate(): hit("migration")
def write_state(): hit("state_write")
def notify(): hit("notification")

if sys.argv[1:] != ["--probe-once"]:
    raise SystemExit(64)
print(json.dumps({{"effects": effects, "probe": "ok"}}, sort_keys=True))
'''
    return source.encode("utf-8")


class AtomicPersistenceCase(unittest.TestCase):
    def test_atomic_permissions_and_forced_write_failures_leave_complete_state(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            path = root / "state" / "state.json"
            prior = oracle.state_to_json(oracle.closed_state()).encode()
            next_bytes = oracle.state_to_json(oracle.open_announced_state(("load",), now=1)).encode()
            support.atomic_write(path, prior)
            self.assertEqual(path.read_bytes(), prior)
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)
            self.assertEqual(path.parent.stat().st_mode & 0o777, 0o700)
            with self.assertRaisesRegex(OSError, "before replace"):
                support.atomic_write(path, next_bytes, fail_stage="before_replace")
            self.assertEqual(path.read_bytes(), prior)
            oracle.state_from_json(path.read_text())
            with self.assertRaisesRegex(OSError, "after replace"):
                support.atomic_write(path, next_bytes, fail_stage="after_replace")
            self.assertEqual(path.read_bytes(), next_bytes)
            oracle.state_from_json(path.read_text())
            self.assertEqual(list(path.parent.glob(f".{path.name}.*")), [])

    def test_synchronized_losing_lock_contender_has_zero_effects(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            lock_path = root / "lock"
            effects = root / "loser-effects"
            state_path = root / "state.json"
            lock_fd = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
            fcntl.flock(lock_fd, fcntl.LOCK_EX)
            code = r'''
import fcntl, os, pathlib, sys
lock = pathlib.Path(sys.argv[1])
effects = pathlib.Path(sys.argv[2])
fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
try:
    try:
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        raise SystemExit(75)
    effects.write_text("sample send migrate write", encoding="utf-8")
finally:
    os.close(fd)
'''
            result = subprocess.run(
                [sys.executable, "-c", code, str(lock_path), str(effects)],
                check=False,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 75, result.stderr)
            self.assertFalse(effects.exists())
            self.assertFalse(state_path.exists())
            fcntl.flock(lock_fd, fcntl.LOCK_UN)
            os.close(lock_fd)

            calls = {"sample": 0, "send": 0, "migrate": 0, "write": 0}

            def transition():
                calls["sample"] += 1
                before = oracle.closed_state({
                    name: (4 if name == "load" else 0) for name in oracle.CONDITIONS
                })
                after, intents, _ = oracle.step(
                    before,
                    oracle.Observation.unhealthy("load"),
                    0,
                    oracle.SenderResult.OK,
                )
                calls["send"] += len(intents)
                calls["write"] += 1
                return oracle.state_to_json(after).encode()

            self.assertTrue(support.admitted_once(lock_path, state_path, transition))
            self.assertEqual(calls, {"sample": 1, "send": 1, "migrate": 0, "write": 1})
            loaded = oracle.state_from_json(state_path.read_text())
            self.assertEqual(loaded.phase, oracle.Phase.OPEN_ANNOUNCED)


class ManifestCase(unittest.TestCase):
    def load(self, host):
        return support.load_manifest(MANIFESTS / f"{host}.json")

    def test_exact_host_facts_canary_order_and_activation_disabled(self):
        lalo = self.load("lalo-dev")
        worker = self.load("worker-1")
        support.validate_manifest(lalo)
        support.validate_manifest(worker)
        self.assertEqual((lalo["canary_order"], worker["canary_order"]), (1, 2))
        self.assertIsNone(lalo["candidate_sha256"])
        self.assertIsNone(worker["candidate_sha256"])
        self.assertFalse(lalo["activation"]["permitted"])
        self.assertFalse(worker["activation"]["permitted"])
        self.assertIn("retain migrated state", lalo["rollback"]["default_state_policy"])

    def test_cross_host_substitution_refused(self):
        lalo = self.load("lalo-dev")
        lalo["source"] = copy.deepcopy(self.load("worker-1")["source"])
        with self.assertRaisesRegex(support.DryRunRefusal, "drift"):
            support.validate_manifest(lalo)
        worker = self.load("worker-1")
        worker["state"] = self.load("lalo-dev")["state"]
        with self.assertRaisesRegex(support.DryRunRefusal, "drift"):
            support.validate_manifest(worker)

    def test_every_q30_named_host_substitution_is_refused(self):
        lalo = self.load("lalo-dev")
        worker = self.load("worker-1")
        substitutions = (
            (("staging",), worker["staging"]),
            (("source_backup",), worker["source_backup"]),
            (("state_backup",), worker["state_backup"]),
            (("scheduler", "invocation"), worker["scheduler"]["invocation"]),
            (("scheduler", "cadence"), worker["scheduler"]["cadence"]),
        )
        for path, value in substitutions:
            with self.subTest(field=".".join(path)):
                damaged = copy.deepcopy(lalo)
                target = damaged
                for component in path[:-1]:
                    target = target[component]
                target[path[-1]] = value
                if path == ("staging",):
                    damaged["probe"]["argv"][0] = value
                with self.assertRaisesRegex(support.DryRunRefusal, "drift"):
                    support.validate_manifest(damaged)

    def test_duplicate_manifest_object_keys_are_refused(self):
        original = (MANIFESTS / "lalo-dev.json").read_text(encoding="utf-8")
        damaged = original.replace('"host": "lalo-dev"', '"host": "lalo-dev", "host": "worker-1"', 1)
        self.assertNotEqual(original, damaged)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lalo-dev.json"
            path.write_text(damaged, encoding="utf-8")
            with self.assertRaisesRegex(support.DryRunRefusal, "duplicate JSON object key"):
                support.load_manifest(path)
        oversized = original.replace('"canary_order": 1', '"canary_order": ' + ("9" * 5000), 1)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "lalo-dev.json"
            path.write_text(oversized, encoding="utf-8")
            with self.assertRaisesRegex(support.DryRunRefusal, "malformed or unreadable"):
                support.load_manifest(path)

    def test_every_manifest_field_and_nested_schema_is_exact(self):
        manifest = self.load("lalo-dev")
        mutations = (
            lambda item: item.update(schema_version=True),
            lambda item: item["source"].update(extra="bad"),
            lambda item: item["scheduler"].update(mutation="allowed"),
            lambda item: item["probe"].update(scope="wrong"),
            lambda item: item["activation"].update(permitted=True),
            lambda item: item["rollback"].update(default_state_policy="restore"),
            lambda item: item["prohibitions"].pop(),
        )
        for index, mutate in enumerate(mutations):
            with self.subTest(mutation=index):
                damaged = copy.deepcopy(manifest)
                mutate(damaged)
                with self.assertRaises(support.DryRunRefusal):
                    support.validate_manifest(damaged)

    def test_temp_root_refuses_live_root(self):
        manifest = self.load("lalo-dev")
        with self.assertRaisesRegex(support.DryRunRefusal, "live root"):
            support.SyntheticDeployment(manifest, Path("/"))

    def test_marker_only_non_executable_probe_is_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.load("lalo-dev")
            deployment = support.SyntheticDeployment(manifest, Path(directory))
            marker_only = b"SYNTHETIC-Q27-PROBE\n"
            support.atomic_write(deployment.path("staging"), marker_only, 0o600)
            deployment.manifest["candidate_sha256"] = support.sha256_bytes(marker_only)
            with self.assertRaisesRegex(support.DryRunRefusal, "not executable"):
                deployment.no_send_probe()

    def test_executed_probe_effect_instrumentation_detects_forbidden_path(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = self.load("lalo-dev")
            deployment = support.SyntheticDeployment(manifest, Path(directory))
            clean = synthetic_probe_bytes()
            bad = clean.replace(
                b'if sys.argv[1:] != ["--probe-once"]:',
                b'hit("sender_import")\nif sys.argv[1:] != ["--probe-once"]:',
            )
            self.assertNotEqual(clean, bad)
            support.atomic_write(deployment.path("staging"), bad, 0o700)
            deployment.manifest["candidate_sha256"] = support.sha256_bytes(bad)
            with self.assertRaisesRegex(support.DryRunRefusal, "zero effects"):
                deployment.no_send_probe()

    def test_temp_root_dry_run_hash_probe_lock_activation_and_rollback(self):
        for host in ("lalo-dev", "worker-1"):
            with self.subTest(host=host), tempfile.TemporaryDirectory() as directory:
                manifest = self.load(host)
                deployment = support.SyntheticDeployment(manifest, Path(directory))
                baseline = f"SYNTHETIC BASELINE {host}\n".encode()
                candidate = synthetic_probe_bytes()
                active = deployment.path("source")
                staged = deployment.path("staging")
                legacy = {
                    "alerted": False,
                    "firing": [],
                    "recover_ok": 0,
                    "streaks": {name: 0 for name in oracle.CONDITIONS},
                }
                old_state = (json.dumps(legacy, sort_keys=True) + "\n").encode()
                support.atomic_write(active, baseline, int(manifest["source"]["mode"], 8))
                support.atomic_write(deployment.path("state"), old_state)

                # The checked-in historical hash cannot match synthetic bytes; inject
                # a test-only expectation only after exact-manifest validation.
                deployment.manifest["baseline_sha256"] = support.sha256_bytes(baseline)
                deployment.verify_baseline()
                support.atomic_write(active, b"drift", int(manifest["source"]["mode"], 8))
                with self.assertRaisesRegex(support.DryRunRefusal, "drift"):
                    deployment.verify_baseline()
                support.atomic_write(active, baseline, int(manifest["source"]["mode"], 8))

                support.atomic_write(staged, candidate, int(manifest["source"]["mode"], 8))
                deployment.manifest["candidate_sha256"] = support.sha256_bytes(candidate)
                deployment.verify_staged()
                deployment.compare_reviewed_bytes(candidate)
                with self.assertRaisesRegex(support.DryRunRefusal, "reviewed"):
                    deployment.compare_reviewed_bytes(candidate + b"different")
                deployment.no_send_probe()
                self.assertEqual(
                    deployment.effects,
                    {name: 0 for name in support.PROBE_EFFECT_KEYS},
                )
                migrated = deployment.inspect_state_migration_under_lock(
                    lambda data: oracle.state_to_json(
                        oracle.load_or_migrate_bytes(data)
                    ).encode()
                )
                self.assertEqual(
                    oracle.state_from_json(migrated.decode()).phase,
                    oracle.Phase.CLOSED,
                )
                self.assertEqual(deployment.path("state").read_bytes(), old_state)

                # Even a complete synthetic stage remains non-activating until the
                # explicit approval fact is added to this in-memory dry-run copy.
                with self.assertRaisesRegex(support.DryRunRefusal, "approval"):
                    deployment.activate_under_lock(candidate)
                deployment.manifest["activation"]["permitted"] = True

                lock = deployment.path("lock")
                lock.parent.mkdir(parents=True, exist_ok=True)
                descriptor = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
                fcntl.flock(descriptor, fcntl.LOCK_EX)
                with self.assertRaisesRegex(support.DryRunRefusal, "lock"):
                    deployment.activate_under_lock(candidate)
                fcntl.flock(descriptor, fcntl.LOCK_UN)
                os.close(descriptor)

                deployment.activate_under_lock(candidate)
                self.assertEqual(active.read_bytes(), candidate)
                self.assertEqual(active.stat().st_mode & 0o777, int(manifest["source"]["mode"], 8))
                self.assertEqual(deployment.path("source_backup").read_bytes(), baseline)
                self.assertEqual(deployment.path("state_backup").read_bytes(), old_state)

                candidate_state = oracle.state_to_json(
                    oracle.open_announced_state(("load",), now=1)
                ).encode()
                support.atomic_write(deployment.path("state"), candidate_state)
                deployment.rollback_source_under_lock()
                self.assertEqual(active.read_bytes(), baseline)
                # Source-only rollback retains the new state by default.
                self.assertEqual(deployment.path("state").read_bytes(), candidate_state)
                with self.assertRaisesRegex(support.DryRunRefusal, "destructive approval"):
                    deployment.restore_state_under_lock(False)
                deployment.restore_state_under_lock(True)
                self.assertEqual(deployment.path("state").read_bytes(), old_state)


if __name__ == "__main__":
    unittest.main()
