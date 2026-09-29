"""目录/层次：tests/unit；职责：守卫 consumer 公共步骤与 caller 业务编排的边界。
依赖：unittest、既有 SV 词法工具；仅读源码，不替代 VCS 中的故障/恢复时序验证。
所有权与生命周期：不创建 runtime 或访问外部资源，不修改被测源码。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class QueueConsumerStepsBoundaryTest(unittest.TestCase):
    """公共步骤只负责通知证据/CI 提交，admission、shadow、幂等与交付仍属于业务 caller。"""

    def test_three_callers_share_both_steps(self):
        """功能：禁止 CQ/event/replay 再次内联 doorbell 结果或 CI gate 逻辑。
        输入输出及副作用：扫描三个方法正文，要求各调用两个公共步骤一次；只读。
        失败边界：遗漏 caller、重复调用或重新绕过公共步骤直接提交均失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        for name in ("commit_cq_poll_candidate", "commit_event_poll_candidate",
                     "replay_consumer_pending"):
            body = declared[name][2]
            for step in ("submit_consumer_doorbell_recorded", "commit_consumer_cursor_recorded"):
                self.assertEqual(len(re.findall(rf"\b{step}\s*\(", body)), 1)
            self.assertNotRegex(body, r"\b(?:submit_consumer_doorbell|commit_cq_consumer|"
                                r"enable_recovery_commit_noalloc|record_recovery_failure_noalloc)\s*\(")

    def test_steps_keep_noallocation_boundary(self):
        """功能：禁止公共步骤在 seam 返回后的 continuation 创建对象或动态构造诊断。
        输入输出及副作用：读取两个步骤净化正文，检查 factory/clone/new 和字符串操作；只读。
        失败边界：出现分配、格式化、字符串拼接或新的 runtime 快照查询即失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        for name in ("submit_consumer_doorbell_recorded", "commit_consumer_cursor_recorded"):
            body = declared[name][2]
            self.assertNotRegex(body, r"\b(?:new|create|clone|copy|make|make_direct|"
                                r"make_status_nonfatal|sformatf|query_\w+|snapshot_\w+)\b")
            self.assertNotRegex(body, r"[{}]")
            self.assertIn("rdma_status::set_fields_noalloc(", body)
            self.assertNotRegex(body, r"\b(?:enter_recovery\w*|publish_cqc_shadow|"
                                r"execute_consumer_wqe_release|complete_consumer_recovery_noalloc)\s*\(")

    def test_step_stage_order_and_success_flag(self):
        """功能：锁定通知→记录证据和 gate→CI seam→失败记录的顺序。
        输入输出及副作用：读取步骤正文和成功标记位置；只读，不推断 MMIO 实际已发生。
        失败边界：提前置 completed、跳过 gate 或失败路径缺少证据记录即失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        doorbell = declared["submit_consumer_doorbell_recorded"][2]
        self.assertLess(doorbell.index("completed = 1'b0;"),
                        doorbell.index("submit_consumer_doorbell("))
        self.assertLess(doorbell.rindex("record_recovery_failure_noalloc("),
                        doorbell.index("completed = 1'b1;"))
        commit = declared["commit_consumer_cursor_recorded"][2]
        self.assertLess(commit.index("enable_recovery_commit_noalloc("),
                        commit.index("commit_cq_consumer("))
        self.assertLess(commit.index("commit_cq_consumer("),
                        commit.index("record_recovery_failure_noalloc("))

    def test_replay_retains_skip_policy(self):
        """功能：要求 replay 只在 NO_SUBMIT 重发通知，只在未 committed 时提交 CI。
        输入输出及副作用：定位两个步骤的外围分支，检查 AMBIGUOUS/SUCCESS 与 CQ release 仍独立。
        失败边界：步骤移出既有幂等分支、shadow 被无条件重写或 WQE release 丢失即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["replay_consumer_pending"][2]
        no_submit = body.index("else if (pending.mmio_evidence == RDMA_QUEUE_MMIO_NO_SUBMIT)")
        success = body.index("else if (pending.mmio_evidence == RDMA_QUEUE_MMIO_SUCCESS)")
        self.assertTrue(no_submit < body.index("submit_consumer_doorbell_recorded(") < success)
        guard = body.index("if (!pending.consumer_committed)")
        release = body.index("if (attachment.kind == RDMA_QUEUE_RUNTIME_CQ")
        self.assertTrue(guard < body.index("commit_consumer_cursor_recorded(") < release)
        self.assertIn("if (!pending.consumer_shadow_published)", body)
        self.assertIn("release_consumer_pending_wqe(", body)

    def test_existing_diagnostics_are_literal_choices(self):
        """功能：锁定三种上下文的 18 条原始错误文本，避免公共步骤丢失业务诊断。
        输入输出及副作用：读取原始 engine 字符串；诊断仅允许固定 literal，不依赖 queue kind。
        失败边界：null/假成功/证据失败/CI 失败任一文本缺失或重复出现即失败。
        """
        source = (CORE / "rdma_queue_data_engine.sv").read_text()
        for prefix in ("CQ consumer", "event consumer", "consumer recovery"):
            for suffix in ("doorbell returned null status",
                           "doorbell returned incomplete success evidence",
                           "commit returned null status", "commit failure could not be retained"):
                self.assertEqual(source.count(f'"{prefix} {suffix}"'), 1)
        for prefix in ("CQ", "event", "consumer recovery"):
            for outcome in ("failure", "success"):
                evidence = "" if prefix == "consumer recovery" else " evidence"
                self.assertEqual(source.count(
                    f'"{prefix} doorbell {outcome}{evidence} could not be retained"'), 1)

    def test_fault_matrix_registered_in_core(self):
        """功能：确保独立 45-case 故障矩阵进入完整 core 回归而不只是被编译。
        输入输出及副作用：读取 package、core manifest 和测试循环；只读。
        失败边界：注册/include 丢失、诊断上下文或两组场景数量收缩即失败。
        """
        name = "rdma_queue_consumer_steps_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        self.assertEqual(package.count(f'`include "unit/{name}.sv"'), 1)
        core = manifest.split("readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        source = read_code(ROOT / f"tests/unit/{name}.sv")
        for bound in ("diagnostic < 3", "mode < 10", "mode < 5"):
            self.assertIn(bound, source)


if __name__ == "__main__":
    unittest.main()
