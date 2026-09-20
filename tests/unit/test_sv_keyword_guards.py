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
    失败边界：净化代码出现独立 context 标识符，或 release_one 退回 task，均立即失败。"""

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

    def test_mock_release_one_is_function(self) -> None:
        """功能：固定 mock gate 释放 API 为 function，避免 function→task 的 VCS TEIF 告警。
        输入输出及副作用：读取 rdma_mock_control_plane.sv 的声明并断言唯一 function 形态。
        失败边界：若 release_one 声明为 task 或出现重复声明，测试失败并提示 TEIF 根因。"""

        path = ROOT / "tests/mocks/rdma_mock_control_plane.sv"
        source = path.read_text(encoding="utf-8")
        self.assertEqual(len(re.findall(r"\bfunction\s+void\s+release_one\s*\(", source)), 1)
        self.assertNotRegex(source, r"\btask\s+release_one\s*\(")

    def test_aeqe_primary_route_miss_is_explicitly_initialized(self) -> None:
        """功能：固定 AEQE route resolver 在查询前显式清零 primary_miss。
        输入输出及副作用：读取 queue-data engine 源文并检查局部变量声明；不运行仿真或修改文件。
        失败边界：缺少显式 0 初始化时立即失败，避免后续把 2-state 默认值误当作设计契约。"""

        path = ROOT / "src/core/rdma_queue_data_engine.sv"
        source = path.read_text(encoding="utf-8")
        resolver = re.search(
            r"protected\s+function\s+rdma_status\s+resolve_aeqe_routes\b.*?\n\s*endfunction",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(resolver, "resolve_aeqe_routes definition is missing")
        self.assertRegex(
            resolver.group(0),
            r"\bbit\s+primary_miss\s*=\s*1'b0\s*;",
            "AEQE primary_miss must be explicitly initialized before route lookup",
        )


if __name__ == "__main__":
    unittest.main()
