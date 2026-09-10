#!/usr/bin/env python3
"""Serve the canonical Firstmate fleet snapshot to an authenticated server.

The service is deliberately a foreground, read-only adapter.  It invokes the
adjacent ``fm-fleet-snapshot.sh --json`` producer for every accepted snapshot
request and projects that canonical result to the upstream contract consumed by
Lalo's Firstmate adapter.

Usage:
    FM_HOME=/path/to/home FM_FLEET_SNAPSHOT_READ_TOKEN=secret \
        fm-fleet-snapshot-serve.py [--port PORT] [--bind-host HOST]

The only successful route is ``GET /api/fleet/snapshot``.  It requires an
exact ``Authorization: Bearer <token>`` header.  The expected token is read
from ``FM_FLEET_SNAPSHOT_READ_TOKEN`` and is never printed or included in a
response.  The default listener is loopback (127.0.0.1); ``--bind-host`` is an
explicit operator override for a separately protected tailnet or proxy
boundary.  ``FM_HOME`` must be an absolute path and is passed to the canonical
producer without reading Firstmate files in this adapter.
"""

from __future__ import annotations

import argparse
import hmac
import json
import os
import re
import selectors
import signal
import subprocess
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any

DEFAULT_BIND_HOST = "127.0.0.1"
DEFAULT_PORT = 8788
SNAPSHOT_PATH = "/api/fleet/snapshot"
SNAPSHOT_TIMEOUT_SECONDS = 4.0
MAX_SNAPSHOT_BYTES = 4 * 1024 * 1024
MAX_ERROR_BYTES = 128
TOKEN_ENV = "FM_FLEET_SNAPSHOT_READ_TOKEN"
TOKEN_PATTERN = re.compile(r"^[!#$%&'*+\-.^_`|~0-9A-Za-z]+$")


class SnapshotUnavailable(Exception):
    """The canonical producer did not yield a usable snapshot."""


def _token_is_valid(token: str | None) -> bool:
    return bool(token and TOKEN_PATTERN.fullmatch(token))


def _expected_token() -> str | None:
    token = os.environ.get(TOKEN_ENV)
    return token if _token_is_valid(token) else None


def _authorized(headers: Any, expected: str | None) -> bool:
    if expected is None:
        return False
    values = headers.get_all("Authorization", [])
    if len(values) != 1:
        return False
    match = re.fullmatch(r"(?i:Bearer) ([!#$%&'*+\-.^_`|~0-9A-Za-z]+)", values[0])
    return bool(match and hmac.compare_digest(match.group(1), expected))


def _record_for_id(snapshot: dict[str, Any]) -> dict[str, dict[str, Any]]:
    records = snapshot.get("backlog", {}).get("records", [])
    return {
        record["id"]: record
        for record in records
        if isinstance(record, dict) and record.get("structured") is True
        and isinstance(record.get("id"), str) and record["id"]
    }


def _task_for_id(snapshot: dict[str, Any]) -> dict[str, dict[str, Any]]:
    return {
        task["id"]: task
        for task in snapshot.get("tasks", [])
        if isinstance(task, dict) and isinstance(task.get("id"), str) and task["id"]
    }


def _string_or_none(value: Any) -> str | None:
    return value if isinstance(value, str) else None


def _project_task(
    task: dict[str, Any] | None,
    record: dict[str, Any] | None,
    *,
    detail: str | None = None,
) -> dict[str, Any]:
    task = task or {}
    record = record or {}
    current_state = task.get("current_state")
    if not isinstance(current_state, dict):
        current_state = {}
    source = current_state.get("source")
    state = _string_or_none(current_state.get("state")) or _string_or_none(record.get("state")) or "unknown"
    if source in {"run-step", "pane"} and state not in {"done", "failed"}:
        current = True
        current_source = "authoritative_current"
    elif source == "status_log":
        current = False
        current_source = "event_only"
    else:
        current = False
        current_source = "unknown"

    pr = task.get("pr")
    if not isinstance(pr, dict):
        pr = {}
    backlog = task.get("backlog")
    if not isinstance(backlog, dict):
        backlog = record
    repository = _string_or_none(backlog.get("repo"))
    return {
        "id": _string_or_none(task.get("id")) or _string_or_none(record.get("id")) or "unknown",
        "kind": _string_or_none(task.get("kind")) or _string_or_none(record.get("kind")) or "unknown",
        "repository": repository,
        "state": state,
        "detail": detail,
        "current": current,
        "currentSource": current_source,
        "productUpdateId": None,
        "prUrl": _string_or_none(pr.get("url")),
        "reportUrl": None,
        "updatedAt": None,
    }


def _valid_canonical(value: Any) -> bool:
    if not isinstance(value, dict) or value.get("schema") != "fm-fleet-snapshot.v1":
        return False
    if not isinstance(value.get("generated"), str):
        return False
    try:
        time.strptime(value["generated"], "%Y-%m-%dT%H:%M:%SZ")
    except (ValueError, TypeError):
        return False
    if not isinstance(value.get("backlog"), dict) or not isinstance(value["backlog"].get("records"), list):
        return False
    if not isinstance(value.get("tasks"), list):
        return False
    inventory = value.get("main_inventory")
    if not isinstance(inventory, dict) or not isinstance(inventory.get("valid"), bool):
        return False
    if inventory.get("reason") is not None and not isinstance(inventory.get("reason"), str):
        return False
    secondmate_current = value.get("secondmate_current")
    if not isinstance(secondmate_current, dict) or not isinstance(secondmate_current.get("records"), list):
        return False
    if not isinstance(secondmate_current.get("registry"), dict):
        return False
    secondmate_landed = value.get("secondmate_landed")
    if not isinstance(secondmate_landed, dict):
        return False
    return all(isinstance(secondmate_landed.get(key), list) for key in ("records", "truncated", "unreadable", "partial"))


def _secondmate_projection(snapshot: dict[str, Any]) -> tuple[dict[str, Any], list[str]]:
    current = snapshot["secondmate_current"]
    registry = current.get("registry")
    records = current.get("records", [])
    omitted: list[str] = []
    details: list[str] = []
    valid = True
    if not isinstance(registry, dict) or registry.get("available") is not True:
        valid = False
        omitted.append("secondmate_registry_unavailable")
        details.append("secondmate registry unavailable")
    elif registry.get("complete") is False:
        valid = False
        omitted.append("secondmate_registry_incomplete")
        details.append("secondmate registry incomplete")
    for record in records:
        if not isinstance(record, dict):
            valid = False
            omitted.append("secondmate_unknown")
            continue
        identifier = record.get("id")
        registry_error = record.get("registry_error")
        if isinstance(registry_error, str) and registry_error:
            valid = False
            marker = f"secondmate_unavailable:{identifier}" if isinstance(identifier, str) else "secondmate_unavailable"
            omitted.append(marker)
            details.append(registry_error)
        state = record.get("current")
        if not isinstance(state, dict) or state.get("state") == "unknown":
            valid = False
            marker = f"secondmate_unknown:{identifier}" if isinstance(identifier, str) else "secondmate_unknown"
            omitted.append(marker)
            reason = state.get("reason") if isinstance(state, dict) else None
            details.append(reason if isinstance(reason, str) and reason else marker)
        if record.get("contradiction") is True:
            omitted.append("secondmate_contradiction")
            details.append("secondmate contradiction evidence present")
    if current.get("truncated", 0):
        omitted.append("secondmate_records_truncated")
        details.append("secondmate records truncated")
    return {
        "valid": valid,
        "detail": "; ".join(dict.fromkeys(details)) if details else None,
    }, omitted


def _to_lalo_payload(snapshot: dict[str, Any]) -> dict[str, Any]:
    """Project only the typed, browser-safe upstream fields expected by Lalo."""
    records = _record_for_id(snapshot)
    tasks = _task_for_id(snapshot)
    backlog_records = snapshot["backlog"]["records"]
    in_flight: list[dict[str, Any]] = []
    for record in backlog_records:
        if not isinstance(record, dict) or record.get("structured") is not True:
            continue
        if record.get("state") == "in_flight":
            in_flight.append(_project_task(tasks.get(record.get("id")), record))

    decisions: list[dict[str, Any]] = []
    decision_ids: set[str] = set()
    for record in backlog_records:
        if not isinstance(record, dict) or record.get("captain_actionable") is not True:
            continue
        identifier = record.get("id")
        if not isinstance(identifier, str) or identifier in decision_ids:
            continue
        decision_ids.add(identifier)
        decisions.append(_project_task(
            tasks.get(identifier), record,
            detail=_string_or_none(record.get("title")),
        ) | {"holdReason": _string_or_none(record.get("hold_reason"))},)
    for task in snapshot["tasks"]:
        if not isinstance(task, dict):
            continue
        hints = task.get("hints")
        if not isinstance(hints, dict):
            continue
        for decision in hints.get("open_decisions", []):
            if not isinstance(decision, dict):
                continue
            identifier = task.get("id")
            if not isinstance(identifier, str):
                continue
            key = f"{identifier}:{decision.get('key', '')}"
            if key in decision_ids:
                continue
            decision_ids.add(key)
            decisions.append(_project_task(
                task, records.get(identifier), detail=_string_or_none(decision.get("summary")),
            ) | {"holdReason": None})

    gates: list[dict[str, Any]] = []
    for record in backlog_records:
        if not isinstance(record, dict) or record.get("structured") is not True:
            continue
        blockers = record.get("unresolved_blocker_ids")
        held = record.get("hold_kind") not in (None, "captain") and record.get("hold_reason") is not None
        if record.get("state") not in {"queued", "in_flight"} or not (isinstance(blockers, list) and blockers or held):
            continue
        identifier = record.get("id")
        if not isinstance(identifier, str):
            continue
        reason = _string_or_none(record.get("blocked_reason")) or _string_or_none(record.get("hold_reason")) or "blocked"
        gates.append(_project_task(tasks.get(identifier), record) | {"gate": reason})
    for task in snapshot["tasks"]:
        if not isinstance(task, dict):
            continue
        state = task.get("current_state")
        identifier = task.get("id")
        if not isinstance(identifier, str) or not isinstance(state, dict):
            continue
        if state.get("state") in {"blocked", "paused", "parked"} and identifier not in {gate["id"] for gate in gates}:
            gate_detail = _string_or_none(state.get("detail")) or _string_or_none(state.get("state")) or "blocked"
            gates.append(_project_task(task, records.get(identifier)) | {"gate": gate_detail})

    completions: list[dict[str, Any]] = []
    for record in backlog_records:
        if not isinstance(record, dict) or record.get("structured") is not True or record.get("state") != "done":
            continue
        identifier = record.get("id")
        if isinstance(identifier, str):
            completions.append(_project_task(tasks.get(identifier), record))

    inventory = snapshot["main_inventory"]
    main_inventory = {
        "valid": inventory.get("valid"),
        "detail": _string_or_none(inventory.get("reason")),
    }
    omitted: list[str] = []
    if main_inventory["valid"] is not True:
        omitted.append("main_inventory_invalid")
    secondmate, secondmate_omitted = _secondmate_projection(snapshot)
    omitted.extend(secondmate_omitted)
    # The canonical producer discloses truncation in its compatibility roll-up.
    landed = snapshot.get("secondmate_landed")
    if isinstance(landed, dict):
        for marker in ("truncated", "unreadable", "partial"):
            values = landed.get(marker)
            if isinstance(values, list) and values:
                omitted.append(f"secondmate_landed_{marker}")
    omitted.extend(marker for marker in snapshot.get("omitted", []) if isinstance(marker, str))
    return {
        "schema": "fm-fleet-snapshot.v1",
        "generatedAt": snapshot["generated"],
        "inFlight": in_flight,
        "decisions": decisions,
        "gates": gates,
        "recentCompletions": completions,
        "omitted": list(dict.fromkeys(omitted)),
        "mainInventory": main_inventory,
        "secondmate": secondmate,
        "provenance": "firstmate-fleet-snapshot.v1 via bin/fm-fleet-snapshot.sh --json",
    }


def _run_canonical_snapshot() -> bytes:
    home = os.environ.get("FM_HOME")
    if not home or not os.path.isabs(home):
        raise SnapshotUnavailable
    producer = os.path.join(os.path.dirname(os.path.abspath(__file__)), "fm-fleet-snapshot.sh")
    if not os.path.isfile(producer) or not os.access(producer, os.X_OK):
        raise SnapshotUnavailable
    env = os.environ.copy()
    env.pop(TOKEN_ENV, None)
    env["FM_HOME"] = home
    try:
        process = subprocess.Popen(
            [producer, "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            env=env,
            start_new_session=True,
        )
    except OSError as error:
        raise SnapshotUnavailable from error

    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    output = bytearray()
    deadline = time.monotonic() + SNAPSHOT_TIMEOUT_SECONDS
    timed_out = False
    too_large = False
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                timed_out = True
                break
            events = selector.select(remaining)
            if not events:
                timed_out = True
                break
            chunk = os.read(process.stdout.fileno(), 65536)
            if not chunk:
                break
            output.extend(chunk)
            if len(output) > MAX_SNAPSHOT_BYTES:
                too_large = True
                break
    finally:
        selector.close()
    if timed_out or too_large or process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except (ProcessLookupError, OSError):
            process.kill()
    try:
        process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        process.kill()
        process.wait()
    if timed_out or too_large or process.returncode != 0 or not output:
        raise SnapshotUnavailable
    return bytes(output)


def _snapshot_response() -> bytes:
    try:
        decoded = json.loads(_run_canonical_snapshot().decode("utf-8"))
    except (SnapshotUnavailable, UnicodeDecodeError, json.JSONDecodeError, ValueError):
        raise SnapshotUnavailable
    if not _valid_canonical(decoded):
        raise SnapshotUnavailable
    try:
        projected = _to_lalo_payload(decoded)
        return json.dumps(projected, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
    except (KeyError, TypeError, ValueError):
        raise SnapshotUnavailable


class SnapshotHandler(BaseHTTPRequestHandler):
    server_version = "fm-fleet-snapshot-serve/1"

    def log_message(self, _format: str, *_args: Any) -> None:
        # Requests may contain secrets in headers and must never be logged.
        return

    def _write_json(self, status: int, body: dict[str, str]) -> None:
        encoded = json.dumps(body, separators=(",", ":")).encode("utf-8")[:MAX_ERROR_BYTES]
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_GET(self) -> None:
        if self.path != SNAPSHOT_PATH:
            self._write_json(404, {"error": "not_found"})
            return
        expected = _expected_token()
        if expected is None:
            self._write_json(503, {"error": "snapshot_unavailable"})
            return
        if not _authorized(self.headers, expected):
            self._write_json(401, {"error": "unauthorized"})
            return
        try:
            payload = _snapshot_response()
        except SnapshotUnavailable:
            self._write_json(503, {"error": "snapshot_unavailable"})
            return
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def _refuse_non_get(self) -> None:
        self._write_json(405, {"error": "method_not_allowed"})

    do_POST = _refuse_non_get
    do_PUT = _refuse_non_get
    do_PATCH = _refuse_non_get
    do_DELETE = _refuse_non_get
    do_HEAD = _refuse_non_get
    do_OPTIONS = _refuse_non_get


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Serve the authenticated Firstmate fleet snapshot.",
        epilog=(
            f"Requires absolute FM_HOME and {TOKEN_ENV}. "
            f"The successful endpoint is GET {SNAPSHOT_PATH}. "
            "The default listener is loopback; use --bind-host only behind an "
            "operator-managed boundary."
        ),
    )
    parser.add_argument("--port", type=int, default=DEFAULT_PORT, help=f"TCP port (default: {DEFAULT_PORT})")
    parser.add_argument(
        "--bind-host", default=DEFAULT_BIND_HOST,
        help=f"listen address (default: {DEFAULT_BIND_HOST}); use only behind an operator-managed boundary",
    )
    return parser


def main(argv: list[str]) -> int:
    args = build_parser().parse_args(argv)
    if not os.environ.get("FM_HOME") or not os.path.isabs(os.environ["FM_HOME"]):
        print("fm-fleet-snapshot-serve: FM_HOME must be an absolute path", file=sys.stderr)
        return 2
    if not args.bind_host or not 0 < args.port < 65536:
        print("fm-fleet-snapshot-serve: invalid listen configuration", file=sys.stderr)
        return 2
    try:
        server = ThreadingHTTPServer((args.bind_host, args.port), SnapshotHandler)
    except OSError:
        print("fm-fleet-snapshot-serve: could not bind listener", file=sys.stderr)
        return 2
    print(f"fm-fleet-snapshot-serve: listening on {args.bind_host}:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
