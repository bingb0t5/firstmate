#!/usr/bin/env python3
"""Fresh host-health episode model implementation.

This module is a new implementation of the independently accepted offline
episode contract.  It is not a live watcher, has no filesystem/network/host
dependency, and does not revive prior host-health transition code.

Authority for one observation is exactly
``step(state, observation, now, sender_result_if_attempted)``.
"""

from __future__ import annotations

from dataclasses import dataclass, fields, replace
from datetime import datetime, timezone
from enum import Enum
import json
import math
import re
from typing import Any, Callable, Mapping

SCHEMA_VERSION = 1
RETRY_SECONDS = 15 * 60
REMINDER_SECONDS = 6 * 60 * 60
MATERIAL_CONFIRMATIONS = 2
RECOVERY_CONFIRMATIONS = 2
MAX_JSON_NESTING = 512

CONDITIONS = (
    "load",
    "swap",
    "low_memory",
    "disk",
    "inode",
    "zombies",
    "process_count",
)
QUALIFICATION_THRESHOLDS = {
    "load": 5,
    "swap": 5,
    "low_memory": 5,
    "disk": 10,
    "inode": 10,
    "zombies": 5,
    "process_count": 5,
}
CONDITION_INDEX = {name: index for index, name in enumerate(CONDITIONS)}


class Phase(str, Enum):
    UNCERTAIN = "UNCERTAIN"
    CLOSED = "CLOSED"
    OPEN_UNANNOUNCED = "OPEN_UNANNOUNCED"
    OPEN_ANNOUNCED = "OPEN_ANNOUNCED"
    RECOVERY_PENDING = "RECOVERY_PENDING"


class ObservationKind(str, Enum):
    UNKNOWN = "UNKNOWN"
    KNOWN_HEALTHY = "KNOWN_HEALTHY"
    KNOWN_UNHEALTHY = "KNOWN_UNHEALTHY"


class NotificationKind(str, Enum):
    INITIAL = "initial"
    CHANGE = "change"
    REMINDER = "reminder"
    RECOVERY = "recovery"


class SenderResult(str, Enum):
    OK = "OK"
    FAILED = "FAILED"


@dataclass(frozen=True)
class Observation:
    kind: ObservationKind
    breached: tuple[str, ...] = ()

    @staticmethod
    def unknown() -> "Observation":
        return Observation(ObservationKind.UNKNOWN)

    @staticmethod
    def healthy() -> "Observation":
        return Observation(ObservationKind.KNOWN_HEALTHY)

    @staticmethod
    def unhealthy(*breached: str) -> "Observation":
        return Observation(
            ObservationKind.KNOWN_UNHEALTHY,
            canonical_signature(breached),
        )


@dataclass(frozen=True)
class PendingNotification:
    kind: NotificationKind
    signature: tuple[str, ...] | None
    last_failed_attempt_at: int | None


@dataclass(frozen=True)
class NotificationIntent:
    kind: NotificationKind
    signature: tuple[str, ...] | None


@dataclass(frozen=True)
class State:
    schema_version: int
    phase: Phase
    qualification: tuple[int, ...]
    announced_signature: tuple[str, ...] | None
    pending_change_signature: tuple[str, ...] | None
    pending_change_count: int
    healthy_run: int
    last_incident_delivery_at: int | None
    last_material_delivery_at: int | None
    pending_notification: PendingNotification | None


PERSISTED_FIELDS = tuple(field.name for field in fields(State))
EXPECTED_PERSISTED_FIELDS = (
    "schema_version",
    "phase",
    "qualification",
    "announced_signature",
    "pending_change_signature",
    "pending_change_count",
    "healthy_run",
    "last_incident_delivery_at",
    "last_material_delivery_at",
    "pending_notification",
)

INVARIANT_IDS = (
    "INV-01-input-partition",
    "INV-02-unknown-non-action",
    "INV-03-raw-healthy-recovery-witness",
    "INV-04-episode-transport-separation",
    "INV-05-delivery-and-rate-anchors",
    "INV-06-pending-change-continuity",
    "INV-07-restart-field-closure",
    "INV-08-corruption-safe-reentry",
    "INV-09-single-writer-boundary",
    "INV-10-closed-state-hygiene",
)

StepResult = tuple[State, tuple[NotificationIntent, ...], tuple[str, ...]]
PhaseHandler = Callable[
    [State, Observation, int, SenderResult | None],
    StepResult,
]


class ModelError(ValueError):
    """Raised for a caller/model-contract violation."""


def canonical_signature(values: Any) -> tuple[str, ...]:
    """Return one sorted, duplicate-free signature, rejecting unknown categories."""
    try:
        items = tuple(values)
    except TypeError as exc:
        raise ModelError("signature is not iterable") from exc
    if any(type(item) is not str or item not in CONDITION_INDEX for item in items):
        raise ModelError("signature contains an unknown or non-string condition")
    if len(set(items)) != len(items):
        raise ModelError("signature contains duplicates")
    return tuple(sorted(items, key=CONDITION_INDEX.__getitem__))


def _zero_qualification() -> tuple[int, ...]:
    return (0,) * len(CONDITIONS)


def _qualification_tuple(mapping: Mapping[str, int]) -> tuple[int, ...]:
    return tuple(mapping[name] for name in CONDITIONS)


def _default_counters_for(signature: tuple[str, ...]) -> dict[str, int]:
    return {
        name: (QUALIFICATION_THRESHOLDS[name] if name in signature else 0)
        for name in CONDITIONS
    }


def uncertain_state() -> State:
    return State(
        schema_version=SCHEMA_VERSION,
        phase=Phase.UNCERTAIN,
        qualification=_zero_qualification(),
        announced_signature=None,
        pending_change_signature=None,
        pending_change_count=0,
        healthy_run=0,
        last_incident_delivery_at=None,
        last_material_delivery_at=None,
        pending_notification=None,
    )


def closed_state(qualification: Mapping[str, int] | None = None) -> State:
    counters = _zero_qualification()
    if qualification is not None:
        counters = _qualification_tuple(qualification)
    state = replace(uncertain_state(), phase=Phase.CLOSED, qualification=counters)
    assert_valid_state(state)
    return state


def open_unannounced_state(
    signature: tuple[str, ...] = ("load",),
    *,
    last_failed_attempt_at: int | None = None,
    qualification: Mapping[str, int] | None = None,
) -> State:
    signature = canonical_signature(signature)
    if not signature:
        raise ModelError("an unannounced episode needs a non-empty signature")
    counters = _default_counters_for(signature)
    if qualification is not None:
        counters.update(qualification)
    state = State(
        schema_version=SCHEMA_VERSION,
        phase=Phase.OPEN_UNANNOUNCED,
        qualification=_qualification_tuple(counters),
        announced_signature=None,
        pending_change_signature=None,
        pending_change_count=0,
        healthy_run=0,
        last_incident_delivery_at=None,
        last_material_delivery_at=None,
        pending_notification=PendingNotification(
            NotificationKind.INITIAL,
            signature,
            last_failed_attempt_at,
        ),
    )
    assert_valid_state(state)
    return state


def open_announced_state(
    signature: tuple[str, ...] = ("load",),
    *,
    now: int = 0,
    last_incident_delivery_at: int | None = None,
    last_material_delivery_at: int | None = None,
    qualification: Mapping[str, int] | None = None,
    pending_change_signature: tuple[str, ...] | None = None,
    pending_change_count: int = 0,
    pending_notification: PendingNotification | None = None,
    healthy_run: int = 0,
) -> State:
    signature = canonical_signature(signature)
    if not signature:
        raise ModelError("an announced episode needs a non-empty signature")
    counters = _default_counters_for(signature)
    if qualification is not None:
        counters.update(qualification)
    if pending_change_signature is not None:
        pending_change_signature = canonical_signature(pending_change_signature)
    state = State(
        schema_version=SCHEMA_VERSION,
        phase=Phase.OPEN_ANNOUNCED,
        qualification=_qualification_tuple(counters),
        announced_signature=signature,
        pending_change_signature=pending_change_signature,
        pending_change_count=pending_change_count,
        healthy_run=healthy_run,
        last_incident_delivery_at=(
            now if last_incident_delivery_at is None else last_incident_delivery_at
        ),
        last_material_delivery_at=last_material_delivery_at,
        pending_notification=pending_notification,
    )
    assert_valid_state(state)
    return state


def recovery_pending_state(
    signature: tuple[str, ...] = ("load",),
    *,
    last_failed_attempt_at: int = 0,
    last_incident_delivery_at: int = 0,
    last_material_delivery_at: int | None = None,
) -> State:
    signature = canonical_signature(signature)
    state = State(
        schema_version=SCHEMA_VERSION,
        phase=Phase.RECOVERY_PENDING,
        qualification=_zero_qualification(),
        announced_signature=signature,
        pending_change_signature=None,
        pending_change_count=0,
        healthy_run=RECOVERY_CONFIRMATIONS,
        last_incident_delivery_at=last_incident_delivery_at,
        last_material_delivery_at=last_material_delivery_at,
        pending_notification=PendingNotification(
            NotificationKind.RECOVERY,
            None,
            last_failed_attempt_at,
        ),
    )
    assert_valid_state(state)
    return state


def _validate_timestamp(value: int | None, name: str) -> None:
    if value is not None and (type(value) is not int or value < 0):
        raise ModelError(f"{name} must be a non-negative integer or null")


def assert_valid_observation(observation: Observation) -> None:
    if not isinstance(observation, Observation):
        raise ModelError("observation must be an Observation")
    if not isinstance(observation.kind, ObservationKind):
        raise ModelError("invalid observation kind")
    signature = canonical_signature(observation.breached)
    if signature != observation.breached:
        raise ModelError("observation signature is not canonical")
    if observation.kind is not ObservationKind.KNOWN_UNHEALTHY and signature:
        raise ModelError("only KNOWN_UNHEALTHY may carry breached categories")
    if observation.kind is ObservationKind.KNOWN_UNHEALTHY and not signature:
        raise ModelError("KNOWN_UNHEALTHY needs at least one raw breached category")


def assert_valid_state(state: State) -> None:
    if not isinstance(state, State):
        raise ModelError("state must be State")
    if type(state.schema_version) is not int or state.schema_version != SCHEMA_VERSION:
        raise ModelError("unsupported or wrong-typed current schema")
    if not isinstance(state.phase, Phase):
        raise ModelError("invalid phase")
    if type(state.qualification) is not tuple or len(state.qualification) != len(CONDITIONS):
        raise ModelError("qualification must contain every condition exactly once")
    for name, value in zip(CONDITIONS, state.qualification):
        if type(value) is not int or not 0 <= value <= QUALIFICATION_THRESHOLDS[name]:
            raise ModelError(f"invalid qualification counter for {name}")
    for signature, name in (
        (state.announced_signature, "announced_signature"),
        (state.pending_change_signature, "pending_change_signature"),
    ):
        if signature is not None:
            if type(signature) is not tuple or canonical_signature(signature) != signature:
                raise ModelError(f"{name} is not canonical")
    if type(state.pending_change_count) is not int or not 0 <= state.pending_change_count <= 2:
        raise ModelError("pending_change_count is outside 0..2")
    if (state.pending_change_signature is None) != (state.pending_change_count == 0):
        raise ModelError("pending change signature/count disagree")
    if state.pending_change_signature == ():
        raise ModelError("an empty qualified set is not a material-change proof")
    if type(state.healthy_run) is not int or not 0 <= state.healthy_run <= 2:
        raise ModelError("healthy_run is outside 0..2")
    _validate_timestamp(state.last_incident_delivery_at, "last_incident_delivery_at")
    _validate_timestamp(state.last_material_delivery_at, "last_material_delivery_at")
    if (
        state.last_material_delivery_at is not None
        and (
            state.last_incident_delivery_at is None
            or state.last_material_delivery_at > state.last_incident_delivery_at
        )
    ):
        raise ModelError("material delivery anchor is unreachable")
    pending = state.pending_notification
    if pending is not None:
        if not isinstance(pending, PendingNotification) or not isinstance(
            pending.kind, NotificationKind
        ):
            raise ModelError("invalid pending notification")
        _validate_timestamp(pending.last_failed_attempt_at, "last_failed_attempt_at")
        if pending.kind is NotificationKind.RECOVERY:
            if pending.signature is not None:
                raise ModelError("recovery intent cannot carry a signature")
        else:
            if pending.signature is None or not pending.signature:
                raise ModelError("incident intent needs a non-empty signature")
            if canonical_signature(pending.signature) != pending.signature:
                raise ModelError("pending notification signature is not canonical")

    if state.phase is Phase.UNCERTAIN:
        if state != uncertain_state():
            raise ModelError("UNCERTAIN must contain no trusted episode facts")
    elif state.phase is Phase.CLOSED:
        if qualified_signature(state.qualification):
            raise ModelError("closed state contains a threshold-qualified condition")
        if any(
            (
                state.announced_signature is not None,
                state.pending_change_signature is not None,
                state.pending_change_count != 0,
                state.healthy_run != 0,
                state.last_incident_delivery_at is not None,
                state.last_material_delivery_at is not None,
                state.pending_notification is not None,
            )
        ):
            raise ModelError("CLOSED contains episode or delivery residue")
    elif state.phase is Phase.OPEN_UNANNOUNCED:
        if state.announced_signature is not None or state.last_incident_delivery_at is not None:
            raise ModelError("unannounced episode has a delivery acknowledgement")
        if state.last_material_delivery_at is not None:
            raise ModelError("unannounced episode has material delivery residue")
        if state.pending_change_signature is not None or state.pending_change_count:
            raise ModelError("unannounced episode cannot own a material-change proof")
        if pending is None or pending.kind is not NotificationKind.INITIAL:
            raise ModelError("unannounced episode must own its initial intent")
        if state.healthy_run > 1:
            raise ModelError("unannounced episode has unreachable recovery proof")
        current = qualified_signature(state.qualification)
        if current and pending.signature != current:
            raise ModelError("unannounced initial identity contradicts qualification")
        if state.healthy_run and (current or any(state.qualification)):
            raise ModelError("unannounced healthy proof has qualification residue")
    elif state.phase is Phase.OPEN_ANNOUNCED:
        if not state.announced_signature or state.last_incident_delivery_at is None:
            raise ModelError("announced episode lacks delivered identity")
        if state.healthy_run > 1:
            raise ModelError("announced episode has unreachable recovery proof")
        current = qualified_signature(state.qualification)
        if state.pending_change_signature is not None:
            if state.pending_change_signature == state.announced_signature:
                raise ModelError("material proof duplicates announced identity")
            if current != state.pending_change_signature:
                raise ModelError("material proof contradicts qualification")
        elif current and current != state.announced_signature:
            raise ModelError("different qualified identity lacks material proof")
        if state.healthy_run and (
            any(state.qualification)
            or state.pending_change_signature is not None
            or pending is not None
        ):
            raise ModelError("announced healthy proof has incompatible residue")
        if pending is not None:
            if pending.kind not in (
                NotificationKind.CHANGE,
                NotificationKind.REMINDER,
            ):
                raise ModelError("announced episode has the wrong pending intent")
            if pending.last_failed_attempt_at is None:
                raise ModelError("announced pending intent lacks failed-attempt time")
            if pending.kind is NotificationKind.CHANGE:
                if (
                    pending.signature == state.announced_signature
                    or state.pending_change_signature != pending.signature
                    or state.pending_change_count != MATERIAL_CONFIRMATIONS
                    or (
                        state.last_material_delivery_at is not None
                        and pending.last_failed_attempt_at - state.last_material_delivery_at
                        < RETRY_SECONDS
                    )
                ):
                    raise ModelError("failed change intent and material proof disagree")
            elif (
                pending.signature != state.announced_signature
                or state.pending_change_signature is not None
                or state.pending_change_count != 0
                or pending.last_failed_attempt_at - state.last_incident_delivery_at
                < REMINDER_SECONDS
            ):
                raise ModelError("failed reminder identity has incompatible proof")
    elif state.phase is Phase.RECOVERY_PENDING:
        if not state.announced_signature or state.last_incident_delivery_at is None:
            raise ModelError("recovery-pending episode lacks announced identity")
        if state.healthy_run != RECOVERY_CONFIRMATIONS:
            raise ModelError("recovery pending lacks raw healthy witness")
        if state.pending_change_signature is not None or state.pending_change_count:
            raise ModelError("recovery pending has material-change residue")
        if pending is None or pending.kind is not NotificationKind.RECOVERY:
            raise ModelError("recovery pending lacks failed recovery intent")
        if pending.last_failed_attempt_at is None:
            raise ModelError("recovery pending must follow a failed attempt")


def _advance_qualification(state: State, observation: Observation) -> tuple[int, ...]:
    if observation.kind is not ObservationKind.KNOWN_UNHEALTHY:
        return _zero_qualification()
    breached = set(observation.breached)
    return tuple(
        min(value + 1, QUALIFICATION_THRESHOLDS[name]) if name in breached else 0
        for name, value in zip(CONDITIONS, state.qualification)
    )


def qualified_signature(qualification: tuple[int, ...]) -> tuple[str, ...]:
    return tuple(
        name
        for name, value in zip(CONDITIONS, qualification)
        if value >= QUALIFICATION_THRESHOLDS[name]
    )


def _floor_reached(now: int, anchor: int | None, floor: int) -> bool:
    return anchor is None or now - anchor >= floor


def _id_seq(*parts: str) -> tuple[str, ...]:
    return tuple(part for part in parts if part)


def _clear_change_proof(state: State) -> State:
    return replace(state, pending_change_signature=None, pending_change_count=0)


def _reset_consecutive_proofs(state: State, *, keep_pending: PendingNotification | None) -> State:
    return replace(
        state,
        qualification=_zero_qualification(),
        healthy_run=0,
        pending_change_signature=None,
        pending_change_count=0,
        pending_notification=keep_pending,
    )


def _attempt(
    state: State,
    kind: NotificationKind,
    signature: tuple[str, ...] | None,
    now: int,
    sender_result: SenderResult | None,
    transition_prefix: str,
) -> StepResult:
    if not isinstance(sender_result, SenderResult):
        raise ModelError(f"sender result required for {kind.value} attempt")
    intent = NotificationIntent(kind, signature)
    if sender_result is SenderResult.FAILED:
        pending = PendingNotification(kind, signature, now)
        failed_state = replace(state, pending_notification=pending)
        if kind is NotificationKind.RECOVERY:
            failed_state = replace(
                failed_state,
                phase=Phase.RECOVERY_PENDING,
                healthy_run=RECOVERY_CONFIRMATIONS,
                pending_change_signature=None,
                pending_change_count=0,
            )
        return failed_state, (intent,), (f"{transition_prefix}-FAILED",)

    delivered = {
        NotificationKind.INITIAL: replace(
            state,
            phase=Phase.OPEN_ANNOUNCED,
            announced_signature=signature,
            pending_notification=None,
            healthy_run=0,
            last_incident_delivery_at=now,
        ),
        NotificationKind.CHANGE: replace(
            state,
            announced_signature=signature,
            pending_change_signature=None,
            pending_change_count=0,
            pending_notification=None,
            last_incident_delivery_at=now,
            last_material_delivery_at=now,
        ),
        NotificationKind.REMINDER: replace(
            state,
            pending_notification=None,
            last_incident_delivery_at=now,
        ),
        NotificationKind.RECOVERY: closed_state(),
    }[kind]
    return delivered, (intent,), (f"{transition_prefix}-OK",)


def _step_uncertain_unknown(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del state, observation, now, sender_result
    return uncertain_state(), (), ("T-UC-X",)


def _step_uncertain_healthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del state, observation, now, sender_result
    return closed_state(), (), ("T-UC-H",)


def _step_uncertain_unhealthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del state, now, sender_result
    qualification = _advance_qualification(closed_state(), observation)
    return (
        closed_state({name: value for name, value in zip(CONDITIONS, qualification)}),
        (),
        ("T-UC-U",),
    )


def _step_closed_unknown(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del state, observation, now, sender_result
    return closed_state(), (), ("T-CL-X",)


def _step_closed_healthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del state, observation, now, sender_result
    return closed_state(), (), ("T-CL-H",)


def _step_closed_unhealthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    qualification = _advance_qualification(state, observation)
    signature = qualified_signature(qualification)
    if not signature:
        return replace(state, qualification=qualification), (), ("T-CL-U-ACCUMULATE",)
    opened = replace(open_unannounced_state(signature), qualification=qualification)
    return _attempt(
        opened,
        NotificationKind.INITIAL,
        signature,
        now,
        sender_result,
        "T-CL-U-INITIAL",
    )


def _step_unannounced_unknown(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del observation, now, sender_result
    return (
        replace(state, qualification=_zero_qualification(), healthy_run=0),
        (),
        ("T-OU-X",),
    )


def _step_unannounced_healthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del observation, now, sender_result
    healthy_run = min(state.healthy_run + 1, RECOVERY_CONFIRMATIONS)
    if healthy_run < RECOVERY_CONFIRMATIONS:
        return (
            replace(state, qualification=_zero_qualification(), healthy_run=healthy_run),
            (),
            ("T-OU-H-WAIT",),
        )
    return closed_state(), (), ("T-OU-H-CLOSE-SILENT",)


def _step_unannounced_unhealthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    qualification = _advance_qualification(state, observation)
    signature = qualified_signature(qualification)
    pending = state.pending_notification
    assert pending is not None
    if signature:
        pending = replace(pending, signature=signature)
    after = replace(
        state,
        qualification=qualification,
        healthy_run=0,
        pending_notification=pending,
    )
    if not _floor_reached(now, pending.last_failed_attempt_at, RETRY_SECONDS):
        return after, (), ("T-OU-U-RETRY-WAIT",)
    return _attempt(
        after,
        NotificationKind.INITIAL,
        pending.signature,
        now,
        sender_result,
        "T-OU-U-INITIAL",
    )


def _step_announced_unknown(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del observation, now, sender_result
    pending = state.pending_notification
    if pending is not None and pending.kind is NotificationKind.CHANGE:
        pending = None
    return _reset_consecutive_proofs(state, keep_pending=pending), (), ("T-OA-X",)


def _step_announced_healthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del observation
    after = _reset_consecutive_proofs(state, keep_pending=None)
    after = replace(
        after,
        healthy_run=min(state.healthy_run + 1, RECOVERY_CONFIRMATIONS),
    )
    if after.healthy_run < RECOVERY_CONFIRMATIONS:
        return after, (), ("T-OA-H-WAIT",)
    return _attempt(
        after,
        NotificationKind.RECOVERY,
        None,
        now,
        sender_result,
        "T-OA-H-RECOVERY",
    )


def _retry_or_cancel_failed_transport(
    state: State,
    current: tuple[str, ...],
    now: int,
    sender_result: SenderResult | None,
) -> StepResult | tuple[State, str]:
    pending = state.pending_notification
    if pending is None:
        return state, ""
    if pending.kind is NotificationKind.CHANGE:
        if current != pending.signature:
            cleared = replace(_clear_change_proof(state), pending_notification=None)
            return cleared, "T-OA-U-CANCEL-STALE-CHANGE"
        if not _floor_reached(now, pending.last_failed_attempt_at, RETRY_SECONDS):
            return state, (), ("T-OA-U-CHANGE-RETRY-WAIT",)
        return _attempt(
            state,
            NotificationKind.CHANGE,
            pending.signature,
            now,
            sender_result,
            "T-OA-U-CHANGE-RETRY",
        )
    if pending.kind is NotificationKind.REMINDER:
        if current != state.announced_signature:
            cleared = replace(_clear_change_proof(state), pending_notification=None)
            return cleared, "T-OA-U-CANCEL-STALE-REMINDER"
        if not _floor_reached(now, pending.last_failed_attempt_at, RETRY_SECONDS):
            return state, (), ("T-OA-U-REMINDER-RETRY-WAIT",)
        return _attempt(
            state,
            NotificationKind.REMINDER,
            state.announced_signature,
            now,
            sender_result,
            "T-OA-U-REMINDER-RETRY",
        )
    raise ModelError("announced state has an impossible pending intent")


def _step_open_announced_unhealthy(
    state: State,
    observation: Observation,
    now: int,
    sender_result: SenderResult | None,
) -> StepResult:
    qualification = _advance_qualification(state, observation)
    current = qualified_signature(qualification)
    working = replace(state, qualification=qualification, healthy_run=0)
    transport = _retry_or_cancel_failed_transport(working, current, now, sender_result)
    if len(transport) == 3:
        return transport
    working, cancelled = transport

    if not current:
        return _clear_change_proof(working), (), _id_seq(cancelled, "T-OA-U-UNQUALIFIED")

    if current == working.announced_signature:
        working = _clear_change_proof(working)
        if not _floor_reached(now, working.last_incident_delivery_at, REMINDER_SECONDS):
            return working, (), _id_seq(cancelled, "T-OA-U-SAME-DEDUP")
        attempted, intents, ids = _attempt(
            working,
            NotificationKind.REMINDER,
            working.announced_signature,
            now,
            sender_result,
            "T-OA-U-REMINDER",
        )
        return attempted, intents, _id_seq(cancelled) + ids

    if working.pending_change_signature == current:
        count = min(working.pending_change_count + 1, MATERIAL_CONFIRMATIONS)
        continuity = "T-OA-U-CHANGE-CONTINUE"
    else:
        count = 1
        continuity = "T-OA-U-CHANGE-START"
    working = replace(
        working,
        pending_change_signature=current,
        pending_change_count=count,
    )
    prefix = _id_seq(cancelled, continuity)
    if count < MATERIAL_CONFIRMATIONS:
        return working, (), prefix
    if not _floor_reached(now, working.last_material_delivery_at, RETRY_SECONDS):
        return working, (), prefix + ("T-OA-U-CHANGE-FLOOR-WAIT",)
    attempted, intents, ids = _attempt(
        working,
        NotificationKind.CHANGE,
        current,
        now,
        sender_result,
        "T-OA-U-CHANGE",
    )
    return attempted, intents, prefix + ids


def _step_recovery_unknown(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del observation, now, sender_result
    after = replace(
        state,
        phase=Phase.OPEN_ANNOUNCED,
        qualification=_zero_qualification(),
        healthy_run=0,
        pending_notification=None,
    )
    return after, (), ("T-RP-X-CANCEL",)


def _step_recovery_healthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    del observation
    after = replace(
        state,
        qualification=_zero_qualification(),
        healthy_run=RECOVERY_CONFIRMATIONS,
    )
    pending = state.pending_notification
    assert pending is not None
    if not _floor_reached(now, pending.last_failed_attempt_at, RETRY_SECONDS):
        return after, (), ("T-RP-H-RETRY-WAIT",)
    return _attempt(
        after,
        NotificationKind.RECOVERY,
        None,
        now,
        sender_result,
        "T-RP-H-RECOVERY",
    )


def _step_recovery_unhealthy(
    state: State, observation: Observation, now: int, sender_result: SenderResult | None
) -> StepResult:
    announced = replace(
        state,
        phase=Phase.OPEN_ANNOUNCED,
        qualification=_zero_qualification(),
        healthy_run=0,
        pending_notification=None,
    )
    after, intents, nested_ids = _step_open_announced_unhealthy(
        announced,
        observation,
        now,
        sender_result,
    )
    return after, intents, ("T-RP-U-CANCEL",) + nested_ids


_PHASE_HANDLERS: dict[tuple[Phase, ObservationKind], PhaseHandler] = {
    (Phase.UNCERTAIN, ObservationKind.UNKNOWN): _step_uncertain_unknown,
    (Phase.UNCERTAIN, ObservationKind.KNOWN_HEALTHY): _step_uncertain_healthy,
    (Phase.UNCERTAIN, ObservationKind.KNOWN_UNHEALTHY): _step_uncertain_unhealthy,
    (Phase.CLOSED, ObservationKind.UNKNOWN): _step_closed_unknown,
    (Phase.CLOSED, ObservationKind.KNOWN_HEALTHY): _step_closed_healthy,
    (Phase.CLOSED, ObservationKind.KNOWN_UNHEALTHY): _step_closed_unhealthy,
    (Phase.OPEN_UNANNOUNCED, ObservationKind.UNKNOWN): _step_unannounced_unknown,
    (Phase.OPEN_UNANNOUNCED, ObservationKind.KNOWN_HEALTHY): _step_unannounced_healthy,
    (Phase.OPEN_UNANNOUNCED, ObservationKind.KNOWN_UNHEALTHY): _step_unannounced_unhealthy,
    (Phase.OPEN_ANNOUNCED, ObservationKind.UNKNOWN): _step_announced_unknown,
    (Phase.OPEN_ANNOUNCED, ObservationKind.KNOWN_HEALTHY): _step_announced_healthy,
    (Phase.OPEN_ANNOUNCED, ObservationKind.KNOWN_UNHEALTHY): _step_open_announced_unhealthy,
    (Phase.RECOVERY_PENDING, ObservationKind.UNKNOWN): _step_recovery_unknown,
    (Phase.RECOVERY_PENDING, ObservationKind.KNOWN_HEALTHY): _step_recovery_healthy,
    (Phase.RECOVERY_PENDING, ObservationKind.KNOWN_UNHEALTHY): _step_recovery_unhealthy,
}


def step(
    state: State,
    observation: Observation,
    now: int,
    sender_result_if_attempted: SenderResult | None,
) -> StepResult:
    """Advance exactly one observation.

    ``sender_result_if_attempted`` is an offered deterministic result.  It is consumed
    only when this transition emits one intent and is otherwise ignored.  A transition
    that needs to attempt with no offered result is a caller error.  ``now`` is an
    explicit non-negative wall-clock second; rollback is represented by a lower value.
    """
    assert_valid_state(state)
    assert_valid_observation(observation)
    if type(now) is not int or now < 0:
        raise ModelError("now must be a non-negative wall-clock integer")
    if sender_result_if_attempted is not None and not isinstance(
        sender_result_if_attempted, SenderResult
    ):
        raise ModelError("invalid sender result")

    handler = _PHASE_HANDLERS[(state.phase, observation.kind)]
    after, intents, ids = handler(state, observation, now, sender_result_if_attempted)
    assert_valid_state(after)
    _assert_transition_invariants(
        state,
        observation,
        now,
        sender_result_if_attempted,
        after,
        intents,
    )
    return after, intents, ids


def _assert_transition_invariants(
    before: State,
    observation: Observation,
    now: int,
    sender_result: SenderResult | None,
    after: State,
    intents: tuple[NotificationIntent, ...],
) -> None:
    """Evaluate every model invariant after every successful step."""
    assert_valid_observation(observation)

    if observation.kind is ObservationKind.UNKNOWN:
        if intents:
            raise AssertionError("INV-02 unknown emitted a notification")
        if before.phase in (Phase.OPEN_UNANNOUNCED, Phase.OPEN_ANNOUNCED):
            if after.phase is not before.phase:
                raise AssertionError("INV-02 unknown changed episode existence")
        if before.phase is Phase.RECOVERY_PENDING and after.phase is not Phase.OPEN_ANNOUNCED:
            raise AssertionError("INV-02 unknown did not conservatively cancel recovery proof")
        if (
            after.announced_signature != before.announced_signature
            or after.last_incident_delivery_at != before.last_incident_delivery_at
            or after.last_material_delivery_at != before.last_material_delivery_at
        ):
            raise AssertionError("INV-02 unknown altered delivery facts")
        if after.healthy_run or after.pending_change_count or any(after.qualification):
            raise AssertionError("INV-02 unknown preserved consecutive proof")

    if any(intent.kind is NotificationKind.RECOVERY for intent in intents):
        if observation.kind is not ObservationKind.KNOWN_HEALTHY:
            raise AssertionError("INV-03 recovery without raw healthy input")
        if before.healthy_run < RECOVERY_CONFIRMATIONS - 1:
            raise AssertionError("INV-03 recovery without consecutive witness")

    if intents and sender_result is SenderResult.FAILED:
        if after.phase is Phase.CLOSED:
            raise AssertionError("INV-04 failed transport closed an episode")
        if after.last_incident_delivery_at != before.last_incident_delivery_at:
            raise AssertionError("INV-04 failed transport changed delivery anchor")
        if after.last_material_delivery_at != before.last_material_delivery_at:
            raise AssertionError("INV-04 failed transport changed material anchor")

    incident_changed = after.last_incident_delivery_at != before.last_incident_delivery_at
    material_changed = after.last_material_delivery_at != before.last_material_delivery_at
    if incident_changed or material_changed:
        if not intents or sender_result is not SenderResult.OK:
            raise AssertionError("INV-05 delivery anchor changed without success")
    if material_changed and intents[0].kind not in (
        NotificationKind.CHANGE,
        NotificationKind.RECOVERY,
    ):
        raise AssertionError("INV-05 invalid material-anchor change")
    if intents and intents[0].kind is NotificationKind.REMINDER:
        pending_retry = (
            before.pending_notification is not None
            and before.pending_notification.kind is NotificationKind.REMINDER
        )
        anchor = (
            before.pending_notification.last_failed_attempt_at
            if pending_retry
            else before.last_incident_delivery_at
        )
        floor = RETRY_SECONDS if pending_retry else REMINDER_SECONDS
        if anchor is None or now - anchor < floor:
            raise AssertionError("INV-05 early reminder/retry")

    if observation.kind is ObservationKind.UNKNOWN and after.pending_change_count:
        raise AssertionError("INV-06 unknown retained material proof")
    if after.pending_change_count:
        if after.pending_change_signature is None or after.pending_change_count > 2:
            raise AssertionError("INV-06 malformed material proof")

    if PERSISTED_FIELDS != EXPECTED_PERSISTED_FIELDS:
        raise AssertionError("INV-07 transient transition authority exists")

    if before.phase is Phase.UNCERTAIN:
        if intents:
            raise AssertionError("INV-08 corruption re-entry notified")
        if observation.kind is ObservationKind.KNOWN_UNHEALTHY:
            for name, value in zip(CONDITIONS, after.qualification):
                expected = 1 if name in observation.breached else 0
                if value != expected:
                    raise AssertionError("INV-08 did not start fresh qualification")

    if len(intents) > 1:
        raise AssertionError("INV-09 multiple sends in one admitted transition")

    assert_valid_state(after)


def state_to_obj(state: State) -> dict[str, Any]:
    assert_valid_state(state)
    pending = state.pending_notification
    return {
        "announced_signature": (
            list(state.announced_signature) if state.announced_signature is not None else None
        ),
        "healthy_run": state.healthy_run,
        "last_incident_delivery_at": state.last_incident_delivery_at,
        "last_material_delivery_at": state.last_material_delivery_at,
        "pending_change_count": state.pending_change_count,
        "pending_change_signature": (
            list(state.pending_change_signature)
            if state.pending_change_signature is not None
            else None
        ),
        "pending_notification": (
            None
            if pending is None
            else {
                "kind": pending.kind.value,
                "last_failed_attempt_at": pending.last_failed_attempt_at,
                "signature": list(pending.signature) if pending.signature is not None else None,
            }
        ),
        "phase": state.phase.value,
        "qualification": {
            name: value for name, value in zip(CONDITIONS, state.qualification)
        },
        "schema_version": state.schema_version,
    }


def state_to_json(state: State) -> str:
    return json.dumps(state_to_obj(state), sort_keys=True, separators=(",", ":")) + "\n"


def _strict_int(value: Any, *, minimum: int, maximum: int, name: str) -> int:
    if type(value) is not int or not minimum <= value <= maximum:
        raise ModelError(f"invalid {name}")
    return value


def _strict_optional_timestamp(value: Any, name: str) -> int | None:
    if value is None:
        return None
    return _strict_int(value, minimum=0, maximum=2**63 - 1, name=name)


def _strict_signature(value: Any, *, nullable: bool) -> tuple[str, ...] | None:
    if value is None and nullable:
        return None
    if type(value) is not list:
        raise ModelError("signature must be a JSON array")
    return canonical_signature(value)


def state_from_obj(obj: Any) -> State:
    if type(obj) is not dict or set(obj) != set(EXPECTED_PERSISTED_FIELDS):
        raise ModelError("current state must be an exact object")
    if type(obj["schema_version"]) is not int or obj["schema_version"] != SCHEMA_VERSION:
        raise ModelError("unsupported or wrong-typed current schema")
    if type(obj["qualification"]) is not dict or set(obj["qualification"]) != set(CONDITIONS):
        raise ModelError("invalid qualification object")
    qualification = tuple(
        _strict_int(
            obj["qualification"][name],
            minimum=0,
            maximum=QUALIFICATION_THRESHOLDS[name],
            name=f"qualification.{name}",
        )
        for name in CONDITIONS
    )
    try:
        phase = Phase(obj["phase"])
    except (TypeError, ValueError) as exc:
        raise ModelError("invalid phase") from exc
    announced = _strict_signature(obj["announced_signature"], nullable=True)
    pending_change = _strict_signature(obj["pending_change_signature"], nullable=True)
    pending_obj = obj["pending_notification"]
    if pending_obj is None:
        pending = None
    else:
        if type(pending_obj) is not dict or set(pending_obj) != {
            "kind",
            "signature",
            "last_failed_attempt_at",
        }:
            raise ModelError("invalid pending notification object")
        try:
            kind = NotificationKind(pending_obj["kind"])
        except (TypeError, ValueError) as exc:
            raise ModelError("invalid pending notification kind") from exc
        pending = PendingNotification(
            kind,
            _strict_signature(pending_obj["signature"], nullable=True),
            _strict_optional_timestamp(
                pending_obj["last_failed_attempt_at"], "last_failed_attempt_at"
            ),
        )
    state = State(
        schema_version=SCHEMA_VERSION,
        phase=phase,
        qualification=qualification,
        announced_signature=announced,
        pending_change_signature=pending_change,
        pending_change_count=_strict_int(
            obj["pending_change_count"], minimum=0, maximum=2, name="pending_change_count"
        ),
        healthy_run=_strict_int(obj["healthy_run"], minimum=0, maximum=2, name="healthy_run"),
        last_incident_delivery_at=_strict_optional_timestamp(
            obj["last_incident_delivery_at"], "last_incident_delivery_at"
        ),
        last_material_delivery_at=_strict_optional_timestamp(
            obj["last_material_delivery_at"], "last_material_delivery_at"
        ),
        pending_notification=pending,
    )
    assert_valid_state(state)
    return state


def _unique_json_object(pairs: list[tuple[Any, Any]]) -> dict[str, Any]:
    obj: dict[str, Any] = {}
    for key, value in pairs:
        if key in obj:
            raise ModelError("duplicate JSON object key")
        obj[key] = value
    return obj


def _json_nesting_within_limit(text: str) -> bool:
    """Return whether JSON containers outside strings stay within the limit."""
    depth = 0
    in_string = False
    escaped = False
    for character in text:
        if in_string:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
            continue
        if character == '"':
            in_string = True
        elif character in "[{":
            depth += 1
            if depth > MAX_JSON_NESTING:
                return False
        elif character in "]}":
            depth -= 1
    return True


def parse_strict_json(text: str) -> Any:
    """Parse JSON text, converting parser failures and duplicate keys to ModelError.

    Oversized integer strings, decoder-depth/recursion failure, Unicode errors,
    OverflowError, and any other parser exception are damaged input: the strict
    parser reports ModelError, and the total loader maps that to UNCERTAIN.
    JSON containers beyond MAX_JSON_NESTING are damaged input before decoding, so the verdict does not depend on the interpreter recursion limit.
    Duplicate object member names are refused at every nesting level.
    """
    if type(text) is not str:
        raise ModelError("JSON must be text")
    if not _json_nesting_within_limit(text):
        raise ModelError("JSON nesting exceeds limit")
    try:
        return json.loads(text, object_pairs_hook=_unique_json_object)
    except ModelError:
        raise
    except (
        json.JSONDecodeError,
        UnicodeError,
        ValueError,
        TypeError,
        RecursionError,
        OverflowError,
    ) as exc:
        raise ModelError("malformed JSON") from exc


def state_from_json(text: str) -> State:
    return state_from_obj(parse_strict_json(text))


BASELINE_OPTIONAL_FIELDS = {
    "last_alert_at",
    "last_recovery_at",
}
BASELINE_REQUIRED_FIELDS = {
    "alerted",
    "streaks",
    "recover_ok",
    "firing",
}


def _parse_baseline_timestamp(value: Any, name: str) -> int | None:
    if value is None:
        return None
    if type(value) is not str or re.fullmatch(
        r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z",
        value,
        flags=re.ASCII,
    ) is None:
        raise ModelError(f"invalid baseline {name}")
    try:
        parsed = datetime.strptime(value, "%Y-%m-%dT%H:%M:%SZ").replace(
            tzinfo=timezone.utc
        )
    except ValueError as exc:
        raise ModelError(f"invalid baseline {name}") from exc
    if parsed.strftime("%Y-%m-%dT%H:%M:%SZ") != value:
        raise ModelError(f"noncanonical baseline {name}")
    epoch = int(parsed.timestamp())
    if epoch < 0:
        raise ModelError(f"pre-epoch baseline {name}")
    return epoch


def migrate_baseline_obj(obj: Any) -> State:
    """Strictly migrate the finite, synthetic baseline schema."""
    if type(obj) is not dict:
        raise ModelError("baseline state must be an object")
    keys = set(obj)
    if not BASELINE_REQUIRED_FIELDS <= keys or not keys <= (
        BASELINE_REQUIRED_FIELDS | BASELINE_OPTIONAL_FIELDS
    ):
        raise ModelError("baseline state fields are missing or unknown")
    if type(obj["alerted"]) is not bool:
        raise ModelError("baseline alerted must be a JSON boolean")
    if type(obj["recover_ok"]) is not int or not 0 <= obj["recover_ok"] <= 2:
        raise ModelError("invalid baseline recover_ok")
    if type(obj["streaks"]) is not dict or set(obj["streaks"]) != set(CONDITIONS):
        raise ModelError("invalid baseline streaks")
    qualification = {}
    for name in CONDITIONS:
        qualification[name] = _strict_int(
            obj["streaks"][name],
            minimum=0,
            maximum=QUALIFICATION_THRESHOLDS[name],
            name=f"baseline streaks.{name}",
        )
    firing = _strict_signature(obj["firing"], nullable=False)
    assert firing is not None
    derived = tuple(
        name
        for name in CONDITIONS
        if qualification[name] >= QUALIFICATION_THRESHOLDS[name]
    )
    if firing != derived:
        raise ModelError("baseline firing contradicts streaks")
    parsed_times = {
        optional: _parse_baseline_timestamp(obj.get(optional), optional)
        for optional in BASELINE_OPTIONAL_FIELDS
    }
    if obj["alerted"]:
        if not firing:
            raise ModelError("active baseline state has no firing signature")
        return open_announced_state(
            firing,
            now=parsed_times["last_alert_at"] or 0,
            last_incident_delivery_at=parsed_times["last_alert_at"] or 0,
            qualification=qualification,
        )
    if firing or obj["recover_ok"]:
        raise ModelError("inactive baseline state is contradictory")
    return closed_state(qualification)


def load_or_migrate_text(text: str) -> State:
    """Return strict current/migrated state, or deterministic UNCERTAIN on damage."""
    if type(text) is not str:
        return uncertain_state()
    try:
        obj = parse_strict_json(text)
    except ModelError:
        return uncertain_state()
    if type(obj) is not dict:
        return uncertain_state()
    try:
        if "schema_version" in obj:
            return state_from_obj(obj)
        return migrate_baseline_obj(obj)
    except (ModelError, KeyError, TypeError, ValueError):
        return uncertain_state()


def load_or_migrate_bytes(data: bytes) -> State:
    if type(data) is not bytes:
        return uncertain_state()
    try:
        text = data.decode("utf-8", errors="strict")
    except UnicodeDecodeError:
        return uncertain_state()
    return load_or_migrate_text(text)


def classify_normalized_metrics(sample: Any) -> Observation:
    """Classify a fully synthetic normalized metric sample.

    Each condition value is its signed distance from the configured production
    threshold: positive means breached, zero is the exact healthy boundary, and
    negative is healthy.  Production threshold values stay outside this model.
    Values must be finite real numbers (booleans excluded) in [-1e9, 1e9].
    Oversized integers that overflow float conversion are UNKNOWN, not a crash.
    """
    if type(sample) is not dict or set(sample) != set(CONDITIONS):
        return Observation.unknown()
    breached: list[str] = []
    for name in CONDITIONS:
        value = sample[name]
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return Observation.unknown()
        try:
            numeric = float(value)
        except (OverflowError, ValueError):
            return Observation.unknown()
        if not math.isfinite(numeric) or not -1_000_000_000 <= numeric <= 1_000_000_000:
            return Observation.unknown()
        if numeric > 0:
            breached.append(name)
    return Observation.unhealthy(*breached) if breached else Observation.healthy()


ALL_TRANSITION_IDS = (
    "T-UC-X",
    "T-UC-H",
    "T-UC-U",
    "T-CL-X",
    "T-CL-H",
    "T-CL-U-ACCUMULATE",
    "T-CL-U-INITIAL-OK",
    "T-CL-U-INITIAL-FAILED",
    "T-OU-X",
    "T-OU-H-WAIT",
    "T-OU-H-CLOSE-SILENT",
    "T-OU-U-RETRY-WAIT",
    "T-OU-U-INITIAL-OK",
    "T-OU-U-INITIAL-FAILED",
    "T-OA-X",
    "T-OA-H-WAIT",
    "T-OA-H-RECOVERY-OK",
    "T-OA-H-RECOVERY-FAILED",
    "T-OA-U-UNQUALIFIED",
    "T-OA-U-SAME-DEDUP",
    "T-OA-U-REMINDER-OK",
    "T-OA-U-REMINDER-FAILED",
    "T-OA-U-REMINDER-RETRY-WAIT",
    "T-OA-U-REMINDER-RETRY-OK",
    "T-OA-U-REMINDER-RETRY-FAILED",
    "T-OA-U-CANCEL-STALE-REMINDER",
    "T-OA-U-CHANGE-START",
    "T-OA-U-CHANGE-CONTINUE",
    "T-OA-U-CHANGE-FLOOR-WAIT",
    "T-OA-U-CHANGE-OK",
    "T-OA-U-CHANGE-FAILED",
    "T-OA-U-CHANGE-RETRY-WAIT",
    "T-OA-U-CHANGE-RETRY-OK",
    "T-OA-U-CHANGE-RETRY-FAILED",
    "T-OA-U-CANCEL-STALE-CHANGE",
    "T-RP-X-CANCEL",
    "T-RP-H-RETRY-WAIT",
    "T-RP-H-RECOVERY-OK",
    "T-RP-H-RECOVERY-FAILED",
    "T-RP-U-CANCEL",
)
