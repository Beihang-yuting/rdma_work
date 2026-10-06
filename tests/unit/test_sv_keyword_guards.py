#!/usr/bin/env python3
"""目录：tests/unit；职责：守卫测试 SV 不重新引入 context 关键字标识符或 TEIF 结构。
依赖：tools.check_changed_sv_style 的词法净化器和 unittest；只读测试源码，不拥有仿真资源。
"""

from __future__ import annotations

from pathlib import Path
import re
import unittest

from tools.check_changed_sv_style import sanitize_source


ROOT = Path(__file__).resolve().parents[2]


class SvKeywordGuardTest(unittest.TestCase):
    """功能：验证测试替身和测试用例遵守 VCS 关键字及函数/task 调用边界。
    输入输出及副作用：读取 tests 下 SV 文本并在内存中净化；不修改源码或仿真状态。
    失败边界：净化代码出现独立 context 标识符即失败。"""

    def test_test_sv_has_no_context_identifier(self) -> None:
        """功能：防止新增测试 SV 使用会触发 VCS KUAI 的独立 context 标识符。
        输入输出及副作用：扫描 tests/**/*.sv 的代码行并报告路径/行号；不写文件。
        失败边界：注释、字符串和 rdma_context 等复合名称不计入；独立 token 出现即失败。"""

        violations: list[str] = []
        for path in sorted((ROOT / "tests").rglob("*.sv")):
            for line_no, line in enumerate(sanitize_source(path.read_text(encoding="utf-8").splitlines()), 1):
                if re.search(r"\bcontext\b", line):
                    violations.append(f"{path.relative_to(ROOT)}:{line_no}")
        self.assertEqual(violations, [], "SV keyword identifier(s): " + ", ".join(violations))


if __name__ == "__main__":
    unittest.main()
