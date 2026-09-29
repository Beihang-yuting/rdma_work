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
        for name in ("commit_cq_poll_candidate", "consume_routed_event",
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

    def test_event_callers_delegate_only_after_route_and_next(self):
        """功能：锁定 CEQ/AEQ 路由之后只调用一个消费事务，不重复物化候选或 continuation。
        输入输出及副作用：读取两个 poll_once，检查 route/next/consume 顺序及委托次数；只读。
        失败边界：路由被迁入共同 task、任一 caller 再复制结果/准备/提交链或漏掉委托即失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        for name, route in (("poll_ceqe_once", "lookup_event_cq_route_for_poll"),
                            ("poll_aeqe_once", "resolve_aeqe_routes")):
            body = declared[name][2]
            self.assertLess(body.index(route + "("), body.index("make_next_poll_cursor_nonfatal("))
            self.assertLess(body.index("make_next_poll_cursor_nonfatal("),
                            body.index("consume_routed_event("))
            self.assertEqual(body.count("consume_routed_event("), 1)
            self.assertNotRegex(body, r"\b(?:completion_status_from_ecode|prepare_event_\w+|"
                                r"enter_recovery_prepared|submit_consumer_doorbell_recorded)\s*\(")
        self.assertNotIn("commit_event_poll_candidate", declared)

    def test_event_route_policy_stays_in_each_caller(self):
        """功能：保留 AEQ 专有读前 epoch gate 和 CQ flush 任一路命中的交付规则。
        输入输出及副作用：只读 CEQ/AEQ 和共同业务 task，核对门禁位置及 route 参数。
        失败边界：向 CEQ 添加 epoch 检查、AEQ gate 后移、flush OR 改为 primary 或公共层重查 route 均失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        ceq, aeq = declared["poll_ceqe_once"][2], declared["poll_aeqe_once"][2]
        self.assertNotIn("validate_attachment_route_epoch(", ceq)
        self.assertLess(aeq.index("validate_attachment_route_epoch("), aeq.index("peek_consumer("))
        self.assertIn("is_cq_flush ? (primary_found || secondary_found)", aeq)
        self.assertRegex(ceq, r"RDMA_ENGINE_CEQ,\s*routed_cq_h,\s*null,\s*route_found")
        self.assertRegex(aeq, r"RDMA_ENGINE_AEQ,\s*primary_route_h,\s*secondary_route_h,\s*deliver_found")
        self.assertNotRegex(declared["consume_routed_event"][2],
                            r"\b(?:resolve_aeqe_routes|lookup_event_cq_route_for_poll|"
                            r"validate_attachment_route_epoch)\s*\(")

    def test_event_preparation_precedes_noallocation_commit(self):
        """功能：保证 event 的结果/恢复证据全部在 admission 前准备，门铃后只执行无分配续接。
        输入输出及副作用：扫描唯一消费 task 的阶段序列和 tail；不运行 scheduler。
        失败边界：重复或颠倒阶段、提交后创建/clone/查询快照、提前交付 result 即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["consume_routed_event"][2]
        stages = ("completion_status_from_ecode(", "prepare_event_result_candidate_ex(",
                  "prepare_event_poll_continuation(", "enter_recovery_prepared(",
                  "submit_consumer_doorbell_recorded(", "commit_consumer_cursor_recorded(",
                  "complete_consumer_recovery_noalloc(", "result = deliver_found ?")
        for stage in stages:
            self.assertEqual(body.count(stage), 1)
        positions = [body.index(stage) for stage in stages]
        self.assertEqual(positions, sorted(positions))
        tail = body[body.index("submit_consumer_doorbell_recorded("):]
        self.assertNotRegex(tail, r"\b(?:new|create|clone|copy|make|make_status_nonfatal|"
                            r"sformatf|query_\w+|snapshot_\w+)\b")

    def test_event_miss_null_final_retains_incoming_status(self):
        """功能：保护 miss 最终状态 raw 分配失败沿用 next cursor status 的既有返回契约。
        输入输出及副作用：读取 task 签名与 miss 分支，核对 inout 和清零边界；只读。
        失败边界：改为 output、准备前清零 status、为 final_success=null 新建错误或继续 admission 均失败。
        """
        source = (CORE / "rdma_queue_data_engine.sv").read_text()
        signature = source.split("protected task consume_routed_event(", 1)[1].split(");", 1)[0]
        self.assertIn("inout rdma_status status", signature)
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["consume_routed_event"][2]
        self.assertRegex(body, r"if \(final_success == null\)\s*return;")
        self.assertEqual(body.count("status = null;"), 1)
        self.assertLess(body.index("prepare_event_poll_continuation("), body.index("status = null;"))

    def test_event_preparation_matrix_remains_in_core(self):
        """功能：锁定真实 topology 的 44-case hit/miss/null/错型与恢复后单次消费矩阵。
        输入输出及副作用：读取既有 test/package/manifest，检查循环维度、状态引用与提交计数断言。
        失败边界：测试退出完整 core、factory 未恢复、漏掉 miss 状态引用或故障未命中检查均失败。
        """
        name = "rdma_queue_event_route_consume_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        self.assertEqual(package.count(f'`include "unit/{name}.sv"'), 1)
        core = manifest.split("readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        source = read_code(ROOT / f"tests/unit/{name}.sv")
        for contract in ("aeq < 2", "miss < 2", "mode < 8", "mode == 0 ? 1 : 2",
                         "status != factory.next_status", "!factory.fired",
                         "service.set_factory(saved_factory)", "used != 1 || pending",
                         "ci_after != ci_before", "mmio_before + 1"):
            self.assertIn(contract, source)


if __name__ == "__main__":
    unittest.main()
