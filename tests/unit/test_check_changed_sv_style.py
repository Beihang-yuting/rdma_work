#!/usr/bin/env python3
"""目录：tests/unit；职责：验证 changed SystemVerilog 风格门禁的 Git 绑定和诊断。
依赖：tools/check_changed_sv_style.py、Git 临时仓库和 unittest；fixture 仅在测试期间存活，
被测脚本不拥有生产源码生命周期，也不得改写输入文件。
"""

from __future__ import annotations

from pathlib import Path
import subprocess
import tempfile
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CHECKER = REPO_ROOT / "tools" / "check_changed_sv_style.py"


class ChangedSvStyleTest(unittest.TestCase):
    """功能：用真实 Git fixture 验证 checker 的变更筛选、注释和语法约束。
    输入输出及副作用：辅助方法创建临时提交并读取 CLI 结果；所有写入都限制在临时目录。
    失败边界：遗漏 brief 要求的硬错误、soft-limit 提示或 head blob 隔离均使测试失败。"""

    def git(self, root: Path, *args: str) -> subprocess.CompletedProcess[str]:
        """功能：以参数数组在 fixture 仓库执行 Git 命令并返回状态。
        输入输出及副作用：输入 root 和 argv，输出带 stdout/stderr 的完成对象；仅修改临时 Git 状态。
        失败边界：命令失败由调用者断言，空参数或非法 revision 保留 Git 原始失败信息。"""

        return subprocess.run(["git", *args], cwd=root, text=True, capture_output=True, check=False)

    def create_repo(self, source: str) -> tuple[tempfile.TemporaryDirectory[str], Path, str]:
        """功能：创建含 sample.sv 基线提交的临时仓库并返回提交哈希。
        输入输出及副作用：输入源文，输出 TemporaryDirectory、仓库路径和 base；目录退出时释放。
        失败边界：初始化、暂存或提交失败表示 fixture 无效，测试立即断言而不继续调用 checker。"""

        holder = tempfile.TemporaryDirectory()
        root = Path(holder.name)
        self.assertEqual(self.git(root, "init", "-q").returncode, 0)
        self.git(root, "config", "user.email", "style@example.invalid")
        self.git(root, "config", "user.name", "style-test")
        (root / "sample.sv").write_text(source, encoding="utf-8")
        self.assertEqual(self.git(root, "add", "sample.sv").returncode, 0)
        committed = self.git(root, "commit", "-qm", "base")
        self.assertEqual(committed.returncode, 0, committed.stderr)
        base = self.git(root, "rev-parse", "HEAD").stdout.strip()
        return holder, root, base

    def invoke(self, root: Path, base: str, *extra: str) -> subprocess.CompletedProcess[str]:
        """功能：从 fixture 根目录调用 checker 的 base/head CLI 并捕获诊断。
        输入输出及副作用：输入仓库、base 和可选参数，输出 CompletedProcess；脚本应保持文件字节不变。
        失败边界：非零返回不在 helper 中吞掉，调用者必须断言对应的稳定 stderr 文本。"""

        return subprocess.run(
            ["python3", str(CHECKER), "--base", base, *extra],
            cwd=root,
            text=True,
            capture_output=True,
            check=False,
        )

    def valid_source(self, body: str = "  value = 0;\n") -> str:
        """功能：构造含完整文件头和方法三段注释的合法 SV 基线。
        输入输出及副作用：输入可替换的方法体，返回 UTF-8 源文字符串；不创建文件或提交状态。
        失败边界：body 由测试负责保持可编译形态，函数只保证 checker 所需的最小头和注释。"""

        return (
            "// 目录：src/；层次：测试层。\n"
            "// 职责：验证样例。\n"
            "// 依赖：无。\n"
            "// 所有权与生命周期：fixture 持有，测试结束释放。\n"
            "class sample;\n"
            "  // 功能：更新样例状态。\n"
            "  // 输入/输出及副作用：写入 value 并保持对象状态。\n"
            "  // 失败/边界：输入不可用时保持原值。\n"
            "  function void update();\n"
            f"{body}"
            "  endfunction\n"
            "endclass\n"
        )

    def test_compliant_constructor_accessor_task_probe_and_test_helper(self) -> None:
        """功能：确认 constructor、accessor、task、probe 和测试辅助函数的新增行均合规。
        输入输出及副作用：向基线追加五个完整注释方法并运行 checker；只写临时 sample.sv。
        失败边界：任一方法缺邻接注释、合法 for 或返回语句被误报即失败。"""

        addition = """  // 功能：构造对象。\n  // 输入/输出及副作用：初始化对象状态。\n  // 失败/边界：资源不足时保持默认值。\n  function new();\n  endfunction\n  // 功能：读取状态。\n  // 输入/输出及副作用：返回 value，不更新对象。\n  // 失败/边界：对象失效时返回零。\n  function int get_status();\n    return value;\n  endfunction\n  // 功能：执行任务。\n  // 输入/输出及副作用：更新状态并完成 task。\n  // 失败/边界：忙时保持原状态。\n  task run_task();\n    value = value + 1;\n  endtask\n  // 功能：探测状态。\n  // 输入/输出及副作用：返回探测结果。\n  // 失败/边界：无效句柄返回零。\n  function bit probe();\n    return 1'b0;\n  endfunction\n  // 功能：构造测试辅助 fixture。\n  // 输入/输出及副作用：创建临时资源并由测试释放。\n  // 失败/边界：资源不足时返回零。\n  function bit test_helper();\n    return 1'b0;\n  endfunction\n"""
        holder, root, base = self.create_repo(self.valid_source() + "\n" + addition)
        with holder:
            (root / "sample.sv").write_text(self.valid_source() + "\n" + addition + "// changed\n", encoding="utf-8")
            result = self.invoke(root, base)
            self.assertEqual(result.returncode, 0, result.stderr)

    def test_missing_each_required_method_label_is_rejected(self) -> None:
        """功能：分别删除功能、输入输出及副作用、失败边界标签并确认硬诊断。
        输入输出及副作用：输入三份带变更方法体的源文，输出非零状态和邻接注释诊断。
        失败边界：缺失任一精确标签却返回零，或合法标签触发误报，均判失败。"""

        labels = ("功能：", "输入/输出及副作用：", "失败/边界：")
        for missing in labels:
            with self.subTest(label=missing):
                base_source = self.valid_source()
                changed = base_source.replace(missing, "删除：").replace("  value = 0;", "  value = 1;")
                holder, root, base = self.create_repo(base_source)
                with holder:
                    (root / "sample.sv").write_text(changed, encoding="utf-8")
                    result = self.invoke(root, base)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("lacks adjacent", result.stderr)

    def test_shared_comment_and_blank_line_terminate_adjacency(self) -> None:
        """功能：拒绝一个注释块服务两个方法，并把声明前空行视为邻接终止。
        输入输出及副作用：输入两个变更方法 fixture，输出非零状态和注释错误；不触碰生产源码。
        失败边界：若共享块或空行后的旧注释被接受，说明方法归属检查失效。"""

        shared = self.valid_source().replace(
            "endclass\n",
            "  // 功能：共享。\n  // 输入/输出及副作用：共享。\n  // 失败/边界：共享。\n  function void first();\n    value = 1;\n  endfunction\n  function void second();\n    value = 2;\n  endfunction\nendclass\n",
        )
        separated = self.valid_source().replace("  function void update();", "\n  function void update();").replace("  value = 0;", "  value = 1;")
        for source in (shared, separated):
            holder, root, base = self.create_repo(self.valid_source())
            with holder:
                (root / "sample.sv").write_text(source, encoding="utf-8")
                result = self.invoke(root, base)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("lacks adjacent", result.stderr)

    def test_new_file_header_requires_all_four_items(self) -> None:
        """功能：验证新增 SV 文件必须含目录层次、职责、依赖和所有权生命周期四项文件头。
        输入输出及副作用：逐项删除头部字段并运行 checker，输出 file header 硬诊断。
        失败边界：历史文件不触发此检查；新增文件漏任一字段必须非零。"""

        markers = ("目录", "职责", "依赖", "所有权与生命周期")
        for marker in markers:
            with self.subTest(marker=marker):
                holder, root, base = self.create_repo(self.valid_source())
                with holder:
                    source = "\n".join(line for line in self.valid_source().splitlines() if marker not in line) + "\n"
                    (root / "new.sv").write_text(source, encoding="utf-8")
                    result = self.invoke(root, base)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn("file header", result.stderr)

    def test_changed_line_checks_and_ignored_inputs(self) -> None:
        """功能：检查尾随空白、百列软限制、多语句和单行 if-return，同时忽略 Python/旧长行。
        输入输出及副作用：依次修改临时 SV 并调用 checker，输出稳定硬/soft-limit 诊断。
        失败边界：for 头两分号及注释/字符串分号合法；未变更历史长行和 .py 永不诊断。"""

        variants = (
            ("  value = 1; value = 2;\n", "multiple statements"),
            ("  if (value) return value;\n", "single-line if return"),
            ("  value = 1;\t\n", "trailing whitespace"),
            ("  // " + "x" * 110 + "\n", "soft-limit"),
        )
        for body, expected in variants:
            with self.subTest(expected=expected):
                holder, root, base = self.create_repo(self.valid_source())
                with holder:
                    (root / "sample.sv").write_text(self.valid_source(body), encoding="utf-8")
                    (root / "ignored.py").write_text("x = 1; y = 2\n", encoding="utf-8")
                    result = self.invoke(root, base)
                    self.assertIn(expected, result.stderr)
                    if expected == "soft-limit":
                        self.assertEqual(result.returncode, 0)
                    else:
                        self.assertNotEqual(result.returncode, 0)

        base_source = self.valid_source() + "// historical long line " + "x" * 110 + "\n"
        holder, root, base = self.create_repo(base_source)
        with holder:
            (root / "sample.sv").write_text(base_source.replace("  value = 0;", "  value = 1;"), encoding="utf-8")
            result = self.invoke(root, base)
            self.assertNotIn("soft-limit", result.stderr)

    def test_for_case_rules(self) -> None:
        """功能：确认 for 合法例外、case default 和多语句分支约束按变更范围执行。
        输入输出及副作用：写入包含 for、字符串/注释分号及 case 变体的 fixture，读取硬诊断。
        失败边界：有 default 且 begin/end 的 case 通过；缺 default 或裸多语句分支必须拒绝。"""

        legal = self.valid_source("""  int i;\n  for (i = 0; i < 2; i++) begin\n    value = i;\n  end\n  // ;\n  value = \";\";\n""")
        holder, root, base = self.create_repo(self.valid_source())
        with holder:
            (root / "sample.sv").write_text(legal, encoding="utf-8")
            self.assertEqual(self.invoke(root, base).returncode, 0)
        for body, message in (
            ("  case (value)\n    1: value = 1;\n  endcase\n", "changed case lacks explicit default"),
            ("  case (value)\n    1: value = 1;\n       value = 2;\n    default: value = 0;\n  endcase\n", "multi-statement case branch requires begin/end"),
        ):
            holder, root, base = self.create_repo(self.valid_source())
            with holder:
                (root / "sample.sv").write_text(self.valid_source(body), encoding="utf-8")
                result = self.invoke(root, base)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(message, result.stderr)

    def test_untracked_invalid_base_and_head_reads_committed_blob(self) -> None:
        """功能：覆盖未跟踪 SV、无效 base，以及 --head 不读取当前工作树的提交 blob 契约。
        输入输出及副作用：创建两个提交后污染工作树，输出对应失败/成功状态；临时目录独立清理。
        失败边界：未跟踪文件必须检查，无效 revision 必须非零，head 模式不得看到工作树污染。"""

        holder, root, base = self.create_repo(self.valid_source())
        with holder:
            (root / "new.sv").write_text("function void f();\nendfunction\n", encoding="utf-8")
            result = self.invoke(root, base)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("file header", result.stderr)
            invalid = self.invoke(root, "does-not-exist")
            self.assertNotEqual(invalid.returncode, 0)
            self.assertIn("base", invalid.stderr)

            changed = self.valid_source("  value = 1;\n")
            (root / "sample.sv").write_text(changed, encoding="utf-8")
            self.git(root, "add", "sample.sv")
            self.assertEqual(self.git(root, "commit", "-qm", "changed").returncode, 0)
            head = self.git(root, "rev-parse", "HEAD").stdout.strip()
            (root / "sample.sv").write_text("// invalid current worktree\n", encoding="utf-8")
            from_head = self.invoke(root, base, "--head", head)
            self.assertEqual(from_head.returncode, 0, from_head.stderr)


if __name__ == "__main__":
    unittest.main()
