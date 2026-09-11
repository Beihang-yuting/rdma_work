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
    """功能：表示冻结归档身份与摘要；输入输出及副作用：字段只读；失败边界：由 load_archive_lock 校验后构造。"""
    archive_id: str
    sha256: str
    size_bytes: int
    prefix: str
    member_list_sha256: str
    member_count: int


@dataclass(frozen=True)
class SourceManifestRecord:
    """功能：表示单条来源文件契约；输入输出及副作用：保存 archive/path/selector/hash；失败边界：非法值不得绕过解析器。"""
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
    """功能：读取并校验 env 键集合；输入输出及副作用：返回字符串映射；失败边界：未知、重复、缺失或空值抛 ContractError。"""
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
    """功能：校验小写 SHA-256；输入输出及副作用：返回原字符串；失败边界：非 64 位小写十六进制抛错。"""
    if _LOWER_SHA256.fullmatch(value) is None:
        raise ContractError(f"{label} must be 64 lowercase hex digits")
    return value


def _require_positive_decimal(label: str, value: str) -> int:
    """功能：解析正十进制整数；输入输出及副作用：返回 int；失败边界：零、负数或非数字抛错。"""
    if re.fullmatch(r"[1-9][0-9]*", value) is None:
        raise ContractError(f"{label} must be a positive decimal integer")
    return int(value, 10)


def _require_relative_member_path(label: str, value: str) -> str:
    """功能：校验 POSIX 相对成员路径；输入输出及副作用：返回原路径；失败边界：绝对、空组件、遍历、反斜杠或 NUL 抛错。"""
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
    """功能：加载冻结 archive lock；输入输出及副作用：读取 path 并返回不可变 ArchiveLock；失败边界：键值或 prefix 不符契约时抛错。"""
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
    """功能：加载来源 manifest；输入输出及副作用：读取 path 返回记录列表；失败边界：列数、路径、摘要或重复身份非法时抛错。"""
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
    """功能：按 GNU tar 拼写排序计算成员列表摘要；输入输出及副作用：返回 SHA-256；失败边界：空列表或重复成员抛错。"""
    if not member_names:
        raise ContractError("archive member list is empty")
    if len(member_names) != len(set(member_names)):
        raise ContractError("archive member list contains duplicate entries")
    payload = "\n".join(sorted(member_names, key=lambda name: name.encode("utf-8"))) + "\n"
    return hashlib.sha256(payload.encode("utf-8")).hexdigest()
