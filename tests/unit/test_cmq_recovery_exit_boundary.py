"""目录/层次：tests/unit；职责：守卫 CMQ recovery 的单一 aligned failure 出口。
依赖：unittest、SV 方法扫描器；只读源码，不代替动态 CAS/恢复/回调验证。
所有权与生命周期：不创建仿真对象，不修改工程或外部状态。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CmqRecoveryExitBoundaryTest(unittest.TestCase):
    """单次循环只收束本次调用的失败，不取消其它激活或重写成功路径。"""

    def body(self):
        """功能：返回完整 recovery task 的净化正文用于结构断言。
        输入输出及副作用：无参数；仅读取生产源码。
        失败边界：方法缺失或重复直接失败，不以空正文通过。
        """
        return methods(read_code(CORE / "rdma_cmq_engine.sv"))["recover_submission_observed"][2]

    def test_single_failure_exit_and_explicit_success(self):
        """功能：要求 12 个拒绝共用尾段，CONFIRM/RETRY 成功不落入失败回填。
        输入输出及副作用：读取调用数和单次循环两边的顺序；只读。
        失败边界：回填重新分叉、按 OK 判别出口或成功遗漏 return 时失败。
        """
        body = self.body()
        self.assertEqual(body.count("reject_recovery_results_locked("), 1)
        prefix, rest = body.split("do begin : recovery_transaction")
        transaction, tail = rest.split("end while (1'b0);")
        self.assertNotIn("reject_recovery_results_locked", prefix + transaction)
        self.assertEqual(" ".join(tail.split()),
                         "reject_recovery_results_locked(results, status.code, status.message); "
                         "engine_lock.put(1); endtask")
        self.assertEqual(len(re.findall(r"engine_lock.put\(1\);\s*return;", transaction)), 2)
        self.assertNotRegex(body, r"\b(?:disable|fork|join|semaphore)\b")

    def test_unlocated_failures_stay_before_alignment(self):
        """功能：保持 gate/locate/shape/item-order 拒绝返回空数组，不发布 aligned 结果。
        输入输出及副作用：只读循环前缀和 staging 位置。
        失败边界：提前 staging、移动空数组初始化或删除早期解锁返回时失败。
        """
        prefix, transaction = self.body().split("do begin : recovery_transaction")
        self.assertIn("results = new[0];", prefix)
        self.assertIn("request.items[i].request_index != record.items[i].request_index", prefix)
        self.assertEqual(prefix.count("engine_lock.put(1);"), 4)
        self.assertNotIn("stage_recovery_results_locked(", prefix)
        self.assertLess(transaction.index("stage_recovery_results_locked("),
                        transaction.index("request.expected_attempt_id != record.attempt_id"))

    def test_owner_failure_exits_both_loops(self):
        """功能：确保首/中/末 owner 拒绝先退出 foreach，再退出事务，不继续 CAS。
        输入输出及副作用：读取局部 owner_rejected 的唯一置位及使用；只读。
        失败边界：循环内 break 被误当作全任务退出、旗标残留或按 status.ok 推断时失败。
        """
        body = self.body()
        self.assertEqual(body.count("owner_rejected = 1'b0;"), 1)
        self.assertEqual(body.count("owner_rejected = 1'b1;"), 1)
        self.assertRegex(body, r"owner_rejected = 1'b1;\s*break;")
        self.assertRegex(body, r"if \(owner_rejected\)\s*break;")
        self.assertLess(body.index("if (owner_rejected)"), body.index("validate_reset_confirmation_locked("))
        self.assertLess(body.index("if (owner_rejected)"), body.index("attempt_id_counter = candidate_attempt;"))

    def test_stale_status_has_no_callback_before_fanout(self):
        """功能：固定三处 stale 直接 status 的文本，使共同尾段取 message 等价于旧字面量。
        输入输出及副作用：读取保留字符串的原文及 direct status 构造契约；只读。
        失败边界：stale status 与 break 间增加回调，或 journal_status 改走 factory 时失败。
        """
        source = (CORE / "rdma_cmq_engine.sv").read_text()
        task = source.split("  task recover_submission_observed(", 1)[1].split("endtask", 1)[0]
        self.assertEqual(len(re.findall(
            r'status = journal_status\(\s*RDMA_SC_INVALID_STATE, "stale CMQ recovery attempt"\s*\);\s*break;',
            task)), 3)
        journal = methods(read_code(CORE / "rdma_cmq_engine.sv"))["journal_status"][2]
        self.assertIn("return rdma_cmq_direct_status(code, message);", journal)
        direct = (ROOT / "src/model/rdma_cmq_execution_models.sv").read_text()
        direct = direct.split("function automatic rdma_status rdma_cmq_direct_status(", 1)[1].split("endfunction", 1)[0]
        self.assertIn('status = new("rdma_cmq_status");', direct)
        self.assertIn("status.message = message;", direct)
        self.assertNotIn("type_id", direct)

    def test_retry_commit_and_regression_registration(self):
        """功能：固定最终 stale 门禁仍在 CAS/I/O 前，并将 36-call 专项独立注册。
        输入输出及副作用：只读生产路径、manifest、package 和测试文件。
        失败边界：提前分配 attempt/调用 transport、漏注册、重复注册或运行父矩阵时失败。
        """
        body = self.body()
        self.assertLess(body.index("stage_recovery_candidate_locked("),
                        body.rindex("request.expected_attempt_id != record.attempt_id"))
        self.assertLess(body.rindex("request.expected_attempt_id != record.attempt_id"),
                        body.index("attempt_id_counter = candidate_attempt;"))
        self.assertLess(body.index("attempt_id_counter = candidate_attempt;"),
                        body.index("transport.submit_observed("))
        name = "rdma_cmq_recovery_exit_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$", (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        self.assertIn("completed 36 CMQ recovery exit calls", test)
        self.assertNotIn("super.run_phase", test)


if __name__ == "__main__":
    unittest.main()
