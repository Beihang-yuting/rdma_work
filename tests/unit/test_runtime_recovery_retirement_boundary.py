"""目录/层次：tests/unit；职责：固定恢复结束的单一状态清理与四个调用边界。
依赖：unittest、既有只读 SV scanner；不替代 VCS 的拒绝/锁/factory 验证。
所有权/生命周期：只读源码，不持有 runtime 或改写工作树。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class RuntimeRecoveryRetirementBoundaryTest(unittest.TestCase):
    """共享清理不接管锁、状态对象或完成条件，业务入口保留最终状态选择。"""

    def declared(self):
        """功能：读取 runtime 的完整方法映射，供结构断言复用。
        输入输出及副作用：无参数；返回只读方法范围/正文。
        失败边界：缺文件或方法直接报错，不用空方法回退。
        """
        return methods(read_code(CORE / "rdma_queue_runtime.sv"))

    def test_shared_retirement_is_only_ordered_assignments(self):
        """功能：固定清理字段与顺序，最后发布 caller 选择的 lifecycle 状态。
        输入输出及副作用：只读 helper；检查完整正文，不执行清理。
        失败边界：新增分配/回调/解锁/条件/游标写入或遗漏字段均失败。
        """
        body = self.declared()["retire_recovery_locked"][2]
        expected = """protected function void retire_recovery_locked(
          rdma_queue_runtime_state_e final_state
        );
          pending_operation_state = null;
          device_reservation_valid = 1'b0;
          device_reservation = null;
          recovery_commit_allowed = 1'b0;
          consumer_release_gate_active = 1'b0;
          recovery_retry_confirmed = 1'b0;
          state = final_state;
        endfunction"""
        self.assertEqual(re.findall(r"\w+|[^\w\s]", body),
                         re.findall(r"\w+|[^\w\s]", expected))

    def test_four_callers_keep_explicit_final_state(self):
        """功能：四入口各只在成功路径委托一次共享清理，紧接原锁释放。
        输入输出及副作用：读取完成与中止入口，不改变准入或状态。
        失败边界：错选 ACTIVE/DETACHED、遗留重复清理、提前解锁或缺失调用均失败。
        """
        declared = self.declared()
        for name, state in (("complete_recovery_retry", "ACTIVE"),
                            ("complete_consumer_recovery_noalloc", "ACTIVE"),
                            ("abort_recovery", "DETACHED"), ("recover", "DETACHED")):
            body = declared[name][2]
            self.assertEqual(body.count("retire_recovery_locked("), 1)
            self.assertRegex(body, rf"retire_recovery_locked\(RDMA_QUEUE_RUNTIME_{state}\);\s*lock.put\(1\);")
            self.assertNotIn("pending_operation_state = null", body)
            self.assertNotIn("device_reservation = null", body)
        source = read_code(CORE / "rdma_queue_runtime.sv")
        self.assertEqual(source.count("retire_recovery_locked("), 5)

    def test_noalloc_keeps_marker_before_retirement_and_status_after_unlock(self):
        """功能：保留 noalloc 的 null/busy 优先级、旧 pending release marker 与原槽交付。
        输入输出及副作用：只读调用顺序；不使用共享清理自证公开行为。
        失败边界：提前丢失旧 pending、分配 status、调用普通入口或交换锁窗口均失败。
        """
        body = self.declared()["complete_consumer_recovery_noalloc"][2]
        body = " ".join(body.split())
        markers = ("status_slot == null", "lock.try_get(1)",
                   "pending_operation_state.completion_released = 1'b1;",
                   "retire_recovery_locked(RDMA_QUEUE_RUNTIME_ACTIVE);",
                   'set_fields_noalloc(status_slot, RDMA_SC_OK, )', "return 1'b1;")
        positions = [body.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertNotRegex(body, r"\b(?:acquire_lock|make_runtime_status|type_id|new)\b")

    def test_registered_characterization_uses_public_apis(self):
        """功能：固定独立专项、241 次四入口调用、公开 consumer 流程及锁/字段观察。
        输入输出及副作用：读取 package、manifest 和测试；不启动仿真。
        失败边界：漏注册、用内部清理替代公开调用、复跑父测试或删除关键矩阵均失败。
        """
        name = "rdma_runtime_recovery_retirement_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(
            f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$", (ROOT /
            "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        source = read_code(ROOT / f"tests/unit/{name}.sv")
        for marker in ("api < 4", "mode < 3", "flags < 8", "fault < 4", "cases != 241",
                       "runtime.complete_recovery_retry()", "runtime.abort_recovery()",
                       "runtime.recover(RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH)",
                       "runtime.complete_consumer_recovery_noalloc(release_now, status)",
                       "runtime.preserved_values()", "observer.recovery", "runtime.lock_tokens(",
                       "runtime.enter_recovery_prepared(pending)", "#1us;"):
            self.assertIn(marker, source)
        self.assertNotIn("retire_recovery_locked(", source)
        self.assertNotIn("super.run_phase", source)


if __name__ == "__main__":
    unittest.main()
