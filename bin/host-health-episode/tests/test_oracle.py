from __future__ import annotations

from dataclasses import replace
import json
from pathlib import Path
import unittest

import oracle


A = ("load",)
B = ("load", "swap")
X = oracle.Observation.unknown()
H = oracle.Observation.healthy()
UA = oracle.Observation.unhealthy("load")
UB = oracle.Observation.unhealthy("load", "swap")


class OracleTraceCase(unittest.TestCase):
    def assert_restart_every_position(self, initial, trace):
        state = initial
        states = [state]
        for observation, now, result in trace:
            state, _, _ = oracle.step(state, observation, now, result)
            states.append(state)
        for position, state in enumerate(states):
            first = oracle.state_to_json(state)
            reloaded = oracle.state_from_json(first)
            self.assertEqual(state, reloaded, f"reload mismatch at {position}")
            self.assertEqual(first, oracle.state_to_json(reloaded), f"unstable bytes at {position}")
            if position < len(trace):
                observation, now, result = trace[position]
                expected = oracle.step(state, observation, now, result)
                restarted = oracle.step(reloaded, observation, now, result)
                self.assertEqual(expected, restarted, f"next-state mismatch at {position}")
        return states

    def test_q24_initial_identical_reminder_then_next_minute_dedup(self):
        state = oracle.closed_state({
            name: (4 if name == "load" else 0) for name in oracle.CONDITIONS
        })
        trace = [
            (UA, 0, oracle.SenderResult.OK),
            (UA, 60, oracle.SenderResult.OK),
            (UA, 21_599, oracle.SenderResult.OK),
            (UA, 21_600, oracle.SenderResult.OK),
            (UA, 21_660, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[1].phase, oracle.Phase.OPEN_ANNOUNCED)
        _, intents_before, _ = oracle.step(states[2], UA, 21_599, oracle.SenderResult.OK)
        self.assertEqual(intents_before, ())
        _, intents_at, _ = oracle.step(states[3], UA, 21_600, oracle.SenderResult.OK)
        self.assertEqual([i.kind for i in intents_at], [oracle.NotificationKind.REMINDER])
        self.assertEqual(states[-1].last_incident_delivery_at, 21_600)

    def test_q24_reminder_material_change_next_minute(self):
        qualification = {name: 0 for name in oracle.CONDITIONS}
        qualification["load"] = 5
        qualification["swap"] = 4
        state = oracle.open_announced_state(A, now=0, qualification=qualification)
        # B is raw input.  After the A reminder resets swap qualification,
        # five B observations qualify swap; the fifth and sixth are the two
        # consecutive qualified-B material observations required by q26.
        trace = [(UA, 21_600, oracle.SenderResult.OK)] + [
            (UB, 21_660 + index * 60, oracle.SenderResult.OK)
            for index in range(6)
        ] + [(UB, 22_020, oracle.SenderResult.OK)]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[1].last_incident_delivery_at, 21_600)
        self.assertEqual(states[6].pending_change_signature, B)
        self.assertEqual(states[6].pending_change_count, 1)
        self.assertEqual(states[7].announced_signature, B)
        self.assertEqual(states[7].last_incident_delivery_at, 21_960)
        self.assertEqual(states[8].last_incident_delivery_at, 21_960)

    def test_q24_category_oscillation_has_no_per_minute_alerts(self):
        state = oracle.open_announced_state(A, now=0)
        trace = [
            (UA, 60, oracle.SenderResult.OK),
            (UB, 120, oracle.SenderResult.OK),
            (UA, 180, oracle.SenderResult.OK),
            (UB, 240, oracle.SenderResult.OK),
        ]
        self.assert_restart_every_position(state, trace)
        intents = []
        for observation, now, result in trace:
            state, emitted, _ = oracle.step(state, observation, now, result)
            intents.extend(emitted)
        self.assertEqual(intents, [])
        self.assertEqual(state.announced_signature, A)

    def test_q24_magnitude_boundary_oscillation_is_same_signature(self):
        state = oracle.open_announced_state(A, now=0)
        observations = []
        for magnitude in (0.9, 1.0, 0.9):
            sample = {name: -1.0 for name in oracle.CONDITIONS}
            sample["load"] = magnitude
            observations.append(oracle.classify_normalized_metrics(sample))
        self.assertEqual([item.breached for item in observations], [A, A, A])
        trace = [
            (observation, 60 * (index + 1), oracle.SenderResult.OK)
            for index, observation in enumerate(observations)
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertTrue(all(item.announced_signature == A for item in states))
        self.assertTrue(all(item.last_incident_delivery_at == 0 for item in states))

    def test_q24_string_false_migration_cannot_recover(self):
        baseline = valid_baseline(active=False)
        baseline["alerted"] = "false"
        state = oracle.load_or_migrate_text(json.dumps(baseline))
        self.assertEqual(state, oracle.uncertain_state())
        trace = [(H, 0, None), (H, 60, None)]
        states = self.assert_restart_every_position(state, trace)
        self.assertTrue(all(s.phase in (oracle.Phase.UNCERTAIN, oracle.Phase.CLOSED) for s in states))

    def test_q25_pending_unknown_raw_unhealthy_no_false_recovery_or_change(self):
        qualification = {name: 0 for name in oracle.CONDITIONS}
        qualification["load"] = 5
        qualification["swap"] = 5
        state = oracle.open_announced_state(
            A,
            now=0,
            qualification=qualification,
            pending_change_signature=B,
            pending_change_count=1,
        )
        trace = [
            (X, 60, None),
            (UB, 120, oracle.SenderResult.OK),
            (UB, 180, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertTrue(all(s.phase is oracle.Phase.OPEN_ANNOUNCED for s in states))
        self.assertEqual(states[-1].pending_change_count, 0)
        self.assertEqual(states[-1].announced_signature, A)

    def test_q25_unknown_breaks_recovery_proof(self):
        state = oracle.open_announced_state(A, now=0)
        trace = [
            (X, 60, None),
            (H, 120, None),
            (X, 180, None),
            (H, 240, None),
            (H, 300, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertTrue(all(s.phase is oracle.Phase.OPEN_ANNOUNCED for s in states[:-1]))
        self.assertEqual(states[-1].phase, oracle.Phase.CLOSED)

    def test_failed_initial_exact_retry_boundary_and_restart(self):
        state = oracle.closed_state({
            name: (4 if name == "load" else 0) for name in oracle.CONDITIONS
        })
        trace = [
            (UA, 0, oracle.SenderResult.FAILED),
            (UA, 899, oracle.SenderResult.OK),
            (UA, 900, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[1].phase, oracle.Phase.OPEN_UNANNOUNCED)
        self.assertEqual(states[2].phase, oracle.Phase.OPEN_UNANNOUNCED)
        self.assertEqual(states[3].phase, oracle.Phase.OPEN_ANNOUNCED)

    def test_failed_change_exact_retry_boundary_and_restart(self):
        qualification = {name: 0 for name in oracle.CONDITIONS}
        qualification["load"] = 5
        qualification["swap"] = 4
        state = oracle.open_announced_state(A, now=0, qualification=qualification)
        trace = [
            (UB, 10, oracle.SenderResult.OK),
            (UB, 11, oracle.SenderResult.FAILED),
            (UB, 910, oracle.SenderResult.OK),
            (UB, 911, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[2].pending_notification.kind, oracle.NotificationKind.CHANGE)
        self.assertEqual(states[3].pending_notification.kind, oracle.NotificationKind.CHANGE)
        self.assertEqual(states[4].announced_signature, B)

    def test_failed_reminder_exact_retry_boundary_and_restart(self):
        state = oracle.open_announced_state(A, now=0)
        trace = [
            (UA, 21_600, oracle.SenderResult.FAILED),
            (UA, 22_499, oracle.SenderResult.OK),
            (UA, 22_500, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[2].pending_notification.kind, oracle.NotificationKind.REMINDER)
        self.assertIsNone(states[3].pending_notification)
        self.assertEqual(states[3].last_incident_delivery_at, 22_500)

    def test_failed_recovery_exact_retry_boundary_and_restart(self):
        state = oracle.open_announced_state(A, now=0)
        trace = [
            (H, 10, None),
            (H, 11, oracle.SenderResult.FAILED),
            (H, 910, oracle.SenderResult.OK),
            (H, 911, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[2].phase, oracle.Phase.RECOVERY_PENDING)
        self.assertEqual(states[3].phase, oracle.Phase.RECOVERY_PENDING)
        self.assertEqual(states[4].phase, oracle.Phase.CLOSED)

    def test_unreadable_state_recovers_liveness_without_fabrication(self):
        state = oracle.load_or_migrate_bytes(b"{not-json")
        trace = [(X, 0, None), (H, 60, None)]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[-1].phase, oracle.Phase.CLOSED)
        self.assertTrue(all(s.last_incident_delivery_at is None for s in states))

        state = oracle.load_or_migrate_bytes(b"\xff")
        intents = []
        threshold_trace = [(UA, i * 60, oracle.SenderResult.OK) for i in range(5)]
        self.assert_restart_every_position(state, threshold_trace)
        for observation, now, result in threshold_trace:
            state, emitted, _ = oracle.step(state, observation, now, result)
            intents.extend(emitted)
        self.assertEqual([i.kind for i in intents], [oracle.NotificationKind.INITIAL])

    def test_successful_recovery_restart_new_full_threshold_is_new_initial(self):
        state = oracle.open_announced_state(A, now=0)
        trace = [(H, 60, None), (H, 120, oracle.SenderResult.OK)] + [
            (UA, 180 + i * 60, oracle.SenderResult.OK) for i in range(5)
        ]
        states = self.assert_restart_every_position(state, trace)
        emitted_kinds = []
        replay = state
        for observation, now, result in trace:
            replay, emitted, _ = oracle.step(replay, observation, now, result)
            emitted_kinds.extend(intent.kind for intent in emitted)
        self.assertEqual(
            emitted_kinds,
            [oracle.NotificationKind.RECOVERY, oracle.NotificationKind.INITIAL],
        )
        self.assertEqual(states[-1].phase, oracle.Phase.OPEN_ANNOUNCED)

    def test_wall_clock_rollback_and_forward_jump_reminder(self):
        state = oracle.open_announced_state(A, now=1_000)
        trace = [
            (UA, 500, oracle.SenderResult.OK),
            (UA, 22_600, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[1].last_incident_delivery_at, 1_000)
        self.assertEqual(states[2].last_incident_delivery_at, 22_600)

    def test_wall_clock_rollback_and_forward_jump_material(self):
        qualification = {name: 0 for name in oracle.CONDITIONS}
        qualification["load"] = 5
        qualification["swap"] = 5
        state = oracle.open_announced_state(
            A,
            now=1_000,
            last_material_delivery_at=1_000,
            qualification=qualification,
            pending_change_signature=B,
            pending_change_count=1,
        )
        trace = [
            (UB, 500, oracle.SenderResult.OK),
            (UB, 1_900, oracle.SenderResult.OK),
        ]
        states = self.assert_restart_every_position(state, trace)
        self.assertEqual(states[1].last_material_delivery_at, 1_000)
        self.assertEqual(states[2].last_material_delivery_at, 1_900)


class QualificationAndMetricCase(unittest.TestCase):
    def test_every_qualification_threshold_full_run(self):
        for condition in oracle.CONDITIONS:
            with self.subTest(condition=condition):
                state = oracle.closed_state()
                intents = []
                observation = oracle.Observation.unhealthy(condition)
                threshold = oracle.QUALIFICATION_THRESHOLDS[condition]
                for index in range(threshold):
                    state, emitted, _ = oracle.step(
                        state,
                        observation,
                        index * 60,
                        oracle.SenderResult.OK,
                    )
                    intents.extend(emitted)
                    if index < threshold - 1:
                        self.assertEqual(state.phase, oracle.Phase.CLOSED)
                self.assertEqual([i.kind for i in intents], [oracle.NotificationKind.INITIAL])

    def test_every_metric_exact_boundary_and_malformed_partition(self):
        baseline = {name: -1.0 for name in oracle.CONDITIONS}
        for condition in oracle.CONDITIONS:
            with self.subTest(condition=condition, boundary="minus"):
                sample = dict(baseline)
                sample[condition] = -1.0
                self.assertEqual(
                    oracle.classify_normalized_metrics(sample).kind,
                    oracle.ObservationKind.KNOWN_HEALTHY,
                )
            with self.subTest(condition=condition, boundary="exact"):
                sample = dict(baseline)
                sample[condition] = 0.0
                self.assertEqual(
                    oracle.classify_normalized_metrics(sample).kind,
                    oracle.ObservationKind.KNOWN_HEALTHY,
                )
            with self.subTest(condition=condition, boundary="plus"):
                sample = dict(baseline)
                sample[condition] = 1.0
                observation = oracle.classify_normalized_metrics(sample)
                self.assertEqual(observation.kind, oracle.ObservationKind.KNOWN_UNHEALTHY)
                self.assertEqual(observation.breached, (condition,))
            for bad in (
                "1",
                None,
                True,
                float("nan"),
                float("inf"),
                -float("inf"),
                1_000_000_001,
                10 ** 5000,
            ):
                with self.subTest(condition=condition, bad=type(bad).__name__ if not isinstance(bad, str) else repr(bad)):
                    sample = dict(baseline)
                    sample[condition] = bad
                    self.assertEqual(
                        oracle.classify_normalized_metrics(sample).kind,
                        oracle.ObservationKind.UNKNOWN,
                    )
            missing = dict(baseline)
            del missing[condition]
            self.assertEqual(
                oracle.classify_normalized_metrics(missing).kind,
                oracle.ObservationKind.UNKNOWN,
            )
        self.assertEqual(
            oracle.classify_normalized_metrics([]).kind,
            oracle.ObservationKind.UNKNOWN,
        )


class MigrationCase(unittest.TestCase):
    def test_strict_active_and_inactive_baseline_mapping(self):
        active = valid_baseline(active=True)
        state = oracle.load_or_migrate_text(json.dumps(active))
        self.assertEqual(state.phase, oracle.Phase.OPEN_ANNOUNCED)
        self.assertEqual(state.announced_signature, A)
        inactive = valid_baseline(active=False)
        state = oracle.load_or_migrate_text(json.dumps(inactive))
        self.assertEqual(state.phase, oracle.Phase.CLOSED)

    def test_optional_baseline_fields_are_optional(self):
        active = valid_baseline(active=True)
        active.pop("last_alert_at")
        active.pop("last_recovery_at")
        self.assertEqual(
            oracle.load_or_migrate_text(json.dumps(active)).phase,
            oracle.Phase.OPEN_ANNOUNCED,
        )

    def test_migration_is_deterministic_and_idempotent(self):
        for active in (False, True):
            source = json.dumps(valid_baseline(active=active), sort_keys=True)
            first = oracle.load_or_migrate_text(source)
            second = oracle.load_or_migrate_text(source)
            self.assertEqual(first, second)
            first_bytes = oracle.state_to_json(first)
            self.assertEqual(first_bytes, oracle.state_to_json(second))
            self.assertEqual(first, oracle.load_or_migrate_text(first_bytes))

    def test_truncation_at_every_byte_boundary_is_uncertain(self):
        text = oracle.state_to_json(oracle.open_announced_state(A, now=0)).encode("utf-8")
        # The final byte is the optional canonical newline; removing only it leaves
        # complete JSON and is not a token truncation.
        for cut in range(len(text) - 1):
            with self.subTest(cut=cut):
                self.assertEqual(
                    oracle.load_or_migrate_bytes(text[:cut]),
                    oracle.uncertain_state(),
                )

    def test_current_schema_rejects_wrong_schema_types_and_unreachable_phase_intents(self):
        base = oracle.state_to_obj(oracle.open_announced_state(A, now=100))
        cases = []
        for wrong_schema in (True, 1.0):
            damaged = json.loads(json.dumps(base))
            damaged["schema_version"] = wrong_schema
            cases.append((f"schema={wrong_schema!r}", damaged))

        reminder_without_failure = json.loads(json.dumps(base))
        reminder_without_failure["pending_notification"] = {
            "kind": "reminder",
            "signature": ["load"],
            "last_failed_attempt_at": None,
        }
        cases.append(("reminder-null-failed-at", reminder_without_failure))

        wrong_reminder = json.loads(json.dumps(base))
        wrong_reminder["pending_notification"] = {
            "kind": "reminder",
            "signature": ["swap"],
            "last_failed_attempt_at": 100,
        }
        cases.append(("reminder-wrong-signature", wrong_reminder))

        early_reminder = json.loads(json.dumps(base))
        early_reminder["pending_notification"] = {
            "kind": "reminder",
            "signature": ["load"],
            "last_failed_attempt_at": 21_699,
        }
        cases.append(("reminder-failure-before-six-hours", early_reminder))

        reminder_with_proof = json.loads(json.dumps(base))
        reminder_with_proof["qualification"]["swap"] = 5
        reminder_with_proof["pending_change_signature"] = ["load", "swap"]
        reminder_with_proof["pending_change_count"] = 1
        reminder_with_proof["pending_notification"] = {
            "kind": "reminder",
            "signature": ["load"],
            "last_failed_attempt_at": 100,
        }
        cases.append(("reminder-with-material-proof", reminder_with_proof))

        change_equal_announced = json.loads(json.dumps(base))
        change_equal_announced["pending_change_signature"] = ["load"]
        change_equal_announced["pending_change_count"] = 2
        change_equal_announced["pending_notification"] = {
            "kind": "change",
            "signature": ["load"],
            "last_failed_attempt_at": 100,
        }
        cases.append(("change-equals-announced", change_equal_announced))

        proof_equal_announced = json.loads(json.dumps(base))
        proof_equal_announced["pending_change_signature"] = ["load"]
        proof_equal_announced["pending_change_count"] = 1
        cases.append(("proof-equals-announced", proof_equal_announced))

        early_change = json.loads(json.dumps(base))
        early_change["qualification"]["swap"] = 5
        early_change["last_material_delivery_at"] = 100
        early_change["pending_change_signature"] = ["load", "swap"]
        early_change["pending_change_count"] = 2
        early_change["pending_notification"] = {
            "kind": "change",
            "signature": ["load", "swap"],
            "last_failed_attempt_at": 999,
        }
        cases.append(("change-failure-before-material-floor", early_change))

        material_after_incident = json.loads(json.dumps(base))
        material_after_incident["last_material_delivery_at"] = 101
        cases.append(("material-anchor-after-incident", material_after_incident))

        healthy_two = json.loads(json.dumps(base))
        healthy_two["healthy_run"] = 2
        healthy_two["qualification"] = {name: 0 for name in oracle.CONDITIONS}
        cases.append(("open-announced-healthy-two", healthy_two))

        different_without_proof = json.loads(json.dumps(base))
        different_without_proof["qualification"]["swap"] = 5
        cases.append(("different-qualified-without-proof", different_without_proof))

        for name, damaged in cases:
            with self.subTest(name=name):
                text = json.dumps(damaged)
                with self.assertRaises(oracle.ModelError):
                    oracle.state_from_json(text)
                state = oracle.load_or_migrate_text(text)
                self.assertEqual(state, oracle.uncertain_state())
                after, intents, _ = oracle.step(state, H, 200, None)
                self.assertEqual(after.phase, oracle.Phase.CLOSED)
                self.assertEqual(intents, ())

    def test_baseline_timestamp_requires_exact_utc_lexical_form(self):
        for value in (
            "2020-1-1T00:00:00z",
            "2020-01-01t00:00:00Z",
            "2020-01-01 00:00:00Z",
            "2020-01-01T00:00:00+00:00",
            "2020-01-01T00:00:00.0Z",
            "2020-01-01T00:00Z",
            "1969-12-31T23:59:59Z",
        ):
            with self.subTest(value=value):
                baseline = valid_baseline(active=True)
                baseline["last_alert_at"] = value
                self.assertEqual(
                    oracle.load_or_migrate_text(json.dumps(baseline)),
                    oracle.uncertain_state(),
                )

    def test_wrong_json_types_unknown_schema_non_object_and_contradictions(self):
        current = oracle.state_to_obj(oracle.closed_state())
        cases = [None, [], "state", 1, True]
        for field in oracle.EXPECTED_PERSISTED_FIELDS:
            damaged = dict(current)
            damaged[field] = [] if field != "qualification" else "bad"
            cases.append(damaged)
        future = dict(current)
        future["schema_version"] = 2
        cases.append(future)
        active = valid_baseline(active=True)
        active["firing"] = []
        cases.append(active)
        inactive = valid_baseline(active=False)
        inactive["recover_ok"] = 1
        cases.append(inactive)
        malformed_boolean = valid_baseline(active=False)
        malformed_boolean["alerted"] = "false"
        cases.append(malformed_boolean)
        malformed_timestamp = valid_baseline(active=True)
        malformed_timestamp["last_alert_at"] = "not-a-timestamp"
        cases.append(malformed_timestamp)
        for index, case in enumerate(cases):
            with self.subTest(case=index):
                self.assertEqual(
                    oracle.load_or_migrate_text(json.dumps(case)),
                    oracle.uncertain_state(),
                )

    def test_oversized_integers_and_parser_depth_are_uncertain(self):
        oversized = "9" * 5000
        current = oracle.state_to_json(oracle.closed_state()).rstrip("\n")
        fixtures = (
            current.replace('"schema_version":1', f'"schema_version":{oversized}'),
            current.replace('"load":0', f'"load":{oversized}', 1),
            json.dumps(valid_baseline(active=False), separators=(",", ":")).replace(
                '"recover_ok":0', f'"recover_ok":{oversized}'
            ),
            json.dumps(valid_baseline(active=False), separators=(",", ":")).replace(
                '"load":0', f'"load":{oversized}', 1
            ),
            "[" * 1_000 + "]" * 1_000,
            '{"a":' * 1_000 + "1" + "}" * 1_000,
        )
        for index, text in enumerate(fixtures):
            with self.subTest(fixture=index):
                with self.assertRaises(oracle.ModelError):
                    oracle.state_from_json(text)
                with self.assertRaises(oracle.ModelError):
                    oracle.parse_strict_json(text)
                self.assertEqual(
                    oracle.load_or_migrate_text(text),
                    oracle.uncertain_state(),
                )
                after, intents, _ = oracle.step(
                    oracle.load_or_migrate_text(text), H, 0, None
                )
                self.assertEqual(after.phase, oracle.Phase.CLOSED)
                self.assertEqual(intents, ())

    def test_duplicate_object_keys_are_uncertain(self):
        current = oracle.state_to_json(oracle.closed_state()).rstrip("\n")
        baseline = json.dumps(valid_baseline(active=False), separators=(",", ":"))
        fixtures = (
            current.replace('"phase":"CLOSED"', '"phase":"CLOSED","phase":"OPEN_ANNOUNCED"'),
            current.replace('"load":0', '"load":0,"load":5', 1),
            current.replace(
                '"pending_notification":null',
                '"pending_notification":null,"pending_notification":{"kind":"initial","signature":["load"],"last_failed_attempt_at":null}',
            ),
            baseline.replace('"alerted":false', '"alerted":false,"alerted":true'),
            baseline.replace('"load":0', '"load":0,"load":5', 1),
        )
        for index, text in enumerate(fixtures):
            with self.subTest(fixture=index):
                with self.assertRaisesRegex(oracle.ModelError, "duplicate JSON object key"):
                    oracle.parse_strict_json(text)
                with self.assertRaisesRegex(oracle.ModelError, "duplicate JSON object key"):
                    oracle.state_from_json(text)
                self.assertEqual(
                    oracle.load_or_migrate_text(text),
                    oracle.uncertain_state(),
                )
                after, intents, _ = oracle.step(
                    oracle.load_or_migrate_text(text), H, 0, None
                )
                self.assertEqual(after.phase, oracle.Phase.CLOSED)
                self.assertEqual(intents, ())


def valid_baseline(*, active: bool) -> dict:
    streaks = {name: 0 for name in oracle.CONDITIONS}
    firing = []
    if active:
        streaks["load"] = oracle.QUALIFICATION_THRESHOLDS["load"]
        firing = ["load"]
    return {
        "alerted": active,
        "firing": firing,
        "last_alert_at": "2020-01-01T00:00:00Z" if active else None,
        "last_recovery_at": None,
        "recover_ok": 0,
        "streaks": streaks,
    }


if __name__ == "__main__":
    unittest.main()
