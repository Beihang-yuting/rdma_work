"""目录/层次：tests/unit；职责：守卫 CQ resize 发布前回滚与发布后 cleanup 的出口边界。
依赖：unittest 与既有 SV 词法工具；只读源码，动态资源与锁行为由 VCS 故障矩阵验证。
所有权与生命周期：不创建 runtime、mapping 或外部对象，不修改被测文件。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CqResizeExitBoundaryTest(unittest.TestCase):
    """统一退出只收束控制流，不能新增 owner、快照窗口或跨过 manager publication 回滚。"""

    def test_one_rollback_exit_for_twenty_failures(self):
        """功能：确保二十个准备失败点使用同一个完整 rollback 续接。
        输入输出及副作用：读取 resize_cq，检查命名块、跳转次数与唯一末尾 abort；只读。
        失败边界：重复回滚、丢失失败点、改用跨调用 disable 或回滚后遗漏锁释放均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["resize_cq"][2]
        self.assertEqual(body.count("do begin : resize_transaction"), 1)
        self.assertEqual(body.count("break;"), 20)
        self.assertEqual(body.count("abort_cq_resize("), 1)
        self.assertNotRegex(body, r"\bdisable\b")
        self.assertRegex(body, r"end while \(1'b0\);\s+status = abort_cq_resize\(cq_h, "
                         r"old_attachment.runtime, dependents,\s+candidate_ref, "
                         r"manager_quiesced, cq_quiesced,\s+status\);\s+"
                         r"return finish_resize\(status\);\s+endfunction\s*$")

    def test_publication_never_falls_into_rollback(self):
        """功能：要求发布后的三种清理错误和成功都直接释放锁返回。
        输入输出及副作用：读取 published 标记之后、rollback 之前的控制流；只读。
        失败边界：发布后新增 break/disable、缺少直接返回或成功路径落入 rollback 时失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["resize_cq"][2]
        published = body.split("recovery.published = 1'b1;", 1)[1]
        published = published.split("status = abort_cq_resize(", 1)[0]
        self.assertNotRegex(published, r"\b(?:disable|break)\b")
        self.assertEqual(published.count("return finish_resize("), 4)
        self.assertRegex(published, r"cq_resize_recoveries.delete\(recovery_key\);\s+"
                         r"return finish_resize\(rdma_status::success\(\)\);\s+"
                         r"end while \(1'b0\);\s*$")

    def test_staging_and_commit_order(self):
        """功能：锁定 quiesce→候选→manager swap→attachment→旧资源释放的顺序。
        输入输出及副作用：比较关键调用在 resize_cq 的位置，保留输入字段的原读取阶段。
        失败边界：提前分配、延后 recovery 准备、提前释放旧 ring 或绕过 manager swap 即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["resize_cq"][2]
        steps = (
            "manager.begin_cq_resize(", "old_attachment.runtime.begin_quiesce(",
            "quiesce_cq_dependents(", "manager.lookup(",
            "backing_planner.allocate_owned_cq_resize_ring(",
            "candidate_runtime.configure(", "candidate_runtime.copy_ring_state(",
            "candidate_runtime.activate(", "candidate_access.configure(",
            "candidate_access.attach_queue(", "candidate_plan.copy(", "candidate_cq.copy(",
            "find_queue_ref(", "binding.function_identity_snapshot(",
            "clone_publish_handle(", "manager.replace_active_cq(",
            "recovery.published = 1'b1;", "attachments[key] = replacement;",
            "cq_resize_recoveries[recovery_key] = recovery;", "restore_cq_dependents(",
            "old_attachment.runtime.detach_quiesced(", "backing_planner.cleanup_local_role(",
        )
        positions = [body.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))

    def test_no_extra_transaction_state_or_return_protocol(self):
        """功能：防止统一出口再引入第二事务对象、成功旗标或延迟 status 规范化。
        输入输出及副作用：检查块入口和外部尾段；临时变量仍只服务已有 resize 阶段。
        失败边界：块外尾段包含 abort/finish 之外的调用、旗标判断或赋值即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["resize_cq"][2]
        self.assertRegex(body, r"manager_quiesced = 1'b1;\s+do begin : resize_transaction\s+"
                         r"status = old_attachment.runtime.begin_quiesce\(\);")
        tail = body.rsplit("return finish_resize(rdma_status::success());", 1)[1]
        tail = tail.split("end while (1'b0);", 1)[1]
        self.assertEqual(re.findall(r"\b(\w+)\s*\(", tail),
                         ["abort_cq_resize", "finish_resize"])
        self.assertEqual(len(re.findall(r"\bstatus\s*=", tail)), 1)

    def test_rollback_keeps_cleanup_restore_and_original_error(self):
        """功能：守卫唯一 rollback 实现的候选清理、CQ/依赖/manager 恢复和原错误保留。
        输入输出及副作用：读取 abort_cq_resize，不改动其恢复证据或错误合成。
        失败边界：先释放 authority 后补证据、漏掉任一 restore 或原错误返回被覆盖即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["abort_cq_resize"][2]
        steps = ("backing_planner.cleanup_local_role(", "record_candidate_cleanup_recovery(",
                 "old_runtime.restore_active(", "restore_cq_dependents(",
                 "manager.restore_active(", "record_prepublish_recovery(")
        positions = [body.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertIn("original_status.message", body)
        self.assertRegex(body, r": original_status;\s+endfunction\s*$")

    def test_fault_matrix_is_registered(self):
        """功能：确保 16-case 故障矩阵及跨 engine 嵌套调用由完整 core 回归实际运行。
        输入输出及副作用：读取 package、manifest、测试循环和资源/锁断言；只读。
        失败边界：漏 include、漏逻辑测试注册、场景缩水或移除零泄漏/锁探测即失败。
        """
        name = "rdma_cq_resize_exit_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        self.assertEqual(package.count(f'`include "unit/{name}.sv"'), 1)
        core = manifest.split("readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        test = read_code(ROOT / f"tests/unit/{name}.sv")
        for contract in ("mode < 15", "mode < 12", "mode / 2", "mode % 2",
                         "has_one_resize_token()", "fixture.mem.live_allocations() != 0",
                         "run_nested_case();", "null_wrapper.hits != 2",
                         "null_wrapper.nested_status.code != RDMA_SC_RESOURCE_EXHAUSTED"):
            self.assertIn(contract, test)


if __name__ == "__main__":
    unittest.main()
