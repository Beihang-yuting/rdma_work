"""目录/层次：tests/unit；职责：固定 RETRY 的持锁提交/发布边界。
依赖：unittest、SV 方法扫描器；只读源码，不代替动态 observer/并发验证。
所有权/生命周期：不创建仿真对象、锁或外部资源，不修改工作树。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CmqRecoveryPublishBoundaryTest(unittest.TestCase):
    """最终 stale 门禁之后只进入一个同步阶段，唯一 owner 与锁均留在 engine。"""

    def bodies(self):
        """功能：取得 recovery 入口与发布阶段的净化正文。
        输入输出及副作用：无参数，返回两个字符串；仅只读生产源码。
        失败边界：任一方法缺失或重名由扫描器/索引报错，不以空正文代替。
        """
        found = methods(read_code(CORE / "rdma_cmq_engine.sv"))
        return found["recover_submission_observed"][2], found["publish_recovery_retry_locked"][2]

    def test_single_entry_after_stale_gate(self):
        """功能：固定阶段调用紧邻最终 stale 重验，并保留 caller 的 OK/解锁/返回。
        输入输出及副作用：只读入口正文及调用次数。
        失败边界：调用前增加回调、把 CAS 留在 caller 或移动成功解锁时失败。
        """
        caller, stage = self.bodies()
        self.assertEqual(caller.count("publish_recovery_retry_locked("), 1)
        self.assertRegex(caller, r"if \(request.expected_attempt_id != record.attempt_id\) begin\s*"
                         r"status = journal_status\([^;]+;\s*break;\s*end\s*"
                         r"publish_recovery_retry_locked\(\s*record, preallocated, recovery_stage, "
                         r"candidate_attempt, results\s*\);\s*status = journal_status\(RDMA_SC_OK\);"
                         r"\s*engine_lock.put\(1\);\s*return;")
        self.assertNotRegex(caller, r"\battempt_id_counter\s*=(?!=)")
        self.assertNotIn("transport.submit_observed(", caller)
        self.assertEqual(stage.count("attempt_id_counter = candidate_attempt;"), 1)

    def test_stage_borrows_objects_without_lock_or_new_authority(self):
        """功能：要求阶段仅借用原行、候选和已对齐结果，锁/失败出口由 caller 持有。
        输入输出及副作用：读取声明与正文；无外部副作用。
        失败边界：新增锁操作、异步 worker、重建结果数组或再次准入时失败。
        """
        _, stage = self.bodies()
        self.assertRegex(stage, r"^\s*protected task publish_recovery_retry_locked\(")
        self.assertIn("input rdma_cmq_execution_result results[]", stage)
        self.assertNotRegex(stage, r"\b(?:engine_lock|fork|join|disable|semaphore|request)\b")
        self.assertNotIn("results =", stage)
        self.assertNotIn("reject_recovery_results_locked(", stage)
        self.assertNotIn("admit_retry_live_authority_locked(", stage)

    def test_commit_transport_and_delivery_order(self):
        """功能：固定 prior 捕获、CAS、pending 初始化、capability、transport 与交付顺序。
        输入输出及副作用：只读发布阶段的关键语句位置。
        失败边界：延迟提交 attempt、提前解码或把 item/result 交付放到 I/O 前时失败。
        """
        _, stage = self.bodies()
        markers = ["prior_cumulative = record.submission_effect;",
                   "attempt_id_counter = candidate_attempt;",
                   "record.attempt_id = candidate_attempt;",
                   "preallocated.attempt_id = candidate_attempt;",
                   "record.items[i].completion = null;",
                   "arm_observers[recovery_stage.capability_key] =",
                   "transport.submit_observed(", "observer_armed = record.observer_armed;",
                   "decode_transport_envelope(", "record.submission_effect = cumulative_effect;",
                   "rdma_cmq_classify_recovery_required(", "results[i].status = copy_submit_status_direct("]
        positions = [stage.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(stage.count("transport.submit_observed("), 1)

    def test_recovery_policy_and_callback_evidence_stay_distinct(self):
        """功能：保持 arm 后使用回调行的累计值、未 arm 使用历史值及逐项降级传播。
        输入输出及副作用：只读折叠、分类及 observation 交付语句。
        失败边界：套用首次 submit 的 PRE 回滚、抹除历史 evidence 或重置逐项错误时失败。
        """
        _, stage = self.bodies()
        self.assertIn("record.submission_effect, fold_evidence, cumulative_effect", stage)
        self.assertIn("prior_cumulative, current_attempt_effect, cumulative_effect", stage)
        self.assertNotIn("classify_observed_transport_effect(", stage)
        self.assertNotIn("remove_submission_journal_locked(", stage)
        self.assertRegex(stage, r"if \(!observer_armed\)\s*arm_observers.delete\(recovery_stage.capability_key\);")
        self.assertLess(stage.index("observation_code = RDMA_SC_INVALID_STATE;",
                                    stage.index("rdma_cmq_classify_recovery_required(")),
                        stage.index("results[i].observation_status = rdma_cmq_direct_status("))

    def test_public_characterization_registration(self):
        """功能：要求 96-case 公共入口矩阵独立注册，使用真实 observer 和调用前 CAS 观察。
        输入输出及副作用：只读测试、manifest 和 package。
        失败边界：漏注册、重复注册、测试改为直接调内部阶段或重复父矩阵时失败。
        """
        name = "rdma_cmq_recovery_publish_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$", (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        self.assertIn("completed 96 CMQ recovery publish cases", test)
        self.assertIn("engine.recover_submission_observed(request, results, status);", test)
        self.assertIn("scheduler.invoke_observer_before_return = armed;", test)
        self.assertIn("RETRY_PUBLISH_CAS", test)
        self.assertNotIn("publish_recovery_retry_locked(", test)
        self.assertNotIn("super.run_phase", test)


if __name__ == "__main__":
    unittest.main()
