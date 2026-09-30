"""目录/层次：tests/unit；职责：固定 queue-data 未接管证据的单一业务移交阶段。
依赖：unittest、既有 SV 方法扫描器；静态结构检查不替代 runtime/factory 仿真。
所有权/生命周期：只读源码，不创建 owner、锁、证据或外部资源。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class UnclaimedRecoveryHandoffBoundaryTest(unittest.TestCase):
    """控制面先校验，移交成功后才继续 claimed/replay；失败不能提前删除证据。"""

    def bodies(self):
        """功能：读取唯一 engine 的公开恢复入口与内部移交阶段。
        输入输出及副作用：无输入，返回净化后的完整方法正文；只读。
        失败边界：方法缺失或重名即失败，不用空壳替代。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        return declared["recover_queue"][2], declared["handoff_unclaimed_device_recovery"][2]

    def test_single_borrowed_stage(self):
        """功能：固定同类 protected 同步阶段，以 ref 保持 caller 的 found/status 槽。
        输入输出及副作用：检查声明、唯一调用点与禁止的 owner/锁/I/O 操作。
        失败边界：新增公开入口、直接分配、延时、锁或重复 admission 校验时失败。
        """
        caller, stage = self.bodies()
        code = read_code(CORE / "rdma_queue_data_engine.sv")
        self.assertRegex(stage, r"^\s*protected function bit handoff_unclaimed_device_recovery\(")
        self.assertIn("ref rdma_queue_data_attachment found", stage)
        self.assertIn("ref rdma_status status", stage)
        self.assertEqual(code.count("handoff_unclaimed_device_recovery("), 2)
        self.assertEqual(caller.count("handoff_unclaimed_device_recovery("), 1)
        self.assertNotRegex(stage, r"\b(?:new|fork|join|semaphore|resize_lock|engine_lock|ensure_handle)\b")
        self.assertNotIn("replay_pending(", stage)
        self.assertNotIn("found = null;", stage)

    def test_control_gate_and_claimed_continuation(self):
        """功能：保持 handle/action/确认门禁先于移交，claimed 定位、授权和重放仍在 caller。
        输入输出及副作用：比较恢复入口关键语句顺序；不执行运行时操作。
        失败边界：先迁移再拒绝、忽略 terminal bit、先确认再取 pending 时失败。
        """
        caller, _ = self.bodies()
        markers = ["status = ensure_handle(", "if (!(action inside",
                   "!caller_confirmed_no_submit", "found = null;",
                   "handoff_unclaimed_device_recovery(", "find_claimed_recovery_attachment(",
                   "resolve_reservation_only_recovery(", "found.runtime.query_pending(",
                   "found.runtime.recover(", "replay_pending("]
        for marker in markers:
            self.assertIn(marker, caller)
        positions = [caller.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertRegex(caller, r"if \(!handoff_unclaimed_device_recovery\(\s*"
                         r"queue_h, action, found, status\)\)\s*return;")
        self.assertNotIn("unclaimed_device_recoveries", caller)
        self.assertIn("found != null && found != claimed_found", caller)

    def test_admission_and_atomic_pair_retirement(self):
        """功能：固定 pair/身份检查、admission、reservation/state 查询及 detach 后成对删除。
        输入输出及副作用：读取阶段分支；验证 fallback abort 终止，成功移交继续。
        失败边界：先删再接管、拆开两表删除、漏 cursor/state 门禁或误继续 abort 时失败。
        """
        _, stage = self.bodies()
        markers = ["!unclaimed_device_recoveries.exists(key)",
                   "!value_ops::attachment_matches_queue_identity(found, queue_h)",
                   "status = admit_device_publish_recovery(found, unclaimed_pending);",
                   "if (action == RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH)",
                   "found.runtime.query_device_reservation(", "found.runtime.query_state(",
                   "runtime_state == RDMA_QUEUE_RUNTIME_ACTIVE",
                   "value_ops::same_cursor_value(reservation, unclaimed_pending.cursor)",
                   "status = detach_recovery_transaction("]
        for marker in markers:
            self.assertIn(marker, stage)
        positions = [stage.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        pair = (r"unclaimed_device_recoveries.delete\(key\);\s*"
                r"unclaimed_recovery_attachments.delete\(key\);")
        self.assertEqual(len(re.findall(pair, stage)), 2)
        self.assertEqual(stage.count(".delete("), 4)
        self.assertRegex(stage, r"if \(!status.ok\(\)\) return 1'b0;\s*" + pair + r"\s*return 1'b0;")
        self.assertRegex(stage, pair + r"\s*end\s*return 1'b1;\s*endfunction\s*$")
        self.assertEqual(stage.count("return 1'b1;"), 1)
        self.assertNotRegex(stage, r"return\s*;")

    def test_public_characterization_registration(self):
        """功能：固定 104 次公开调用专项的注册及真实 reservation/admission 测试路径。
        输入输出及副作用：读取 package、manifest 与独立专项；不运行仿真。
        失败边界：漏注册、直接测新 helper、覆盖 recover_queue 或复跑父测试时失败。
        """
        name = "rdma_unclaimed_recovery_handoff_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(f'"unit/{name}.sv"'), 1)
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        self.assertEqual(len(re.findall(rf"^  {name}$", manifest, re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        self.assertIn("completed 104 unclaimed recovery calls", test)
        self.assertIn("runtime.reserve_device_producer(cursor)", test)
        self.assertIn("super.admit_device_publish_recovery(attachment, prepared_pending)", test)
        self.assertIn("engine.recover_queue(", test)
        self.assertNotIn("handoff_unclaimed_device_recovery(", test)
        self.assertNotIn("super.run_phase", test)
        self.assertNotRegex(test, r"\btask recover_queue\(")


if __name__ == "__main__":
    unittest.main()
