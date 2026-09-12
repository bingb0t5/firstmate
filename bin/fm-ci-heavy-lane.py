#!/usr/bin/env python3
"""Classify the fixed Lalo-dev heavy CI lane from GitHub API snapshots."""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Mapping

REQUIRED_LABELS = frozenset({"self-hosted", "linux", "lalo-dev"})
HEAVY_JOB_NAMES = frozenset(
    {
        "Behavior tests (Herdr)",
        *(f"Behavior portable serial {shard}" for shard in range(1, 5)),
    }
)


def load_snapshot(path: str) -> Mapping[str, Any]:
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise ValueError(f"cannot read {path}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path}: expected a JSON object")
    return value


def matching_runners(snapshot: Mapping[str, Any]) -> list[Mapping[str, Any]]:
    runners = snapshot.get("runners")
    if not isinstance(runners, list):
        raise ValueError("runner snapshot: expected runners array")
    matches = []
    for runner in runners:
        if not isinstance(runner, dict):
            raise ValueError("runner snapshot: expected runner object")
        labels = runner.get("labels")
        if not isinstance(labels, list):
            raise ValueError("runner snapshot: expected labels array")
        names = {
            label["name"].lower()
            for label in labels
            if isinstance(label, dict) and isinstance(label.get("name"), str)
        }
        if REQUIRED_LABELS.issubset(names):
            matches.append(runner)
    return matches


def preflight(snapshot: Mapping[str, Any]) -> str:
    return "available" if any(
        runner.get("status") == "online" and not runner.get("busy", True)
        for runner in matching_runners(snapshot)
    ) else "unavailable"


def queue_status(runners: Mapping[str, Any], jobs: Mapping[str, Any]) -> str:
    listed_jobs = jobs.get("jobs")
    if not isinstance(listed_jobs, list):
        raise ValueError("job snapshot: expected jobs array")
    heavy = {
        job.get("name"): job
        for job in listed_jobs
        if isinstance(job, dict) and job.get("name") in HEAVY_JOB_NAMES
    }
    if len(heavy) == len(HEAVY_JOB_NAMES) and all(
        job.get("status") == "completed" for job in heavy.values()
    ):
        return "complete"
    return "wait" if any(
        runner.get("status") == "online" for runner in matching_runners(runners)
    ) else "unavailable"


def main(argv: list[str]) -> int:
    if len(argv) not in (3, 4) or argv[1] not in {"preflight", "watch"}:
        print(
            "usage: fm-ci-heavy-lane.py preflight <runners.json> | "
            "fm-ci-heavy-lane.py watch <runners.json> <jobs.json>",
            file=sys.stderr,
        )
        return 2
    try:
        runners = load_snapshot(argv[2])
        if argv[1] == "preflight" and len(argv) == 3:
            result = preflight(runners)
        elif argv[1] == "watch" and len(argv) == 4:
            result = queue_status(runners, load_snapshot(argv[3]))
        else:
            raise ValueError("invalid argument count")
    except ValueError as error:
        print(f"fm-ci-heavy-lane.py: {error}", file=sys.stderr)
        return 2
    print(result)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
