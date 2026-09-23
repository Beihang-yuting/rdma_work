"""tests/unit：Phase 1A approval checker 的 parser、Git 证据和 CLI 契约测试。

本文件只构造内存字节和只读 Git runner，不创建真实 approval artifact；fixture 的
所有权由测试方法持有，runner 生命周期限于单次断言。
"""

from __future__ import annotations

import contextlib
import io
import tempfile
import unittest
from pathlib import Path

from tools import check_rdma_phase1a_approval as checker


PLAN_PATH = checker.PLAN_PATH
ARTIFACT_PATH = checker.ARTIFACT_PATH
COMMIT = "1" * 40
BASE = "2" * 40
PLAN_BYTES = b"plan bytes\n"
APPROVAL_VALUES = {
    "APPROVAL_SCHEMA": "1",
    "PLAN_PATH": PLAN_PATH,
    "PLAN_COMMIT": COMMIT,
    "PLAN_BLOB_SHA256": checker.hashlib.sha256(PLAN_BYTES).hexdigest(),
    "APPROVER_ID": "owner@example.com",
    "APPROVED_AT_UTC": "2026-09-12T10:20:30Z",
    "TASK8_FOUR_STATE_EFFECT": "APPROVED",
    "TASK9_EXECUTION_AND_DIGEST": "APPROVED",
    "TASK17_RESET_ORDER": "APPROVED",
    "TASK18_LEGACY_SEAM": "APPROVED",
}


def approval_bytes(values: dict[str, str] | None = None, *, terminal_lf: bool = True) -> bytes:
    """功能：按十键顺序构造 approval fixture，供 parser 和 Git 绑定测试复用。

    输入输出及副作用：输入可选的 key-value 覆盖，输出 UTF-8 原始字节，不触碰文件系统。
    失败边界：未知 key 仅在被调用方解析时暴露；terminal_lf=False 用于验证缺失终止换行。
    """
    selected = dict(APPROVAL_VALUES)
    selected.update(values or {})
    payload = "\n".join(f"{key}={selected[key]}" for key in checker.EXPECTED_KEYS)
    return (payload + ("\n" if terminal_lf else "")).encode("utf-8")


class FakeGit:
    """为 checker 提供可审计的 argv→结果映射，拒绝任何非预置命令。"""

    def __init__(self, responses: dict[tuple[str, ...], tuple[int, bytes, bytes]]):
        """功能：接管一组预置 Git 响应，形成单测试调用范围内的只读 runner。

        输入输出及副作用：输入 argv 到结果的映射，初始化 responses 和空 calls；不执行外部命令。
        失败边界：映射缺少命令时由 __call__ 返回 127，明确暴露未声明的 Git 证据需求。
        """
        self.responses = responses
        self.calls: list[tuple[str, ...]] = []

    def __call__(self, argv: list[str]) -> tuple[int, bytes, bytes]:
        """功能：记录并返回预置 Git 命令结果，模拟只读命令 runner。

        输入输出及副作用：输入为不含 git 前缀的参数数组，输出 returncode/stdout/stderr 三元组；副作用是追加 calls。
        失败边界：未预置的命令返回 127，确保测试不会默默调用真实 Git。
        """
        key = tuple(argv)
        self.calls.append(key)
        return self.responses.get(key, (127, b"", b"unexpected command"))


class CheckerTests(unittest.TestCase):
    """覆盖 parser 精确语法及默认/staged Git 绑定的拒绝路径。"""

    def _responses(self, *, artifact: bytes | None = None, plan: bytes = PLAN_BYTES) -> dict[tuple[str, ...], tuple[int, bytes, bytes]]:
        """功能：建立一个通过所有正常 Git 证据检查的可注入响应表。

        输入输出及副作用：输入 approval/plan 字节，输出 FakeGit 响应映射；不执行 Git。
        失败边界：调用方覆盖某条响应即可注入缺失、dirty、非祖先或 hash 漂移故障。
        """
        artifact = artifact if artifact is not None else approval_bytes()
        return {
            ("ls-files", "--error-unmatch", "--", ARTIFACT_PATH): (0, (ARTIFACT_PATH + "\n").encode(), b""),
            ("ls-files", "--error-unmatch", "--", PLAN_PATH): (0, (PLAN_PATH + "\n").encode(), b""),
            ("diff", "--quiet", "--", ARTIFACT_PATH): (0, b"", b""),
            ("diff", "--cached", "--quiet", "--", ARTIFACT_PATH): (0, b"", b""),
            ("diff", "--quiet", "--", PLAN_PATH): (0, b"", b""),
            ("diff", "--cached", "--quiet", "--", PLAN_PATH): (0, b"", b""),
            ("rev-parse", "--verify", f"{COMMIT}^{{commit}}"): (0, (COMMIT + "\n").encode(), b""),
            ("merge-base", "--is-ancestor", COMMIT, "HEAD"): (0, b"", b""),
            ("rev-parse", "--verify", f"{checker.BASE_COMMIT}^{{commit}}"): (0, (BASE + "\n").encode(), b""),
            ("rev-list", "--parents", "-n", "1", COMMIT): (0, (COMMIT + " " + BASE + "\n").encode(), b""),
            ("diff-tree", "--no-commit-id", "--name-only", "-r", COMMIT): (0, (PLAN_PATH + "\n").encode(), b""),
            ("show", f"{COMMIT}:{PLAN_PATH}"): (0, plan, b""),
            ("show", f":{ARTIFACT_PATH}"): (0, artifact, b""),
        }

    def _parse(self, raw: bytes) -> checker.Phase1AApproval:
        """功能：调用生产 parser 并返回不可变 approval 值，集中减少测试样板。

        输入输出及副作用：输入原始 approval 字节，输出 Phase1AApproval；无外部副作用。
        失败边界：任何语法或字段值拒绝均向测试抛出 ApprovalError。
        """
        return checker.parse_approval(raw)

    @contextlib.contextmanager
    def _repo_fixture(self, *, artifact: bytes | None = None, plan: bytes = PLAN_BYTES):
        """功能：在临时仓库根下写入真实 approval/plan fixture，供生产文件读取路径使用。

        输入输出及副作用：输入两份 bytes，yield 临时 Path；上下文退出时清理临时目录。
        失败边界：目录创建或写入失败直接让测试失败，不以 mock 掩盖文件生命周期问题。
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            artifact_path = root / ARTIFACT_PATH
            plan_path = root / PLAN_PATH
            artifact_path.parent.mkdir(parents=True)
            plan_path.parent.mkdir(parents=True, exist_ok=True)
            artifact_path.write_bytes(artifact if artifact is not None else approval_bytes())
            plan_path.write_bytes(plan)
            yield root

    def test_parser_accepts_valid_fixture_and_is_immutable(self) -> None:
        """功能：确认合法十键 fixture 可解析且结果不可变。

        输入输出及副作用：解析内存 fixture 并检查字段；不写文件。
        失败边界：字段缺失或 dataclass 可变都会使契约断言失败。
        """
        parsed = self._parse(approval_bytes())
        self.assertEqual(parsed.plan_commit, COMMIT)
        with self.assertRaises((AttributeError, TypeError)):
            parsed.plan_commit = BASE  # type: ignore[misc]

    def test_parser_rejects_byte_level_forms(self) -> None:
        """功能：逐项拒绝 BOM、CRLF、缺失 terminal LF、空行和注释。

        输入输出及副作用：构造变体并断言每个变体抛错；不触碰文件系统。
        失败边界：任一非规范字节布局必须 fail-closed。
        """
        variants = [
            b"\xef\xbb\xbf" + approval_bytes(),
            approval_bytes().replace(b"\n", b"\r\n"),
            approval_bytes(terminal_lf=False),
            approval_bytes().replace(b"\n", b"\n\n", 1),
            approval_bytes().replace(b"\n", b"\n# note\n", 1),
            approval_bytes().replace(b"PLAN_PATH=", b"PLAN_PATH ="),
            approval_bytes().replace(b"PLAN_PATH=", b" PLAN_PATH="),
            b"\xff" + approval_bytes(),
        ]
        for raw in variants:
            with self.subTest(raw=raw[:24]):
                with self.assertRaises(checker.ApprovalError):
                    self._parse(raw)

    def test_parser_rejects_key_shape_and_order(self) -> None:
        """功能：拒绝未知、缺失、重复及重排 key，保持十键 exact ordered grammar。

        输入输出及副作用：修改 fixture 行序或 key 集合并断言抛错；无外部副作用。
        失败边界：任一 key 集合/顺序偏离 EXPECTED_KEYS 都不得被容忍。
        """
        lines = approval_bytes().decode().splitlines()
        variants = [
            lines[:-1],
            lines + ["UNKNOWN=x"],
            lines[:3] + [lines[2]] + lines[3:],
            [lines[1], lines[0], *lines[2:]],
        ]
        for rows in variants:
            with self.subTest(rows=rows):
                with self.assertRaises(checker.ApprovalError):
                    self._parse(("\n".join(rows) + "\n").encode())

    def test_parser_rejects_field_values(self) -> None:
        """功能：覆盖 commit/hash/approver/timestamp/path/schema/decision 的值域拒绝。

        输入输出及副作用：逐项替换一个字段并断言 parser 抛错；无文件系统副作用。
        失败边界：只有精确 lowercase hex、UTC 时间、owner ID 和 APPROVED 可通过。
        """
        bad = {
            "APPROVAL_SCHEMA": "2",
            "PLAN_PATH": "other.md",
            "PLAN_COMMIT": "A" * 40,
            "PLAN_BLOB_SHA256": "A" * 64,
            "APPROVER_ID": "bad id",
            "APPROVED_AT_UTC": "2026-99-99T10:20:30Z",
            "TASK8_FOUR_STATE_EFFECT": "REJECTED",
            "TASK9_EXECUTION_AND_DIGEST": "APPROVED ",
            "TASK17_RESET_ORDER": "REJECTED",
            "TASK18_LEGACY_SEAM": "REJECTED",
        }
        for key, value in bad.items():
            with self.subTest(key=key):
                with self.assertRaises(checker.ApprovalError):
                    self._parse(approval_bytes({key: value}))

    def test_default_mode_validates_clean_artifact_and_plan(self) -> None:
        """功能：默认模式读取 tracked worktree artifact 并通过完整 Git 绑定。

        输入输出及副作用：临时目录提供 artifact/plan 字节，返回 Phase1AApproval；不修改文件。
        失败边界：runner 未覆盖的命令会失败，防止偷偷访问真实仓库。
        """
        with self._repo_fixture() as root:
            result = checker.check_approval(repo_root=root, runner=FakeGit(self._responses()))
        self.assertEqual(result.plan_commit, COMMIT)

    def test_default_mode_rejects_artifact_tracking_and_dirty_failures(self) -> None:
        """功能：默认模式拒绝 missing/untracked/dirty artifact。

        输入输出及副作用：为 ls-files、worktree diff 或 index diff 注入失败并断言 ApprovalError。
        失败边界：任一 tracked/clean 证据失败即停止，不读取 artifact。
        """
        for command in [
            ("ls-files", "--error-unmatch", "--", ARTIFACT_PATH),
            ("diff", "--quiet", "--", ARTIFACT_PATH),
            ("diff", "--cached", "--quiet", "--", ARTIFACT_PATH),
        ]:
            responses = self._responses()
            responses[command] = (1, b"", b"dirty")
            with self.subTest(command=command), self._repo_fixture() as root:
                with self.assertRaises(checker.ApprovalError):
                    checker.check_approval(repo_root=root, runner=FakeGit(responses))

    def test_default_mode_rejects_tracked_but_physically_missing_artifact(self) -> None:
        """功能：默认模式拒绝 Git 报告 tracked 但 worktree 实体已缺失的 approval artifact。

        输入输出及副作用：从临时 fixture 删除 artifact 后运行生产文件读取，断言稳定 ApprovalError；临时目录负责清理。
        失败边界：ls-files 与两类 diff 均成功也不能掩盖 read_bytes 的文件缺失失败。
        """
        with self._repo_fixture() as root:
            (root / ARTIFACT_PATH).unlink()
            with self.assertRaises(checker.ApprovalError) as raised:
                checker.check_approval(repo_root=root, runner=FakeGit(self._responses()))
        self.assertEqual(str(raised.exception), "approval artifact cannot be read")

    def test_staged_mode_requires_only_artifact_and_reads_index_blob(self) -> None:
        """功能：staged 模式只接受 approval 单一路径并从 git show :path 读取字节。

        输入输出及副作用：注入 cached name-only 与 index blob，返回解析值；不读取 worktree artifact。
        失败边界：额外 staged path 或 index blob 缺失必须拒绝。
        """
        responses = self._responses()
        responses[("diff", "--cached", "--name-only")] = (0, (ARTIFACT_PATH + "\n").encode(), b"")
        fake = FakeGit(responses)
        with self._repo_fixture() as root:
            result = checker.check_approval(repo_root=root, staged=True, runner=fake)
        self.assertEqual(result.approver_id, "owner@example.com")
        self.assertIn(("show", f":{ARTIFACT_PATH}"), fake.calls)

    def test_staged_mode_rejects_extra_path(self) -> None:
        """功能：staged 模式拒绝包含 artifact 之外路径的 index 候选。

        输入输出及副作用：注入两个 staged 路径并断言 ApprovalError；不修改 index。
        失败边界：即使 approval 内容有效，额外路径也必须 fail-closed。
        """
        responses = self._responses()
        responses[("diff", "--cached", "--name-only")] = (0, f"{ARTIFACT_PATH}\nother\n".encode(), b"")
        with self._repo_fixture() as root:
            with self.assertRaises(checker.ApprovalError):
                checker.check_approval(repo_root=root, staged=True, runner=FakeGit(responses))

    def test_staged_mode_rejects_missing_index_artifact_blob(self) -> None:
        """功能：staged 模式拒绝唯一 staged 路径存在但 `git show :artifact` 无法读取的候选。

        输入输出及副作用：注入 staged name-only 成功和 index show 失败，断言稳定 ApprovalError；不修改真实 index。
        失败边界：worktree 中存在同名 artifact 也不得回退读取，缺失 index blob 必须 fail-closed。
        """
        responses = self._responses()
        responses[("diff", "--cached", "--name-only")] = (0, (ARTIFACT_PATH + "\n").encode(), b"")
        responses[("show", f":{ARTIFACT_PATH}")] = (1, b"", b"missing index blob")
        with self._repo_fixture() as root:
            with self.assertRaises(checker.ApprovalError) as raised:
                checker.check_approval(repo_root=root, staged=True, runner=FakeGit(responses))
        self.assertEqual(str(raised.exception), "staged approval blob is unavailable")

    def test_default_and_staged_modes_reject_untracked_or_dirty_plan(self) -> None:
        """功能：确认默认和 staged 两种入口共享 plan tracked、worktree clean、index clean 门禁。

        输入输出及副作用：逐模式注入三类 Git 失败并断言各自稳定 ApprovalError；只使用临时文件及 FakeGit。
        失败边界：plan 未跟踪、worktree dirty 或 index dirty 任一成立时，两种模式都必须停止。
        """
        failures = [
            (("ls-files", "--error-unmatch", "--", PLAN_PATH), "plan is not tracked"),
            (("diff", "--quiet", "--", PLAN_PATH), "current plan worktree is dirty"),
            (("diff", "--cached", "--quiet", "--", PLAN_PATH), "current plan index is dirty"),
        ]
        for staged in (False, True):
            for command, diagnostic in failures:
                responses = self._responses()
                if staged:
                    responses[("diff", "--cached", "--name-only")] = (0, (ARTIFACT_PATH + "\n").encode(), b"")
                responses[command] = (1, b"", b"rejected")
                with self.subTest(staged=staged, command=command), self._repo_fixture() as root:
                    with self.assertRaises(checker.ApprovalError) as raised:
                        checker.check_approval(repo_root=root, staged=staged, runner=FakeGit(responses))
                self.assertEqual(str(raised.exception), diagnostic)

    def test_cli_prints_bound_values_on_success(self) -> None:
        """功能：确认 CLI 成功时输出计划 commit、blob hash、approver 与四项 APPROVED 决策。

        输入输出及副作用：通过注入只读 runner 和临时文件捕获 stdout，返回 0；不修改仓库。
        失败边界：缺少任一成功输出或返回非零都表示 CLI 契约回归。
        """
        output = io.StringIO()
        with self._repo_fixture() as root, contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            status = checker.main([], repo_root=root, runner=FakeGit(self._responses()))
        self.assertEqual(status, 0)
        rendered = output.getvalue()
        self.assertIn(f"PLAN_COMMIT={COMMIT}", rendered)
        self.assertIn(f"PLAN_BLOB_SHA256={APPROVAL_VALUES['PLAN_BLOB_SHA256']}", rendered)
        self.assertIn("APPROVER_ID=owner@example.com", rendered)
        for key in checker.EXPECTED_KEYS[6:]:
            self.assertIn(f"{key}=APPROVED", rendered)

    def test_cli_emits_one_stable_failure_line(self) -> None:
        """功能：确认 CLI 失败时仅以一行 stderr 诊断并返回非零。

        输入输出及副作用：注入 artifact tracked 失败并捕获 stderr；不创建或修改 artifact。
        失败边界：stderr 为空、多行或返回零均违反 fail-closed CLI 契约。
        """
        responses = self._responses()
        responses[("ls-files", "--error-unmatch", "--", ARTIFACT_PATH)] = (1, b"", b"missing")
        error = io.StringIO()
        with self._repo_fixture() as root, contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(error):
            status = checker.main([], repo_root=root, runner=FakeGit(responses))
        self.assertNotEqual(status, 0)
        self.assertEqual(len(error.getvalue().splitlines()), 1)
        self.assertTrue(error.getvalue().startswith("phase1a approval check failed: "))

    def test_cli_rejects_invalid_arguments_without_argparse_exit(self) -> None:
        """功能：确认未知选项和位置参数不会触发 argparse SystemExit 或多行 usage。

        输入输出及副作用：逐个调用 main 并捕获 stdout/stderr，要求返回 1 和精确单行诊断；runner 不应被调用。
        失败边界：`--bad` 与 `unexpected` 必须各自 fail-closed，禁止 SystemExit(2) 逃逸。
        """
        cases = [
            (["--bad"], "phase1a approval check failed: invalid command line: unrecognized arguments: --bad\n"),
            (["unexpected"], "phase1a approval check failed: invalid command line: unrecognized arguments: unexpected\n"),
        ]
        for argv, diagnostic in cases:
            output = io.StringIO()
            error = io.StringIO()
            fake = FakeGit({})
            with self.subTest(argv=argv), contextlib.redirect_stdout(output), contextlib.redirect_stderr(error):
                status = checker.main(argv, runner=fake)
            self.assertEqual(status, 1)
            self.assertEqual(output.getvalue(), "")
            self.assertEqual(error.getvalue(), diagnostic)
            self.assertEqual(fake.calls, [])

    def test_git_evidence_rejects_commit_plan_and_hash_failures(self) -> None:
        """功能：覆盖 commit 缺失、非祖先、错误 parent、额外路径、计划路径和双 hash 漂移。

        输入输出及副作用：分别扰动 Git 响应/plan 字节并断言 ApprovalError；不写仓库。
        失败边界：任一 frozen blob、current plan、 ancestry 或 topology 证据不匹配即拒绝。
        """
        cases: list[tuple[str, tuple[str, ...], tuple[int, bytes, bytes]]] = [
            ("missing commit", ("rev-parse", "--verify", f"{COMMIT}^{{commit}}"), (1, b"", b"")),
            ("not ancestor", ("merge-base", "--is-ancestor", COMMIT, "HEAD"), (1, b"", b"")),
            ("wrong parent", ("rev-list", "--parents", "-n", "1", COMMIT), (0, (COMMIT + " " + "3" * 40 + "\n").encode(), b"")),
            ("extra path", ("diff-tree", "--no-commit-id", "--name-only", "-r", COMMIT), (0, (PLAN_PATH + "\nother\n").encode(), b"")),
            ("wrong plan path", ("diff-tree", "--no-commit-id", "--name-only", "-r", COMMIT), (0, b"other\n", b"")),
            ("blob drift", ("show", f"{COMMIT}:{PLAN_PATH}"), (0, b"different\n", b"")),
        ]
        for name, command, response in cases:
            responses = self._responses()
            responses[command] = response
            with self.subTest(name=name), self._repo_fixture() as root:
                with self.assertRaises(checker.ApprovalError):
                    checker.check_approval(repo_root=root, runner=FakeGit(responses))

        responses = self._responses()
        with self._repo_fixture(plan=b"current drift\n") as root:
            with self.assertRaises(checker.ApprovalError):
                checker.check_approval(repo_root=root, runner=FakeGit(responses))


if __name__ == "__main__":
    unittest.main()
