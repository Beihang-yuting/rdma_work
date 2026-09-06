"""Task 9 的静态回归矩阵与中文源码契约检查。"""

from __future__ import annotations

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
CONTRACT_FILES = (
    REPO_ROOT / "src/adapters/net_packet/rdma_net_packet_adapter_pkg.sv",
    REPO_ROOT / "src/adapters/net_packet/rdma_net_packet_bridge.sv",
    REPO_ROOT / "src/adapter/rdma_abi_v5_api.sv",
    REPO_ROOT / "tests/integration/rdma_net_packet_adapter_test.sv",
    REPO_ROOT / "tests/integration/rdma_host_mem_umem_test.sv",
    REPO_ROOT / "tests/unit/rdma_abi_v5_adapter_test.sv",
    REPO_ROOT / "tests/unit/rdma_umem_pbl_mw_test.sv",
)
FUNCTION_DECLARATION = re.compile(
    r"^\s*(?:(?:pure|virtual|protected|local|static|automatic|extern|final)\s+)*"
    r"(?:function|task)\b"
)


def _has_function_contract(lines: list[str], declaration_line: int) -> bool:
    """检查函数/task 声明前的紧邻注释是否包含三段中文契约。"""

    window = "\n".join(lines[max(0, declaration_line - 18):declaration_line])
    return all(
        marker in window
        for marker in ("// 功能：", "// 输入/输出及副作用：", "// 失败/边界：")
    )


class Task9VerificationTest(unittest.TestCase):
    """验证 Task 9 的源码契约、回归分层和可复现文档。"""

    def test_all_new_sources_have_chinese_header_and_function_contracts(self) -> None:
        """新增适配器和 UMEM 测试必须声明目录职责并覆盖每个函数/task。"""

        for path in CONTRACT_FILES:
            with self.subTest(path=path):
                text = path.read_text(encoding="utf-8")
                self.assertIn("目录：", text)
                self.assertIn("功能：", text)
                self.assertIn("失败/边界：", text)
                lines = text.splitlines()
                for line_number, line in enumerate(lines):
                    if FUNCTION_DECLARATION.match(line):
                        self.assertTrue(
                            _has_function_contract(lines, line_number),
                            f"{path}:{line_number + 1} lacks a Chinese function contract",
                        )

    def test_core_inputs_do_not_couple_external_component_names(self) -> None:
        """core filelist 和核心源码不得直接引入外部组件实现名称。"""

        forbidden = re.compile(
            r"(?:net_packet|axis_vip|pcie_work|host_mem_manager)", re.IGNORECASE
        )
        paths = [REPO_ROOT / "sim/filelists/core.f"]
        paths.extend((REPO_ROOT / "src/core").glob("*.sv"))
        violations = []
        for path in paths:
            for line_number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                if forbidden.search(line):
                    violations.append(f"{path.relative_to(REPO_ROOT)}:{line_number}:{line}")
        self.assertEqual([], violations, "core contains an external component reference")

    def test_regression_matrix_covers_all_local_and_external_suites(self) -> None:
        """回归入口必须列出新增 core、host_mem、integration 和 net_packet 测试。"""

        queue_runner = (REPO_ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        host_runner = (REPO_ROOT / "scripts/run_host_mem_regression53.sh").read_text()
        makefile = (REPO_ROOT / "sim/Makefile").read_text()
        for test_name in (
            "rdma_abi_v5_adapter_test",
            "rdma_umem_pbl_mw_test",
            "rdma_cq_shadow_flush_test",
        ):
            self.assertIn(test_name, queue_runner)
        self.assertIn("rdma_host_mem_umem_test", host_runner)
        for target in ("core", "integration", "host_mem", "net_packet"):
            self.assertRegex(
                makefile, re.compile(rf"^\.PHONY:.*\b{target}\b", re.MULTILINE)
            )
            self.assertRegex(makefile, re.compile(rf"^{target}:", re.MULTILINE))

    def test_verification_document_is_reproducible(self) -> None:
        """验证文档必须固定依赖版本、入口命令和 UVM 零告警要求。"""

        readme = REPO_ROOT / "README.md"
        report = REPO_ROOT / "docs/rdma-0.1.34-gap-closure-verification.md"
        self.assertTrue(readme.is_file())
        self.assertTrue(report.is_file())
        text = readme.read_text(encoding="utf-8") + report.read_text(encoding="utf-8")
        for token in (
            "0.1.34",
            "NET_PACKET_ROOT",
            "HOST_MEM_ROOT",
            "DPU_COMMON_ROOT",
            "scripts/run_vcs53.sh",
            "warning=0",
            "error=0",
            "fatal=0",
        ):
            self.assertIn(token, text)


if __name__ == "__main__":
    unittest.main()
