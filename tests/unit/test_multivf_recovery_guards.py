#!/usr/bin/env python3
"""验证多 VF recovery 场景的隔离断言顺序和状态空值防护。"""

from pathlib import Path
import re
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]
SOURCE_PATH = REPO_ROOT / "tests" / "integration" / "rdma_multivf_recovery_test.sv"


class MultiVFRecoveryGuardTest(unittest.TestCase):
    """功能：静态检查并发故障测试不会在释放后误判隔离，也不会解引用空状态。
    输入输出及副作用：读取 recovery 测试源码并返回断言结果，不创建仿真资源。
    失败边界：隔离检查晚于统一 release、FLR/lookup 状态未做空值保护或函数缺少
    三段中文说明时立即失败，防止回归到非确定性的 UVM_ERROR/仿真崩溃。
    """

    def setUp(self) -> None:
        """功能：加载待检查的多 VF recovery 源码。
        输入输出及副作用：无输入；更新本测试实例的 source 文本，不修改文件。
        失败边界：源码文件不存在或无法按 UTF-8 读取时由 unittest 报告错误。
        """
        self.source = SOURCE_PATH.read_text(encoding="utf-8")
        run_phase = self.source.split("task run_phase", 1)[1]
        self.run_phase = run_phase.split("endtask", 1)[0]

    def test_isolation_assertion_precedes_mapping_release(self) -> None:
        """功能：确保非目标 VF 隔离快照在 release 改变 mapping 状态前完成。
        输入输出及副作用：读取 run_phase 中的调用顺序，返回断言结果，不执行 DUT。
        失败边界：缺少隔离断言、缺少 release loop 或顺序反转时测试失败。
        """
        isolation = self.run_phase.find(
            "assert_other_vfs_unchanged(3, isolation_status)"
        )
        release = self.run_phase.find("release_vf_mapping(index, status)")
        self.assertGreaterEqual(isolation, 0, "run_phase 必须执行非目标 VF 隔离断言")
        self.assertGreaterEqual(release, 0, "run_phase 必须执行统一 mapping release")
        self.assertLess(
            isolation,
            release,
            "隔离断言必须在 release loop 前执行，避免把 RELEASED 误判为串扰",
        )

    def test_fault_case_guards_nullable_status_objects(self) -> None:
        """功能：检查故障 task 的 reset/lookup/coverage 路径先判空再访问字段。
        输入输出及副作用：读取 run_vf_case 文本并匹配保护模式，不调用仿真接口。
        失败边界：出现无 null guard 的 reset_status/lookup_status 或最终 status 字段
        访问时测试失败，防止外部 adapter 异常导致空句柄解引用。
        """
        run_case = self.source.split("task automatic run_vf_case", 1)[1]
        run_case = run_case.split("endtask", 1)[0]
        self.assertRegex(
            run_case,
            r"if\s*\(reset_status\s*==\s*null\s*\|\|\s*!reset_status\.ok\(\)\)",
        )
        self.assertRegex(
            run_case,
            r"if\s*\(lookup_status\s*==\s*null\s*\|\|\s*lookup_status\s*\.code",
        )
        self.assertRegex(
            run_case,
            r"if\s*\(status\s*==\s*null\)[\s\S]*?status\s*=\s*rdma_status::make",
        )

    def test_recovery_helpers_have_three_part_chinese_comments(self) -> None:
        """功能：检查本 task 涉及的 helper 前均保留功能、输入输出及副作用、失败边界说明。
        输入输出及副作用：扫描源文件注释文本，返回断言结果，不修改源码。
        失败边界：任一 helper 缺少三段紧邻注释时测试失败，避免新增分支失去设计依据。
        """
        for name in (
            "run_vf_case",
            "assert_other_vfs_unchanged",
            "run_phase",
        ):
            declarations = list(
                re.finditer(
                    rf"\b(?:task|function)\b[^\n]*\b{name}\b",
                    self.source,
                )
            )
            self.assertTrue(declarations, f"未找到 {name} 声明")
            declaration = declarations[-1]
            preceding = self.source[: declaration.start()]
            comment_block = preceding[preceding.rfind("\n\n") + 2 :]
            self.assertIn("// 功能：", comment_block,
                          f"{name} 缺少功能说明")
            self.assertIn("// 输入/输出及副作用：", comment_block,
                          f"{name} 缺少输入输出及副作用说明")
            self.assertIn("// 失败/边界：", comment_block,
                          f"{name} 缺少失败边界说明")

    def test_build_fixture_keeps_retry_authority_when_cleanup_fails(self) -> None:
        """功能：约束 fixture 重入时先验证旧 mapping 清理结果。
        输入输出及副作用：读取 build_fixture 源码并检查控制流顺序，不执行仿真。
        失败边界：若 release 失败后仍清空 env/mapping 引用，后续无法重试释放，
        测试应立即失败。
        """
        build_fixture = self.source.split("task automatic build_fixture", 1)[1]
        build_fixture = build_fixture.split("endtask", 1)[0]
        self.assertRegex(
            build_fixture,
            r"release_partial_mappings\(status\);\s*"
            r"if\s*\(status\s*==\s*null\s*\|\|\s*!status\.ok\(\)\)",
            "重入清理必须在清空 env 前检查 release 状态",
        )

    def test_fixture_readiness_is_fail_closed_on_isolation_mismatch(self) -> None:
        """功能：约束 equal-IOVA/domain 夹具不一致时停止后续故障矩阵。
        输入输出及副作用：读取 build_fixture/run_phase 控制流，不创建资源。
        失败边界：若 domain/IOVA 断言只报告错误却继续运行，测试应失败，避免
        把错误拓扑当成隔离覆盖证据。
        """
        self.assertIn("bit fixture_ready;", self.source)
        self.assertRegex(
            self.source,
            r"if\s*\(vf_iova\[0\]\s*!=\s*vf_iova\[1\]\s*\|\|\s*"
            r"vf_domain_id\[0\]\s*==\s*vf_domain_id\[1\]\)\s*begin[\s\S]{0,600}"
            r"abandon_fixture",
            "equal-IOVA/domain 不一致必须通过统一清理入口 fail-closed",
        )
        run_phase = self.run_phase
        self.assertIn(
            "if (!fixture_ready || env == null)",
            run_phase,
            "run_phase 必须拒绝未完成构建的 fixture",
        )


if __name__ == "__main__":
    unittest.main()
