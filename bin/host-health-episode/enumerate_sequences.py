#!/usr/bin/env python3
"""Deterministic bounded exhaustive evidence for the q27 pure oracle."""

from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass, replace
from enum import Enum
import hashlib
import itertools
import json
from pathlib import Path
import sys
import time

import oracle

MAX_STEPS = 25_000_000
A = ("load",)
B = ("load", "swap")
EVENTS = (
    ("H", oracle.Observation.healthy()),
    ("A", oracle.Observation.unhealthy("load")),
    ("B", oracle.Observation.unhealthy("load", "swap")),
    ("X", oracle.Observation.unknown()),
)
SENDER_SCRIPTS = ("all_success", "first_fail_then_success", "all_fail")
ELAPSED_BUCKETS = (
    ("rollback", -1),
    ("zero", 0),
    ("14:59", 899),
    ("15:00", 900),
    ("15:01", 901),
    ("5:59:59", 21_599),
    ("6:00:00", 21_600),
    ("6:00:01", 21_601),
)
PENDING_VALUES = (None,) + tuple(oracle.NotificationKind)


@dataclass(frozen=True)
class Seed:
    name: str
    state: oracle.State
    first_now: int


class StepBudget:
    def __init__(self, predicted: int):
        if predicted > MAX_STEPS:
            raise RuntimeError(
                f"refusing enumeration: predicted {predicted} steps exceeds {MAX_STEPS}"
            )
        self.predicted = predicted
        self.actual = 0

    def count(self):
        self.actual += 1
        if self.actual > MAX_STEPS:
            raise RuntimeError(f"hard transition-step limit exceeded at {self.actual}")


def qmap(**overrides: int) -> dict[str, int]:
    values = {name: 0 for name in oracle.CONDITIONS}
    values.update(overrides)
    return values


def canonical_seeds() -> tuple[Seed, ...]:
    minus_one = {
        name: oracle.QUALIFICATION_THRESHOLDS[name] - 1
        for name in oracle.CONDITIONS
    }
    failed_initial = oracle.open_unannounced_state(A, last_failed_attempt_at=100_000)
    reminder = oracle.open_announced_state(
        A,
        now=100_000,
        last_incident_delivery_at=100_000,
    )
    pending_b = oracle.open_announced_state(
        A,
        now=100_000,
        qualification=qmap(load=5, swap=5),
        pending_change_signature=B,
        pending_change_count=1,
    )
    material_boundary = oracle.open_announced_state(
        A,
        now=100_000,
        last_material_delivery_at=100_000,
        qualification=qmap(load=5, swap=5),
        pending_change_signature=B,
        pending_change_count=1,
    )
    return (
        Seed("uncertain", oracle.uncertain_state(), 100_000),
        Seed("closed-empty", oracle.closed_state(), 100_000),
        Seed("closed-all-threshold-minus-one", oracle.closed_state(minus_one), 100_000),
        Seed("open-unannounced-no-attempt", oracle.open_unannounced_state(A), 100_000),
        Seed("open-unannounced-failed-14:59", failed_initial, 100_899),
        Seed("open-announced-reminder-5:59:59", reminder, 121_599),
        Seed("open-announced-pending-B-one", pending_b, 100_000),
        Seed("open-announced-material-14:59", material_boundary, 100_899),
        Seed(
            "recovery-pending-failed-14:59",
            oracle.recovery_pending_state(
                A,
                last_failed_attempt_at=100_000,
                last_incident_delivery_at=90_000,
            ),
            100_899,
        ),
    )


def sender_offer(script: str, attempts: int) -> oracle.SenderResult:
    if script == "all_success":
        return oracle.SenderResult.OK
    if script == "all_fail":
        return oracle.SenderResult.FAILED
    return oracle.SenderResult.FAILED if attempts == 0 else oracle.SenderResult.OK


def state_key(state: oracle.State) -> str:
    pending = state.pending_notification
    return "/".join(
        (
            state.phase.value,
            "".join(str(value) for value in state.qualification),
            ",".join(state.announced_signature or ()),
            ",".join(state.pending_change_signature or ()),
            str(state.pending_change_count),
            str(state.healthy_run),
            str(state.last_incident_delivery_at),
            str(state.last_material_delivery_at),
            "-"
            if pending is None
            else f"{pending.kind.value}:{','.join(pending.signature or ())}:{pending.last_failed_attempt_at}",
        )
    )


def record_step(
    budget: StepBudget,
    transitions: Counter,
    invariants: Counter,
    ids: tuple[str, ...],
):
    budget.count()
    transitions.update(ids)
    # This counts the one unconditional post-transition bundle call in step().
    # Individual clause counts below are derived from successful return through
    # that bundle; they are not represented as independently instrumented hooks.
    invariants["unconditional_bundle_calls"] += 1


def predicted_counts() -> dict[str, int]:
    traces_per_seed_script = sum(4**length for length in range(9))
    steps_per_seed_script = sum(length * 4**length for length in range(9))
    observation_traces = 9 * 3 * traces_per_seed_script
    observation_steps = 9 * 3 * steps_per_seed_script
    matrix_cases = len(oracle.Phase) * len(PENDING_VALUES) * 3 * 8 * 2 * 4
    legal_pairs = 7
    matrix_steps = legal_pairs * 3 * 8 * 2 * 4
    full_threshold_steps = sum(oracle.QUALIFICATION_THRESHOLDS.values()) * 3
    return {
        "traces_per_seed_sender": traces_per_seed_script,
        "observation_traces": observation_traces,
        "observation_steps": observation_steps,
        "boundary_cases": matrix_cases,
        "boundary_valid_transition_cases": matrix_steps,
        "boundary_invalid_pair_refusals": matrix_cases - matrix_steps,
        "boundary_steps": matrix_steps,
        "full_threshold_steps": full_threshold_steps,
        "total_steps": observation_steps + matrix_steps + full_threshold_steps,
    }


def enumerate_observations(
    seeds: tuple[Seed, ...],
    budget: StepBudget,
    transitions: Counter,
    invariants: Counter,
    digest,
) -> int:
    trace_count = 0
    for seed in seeds:
        for script in SENDER_SCRIPTS:
            for length in range(9):
                for event_indexes in itertools.product(range(len(EVENTS)), repeat=length):
                    state = seed.state
                    attempts = 0
                    trace_ids: list[str] = []
                    intent_codes: list[str] = []
                    for position, event_index in enumerate(event_indexes):
                        code, observation = EVENTS[event_index]
                        offer = sender_offer(script, attempts)
                        state, intents, ids = oracle.step(
                            state,
                            observation,
                            seed.first_now + position * 60,
                            offer,
                        )
                        record_step(budget, transitions, invariants, ids)
                        trace_ids.extend(ids)
                        if intents:
                            attempts += 1
                            intent_codes.append(f"{position}:{intents[0].kind.value}:{offer.value}")
                    digest.update(
                        (
                            f"OBS|{seed.name}|{script}|"
                            f"{''.join(EVENTS[index][0] for index in event_indexes)}|"
                            f"{state_key(state)}|{','.join(trace_ids)}|{','.join(intent_codes)}\n"
                        ).encode()
                    )
                    trace_count += 1
    return trace_count


def pending_for(kind: oracle.NotificationKind, anchor: int):
    signature = None if kind is oracle.NotificationKind.RECOVERY else A
    if kind is oracle.NotificationKind.CHANGE:
        signature = B
    return oracle.PendingNotification(kind, signature, anchor)


def matrix_state(phase: oracle.Phase, pending_kind, anchor: int) -> tuple[oracle.State, bool]:
    valid = False
    if phase is oracle.Phase.UNCERTAIN:
        state = oracle.uncertain_state()
        valid = pending_kind is None
    elif phase is oracle.Phase.CLOSED:
        state = oracle.closed_state()
        valid = pending_kind is None
    elif phase is oracle.Phase.OPEN_UNANNOUNCED:
        state = oracle.open_unannounced_state(A, last_failed_attempt_at=anchor)
        valid = pending_kind is oracle.NotificationKind.INITIAL
    elif phase is oracle.Phase.OPEN_ANNOUNCED:
        if pending_kind is oracle.NotificationKind.CHANGE:
            state = oracle.open_announced_state(
                A,
                now=anchor,
                last_material_delivery_at=anchor - oracle.RETRY_SECONDS,
                qualification=qmap(load=5, swap=5),
                pending_change_signature=B,
                pending_change_count=2,
                pending_notification=pending_for(pending_kind, anchor),
            )
            valid = True
        elif pending_kind is oracle.NotificationKind.REMINDER:
            state = oracle.open_announced_state(
                A,
                now=anchor - oracle.REMINDER_SECONDS,
                pending_notification=pending_for(pending_kind, anchor),
            )
            valid = True
        else:
            state = oracle.open_announced_state(A, now=anchor)
            valid = pending_kind is None
    else:
        state = oracle.recovery_pending_state(
            A,
            last_failed_attempt_at=anchor,
            last_incident_delivery_at=anchor,
        )
        valid = pending_kind is oracle.NotificationKind.RECOVERY

    if valid:
        return state, True
    if pending_kind is None:
        return replace(state, pending_notification=None), False
    # Create the exact illegal phase/intent pair without calling a validating helper.
    illegal = replace(state, pending_notification=pending_for(pending_kind, anchor))
    return illegal, False


def enumerate_boundary_matrix(
    budget: StepBudget,
    transitions: Counter,
    invariants: Counter,
    digest,
) -> tuple[int, int]:
    anchor = 100_000
    cases = 0
    refusals = 0
    observation_classes = (
        ("X", oracle.Observation.unknown()),
        ("H", oracle.Observation.healthy()),
        ("U", None),
    )
    for phase, pending_kind, (elapsed_name, elapsed), (obs_name, base_observation), result, restart_mask in itertools.product(
        oracle.Phase,
        PENDING_VALUES,
        ELAPSED_BUCKETS,
        observation_classes,
        oracle.SenderResult,
        range(4),
    ):
        cases += 1
        state, valid = matrix_state(phase, pending_kind, anchor)
        label = (
            f"BOUND|{phase.value}|{getattr(pending_kind, 'value', 'none')}|"
            f"{obs_name}|{elapsed_name}|{result.value}|restart={restart_mask}"
        )
        if not valid:
            try:
                oracle.assert_valid_state(state)
            except oracle.ModelError:
                refusals += 1
                digest.update(f"{label}|REFUSED\n".encode())
                continue
            raise AssertionError(f"invalid matrix pair was accepted: {label}")
        if restart_mask & 1:
            state = oracle.state_from_json(oracle.state_to_json(state))
        observation = base_observation
        if observation is None:
            observation = (
                oracle.Observation.unhealthy("load", "swap")
                if pending_kind is oracle.NotificationKind.CHANGE
                else oracle.Observation.unhealthy("load")
            )
        after, intents, ids = oracle.step(state, observation, anchor + elapsed, result)
        record_step(budget, transitions, invariants, ids)
        if restart_mask & 2:
            serialized = oracle.state_to_json(after)
            after = oracle.state_from_json(serialized)
            if oracle.state_to_json(after) != serialized:
                raise AssertionError("boundary restart serialization was not stable")
        digest.update(
            f"{label}|{state_key(after)}|{','.join(ids)}|{','.join(i.kind.value for i in intents)}\n".encode()
        )
    return cases, refusals


def enumerate_full_thresholds(
    budget: StepBudget,
    transitions: Counter,
    invariants: Counter,
    digest,
) -> int:
    steps = 0
    for script in SENDER_SCRIPTS:
        for condition in oracle.CONDITIONS:
            state = oracle.closed_state()
            attempts = 0
            all_ids: list[str] = []
            for index in range(oracle.QUALIFICATION_THRESHOLDS[condition]):
                offer = sender_offer(script, attempts)
                state, intents, ids = oracle.step(
                    state,
                    oracle.Observation.unhealthy(condition),
                    200_000 + index * 60,
                    offer,
                )
                if intents:
                    attempts += 1
                record_step(budget, transitions, invariants, ids)
                all_ids.extend(ids)
                steps += 1
            digest.update(
                f"FULL|{script}|{condition}|{state_key(state)}|{','.join(all_ids)}\n".encode()
            )
    return steps


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    counts = predicted_counts()
    budget = StepBudget(counts["total_steps"])
    transitions: Counter[str] = Counter()
    invariants: Counter[str] = Counter()
    digest = hashlib.sha256()
    started = time.monotonic()
    seeds = canonical_seeds()
    if len(seeds) != 9:
        raise AssertionError("canonical seed count changed")
    observed_traces = enumerate_observations(seeds, budget, transitions, invariants, digest)
    matrix_cases, refusals = enumerate_boundary_matrix(
        budget, transitions, invariants, digest
    )
    full_steps = enumerate_full_thresholds(
        budget, transitions, invariants, digest
    )
    if observed_traces != counts["observation_traces"]:
        raise AssertionError("observation trace count mismatch")
    if matrix_cases != counts["boundary_cases"] or refusals != counts["boundary_invalid_pair_refusals"]:
        raise AssertionError("boundary matrix count mismatch")
    if full_steps != counts["full_threshold_steps"]:
        raise AssertionError("full-threshold count mismatch")
    if budget.actual != counts["total_steps"]:
        raise AssertionError(
            f"step count mismatch: actual={budget.actual} predicted={counts['total_steps']}"
        )
    missing = sorted(set(oracle.ALL_TRANSITION_IDS) - set(transitions))
    extra = sorted(set(transitions) - set(oracle.ALL_TRANSITION_IDS))
    result = {
        "schema_version": 1,
        "algorithm": "deterministic lexical itertools.product; no random sampling",
        "event_order": [code for code, _ in EVENTS],
        "sender_scripts": list(SENDER_SCRIPTS),
        "seed_names": [seed.name for seed in seeds],
        "counts": counts,
        "actual_steps": budget.actual,
        "hard_step_limit": MAX_STEPS,
        "trace_sha256": digest.hexdigest(),
        "transition_id_hits": dict(sorted(transitions.items())),
        "transition_coverage": {
            "defined": len(oracle.ALL_TRANSITION_IDS),
            "hit": len(set(transitions) & set(oracle.ALL_TRANSITION_IDS)),
            "percent": 100.0 if not missing and not extra else None,
            "missing": missing,
            "unexpected": extra,
        },
        "invariant_accounting": {
            "method": (
                "static call-site accounting: every successful step returned through "
                "the single unconditional _assert_transition_invariants call; no "
                "independent per-clause instrumentation"
            ),
            "unconditional_bundle_calls": invariants["unconditional_bundle_calls"],
            "clause_ids": list(oracle.INVARIANT_IDS),
            "derived_successful_reaches_per_clause": {
                invariant_id: invariants["unconditional_bundle_calls"]
                for invariant_id in oracle.INVARIANT_IDS
            },
        },
        "intentionally_unreachable_defensive_branches": [
            "OPEN_ANNOUNCED carrying initial or recovery pending intent is rejected by strict state validation"
        ],
        "runtime_seconds": round(time.monotonic() - started, 3),
        "verdict": "pass" if not missing and not extra else "blocked",
    }
    rendered = json.dumps(result, sort_keys=True, indent=2) + "\n"
    if args.output:
        args.output.write_text(rendered, encoding="utf-8")
    print(rendered, end="")
    return 0 if result["verdict"] == "pass" else 2


if __name__ == "__main__":
    raise SystemExit(main())
