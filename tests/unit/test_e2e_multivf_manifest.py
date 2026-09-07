#!/usr/bin/env python3
"""验证多 VF recovery 的 e2e 构建入口不会丢失 dpu_common 依赖。"""

from pathlib import Path
import unittest


REPO_ROOT = Path(__file__).resolve().parents[2]


class E2EMultiVFManifestTest(unittest.TestCase):
    """功能：检查 e2e filelist 和 Makefile 共同注册真实多 VF 测试入口。
    输入输出及副作用：读取仓库内构建文件，返回断言结果，不创建或修改仿真产物。
    失败边界：缺少 dpu_common package、RDMA_DPU_INTEGRATION 定义或多 VF 测试
    注册时立即失败，避免把 integration-only 验证误报成 e2e 通过。
    """

    def test_e2e_manifest_contains_dpu_common_multivf_path(self) -> None:
        makefile = (REPO_ROOT / "sim" / "Makefile").read_text(encoding="utf-8")
        filelist = (REPO_ROOT / "sim" / "filelists" / "e2e.f").read_text(
            encoding="utf-8"
        )
        test_pkg = (REPO_ROOT / "tests" / "rdma_unit_test_pkg.sv").read_text(
            encoding="utf-8"
        )

        self.assertIn("+define+RDMA_DPU_INTEGRATION", makefile)
        self.assertIn("dpu_resource_pkg.sv", filelist)
        self.assertIn("rdma_dpu_env_pkg.sv", filelist)
        self.assertIn("rdma_multivf_recovery_test.sv", test_pkg)

    def test_multivf_fault_matrix_uses_adapter_paths_and_real_release(self) -> None:
        test_source = (REPO_ROOT / "tests" / "integration" /
                       "rdma_multivf_recovery_test.sv").read_text(encoding="utf-8")

        self.assertIn("host_mem.allocate", test_source)
        self.assertIn("mapping.check_access", test_source)
        self.assertIn("cmq.execute", test_source)
        self.assertIn("engine.poll_cqe", test_source)
        # 多 VF 夹具必须按 VF 索引调用真实 adapter；不要退回到没有
        # Function 隔离语义的单一全局 net_adapter。
        self.assertIn("net_adapter[vf_index].send_packet", test_source)
        self.assertIn("release_completion_status", test_source)
        self.assertNotIn(
            "RDMA_FAULT_WRONG_REQUESTER: status = rdma_status::make",
            test_source,
        )
        self.assertNotIn(
            "RDMA_FAULT_IOVA_PERMISSION: status = rdma_status::make",
            test_source,
        )
        self.assertNotIn(
            "RDMA_FAULT_CMQ_TIMEOUT: status = rdma_status::make",
            test_source,
        )
        self.assertNotIn(
            "RDMA_FAULT_CQE_ERROR: status = rdma_status::make",
            test_source,
        )
        self.assertNotIn(
            "RDMA_FAULT_PACKET_DROP: status = rdma_status::make",
            test_source,
        )
        self.assertNotIn("owned_release_count[vf_index]++", test_source)

    def test_multivf_fault_status_preserves_router_and_cqe_evidence(self) -> None:
        """功能：约束多 VF 故障测试保留真实 router/CQE 返回的错误证据。
        输入输出及副作用：读取 recovery 测试源码并返回断言结果，不执行 DUT。
        失败边界：若 requester 错误被误判为 INVALID_ARGUMENT，或 CQE 顶层事务
        状态取代 completion_status，测试失败，防止把硬件错误路径改成合成状态。
        """
        test_source = (REPO_ROOT / "tests" / "integration" /
                       "rdma_multivf_recovery_test.sv").read_text(encoding="utf-8")

        self.assertIn("first_wrong_requester.code != RDMA_SC_DMA_TRANSLATION", test_source)
        self.assertIn("queue_completion.completion_status", test_source)
        self.assertIn("RDMA_SC_QUEUE_FULL", test_source)
        self.assertNotIn(
            "status.code != RDMA_SC_UNKNOWN_HW_ERROR ||\n                  queue_completion != null",
            test_source,
        )


if __name__ == "__main__":
    unittest.main()
