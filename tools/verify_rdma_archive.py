# 目录：tools，RDMA 驱动归档核验与安全解压入口。
# 职责：在完成字节、成员列表和来源 hash 校验后原子地发布内核根目录。
# 所有权与生命周期：解析结果为不可变契约值；staging 由本模块拥有并在失败时清理。

from __future__ import annotations

import argparse
import hashlib
from pathlib import Path, PurePosixPath
import shutil
import sys
import tarfile
import tempfile

try:
    from .rdma_driver_contract import (
        ContractError, canonical_member_list_digest, load_archive_lock,
        load_source_manifest,
    )
except ImportError:  # pragma: no cover - direct script execution
    from rdma_driver_contract import (
        ContractError, canonical_member_list_digest, load_archive_lock,
        load_source_manifest,
    )


def _safe_name(name: str) -> str:
    """功能：按契约拒绝 tar 成员的绝对、遍历或非 POSIX 名称。
输入输出及副作用：name 是 TarInfo.name，返回原名供进一步校验。
失败边界：空、"."/".." 路径件、反斜杠和 NUL 字符触发 ContractError。"""
    if "\\" in name or "\x00" in name:
        raise ContractError(f"unsafe archive member path: {name!r}")
    check_name = name[:-1] if name.endswith("/") else name
    pure = PurePosixPath(check_name)
    parts = check_name.split("/")
    if pure.is_absolute() or any(part in {"", ".", ".."} for part in parts):
        raise ContractError(f"unsafe archive member path: {name!r}")
    return name


def verify_archive(archive: Path, lock_path: Path, manifest_path: Path, extract_dir: Path) -> Path:
    """功能：校验并安全解压锁定 RDMA archive，原子返回内核根目录。
输入输出及副作用：读取 archive/lock/manifest，在 extract_dir 下创建并重命名 prefix，返回 resolved Path。
失败边界：字节、成员、类型、路径、manifest hash 或目录已存在均拒绝，且仅删除私有 staging。"""
    archive = Path(archive)
    lock = load_archive_lock(Path(lock_path))
    records = load_source_manifest(Path(manifest_path))
    if any(record.archive_id != lock.archive_id for record in records):
        raise ContractError("source manifest archive ID does not match lock")
    if archive.stat().st_size != lock.size_bytes:
        raise ContractError("archive size does not match lock")
    digest = hashlib.sha256()
    with archive.open("rb") as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(chunk)
    if digest.hexdigest() != lock.sha256:
        raise ContractError("archive SHA-256 does not match lock")

    extract_dir = Path(extract_dir)
    if extract_dir.is_symlink():
        raise ContractError("extract directory must not be a symlink")
    extract_dir.mkdir(parents=True, exist_ok=True)
    final_root = extract_dir / lock.prefix
    if final_root.exists():
        raise ContractError(f"destination already exists: {final_root}")
    stage = Path(tempfile.mkdtemp(prefix=".rdma-stage-", dir=str(extract_dir)))
    try:
        member_names: list[str] = []
        infos: list[tarfile.TarInfo] = []
        with tarfile.open(archive, mode="r:gz") as tar:
            for member in tar.getmembers():
                raw_name = member.name + "/" if member.isdir() and not member.name.endswith("/") else member.name
                _safe_name(raw_name)
                if raw_name in member_names:
                    raise ContractError(f"duplicate archive member: {raw_name}")
                if not (member.isfile() or member.isdir()):
                    raise ContractError(f"unsupported archive member type: {raw_name}")
                member_names.append(raw_name)
                infos.append(member)
            if len(member_names) != lock.member_count:
                raise ContractError("archive member count does not match lock")
            if canonical_member_list_digest(member_names) != lock.member_list_sha256:
                raise ContractError("archive member list digest does not match lock")
            tops = {name.split("/", 1)[0] for name in member_names}
            if tops != {lock.prefix}:
                raise ContractError("archive must contain exactly one top-level prefix")

            for member in infos:
                rel = member.name + "/" if member.isdir() and not member.name.endswith("/") else member.name
                target = stage / rel
                if member.isdir():
                    target.mkdir(parents=True, exist_ok=True)
                    continue
                parent = target.parent
                parent.mkdir(parents=True, exist_ok=True)
                stage_resolved = stage.resolve()
                if stage_resolved not in parent.resolve().parents and parent.resolve() != stage_resolved:
                    raise ContractError("archive member escapes staging root")
                source = tar.extractfile(member)
                if source is None:
                    raise ContractError(f"cannot read archive member: {rel}")
                with source, target.open("xb") as output:
                    shutil.copyfileobj(source, output)

        for record in records:
            path = stage / lock.prefix / record.path
            if not path.is_file():
                raise ContractError(f"manifest member missing: {record.path}")
            actual = hashlib.sha256(path.read_bytes()).hexdigest()
            if actual != record.sha256:
                raise ContractError(f"manifest member hash mismatch: {record.path}")
        staged_prefix = stage / lock.prefix
        if final_root.exists():
            raise ContractError(f"destination appeared during verification: {final_root}")
        staged_prefix.rename(final_root)
        return final_root.resolve()
    except Exception as exc:
        shutil.rmtree(stage, ignore_errors=True)
        if isinstance(exc, (UnicodeError, tarfile.TarError)):
            raise ContractError(f"invalid tar archive metadata: {exc}") from exc
        raise
    finally:
        if stage.exists():
            shutil.rmtree(stage, ignore_errors=True)


def main(argv: list[str] | None = None) -> int:
    """功能：解析命令行参数并打印唯一已验证根目录。
输入输出及副作用：输入 archive/lock/manifest/extract-dir，成功时 stdout 仅一行路径。
失败边界：参数缺失或 ContractError 输出 stderr 并返回非零。"""
    parser = argparse.ArgumentParser()
    parser.add_argument("--archive", required=True, type=Path)
    parser.add_argument("--lock", required=True, type=Path)
    parser.add_argument("--source-manifest", required=True, type=Path)
    parser.add_argument("--extract-dir", required=True, type=Path)
    parser.add_argument("--print-kernel-root", action="store_true")
    args = parser.parse_args(argv)
    try:
        root = verify_archive(args.archive, args.lock, args.source_manifest, args.extract_dir)
    except (ContractError, OSError, tarfile.TarError) as exc:
        print(f"RDMA archive verification failed: {exc}", file=sys.stderr)
        return 1
    if args.print_kernel_root:
        print(root)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
