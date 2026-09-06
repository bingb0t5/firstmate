#!/usr/bin/env python3
"""Kill the twelve q26 defect classes with temporary candidate adapters.

The accepted oracle is hashed before/after and never edited.  Every mutant is a
single assertion-checked replacement of one placeholder in a fresh temporary module.
"""

from __future__ import annotations

from dataclasses import dataclass, replace
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys
import tempfile
from types import ModuleType
from typing import Callable

import oracle

PACKAGE = Path(__file__).resolve().parent
ORACLE_PATH = PACKAGE / "oracle.py"
TEMPLATE = """from dataclasses import replace
import json
import oracle

__MUTATION_BODY__
"""
PLACEHOLDER = "__MUTATION_BODY__"
A = ("load",)
B = ("load", "swap")
H = oracle.Observation.healthy()
X = oracle.Observation.unknown()
UA = oracle.Observation.unhealthy("load")
UB = oracle.Observation.unhealthy("load", "swap")


@dataclass(frozen=True)
class Mutation:
    number: int
    name: str
    body: str
    killing_trace: str
    kill: Callable[[ModuleType, Path], str]


def module_from_mutation(root: Path, mutation: Mutation) -> ModuleType:
    if TEMPLATE.count(PLACEHOLDER) != 1:
        raise AssertionError("mutation template placeholder is not unique")
    source = TEMPLATE.replace(PLACEHOLDER, mutation.body)
    if PLACEHOLDER in source:
        raise AssertionError("mutation replacement was incomplete")
    path = root / f"mutant_{mutation.number:02d}.py"
    path.write_text(source, encoding="utf-8")
    spec = importlib.util.spec_from_file_location(f"q27_mutant_{mutation.number:02d}", path)
    if spec is None or spec.loader is None:
        raise AssertionError("could not load temporary mutant")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def kill_recovery_from_empty(module, _root):
    state = oracle.open_announced_state(A, now=0, qualification=qmap())
    expected1 = oracle.step(state, UB, 60, oracle.SenderResult.OK)
    actual1 = module.mutant_step(state, UB, 60, oracle.SenderResult.OK)
    expected2 = oracle.step(expected1[0], UB, 120, oracle.SenderResult.OK)
    actual2 = module.mutant_step(actual1[0], UB, 120, oracle.SenderResult.OK)
    if actual2 == expected2:
        raise AssertionError("mutant survived raw-unhealthy empty-qualified trace")
    return "open A -> raw U(B) below qualification -> raw U(B): mutant fabricated recovery"


def kill_unknown_healthy(module, _root):
    state = oracle.open_announced_state(A, now=0, healthy_run=1, qualification=qmap())
    expected = oracle.step(state, X, 60, oracle.SenderResult.OK)
    actual = module.mutant_step(state, X, 60, oracle.SenderResult.OK)
    if actual == expected:
        raise AssertionError("mutant survived unknown recovery-break trace")
    return "open A with healthy_run=1 -> X: mutant preserved/advanced recovery evidence"


def kill_unknown_material(module, _root):
    state = oracle.open_announced_state(
        A,
        now=0,
        qualification=qmap(load=5, swap=5),
        pending_change_signature=B,
        pending_change_count=1,
    )
    expected = oracle.step(state, X, 60, None)
    actual = module.mutant_step(state, X, 60, None)
    if actual == expected:
        raise AssertionError("mutant survived unknown material-break trace")
    return "open A pending B(1) -> X: mutant retained material proof"


def kill_failure_delivery(module, _root):
    state = oracle.closed_state(qmap(load=4))
    expected = oracle.step(state, UA, 0, oracle.SenderResult.FAILED)
    actual = module.mutant_step(state, UA, 0, oracle.SenderResult.FAILED)
    if actual == expected:
        raise AssertionError("mutant survived sender-failure trace")
    return "threshold initial with FAILED sender: mutant recorded successful delivery"


def kill_episode_tied_to_delivery(module, _root):
    state = oracle.closed_state(qmap(load=4))
    expected = oracle.step(state, UA, 0, oracle.SenderResult.FAILED)
    actual = module.mutant_step(state, UA, 0, oracle.SenderResult.FAILED)
    if actual == expected or actual[0].phase is not oracle.Phase.CLOSED:
        raise AssertionError("mutant survived open-unannounced trace")
    return "failed initial: mutant closed the episode instead of OPEN_UNANNOUNCED"


def kill_stale_reminder_anchor(module, _root):
    state = oracle.open_announced_state(
        A,
        now=0,
        last_incident_delivery_at=0,
        qualification=qmap(load=5, swap=5),
        pending_change_signature=B,
        pending_change_count=1,
    )
    expected = oracle.step(state, UB, 21_600, oracle.SenderResult.OK)
    actual = module.mutant_step(state, UB, 21_600, oracle.SenderResult.OK)
    if actual == expected:
        raise AssertionError("mutant survived material anchor trace")
    try:
        oracle.assert_valid_state(actual[0])
    except oracle.ModelError:
        return "successful material with stale incident anchor: strict anchor invariant rejected mutant"
    _, expected_next, _ = oracle.step(expected[0], UB, 21_660, oracle.SenderResult.OK)
    _, actual_next, _ = module.mutant_step(actual[0], UB, 21_660, oracle.SenderResult.OK)
    if expected_next or not actual_next:
        raise AssertionError("stale-anchor trace did not distinguish reminder behavior")
    return "successful material at 6h -> same next minute: mutant emitted stale-anchor reminder"


def kill_immediate_material(module, _root):
    state = oracle.open_announced_state(A, now=0, qualification=qmap(load=5, swap=4))
    expected = oracle.step(state, UB, 60, oracle.SenderResult.OK)
    actual = module.mutant_step(state, UB, 60, oracle.SenderResult.OK)
    if actual == expected or not actual[1]:
        raise AssertionError("mutant survived first changed-signature observation")
    return "open A with swap threshold-minus-one -> first qualified B: mutant sent immediately"


def kill_no_retry_floor(module, _root):
    state = oracle.open_unannounced_state(A, last_failed_attempt_at=0)
    expected = oracle.step(state, UA, 899, oracle.SenderResult.OK)
    actual = module.mutant_step(state, UA, 899, oracle.SenderResult.OK)
    if actual == expected or not actual[1]:
        raise AssertionError("mutant survived 14:59 failed-retry boundary")
    return "failed initial -> valid unhealthy at 14:59: mutant retried before 15:00"


def kill_truthy_boolean(module, _root):
    baseline = {
        "alerted": "false",
        "firing": ["load"],
        "recover_ok": 0,
        "streaks": qmap(load=5),
    }
    expected = oracle.load_or_migrate_text(json.dumps(baseline))
    actual = module.mutant_load(json.dumps(baseline))
    if actual == expected or actual.phase is not oracle.Phase.OPEN_ANNOUNCED:
        raise AssertionError("mutant survived string-boolean migration")
    return 'baseline alerted="false" with firing load: mutant truthiness fabricated announced episode'


def kill_unreadable_latch(module, _root):
    state = module.mutant_load("{")
    expected = oracle.step(state, H, 60, None)
    actual = module.mutant_step(state, H, 60, None)
    if actual == expected or actual[0].phase is not oracle.Phase.UNCERTAIN:
        raise AssertionError("mutant survived unreadable-state liveness trace")
    return "unreadable -> valid H: mutant remained permanently UNCERTAIN"


def kill_restart_drops_dedup(module, _root):
    state = oracle.open_announced_state(A, now=21_600)
    expected_state = oracle.state_from_json(oracle.state_to_json(state))
    actual_state = module.mutant_reload(state)
    expected = oracle.step(expected_state, UA, 21_660, oracle.SenderResult.OK)
    actual = oracle.step(actual_state, UA, 21_660, oracle.SenderResult.OK)
    if actual == expected or not actual[1]:
        raise AssertionError("mutant survived restart dedup trace")
    return "restart one minute after delivery: mutant dropped incident anchor and reminded"


def kill_losing_lock(module, root):
    root.mkdir(parents=True, exist_ok=True)
    lock_path = root / "lock"
    effects = root / "effects"
    descriptor = os.open(lock_path, os.O_RDWR | os.O_CREAT, 0o600)
    fcntl.flock(descriptor, fcntl.LOCK_EX)
    try:
        module.mutant_contender(lock_path, effects)
    finally:
        fcntl.flock(descriptor, fcntl.LOCK_UN)
        os.close(descriptor)
    if not effects.exists():
        raise AssertionError("mutant survived synchronized lock trace")
    return "lock held by process one: mutant losing contender entered sample/send/migrate/write"


def qmap(**overrides):
    values = {name: 0 for name in oracle.CONDITIONS}
    values.update(overrides)
    return values


MUTATIONS = (
    Mutation(
        1,
        "recovery-from-empty-qualified-set",
        '''def mutant_step(state, observation, now, result):
    if state.phase is oracle.Phase.OPEN_ANNOUNCED and observation.kind is oracle.ObservationKind.KNOWN_UNHEALTHY:
        q = oracle._advance_qualification(state, observation)
        if not oracle.qualified_signature(q):
            return oracle.step(state, oracle.Observation.healthy(), now, result)
    return oracle.step(state, observation, now, result)
''',
        "q25 raw-unhealthy after reset",
        kill_recovery_from_empty,
    ),
    Mutation(
        2,
        "unknown-preserves-or-advances-healthy-run",
        '''def mutant_step(state, observation, now, result):
    if observation.kind is oracle.ObservationKind.UNKNOWN and state.phase is oracle.Phase.OPEN_ANNOUNCED:
        return oracle.step(state, oracle.Observation.healthy(), now, result)
    return oracle.step(state, observation, now, result)
''',
        "open healthy_run one then unknown",
        kill_unknown_healthy,
    ),
    Mutation(
        3,
        "unknown-preserves-pending-material-count",
        '''def mutant_step(state, observation, now, result):
    answer = oracle.step(state, observation, now, result)
    if observation.kind is oracle.ObservationKind.UNKNOWN and state.pending_change_count:
        changed = replace(answer[0], pending_change_signature=state.pending_change_signature, pending_change_count=state.pending_change_count)
        return changed, answer[1], answer[2]
    return answer
''',
        "open A pending B one then unknown",
        kill_unknown_material,
    ),
    Mutation(
        4,
        "sender-failure-recorded-as-delivery",
        '''def mutant_step(state, observation, now, result):
    if result is oracle.SenderResult.FAILED:
        result = oracle.SenderResult.OK
    return oracle.step(state, observation, now, result)
''',
        "failed threshold initial",
        kill_failure_delivery,
    ),
    Mutation(
        5,
        "episode-existence-tied-to-delivery-success",
        '''def mutant_step(state, observation, now, result):
    answer = oracle.step(state, observation, now, result)
    if answer[1] and answer[1][0].kind is oracle.NotificationKind.INITIAL and result is oracle.SenderResult.FAILED:
        return oracle.closed_state(), answer[1], answer[2]
    return answer
''',
        "failed initial remains open-unannounced",
        kill_episode_tied_to_delivery,
    ),
    Mutation(
        6,
        "reminder-anchored-to-stale-delivery",
        '''def mutant_step(state, observation, now, result):
    answer = oracle.step(state, observation, now, result)
    if answer[1] and answer[1][0].kind is oracle.NotificationKind.CHANGE and result is oracle.SenderResult.OK:
        changed = replace(answer[0], last_incident_delivery_at=state.last_incident_delivery_at)
        return changed, answer[1], answer[2]
    return answer
''',
        "reminder/material/same-next-minute",
        kill_stale_reminder_anchor,
    ),
    Mutation(
        7,
        "immediate-material-change",
        '''def mutant_step(state, observation, now, result):
    if state.phase is oracle.Phase.OPEN_ANNOUNCED and observation.kind is oracle.ObservationKind.KNOWN_UNHEALTHY:
        q = oracle._advance_qualification(state, observation)
        signature = oracle.qualified_signature(q)
        if signature and signature != state.announced_signature and state.pending_change_count == 0:
            state = replace(
                state,
                qualification=q,
                pending_change_signature=signature,
                pending_change_count=1,
            )
    return oracle.step(state, observation, now, result)
''',
        "first qualified B observation",
        kill_immediate_material,
    ),
    Mutation(
        8,
        "no-fifteen-minute-failed-send-floor",
        '''def mutant_step(state, observation, now, result):
    if state.pending_notification is not None and state.pending_notification.last_failed_attempt_at is not None:
        pending = replace(state.pending_notification, last_failed_attempt_at=None)
        state = replace(state, pending_notification=pending)
    return oracle.step(state, observation, now, result)
''',
        "failed initial at 14:59",
        kill_no_retry_floor,
    ),
    Mutation(
        9,
        "truthy-string-boolean-migration",
        '''def mutant_load(text):
    obj = json.loads(text)
    if "schema_version" not in obj and bool(obj.get("alerted")):
        obj["alerted"] = True
    return oracle.migrate_baseline_obj(obj)
''',
        "string false legacy state",
        kill_truthy_boolean,
    ),
    Mutation(
        10,
        "unreadable-state-permanent-latch",
        '''def mutant_load(text):
    return oracle.load_or_migrate_text(text)

def mutant_step(state, observation, now, result):
    if state.phase is oracle.Phase.UNCERTAIN:
        return state, (), ("MUTANT-PERMANENT-LATCH",)
    return oracle.step(state, observation, now, result)
''',
        "unreadable state then valid healthy",
        kill_unreadable_latch,
    ),
    Mutation(
        11,
        "restart-drops-reminder-dedup-state",
        '''def mutant_reload(state):
    obj = oracle.state_to_obj(state)
    obj["last_incident_delivery_at"] = 0
    return oracle.state_from_obj(obj)
''',
        "restart one minute after successful delivery",
        kill_restart_drops_dedup,
    ),
    Mutation(
        12,
        "losing-lock-contender-enters-effects",
        '''def mutant_contender(lock_path, effects_path):
    effects_path.write_text("sample send migrate write", encoding="utf-8")
''',
        "synchronized held fcntl lock",
        kill_losing_lock,
    ),
)


def main() -> int:
    before_hash = hashlib.sha256(ORACLE_PATH.read_bytes()).hexdigest()
    results = []
    with tempfile.TemporaryDirectory(prefix="q27-mutations-") as directory:
        root = Path(directory)
        for mutation in MUTATIONS:
            module = module_from_mutation(root, mutation)
            try:
                detail = mutation.kill(module, root / f"case-{mutation.number:02d}")
            except Exception as exc:
                results.append(
                    {
                        "number": mutation.number,
                        "mutation": mutation.name,
                        "killing_trace": mutation.killing_trace,
                        "status": "SURVIVED_OR_RUNNER_FAILED",
                        "detail": f"{type(exc).__name__}: {exc}",
                    }
                )
            else:
                results.append(
                    {
                        "number": mutation.number,
                        "mutation": mutation.name,
                        "killing_trace": mutation.killing_trace,
                        "status": "KILLED",
                        "detail": detail,
                    }
                )
    after_hash = hashlib.sha256(ORACLE_PATH.read_bytes()).hexdigest()
    if before_hash != after_hash:
        raise AssertionError("accepted oracle changed during mutation run")
    killed = sum(result["status"] == "KILLED" for result in results)
    evidence = {
        "schema_version": 1,
        "oracle_sha256_before": before_hash,
        "oracle_sha256_after": after_hash,
        "temporary_source_replacement_asserted": True,
        "mutants": results,
        "score": f"{killed}/{len(MUTATIONS)}",
        "verdict": "pass" if killed == len(MUTATIONS) == 12 else "blocked",
    }
    print(json.dumps(evidence, sort_keys=True, indent=2))
    return 0 if evidence["verdict"] == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
