"""目录/层次：tests/unit；职责：守卫 CQ resize 回滚、发布后 cleanup 与 retry 的出口边界。
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

    def test_retry_has_one_recorded_failure_exit(self):
        """功能：要求 retry 的 17 个记录内失败点共用原诊断保存、解锁、返回续接。
        输入输出及副作用：只读 retry_cq_resize_cleanup 的完整方法，不构造运行时对象。
        失败边界：重复 last_status、遗漏失败点、新增跨调用 disable 或额外嵌套循环均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["retry_cq_resize_cleanup"][2]
        self.assertEqual(body.count("do begin : resize_recovery"), 1)
        self.assertEqual(body.count("break;"), 17)
        self.assertEqual(body.count("recovery.last_status = status;"), 1)
        self.assertNotRegex(body, r"\b(?:disable|for|foreach|repeat)\b")
        self.assertRegex(body, r"end while \(1'b0\);\s+recovery.last_status = status;\s+"
                         r"resize_lock.put\(1\);\s+return status;\s+endfunction\s*$")

    def test_retry_entry_errors_stay_outside_recorded_exit(self):
        """功能：保持未配置、非法 handle、锁忙和无记录拒绝在已捕获 recovery 之前。
        输入输出及副作用：读取 loop 之前的准入片段，核对返回数量、解锁及记录读取顺序。
        失败边界：早拒绝写 last_status、重复解锁、无记录返回变为成功或进入公共出口即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["retry_cq_resize_cleanup"][2]
        entry = body.split("do begin : resize_recovery", 1)[0]
        self.assertEqual(entry.count("return bad("), 4)
        self.assertEqual(entry.count("resize_lock.put(1);"), 1)
        self.assertNotIn("last_status", entry)
        self.assertRegex(entry, r"recovery = cq_resize_recoveries\[key\];\s*$")
        for code in ("RDMA_SC_INVALID_STATE", "RDMA_SC_RESOURCE_BUSY"):
            self.assertIn(code, entry)
        # handle 拒绝沿用 bad 的缺省 INVALID_ARGUMENT，不额外分配分类对象。
        self.assertIn('bad("CQ resize recovery handle is invalid")',
                      (CORE / "rdma_queue_data_engine.sv").read_text())

    def test_retry_success_unlocks_before_status_factory(self):
        """功能：保持发布前/后两条成功路径删除记录并解锁后再创建 OK status。
        输入输出及副作用：检查完整成功 token 序列和 finish_resize 缺席；不执行 factory。
        失败边界：成功也写 last_status、factory 提前到锁内、合并成延迟成功旗标均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["retry_cq_resize_cleanup"][2]
        success = (r"cq_resize_recoveries.delete\(key\);\s+resize_lock.put\(1\);\s+"
                   r"return rdma_status::success\(\);")
        self.assertEqual(len(re.findall(success, body)), 2)
        self.assertNotIn("finish_resize(", body)
        self.assertEqual(body.count("resize_lock.put(1);"), 4)

    def test_retry_keeps_stage_order_and_incremental_progress(self):
        """功能：固定 authority 门禁、发布前恢复/候选清理、发布后依赖恢复/旧资源清理顺序。
        输入输出及副作用：读取 retry 阶段标记和原 flag 更新；不重算 authority 或 snapshot。
        失败边界：在 backing 校验前恢复、跨 publication 清理错 ref、删除进度标记或重做 detach 即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["retry_cq_resize_cleanup"][2]
        steps = ("same_cq_recovery_identity(", "binding.function_identity_snapshot(",
                 "find_cq_recovery_attachment(", "recovery_backing_matches(",
                 "if (!recovery.published)", "recovery.old_runtime.restore_active(",
                 "recovery.cq_restore_pending = 1'b0;", "restore_cq_dependents(",
                 "manager.restore_active(", "recovery.manager_restore_pending = 1'b0;",
                 "recovery.prepublish_restore_pending = 1'b0;",
                 "backing_planner.cleanup_local_role(")
        positions = [body.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(body.count("restore_cq_dependents(recovery.dependents)"), 2)
        self.assertIn("else if (recovery.old_runtime.state != RDMA_QUEUE_RUNTIME_DETACHED)", body)
        self.assertIn("recovery.pending_ref, cleanup_complete", body)
        self.assertRegex(body, r"cleanup_local_role\(recovery.old_ref,\s+cleanup_complete\)")

    def test_retry_matrix_covers_retention_progress_and_reentrancy(self):
        """功能：要求既有 resize test 同时运行 21 个单故障与一个嵌套 retry 场景。
        输入输出及副作用：读取独立注入、诊断/记录/进度/资源检查与 run_phase 调用。
        失败边界：场景缩水、遗漏准确错误或移除同 owner busy/异 owner 嵌套检查均失败。
        """
        test = read_code(ROOT / "tests/unit/rdma_cq_resize_exit_test.sv")
        for token in ("mode < 21", "run_retry_case(mode)", "run_nested_retry_case()",
                      "failure.message != expected", "record.last_status != failure",
                      "probe.borrow_recovery(fixture.cq.handle) != record",
                      "fixture.mem.live_allocations() != live_before - 1",
                      "callback.busy_status.code != RDMA_SC_RESOURCE_BUSY",
                      "records[1].last_status != callback.nested_status",
                      "callback.evidence_unchanged", "record.cq_restore_pending"):
            self.assertIn(token, test)


if __name__ == "__main__":
    unittest.main()
