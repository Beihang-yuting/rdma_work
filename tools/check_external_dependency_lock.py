#!/usr/bin/env python3
"""
目录：tools，外部仿真依赖锁检查与候选捕获工具。
职责：解析 external_dependencies.tsv，解析 SystemVerilog include 闭包并校验 Git/快照身份。
依赖与所有权：仅读取外部 root；候选文件由调用者指定，工具不拥有外部源码生命周期。
"""
from __future__ import annotations

import argparse
import csv
import hashlib
import os
import re
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path

SCHEMA = ("dependency", "approval", "root_env", "git_commit", "snapshot_tree_sha256", "include_dirs", "input_kind", "relative_path", "sha256")
HEX40 = re.compile(r"^[0-9a-f]{40}$")
HEX64 = re.compile(r"^[0-9a-f]{64}$")
INCLUDE_RE = re.compile(r"`include\s+[\"<]([^\">]+)[\">]")
ALLOW_UNRESOLVED = {"uvm_macros.svh"}


@dataclass(frozen=True)
class Row:
    dependency: str
    approval: str
    root_env: str
    git_commit: str
    tree: str
    include_dirs: tuple[str, ...]
    input_kind: str
    relative_path: str
    sha256: str


def fail(message: str) -> "NoReturn":
    """功能：以稳定文本终止命令，供 CLI 和测试断言共享失败语义。\n输入输出及副作用：输入 message 写入 stderr；不返回并以状态码 1 退出。\n失败边界：调用者若需要继续处理必须捕获 SystemExit；空消息仍会产生换行。"""
    print(message, file=sys.stderr)
    raise SystemExit(1)


def safe_relative(path: str) -> bool:
    """功能：判断锁中的相对路径是否是规范、可在 root 内解析的 POSIX 路径。\n输入输出及副作用：输入字符串 path；返回布尔值，不访问文件系统。\n失败边界：绝对路径、空段、`.`、`..`、反斜杠和空字符串均拒绝。"""
    if not path or "\\" in path or path.startswith("/"):
        return False
    parts = path.split("/")
    return all(part not in ("", ".", "..") for part in parts)


def parse_lock(path: Path) -> list[Row]:
    """功能：读取并严格验证外部依赖 TSV 的列、组元数据及哈希格式。\n输入输出及副作用：输入 lock 路径；返回按文件顺序保留的 Row 列表，不修改文件。\n失败边界：缺列、重复键、混合元数据、无 DIRECT、非法审批/路径/哈希都会抛出 ValueError。"""
    with path.open("r", encoding="utf-8", newline="") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        if tuple(reader.fieldnames or ()) != SCHEMA:
            raise ValueError("invalid lock columns")
        rows: list[Row] = []
        seen: set[tuple[str, str]] = set()
        for record in reader:
            if any(value is None for value in record.values()):
                raise ValueError("invalid lock row")
            dep = record["dependency"]
            key = (dep, record["relative_path"])
            if key in seen:
                raise ValueError("duplicate dependency path")
            seen.add(key)
            approval = record["approval"]
            kind = record["input_kind"]
            if approval not in {"APPROVED", "UNAPPROVED"} or kind not in {"DIRECT", "INCLUDE"}:
                raise ValueError("invalid approval or input kind")
            rel = record["relative_path"]
            if not safe_relative(rel):
                raise ValueError("invalid relative path")
            dirs = tuple(record["include_dirs"].split(";")) if record["include_dirs"] else tuple()
            if any(not safe_relative(d) for d in dirs):
                raise ValueError("invalid include directory")
            if approval == "APPROVED":
                if not HEX40.fullmatch(record["git_commit"]) or not HEX64.fullmatch(record["snapshot_tree_sha256"]) or not HEX64.fullmatch(record["sha256"]):
                    raise ValueError("invalid approved identity")
            else:
                identities_are_seed = record["git_commit"] == record["snapshot_tree_sha256"] == record["sha256"] == "-"
                identities_are_candidate = HEX40.fullmatch(record["git_commit"]) and HEX64.fullmatch(record["snapshot_tree_sha256"]) and HEX64.fullmatch(record["sha256"])
                if not (identities_are_seed or identities_are_candidate):
                    raise ValueError("invalid unapproved identity")
            rows.append(Row(dep, approval, record["root_env"], record["git_commit"], record["snapshot_tree_sha256"], dirs, kind, rel, record["sha256"].lower()))
    groups: dict[str, list[Row]] = {}
    for row in rows:
        groups.setdefault(row.dependency, []).append(row)
    for dep, group in groups.items():
        metadata = {(r.approval, r.root_env, r.git_commit, r.tree, r.include_dirs) for r in group}
        if len(metadata) != 1 or not any(r.input_kind == "DIRECT" for r in group):
            raise ValueError(f"inconsistent dependency metadata: {dep}")
    return rows


def _root_path(root: str) -> Path:
    """功能：解析并验证外部 root 为真实目录且路径组件不含符号链接。\n输入输出及副作用：输入 root 字符串；返回绝对 Path，不创建或修改资源。\n失败边界：不存在、非目录、组件符号链接或特殊根对象均抛出 ValueError。"""
    candidate = Path(root)
    if not candidate.is_absolute():
        raise ValueError("root must be absolute")
    current = Path(candidate.anchor)
    for part in candidate.parts[1:]:
        current /= part
        info = os.lstat(current)
        if stat.S_ISLNK(info.st_mode):
            raise ValueError("root contains symlink")
    info = os.lstat(candidate)
    if not stat.S_ISDIR(info.st_mode):
        raise ValueError("root is not a directory")
    return candidate


def _resolve(root: Path, rel: str) -> Path:
    """功能：在 root 下安全解析一个锁相对路径，阻止符号链接和 root 外逃逸。\n输入输出及副作用：输入 root 与 rel；返回常规文件 Path，不写入文件。\n失败边界：缺失、组件符号链接、特殊文件或 realpath 越界均抛出 ValueError。"""
    if not safe_relative(rel):
        raise ValueError("invalid relative path")
    current = root
    parts = rel.split("/")
    for index, part in enumerate(parts):
        current = current / part
        info = os.lstat(current)
        if stat.S_ISLNK(info.st_mode):
            raise ValueError(f"symlink path: {rel}")
        if index == len(parts) - 1 and not stat.S_ISREG(info.st_mode):
            raise ValueError(f"special or missing path: {rel}")
    real = current.resolve()
    if os.path.commonpath((str(root.resolve()), str(real))) != str(root.resolve()):
        raise ValueError(f"path escapes root: {rel}")
    return current


def _hash(path: Path) -> str:
    """功能：计算单个依赖源码文件的 SHA-256。\n输入输出及副作用：输入常规文件 path；返回小写十六进制摘要，仅执行只读 I/O。\n失败边界：文件不可读或在读取期间消失时传播 OSError。"""
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _includes(path: Path) -> list[str]:
    """功能：提取 SystemVerilog 文件中的反引号 include 名称。\n输入输出及副作用：输入源码 path；返回按出现顺序的 include 名称列表，不修改源码。\n失败边界：无法解码时按替换字符读取，未知语法不会误报为 include。"""
    text = path.read_text(encoding="utf-8", errors="replace")
    return INCLUDE_RE.findall(text)


def closure(root: Path, direct: list[str], include_dirs: tuple[str, ...]) -> list[str]:
    """功能：从直接种子递归解析 include 闭包并返回规范相对路径集合。\n输入输出及副作用：输入 root、direct 相对路径和有序 include_dirs；返回 UTF-8 字节排序的路径列表。\n失败边界：未解析 include（uvm_macros.svh 除外）、越界、符号链接和循环引用均触发 ValueError。"""
    queue = list(direct)
    found: set[str] = set()
    dirs = [root / item for item in include_dirs]
    while queue:
        rel = queue.pop(0)
        if rel in found:
            continue
        path = _resolve(root, rel)
        found.add(rel)
        for name in _includes(path):
            candidates: list[Path] = []
            local = path.parent / name
            if local.exists():
                candidates.append(local)
            for directory in dirs:
                candidate = directory / name
                if candidate.exists() and candidate not in candidates:
                    candidates.append(candidate)
            if not candidates:
                if name in ALLOW_UNRESOLVED:
                    continue
                raise ValueError(f"unresolved include: {name}")
            selected = candidates[0].resolve()
            if os.path.commonpath((str(root.resolve()), str(selected))) != str(root.resolve()):
                raise ValueError(f"include escapes root: {name}")
            rel_name = os.path.relpath(selected, root).replace(os.sep, "/")
            queue.append(rel_name)
    return sorted(found, key=lambda item: item.encode("utf-8"))


def _git(root: Path, *args: str) -> str:
    """功能：在外部 root 执行 Git 查询并返回去除尾换行的输出。\n输入输出及副作用：输入 root 和 git 参数；返回 stdout 文本，不改变索引或工作树。\n失败边界：非 Git 目录或命令失败时传播 CalledProcessError。"""
    return subprocess.check_output(["git", "-C", str(root), *args], text=True).strip()


def tree_digest(root: Path, paths: list[str]) -> str:
    """功能：按规范路径和文件摘要计算锁要求的 canonical tree digest。\n输入输出及副作用：输入 root 与路径集合；返回 SHA-256 十六进制摘要，只读取文件。\n失败边界：任一文件无法读取时传播底层 I/O 错误。"""
    digest = hashlib.sha256()
    for rel in sorted(paths, key=lambda item: item.encode("utf-8")):
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(_hash(_resolve(root, rel)).encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


def verify(rows: list[Row], dependency: str, root_text: str) -> None:
    """功能：校验指定依赖的批准状态、闭包、文件摘要及 Git/快照身份。\n输入输出及副作用：输入解析后的 rows、依赖名和绝对 root；成功无返回且只读，失败抛出 ValueError。\n失败边界：UNAPPROVED 先于 root 检查拒绝；身份、清洁度、闭包和哈希任何不符均 fail closed。"""
    group = [r for r in rows if r.dependency == dependency]
    if not group:
        raise ValueError(f"unknown dependency: {dependency}")
    if group[0].approval != "APPROVED":
        raise ValueError(f"external dependency is not approved: {dependency}")
    root = _root_path(root_text)
    direct = [r.relative_path for r in group if r.input_kind == "DIRECT"]
    actual = closure(root, direct, group[0].include_dirs)
    expected = sorted((r.relative_path for r in group), key=lambda item: item.encode("utf-8"))
    if actual != expected:
        raise ValueError("dependency closure set drift")
    for row in group:
        if _hash(_resolve(root, row.relative_path)) != row.sha256:
            raise ValueError(f"hash drift: {row.relative_path}")
    try:
        head = _git(root, "rev-parse", "HEAD")
    except subprocess.CalledProcessError:
        head = None
    if head is not None:
        if head != group[0].git_commit:
            raise ValueError("git HEAD drift")
        if _git(root, "status", "--porcelain", "--untracked-files=all"):
            raise ValueError("git worktree is not clean")
        for rel in actual:
            try:
                _git(root, "ls-files", "--error-unmatch", rel)
            except subprocess.CalledProcessError as exc:
                raise ValueError(f"untracked consumed file: {rel}") from exc
        for include_dir in group[0].include_dirs:
            ignored = _git(root, "ls-files", "--others", "--ignored", "--exclude-standard", "--", include_dir)
            if ignored:
                raise ValueError("untracked or ignored include shadow")
    else:
        if group[0].git_commit != "-" or tree_digest(root, actual) != group[0].tree:
            raise ValueError("snapshot identity drift")


def capture(rows: list[Row], dependency: str, root_text: str, candidate_text: str) -> None:
    """功能：捕获直接种子及递归闭包为 0600 原子候选 TSV，保留锁中的 UNAPPROVED 状态。\n输入输出及副作用：输入锁 rows、依赖、root、候选路径；写入候选文件并 fsync，不修改锁及源码。\n失败边界：候选必须位于 /tmp 且无符号链接；Git checkout 的 HEAD/闭包可捕获但绝不自动批准。"""
    group = [r for r in rows if r.dependency == dependency]
    if not group:
        raise ValueError(f"unknown dependency: {dependency}")
    root = _root_path(root_text)
    candidate = Path(candidate_text)
    if not candidate.is_absolute() or os.path.commonpath(("/tmp", str(candidate.parent.resolve()))) != "/tmp":
        raise ValueError("candidate must be below /tmp")
    parent = candidate.parent
    while parent != Path("/") and parent != Path("/tmp"):
        if parent.exists() and parent.is_symlink():
            raise ValueError("candidate parent is symlink")
        parent = parent.parent
    if candidate.exists() and candidate.is_symlink():
        raise ValueError("candidate is symlink")
    direct = [r.relative_path for r in group if r.input_kind == "DIRECT"]
    paths = closure(root, direct, group[0].include_dirs)
    try:
        commit = _git(root, "rev-parse", "HEAD")
    except subprocess.CalledProcessError:
        commit = "-"
    digest = tree_digest(root, paths)
    approval = group[0].approval
    lines = ["\t".join(SCHEMA)]
    kinds = {r.relative_path: r.input_kind for r in group}
    for rel in paths:
        kind = kinds.get(rel, "INCLUDE")
        lines.append("\t".join((dependency, approval, group[0].root_env, commit, digest, ";".join(group[0].include_dirs), kind, rel, _hash(_resolve(root, rel)))))
    payload = ("\n".join(lines) + "\n").encode()
    candidate.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{candidate.name}.", dir=str(candidate.parent))
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, candidate)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def main(argv: list[str] | None = None) -> int:
    """功能：解析 verify/capture 命令行并调用对应锁操作。\n输入输出及副作用：输入 argv 或进程参数；成功返回 0，失败输出稳定错误并返回 1/2。\n失败边界：参数缺失、TSV 或检查失败均不写入锁并以非零状态结束。"""
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="mode", required=True)
    for mode in ("verify", "capture"):
        command = sub.add_parser(mode)
        command.add_argument("--lock", required=True)
        command.add_argument("--dependency", required=True)
        command.add_argument("--root", required=True)
        if mode == "capture":
            command.add_argument("--candidate", required=True)
    args = parser.parse_args(argv)
    try:
        rows = parse_lock(Path(args.lock))
        if args.mode == "verify":
            verify(rows, args.dependency, args.root)
        else:
            capture(rows, args.dependency, args.root, args.candidate)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(str(exc), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
