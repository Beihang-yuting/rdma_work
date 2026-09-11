# 目录：tools，RDMA 驱动归档契约解析层。
# 职责：提供不修改输入的 archive lock/source manifest 解析和规范校验。
# 所有权与生命周期：返回的 frozen dataclass 独立拥有解析值，Path 由调用方管理。

from __future__ import annotations

from dataclasses import dataclass
import hashlib
from pathlib import Path, PurePosixPath
import re


class ContractError(RuntimeError):
    """受版本控制的驱动契约输入无效或彼此不一致。"""


@dataclass(frozen=True)
class ArchiveLock:
    archive_id: str
    sha256: str
    size_bytes: int
    prefix: str
    member_list_sha256: str
    member_count: int


@dataclass(frozen=True)
class SourceManifestRecord:
    archive_id: str
    path: str
    selector: str
    sha256: str


_ARCHIVE_KEYS = {
    "RDMA_ARCHIVE_ID", "RDMA_ARCHIVE_SHA256", "RDMA_ARCHIVE_SIZE_BYTES",
    "RDMA_ARCHIVE_PREFIX", "RDMA_ARCHIVE_MEMBER_LIST_SHA256", "RDMA_ARCHIVE_MEMBER_COUNT",
}
_LOWER_SHA256 = re.compile(r"[0-9a-f]{64}")


def _load_exact_env(path: Path, expected_keys: set[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.count("=") != 1:
            raise ContractError(f"{path}:{line_number}: expected KEY=VALUE")
        key, value = line.split("=", 1)
        if key not in expected_keys:
            raise ContractError(f"{path}:{line_number}: unknown key {key}")
        if key in values:
            raise ContractError(f"{path}:{line_number}: duplicate key {key}")
        if not value:
            raise ContractError(f"{path}:{line_number}: empty value for {key}")
        values[key] = value
    missing = expected_keys - values.keys()
    if missing:
        raise ContractError(f"{path}: missing keys {sorted(missing)}")
    return values


def _require_lower_sha256(label: str, value: str) -> str:
    if _LOWER_SHA256.fullmatch(value) is None:
        raise ContractError(f"{label} must be 64 lowercase hex digits")
    return value


def _require_positive_decimal(label: str, value: str) -> int:
    if re.fullmatch(r"[1-9][0-9]*", value) is None:
        raise ContractError(f"{label} must be a positive decimal integer")
    return int(value, 10)


def _require_relative_member_path(label: str, value: str) -> str:
    pure_path = PurePosixPath(value)
    raw_parts = value.split("/")
    if pure_path.is_absolute() or value in {"", "."}:
        raise ContractError(f"{label} must be a non-empty relative path")
    if "\\" in value or "\x00" in value:
        raise ContractError(f"{label} contains a non-POSIX separator/control")
    if any(part in {"", ".", ".."} for part in raw_parts):
        raise ContractError(f"{label} contains an unsafe path component")
    return value


def load_archive_lock(path: Path) -> ArchiveLock:
    values = _load_exact_env(path, _ARCHIVE_KEYS)
    prefix = _require_relative_member_path("RDMA_ARCHIVE_PREFIX", values["RDMA_ARCHIVE_PREFIX"])
    if "/" in prefix:
        raise ContractError("RDMA_ARCHIVE_PREFIX must be one top-level name")
    return ArchiveLock(
        archive_id=values["RDMA_ARCHIVE_ID"],
        sha256=_require_lower_sha256("RDMA_ARCHIVE_SHA256", values["RDMA_ARCHIVE_SHA256"]),
        size_bytes=_require_positive_decimal("RDMA_ARCHIVE_SIZE_BYTES", values["RDMA_ARCHIVE_SIZE_BYTES"]),
        prefix=prefix,
        member_list_sha256=_require_lower_sha256("RDMA_ARCHIVE_MEMBER_LIST_SHA256", values["RDMA_ARCHIVE_MEMBER_LIST_SHA256"]),
        member_count=_require_positive_decimal("RDMA_ARCHIVE_MEMBER_COUNT", values["RDMA_ARCHIVE_MEMBER_COUNT"]),
    )


def load_source_manifest(path: Path) -> list[SourceManifestRecord]:
    records: list[SourceManifestRecord] = []
    identities: set[tuple[str, str, str]] = set()
    for line_number, raw_line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        columns = line.split()
        if len(columns) != 4:
            raise ContractError(f"{path}:{line_number}: expected four columns")
        archive_id, relative_path, selector, digest = columns
        relative_path = _require_relative_member_path(f"{path}:{line_number}: source path", relative_path)
        digest = _require_lower_sha256(f"{path}:{line_number}: source sha256", digest)
        if not archive_id or not selector:
            raise ContractError(f"{path}:{line_number}: archive ID and selector are required")
        identity = (archive_id, relative_path, selector)
        if identity in identities:
            raise ContractError(f"{path}:{line_number}: duplicate manifest row")
        identities.add(identity)
        records.append(SourceManifestRecord(archive_id=archive_id, path=relative_path, selector=selector, sha256=digest))
    if not records:
        raise ContractError(f"{path}: source manifest has no records")
    return records


def canonical_member_list_digest(member_names: list[str]) -> str:
    if not member_names:
        raise ContractError("archive member list is empty")
    if len(member_names) != len(set(member_names)):
        raise ContractError("archive member list contains duplicate entries")
    payload = "\n".join(sorted(member_names, key=lambda name: name.encode("utf-8"))) + "\n"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()
