#!/usr/bin/env python3
"""Write Telegram message payloads into Mr Beanz.

The shell wrapper owns command dispatch.
This module owns payload validation, credential parsing, the Beanz POST, and
durable receipts.
It never polls Telegram.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Dict, Iterable, Optional, Tuple
from urllib.parse import urlparse


MAX_UPDATE_ID = 2**31 - 1
MAX_CREDENTIAL_BYTES = 65536
MAX_RESPONSE_BYTES = 1024 * 1024
DEFAULT_BRAIN_URL = "https://brain.mrbea.nz"
DEFAULT_TIMEOUT = 30
CAPTAIN_SOURCE = "firstmate-telegram"
GROUP_SOURCE = "firstmate-telegram-group"
UPDATE_ID_RE = re.compile(r"^[1-9][0-9]*$")
BRAIN_URL_RE = re.compile(r"https://[A-Za-z0-9\-._~:/?#\[\]@!$&'()*+,;=%]+")
MAX_CAPTURE_ID_CHARS = 200
RECEIPT_IDENTITY_FIELDS = ("update_id", "text", "chat_id")
RECEIPT_DIR_NAME = "telegram-brain-capture"
SYSTEMIC_HTTP_STATUSES = (401, 403, 404, 405, 429)
MAX_JSON_DEPTH = 256


class UserError(Exception):
    pass


class PayloadError(UserError):
    def __init__(self, message: str, update_id: Optional[int] = None) -> None:
        super().__init__(message)
        self.update_id = update_id


class CaptureError(UserError):
    pass


def failpoint(name: str) -> None:
    if os.environ.get("FM_TELEGRAM_BRAIN_CAPTURE_FAILPOINT") == name:
        os._exit(91)


def positive_int(value: object, name: str) -> int:
    if type(value) is not int or isinstance(value, bool):
        raise PayloadError("%s is not an integer" % name)
    if value < 1 or value > MAX_UPDATE_ID:
        raise PayloadError("%s is outside the supported positive range" % name)
    return value


def parse_env_value(raw: str) -> str:
    if not raw:
        return ""
    if raw[0] in ("'", '"'):
        if len(raw) < 2 or raw[-1] != raw[0]:
            raise UserError("quoted credential value is not closed")
        value = raw[1:-1]
    else:
        value = raw
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise UserError("credential value contains control bytes")
    return value


def read_env_file(path: Path) -> Dict[str, str]:
    try:
        before = path.lstat()
    except OSError as exc:
        raise UserError("cannot read %s: %s" % (path, exc))
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise UserError("%s is not a regular file" % path)
    if stat.S_IMODE(before.st_mode) != 0o600:
        raise UserError("%s mode is not 600" % path)
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(str(path), flags)
    except OSError as exc:
        raise UserError("cannot open %s: %s" % (path, exc))
    try:
        after = os.fstat(fd)
        if (
            after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or not stat.S_ISREG(after.st_mode)
            or stat.S_IMODE(after.st_mode) != 0o600
        ):
            raise UserError("%s changed during open" % path)
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, min(8192, MAX_CREDENTIAL_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_CREDENTIAL_BYTES:
                raise UserError("%s is too large" % path)
        try:
            text = b"".join(chunks).decode("utf-8")
        except UnicodeDecodeError as exc:
            raise UserError("%s is not UTF-8: %s" % (path, exc))
    finally:
        os.close(fd)
    values: Dict[str, str] = {}
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if stripped.startswith("export "):
            raise UserError("%s must not be sourced as shell" % path)
        if "=" not in stripped:
            raise UserError("%s has a line that is not KEY=VALUE" % path)
        key, raw = stripped.split("=", 1)
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", key):
            raise UserError("%s has an invalid key" % path)
        if key in values:
            raise UserError("%s repeats %s" % (path, key))
        values[key] = parse_env_value(raw)
    return values


def brain_env_path() -> Path:
    override = os.environ.get("FM_BEANZ_ENV_FILE")
    if override:
        return Path(override)
    return Path.home() / ".config" / "beanz" / "mcp.env"


def telegram_env_path() -> Path:
    override = os.environ.get("FM_TELEGRAM_ENV_FILE")
    if override:
        return Path(override)
    return Path.home() / ".config" / "beanz" / "telegram.env"


def validated_capture_id(value: object, origin: str, error=UserError) -> str:
    if not isinstance(value, str) or not value:
        raise error("%s has no capture_id" % origin)
    if len(value) > MAX_CAPTURE_ID_CHARS:
        raise error("%s returned an oversized capture_id" % origin)
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise error("%s returned a capture_id with control bytes" % origin)
    try:
        value.encode("utf-8")
    except UnicodeEncodeError:
        raise error("%s returned a capture_id that is not valid UTF-8" % origin)
    return value


def brain_url_from(values: Dict[str, str]) -> str:
    url = values.get("BEANZ_MCP_URL") or DEFAULT_BRAIN_URL
    if not BRAIN_URL_RE.fullmatch(url):
        raise UserError("BEANZ_MCP_URL is not a plain https URL")
    try:
        parsed = urlparse(url)
        valid_origin = (
            parsed.scheme == "https"
            and bool(parsed.netloc)
            and bool(parsed.hostname)
            and parsed.username is None
            and parsed.password is None
            and parsed.path in ("", "/")
            and not parsed.query
            and not parsed.fragment
        )
        _ = parsed.port
    except ValueError:
        valid_origin = False
    if not valid_origin:
        raise UserError("BEANZ_MCP_URL must be an https origin with no userinfo")
    return url.rstrip("/")


def brain_credentials() -> Tuple[str, str]:
    path = brain_env_path()
    values = read_env_file(path)
    token = values.get("BEANZ_MCP_TOKEN")
    if not token:
        raise UserError("BEANZ_MCP_TOKEN is missing from %s" % path)
    return token, brain_url_from(values)


def path_is_absent(path: Path, name: str) -> bool:
    try:
        path.lstat()
    except FileNotFoundError:
        return True
    except OSError as exc:
        raise UserError("cannot inspect %s: %s" % (name, exc))
    return False


def unconfigured_reason() -> Optional[str]:
    if path_is_absent(brain_env_path(), "brain credentials"):
        return "brain-credentials"
    if not os.environ.get("FM_TELEGRAM_CAPTAIN_CHAT_ID") and path_is_absent(
        telegram_env_path(), "Telegram credentials"
    ):
        return "captain-chat"
    return None


def captain_chat_id() -> int:
    override = os.environ.get("FM_TELEGRAM_CAPTAIN_CHAT_ID")
    if override:
        if not re.fullmatch(r"-?[1-9][0-9]*", override):
            raise UserError("FM_TELEGRAM_CAPTAIN_CHAT_ID must be an integer")
        return int(override)
    values = read_env_file(telegram_env_path())
    raw = values.get("TELEGRAM_CAPTAIN_CHAT_ID")
    if not raw or not re.fullmatch(r"-?[1-9][0-9]*", raw):
        raise UserError(
            "TELEGRAM_CAPTAIN_CHAT_ID is missing from %s" % telegram_env_path()
        )
    return int(raw)


def group_capture_enabled(config: Path) -> bool:
    override = os.environ.get("FM_TELEGRAM_BRAIN_CAPTURE_GROUP")
    if override is not None and override.strip() != "":
        return override.strip() == "on"
    path = config / "telegram-brain-capture-group"
    try:
        info = path.lstat()
    except FileNotFoundError:
        return False
    except OSError as exc:
        raise UserError("cannot inspect telegram-brain-capture-group: %s" % exc)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UserError("telegram-brain-capture-group is not a regular file")
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise UserError("cannot read telegram-brain-capture-group: %s" % exc)
    for line in text.splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        return stripped == "on"
    return False


def timeout_seconds() -> int:
    raw = os.environ.get("FM_BEANZ_CAPTURE_TIMEOUT", str(DEFAULT_TIMEOUT))
    if not re.fullmatch(r"[1-9][0-9]*", raw):
        raise UserError("FM_BEANZ_CAPTURE_TIMEOUT must be a positive integer")
    value = int(raw)
    if value > 120:
        raise UserError("FM_BEANZ_CAPTURE_TIMEOUT must be at most 120")
    return value


def inspect_receipt_dir(state: Path) -> Tuple[str, Optional[str]]:
    try:
        info = state.lstat()
    except FileNotFoundError:
        return "absent", None
    except OSError as exc:
        return "unreadable", "state directory is unreadable: %s" % exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        return "unreadable", "state path is not a directory"
    receipts = state / RECEIPT_DIR_NAME
    try:
        info = receipts.lstat()
    except FileNotFoundError:
        return "absent", None
    except OSError as exc:
        return "unreadable", "receipt directory is unreadable: %s" % exc
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        return "unreadable", "receipt directory is unsafe"
    if stat.S_IMODE(info.st_mode) != 0o700:
        return "unreadable", "receipt directory mode is not 700"
    return "present", None


def ensure_receipt_dir(state: Path) -> Path:
    receipts = state / RECEIPT_DIR_NAME
    store_state, refusal = inspect_receipt_dir(state)
    if refusal is not None:
        raise UserError(refusal)
    if store_state == "present":
        return receipts
    try:
        if not os.path.lexists(str(state)):
            os.makedirs(str(state), 0o700)
            os.chmod(str(state), 0o700)
        os.mkdir(str(receipts), 0o700)
        os.chmod(str(receipts), 0o700)
    except OSError as exc:
        raise UserError("cannot create the receipt directory: %s" % exc)
    return receipts


def receipt_path(receipts: Path, update_id: int) -> Path:
    name = str(update_id)
    if not UPDATE_ID_RE.fullmatch(name):
        raise CaptureError("update_id is not a safe receipt name")
    return receipts / name


def payload_hash(payload: Dict[str, object]) -> str:
    identity = {key: payload[key] for key in RECEIPT_IDENTITY_FIELDS}
    encoded = json.dumps(identity, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(encoded.encode("utf-8")).hexdigest()


def read_receipt(path: Path) -> Dict[str, object]:
    try:
        info = path.lstat()
    except OSError as exc:
        raise CaptureError("cannot read receipt: %s" % exc)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise CaptureError("receipt is not a regular file")
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise CaptureError("receipt mode is not 600")
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise CaptureError("receipt is not valid JSON: %s" % exc)
    if not isinstance(data, dict):
        raise CaptureError("receipt is not an object")
    return data


def write_receipt(path: Path, body: Dict[str, object]) -> None:
    encoded = json.dumps(
        body, ensure_ascii=False, sort_keys=True, separators=(",", ":")
    ).encode("utf-8")
    directory = path.parent
    tmp_name = None
    try:
        fd, tmp_name = tempfile.mkstemp(prefix=".receipt.", dir=str(directory))
        try:
            os.fchmod(fd, 0o600)
            written = 0
            while written < len(encoded):
                count = os.write(fd, encoded[written:])
                if count == 0:
                    raise OSError("receipt write made no progress")
                written += count
            os.fsync(fd)
        finally:
            os.close(fd)
        os.replace(tmp_name, str(path))
        dir_fd = os.open(str(directory), os.O_RDONLY)
        try:
            os.fsync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError as exc:
        raise UserError("cannot write the capture receipt: %s" % exc)
    finally:
        if tmp_name is not None:
            try:
                Path(tmp_name).unlink()
            except FileNotFoundError:
                pass
            except OSError:
                pass


def parse_payload(line: str) -> Dict[str, object]:
    try:
        payload = json.loads(line)
    except ValueError as exc:
        raise PayloadError("payload is not valid JSON: %s" % exc)
    if not isinstance(payload, dict):
        raise PayloadError("payload is not an object")
    update_id = positive_int(payload.get("update_id"), "update_id")
    text = payload.get("text")
    if not isinstance(text, str) or not text:
        raise PayloadError("text is not a nonempty string", update_id)
    try:
        text.encode("utf-8")
    except UnicodeEncodeError:
        raise PayloadError("text is not valid UTF-8", update_id)
    chat_id = payload.get("chat_id")
    if type(chat_id) is not int or isinstance(chat_id, bool):
        raise PayloadError("chat_id is not an integer", update_id)
    return {
        "update_id": update_id,
        "text": text,
        "chat_id": chat_id,
    }


def http_failure_error(status: int):
    if 400 <= status < 500 and status not in SYSTEMIC_HTTP_STATUSES:
        return CaptureError
    return UserError


def curl_config_value(value: str) -> str:
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise UserError("a curl config value contains control bytes")
    return value.replace("\\", "\\\\").replace('"', '\\"')


class JsonResponseReader:
    def __init__(self, path: Path) -> None:
        self.stream = path.open("r", encoding="utf-8")
        self.pending = ""

    def close(self) -> None:
        self.stream.close()

    def take(self) -> str:
        if self.pending:
            char = self.pending
            self.pending = ""
            return char
        return self.stream.read(1)

    def push(self, char: str) -> None:
        self.pending = char

    def nonspace(self) -> str:
        char = self.take()
        while char and char in " \t\r\n":
            char = self.take()
        return char

    def string(self, limit: int = 0) -> Optional[str]:
        raw = ['"'] if limit else None
        escaped = False
        unicode_left = 0
        while True:
            char = self.take()
            if not char or (ord(char) < 32 and not escaped):
                raise ValueError("invalid JSON string")
            if raw is not None and len(raw) <= limit:
                raw.append(char)
            if unicode_left:
                if char not in "0123456789abcdefABCDEF":
                    raise ValueError("invalid JSON escape")
                unicode_left -= 1
                escaped = unicode_left != 0
                continue
            if escaped:
                if char == "u":
                    unicode_left = 4
                elif char not in '"\\/bfnrt':
                    raise ValueError("invalid JSON escape")
                escaped = unicode_left != 0
                continue
            if char == "\\":
                escaped = True
            elif char == '"':
                break
        if raw is None or len(raw) > limit:
            return None
        return json.loads("".join(raw))

    def number(self, first: str) -> None:
        char = first
        if char == "-":
            char = self.take()
        if char == "0":
            char = self.take()
            if char.isdigit():
                raise ValueError("invalid JSON number")
        elif char in "123456789":
            char = self.take()
            while char.isdigit():
                char = self.take()
        else:
            raise ValueError("invalid JSON number")
        if char == ".":
            char = self.take()
            if not char.isdigit():
                raise ValueError("invalid JSON number")
            while char.isdigit():
                char = self.take()
        if char in "eE":
            char = self.take()
            if char in "+-":
                char = self.take()
            if not char.isdigit():
                raise ValueError("invalid JSON number")
            while char.isdigit():
                char = self.take()
        self.push(char)

    def value(self, first: str, depth: int, collect_string: bool = False) -> object:
        if depth > MAX_JSON_DEPTH:
            raise ValueError("JSON nesting is too deep")
        if first == '"':
            return self.string(MAX_CAPTURE_ID_CHARS * 6 + 2 if collect_string else 0)
        if first == "{":
            return self.object(depth + 1, False)
        if first == "[":
            char = self.nonspace()
            if char == "]":
                return None
            while True:
                self.value(char, depth + 1)
                char = self.nonspace()
                if char == "]":
                    return None
                if char != ",":
                    raise ValueError("invalid JSON array")
                char = self.nonspace()
        if first in "-0123456789":
            self.number(first)
            return None
        literal = {"t": "rue", "f": "alse", "n": "ull"}.get(first)
        if literal is None or "".join(self.take() for _ in literal) != literal:
            raise ValueError("invalid JSON value")
        return None

    def object(self, depth: int, capture_top_level: bool) -> object:
        capture_id = None
        char = self.nonspace()
        if char == "}":
            return capture_id
        while True:
            if char != '"':
                raise ValueError("invalid JSON object")
            key = self.string(64)
            if self.nonspace() != ":":
                raise ValueError("invalid JSON object")
            char = self.nonspace()
            collecting = capture_top_level and key == "capture_id"
            value = self.value(char, depth, collecting)
            if collecting:
                capture_id = value
            char = self.nonspace()
            if char == "}":
                return capture_id
            if char != ",":
                raise ValueError("invalid JSON object")
            char = self.nonspace()


def oversized_json_capture_id(path: Path) -> object:
    reader = JsonResponseReader(path)
    try:
        first = reader.nonspace()
        if first == "{":
            capture_id = reader.object(1, True)
        else:
            reader.value(first, 1)
            capture_id = None
        if reader.nonspace():
            raise ValueError("trailing JSON data")
        return capture_id
    finally:
        reader.close()


def post_capture(
    token: str, brain_url: str, text: str, source: str, workdir: Path, timeout: int
) -> str:
    body = json.dumps({"text": text, "source": source}, ensure_ascii=False)
    staged = []
    try:
        try:
            for prefix in (".beanz-body.", ".beanz-resp."):
                fd, name = tempfile.mkstemp(prefix=prefix, dir=str(workdir))
                staged.append(Path(name))
                try:
                    os.fchmod(fd, 0o600)
                finally:
                    os.close(fd)
        except OSError as exc:
            raise UserError("cannot stage the brain capture request: %s" % exc)
        body_path, resp_path = staged
        config = (
            'url = "%s/v1/capture"\n'
            'header = "Authorization: Bearer %s"\n'
            'header = "Content-Type: application/json"\n'
            'data-binary = "@%s"\n'
            % (
                curl_config_value(brain_url),
                curl_config_value(token),
                curl_config_value(str(body_path)),
            )
        )
        try:
            body_path.write_bytes(body.encode("utf-8"))
        except OSError as exc:
            raise UserError("cannot stage the brain capture request: %s" % exc)
        try:
            completed = subprocess.run(
                [
                    "curl",
                    "-q",
                    "-s",
                    "-o",
                    str(resp_path),
                    "-w",
                    "%{http_code}",
                    "--max-time",
                    str(timeout),
                    "-K",
                    "-",
                ],
                input=config.encode("utf-8"),
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                timeout=timeout + 5,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as exc:
            raise UserError("brain capture transport failed: %s" % exc)
        if completed.returncode != 0:
            raise UserError(
                "brain capture transport failed: curl exit %d" % completed.returncode
            )
        try:
            status_text = completed.stdout.decode("ascii").strip()
        except UnicodeDecodeError:
            raise UserError("brain capture returned a malformed status")
        if not re.fullmatch(r"[0-9]{3}", status_text):
            raise UserError("brain capture returned a malformed status")
        status = int(status_text)
        if not 200 <= status < 300:
            raise http_failure_error(status)(
                "brain capture failed with HTTP %s" % status
            )
        try:
            oversized = resp_path.stat().st_size > MAX_RESPONSE_BYTES
            if oversized:
                capture_id = oversized_json_capture_id(resp_path)
            else:
                raw = resp_path.read_bytes()
                response = json.loads(raw.decode("utf-8"))
                capture_id = (
                    response.get("capture_id") if isinstance(response, dict) else None
                )
        except OSError as exc:
            raise UserError("cannot read the brain capture response: %s" % exc)
        except (UnicodeDecodeError, ValueError):
            raise UserError("brain capture returned a non-JSON response")
        if oversized and capture_id is None:
            raise CaptureError("brain capture response is too large")
        return validated_capture_id(capture_id, "brain capture", CaptureError)
    finally:
        for path in staged:
            try:
                path.unlink()
            except OSError:
                pass


def classify_chat(
    chat_id: int, captain_chat: int, group_on: bool
) -> Tuple[Optional[str], Optional[str]]:
    if chat_id == captain_chat:
        return CAPTAIN_SOURCE, None
    if chat_id >= 0:
        return None, "private"
    if not group_on:
        return None, "group"
    return GROUP_SOURCE, None


def capture_line(
    line: str,
    receipts: Path,
    token: str,
    brain_url: str,
    captain_chat: int,
    group_on: bool,
    timeout: int,
) -> str:
    payload = parse_payload(line)
    update_id = int(payload["update_id"])
    try:
        return capture_payload(
            payload, receipts, token, brain_url, captain_chat, group_on, timeout
        )
    except CaptureError as exc:
        raise CaptureError("%d %s" % (update_id, exc))
    except UserError as exc:
        raise UserError("%d %s" % (update_id, exc))


def capture_payload(
    payload: Dict[str, object],
    receipts: Path,
    token: str,
    brain_url: str,
    captain_chat: int,
    group_on: bool,
    timeout: int,
) -> str:
    update_id = int(payload["update_id"])
    chat_id = int(payload["chat_id"])
    source, skipped = classify_chat(chat_id, captain_chat, group_on)
    if source is None:
        return "skipped:%s %d" % (skipped, update_id)
    digest = payload_hash(payload)
    path = receipt_path(receipts, update_id)
    if path.exists() or path.is_symlink():
        existing = read_receipt(path)
        if existing.get("payload_sha256") != digest:
            raise CaptureError("receipt disagrees with the payload")
        capture_id = validated_capture_id(
            existing.get("capture_id"), "receipt", CaptureError
        )
        return "already-captured %d %s" % (update_id, capture_id)
    capture_id = post_capture(
        token, brain_url, str(payload["text"]), source, receipts, timeout
    )
    failpoint("before-receipt")
    write_receipt(
        path,
        {
            "update_id": update_id,
            "payload_sha256": digest,
            "capture_id": capture_id,
            "source": source,
            "captured_at": int(time.time()),
        },
    )
    return "captured %d %s" % (update_id, capture_id)


def iter_payload_lines(raw: str) -> Iterable[str]:
    for line in raw.split("\n"):
        record = line.rstrip("\r")
        if record.strip():
            yield record


def pending_post_count(
    lines: list, state: Path, captain_chat: Optional[int], group_on: bool
) -> int:
    receipts = state / RECEIPT_DIR_NAME
    count = 0
    for line in lines:
        try:
            payload = parse_payload(line)
        except PayloadError:
            continue
        if captain_chat is not None:
            source, _ = classify_chat(int(payload["chat_id"]), captain_chat, group_on)
            if source is None:
                continue
        path = receipts / str(int(payload["update_id"]))
        if path.exists() or path.is_symlink():
            continue
        count += 1
    return count


def report_unattempted(
    lines: list, state: Path, captain_chat: Optional[int], group_on: bool
) -> None:
    remaining = pending_post_count(lines, state, captain_chat, group_on)
    if remaining:
        print("unattempted %d" % remaining)


def decode_payload_input(data: bytes) -> str:
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise UserError("payload input is not UTF-8: %s" % exc)


def command_capture(state: Path, config: Path) -> int:
    try:
        data = sys.stdin.buffer.read()
    except OSError as exc:
        raise UserError("cannot read the payload batch: %s" % exc)
    try:
        missing = unconfigured_reason()
    except UserError as exc:
        print("error: %s" % exc, file=sys.stderr)
        try:
            raw = decode_payload_input(data)
            lines = list(iter_payload_lines(raw))
        except UserError:
            lines = []
        report_unattempted(lines, state, None, False)
        return 1
    if missing:
        print("capture-unconfigured %s" % missing)
        return 0
    raw = decode_payload_input(data)
    lines = list(iter_payload_lines(raw))
    captain_chat = None
    group_on = False
    try:
        group_on = group_capture_enabled(config)
        captain_chat = captain_chat_id()
        token, brain_url = brain_credentials()
        timeout = timeout_seconds()
        receipts = ensure_receipt_dir(state)
    except UserError as exc:
        print("error: %s" % exc, file=sys.stderr)
        report_unattempted(lines, state, captain_chat, group_on)
        return 1
    failed = False
    for index, line in enumerate(lines):
        try:
            print(
                capture_line(
                    line, receipts, token, brain_url, captain_chat, group_on, timeout
                )
            )
        except PayloadError as exc:
            marker = "-" if exc.update_id is None else str(exc.update_id)
            print("skipped:unsupported %s %s" % (marker, exc))
        except CaptureError as exc:
            print("error: %s" % exc, file=sys.stderr)
            failed = True
        except UserError as exc:
            print("error: %s" % exc, file=sys.stderr)
            failed = True
            report_unattempted(lines[index + 1:], state, captain_chat, group_on)
            break
    return 1 if failed else 0


def command_doctor(state: Path, config: Path) -> int:
    brain_path = brain_env_path()
    telegram_path = telegram_env_path()
    brain_state = "missing"
    brain_url = "unknown"
    try:
        _, brain_url = brain_credentials()
        brain_state = "present"
    except UserError:
        try:
            brain_missing = path_is_absent(brain_path, "brain credentials")
        except UserError:
            brain_missing = False
        if not brain_missing:
            brain_state = "unreadable"
    chat_state = "missing"
    try:
        captain_chat_id()
        chat_state = "configured"
    except UserError:
        try:
            chat_missing = path_is_absent(telegram_path, "Telegram credentials")
        except UserError:
            chat_missing = False
        if not chat_missing or os.environ.get("FM_TELEGRAM_CAPTAIN_CHAT_ID"):
            chat_state = "unreadable"
    try:
        group_state = "on" if group_capture_enabled(config) else "off"
    except UserError:
        group_state = "unreadable"
    receipt_state, _ = inspect_receipt_dir(state)
    print("brain-env: %s" % brain_state)
    print("brain-url: %s" % brain_url)
    print("captain-chat: %s" % chat_state)
    print("group-capture: %s" % group_state)
    print("receipts: %s" % receipt_state)
    return 0


def main(argv: Optional[list] = None) -> int:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--state", required=True)
    parser.add_argument("--config", required=True)
    parser.add_argument("command")
    args = parser.parse_args(argv)
    state = Path(args.state)
    config = Path(args.config)
    try:
        if args.command == "capture":
            return command_capture(state, config)
        if args.command == "doctor":
            return command_doctor(state, config)
        raise UserError("unknown engine command: %s" % args.command)
    except UserError as exc:
        print("error: %s" % exc, file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
