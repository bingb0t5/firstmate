#!/usr/bin/env python3
"""Transactional state owner for the Telegram process-event adapter.

The shell adapter delegates every Telegram-specific state transition to this
module.  A poll validates a complete external event before opening one SQLite
transaction, then commits accepted messages, their durable notice, and the
next offset together.  Rejected input never reaches that transaction.

The database is the only authoritative live state after initialization or
migration.  Legacy files remain untouched as migration evidence and are never
read by ordinary polling.
"""

import argparse
import datetime
import hashlib
import json
import os
import re
import select
import shlex
import shutil
import sqlite3
import stat
import subprocess
import sys
import tempfile
import time
import urllib.parse
import uuid
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Dict, Iterable, List, Optional, Sequence, Tuple


SCHEMA_VERSION = 1
MAX_REPLY_BYTES = 65536
# The Bot API accepts 1-4096 characters in the sendMessage text field and counts
# them as UTF-16 code units, the same unit it uses for entity offsets.
MAX_REPLY_CHARS = 4096
# Telegram keeps an undelivered update for about a day, so a reply still owed
# past that window is no longer an in-conversation answer worth tracking.
RETAINED_REPLY_INTENT_SECONDS = 86400
MAX_SEND_TIME = 300
DOCTOR_REPLY_ATTENTION_LIMIT = 10
REPLY_LABEL_COUNTS_SQL = (
    "SELECT CASE"
    " WHEN state = 'sent' THEN 'sent'"
    " WHEN state = 'failed' THEN 'definitely-failed'"
    " WHEN state = 'unknown' OR network_started = 1 THEN 'delivery-unknown'"
    " ELSE 'reserved' END AS label, COUNT(*) FROM replies GROUP BY label"
)
REPLY_STATES = {"reserved", "sent", "failed", "unknown"}
DELIVERY_UNKNOWN_GUIDANCE = (
    "delivery is unknown; automatic retry is refused; inspect durable reply state with: doctor"
)
# The Bot API declares Update identifiers as positive Integers and says an
# unspecified Integer field is safe in a signed 32-bit value, so the ceiling is
# that published contract rather than any local arithmetic width.
MAX_UPDATE_ID = 2**31 - 1
MAX_OFFSET = MAX_UPDATE_ID + 1
MAX_CREDENTIAL_BYTES = 65536
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
EXPECTED_CREDENTIAL_KEYS = {
    "TELEGRAM_BOT_TOKEN",
    "TELEGRAM_CAPTAIN_CHAT_ID",
    "TELEGRAM_CAPTAIN_USER_ID",
}
NOTICE_KINDS = {
    "message",
    "api-blocked",
    "credential-blocked",
    "protocol-blocked",
    "transport-blocked",
    "migration-blocked",
}
CONDITION_KINDS = {
    "api-401",
    "api-409",
    "credential",
    "protocol",
    "transport",
}
DETAIL_RE = re.compile(r"^[a-z0-9][a-z0-9.-]{0,63}$")
MIGRATION_CAUSE_RE = re.compile(r"^[^\x00-\x1f\x7f]{1,240}$")
CONTROL_BYTE_RE = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f-\x9f]")
FOREIGN_PATH_RE = re.compile(r"(?<![\w.\-/])/[^\s:'\"]+")
ARCHIVE_PARENT_NAME = "telegram-migration-archive"
ARCHIVE_SCHEMA = "fm-telegram-migration-archive.v1"
ARCHIVE_NAME_RE = re.compile(r"^[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}$")
STAGING_PREFIX = ".telegram-migration-staging-"
STAGING_GLOB = STAGING_PREFIX + "*"
STAGING_MARKER_SUFFIX = ".owner"
STAGING_NAME_RE = re.compile(r"^\.telegram-migration-staging-[0-9]+-[0-9a-f]{8}$")
STAGING_SCHEMA = "fm-telegram-migration-staging.v1"
DATABASE_TEMP_GLOB = ".channel.db.*"
DATABASE_TEMP_RE = re.compile(r"^\.channel\.db\.[0-9]+\.[0-9a-f]{32}$")
DATABASE_STAGING_SCHEMA = "fm-telegram-database-staging.v1"
DATABASE_JOURNAL_SUFFIX = "-journal"
STATUS_TRAILER_BYTES = 4
STATUS_TRAILER_RE = re.compile(rb"\n[0-9]{3}")
ARCHIVE_ENTRY_TYPES = ("file", "directory", "symlink", "other")
RESOLUTION_DIGEST_RE = re.compile(r"[0-9a-f]{64}")
ACKNOWLEDGEMENT_PATH_RE = re.compile(
    r"^(?:telegram-inbox|\.telegram-delivery-receipts)/[1-9][0-9]*\.json$"
)
NOTICE_TOKEN_RE = re.compile(
    r"^(?P<state>[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-"
    r"[0-9a-f]{4}-[0-9a-f]{12}):(?P<notice>[1-9][0-9]*)$"
)
MESSAGE_RESULT_RE = re.compile(
    r"^message: (?P<count>[1-9][0-9]*) notice=(?P<token>[^ ]+)$"
)
BLOCKED_RESULT_RE = re.compile(
    r"^blocked: (?P<kind>[a-z0-9-]+) (?P<detail>[a-z0-9.-]+) "
    r"notice=(?P<token>[^ ]+)$"
)
LOCAL_BLOCKED_RESULT_RE = re.compile(
    r"^blocked: local-state fingerprint=(?P<fingerprint>[0-9a-f]{16})$"
)
LEGACY_EXACT_PATHS = (
    ".telegram-offset",
    ".telegram-blocked",
    ".telegram-pending-delivery",
    ".telegram-delivery-receipts",
    "telegram-inbox",
    "telegram-watch.check.sh",
    "telegram-watch.check-trust",
)
LEGACY_TEMP_PATTERNS = (
    ".telegram-offset.*",
    ".telegram-blocked.*",
    ".telegram-pending-delivery.*",
)


class UserError(Exception):
    """An explicit operator action or valid external configuration is needed."""


class LocalStateError(Exception):
    """The authoritative store cannot safely produce a transition."""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


class CredentialError(Exception):
    """The credential snapshot is missing or invalid."""


class ProtocolError(Exception):
    """A Telegram response cannot be accepted as a complete typed batch."""


class ApiRefusal(ProtocolError):
    """Telegram explicitly refused a send request."""


@dataclass(frozen=True)
class Credentials:
    token: str
    captain_chat_id: int
    captain_user_id: int


@dataclass(frozen=True)
class SendRequest:
    body_file: IO[bytes]
    max_time: int

    def close(self) -> None:
        self.body_file.close()


@dataclass(frozen=True)
class PlannedMessage:
    update_id: int
    payload: Optional[str]


@dataclass(frozen=True)
class BatchPlan:
    next_offset: int
    messages: Tuple[PlannedMessage, ...]
    empty: bool


@dataclass(frozen=True)
class ParsedResult:
    classification: str
    notice_id: Optional[int]
    state_uuid: Optional[str]
    count: Optional[int]
    kind: Optional[str]
    detail: Optional[str]


@dataclass
class MigrationPlan:
    offset: int
    handled_messages: List[PlannedMessage]
    pending_messages: List[PlannedMessage]
    api_conditions: List[str]


@dataclass(frozen=True)
class ResolutionPayload:
    path: str
    update_id: int
    sha256: str
    size: int


@dataclass
class ResolutionEvidence:
    fingerprint: str
    archive_manifest_sha256: str
    payloads: List[ResolutionPayload]
    plan: MigrationPlan


def now_epoch() -> int:
    return int(time.time())


def failpoint(name: str) -> None:
    if os.environ.get("FM_TELEGRAM_FAILPOINT") == name:
        os._exit(91)


def synchronization_failpoint(name: str) -> None:
    if os.environ.get("FM_TELEGRAM_FAILPOINT") != name:
        return
    marker = os.environ.get("FM_TELEGRAM_FAILPOINT_MARKER")
    release = os.environ.get("FM_TELEGRAM_FAILPOINT_RELEASE")
    if not marker or not release:
        raise LocalStateError("failpoint-config", "synchronization paths are missing")
    fd = os.open(marker, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(fd)
    deadline = time.monotonic() + 10
    while not os.path.exists(release):
        if time.monotonic() >= deadline:
            raise LocalStateError("failpoint-timeout", name)
        time.sleep(0.01)


def raising_failpoint(name: str) -> None:
    if os.environ.get("FM_TELEGRAM_FAILPOINT") == name:
        raise LocalStateError("failpoint", name)


class Publication:
    """Tracks whether the irreversible database publication already happened."""

    def __init__(self) -> None:
        self.published = False


def clean_error_detail(value: object) -> str:
    text = str(value)
    text = re.sub(r"/[^ \n:]+", "<path>", text)
    text = re.sub(r"\s+", " ", text).strip()
    return text[:240]


def state_fingerprint(code: str, detail: object) -> str:
    material = "%s\0%s" % (code, clean_error_detail(detail))
    return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]


def migration_cause_text(state: Path, error: BaseException) -> str:
    text = str(error)
    if not isinstance(error, UserError):
        text = "%s: %s" % (error.__class__.__name__, text)
    text = relative_to_state(state, text)
    text = FOREIGN_PATH_RE.sub("<path>", text)
    text = CONTROL_BYTE_RE.sub("?", text)
    text = re.sub(r"\s+", " ", text).strip()
    text = text[:240] or error.__class__.__name__
    if not MIGRATION_CAUSE_RE.fullmatch(text):
        return "unprintable migration failure detail (%s)" % error.__class__.__name__
    return text


def relative_to_state(state: Path, text: str) -> str:
    prefix = str(state)
    text = text.replace(prefix + os.sep, "")
    return text.replace(prefix, "<state>")


def copy_failure_detail(state: Path, error: BaseException) -> str:
    if isinstance(error, shutil.Error) and error.args:
        reasons = []
        for item in error.args[0] if isinstance(error.args[0], list) else []:
            if isinstance(item, tuple) and len(item) == 3:
                reasons.append("%s (%s)" % (relative_to_state(state, str(item[0])), item[2]))
        if reasons:
            return "; ".join(reasons[:3])
    return str(error)


def local_block_line(error: object) -> str:
    if isinstance(error, LocalStateError):
        code = error.code
        detail = error.detail
    else:
        code = error.__class__.__name__
        detail = clean_error_detail(error)
    return "blocked: local-state fingerprint=%s" % state_fingerprint(code, detail)


def valid_update_id(value: object) -> bool:
    return type(value) is int and 1 <= value <= MAX_UPDATE_ID


def validate_positive_int(value: str, name: str, maximum: Optional[int] = None) -> int:
    if not re.fullmatch(r"[1-9][0-9]*", value):
        raise UserError("%s must be a positive integer" % name)
    parsed = int(value)
    if maximum is not None and parsed > maximum:
        raise UserError("%s must be at most %d" % (name, maximum))
    return parsed


def state_paths(state: Path) -> Tuple[Path, Path]:
    return state / "telegram", state / "telegram" / "channel.db"


def ensure_existing_directory(path: Path, exact_mode: Optional[int] = None) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise LocalStateError("directory-unreadable", str(exc))
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise LocalStateError("directory-unsafe", str(path))
    if exact_mode is not None and stat.S_IMODE(info.st_mode) != exact_mode:
        raise LocalStateError("directory-mode", "%s mode is not %o" % (path, exact_mode))


def ensure_telegram_directory(state: Path, create: bool) -> Path:
    ensure_existing_directory(state)
    telegram_dir, _ = state_paths(state)
    if not telegram_dir.exists():
        if not create:
            raise LocalStateError("database-directory-missing", str(telegram_dir))
        try:
            telegram_dir.mkdir(mode=0o700)
            fsync_directory(state)
        except OSError as exc:
            raise LocalStateError("database-directory-create", str(exc))
    ensure_existing_directory(telegram_dir, 0o700)
    return telegram_dir


def ensure_private_database(path: Path) -> None:
    try:
        info = path.lstat()
    except OSError as exc:
        raise LocalStateError("database-missing", str(exc))
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise LocalStateError("database-unsafe", str(path))
    if stat.S_IMODE(info.st_mode) != 0o600:
        raise LocalStateError("database-mode", "%s mode is not 600" % path)


def fsync_directory(path: Path) -> None:
    flags = os.O_RDONLY
    if hasattr(os, "O_DIRECTORY"):
        flags |= os.O_DIRECTORY
    fd = os.open(str(path), flags)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def fsync_path(path: Path) -> None:
    try:
        fd = os.open(str(path), os.O_RDONLY)
    except OSError:
        return
    try:
        os.fsync(fd)
    except OSError:
        pass
    finally:
        os.close(fd)


def configure_connection(conn: sqlite3.Connection) -> None:
    conn.execute("PRAGMA foreign_keys = ON")
    conn.execute("PRAGMA trusted_schema = OFF")
    conn.execute("PRAGMA busy_timeout = 5000")
    mode = conn.execute("PRAGMA journal_mode = DELETE").fetchone()
    if mode is None or str(mode[0]).lower() != "delete":
        raise LocalStateError("journal-mode", "SQLite refused rollback journaling")
    conn.execute("PRAGMA synchronous = FULL")
    conn.execute("PRAGMA fullfsync = ON")
    conn.execute("PRAGMA checkpoint_fullfsync = ON")
    conn.execute("PRAGMA temp_store = MEMORY")


def required_schema() -> Dict[str, Tuple[str, ...]]:
    return {
        "meta": (
            "singleton",
            "schema_version",
            "state_uuid",
            "committed_offset",
            "last_success",
            "consecutive_failures",
            "first_failure",
            "migration_status",
            "migration_archive",
            "migration_fingerprint",
            "migration_cause",
        ),
        "notices": (
            "id",
            "kind",
            "detail",
            "created_at",
            "acknowledged_at",
        ),
        "messages": (
            "update_id",
            "payload",
            "notice_id",
            "handled_at",
        ),
        "conditions": (
            "kind",
            "detail",
            "notice_id",
            "started_at",
        ),
    }


def reply_schema() -> Tuple[str, ...]:
    return (
        "update_id",
        "body_sha256",
        "state",
        "reserved_at",
        "updated_at",
        "network_started",
        "telegram_message_id",
        "failure_detail",
    )


def ensure_reply_schema(conn: sqlite3.Connection) -> None:
    conn.execute(
        """
        CREATE TABLE IF NOT EXISTS replies (
            update_id INTEGER PRIMARY KEY REFERENCES messages(update_id) ON DELETE RESTRICT,
            body_sha256 TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('reserved', 'sent', 'failed', 'unknown')),
            reserved_at INTEGER NOT NULL CHECK (reserved_at >= 0),
            updated_at INTEGER NOT NULL CHECK (updated_at >= reserved_at),
            network_started INTEGER NOT NULL DEFAULT 0 CHECK (network_started IN (0, 1)),
            telegram_message_id INTEGER,
            failure_detail TEXT,
            CHECK (
                (state = 'sent' AND telegram_message_id IS NOT NULL AND failure_detail IS NULL)
                OR (state = 'reserved' AND telegram_message_id IS NULL AND failure_detail IS NULL)
                OR (state = 'unknown' AND telegram_message_id IS NULL AND failure_detail IS NOT NULL)
                OR (state = 'failed' AND telegram_message_id IS NULL AND failure_detail IS NOT NULL)
            )
        )
        """
    )
    conn.commit()


def validate_reply_rows(conn: sqlite3.Connection) -> None:
    rows = conn.execute("PRAGMA table_info(replies)").fetchall()
    if tuple(row[1] for row in rows) != reply_schema():
        raise LocalStateError("reply-columns", repr(tuple(row[1] for row in rows)))
    for row in conn.execute(
        "SELECT update_id, body_sha256, state, reserved_at, updated_at, "
        "network_started, telegram_message_id, failure_detail FROM replies"
    ):
        update_id, digest, state, reserved_at, updated_at, started, sent_id, failure = row
        if not valid_update_id(update_id):
            raise LocalStateError("reply-update-id", repr(update_id))
        if not isinstance(digest, str) or RESOLUTION_DIGEST_RE.fullmatch(digest) is None:
            raise LocalStateError("reply-digest", repr(update_id))
        if state not in REPLY_STATES:
            raise LocalStateError("reply-state", repr(state))
        if type(reserved_at) is not int or reserved_at < 0:
            raise LocalStateError("reply-reserved", repr(update_id))
        if type(updated_at) is not int or updated_at < reserved_at:
            raise LocalStateError("reply-updated", repr(update_id))
        if started not in (0, 1):
            raise LocalStateError("reply-network-started", repr(update_id))
        if state == "sent":
            if type(sent_id) is not int or sent_id <= 0 or failure is not None:
                raise LocalStateError("reply-sent-shape", repr(update_id))
        elif state == "failed":
            if sent_id is not None or not isinstance(failure, str) or not DETAIL_RE.fullmatch(failure):
                raise LocalStateError("reply-failed-shape", repr(update_id))
        elif state == "unknown":
            if sent_id is not None or not isinstance(failure, str) or not DETAIL_RE.fullmatch(failure):
                raise LocalStateError("reply-unknown-shape", repr(update_id))
        elif sent_id is not None or failure is not None:
            raise LocalStateError("reply-pending-shape", repr(update_id))
        if conn.execute(
            "SELECT 1 FROM messages WHERE update_id = ? AND payload IS NOT NULL",
            (update_id,),
        ).fetchone() is None:
            raise LocalStateError("reply-inbound-missing", repr(update_id))


def resolution_extension_tables(conn: sqlite3.Connection) -> Tuple[bool, bool]:
    names = {
        row[0]
        for row in conn.execute(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN "
            "('migration_resolution', 'migration_resolution_payloads')"
        )
    }
    return "migration_resolution" in names, "migration_resolution_payloads" in names


def validate_resolution_extension(
    conn: sqlite3.Connection, migration_status: str
) -> Optional[Tuple[str, str, int, int]]:
    has_resolution, has_payloads = resolution_extension_tables(conn)
    if has_resolution != has_payloads:
        raise LocalStateError("resolution-tables", "resolution proof tables are incomplete")
    if not has_resolution:
        return None
    if migration_status != "complete":
        raise LocalStateError("resolution-status", "resolution proof is not complete")
    meta = conn.execute(
        "SELECT migration_archive, migration_fingerprint FROM meta WHERE singleton = 1"
    ).fetchone()
    if (
        meta is None
        or not isinstance(meta[0], str)
        or not isinstance(meta[1], str)
        or not re.fullmatch(r"[0-9a-f]{16}", meta[1])
    ):
        raise LocalStateError("resolution-binding", "resolution proof has no migration binding")
    expected_resolution = (
        "singleton",
        "kind",
        "blocked_fingerprint",
        "archive_manifest_sha256",
        "acknowledged_at",
        "payload_count",
    )
    expected_payloads = (
        "path",
        "update_id",
        "sha256",
        "size",
        "resolution",
    )
    for table, expected in (
        ("migration_resolution", expected_resolution),
        ("migration_resolution_payloads", expected_payloads),
    ):
        rows = conn.execute("PRAGMA table_info(%s)" % table).fetchall()
        columns = tuple(row[1] for row in rows)
        if columns != expected:
            raise LocalStateError("resolution-columns", "%s:%r" % (table, columns))
    resolutions = conn.execute(
        "SELECT singleton, kind, blocked_fingerprint, archive_manifest_sha256, "
        "acknowledged_at, payload_count FROM migration_resolution"
    ).fetchall()
    if len(resolutions) != 1:
        raise LocalStateError("resolution-row", "expected one resolution row")
    singleton, kind, fingerprint, manifest_digest, acknowledged_at, payload_count = resolutions[0]
    if singleton != 1 or kind != "operator-acknowledged-delivery":
        raise LocalStateError("resolution-kind", repr(kind))
    if not isinstance(fingerprint, str) or not re.fullmatch(r"[0-9a-f]{16}", fingerprint):
        raise LocalStateError("resolution-fingerprint", repr(fingerprint))
    if fingerprint != meta[1]:
        raise LocalStateError("resolution-fingerprint", "proof does not match migration")
    if not isinstance(manifest_digest, str) or not RESOLUTION_DIGEST_RE.fullmatch(manifest_digest):
        raise LocalStateError("resolution-manifest", repr(manifest_digest))
    if type(acknowledged_at) is not int or acknowledged_at < 0:
        raise LocalStateError("resolution-time", repr(acknowledged_at))
    if type(payload_count) is not int or payload_count <= 0:
        raise LocalStateError("resolution-count", repr(payload_count))
    if conn.execute(
        "SELECT COUNT(*) FROM notices "
        "WHERE kind = 'migration-blocked' AND acknowledged_at IS NULL"
    ).fetchone()[0] != 0:
        raise LocalStateError(
            "resolution-notices", "resolved proof has a pending migration notice"
        )
    payloads = conn.execute(
        "SELECT path, update_id, sha256, size, resolution "
        "FROM migration_resolution_payloads ORDER BY path"
    ).fetchall()
    if len(payloads) != payload_count:
        raise LocalStateError("resolution-count", "payload count does not match rows")
    update_digests: Dict[int, str] = {}
    for path, update_id, digest, size, resolution in payloads:
        if not isinstance(path, str) or ACKNOWLEDGEMENT_PATH_RE.fullmatch(path) is None:
            raise LocalStateError("resolution-path", repr(path))
        if int(Path(path).stem) != update_id:
            raise LocalStateError("resolution-update-id", repr(path))
        if not valid_update_id(update_id):
            raise LocalStateError("resolution-update-id", repr(update_id))
        if not isinstance(digest, str) or not RESOLUTION_DIGEST_RE.fullmatch(digest):
            raise LocalStateError("resolution-digest", repr(path))
        previous_digest = update_digests.get(update_id)
        if previous_digest is not None and previous_digest != digest:
            raise LocalStateError("resolution-conflict", repr(update_id))
        update_digests[update_id] = digest
        if type(size) is not int or size < 0 or resolution != 1:
            raise LocalStateError("resolution-payload", repr(path))
        tombstone = conn.execute(
            "SELECT payload, notice_id, handled_at FROM messages WHERE update_id = ?",
            (update_id,),
        ).fetchone()
        if tombstone is None or tombstone[0] is not None or tombstone[1] is not None:
            raise LocalStateError("resolution-tombstone", repr(path))
        if type(tombstone[2]) is not int or tombstone[2] < 0:
            raise LocalStateError("resolution-tombstone", repr(path))
    return fingerprint, manifest_digest, acknowledged_at, payload_count


def verify_integrity(conn: sqlite3.Connection) -> None:
    quick = conn.execute("PRAGMA quick_check").fetchall()
    if quick != [("ok",)]:
        raise LocalStateError("integrity-check", repr(quick[:4]))


def validate_store(conn: sqlite3.Connection) -> None:
    version = conn.execute("PRAGMA user_version").fetchone()
    if version is None or version[0] != SCHEMA_VERSION:
        raise LocalStateError("schema-version", repr(version))
    for table, expected_columns in required_schema().items():
        rows = conn.execute("PRAGMA table_info(%s)" % table).fetchall()
        columns = tuple(row[1] for row in rows)
        if columns != expected_columns:
            raise LocalStateError("schema-columns", "%s:%r" % (table, columns))
    meta_rows = conn.execute(
        "SELECT schema_version, state_uuid, committed_offset, last_success, "
        "consecutive_failures, first_failure, migration_status, "
        "migration_archive, migration_fingerprint, migration_cause "
        "FROM meta WHERE singleton = 1"
    ).fetchall()
    if len(meta_rows) != 1:
        raise LocalStateError("meta-row", "expected one singleton row")
    (
        schema_version,
        store_uuid,
        offset,
        last_success,
        failure_count,
        first_failure,
        migration_status,
        migration_archive,
        migration_fingerprint,
        migration_cause,
    ) = meta_rows[0]
    try:
        uuid.UUID(store_uuid)
    except (ValueError, TypeError, AttributeError) as exc:
        raise LocalStateError("state-uuid", str(exc))
    if schema_version != SCHEMA_VERSION:
        raise LocalStateError("meta-schema-version", repr(schema_version))
    if type(offset) is not int or not 0 <= offset <= MAX_OFFSET:
        raise LocalStateError("committed-offset", repr(offset))
    if last_success is not None and (type(last_success) is not int or last_success < 0):
        raise LocalStateError("last-success", repr(last_success))
    if type(failure_count) is not int or failure_count < 0:
        raise LocalStateError("failure-count", repr(failure_count))
    if first_failure is not None and (type(first_failure) is not int or first_failure < 0):
        raise LocalStateError("first-failure", repr(first_failure))
    if migration_status not in ("fresh", "complete", "blocked"):
        raise LocalStateError("migration-status", repr(migration_status))
    if migration_archive is not None and not isinstance(migration_archive, str):
        raise LocalStateError("migration-archive", repr(migration_archive))
    if migration_fingerprint is not None and not re.fullmatch(
        r"[0-9a-f]{16}", migration_fingerprint
    ):
        raise LocalStateError("migration-fingerprint", repr(migration_fingerprint))
    if migration_cause is not None and not MIGRATION_CAUSE_RE.fullmatch(migration_cause):
        raise LocalStateError("migration-cause", repr(migration_cause)[:80])
    validate_resolution_extension(conn, migration_status)
    pending = conn.execute(
        "SELECT COUNT(*) FROM notices WHERE acknowledged_at IS NULL"
    ).fetchone()[0]
    if pending > 1:
        raise LocalStateError("pending-notices", "more than one notice is pending")
    notices = conn.execute(
        "SELECT id, kind, detail, created_at, acknowledged_at FROM notices"
    ).fetchall()
    notice_map = {}
    for notice_id, kind, detail, created_at, acknowledged_at in notices:
        if type(notice_id) is not int or notice_id <= 0:
            raise LocalStateError("notice-id", repr(notice_id))
        if kind not in NOTICE_KINDS:
            raise LocalStateError("notice-kind", repr(kind))
        if not isinstance(detail, str) or not DETAIL_RE.fullmatch(detail):
            raise LocalStateError("notice-detail", repr(detail))
        if type(created_at) is not int or created_at < 0:
            raise LocalStateError("notice-created", repr(created_at))
        if acknowledged_at is not None and (
            type(acknowledged_at) is not int or acknowledged_at < created_at
        ):
            raise LocalStateError("notice-acknowledged", repr(acknowledged_at))
        notice_map[notice_id] = (kind, acknowledged_at)
    for kind, detail, notice_id, started_at in conn.execute(
        "SELECT kind, detail, notice_id, started_at FROM conditions"
    ):
        if kind not in CONDITION_KINDS:
            raise LocalStateError("condition-kind", repr(kind))
        if not isinstance(detail, str) or not DETAIL_RE.fullmatch(detail):
            raise LocalStateError("condition-detail", repr(detail))
        if notice_id is not None and notice_id not in notice_map:
            raise LocalStateError("condition-notice", repr(notice_id))
        if notice_id is not None:
            notice_kind, _ = notice_map[notice_id]
            if notice_kind != notice_kind_for_condition(kind):
                raise LocalStateError("condition-notice-kind", repr(notice_id))
            notice_detail = conn.execute(
                "SELECT detail FROM notices WHERE id = ?", (notice_id,)
            ).fetchone()[0]
            if notice_detail != detail:
                raise LocalStateError("condition-notice-detail", repr(notice_id))
        if type(started_at) is not int or started_at < 0:
            raise LocalStateError("condition-started", repr(started_at))
    for update_id, payload, notice_id, handled_at in conn.execute(
        "SELECT update_id, payload, notice_id, handled_at FROM messages"
    ):
        if not valid_update_id(update_id):
            raise LocalStateError("message-update-id", repr(update_id))
        if payload is None:
            if notice_id is not None or handled_at is None:
                raise LocalStateError("message-tombstone-shape", repr(update_id))
        else:
            try:
                decoded = json.loads(payload)
            except (TypeError, ValueError) as exc:
                raise LocalStateError("message-payload", str(exc))
            if (
                not isinstance(decoded, dict)
                or decoded.get("update_id") != update_id
                or not isinstance(decoded.get("text"), str)
                or not decoded.get("text")
                or not isinstance(decoded.get("chat_id"), int)
                or type(decoded.get("chat_id")) is bool
                or not isinstance(decoded.get("from_id"), int)
                or type(decoded.get("from_id")) is bool
                or (
                    "message_id" in decoded
                    and not valid_update_id(decoded.get("message_id"))
                )
            ):
                raise LocalStateError("message-payload-shape", repr(update_id))
        if notice_id is not None:
            notice = notice_map.get(notice_id)
            if notice is None or notice[0] != "message":
                raise LocalStateError("message-notice", repr(notice_id))
        if handled_at is None and notice_id is None:
            raise LocalStateError("unhandled-message-notice", repr(update_id))
        if handled_at is not None and (type(handled_at) is not int or handled_at < 0):
            raise LocalStateError("message-handled", repr(handled_at))
    validate_reply_rows(conn)


def connect_existing(state: Path) -> sqlite3.Connection:
    _, database = state_paths(state)
    ensure_telegram_directory(state, create=False)
    ensure_private_database(database)
    try:
        uri = "file:%s?mode=rw" % urllib.parse.quote(database.as_posix(), safe="")
        conn = sqlite3.connect(uri, uri=True, isolation_level=None, timeout=5)
        configure_connection(conn)
        verify_integrity(conn)
        ensure_reply_schema(conn)
        validate_store(conn)
        return conn
    except LocalStateError:
        raise
    except sqlite3.Error as exc:
        raise LocalStateError("database-open", str(exc))


def create_schema(conn: sqlite3.Connection) -> None:
    conn.executescript(
        """
        CREATE TABLE meta (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            schema_version INTEGER NOT NULL,
            state_uuid TEXT NOT NULL,
            committed_offset INTEGER NOT NULL
                CHECK (committed_offset >= 0 AND committed_offset <= 2147483648),
            last_success INTEGER,
            consecutive_failures INTEGER NOT NULL DEFAULT 0
                CHECK (consecutive_failures >= 0),
            first_failure INTEGER,
            migration_status TEXT NOT NULL
                CHECK (migration_status IN ('fresh', 'complete', 'blocked')),
            migration_archive TEXT,
            migration_fingerprint TEXT,
            migration_cause TEXT
        );
        CREATE TABLE notices (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            kind TEXT NOT NULL CHECK (
                kind IN (
                    'message',
                    'api-blocked',
                    'credential-blocked',
                    'protocol-blocked',
                    'transport-blocked',
                    'migration-blocked'
                )
            ),
            detail TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            acknowledged_at INTEGER
        );
        CREATE TABLE messages (
            update_id INTEGER PRIMARY KEY
                CHECK (update_id >= 1 AND update_id <= 2147483647),
            payload TEXT,
            notice_id INTEGER REFERENCES notices(id),
            handled_at INTEGER,
            CHECK (
                payload IS NOT NULL
                OR (notice_id IS NULL AND handled_at IS NOT NULL)
            )
        );
        CREATE TABLE conditions (
            kind TEXT PRIMARY KEY CHECK (
                kind IN ('api-401', 'api-409', 'credential', 'protocol', 'transport')
            ),
            detail TEXT NOT NULL,
            notice_id INTEGER REFERENCES notices(id),
            started_at INTEGER NOT NULL
        );
        CREATE TABLE replies (
            update_id INTEGER PRIMARY KEY REFERENCES messages(update_id) ON DELETE RESTRICT,
            body_sha256 TEXT NOT NULL,
            state TEXT NOT NULL CHECK (state IN ('reserved', 'sent', 'failed', 'unknown')),
            reserved_at INTEGER NOT NULL CHECK (reserved_at >= 0),
            updated_at INTEGER NOT NULL CHECK (updated_at >= reserved_at),
            network_started INTEGER NOT NULL DEFAULT 0 CHECK (network_started IN (0, 1)),
            telegram_message_id INTEGER,
            failure_detail TEXT,
            CHECK (
                (state = 'sent' AND telegram_message_id IS NOT NULL AND failure_detail IS NULL)
                OR (state = 'reserved' AND telegram_message_id IS NULL AND failure_detail IS NULL)
                OR (state = 'unknown' AND telegram_message_id IS NULL AND failure_detail IS NOT NULL)
                OR (state = 'failed' AND telegram_message_id IS NULL AND failure_detail IS NOT NULL)
            )
        );
        PRAGMA user_version = 1;
        """
    )


def create_store(
    state: Path,
    migration_status: str,
    migration_archive: Optional[str],
    migration_fingerprint: Optional[str],
    plan: Optional[MigrationPlan] = None,
    migration_cause: Optional[str] = None,
    publication: Optional[Publication] = None,
) -> sqlite3.Connection:
    telegram_dir = ensure_telegram_directory(state, create=True)
    _, database = state_paths(state)
    if database.exists() or database.is_symlink():
        raise UserError("Telegram state database already exists: %s" % database)
    temp_path = telegram_dir / (".channel.db.%d.%s" % (os.getpid(), uuid.uuid4().hex))
    marker_path = staging_marker_path(temp_path)
    conn = None
    try:
        write_owner_marker(marker_path, DATABASE_STAGING_SCHEMA)
        fd = os.open(str(temp_path), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(fd)
        conn = sqlite3.connect(str(temp_path), isolation_level=None, timeout=5)
        configure_connection(conn)
        create_schema(conn)
        conn.commit()
        conn.execute("BEGIN IMMEDIATE")
        store_uuid = str(uuid.uuid4())
        offset = plan.offset if plan is not None else 0
        conn.execute(
            "INSERT INTO meta (singleton, schema_version, state_uuid, committed_offset, "
            "last_success, consecutive_failures, first_failure, migration_status, "
            "migration_archive, migration_fingerprint, migration_cause) "
            "VALUES (1, ?, ?, ?, NULL, 0, NULL, ?, ?, ?, ?)",
            (
                SCHEMA_VERSION,
                store_uuid,
                offset,
                migration_status,
                migration_archive,
                migration_fingerprint,
                migration_cause,
            ),
        )
        if plan is not None:
            import_migration_plan(conn, plan)
        elif migration_status == "blocked":
            create_notice(conn, "migration-blocked", "ambiguous")
        failpoint("during_database_build")
        conn.commit()
        failpoint("after_database_commit")
        verify_integrity(conn)
        validate_store(conn)
        conn.close()
        conn = None
        os.chmod(temp_path, 0o600)
        with temp_path.open("rb") as handle:
            os.fsync(handle.fileno())
        os.replace(temp_path, database)
        if publication is not None:
            publication.published = True
        unlink_quietly(marker_path)
        raising_failpoint("after_database_publish")
        fsync_directory(telegram_dir)
        return connect_existing(state)
    except BaseException:
        if conn is not None:
            try:
                conn.close()
            except sqlite3.Error:
                pass
        if publication is None or not publication.published:
            unlink_quietly(temp_path)
        unlink_quietly(database_journal_path(temp_path))
        unlink_quietly(marker_path)
        raise


def create_notice(conn: sqlite3.Connection, kind: str, detail: str) -> int:
    if kind not in NOTICE_KINDS or not DETAIL_RE.fullmatch(detail):
        raise LocalStateError("notice-plan", "%s:%s" % (kind, detail))
    pending = conn.execute(
        "SELECT id FROM notices WHERE acknowledged_at IS NULL"
    ).fetchone()
    if pending is not None:
        raise LocalStateError("notice-overlap", repr(pending[0]))
    cursor = conn.execute(
        "INSERT INTO notices (kind, detail, created_at, acknowledged_at) "
        "VALUES (?, ?, ?, NULL)",
        (kind, detail, now_epoch()),
    )
    return int(cursor.lastrowid)


def notice_token(conn: sqlite3.Connection, notice_id: int) -> str:
    store_uuid = conn.execute(
        "SELECT state_uuid FROM meta WHERE singleton = 1"
    ).fetchone()[0]
    return "%s:%d" % (store_uuid, notice_id)


def notice_result(conn: sqlite3.Connection, notice_id: int) -> str:
    row = conn.execute(
        "SELECT kind, detail, acknowledged_at FROM notices WHERE id = ?",
        (notice_id,),
    ).fetchone()
    if row is None:
        raise LocalStateError("notice-missing", repr(notice_id))
    kind, detail, acknowledged_at = row
    if acknowledged_at is not None:
        raise LocalStateError("notice-already-acknowledged", repr(notice_id))
    token = notice_token(conn, notice_id)
    if kind == "message":
        count = conn.execute(
            "SELECT COUNT(*) FROM messages WHERE notice_id = ? AND handled_at IS NULL",
            (notice_id,),
        ).fetchone()[0]
        if count <= 0:
            raise LocalStateError("message-notice-empty", repr(notice_id))
        return "message: %d notice=%s" % (count, token)
    return "blocked: %s %s notice=%s" % (kind, detail, token)


def emit_notice(conn: sqlite3.Connection, notice_id: int) -> int:
    failpoint("before_output")
    print(notice_result(conn, notice_id), flush=True)
    failpoint("after_output")
    return 0


def pending_notice(conn: sqlite3.Connection) -> Optional[int]:
    row = conn.execute(
        "SELECT id FROM notices WHERE acknowledged_at IS NULL ORDER BY id LIMIT 1"
    ).fetchone()
    return None if row is None else int(row[0])


def notice_kind_for_condition(condition: str) -> str:
    if condition.startswith("api-"):
        return "api-blocked"
    if condition == "credential":
        return "credential-blocked"
    if condition == "protocol":
        return "protocol-blocked"
    if condition == "transport":
        return "transport-blocked"
    raise LocalStateError("condition-notice-kind", condition)


def ensure_unannounced_condition_notice(conn: sqlite3.Connection) -> Optional[int]:
    row = conn.execute(
        "SELECT kind, detail FROM conditions WHERE notice_id IS NULL "
        "ORDER BY CASE kind WHEN 'api-401' THEN 1 WHEN 'api-409' THEN 2 ELSE 3 END, kind "
        "LIMIT 1"
    ).fetchone()
    if row is None:
        return None
    condition, detail = row
    conn.execute("BEGIN IMMEDIATE")
    try:
        current = conn.execute(
            "SELECT detail, notice_id FROM conditions WHERE kind = ?",
            (condition,),
        ).fetchone()
        if current is None or current[1] is not None:
            conn.rollback()
            return None
        notice_id = create_notice(conn, notice_kind_for_condition(condition), detail)
        conn.execute(
            "UPDATE conditions SET notice_id = ? WHERE kind = ?",
            (notice_id, condition),
        )
        conn.commit()
        return notice_id
    except Exception:
        conn.rollback()
        raise


def raise_condition(
    conn: sqlite3.Connection, condition: str, detail: str
) -> Optional[int]:
    if condition not in CONDITION_KINDS or not DETAIL_RE.fullmatch(detail):
        raise LocalStateError("condition-plan", "%s:%s" % (condition, detail))
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute(
            "SELECT detail, notice_id FROM conditions WHERE kind = ?",
            (condition,),
        ).fetchone()
        if row is not None:
            conn.commit()
            return None
        notice_id = create_notice(conn, notice_kind_for_condition(condition), detail)
        conn.execute(
            "INSERT INTO conditions (kind, detail, notice_id, started_at) "
            "VALUES (?, ?, ?, ?)",
            (condition, detail, notice_id, now_epoch()),
        )
        conn.commit()
        return notice_id
    except Exception:
        conn.rollback()
        raise


def clear_condition(conn: sqlite3.Connection, condition: str) -> None:
    conn.execute("BEGIN IMMEDIATE")
    try:
        conn.execute("DELETE FROM conditions WHERE kind = ?", (condition,))
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def parse_env_value(raw: str) -> str:
    if not raw:
        return ""
    if raw[0] in ("'", '"'):
        try:
            parts = shlex.split(raw, posix=True)
        except ValueError as exc:
            raise CredentialError("invalid quoted credential value: %s" % exc)
        if len(parts) != 1:
            raise CredentialError("credential value must be one token")
        value = parts[0]
    else:
        value = raw
    if any(ord(char) < 32 or ord(char) == 127 for char in value):
        raise CredentialError("credential value contains control bytes")
    return value


def read_credentials(path: Path) -> Credentials:
    try:
        before = path.lstat()
    except OSError as exc:
        raise CredentialError(str(exc))
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise CredentialError("credential path is not a regular file")
    if stat.S_IMODE(before.st_mode) != 0o600:
        raise CredentialError("credential file mode is not 600")
    synchronization_failpoint("credential-after-lstat")
    flags = os.O_RDONLY
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    try:
        fd = os.open(str(path), flags)
    except OSError as exc:
        raise CredentialError(str(exc))
    try:
        after = os.fstat(fd)
        if (
            after.st_dev != before.st_dev
            or after.st_ino != before.st_ino
            or not stat.S_ISREG(after.st_mode)
            or stat.S_IMODE(after.st_mode) != 0o600
        ):
            raise CredentialError("credential file changed during open")
        chunks = []
        total = 0
        while True:
            chunk = os.read(fd, min(8192, MAX_CREDENTIAL_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_CREDENTIAL_BYTES:
                raise CredentialError("credential file is too large")
        final = os.fstat(fd)
        if (
            final.st_dev != after.st_dev
            or final.st_ino != after.st_ino
            or final.st_size != after.st_size
            or final.st_mtime_ns != after.st_mtime_ns
            or final.st_ctime_ns != after.st_ctime_ns
        ):
            raise CredentialError("credential file changed during read")
    finally:
        os.close(fd)
    try:
        text = b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise CredentialError("credential file is not UTF-8: %s" % exc)
    values: Dict[str, str] = {}
    for line_number, line in enumerate(text.splitlines(), 1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        if "=" not in line:
            raise CredentialError("line %d is not KEY=VALUE" % line_number)
        key, raw = line.split("=", 1)
        key = key.strip()
        raw = raw.strip()
        if key not in EXPECTED_CREDENTIAL_KEYS:
            raise CredentialError("line %d has an unknown key" % line_number)
        if key in values:
            raise CredentialError("line %d repeats a key" % line_number)
        values[key] = parse_env_value(raw)
    if set(values) != EXPECTED_CREDENTIAL_KEYS or any(
        not values[key] for key in EXPECTED_CREDENTIAL_KEYS
    ):
        raise CredentialError("credential file is incomplete")
    token = values["TELEGRAM_BOT_TOKEN"]
    if not re.fullmatch(r"[0-9]+:[A-Za-z0-9_-]+", token):
        raise CredentialError("bot token is not in Telegram's documented form")
    chat_text = values["TELEGRAM_CAPTAIN_CHAT_ID"]
    user_text = values["TELEGRAM_CAPTAIN_USER_ID"]
    if not re.fullmatch(r"-?[1-9][0-9]*", chat_text):
        raise CredentialError("captain chat id is not a nonzero integer")
    if not re.fullmatch(r"[1-9][0-9]*", user_text):
        raise CredentialError("captain user id is not a positive integer")
    return Credentials(token, int(chat_text), int(user_text))


def poll_timeout() -> int:
    return validate_positive_int(
        os.environ.get("FM_TELEGRAM_POLL_TIMEOUT", "25"),
        "FM_TELEGRAM_POLL_TIMEOUT",
        50,
    )


def poll_configuration() -> Tuple[int, int, int]:
    timeout = poll_timeout()
    curl_max = validate_positive_int(
        os.environ.get("FM_TELEGRAM_CURL_MAX_TIME", str(timeout + 15)),
        "FM_TELEGRAM_CURL_MAX_TIME",
        300,
    )
    if curl_max <= timeout:
        raise UserError("FM_TELEGRAM_CURL_MAX_TIME must exceed the poll timeout")
    budget = validate_positive_int(
        os.environ.get("FM_TELEGRAM_TRANSIENT_ERROR_BUDGET", "3"),
        "FM_TELEGRAM_TRANSIENT_ERROR_BUDGET",
        100,
    )
    return timeout, curl_max, budget


def read_bounded_stream(
    stream: object, limit: int, deadline: float
) -> Tuple[bytes, bytes, int, bool, bool]:
    chunks: List[bytes] = []
    tail = b""
    total = 0
    overflow = False
    descriptor = stream.fileno()
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return b"".join(chunks), tail, total, overflow, True
        try:
            ready, _, _ = select.select([descriptor], [], [], min(remaining, 1.0))
        except OSError:
            return b"".join(chunks), tail, total, overflow, True
        if not ready:
            continue
        try:
            chunk = os.read(descriptor, 65536)
        except OSError:
            return b"".join(chunks), tail, total, overflow, True
        if not chunk:
            return b"".join(chunks), tail, total, overflow, False
        total += len(chunk)
        tail = (tail + chunk)[-STATUS_TRAILER_BYTES:]
        if overflow or total > limit:
            overflow = True
            chunks = []
            continue
        chunks.append(chunk)


def run_curl_request(
    config: bytes,
    extra_argv: Sequence[str],
    max_time: int,
    pass_fds: Tuple[int, ...] = (),
) -> Tuple[Optional[int], Optional[bytes], Optional[str]]:
    try:
        process = subprocess.Popen(
            [
                "curl",
                "-q",
                "-s",
                "-w",
                "\\n%{http_code}",
                "--max-time",
                str(max_time),
                "-K",
                "-",
            ]
            + list(extra_argv),
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            pass_fds=pass_fds,
        )
    except OSError:
        return None, None, "transport"
    deadline = time.monotonic() + max_time + 5
    try:
        try:
            process.stdin.write(config)
            process.stdin.close()
        except OSError:
            return None, None, "transport"
        captured, tail, total, overflow, timed_out = read_bounded_stream(
            process.stdout, MAX_RESPONSE_BYTES + STATUS_TRAILER_BYTES, deadline
        )
        if timed_out:
            return None, None, "transport"
        try:
            returncode = process.wait(timeout=max(0.0, deadline - time.monotonic()))
        except subprocess.TimeoutExpired:
            return None, None, "transport"
        if returncode != 0:
            return None, None, "transport"
        if total < STATUS_TRAILER_BYTES or STATUS_TRAILER_RE.fullmatch(tail) is None:
            return None, None, "transport"
        status = int(tail[1:])
        if overflow or total - STATUS_TRAILER_BYTES > MAX_RESPONSE_BYTES:
            return status, None, "response-too-large"
        return status, captured[: total - STATUS_TRAILER_BYTES], None
    finally:
        if process.poll() is None:
            process.kill()
        for handle in (process.stdin, process.stdout):
            try:
                handle.close()
            except OSError:
                pass
        process.wait()


def run_curl(
    state: Path, credentials: Credentials, offset: int, timeout: int, curl_max: int
) -> Tuple[Optional[int], Optional[bytes], Optional[str]]:
    ensure_telegram_directory(state, create=False)
    config = (
        'url = "https://api.telegram.org/bot%s/getUpdates?offset=%d&timeout=%d"\n'
        % (credentials.token, offset, timeout)
    ).encode("utf-8")
    return run_curl_request(config, (), curl_max)


def canonical_message(
    update: Dict[str, object], credentials: Credentials
) -> Optional[PlannedMessage]:
    present = [name for name in ("message", "edited_message") if name in update]
    if len(present) > 1:
        raise ProtocolError("an update has more than one supported message shape")
    if not present:
        return None
    raw_message = update[present[0]]
    if not isinstance(raw_message, dict):
        raise ProtocolError("message is not an object")
    if "text" not in raw_message:
        return None
    text = raw_message["text"]
    if not isinstance(text, str) or not text:
        raise ProtocolError("message text is not a nonempty string")
    chat = raw_message.get("chat")
    if not isinstance(chat, dict):
        raise ProtocolError("text message identity containers are malformed")
    if "from" not in raw_message:
        return None
    sender = raw_message["from"]
    if not isinstance(sender, dict):
        raise ProtocolError("text message identity containers are malformed")
    chat_id = chat.get("id")
    sender_id = sender.get("id")
    if type(chat_id) is not int or type(sender_id) is not int:
        raise ProtocolError("text message identity is not integer shaped")
    date = raw_message.get("date")
    if date is not None and type(date) is not int:
        raise ProtocolError("message date is not integer shaped")
    if chat_id != credentials.captain_chat_id or sender_id != credentials.captain_user_id:
        return None
    message_id = raw_message.get("message_id")
    update_id = update["update_id"]
    payload_data = {
        "update_id": update_id,
        "date": date,
        "chat_id": chat_id,
        "from_id": sender_id,
        "text": text,
    }
    if valid_update_id(message_id):
        payload_data["message_id"] = message_id
    payload = json.dumps(
        payload_data,
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return PlannedMessage(int(update_id), payload)


def validate_batch(body: bytes, offset: int, credentials: Credentials) -> BatchPlan:
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise ProtocolError("response is not valid UTF-8 JSON: %s" % exc)
    if not isinstance(response, dict) or response.get("ok") is not True:
        raise ProtocolError("response is not a successful Telegram envelope")
    updates = response.get("result")
    if not isinstance(updates, list):
        raise ProtocolError("result is not a list")
    seen = set()
    highest = None
    messages = []
    for update in updates:
        if not isinstance(update, dict):
            raise ProtocolError("update is not an object")
        update_id = update.get("update_id")
        if not valid_update_id(update_id):
            raise ProtocolError("update_id is outside the supported positive range")
        if update_id in seen:
            raise ProtocolError("batch repeats an update_id")
        if update_id < offset:
            raise ProtocolError("batch contains an update below the committed offset")
        seen.add(update_id)
        highest = update_id if highest is None else max(highest, update_id)
        planned = canonical_message(update, credentials)
        if planned is not None:
            messages.append(planned)
    if highest is None:
        return BatchPlan(offset, tuple(), True)
    return BatchPlan(highest + 1, tuple(messages), False)


def reset_success_conditions(conn: sqlite3.Connection) -> None:
    conn.execute(
        "DELETE FROM conditions WHERE kind IN "
        "('api-401', 'api-409', 'protocol', 'transport')"
    )
    conn.execute(
        "UPDATE meta SET last_success = ?, consecutive_failures = 0, "
        "first_failure = NULL WHERE singleton = 1",
        (now_epoch(),),
    )


def expire_reply_intents(conn: sqlite3.Connection) -> None:
    conn.execute(
        "DELETE FROM replies WHERE state = 'reserved' AND network_started = 0 "
        "AND reserved_at < ?",
        (now_epoch() - RETAINED_REPLY_INTENT_SECONDS,),
    )


def payload_conflicts(stored: str, planned: str) -> bool:
    try:
        stored_data = json.loads(stored)
        planned_data = json.loads(planned)
    except ValueError:
        return True
    if not isinstance(stored_data, dict) or not isinstance(planned_data, dict):
        return True
    if "message_id" not in stored_data:
        planned_data = {
            key: value for key, value in planned_data.items() if key != "message_id"
        }
    return stored_data != planned_data


def commit_batch(conn: sqlite3.Connection, plan: BatchPlan) -> Optional[int]:
    failpoint("after_validate")
    conn.execute("BEGIN IMMEDIATE")
    try:
        failpoint("after_begin")
        current_offset = conn.execute(
            "SELECT committed_offset FROM meta WHERE singleton = 1"
        ).fetchone()[0]
        if plan.empty:
            if plan.next_offset != current_offset:
                raise LocalStateError("empty-plan-offset", repr(plan.next_offset))
        elif plan.next_offset <= current_offset:
            raise LocalStateError(
                "batch-plan-offset",
                "%d is not above %d" % (plan.next_offset, current_offset),
            )
        new_messages = []
        for message in plan.messages:
            existing = conn.execute(
                "SELECT payload FROM messages WHERE update_id = ?",
                (message.update_id,),
            ).fetchone()
            if existing is None:
                new_messages.append(message)
            elif existing[0] is None:
                continue
            elif payload_conflicts(existing[0], message.payload):
                raise LocalStateError("message-conflict", repr(message.update_id))
        notice_id = None
        if new_messages:
            notice_id = create_notice(conn, "message", "captain-messages")
            failpoint("after_notice")
            for message in new_messages:
                conn.execute(
                    "INSERT INTO messages (update_id, payload, notice_id, handled_at) "
                    "VALUES (?, ?, ?, NULL)",
                    (message.update_id, message.payload, notice_id),
                )
                failpoint("after_message")
        if not plan.empty:
            conn.execute(
                "UPDATE meta SET committed_offset = ? WHERE singleton = 1",
                (plan.next_offset,),
            )
            failpoint("after_offset")
        reset_success_conditions(conn)
        expire_reply_intents(conn)
        failpoint("before_commit")
        conn.commit()
        failpoint("after_commit")
        return notice_id
    except Exception:
        conn.rollback()
        raise


def record_transport_failure(
    conn: sqlite3.Connection, budget: int
) -> Optional[int]:
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = conn.execute(
            "SELECT consecutive_failures, first_failure FROM meta WHERE singleton = 1"
        ).fetchone()
        count = int(row[0]) + 1
        first_failure = row[1] if row[1] is not None else now_epoch()
        conn.execute(
            "UPDATE meta SET consecutive_failures = ?, first_failure = ? "
            "WHERE singleton = 1",
            (count, first_failure),
        )
        condition = conn.execute(
            "SELECT notice_id FROM conditions WHERE kind = 'transport'"
        ).fetchone()
        notice_id = None
        if count >= budget and condition is None:
            notice_id = create_notice(conn, "transport-blocked", "failure-budget")
            conn.execute(
                "INSERT INTO conditions (kind, detail, notice_id, started_at) "
                "VALUES ('transport', 'failure-budget', ?, ?)",
                (notice_id, first_failure),
            )
        conn.commit()
        return notice_id
    except Exception:
        conn.rollback()
        raise


def announce(conn: sqlite3.Connection, notice_id: Optional[int]) -> int:
    if notice_id is None:
        return 3
    return emit_notice(conn, notice_id)


def command_poll(state: Path, credential_path: Path) -> int:
    conn: Optional[sqlite3.Connection] = connect_existing(state)
    try:
        pending = pending_notice(conn)
        if pending is not None:
            return emit_notice(conn, pending)
        migration_status, migration_fingerprint = conn.execute(
            "SELECT migration_status, migration_fingerprint FROM meta WHERE singleton = 1"
        ).fetchone()
        if migration_status == "blocked":
            timeout = poll_timeout()
            conn.close()
            conn = None
            while True:
                time.sleep(timeout)
                conn = connect_existing(state)
                migration_status, migration_fingerprint = conn.execute(
                    "SELECT migration_status, migration_fingerprint "
                    "FROM meta WHERE singleton = 1"
                ).fetchone()
                if migration_status != "blocked":
                    break
                conn.close()
                conn = None
        pending = ensure_unannounced_condition_notice(conn)
        if pending is not None:
            return emit_notice(conn, pending)
        try:
            credentials = read_credentials(credential_path)
        except CredentialError:
            return announce(conn, raise_condition(conn, "credential", "unavailable"))
        if conn.execute(
            "SELECT 1 FROM conditions WHERE kind = 'credential'"
        ).fetchone() is not None:
            clear_condition(conn, "credential")
        timeout, curl_max, budget = poll_configuration()
        offset = conn.execute(
            "SELECT committed_offset FROM meta WHERE singleton = 1"
        ).fetchone()[0]
        http_code, body, transport_error = run_curl(
            state, credentials, offset, timeout, curl_max
        )
        credentials = Credentials("", credentials.captain_chat_id, credentials.captain_user_id)
        if transport_error is not None or http_code is None:
            if transport_error == "response-too-large" and http_code == 200:
                return announce(
                    conn, raise_condition(conn, "protocol", "response-too-large")
                )
            if http_code in (401, 409):
                return announce(
                    conn, raise_condition(conn, "api-%d" % http_code, str(http_code))
                )
            return announce(conn, record_transport_failure(conn, budget))
        if http_code in (401, 409):
            return announce(
                conn, raise_condition(conn, "api-%d" % http_code, str(http_code))
            )
        if http_code != 200:
            return announce(conn, record_transport_failure(conn, budget))
        if body is None:
            raise LocalStateError("response-body-missing", "HTTP 200 has no body")
        try:
            plan = validate_batch(body, offset, credentials)
        except ProtocolError:
            return announce(conn, raise_condition(conn, "protocol", "invalid-response"))
        return announce(conn, commit_batch(conn, plan))
    finally:
        if conn is not None:
            conn.close()


def send_max_time() -> int:
    return validate_positive_int(
        os.environ.get("FM_TELEGRAM_SEND_MAX_TIME", "30"),
        "FM_TELEGRAM_SEND_MAX_TIME",
        MAX_SEND_TIME,
    )


def read_reply_body() -> Tuple[bytes, str]:
    body = sys.stdin.buffer.read(MAX_REPLY_BYTES + 1)
    if len(body) > MAX_REPLY_BYTES:
        raise UserError("reply text exceeds the bounded Telegram send limit")
    if not body:
        raise UserError("reply text from stdin must not be empty")
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError:
        raise UserError("reply text from stdin is not valid UTF-8")
    if not text.strip():
        raise UserError("reply text from stdin must not be empty")
    if len(text.encode("utf-16-le")) // 2 > MAX_REPLY_CHARS:
        raise UserError(
            "reply text exceeds the Telegram limit of %d characters" % MAX_REPLY_CHARS
        )
    return body, text


def stage_send_request(chat_id: int, message_id: int, text: str) -> SendRequest:
    max_time = send_max_time()
    encoded = urllib.parse.urlencode(
        {
            "chat_id": str(chat_id),
            "reply_parameters": json.dumps(
                {"message_id": message_id}, separators=(",", ":")
            ),
            "text": text,
        }
    ).encode("utf-8")
    body_file = tempfile.TemporaryFile(mode="w+b")
    try:
        body_file.write(encoded)
        body_file.flush()
        body_file.seek(0)
    except Exception:
        body_file.close()
        raise
    return SendRequest(body_file, max_time)


def run_send_curl(
    credentials: Credentials, request: SendRequest
) -> Tuple[Optional[int], Optional[bytes], Optional[str]]:
    body_fd = request.body_file.fileno()
    config = (
        'url = "https://api.telegram.org/bot%s/sendMessage"\n'
        "request = POST\n"
        % credentials.token
    ).encode("utf-8")
    return run_curl_request(
        config,
        ("--data-binary", "@/dev/fd/%d" % body_fd),
        request.max_time,
        (body_fd,),
    )


def parse_send_success(
    body: bytes, chat_id: int, message_id: int, expected_text: str
) -> int:
    try:
        response = json.loads(body.decode("utf-8"))
    except (UnicodeDecodeError, ValueError):
        raise ProtocolError("send response is not valid JSON")
    if not isinstance(response, dict):
        raise ProtocolError("send response is not a Telegram envelope")
    if response.get("ok") is False:
        error_code = response.get("error_code")
        if type(error_code) is int and 400 <= error_code <= 599:
            raise ApiRefusal("api-refusal-%d" % error_code)
        raise ApiRefusal("api-refusal")
    if response.get("ok") is not True:
        raise ProtocolError("send response is not a successful Telegram envelope")
    result = response.get("result")
    if not isinstance(result, dict):
        raise ProtocolError("send response result is not an object")
    sent_id = result.get("message_id")
    result_chat = result.get("chat")
    reply_to = result.get("reply_to_message")
    if (
        not valid_update_id(sent_id)
        or not isinstance(result_chat, dict)
        or type(result_chat.get("id")) is not int
        or result_chat.get("id") != chat_id
        or not isinstance(reply_to, dict)
        or not valid_update_id(reply_to.get("message_id"))
        or reply_to.get("message_id") != message_id
        or result.get("text") != expected_text
    ):
        raise ProtocolError("send response is not bound to the accepted Telegram message")
    return sent_id


def safe_reply_failure(detail: str) -> str:
    detail = re.sub(r"[^a-z0-9.-]+", "-", detail.lower()).strip("-")
    return (detail or "unknown")[:64]


def reply_record(
    conn: sqlite3.Connection, update_id: int
) -> Optional[Tuple[object, ...]]:
    return conn.execute(
        "SELECT body_sha256, state, reserved_at, updated_at, network_started, "
        "telegram_message_id, failure_detail FROM replies WHERE update_id = ?",
        (update_id,),
    ).fetchone()


def reply_label(state: str, network_started: int) -> str:
    if state == "sent":
        return "sent"
    if state == "failed":
        return "definitely-failed"
    if state == "unknown" or network_started:
        return "delivery-unknown"
    return "reserved"


def replaceable_reservation(row: Tuple[object, ...]) -> bool:
    return row[1] == "reserved" and not row[4]


def classify_reply_attempt(
    row: Optional[Tuple[object, ...]], body_sha256: str
) -> str:
    if row is None:
        return "new"
    if row[0] != body_sha256 and not replaceable_reservation(row):
        raise UserError("an accepted inbound event already has a different reply")
    label = reply_label(row[1], row[4])
    if label == "definitely-failed":
        raise UserError("the reply has a definite Telegram failure and will not be retried")
    if label == "delivery-unknown":
        raise UserError(DELIVERY_UNKNOWN_GUIDANCE)
    return label


def reserve_reply(
    conn: sqlite3.Connection, update_id: int, body_sha256: str
) -> str:
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = reply_record(conn, update_id)
        disposition = classify_reply_attempt(row, body_sha256)
        if row is not None:
            if disposition == "sent":
                conn.commit()
                return "sent"
            if row[0] != body_sha256:
                conn.execute(
                    "UPDATE replies SET body_sha256 = ?, updated_at = ? WHERE update_id = ? "
                    "AND state = 'reserved' AND network_started = 0",
                    (body_sha256, now_epoch(), update_id),
                )
            conn.commit()
            return "reserved"
        now = now_epoch()
        conn.execute(
            "INSERT INTO replies (update_id, body_sha256, state, reserved_at, updated_at, "
            "network_started, telegram_message_id, failure_detail) "
            "VALUES (?, ?, 'reserved', ?, ?, 0, NULL, NULL)",
            (update_id, body_sha256, now, now),
        )
        conn.commit()
        return "reserved"
    except Exception:
        try:
            conn.rollback()
        except sqlite3.Error:
            pass
        raise


def mark_reply_network_started(
    conn: sqlite3.Connection, update_id: int, body_sha256: str
) -> None:
    conn.execute("BEGIN IMMEDIATE")
    try:
        changed = conn.execute(
            "UPDATE replies SET state = 'unknown', network_started = 1, "
            "updated_at = ?, failure_detail = 'delivery-unknown' "
            "WHERE update_id = ? AND state = 'reserved' AND network_started = 0 "
            "AND body_sha256 = ?",
            (now_epoch(), update_id, body_sha256),
        ).rowcount
        if changed != 1:
            raise UserError("the reply reservation changed before sending")
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def finish_reply(
    conn: sqlite3.Connection,
    update_id: int,
    state: str,
    telegram_message_id: Optional[int] = None,
    failure_detail: Optional[str] = None,
) -> None:
    if state not in ("sent", "failed", "unknown"):
        raise LocalStateError("reply-result", state)
    conn.execute("BEGIN IMMEDIATE")
    try:
        row = reply_record(conn, update_id)
        if row is None or row[1] not in ("reserved", "unknown") or not row[4]:
            raise LocalStateError("reply-reservation", repr(update_id))
        if state == "sent":
            conn.execute(
                "UPDATE replies SET state = 'sent', updated_at = ?, "
                "telegram_message_id = ?, failure_detail = NULL WHERE update_id = ?",
                (now_epoch(), telegram_message_id, update_id),
            )
        else:
            conn.execute(
                "UPDATE replies SET state = ?, updated_at = ?, "
                "telegram_message_id = NULL, failure_detail = ? WHERE update_id = ?",
                (state, now_epoch(), failure_detail or "delivery-unknown", update_id),
            )
        raising_failpoint("before_reply_finish_commit")
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def retain_reply_intent(conn: sqlite3.Connection, update_id: int) -> None:
    conn.execute("BEGIN IMMEDIATE")
    try:
        changed = conn.execute(
            "UPDATE replies SET state = 'reserved', network_started = 0, updated_at = ?, "
            "telegram_message_id = NULL, failure_detail = NULL "
            "WHERE update_id = ? AND state = 'unknown' AND network_started = 1",
            (now_epoch(), update_id),
        ).rowcount
        if changed != 1:
            raise LocalStateError("reply-reservation", repr(update_id))
        conn.commit()
    except Exception:
        conn.rollback()
        raise


def command_reply(state: Path, credential_path: Path, update_id_text: str) -> int:
    update_id = validate_positive_int(update_id_text, "accepted inbound update id", MAX_UPDATE_ID)
    body, text = read_reply_body()
    body_sha256 = hashlib.sha256(body).hexdigest()
    conn = connect_existing(state)
    network_outcome_unresolved = False
    try:
        disposition = classify_reply_attempt(reply_record(conn, update_id), body_sha256)
        if disposition == "sent":
            print("already-sent: update_id=%d" % update_id)
            return 0
        try:
            credentials = read_credentials(credential_path)
        except CredentialError:
            raise UserError(
                "Telegram reply credentials are unavailable or invalid; repair the configured "
                "credential file, then retry with: reply %d" % update_id
            )
        inbound = conn.execute(
            "SELECT payload FROM messages WHERE update_id = ?", (update_id,)
        ).fetchone()
        if inbound is None or inbound[0] is None:
            raise UserError("accepted inbound event is unknown")
        try:
            payload = json.loads(inbound[0])
        except (TypeError, ValueError):
            raise UserError("accepted inbound event has malformed evidence")
        inbound_message_id = payload.get("message_id") if isinstance(payload, dict) else None
        if (
            not isinstance(payload, dict)
            or payload.get("chat_id") != credentials.captain_chat_id
            or payload.get("from_id") != credentials.captain_user_id
            or not valid_update_id(inbound_message_id)
        ):
            raise UserError("accepted inbound event lacks strict reply identity evidence")
        failpoint("before_reply_reserve")
        reservation = reserve_reply(conn, update_id, body_sha256)
        if reservation == "sent":
            print("already-sent: update_id=%d" % update_id)
            return 0
        failpoint("after_reply_reserve")
        synchronization_failpoint("reply-after-reserve")
        request = stage_send_request(credentials.captain_chat_id, inbound_message_id, text)
        try:
            mark_reply_network_started(conn, update_id, body_sha256)
            network_outcome_unresolved = True
            failpoint("before_reply_network")
            http_code, response, transport_error = run_send_curl(credentials, request)
        finally:
            request.close()
        credentials = Credentials("", credentials.captain_chat_id, credentials.captain_user_id)
        if transport_error is not None or http_code is None:
            finish_reply(conn, update_id, "unknown", failure_detail="delivery-unknown")
            network_outcome_unresolved = False
            raise UserError(DELIVERY_UNKNOWN_GUIDANCE)
        if http_code == 429:
            retain_reply_intent(conn, update_id)
            network_outcome_unresolved = False
            raise UserError(
                "Telegram rate-limited the reply; it was not sent and is still owed - "
                "send it explicitly again with: reply %d" % update_id
            )
        if http_code in (401, 404):
            retain_reply_intent(conn, update_id)
            network_outcome_unresolved = False
            raise UserError(
                "Telegram refused the bot credentials or endpoint (http-%d); the reply was "
                "not sent and is still owed - send it explicitly again with: reply %d "
                "once the configuration is corrected" % (http_code, update_id)
            )
        if 400 <= http_code < 500:
            finish_reply(conn, update_id, "failed", failure_detail="http-%d" % http_code)
            network_outcome_unresolved = False
            raise UserError("Telegram definitely refused the reply (http-%d)" % http_code)
        if http_code != 200 or response is None:
            finish_reply(conn, update_id, "unknown", failure_detail="delivery-unknown")
            network_outcome_unresolved = False
            raise UserError(DELIVERY_UNKNOWN_GUIDANCE)
        try:
            sent_message_id = parse_send_success(
                response,
                credentials.captain_chat_id,
                inbound_message_id,
                text.strip(),
            )
        except ApiRefusal as exc:
            detail = safe_reply_failure(str(exc))
            finish_reply(conn, update_id, "failed", failure_detail=detail)
            network_outcome_unresolved = False
            raise UserError("Telegram definitely refused the reply")
        except ProtocolError:
            finish_reply(conn, update_id, "unknown", failure_detail="unbound-response")
            network_outcome_unresolved = False
            raise UserError(
                "Telegram did not prove delivery to the accepted message; "
                + DELIVERY_UNKNOWN_GUIDANCE
            )
        failpoint("after_reply_response")
        finish_reply(conn, update_id, "sent", telegram_message_id=sent_message_id)
        network_outcome_unresolved = False
        failpoint("after_reply_commit")
        print("sent: update_id=%d telegram_message_id=%d" % (update_id, sent_message_id))
        return 0
    except Exception as exc:
        if network_outcome_unresolved:
            raise UserError(DELIVERY_UNKNOWN_GUIDANCE) from exc
        raise
    finally:
        conn.close()


def read_result_file(path: Path) -> str:
    try:
        info = path.lstat()
    except OSError as exc:
        raise UserError("result file is unavailable: %s" % exc)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UserError("result file is not a regular file")
    if info.st_size > 4096:
        raise UserError("result file is too large")
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise UserError("result file is unreadable: %s" % exc)
    return lines[0] if lines else ""


def parse_result(line: str) -> ParsedResult:
    local = LOCAL_BLOCKED_RESULT_RE.fullmatch(line)
    if local:
        return ParsedResult(
            "blocked", None, None, None, "local-state", local.group("fingerprint")
        )
    message = MESSAGE_RESULT_RE.fullmatch(line)
    blocked = BLOCKED_RESULT_RE.fullmatch(line)
    match = message or blocked
    if match is None:
        return ParsedResult("none", None, None, None, None, None)
    token = NOTICE_TOKEN_RE.fullmatch(match.group("token"))
    if token is None:
        return ParsedResult("none", None, None, None, None, None)
    if message:
        return ParsedResult(
            "message",
            int(token.group("notice")),
            token.group("state"),
            int(message.group("count")),
            "message",
            None,
        )
    return ParsedResult(
        "blocked",
        int(token.group("notice")),
        token.group("state"),
        None,
        blocked.group("kind"),
        blocked.group("detail"),
    )


def verified_result(
    conn: sqlite3.Connection, parsed: ParsedResult
) -> ParsedResult:
    if parsed.notice_id is None or parsed.state_uuid is None:
        return parsed
    store_uuid = conn.execute(
        "SELECT state_uuid FROM meta WHERE singleton = 1"
    ).fetchone()[0]
    if store_uuid != parsed.state_uuid:
        return ParsedResult("none", None, None, None, None, None)
    row = conn.execute(
        "SELECT kind, detail, acknowledged_at FROM notices WHERE id = ?",
        (parsed.notice_id,),
    ).fetchone()
    if row is None or row[2] is not None:
        return ParsedResult("none", None, None, None, None, None)
    kind, detail, _ = row
    if parsed.classification == "message":
        count = conn.execute(
            "SELECT COUNT(*) FROM messages WHERE notice_id = ? AND handled_at IS NULL",
            (parsed.notice_id,),
        ).fetchone()[0]
        if kind != "message" or count != parsed.count:
            return ParsedResult("none", None, None, None, None, None)
    elif kind != parsed.kind or detail != parsed.detail:
        return ParsedResult("none", None, None, None, None, None)
    return parsed


def command_classify(state: Path, result_path: Path) -> int:
    parsed = parse_result(read_result_file(result_path))
    if parsed.kind == "local-state":
        print("blocked")
        return 0
    if parsed.classification == "none":
        print("none")
        return 0
    try:
        conn = connect_existing(state)
        try:
            parsed = verified_result(conn, parsed)
        finally:
            conn.close()
    except Exception:
        print("blocked")
        return 0
    print(parsed.classification)
    return 0


def command_messages(state: Path, result_path: Path) -> int:
    parsed = parse_result(read_result_file(result_path))
    if parsed.classification != "message" or parsed.notice_id is None:
        raise UserError("result does not identify a message notice")
    conn = connect_existing(state)
    try:
        parsed = verified_result(conn, parsed)
        if parsed.classification != "message" or parsed.notice_id is None:
            return 0
        for row in conn.execute(
            "SELECT payload FROM messages WHERE notice_id = ? AND handled_at IS NULL "
            "ORDER BY update_id",
            (parsed.notice_id,),
        ):
            print(row[0])
        return 0
    finally:
        conn.close()


def command_ack(state: Path, result_path: Path) -> int:
    parsed = parse_result(read_result_file(result_path))
    if parsed.kind == "local-state":
        print("unacknowledgeable: local-state")
        return 0
    if parsed.notice_id is None or parsed.state_uuid is None:
        raise UserError("result has no acknowledgeable notice")
    conn = connect_existing(state)
    try:
        store_uuid = conn.execute(
            "SELECT state_uuid FROM meta WHERE singleton = 1"
        ).fetchone()[0]
        if store_uuid != parsed.state_uuid:
            raise UserError("result belongs to another Telegram state generation")
        row = conn.execute(
            "SELECT acknowledged_at FROM notices WHERE id = ?",
            (parsed.notice_id,),
        ).fetchone()
        if row is None:
            raise UserError("result names an unknown notice")
        if row[0] is not None:
            print("already-acknowledged: notice=%s:%d" % (store_uuid, parsed.notice_id))
            return 0
        failpoint("before_ack")
        conn.execute("BEGIN IMMEDIATE")
        try:
            acknowledged_at = now_epoch()
            conn.execute(
                "UPDATE messages SET handled_at = ? "
                "WHERE notice_id = ? AND handled_at IS NULL",
                (acknowledged_at, parsed.notice_id),
            )
            conn.execute(
                "UPDATE notices SET acknowledged_at = ? "
                "WHERE id = ? AND acknowledged_at IS NULL",
                (acknowledged_at, parsed.notice_id),
            )
            failpoint("before_ack_commit")
            conn.commit()
            failpoint("after_ack_commit")
        except Exception:
            conn.rollback()
            raise
        print("acknowledged: notice=%s:%d" % (store_uuid, parsed.notice_id))
        return 0
    finally:
        conn.close()


def legacy_paths_present(state: Path) -> List[Path]:
    present = []
    for relative in LEGACY_EXACT_PATHS:
        path = state / relative
        if path.exists() or path.is_symlink():
            present.append(path)
    for pattern in LEGACY_TEMP_PATTERNS:
        for path in sorted(state.glob(pattern)):
            if path not in present and (path.exists() or path.is_symlink()):
                present.append(path)
    inbox = state / "procevent-inbox"
    if inbox.is_dir() and not inbox.is_symlink():
        for path in sorted(inbox.glob("telegram.*")):
            if path.exists() or path.is_symlink():
                present.append(path)
    return present


def command_arm_state(state: Path) -> int:
    _, database = state_paths(state)
    if database.exists() or database.is_symlink():
        try:
            conn = connect_existing(state)
            conn.close()
            print("state: ready")
        except Exception as exc:
            print("state: blocked fingerprint=%s" % state_fingerprint(
                exc.__class__.__name__, exc
            ))
        return 0
    legacy = legacy_paths_present(state)
    if legacy:
        raise UserError(
            "legacy Telegram state exists; run fm-procevent-telegram.sh migrate before arm"
        )
    reconcile_database_staging(state, "arm")
    conn = create_store(state, "fresh", None, None)
    conn.close()
    print("state: initialized")
    return 0


def command_check_credentials(credential_path: Path) -> int:
    read_credentials(credential_path)
    print("credential: ready")
    return 0


def hash_regular_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def archive_manifest_entries(root: Path) -> List[Dict[str, object]]:
    entries = []
    for base, directories, files in os.walk(str(root), topdown=True, followlinks=False):
        base_path = Path(base)
        for name in sorted(directories + files):
            path = base_path / name
            relative = path.relative_to(root).as_posix()
            info = path.lstat()
            item: Dict[str, object] = {
                "path": relative,
                "mode": stat.S_IMODE(info.st_mode),
            }
            if stat.S_ISLNK(info.st_mode):
                item["type"] = "symlink"
                item["target"] = os.readlink(str(path))
            elif stat.S_ISDIR(info.st_mode):
                item["type"] = "directory"
            elif stat.S_ISREG(info.st_mode):
                item["type"] = "file"
                item["sha256"] = hash_regular_file(path)
                item["size"] = info.st_size
            else:
                item["type"] = "other"
            entries.append(item)
    return entries


def remove_tree_forcibly(path: Path) -> None:
    if not path.exists() and not path.is_symlink():
        return
    for base, _, _ in os.walk(str(path), topdown=True):
        try:
            os.chmod(base, 0o700)
        except OSError:
            pass
    shutil.rmtree(str(path), ignore_errors=True)


def unlink_quietly(path: Path) -> None:
    try:
        path.unlink()
    except OSError:
        pass


def database_journal_path(temp_path: Path) -> Path:
    return temp_path.parent / (temp_path.name + DATABASE_JOURNAL_SUFFIX)


def staging_marker_path(staging: Path) -> Path:
    return staging.parent / (staging.name + STAGING_MARKER_SUFFIX)


def write_owner_marker(marker: Path, schema: str) -> None:
    fd = os.open(str(marker), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, "w", encoding="utf-8") as handle:
        json.dump(
            {"schema": schema, "pid": os.getpid(), "created_at": now_epoch()},
            handle,
            sort_keys=True,
        )
        handle.flush()
        os.fsync(handle.fileno())


def marked_schema(path: Path) -> Optional[str]:
    try:
        info = path.lstat()
    except OSError:
        return None
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        return None
    if info.st_size > 65536:
        return None
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError):
        return None
    if not isinstance(document, dict):
        return None
    schema = document.get("schema")
    return schema if isinstance(schema, str) else None


def refuse_leftover(command: str, name: str, reason: str) -> None:
    raise UserError(
        "Telegram state leftover %s %s; inspect and remove it manually, then rerun %s"
        % (name, reason, command)
    )


def refuse_unsafe_telegram_directory(state: Path, command: str) -> bool:
    telegram_dir, _ = state_paths(state)
    if telegram_dir.is_symlink() or (telegram_dir.exists() and not telegram_dir.is_dir()):
        refuse_leftover(command, "telegram", "is not a private state directory")
    if not telegram_dir.exists():
        return False
    mode = stat.S_IMODE(telegram_dir.lstat().st_mode)
    if mode != 0o700:
        refuse_leftover(command, "telegram", "has an unexpected mode %o" % mode)
    return True


def reconcile_database_staging(state: Path, command: str) -> None:
    telegram_dir, _ = state_paths(state)
    if not refuse_unsafe_telegram_directory(state, command):
        return
    entries = sorted(telegram_dir.glob(DATABASE_TEMP_GLOB))
    reaped = set()
    for path in entries:
        name = "telegram/" + path.name
        if path.name.endswith(STAGING_MARKER_SUFFIX):
            continue
        if path.name.endswith(DATABASE_JOURNAL_SUFFIX):
            continue
        if path.is_symlink() or not path.is_file():
            refuse_leftover(command, name, "is not a private database staging file")
        if not DATABASE_TEMP_RE.fullmatch(path.name):
            refuse_leftover(
                command, name, "does not carry this migrator's database staging name"
            )
        if stat.S_IMODE(path.lstat().st_mode) != 0o600:
            refuse_leftover(
                command, name, "is not a private mode-0600 database staging file"
            )
        if marked_schema(staging_marker_path(path)) != DATABASE_STAGING_SCHEMA:
            refuse_leftover(
                command, name, "has no valid private database staging ownership marker"
            )
        unlink_quietly(path)
        unlink_quietly(staging_marker_path(path))
        unlink_quietly(database_journal_path(path))
        reaped.add(path.name)
    for path in entries:
        name = "telegram/" + path.name
        if path.name.endswith(STAGING_MARKER_SUFFIX):
            if not path.exists() and not path.is_symlink():
                continue
            if path.is_symlink() or not path.is_file():
                refuse_leftover(
                    command, name, "is not a private database staging ownership marker"
                )
            if marked_schema(path) != DATABASE_STAGING_SCHEMA:
                refuse_leftover(
                    command,
                    name,
                    "is not a valid private database staging ownership marker",
                )
            unlink_quietly(path)
        elif path.name.endswith(DATABASE_JOURNAL_SUFFIX):
            base = path.name[: -len(DATABASE_JOURNAL_SUFFIX)]
            if base in reaped:
                continue
            if path.is_symlink() or not path.is_file():
                refuse_leftover(
                    command, name, "is not a private database staging journal"
                )
            if not DATABASE_TEMP_RE.fullmatch(base):
                refuse_leftover(
                    command, name, "does not carry this migrator's database staging name"
                )
            if stat.S_IMODE(path.lstat().st_mode) != 0o600:
                refuse_leftover(
                    command, name, "is not a private mode-0600 database staging journal"
                )
            unlink_quietly(path)


def reconcile_migration_leftovers(state: Path, command: str) -> None:
    for path in sorted(state.glob(STAGING_GLOB)):
        if path.name.endswith(STAGING_MARKER_SUFFIX):
            continue
        if path.is_symlink() or not path.is_dir():
            refuse_leftover(command, path.name, "is not a private staging directory")
        if not STAGING_NAME_RE.fullmatch(path.name):
            refuse_leftover(
                command, path.name, "does not carry this migrator's staging name"
            )
        if marked_schema(staging_marker_path(path)) != STAGING_SCHEMA:
            refuse_leftover(
                command, path.name, "has no valid private staging ownership marker"
            )
        remove_tree_forcibly(path)
        unlink_quietly(staging_marker_path(path))
    for path in sorted(state.glob(STAGING_GLOB)):
        if not path.name.endswith(STAGING_MARKER_SUFFIX):
            continue
        if path.is_symlink() or not path.is_file():
            refuse_leftover(command, path.name, "is not a private staging ownership marker")
        if marked_schema(path) != STAGING_SCHEMA:
            refuse_leftover(
                command, path.name, "is not a valid private staging ownership marker"
            )
        unlink_quietly(path)
    reconcile_database_staging(state, command)
    reconcile_orphan_archives(state, command)


def reconcile_orphan_archives(state: Path, command: str) -> None:
    archive_parent = state / ARCHIVE_PARENT_NAME
    if archive_parent.is_symlink():
        refuse_leftover(
            command, ARCHIVE_PARENT_NAME, "is a symlink rather than a directory"
        )
    if not archive_parent.exists():
        return
    if not archive_parent.is_dir():
        refuse_leftover(command, ARCHIVE_PARENT_NAME, "is not a directory")
    mode = stat.S_IMODE(archive_parent.lstat().st_mode)
    if mode not in (0o500, 0o700):
        refuse_leftover(
            command, ARCHIVE_PARENT_NAME, "has an unexpected mode %o" % mode
        )
    if mode != 0o700:
        os.chmod(archive_parent, 0o700)
    for entry in sorted(archive_parent.iterdir()):
        if entry.is_symlink() or not entry.is_dir():
            refuse_leftover(command, entry.name, "is not a published archive directory")
        if not ARCHIVE_NAME_RE.fullmatch(entry.name):
            refuse_leftover(command, entry.name, "does not carry a published archive name")
        if marked_schema(entry / "manifest.json") != ARCHIVE_SCHEMA:
            refuse_leftover(command, entry.name, "is not a complete manifest-bound archive")
        remove_tree_forcibly(entry)
    prune_empty_archive_parent(state)


def fsync_staged_tree(staging: Path) -> None:
    for base, _, files in os.walk(str(staging), topdown=False):
        for name in files:
            path = Path(base) / name
            if not path.is_symlink():
                fsync_path(path)
        fsync_path(Path(base))


def legacy_source_entries(state: Path, paths: Sequence[Path]) -> List[Dict[str, object]]:
    seen: Dict[str, Dict[str, object]] = {}
    pending = list(paths)
    while pending:
        current = pending.pop()
        relative = current.relative_to(state).as_posix()
        info = current.lstat()
        item: Dict[str, object] = {"path": relative}
        if stat.S_ISLNK(info.st_mode):
            item["type"] = "symlink"
            item["target"] = os.readlink(str(current))
        elif stat.S_ISDIR(info.st_mode):
            item["type"] = "directory"
            pending.extend(current.iterdir())
        elif stat.S_ISREG(info.st_mode):
            item["type"] = "file"
            item["sha256"] = hash_regular_file(current)
            item["size"] = info.st_size
        else:
            item["type"] = "other"
        seen[relative] = item
    return [seen[key] for key in sorted(seen)]


def decode_archive_manifest(manifest_path: Path) -> List[Dict[str, object]]:
    try:
        raw = manifest_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise UserError("the staged Telegram archive manifest is unreadable: %s" % exc)
    try:
        document = json.loads(raw)
    except ValueError as exc:
        raise UserError("the staged Telegram archive manifest is not valid JSON: %s" % exc)
    if not isinstance(document, dict):
        raise UserError("the staged Telegram archive manifest is not an object")
    if document.get("schema") != ARCHIVE_SCHEMA:
        raise UserError("the staged Telegram archive manifest has an unknown schema")
    if type(document.get("created_at")) is not int:
        raise UserError("the staged Telegram archive manifest has no valid timestamp")
    entries = document.get("entries")
    if not isinstance(entries, list):
        raise UserError("the staged Telegram archive manifest has no entry list")
    for entry in entries:
        if not isinstance(entry, dict):
            raise UserError("the staged Telegram archive manifest has a malformed entry")
        if not isinstance(entry.get("path"), str) or type(entry.get("mode")) is not int:
            raise UserError("the staged Telegram archive manifest has a malformed entry")
        if entry.get("type") not in ARCHIVE_ENTRY_TYPES:
            raise UserError("the staged Telegram archive manifest has an unknown entry type")
        if entry.get("type") == "file" and (
            not isinstance(entry.get("sha256"), str) or type(entry.get("size")) is not int
        ):
            raise UserError(
                "the staged Telegram archive manifest has a malformed file entry"
            )
        if entry.get("type") == "symlink" and not isinstance(entry.get("target"), str):
            raise UserError(
                "the staged Telegram archive manifest has a malformed symlink entry"
            )
    return entries


def first_entry_difference(
    expected: Sequence[Dict[str, object]], observed: Sequence[Dict[str, object]]
) -> str:
    expected_map = {str(item.get("path")): item for item in expected}
    observed_map = {str(item.get("path")): item for item in observed}
    for name in sorted(set(expected_map) | set(observed_map)):
        if expected_map.get(name) != observed_map.get(name):
            return name
    return "entry order"


def verify_staged_archive(
    state: Path, copied: Path, manifest_path: Path, paths: Sequence[Path]
) -> None:
    declared = decode_archive_manifest(manifest_path)
    observed = archive_manifest_entries(copied)
    if declared != observed:
        raise UserError(
            "the staged Telegram archive does not match its manifest at %s"
            % first_entry_difference(declared, observed)
        )
    staged = {str(entry.get("path")): entry for entry in observed}
    for item in legacy_source_entries(state, paths):
        name = str(item["path"])
        copy = staged.get(name)
        if copy is None:
            raise UserError("the staged Telegram archive is missing %s" % name)
        for key in ("type", "size", "sha256", "target"):
            if item.get(key) != copy.get(key):
                raise UserError(
                    "the staged copy of %s does not match the original legacy artifact"
                    % name
                )


def validate_archive_relative_path(path: object) -> str:
    if not isinstance(path, str) or not path or path.startswith("/") or "\\" in path:
        raise UserError("the Telegram migration archive contains an unsafe path")
    parts = path.split("/")
    if any(part in ("", ".", "..") for part in parts):
        raise UserError("the Telegram migration archive contains a path-escaping entry")
    return path


def resolution_archive(state: Path, relative_archive: object) -> Tuple[Path, str, List[Dict[str, object]]]:
    if not isinstance(relative_archive, str) or not re.fullmatch(
        r"telegram-migration-archive/[0-9]{8}T[0-9]{6}Z-[0-9a-f]{8}",
        relative_archive,
    ):
        raise UserError("migration archive binding is unsafe")
    archive_parent = state / ARCHIVE_PARENT_NAME
    archive = state / relative_archive
    manifest = archive / "manifest.json"
    copied = archive / "state"
    ensure_existing_directory(archive_parent, 0o500)
    try:
        parent_entries = sorted(item.name for item in archive_parent.iterdir())
    except OSError as exc:
        raise UserError("migration archive parent is unreadable: %s" % exc)
    if parent_entries != [archive.name]:
        raise UserError("migration archive parent contains an unexpected archive")
    ensure_existing_directory(archive, 0o500)
    try:
        archive_entries = sorted(item.name for item in archive.iterdir())
    except OSError as exc:
        raise UserError("migration archive is unreadable: %s" % exc)
    if archive_entries != ["manifest.json", "state"]:
        raise UserError("migration archive contains an unexpected artifact")
    try:
        manifest_info = manifest.lstat()
        copied_info = copied.lstat()
    except OSError as exc:
        raise UserError("migration archive is missing a sealed artifact: %s" % exc)
    if (
        stat.S_ISLNK(manifest_info.st_mode)
        or not stat.S_ISREG(manifest_info.st_mode)
        or stat.S_IMODE(manifest_info.st_mode) != 0o400
    ):
        raise UserError("migration archive manifest is not a sealed regular file")
    if (
        stat.S_ISLNK(copied_info.st_mode)
        or not stat.S_ISDIR(copied_info.st_mode)
        or stat.S_IMODE(copied_info.st_mode) != 0o500
    ):
        raise UserError("migration archive state tree is not sealed")
    try:
        raw_manifest = manifest.read_bytes()
    except OSError as exc:
        raise UserError("migration archive manifest is unreadable: %s" % exc)
    declared = decode_archive_manifest(manifest)
    for entry in declared:
        validate_archive_relative_path(entry.get("path"))
        mode = entry.get("mode")
        if type(mode) is not int or mode < 0 or mode > 0o7777:
            raise UserError("migration archive manifest has an invalid mode")
        if entry.get("type") == "file":
            digest = entry.get("sha256")
            size = entry.get("size")
            if not isinstance(digest, str) or RESOLUTION_DIGEST_RE.fullmatch(digest) is None:
                raise UserError("migration archive manifest has an invalid file digest")
            if type(size) is not int or size < 0:
                raise UserError("migration archive manifest has an invalid file size")
        if entry.get("type") == "symlink" and (
            not isinstance(entry.get("target"), str)
            or entry.get("target", "").startswith("/")
        ):
            raise UserError("migration archive manifest has an unsafe symlink")
    observed = archive_manifest_entries(copied)
    declared_shape = [dict(entry, mode=0) for entry in declared]
    observed_shape = [dict(entry, mode=0) for entry in observed]
    if declared_shape != observed_shape:
        raise UserError(
            "migration archive does not match its manifest at %s"
            % first_entry_difference(declared_shape, observed_shape)
        )
    for entry in observed:
        path = copied / str(entry["path"])
        if entry["type"] == "file" and stat.S_IMODE(path.lstat().st_mode) != 0o400:
            raise UserError("migration archive file is not sealed: %s" % entry["path"])
        if entry["type"] == "directory" and stat.S_IMODE(path.lstat().st_mode) != 0o500:
            raise UserError("migration archive directory is not sealed: %s" % entry["path"])
    return archive, hashlib.sha256(raw_manifest).hexdigest(), declared


def resolution_payload(path: Path) -> int:
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise ValueError("payload is not a regular file")
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise UserError("legacy payload is not resolvable: %s" % exc)
    if not isinstance(data, dict) or not valid_update_id(data.get("update_id")):
        raise UserError("legacy payload has an invalid update id")
    update_id = int(data["update_id"])
    if path.name != "%d.json" % update_id:
        raise UserError("legacy payload filename disagrees with its update id")
    if not isinstance(data.get("text"), str) or not data["text"]:
        raise UserError("legacy payload has no usable text")
    if type(data.get("date")) is not int or type(data.get("chat_id")) is not int:
        raise UserError("legacy payload has unsupported identity or date ambiguity")
    if "from_id" in data and type(data["from_id"]) is not int:
        raise UserError("legacy payload has malformed sender identity")
    return update_id


def resolution_payloads(archive_state: Path) -> List[ResolutionPayload]:
    found: List[ResolutionPayload] = []
    for relative_dir in ("telegram-inbox", ".telegram-delivery-receipts"):
        directory = archive_state / relative_dir
        if not directory.exists() and not directory.is_symlink():
            continue
        info = directory.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
            raise UserError("legacy payload directory is not a regular directory")
        for entry in sorted(directory.iterdir()):
            if relative_dir == "telegram-inbox" and entry.name == "handled":
                continue
            if relative_dir == ".telegram-delivery-receipts" and entry.name.startswith("tmp."):
                info = entry.lstat()
                if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
                    raise UserError("legacy temporary receipt is not a regular file")
                continue
            if not entry.name.endswith(".json"):
                raise UserError("legacy payload directory has an unknown entry")
            update_id = resolution_payload(entry)
            found.append(
                ResolutionPayload(
                    "%s/%s" % (relative_dir, entry.name),
                    update_id,
                    hash_regular_file(entry),
                    entry.stat().st_size,
                )
            )
    if not found:
        raise UserError("no resolvable legacy payload blockers are present")
    by_update: Dict[int, str] = {}
    for payload in found:
        previous = by_update.get(payload.update_id)
        if previous is not None and previous != payload.sha256:
            raise UserError("legacy payload copies conflict for one update")
        by_update[payload.update_id] = payload.sha256
    return sorted(found, key=lambda item: item.path)


def resolution_evidence(state: Path, conn: sqlite3.Connection) -> ResolutionEvidence:
    row = conn.execute(
        "SELECT migration_status, committed_offset, last_success, consecutive_failures, "
        "first_failure, migration_archive, migration_fingerprint, migration_cause "
        "FROM meta WHERE singleton = 1"
    ).fetchone()
    if row is None or row[0] != "blocked":
        raise UserError("there is no blocked migration to resolve")
    if row[1] != 0 or row[2] is not None or row[3] != 0 or row[4] is not None:
        raise UserError("blocked migration has unexpected live state")
    if not row[5] or not row[6] or not row[7]:
        raise UserError("blocked migration has incomplete historical binding")
    if conn.execute("SELECT COUNT(*) FROM messages").fetchone()[0] != 0:
        raise UserError("blocked migration already contains messages")
    if conn.execute("SELECT COUNT(*) FROM conditions").fetchone()[0] != 0:
        raise UserError("blocked migration already contains conditions")
    notices = conn.execute(
        "SELECT id, kind, acknowledged_at FROM notices ORDER BY id"
    ).fetchall()
    if len(notices) != 1 or notices[0][1] != "migration-blocked":
        raise UserError("blocked migration notices do not match one migration episode")
    archive, manifest_digest, _ = resolution_archive(state, row[5])
    archive_state = archive / "state"
    payloads = resolution_payloads(archive_state)
    handled = read_legacy_payload_directory(
        archive_state / "telegram-inbox" / "handled", allow_temps=False, require_payload=False
    )
    if any(
        item.update_id in handled and item.path.startswith("telegram-inbox/")
        for item in payloads
    ):
        raise UserError("legacy payload is both live and handled")
    payloads = [item for item in payloads if item.update_id not in handled]
    if not payloads:
        raise UserError("no resolvable legacy payload blockers are present")
    for payload in payloads:
        source = state / payload.path
        try:
            source_info = source.lstat()
            if stat.S_ISLNK(source_info.st_mode) or not stat.S_ISREG(source_info.st_mode):
                raise UserError("preserved legacy source is not a regular file: %s" % payload.path)
            if source_info.st_size != payload.size or hash_regular_file(source) != payload.sha256:
                raise UserError("preserved legacy source changed: %s" % payload.path)
        except OSError as exc:
            raise UserError("preserved legacy source is unavailable: %s" % exc)
    offset = parse_legacy_offset(archive_state)
    pending = parse_legacy_pending(archive_state)
    ids = {item.update_id for item in payloads}
    if pending is not None:
        count, target = pending
        if target < offset or len(ids) != count:
            raise UserError("legacy pending target cannot be mapped to exact blockers")
        offset = target
    plan = MigrationPlan(
        offset=offset,
        handled_messages=[handled[key] for key in sorted(handled)]
        + [PlannedMessage(update_id, None) for update_id in sorted(ids)],
        pending_messages=[],
        api_conditions=parse_legacy_blocks(archive_state),
    )
    return ResolutionEvidence(row[6], manifest_digest, payloads, plan)


def stage_migration_archive(state: Path, staging: Path, paths: Sequence[Path]) -> None:
    staging.mkdir(mode=0o700)
    copied = staging / "state"
    copied.mkdir(mode=0o700)
    for source in paths:
        relative = source.relative_to(state)
        destination = copied / relative
        destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = source.lstat()
        try:
            if stat.S_ISLNK(info.st_mode):
                destination.symlink_to(os.readlink(str(source)))
            elif stat.S_ISDIR(info.st_mode):
                shutil.copytree(source, destination, symlinks=True)
            elif stat.S_ISREG(info.st_mode):
                shutil.copy2(source, destination, follow_symlinks=False)
            else:
                raise UserError(
                    "legacy artifact %s has an unsupported file type" % relative.as_posix()
                )
        except UserError:
            raise
        except Exception as exc:
            raise UserError(
                "legacy artifact %s could not be archived: %s"
                % (relative.as_posix(), copy_failure_detail(state, exc))
            )
    synchronization_failpoint("staged-copies")
    fsync_staged_tree(staging)
    manifest = {
        "schema": ARCHIVE_SCHEMA,
        "created_at": now_epoch(),
        "entries": archive_manifest_entries(copied),
    }
    manifest_path = staging / "manifest.json"
    manifest_path.write_text(
        json.dumps(manifest, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    with manifest_path.open("rb") as handle:
        os.fsync(handle.fileno())
    fsync_directory(staging)
    synchronization_failpoint("staged-archive")
    verify_staged_archive(state, copied, manifest_path, paths)


def make_migration_archive(state: Path, paths: Sequence[Path]) -> Path:
    archive_parent = state / ARCHIVE_PARENT_NAME
    if archive_parent.exists() or archive_parent.is_symlink():
        ensure_existing_directory(archive_parent, 0o700)
    else:
        archive_parent.mkdir(mode=0o700)
        fsync_directory(state)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    suffix = uuid.uuid4().hex[:8]
    staging = state / ("%s%d-%s" % (STAGING_PREFIX, os.getpid(), suffix))
    marker = staging_marker_path(staging)
    archive = archive_parent / ("%s-%s" % (stamp, suffix))
    try:
        write_owner_marker(marker, STAGING_SCHEMA)
        stage_migration_archive(state, staging, paths)
        for base, directories, files in os.walk(str(staging), topdown=False):
            for name in files:
                path = Path(base) / name
                if not path.is_symlink():
                    os.chmod(path, 0o400)
            for name in directories:
                path = Path(base) / name
                if not path.is_symlink():
                    os.chmod(path, 0o500)
        failpoint("after_stage")
        os.replace(str(staging), str(archive))
        os.chmod(archive, 0o500)
        fsync_directory(archive_parent)
        unlink_quietly(marker)
        fsync_directory(state)
        failpoint("after_archive_publish")
    except BaseException:
        remove_tree_forcibly(staging)
        remove_tree_forcibly(archive)
        unlink_quietly(marker)
        raise
    return archive


def discard_migration_archive(state: Path, archive: Path) -> None:
    unseal_migration_archive_parent(state)
    remove_tree_forcibly(archive)


def unseal_migration_archive_parent(state: Path) -> None:
    archive_parent = state / ARCHIVE_PARENT_NAME
    if archive_parent.is_symlink() or not archive_parent.is_dir():
        return
    try:
        os.chmod(archive_parent, 0o700)
    except OSError:
        pass


def prune_empty_archive_parent(state: Path) -> None:
    archive_parent = state / ARCHIVE_PARENT_NAME
    if archive_parent.is_symlink() or not archive_parent.is_dir():
        return
    try:
        if any(archive_parent.iterdir()):
            return
        archive_parent.rmdir()
        fsync_directory(state)
    except OSError:
        pass


def seal_migration_archive_parent(state: Path) -> None:
    archive_parent = state / ARCHIVE_PARENT_NAME
    os.chmod(archive_parent, 0o500)
    fsync_directory(state)


def parse_legacy_payload(path: Path, require_payload: bool) -> PlannedMessage:
    try:
        info = path.lstat()
        if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
            raise ValueError("payload is not a regular file")
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, ValueError) as exc:
        raise UserError("legacy payload is ambiguous at %s: %s" % (path, exc))
    if not isinstance(data, dict):
        raise UserError("legacy payload is not an object: %s" % path)
    update_id = data.get("update_id")
    if not valid_update_id(update_id):
        raise UserError("legacy payload has an invalid update id: %s" % path)
    if not require_payload:
        return PlannedMessage(update_id, None)
    text = data.get("text")
    if not isinstance(text, str) or not text:
        raise UserError("legacy payload has no usable text: %s" % path)
    if type(data.get("chat_id")) is not int or type(data.get("from_id")) is not int:
        raise UserError(
            "legacy payload awaiting delivery has no coherent chat or sender identity: %s"
            % path
        )
    if type(data.get("date")) is not int:
        raise UserError(
            "legacy payload awaiting delivery has no coherent integer date: %s" % path
        )
    canonical = json.dumps(
        {
            "update_id": update_id,
            "date": data.get("date"),
            "chat_id": data.get("chat_id"),
            "from_id": data.get("from_id"),
            "text": text,
        },
        ensure_ascii=False,
        sort_keys=True,
        separators=(",", ":"),
    )
    return PlannedMessage(update_id, canonical)


def read_legacy_payload_directory(
    directory: Path, allow_temps: bool, require_payload: bool
) -> Dict[int, PlannedMessage]:
    messages: Dict[int, PlannedMessage] = {}
    if not directory.exists() and not directory.is_symlink():
        return messages
    info = directory.lstat()
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISDIR(info.st_mode):
        raise UserError("legacy payload directory is ambiguous: %s" % directory)
    for entry in sorted(directory.iterdir()):
        if entry.name == "handled" and directory.name == "telegram-inbox":
            continue
        if allow_temps and entry.name.startswith("tmp."):
            if not entry.is_file() or entry.is_symlink():
                raise UserError("legacy temporary receipt is ambiguous: %s" % entry)
            continue
        if not entry.name.endswith(".json"):
            raise UserError("legacy payload directory has an unknown entry: %s" % entry)
        message = parse_legacy_payload(entry, require_payload)
        if entry.name != "%d.json" % message.update_id:
            raise UserError("legacy payload filename disagrees with its update id: %s" % entry)
        existing = messages.get(message.update_id)
        if existing is not None and existing.payload != message.payload:
            raise UserError("legacy payloads conflict for update %d" % message.update_id)
        messages[message.update_id] = message
    return messages


def parse_legacy_offset(state: Path) -> int:
    path = state / ".telegram-offset"
    if not path.exists() and not path.is_symlink():
        return 0
    try:
        info = path.lstat()
        text = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise UserError("legacy offset is ambiguous: %s" % exc)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UserError("legacy offset is not a regular file")
    if not re.fullmatch(r"[0-9]+", text):
        raise UserError("legacy offset is not an unsigned integer")
    offset = int(text)
    if not 0 <= offset <= MAX_OFFSET:
        raise UserError("legacy offset is outside the supported range")
    return offset


def parse_legacy_blocks(state: Path) -> List[str]:
    path = state / ".telegram-blocked"
    if not path.exists() and not path.is_symlink():
        return []
    try:
        info = path.lstat()
        lines = path.read_text(encoding="ascii").splitlines()
    except (OSError, UnicodeDecodeError) as exc:
        raise UserError("legacy blocked marker is ambiguous: %s" % exc)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UserError("legacy blocked marker is not a regular file")
    if len(lines) != len(set(lines)) or any(line not in ("401", "409") for line in lines):
        raise UserError("legacy blocked marker is malformed")
    return ["api-%s" % line for line in lines]


def parse_legacy_pending(state: Path) -> Optional[Tuple[int, int]]:
    path = state / ".telegram-pending-delivery"
    if not path.exists() and not path.is_symlink():
        return None
    try:
        info = path.lstat()
        text = path.read_text(encoding="ascii").strip()
    except (OSError, UnicodeDecodeError) as exc:
        raise UserError("legacy pending record is ambiguous: %s" % exc)
    if stat.S_ISLNK(info.st_mode) or not stat.S_ISREG(info.st_mode):
        raise UserError("legacy pending record is not a regular file")
    match = re.fullmatch(r"([1-9][0-9]*) ([0-9]+)", text)
    if match is None:
        raise UserError("legacy pending record is malformed")
    count = int(match.group(1))
    target = int(match.group(2))
    if target > MAX_OFFSET:
        raise UserError("legacy pending target is outside the supported range")
    return count, target


def unhandled_legacy_results(state: Path) -> List[Path]:
    inbox = state / "procevent-inbox"
    if not inbox.is_dir() or inbox.is_symlink():
        return []
    pending = []
    for result in sorted(inbox.glob("telegram.*.result")):
        handled = result.with_suffix(".handled")
        if not handled.exists() and not handled.is_symlink():
            pending.append(result)
    return pending


def refuse_unhandled_legacy_results(state: Path) -> None:
    unhandled = unhandled_legacy_results(state)
    if not unhandled:
        return
    listed = ", ".join(path.relative_to(state).as_posix() for path in unhandled)
    raise UserError(
        "%d captured legacy Telegram result%s still unhandled: %s; act on each one, run "
        "bin/fm-procevent.sh handled telegram <sequence> for it, then rerun migrate "
        "(nothing was archived or created)"
        % (len(unhandled), "" if len(unhandled) == 1 else "s", listed)
    )


def build_migration_plan(state: Path) -> MigrationPlan:
    offset = parse_legacy_offset(state)
    api_conditions = parse_legacy_blocks(state)
    pending = parse_legacy_pending(state)
    inbox = state / "telegram-inbox"
    live = read_legacy_payload_directory(inbox, allow_temps=False, require_payload=True)
    handled = read_legacy_payload_directory(
        inbox / "handled", allow_temps=False, require_payload=False
    )
    receipts = read_legacy_payload_directory(
        state / ".telegram-delivery-receipts", allow_temps=True, require_payload=True
    )
    overlapping = set(live) & set(handled)
    if overlapping:
        raise UserError(
            "legacy messages are both live and handled: %s"
            % ",".join(str(value) for value in sorted(overlapping))
        )
    for update_id, message in list(receipts.items()):
        if update_id in handled:
            del receipts[update_id]
            continue
        existing = live.get(update_id)
        if existing is not None and existing.payload != message.payload:
            raise UserError("legacy receipt conflicts with the live payload")
        live[update_id] = message
    pending_messages: Dict[int, PlannedMessage] = {}
    if pending is not None:
        count, target = pending
        if target < offset:
            raise UserError("legacy pending target is below the committed offset")
        offset = target
        candidates = receipts if receipts else live
        if len(candidates) != count:
            raise UserError("legacy pending count cannot be mapped to exact messages")
        pending_messages.update(candidates)
    elif receipts:
        pending_messages.update(receipts)
    if pending_messages:
        extras = set(live) - set(pending_messages)
        if extras:
            raise UserError("legacy live inbox contains messages with unknown notice state")
    elif live:
        raise UserError("legacy live inbox contains messages with unknown notice state")
    return MigrationPlan(
        offset=offset,
        handled_messages=[handled[key] for key in sorted(handled)],
        pending_messages=[pending_messages[key] for key in sorted(pending_messages)],
        api_conditions=api_conditions,
    )


def import_migration_plan(conn: sqlite3.Connection, plan: MigrationPlan) -> None:
    for message in plan.handled_messages:
        conn.execute(
            "INSERT INTO messages (update_id, payload, notice_id, handled_at) "
            "VALUES (?, ?, NULL, ?)",
            (message.update_id, message.payload, now_epoch()),
        )
    if plan.pending_messages:
        notice_id = create_notice(conn, "message", "captain-messages")
        for message in plan.pending_messages:
            conn.execute(
                "INSERT INTO messages (update_id, payload, notice_id, handled_at) "
                "VALUES (?, ?, ?, NULL)",
                (message.update_id, message.payload, notice_id),
            )
    for condition in plan.api_conditions:
        detail = condition.split("-", 1)[1]
        conn.execute(
            "INSERT INTO conditions (kind, detail, notice_id, started_at) "
            "VALUES (?, ?, NULL, ?)",
            (condition, detail, now_epoch()),
        )


def command_migrate(state: Path) -> int:
    _, database = state_paths(state)
    if database.exists() or database.is_symlink():
        raise UserError("Telegram state database already exists; migration is single-use")
    refuse_unhandled_legacy_results(state)
    reconcile_migration_leftovers(state, "migrate")
    paths = legacy_paths_present(state)
    try:
        archive = make_migration_archive(state, paths)
    except Exception as exc:
        prune_empty_archive_parent(state)
        raise UserError(
            "legacy Telegram state could not be archived completely, so no cutover was "
            "attempted and no database exists: %s; repair the reported artifact and rerun "
            "migrate" % migration_cause_text(state, exc)
        )
    except BaseException:
        prune_empty_archive_parent(state)
        raise
    relative_archive = archive.relative_to(state).as_posix()
    plan: Optional[MigrationPlan] = None
    cause: Optional[str] = None
    fingerprint: Optional[str] = None
    publication = Publication()
    try:
        try:
            plan = build_migration_plan(state)
        except Exception as exc:
            cause = migration_cause_text(state, exc)
            fingerprint = state_fingerprint("migration-ambiguous", exc)
        seal_migration_archive_parent(state)
        failpoint("after_archive_seal")
        if plan is None:
            conn = create_store(
                state,
                "blocked",
                relative_archive,
                fingerprint,
                plan=None,
                migration_cause=cause,
                publication=publication,
            )
        else:
            conn = create_store(
                state,
                "complete",
                relative_archive,
                None,
                plan=plan,
                publication=publication,
            )
        conn.close()
    except Exception as exc:
        if publication.published:
            raise UserError(
                "the Telegram cutover database was published but could not be confirmed: "
                "%s; the database and its sealed archive %s are both preserved - run "
                "bin/fm-procevent-telegram.sh doctor before any further action"
                % (migration_cause_text(state, exc), relative_archive)
            )
        discard_migration_archive(state, archive)
        prune_empty_archive_parent(state)
        raise
    except BaseException:
        if not publication.published:
            discard_migration_archive(state, archive)
            prune_empty_archive_parent(state)
        raise
    if plan is None:
        print(
            "blocked: migration-ambiguous fingerprint=%s archive=%s"
            % (fingerprint, relative_archive)
        )
        print("detail: %s" % cause)
        return 1
    print("migrated: archive=%s offset=%d" % (relative_archive, plan.offset))
    return 0


def parse_resolution_acknowledgements(values: Optional[Sequence[str]]) -> List[ResolutionPayload]:
    if not values:
        raise UserError("resolve-migration needs at least one --acknowledge-delivered")
    parsed: List[ResolutionPayload] = []
    seen = set()
    for value in values:
        if not isinstance(value, str) or value.count("=") != 1:
            raise UserError("acknowledgement must be path=sha256:digest")
        path, digest_value = value.split("=", 1)
        if ACKNOWLEDGEMENT_PATH_RE.fullmatch(path) is None:
            raise UserError("acknowledgement path is outside the allowed legacy payload paths")
        if not digest_value.startswith("sha256:"):
            raise UserError("acknowledgement must use sha256:digest")
        digest = digest_value[7:]
        if RESOLUTION_DIGEST_RE.fullmatch(digest) is None:
            raise UserError("acknowledgement digest must be 64 lower-case hex characters")
        if path in seen:
            raise UserError("acknowledgement paths must not be duplicated")
        seen.add(path)
        parsed.append(ResolutionPayload(path, 0, digest, 0))
    return sorted(parsed, key=lambda item: item.path)


def match_resolution_intent(
    evidence: ResolutionEvidence,
    supplied: Sequence[ResolutionPayload],
    fingerprint: Optional[str],
    manifest_digest: Optional[str],
) -> None:
    if fingerprint is None or re.fullmatch(r"[0-9a-f]{16}", fingerprint) is None:
        raise UserError("--blocked-fingerprint must be 16 lower-case hex characters")
    if manifest_digest is None or RESOLUTION_DIGEST_RE.fullmatch(manifest_digest) is None:
        raise UserError("--archive-manifest-sha256 must be 64 lower-case hex characters")
    if fingerprint != evidence.fingerprint:
        raise UserError("blocked migration fingerprint does not match")
    if manifest_digest != evidence.archive_manifest_sha256:
        raise UserError("migration archive manifest digest does not match")
    expected = [(item.path, item.sha256) for item in evidence.payloads]
    actual = [(item.path, item.sha256) for item in supplied]
    if actual != expected:
        raise UserError("acknowledgements must exactly match every derived blocker")


def resolution_rows(conn: sqlite3.Connection) -> List[ResolutionPayload]:
    return [
        ResolutionPayload(path, int(update_id), sha256, int(size))
        for path, update_id, sha256, size in conn.execute(
            "SELECT path, update_id, sha256, size FROM migration_resolution_payloads ORDER BY path"
        )
    ]


def command_resolve_migration(
    state: Path,
    fingerprint: Optional[str],
    manifest_digest: Optional[str],
    acknowledgement_values: Optional[Sequence[str]],
) -> int:
    supplied = parse_resolution_acknowledgements(acknowledgement_values)
    conn = connect_existing(state)
    try:
        meta = conn.execute(
            "SELECT migration_status, committed_offset, migration_archive, "
            "migration_fingerprint FROM meta WHERE singleton = 1"
        ).fetchone()
        if meta is None:
            raise UserError("Telegram state has no singleton metadata")
        has_resolution, has_payloads = resolution_extension_tables(conn)
        if has_resolution != has_payloads:
            raise UserError("resolution proof tables are incomplete")
        if meta[0] == "complete" and has_resolution:
            stored = validate_resolution_extension(conn, meta[0])
            if stored is None:
                raise UserError("resolution proof is unavailable")
            stored_fingerprint, stored_manifest, _, _ = stored
            if fingerprint != stored_fingerprint or manifest_digest != stored_manifest:
                raise UserError("changed resolution intent refuses an already resolved migration")
            stored_rows = resolution_rows(conn)
            if [(item.path, item.sha256) for item in supplied] != [
                (item.path, item.sha256) for item in stored_rows
            ]:
                raise UserError("changed resolution intent refuses an already resolved migration")
            verify_resolved_evidence(state, meta[2], stored_manifest, stored_rows)
            print(
                "already-resolved: migration fingerprint=%s acknowledged-delivered=%d "
                "offset=%d archive=%s"
                % (stored_fingerprint, len(stored_rows), meta[1], meta[2])
            )
            return 0
        if meta[0] != "blocked":
            raise UserError("there is no blocked migration to resolve")
        if fingerprint != meta[3]:
            raise UserError("blocked migration fingerprint does not match")
        evidence = resolution_evidence(state, conn)
        match_resolution_intent(evidence, supplied, fingerprint, manifest_digest)
        conn.execute("BEGIN IMMEDIATE")
        try:
            current = conn.execute(
                "SELECT migration_status, committed_offset, migration_archive, "
                "migration_fingerprint, migration_cause FROM meta WHERE singleton = 1"
            ).fetchone()
            if (
                current is None
                or current[0] != "blocked"
                or current[1] != 0
                or current[2] != meta[2]
                or current[3] != meta[3]
            ):
                raise UserError("blocked migration changed during resolution")
            current_evidence = resolution_evidence(state, conn)
            match_resolution_intent(
                current_evidence, supplied, fingerprint, manifest_digest
            )
            ack_at = now_epoch()
            conn.execute(
                """
                CREATE TABLE migration_resolution (
                    singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
                    kind TEXT NOT NULL CHECK (kind = 'operator-acknowledged-delivery'),
                    blocked_fingerprint TEXT NOT NULL,
                    archive_manifest_sha256 TEXT NOT NULL,
                    acknowledged_at INTEGER NOT NULL CHECK (acknowledged_at >= 0),
                    payload_count INTEGER NOT NULL CHECK (payload_count > 0)
                )
                """
            )
            conn.execute(
                """
                CREATE TABLE migration_resolution_payloads (
                    path TEXT PRIMARY KEY,
                    update_id INTEGER NOT NULL
                        CHECK (update_id >= 1 AND update_id <= 2147483647),
                    sha256 TEXT NOT NULL,
                    size INTEGER NOT NULL CHECK (size >= 0),
                    resolution INTEGER NOT NULL DEFAULT 1
                        REFERENCES migration_resolution(singleton) ON DELETE RESTRICT,
                    CHECK (resolution = 1)
                )
                """
            )
            failpoint("after_resolution_ddl")
            conn.execute(
                "INSERT INTO migration_resolution "
                "(singleton, kind, blocked_fingerprint, archive_manifest_sha256, "
                "acknowledged_at, payload_count) VALUES (1, ?, ?, ?, ?, ?)",
                (
                    "operator-acknowledged-delivery",
                    fingerprint,
                    manifest_digest,
                    ack_at,
                    len(current_evidence.payloads),
                ),
            )
            for item in current_evidence.payloads:
                conn.execute(
                    "INSERT INTO migration_resolution_payloads "
                    "(path, update_id, sha256, size) VALUES (?, ?, ?, ?)",
                    (item.path, item.update_id, item.sha256, item.size),
                )
            failpoint("after_resolution_ack")
            notice = conn.execute(
                "SELECT id, acknowledged_at FROM notices WHERE kind = 'migration-blocked'"
            ).fetchone()
            if notice is None:
                raise UserError("migration notice is missing")
            if notice[1] is None:
                conn.execute(
                    "UPDATE notices SET acknowledged_at = ? WHERE id = ?",
                    (ack_at, notice[0]),
                )
            for message in current_evidence.plan.handled_messages:
                handled_at = ack_at if message.update_id in {
                    item.update_id for item in current_evidence.payloads
                } else now_epoch()
                conn.execute(
                    "INSERT INTO messages (update_id, payload, notice_id, handled_at) "
                    "VALUES (?, NULL, NULL, ?)",
                    (message.update_id, handled_at),
                )
            failpoint("after_resolution_tombstone")
            for condition in current_evidence.plan.api_conditions:
                detail = condition.split("-", 1)[1]
                conn.execute(
                    "INSERT INTO conditions (kind, detail, notice_id, started_at) "
                    "VALUES (?, ?, NULL, ?)",
                    (condition, detail, ack_at),
                )
            failpoint("after_resolution_plan")
            conn.execute(
                "UPDATE meta SET migration_status = 'complete', committed_offset = ? "
                "WHERE singleton = 1",
                (current_evidence.plan.offset,),
            )
            failpoint("after_resolution_meta")
            verify_integrity(conn)
            validate_store(conn)
            failpoint("before_resolution_commit")
            conn.commit()
            failpoint("after_resolution_commit")
            print(
                "resolved: migration fingerprint=%s acknowledged-delivered=%d "
                "offset=%d archive=%s"
                % (
                    fingerprint,
                    len(current_evidence.payloads),
                    current_evidence.plan.offset,
                    meta[2],
                )
            )
            return 0
        except Exception:
            conn.rollback()
            raise
    finally:
        conn.close()


def verify_resolved_evidence(
    state: Path,
    archive_relative: str,
    manifest_digest: str,
    rows: Sequence[ResolutionPayload],
) -> None:
    archive, actual_digest, _ = resolution_archive(state, archive_relative)
    if actual_digest != manifest_digest:
        raise UserError("resolved migration archive manifest changed")
    for item in rows:
        source = state / item.path
        archived = archive / "state" / item.path
        if (
            source.is_symlink()
            or not source.is_file()
            or archived.is_symlink()
            or not archived.is_file()
            or source.stat().st_size != item.size
            or hash_regular_file(source) != item.sha256
            or archived.stat().st_size != item.size
            or hash_regular_file(archived) != item.sha256
        ):
            raise UserError("resolved legacy payload evidence changed")


def command_doctor(state: Path) -> int:
    try:
        conn = connect_existing(state)
    except Exception as exc:
        print(local_block_line(exc))
        if isinstance(exc, LocalStateError):
            print("detail: %s: %s" % (exc.code, clean_error_detail(exc.detail)))
        else:
            print("detail: %s" % clean_error_detail(exc))
        return 1
    try:
        meta = conn.execute(
            "SELECT schema_version, state_uuid, committed_offset, last_success, "
            "consecutive_failures, migration_status, migration_archive, "
            "migration_fingerprint, migration_cause FROM meta WHERE singleton = 1"
        ).fetchone()
        print("integrity=ok")
        print("schema_version=%d" % meta[0])
        print("state_uuid=%s" % meta[1])
        print("committed_offset=%d" % meta[2])
        print("last_success=%s" % (meta[3] if meta[3] is not None else "none"))
        print("consecutive_failures=%d" % meta[4])
        print("migration_status=%s" % meta[5])
        print("migration_archive=%s" % (meta[6] if meta[6] else "none"))
        print("migration_fingerprint=%s" % (meta[7] if meta[7] else "none"))
        print("migration_cause=%s" % (meta[8] if meta[8] else "none"))
        if meta[5] == "blocked":
            try:
                evidence = resolution_evidence(state, conn)
                print("migration_resolution=available")
                print(
                    "migration_resolution_manifest_sha256=%s"
                    % evidence.archive_manifest_sha256
                )
                print(
                    "migration_resolution_blocker_count=%d" % len(evidence.payloads)
                )
                for number, item in enumerate(evidence.payloads, 1):
                    print(
                        "migration_resolution_blocker.%d=%s update_id=%d sha256=%s size=%d"
                        % (number, item.path, item.update_id, item.sha256, item.size)
                    )
            except Exception as exc:
                print("migration_resolution=unavailable")
                print(
                    "migration_resolution_detail=%s"
                    % migration_cause_text(state, exc)
                )
        elif meta[5] == "complete":
            extension = validate_resolution_extension(conn, meta[5])
            if extension is not None:
                fingerprint, digest, resolved_at, count = extension
                rows = resolution_rows(conn)
                print("migration_resolution=operator-acknowledged-delivery")
                print("migration_resolution_at=%d" % resolved_at)
                print("migration_resolution_payload_count=%d" % count)
                print("migration_resolution_manifest_sha256=%s" % digest)
                for number, item in enumerate(rows, 1):
                    print(
                        "migration_resolution_ack.%d=%s update_id=%d sha256=%s size=%d"
                        % (number, item.path, item.update_id, item.sha256, item.size)
                    )
                try:
                    verify_resolved_evidence(state, meta[6], digest, rows)
                    print("migration_resolution_evidence=verified")
                except Exception as exc:
                    print("migration_resolution_evidence=unavailable")
                    print(
                        "migration_resolution_detail=%s"
                        % migration_cause_text(state, exc)
                    )
        totals = {"sent": 0, "reserved": 0, "definitely-failed": 0, "delivery-unknown": 0}
        for label, count in conn.execute(REPLY_LABEL_COUNTS_SQL):
            totals[label] = count
        print("reply_count=%d" % sum(totals.values()))
        print("reply_sent=%d" % totals["sent"])
        print("reply_reserved=%d" % totals["reserved"])
        print("reply_definitely_failed=%d" % totals["definitely-failed"])
        print("reply_delivery_unknown=%d" % totals["delivery-unknown"])
        attention = conn.execute(
            "SELECT update_id, state, network_started, failure_detail FROM replies "
            "WHERE state != 'sent' ORDER BY updated_at DESC, update_id DESC LIMIT ?",
            (DOCTOR_REPLY_ATTENTION_LIMIT,),
        ).fetchall()
        for update_id, reply_state, network_started, failure in attention:
            label = reply_label(reply_state, network_started)
            if failure is None:
                print("reply.%d=%s" % (update_id, label))
            else:
                print("reply.%d=%s detail=%s" % (update_id, label, failure))
        print(
            "reply_attention_omitted=%d"
            % (sum(totals.values()) - totals["sent"] - len(attention))
        )
        print(
            "pending_notices=%d"
            % conn.execute(
                "SELECT COUNT(*) FROM notices WHERE acknowledged_at IS NULL"
            ).fetchone()[0]
        )
        conditions = ",".join(
            row[0]
            for row in conn.execute("SELECT kind FROM conditions ORDER BY kind")
        )
        print("active_conditions=%s" % (conditions if conditions else "none"))
        print("journal_mode=%s" % conn.execute("PRAGMA journal_mode").fetchone()[0])
        print("synchronous=%s" % conn.execute("PRAGMA synchronous").fetchone()[0])
        print("fullfsync=%s" % conn.execute("PRAGMA fullfsync").fetchone()[0])
        return 0
    finally:
        conn.close()


def command_export_legacy_offset(state: Path) -> int:
    conn = connect_existing(state)
    try:
        migration_status, offset = conn.execute(
            "SELECT migration_status, committed_offset FROM meta WHERE singleton = 1"
        ).fetchone()
        if migration_status == "blocked":
            raise UserError("cannot export an offset from blocked migration state")
    finally:
        conn.close()
    old_path = state / ".telegram-offset"
    if old_path.exists() or old_path.is_symlink():
        old_offset = parse_legacy_offset(state)
        if old_offset > offset:
            raise UserError(
                "legacy offset is newer than the transactional offset; refusing rollback export"
            )
    fd, temp_name = tempfile.mkstemp(prefix=".telegram-offset.export.", dir=str(state))
    temp = Path(temp_name)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="ascii") as handle:
            handle.write("%d\n" % offset)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temp, old_path)
        fsync_directory(state)
    except Exception:
        try:
            os.close(fd)
        except OSError:
            pass
        try:
            temp.unlink()
        except OSError:
            pass
        raise
    print("exported-offset: %d" % offset)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--state", required=True)
    parser.add_argument("--credentials")
    parser.add_argument(
        "command",
        choices=(
            "ack",
            "arm-state",
            "classify",
            "credential-check",
            "doctor",
            "reply",
            "export-legacy-offset",
            "messages",
            "migrate",
            "poll",
            "resolve-migration",
        ),
    )
    parser.add_argument("argument", nargs="?")
    parser.add_argument("--blocked-fingerprint")
    parser.add_argument("--archive-manifest-sha256")
    parser.add_argument("--acknowledge-delivered", action="append")
    return parser


def dispatch(arguments: argparse.Namespace) -> int:
    state = Path(arguments.state)
    command = arguments.command
    if command == "poll":
        if not arguments.credentials:
            raise UserError("poll needs --credentials")
        return command_poll(state, Path(arguments.credentials))
    if command == "reply":
        if not arguments.credentials:
            raise UserError("reply needs --credentials")
        if not arguments.argument:
            raise UserError("reply needs an accepted inbound update id")
        return command_reply(state, Path(arguments.credentials), arguments.argument)
    if command == "credential-check":
        if not arguments.credentials:
            raise UserError("credential-check needs --credentials")
        return command_check_credentials(Path(arguments.credentials))
    if command == "arm-state":
        return command_arm_state(state)
    if command == "migrate":
        return command_migrate(state)
    if command == "doctor":
        return command_doctor(state)
    if command == "export-legacy-offset":
        return command_export_legacy_offset(state)
    if command == "resolve-migration":
        return command_resolve_migration(
            state,
            arguments.blocked_fingerprint,
            arguments.archive_manifest_sha256,
            arguments.acknowledge_delivered,
        )
    if command in ("classify", "messages", "ack"):
        if not arguments.argument:
            raise UserError("%s needs a result file" % command)
        result_path = Path(arguments.argument)
        if command == "classify":
            return command_classify(state, result_path)
        if command == "messages":
            return command_messages(state, result_path)
        return command_ack(state, result_path)
    raise UserError("unknown command")


def main(argv: Sequence[str]) -> int:
    try:
        arguments = build_parser().parse_args(argv)
        return dispatch(arguments)
    except UserError as exc:
        if "poll" in argv:
            print(local_block_line(exc))
            return 0
        print("error: %s" % exc, file=sys.stderr)
        return 1
    except Exception as exc:
        command = None
        for candidate in (
            "poll",
            "classify",
            "messages",
            "reply",
            "ack",
            "arm-state",
            "doctor",
            "resolve-migration",
        ):
            if candidate in argv:
                command = candidate
                break
        if command == "poll":
            print(local_block_line(exc))
            return 0
        if command == "classify":
            print("blocked")
            return 0
        print("error: local Telegram state failure (%s)" % state_fingerprint(
            exc.__class__.__name__, exc
        ), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
