#!/usr/bin/env python3
"""Serialize a guest-scoped Astra client and validate its readiness contract.

The command is intentionally client-neutral.  The guest supplies an executable
adapter around the maintained Codex/CUA component; this helper owns readiness,
exclusive input, handoff, timeout cleanup, and safe timing output.
"""
from __future__ import annotations

import argparse
import contextlib
import fcntl
import json
import os
import re
import signal
import subprocess
import sys
import time
import uuid
from pathlib import Path
from typing import Any, Iterator

EXIT_CLIENT = 5
EXIT_NOT_READY = 3
EXIT_USAGE = 2

FORBIDDEN_KEY = re.compile(
    r"(?:token|password|secret|private[_-]?key|api[_-]?key|cookie|credential[_-]?value)",
    re.IGNORECASE,
)
REQUIRED_FIELDS = (
    "vm.id",
    "vm.guest_user",
    "reachability.endpoint",
    "reachability.transport",
    "reachability.auth_method",
    "reachability.authenticated",
    "desktop.display",
    "desktop.viewer",
    "desktop.browser_profile",
    "lifecycle.owner",
    "readiness.marker",
    "readiness.state",
    "readiness.astra_identifier",
    "components.cua_repl",
    "components.node_repl",
    "components.client_adapter",
    "credential_status",
)


def die(message: str, code: int = EXIT_USAGE) -> int:
    print(f"fm-astra-guest: {message}", file=sys.stderr)
    return code


def load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise ValueError(f"manifest not found: {path}") from None
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"manifest is unreadable: {exc}") from exc
    if not isinstance(value, dict):
        raise ValueError("manifest root must be an object")
    return value


def reject_sensitive_keys(value: Any, path: str = "manifest") -> None:
    if isinstance(value, dict):
        for key, child in value.items():
            if str(key).lower() in {"credential", "credentials"} or FORBIDDEN_KEY.search(str(key)):
                raise ValueError(
                    f"{path}.{key} is not allowed; publish credential status, never a credential value"
                )
            reject_sensitive_keys(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            reject_sensitive_keys(child, f"{path}[{index}]")


def get_field(doc: dict[str, Any], dotted: str) -> Any:
    value: Any = doc
    for part in dotted.split("."):
        if not isinstance(value, dict) or part not in value:
            return None
        value = value[part]
    return value


def missing_fields(doc: dict[str, Any]) -> list[str]:
    missing: list[str] = []
    for field in REQUIRED_FIELDS:
        value = get_field(doc, field)
        if value is None or value == "":
            missing.append(field)
    vm_user = get_field(doc, "vm.guest_user")
    if vm_user == "root":
        missing.append("vm.guest_user(non-root)")
    reachability = get_field(doc, "reachability")
    if isinstance(reachability, dict):
        if reachability.get("public") is not False:
            missing.append("reachability.public=false")
    else:
        missing.append("reachability.public=false")
    readiness = get_field(doc, "readiness")
    if isinstance(readiness, dict) and readiness.get("state") != "ready":
        missing.append("readiness.state=ready")
    credential_status = get_field(doc, "credential_status")
    if credential_status not in {"available", "pending", "captain-assistance-required"}:
        missing.append("credential_status(valid state)")
    return missing


def validate_manifest(path: Path, require_ready: bool = True) -> dict[str, Any]:
    try:
        doc = load_json(path)
        reject_sensitive_keys(doc)
    except ValueError:
        raise
    if "schema" not in doc:
        missing = ["schema"] + missing_fields(doc)
        raise ValueError("missing interface fields: " + ", ".join(missing))
    if doc.get("schema") != 1:
        raise ValueError("manifest.schema must be 1")
    missing = missing_fields(doc)
    if not require_ready:
        missing = [field for field in missing if field not in {"readiness.state=ready"}]
    if require_ready and get_field(doc, "credential_status") != "available":
        missing.append("credential_status=available")
    if missing:
        raise ValueError("missing interface fields: " + ", ".join(missing))
    vm_id = get_field(doc, "vm.id")
    guest_user = get_field(doc, "vm.guest_user")
    if not re.fullmatch(r"[A-Za-z0-9._-]+", str(vm_id)):
        raise ValueError("vm.id must use letters, numbers, dot, underscore, and dash only")
    if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_.-]*[$]?", str(guest_user)):
        raise ValueError("vm.guest_user is not a valid non-root username")
    if get_field(doc, "reachability.authenticated") is not True:
        raise ValueError("reachability.authenticated must be true before guest calls")
    if get_field(doc, "reachability.public") is not False:
        raise ValueError("reachability.public must be false")
    return doc


def print_safe_summary(doc: dict[str, Any]) -> None:
    readiness = get_field(doc, "readiness")
    print(
        "ready"
        f" vm={get_field(doc, 'vm.id')}"
        f" guest_user={get_field(doc, 'vm.guest_user')}"
        f" endpoint={get_field(doc, 'reachability.endpoint')}"
        f" display={get_field(doc, 'desktop.display')}"
        f" viewer={get_field(doc, 'desktop.viewer')}"
        f" lifecycle_owner={get_field(doc, 'lifecycle.owner')}"
        f" credential_status={doc.get('credential_status')}"
        f" astra={readiness.get('astra_identifier')}"
    )


def state_paths(state_dir: Path) -> tuple[Path, Path]:
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir / "handoff.json", state_dir / "input.lock"


def read_state(state_file: Path) -> dict[str, Any]:
    if not state_file.exists():
        return {"mode": "active", "generation": 0, "reason": ""}
    try:
        value = json.loads(state_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ValueError(f"handoff state is unreadable: {exc}") from exc
    if not isinstance(value, dict) or value.get("mode") not in {"active", "human"}:
        raise ValueError("handoff state is invalid")
    return value


def write_state(state_file: Path, state: dict[str, Any]) -> None:
    temporary = state_file.with_suffix(".tmp")
    temporary.write_text(json.dumps(state, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, state_file)


@contextlib.contextmanager
def exclusive_state(state_dir: Path) -> Iterator[tuple[dict[str, Any], Path]]:
    state_file, lock_file = state_paths(state_dir)
    with lock_file.open("a+", encoding="utf-8") as handle:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        state = read_state(state_file)
        yield state, state_file
        fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def command_prepare(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest).resolve()
    try:
        doc = validate_manifest(manifest_path, require_ready=False)
    except ValueError as exc:
        return die(str(exc), EXIT_NOT_READY)
    project = Path(args.project).resolve()
    if not project.is_dir():
        return die(f"project directory not found: {project}")
    output = Path(args.out).resolve() if args.out else project / ".codex" / "astra-guest.toml"
    try:
        output.relative_to(project)
    except ValueError:
        return die("generated config must be inside the guest project directory")
    if output.exists() and not args.replace:
        return die(f"refusing to overwrite existing file: {output} (use --replace-generated)")
    output.parent.mkdir(parents=True, exist_ok=True)
    readiness = get_field(doc, "readiness") or {}
    components = get_field(doc, "components") or {}
    desktop = get_field(doc, "desktop") or {}
    state_dir = Path(args.state_dir).resolve() if args.state_dir else project / ".codex" / "astra-state"
    lines = [
        "# Generated by fm-astra-guest; additive sidecar, not the Codex host config.",
        "# Keep this file in the isolated guest project and never copy host credentials.",
        "[computer_use]",
        'provider = "codex-cli-astra"',
        'execution = "guest"',
        'component = "cua_repl/node_repl"',
        f"astra_identifier = {json.dumps(str(readiness.get('astra_identifier', 'unpublished')))}",
        f"display = {json.dumps(str(desktop.get('display')))}",
        f"browser_profile = {json.dumps(str(desktop.get('browser_profile')))}",
        f"client_adapter = {json.dumps(str(components.get('client_adapter')))}",
        "session_persistent = true",
        "",
        "[handoff]",
        'ownership = "exclusive"',
        "pause_before_human = true",
        "timeout_releases_input = true",
        f"state_dir = {json.dumps(str(state_dir))}",
        "",
        "[reachability]",
        f"transport = {json.dumps(str(get_field(doc, 'reachability.transport')))}",
        "# The endpoint is published for operator routing; credentials are injected only in the guest.",
    ]
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"prepared additive guest config: {output}")
    return 0


def command_handoff(args: argparse.Namespace, mode: str) -> int:
    state_dir = Path(args.state_dir).resolve()
    try:
        with exclusive_state(state_dir) as (state, state_file):
            state["mode"] = mode
            state["generation"] = int(state.get("generation", 0)) + 1
            state["reason"] = args.reason if mode == "human" else ""
            write_state(state_file, state)
            print(f"handoff={mode} generation={state['generation']}")
    except ValueError as exc:
        return die(str(exc))
    return 0


def command_status(args: argparse.Namespace) -> int:
    state_dir = Path(args.state_dir).resolve()
    try:
        with exclusive_state(state_dir) as (state, _):
            print(
                f"handoff={state['mode']} generation={state.get('generation', 0)}"
                f" reason={state.get('reason', '')}"
            )
    except ValueError as exc:
        return die(str(exc))
    return 0


def request_payload(args: argparse.Namespace) -> dict[str, Any]:
    if bool(args.request) == bool(args.prompt):
        raise ValueError("exactly one of --request or --prompt is required")
    if args.request:
        value = load_json(Path(args.request))
        if not isinstance(value, dict):
            raise ValueError("request root must be an object")
        return value
    return {"prompt": args.prompt}


def kill_process_group(process: subprocess.Popen[str]) -> None:
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def command_run(args: argparse.Namespace) -> int:
    manifest_path = Path(args.manifest).resolve()
    try:
        doc = validate_manifest(manifest_path, require_ready=True)
        payload = request_payload(args)
    except (ValueError, OSError) as exc:
        return die(str(exc), EXIT_NOT_READY if "manifest" in str(exc) or "interface" in str(exc) else EXIT_USAGE)
    client = Path(args.client).resolve()
    if not client.is_file() or not os.access(client, os.X_OK):
        return die(f"client adapter is not executable: {client}", EXIT_CLIENT)
    state_dir = Path(args.state_dir).resolve()
    try:
        with exclusive_state(state_dir) as (state, _):
            if state["mode"] != "active":
                return die("desktop is paused for human takeover; resume explicitly before agent use", EXIT_CLIENT)
            request_id = str(uuid.uuid4())
            payload = dict(payload)
            payload.setdefault("protocol", 1)
            payload["request_id"] = request_id
            env = os.environ.copy()
            env.update(
                {
                    "FM_ASTRA_REQUEST_ID": request_id,
                    "FM_ASTRA_SESSION_DIR": str(state_dir),
                    "FM_ASTRA_DESKTOP_OWNER": "agent",
                    "FM_ASTRA_BROWSER_PROFILE": str(get_field(doc, "desktop.browser_profile")),
                    "DISPLAY": str(get_field(doc, "desktop.display")),
                }
            )
            command = [str(client), *args.client_arg]
            started = time.monotonic()
            process = subprocess.Popen(
                command,
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                env=env,
                start_new_session=True,
            )
            try:
                stdout, stderr = process.communicate(
                    json.dumps(payload, ensure_ascii=False) + "\n", timeout=args.timeout
                )
            except subprocess.TimeoutExpired:
                kill_process_group(process)
                process.communicate()
                return die("client timed out; desktop input lock released", EXIT_CLIENT)
            duration_ms = int((time.monotonic() - started) * 1000)
            if process.returncode != 0:
                return die(f"client adapter exited {process.returncode}", EXIT_CLIENT)
            lines = [line for line in stdout.splitlines() if line.strip()]
            if not lines:
                return die("client adapter returned no JSON response", EXIT_CLIENT)
            try:
                response = json.loads(lines[-1])
            except json.JSONDecodeError:
                return die("client adapter returned invalid JSON", EXIT_CLIENT)
            if not isinstance(response, dict):
                return die("client adapter response must be an object", EXIT_CLIENT)
            try:
                reject_sensitive_keys(response, "client response")
            except ValueError as exc:
                return die(str(exc), EXIT_CLIENT)
            envelope = {
                "protocol": 1,
                "request_id": request_id,
                "duration_ms": duration_ms,
                "client": response,
            }
            print(json.dumps(envelope, ensure_ascii=False, sort_keys=True))
            if stderr.strip():
                print("client diagnostics suppressed from result", file=sys.stderr)
            return 0
    except (OSError, ValueError) as exc:
        return die(str(exc), EXIT_CLIENT)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Prepare and serialize guest-scoped Codex/Astra calls.")
    sub = parser.add_subparsers(dest="command", required=True)

    check = sub.add_parser("check", help="validate and print the safe readiness summary")
    check.add_argument("--manifest", required=True)
    check.set_defaults(func=lambda args: command_check(args))

    prepare = sub.add_parser("prepare", help="write an additive guest-project sidecar")
    prepare.add_argument("--manifest", required=True)
    prepare.add_argument("--project", required=True)
    prepare.add_argument("--out")
    prepare.add_argument("--state-dir")
    prepare.add_argument("--replace-generated", dest="replace", action="store_true")
    prepare.set_defaults(func=command_prepare)

    for name, mode in (("pause", "human"), ("resume", "active")):
        handoff = sub.add_parser(name, help=f"set explicit {mode} desktop ownership")
        handoff.add_argument("--state-dir", required=True)
        handoff.add_argument("--reason", default="")
        handoff.set_defaults(func=lambda args, mode=mode: command_handoff(args, mode))

    status = sub.add_parser("status", help="show safe handoff status")
    status.add_argument("--state-dir", required=True)
    status.set_defaults(func=command_status)

    run = sub.add_parser("run", help="execute one serialized client-adapter request")
    run.add_argument("--manifest", required=True)
    run.add_argument("--state-dir", required=True)
    run.add_argument("--client", required=True)
    run.add_argument("--client-arg", action="append", default=[])
    run.add_argument("--timeout", type=float, default=120.0)
    run.add_argument("--request")
    run.add_argument("--prompt")
    run.set_defaults(func=command_run)
    return parser


def command_check(args: argparse.Namespace) -> int:
    try:
        doc = validate_manifest(Path(args.manifest).resolve(), require_ready=True)
    except ValueError as exc:
        return die(str(exc), EXIT_NOT_READY)
    print_safe_summary(doc)
    return 0


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        return int(args.func(args))
    except ValueError as exc:
        return die(str(exc))


if __name__ == "__main__":
    raise SystemExit(main())
