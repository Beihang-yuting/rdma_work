"""目录/层次：tests/unit；职责：固定 CEQ/AEQ 事件轮询准备阶段的职责边界。
依赖：unittest、SV 词法扫描器和既有 event route 公共专项；只读源码，不创建仿真资源。
所有权/生命周期：准备阶段只借用 attachment/runtime/backing，consumer owner 仍归 engine。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class EventPollPrepareBoundaryTest(unittest.TestCase):
    """CEQ/AEQ 共享读取与解码，route、doorbell、commit 和 recovery 仍由 caller 决定。"""

    def bodies(self):
        """功能：读取 event preparation 与两个单次 poll caller 的净化正文。
        输入输出及副作用：无输入，返回三个完整方法正文；只读源码。
        失败边界：方法缺失或重复由扫描器报错，不使用空正文替代。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        return (declared["prepare_event_poll_entry"][2],
                declared["poll_ceqe_once"][2],
                declared["poll_aeqe_once"][2])

    def test_preparation_is_one_protected_stage(self):
        """功能：要求阶段按 lookup→peek→read→image→decode 顺序工作。
        输入输出及副作用：检查 protected task、输出槽清零及准备阶段调用；只读。
        失败边界：新增公开 API、独立 owner/锁、consumer mutation 或漏掉清零输出时失败。
        """
        stage, _, _ = self.bodies()
        self.assertRegex(stage, r"^\s*protected task prepare_event_poll_entry\(")
        for marker in ("output rdma_queue_data_attachment attachment",
                       "output rdma_queue_cursor_snapshot cursor",
                       "output rdma_hw_image entry_image",
                       "output rdma_hw_model decoded_model",
                       "output longint unsigned offset",
                       "output rdma_status status"):
            self.assertIn(marker, stage)
        markers = ["attachment = null;", "cursor = null;",
                   "entry_image = null;", "decoded_model = null;", "offset = 0;",
                   "status = null;", "lookup_attachment(", "peek_consumer(",
                   "attachment.access.read(", "make_entry_image(",
                   "decode_event_image("]
        positions = [stage.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertNotRegex(stage, r"\b(?:fork|join|semaphore|lock\.\w+|mmio_write|commit_)\b")
        self.assertNotIn("make_next_poll_cursor_nonfatal(", stage)
        self.assertNotIn("consume_routed_event(", stage)

    def test_route_epoch_is_explicit_policy_and_caller_owns_mutation(self):
        """功能：固定 AEQ 的 route/epoch gate 作为参数策略，CEQ/AEQ caller 保留类型化 owner。
        输入输出及副作用：读取阶段与两个 caller 的调用/后续正文；无外部副作用。
        失败边界：把 route resolver、consumer commit 或 recovery 移入共享阶段时失败。
        """
        stage, ceq, aeq = self.bodies()
        self.assertIn("input bit check_route_epoch", stage)
        self.assertRegex(stage, r"if \(check_route_epoch\) begin\s*"
                         r"status = validate_attachment_route_epoch\(attachment\);")
        self.assertRegex(ceq, r"RDMA_IMAGE_CEQE,\s*,\s*1'b0")
        self.assertRegex(aeq, r"RDMA_IMAGE_AEQE,\s*,\s*1'b1")
        self.assertEqual(ceq.count("prepare_event_poll_entry("), 1)
        self.assertEqual(aeq.count("prepare_event_poll_entry("), 1)
        self.assertIn("lookup_event_cq_route_for_poll(", ceq)
        self.assertIn("resolve_aeqe_routes(", aeq)
        self.assertIn("make_next_poll_cursor_nonfatal(", ceq)
        self.assertIn("make_next_poll_cursor_nonfatal(", aeq)
        self.assertIn("consume_routed_event(", ceq)
        self.assertIn("consume_routed_event(", aeq)
        self.assertNotIn("lookup_event_cq_route_for_poll(", stage)
        self.assertNotIn("resolve_aeqe_routes(", stage)
        self.assertNotIn("consume_routed_event(", stage)

    def test_public_event_characterization_remains_unchanged(self):
        """功能：确认已有 44-case event route 专项仍只调用公开 CEQ/AEQ poll 入口。
        输入输出及副作用：读取既有专项源码、package 和 core manifest；只读。
        失败边界：直接调用新阶段、删除 44-case 标记、漏注册既有专项时失败。
        """
        name = "rdma_queue_event_route_consume_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        self.assertEqual(package.count(f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$", manifest, re.M)), 1)
        self.assertIn("completed 44 event prepare cases", test)
        self.assertGreaterEqual(test.count("fixture.engine.poll_ceqe("), 3)
        self.assertGreaterEqual(test.count("fixture.engine.poll_aeqe("), 3)
        self.assertNotIn("prepare_event_poll_entry(", test)
        self.assertNotRegex(test, r"\btask\s+poll_(?:ceqe|aeqe)_once\(")


if __name__ == "__main__":
    unittest.main()
