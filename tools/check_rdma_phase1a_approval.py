#!/usr/bin/env python3
"""tools 层：fail-closed 校验 Phase 1A 设计批准 artifact。

本模块只读取 approval、计划文件和 Git 证据，不拥有或修改任何仓库资源；Git 调用通过
参数数组和可注入 runner 完成，以便测试复现字节、祖先关系及 staged 边界。
"""

from __future__ import annotations

import argparse
import dataclasses
import datetime
import hashlib
import re
import subprocess
import sys
from pathlib import Path
from typing import Callable, NoReturn, Sequence


ARTIFACT_PATH = "docs/superpowers/approvals/2026-09-11-rdma-cmq-contract-foundation-phase1a.env"
PLAN_PATH = "docs/superpowers/plans/2026-09-11-rdma-cmq-contract-foundation.md"
BASE_COMMIT = "cc07586"
EXPECTED_KEYS = (
    "APPROVAL_SCHEMA",
    "PLAN_PATH",
    "PLAN_COMMIT",
    "PLAN_BLOB_SHA256",
    "APPROVER_ID",
    "APPROVED_AT_UTC",
    "TASK8_FOUR_STATE_EFFECT",
    "TASK9_EXECUTION_AND_DIGEST",
    "TASK17_RESET_ORDER",
    "TASK18_LEGACY_SEAM",
)
_DECISION_KEYS = EXPECTED_KEYS[6:]
_COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
_SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
_APPROVER_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._@-]{0,63}$")
_TIMESTAMP_RE = re.compile(r"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")


class ApprovalError(ValueError):
    """表示 approval 字节、字段或 Git 绑定证据不满足 fail-closed 契约。"""


class _FailClosedArgumentParser(argparse.ArgumentParser):
    """将 argparse 的 usage/error 退出收束到 checker 的单行失败诊断。"""

    def error(self, message: str) -> NoReturn:
        """功能：把未知选项、位置参数和其他 CLI grammar 错误转换为 ApprovalError。

        输入输出及副作用：输入 argparse 生成的 message，不打印 usage，始终抛出异常交给 main 输出。
        失败边界：仅处理无效命令行；正常解析及 `--help` 的成功退出仍沿用 argparse 行为。
        """
        raise ApprovalError(f"invalid command line: {message}")


@dataclasses.dataclass(frozen=True)
class Phase1AApproval:
    """不可变的十键 Phase 1A 批准记录，字段顺序与 artifact grammar 一致。"""

    schema: str
    plan_path: str
    plan_commit: str
    plan_blob_sha256: str
    approver_id: str
    approved_at_utc: str
    task8_four_state_effect: str
    task9_execution_and_digest: str
    task17_reset_order: str
    task18_legacy_seam: str

    @property
    def approval_schema(self) -> str:
        """功能：以 artifact 字段名提供 schema 只读别名，便于调用方按 key 访问冻结值。

        输入输出及副作用：无输入副作用，返回 schema 字符串；不会复制或修改 dataclass。
        失败边界：对象始终由 frozen dataclass 构造，别名不存在可变写入口。
        """
        return self.schema


def parse_approval(raw: bytes) -> Phase1AApproval:
    """功能：将 approval 原始字节解析为严格十键、不可变 Phase1AApproval。

    输入输出及副作用：输入为 artifact 原始 bytes，输出冻结 dataclass；不读写文件或 Git。
    失败边界：拒绝 BOM、非 UTF-8、CRLF、缺失/重复/重排 key、空注释行、空格、非法字段值及非 APPROVED 决策。
    """
    if raw.startswith(b"\xef\xbb\xbf"):
        raise ApprovalError("UTF-8 BOM is not allowed")
    if b"\r" in raw:
        raise ApprovalError("CRLF is not allowed")
    if not raw.endswith(b"\n"):
        raise ApprovalError("approval must end with one terminal LF")
    try:
        text = raw.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ApprovalError("approval is not valid UTF-8") from exc
    body = text[:-1]
    if not body or body.endswith("\n"):
        raise ApprovalError("blank approval line is not allowed")
    lines = body.split("\n")
    if len(lines) != len(EXPECTED_KEYS):
        raise ApprovalError("approval must contain exactly ten lines")
    values: dict[str, str] = {}
    for index, line in enumerate(lines):
        if not line or line.startswith("#"):
            raise ApprovalError("blank/comment approval line is not allowed")
        if line.count("=") != 1:
            raise ApprovalError("approval lines must contain exactly one '='")
        key, value = line.split("=", 1)
        if not key or not value or key != EXPECTED_KEYS[index] or key in values:
            raise ApprovalError("approval keys are unknown, missing, duplicated, or reordered")
        if key.strip() != key or value.strip() != value:
            raise ApprovalError("approval key/value whitespace is not allowed")
        values[key] = value
    if values["APPROVAL_SCHEMA"] != "1":
        raise ApprovalError("APPROVAL_SCHEMA must be exactly 1")
    if values["PLAN_PATH"] != PLAN_PATH:
        raise ApprovalError("PLAN_PATH does not match the frozen plan")
    if not _COMMIT_RE.fullmatch(values["PLAN_COMMIT"]):
        raise ApprovalError("PLAN_COMMIT must be 40 lowercase hex characters")
    if not _SHA256_RE.fullmatch(values["PLAN_BLOB_SHA256"]):
        raise ApprovalError("PLAN_BLOB_SHA256 must be 64 lowercase hex characters")
    if not _APPROVER_RE.fullmatch(values["APPROVER_ID"]):
        raise ApprovalError("APPROVER_ID has invalid grammar")
    timestamp = values["APPROVED_AT_UTC"]
    if not _TIMESTAMP_RE.fullmatch(timestamp):
        raise ApprovalError("APPROVED_AT_UTC has invalid UTC grammar")
    try:
        datetime.datetime.strptime(timestamp, "%Y-%m-%dT%H:%M:%SZ")
    except ValueError as exc:
        raise ApprovalError("APPROVED_AT_UTC is not a valid UTC instant") from exc
    for key in _DECISION_KEYS:
        if values[key] != "APPROVED":
            raise ApprovalError(f"{key} must be exactly APPROVED")
    return Phase1AApproval(
        schema=values["APPROVAL_SCHEMA"],
        plan_path=values["PLAN_PATH"],
        plan_commit=values["PLAN_COMMIT"],
        plan_blob_sha256=values["PLAN_BLOB_SHA256"],
        approver_id=values["APPROVER_ID"],
        approved_at_utc=values["APPROVED_AT_UTC"],
        task8_four_state_effect=values["TASK8_FOUR_STATE_EFFECT"],
        task9_execution_and_digest=values["TASK9_EXECUTION_AND_DIGEST"],
        task17_reset_order=values["TASK17_RESET_ORDER"],
        task18_legacy_seam=values["TASK18_LEGACY_SEAM"],
    )


# Descriptive alias retained for callers that name the operation after the artifact.
parse_phase1a_approval = parse_approval


def _read_file_bytes(path: Path) -> bytes:
    """功能：读取已由 Git 状态检查保护的 worktree 文件原始字节。

    输入输出及副作用：输入具体 Path，输出 bytes；仅执行一次只读 open/read。
    失败边界：文件不存在、权限错误或读取异常向上层转为稳定 approval failure。
    """
    return path.read_bytes()


GitRunner = Callable[[list[str]], tuple[int, bytes, bytes]]


def _subprocess_runner(repo_root: Path, argv: list[str]) -> tuple[int, bytes, bytes]:
    """功能：以 argv 数组在指定仓库执行单条只读 Git 命令并捕获原始输出。

    输入输出及副作用：输入仓库根目录和 git 参数列表，输出 returncode/stdout/stderr；不经 shell。
    失败边界：Git 不存在或命令失败由 returncode 交给校验层处理，不自动重试或改写输出。
    """
    completed = subprocess.run(["git", *argv], cwd=repo_root, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False)
    return completed.returncode, completed.stdout, completed.stderr


def _invoke(runner: GitRunner | None, repo_root: Path, argv: list[str]) -> tuple[int, bytes, bytes]:
    """功能：统一调用注入 runner 或默认 subprocess runner，确保 Git 参数始终为数组。

    输入输出及副作用：输入 runner、仓库根目录和参数，输出三元组；注入 runner 的调用被完整记录于其自身。
    失败边界：runner 返回非三元组或非 bytes 输出时立即拒绝，避免隐式字符串解析。
    """
    result = _subprocess_runner(repo_root, argv) if runner is None else runner(argv)
    if isinstance(result, subprocess.CompletedProcess):
        result = (result.returncode, result.stdout, result.stderr)
    if not isinstance(result, tuple) or len(result) != 3:
        raise ApprovalError("Git runner must return (returncode, stdout, stderr)")
    code, stdout, stderr = result
    if not isinstance(code, int) or not isinstance(stdout, bytes) or not isinstance(stderr, bytes):
        raise ApprovalError("Git runner returned invalid result types")
    return code, stdout, stderr


def _git_ok(runner: GitRunner | None, repo_root: Path, argv: list[str], detail: str) -> bytes:
    """功能：执行要求成功的 Git 证据命令并返回未经改写的 stdout。

    输入输出及副作用：输入命令参数和失败描述，输出 raw stdout；只读调用，不修改仓库。
    失败边界：returncode 非零即抛 ApprovalError，stderr 不泄露为不稳定诊断。
    """
    code, stdout, _ = _invoke(runner, repo_root, argv)
    if code != 0:
        raise ApprovalError(detail)
    return stdout


def _line_output(raw: bytes, detail: str) -> list[str]:
    """功能：将 Git name-only/parent 输出按 LF 解码为严格行列表。

    输入输出及副作用：输入 Git raw stdout，输出去除单个 terminal LF 的 UTF-8 行；无副作用。
    失败边界：非 UTF-8、CR 或缺失 terminal LF 均拒绝，防止路径/parent 被模糊解析。
    """
    if b"\r" in raw or not raw.endswith(b"\n"):
        raise ApprovalError("Git output has invalid line termination")
    try:
        text = raw[:-1].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ApprovalError("Git output is not UTF-8") from exc
    return text.split("\n") if text else []


def _full_hex(raw: bytes, detail: str) -> str:
    """功能：校验 rev-parse 输出恰为一个完整 40 位 lowercase commit。

    输入输出及副作用：输入 raw stdout，输出 commit 字符串；不执行额外命令。
    失败边界：非 UTF-8、额外行、缩写或大写 hash 均拒绝。
    """
    lines = _line_output(raw, detail)
    if len(lines) != 1 or not _COMMIT_RE.fullmatch(lines[0]):
        raise ApprovalError(detail)
    return lines[0]


def check_approval(*, repo_root: Path | str = Path("."), staged: bool = False, runner: GitRunner | None = None) -> Phase1AApproval:
    """功能：验证默认 committed 或 --staged approval，并绑定冻结计划的完整 Git 证据。

    输入输出及副作用：输入仓库根目录、staged 模式和可注入 runner，输出 Phase1AApproval；只读 Git/文件操作。
    失败边界：artifact tracking/cleanliness、计划 tracking/cleanliness、祖先、first parent、路径、blob/current hash 或 parser 任一失败都拒绝。
    """
    root = Path(repo_root)
    artifact_path = root / ARTIFACT_PATH
    plan_path = root / PLAN_PATH
    if staged:
        names = _line_output(_git_ok(runner, root, ["diff", "--cached", "--name-only"], "staged path query failed"), "staged path query failed")
        if names != [ARTIFACT_PATH]:
            raise ApprovalError("staged index must contain only the approval artifact")
        artifact_bytes = _git_ok(runner, root, ["show", f":{ARTIFACT_PATH}"], "staged approval blob is unavailable")
    else:
        _git_ok(runner, root, ["ls-files", "--error-unmatch", "--", ARTIFACT_PATH], "approval artifact is not tracked")
        _git_ok(runner, root, ["diff", "--quiet", "--", ARTIFACT_PATH], "approval artifact worktree is dirty")
        _git_ok(runner, root, ["diff", "--cached", "--quiet", "--", ARTIFACT_PATH], "approval artifact index is dirty")
        try:
            artifact_bytes = _read_file_bytes(artifact_path)
        except OSError as exc:
            raise ApprovalError("approval artifact cannot be read") from exc

    _git_ok(runner, root, ["ls-files", "--error-unmatch", "--", PLAN_PATH], "plan is not tracked")
    _git_ok(runner, root, ["diff", "--quiet", "--", PLAN_PATH], "current plan worktree is dirty")
    _git_ok(runner, root, ["diff", "--cached", "--quiet", "--", PLAN_PATH], "current plan index is dirty")
    try:
        current_plan = _read_file_bytes(plan_path)
    except OSError as exc:
        raise ApprovalError("current plan cannot be read") from exc

    approval = parse_approval(artifact_bytes)
    resolved_commit = _full_hex(_git_ok(runner, root, ["rev-parse", "--verify", f"{approval.plan_commit}^{{commit}}"], "plan commit cannot be resolved"), "plan commit cannot be resolved")
    if resolved_commit != approval.plan_commit:
        raise ApprovalError("resolved plan commit differs from recorded commit")
    _git_ok(runner, root, ["merge-base", "--is-ancestor", approval.plan_commit, "HEAD"], "plan commit is not an ancestor of HEAD")
    baseline = _full_hex(_git_ok(runner, root, ["rev-parse", "--verify", f"{BASE_COMMIT}^{{commit}}"], "baseline commit cannot be resolved"), "baseline commit cannot be resolved")
    parent_lines = _line_output(_git_ok(runner, root, ["rev-list", "--parents", "-n", "1", approval.plan_commit], "plan commit parent cannot be resolved"), "plan commit parent cannot be resolved")
    if len(parent_lines) != 1 or len(parent_lines[0].split()) < 2 or parent_lines[0].split()[1] != baseline:
        raise ApprovalError("plan commit first parent does not match baseline")
    paths = _line_output(_git_ok(runner, root, ["diff-tree", "--no-commit-id", "--name-only", "-r", approval.plan_commit], "plan commit path evidence failed"), "plan commit path evidence failed")
    if paths != [PLAN_PATH]:
        raise ApprovalError("plan commit must change only the exact plan path")
    frozen_plan = _git_ok(runner, root, ["show", f"{approval.plan_commit}:{PLAN_PATH}"], "frozen plan blob is unavailable")
    expected_hash = hashlib.sha256(frozen_plan).hexdigest()
    if expected_hash != approval.plan_blob_sha256:
        raise ApprovalError("recorded plan blob hash does not match frozen blob")
    if hashlib.sha256(current_plan).hexdigest() != approval.plan_blob_sha256:
        raise ApprovalError("recorded plan blob hash does not match current plan")
    if current_plan != frozen_plan:
        raise ApprovalError("current plan bytes differ from frozen blob")
    return approval


def main(argv: Sequence[str] | None = None, *, repo_root: Path | str = Path("."), runner: GitRunner | None = None) -> int:
    """功能：解析 CLI 选项、运行 approval checker 并输出稳定成功/失败诊断。

    输入输出及副作用：输入可选 --staged，成功向 stdout 打印 commit/hash/approver/四项决策并返回 0；失败 stderr 一行并返回 1。
    失败边界：所有 ApprovalError、OS 错误和 runner 失败均 fail-closed，不创建或修改 artifact。
    """
    try:
        parser = _FailClosedArgumentParser(description="check CMQ Phase 1A approval")
        parser.add_argument("--staged", action="store_true", help="validate the index candidate")
        args = parser.parse_args(argv)
        approval = check_approval(repo_root=repo_root, staged=args.staged, runner=runner)
    except (ApprovalError, OSError) as exc:
        print(f"phase1a approval check failed: {exc}", file=sys.stderr)
        return 1
    print(f"PLAN_COMMIT={approval.plan_commit}")
    print(f"PLAN_BLOB_SHA256={approval.plan_blob_sha256}")
    print(f"APPROVER_ID={approval.approver_id}")
    for key in _DECISION_KEYS:
        print(f"{key}=APPROVED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
