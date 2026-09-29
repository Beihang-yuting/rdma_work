"""目录/层次：tests/unit；职责：固定 CMQ reconcile 的锁出口和非终态交付边界。
依赖：unittest 与 SV 方法扫描器；仅读取源码，不代替动态失败/回调/超时验证。
所有权/生命周期：不创建引擎、锁或外部资源，不改写工作树。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CmqReconcileDeliveryBoundaryTest(unittest.TestCase):
    """统一的是锁和状态交付，保留 retained-first 与 current-runtime-only poll 策略。"""

    def bodies(self):
        """功能：读取 reconcile 入口与 retained projector 的净化正文。
        输入输出及副作用：无参数，返回两个方法字符串；仅只读 engine 文件。
        失败边界：方法缺失或重复由扫描器/索引拒绝，不以空正文代替。
        """
        found = methods(read_code(CORE / "rdma_cmq_engine.sv"))
        return found["reconcile_ticket"][2], found["project_reconciled_journal_item_locked"][2]

    def test_single_lock_exit_without_nested_loop(self):
        """功能：要求十个早退只退出单次观察段，成功/失败均共用唯一解锁。
        输入输出及副作用：只读控制结构、锁调用次数和尾部；无仿真副作用。
        失败边界：新增内层循环改变 break 含义、增加取放锁或遗漏统一出口时失败。
        """
        caller, _ = self.bodies()
        self.assertEqual(caller.count("engine_lock.get(1);"), 1)
        self.assertEqual(caller.count("engine_lock.put(1);"), 1)
        self.assertEqual(caller.count("break;"), 10)
        self.assertNotRegex(caller, r"\b(?:foreach|forever|for|fork|join|disable|return)\b")
        prefix, body = caller.split("do begin : reconcile_observation")
        transaction, tail = body.split("end while (1'b0);")
        self.assertIn("engine_lock.get(1);", prefix)
        self.assertNotIn("engine_lock", transaction)
        self.assertNotRegex(transaction, r"\b(?:do|while)\b")
        self.assertEqual(" ".join(tail.split()), "engine_lock.put(1); endtask")

    def test_retained_first_and_live_poll_sequence(self):
        """功能：固定 gate、冻结 ticket、journal 定位、live authority、expire/poll 与重读顺序。
        输入输出及副作用：只读关键调用位置和次数。
        失败边界：将终态查询绑定当前 runtime、提前 poll、遗漏重读或用 status.ok 推断终态时失败。
        """
        caller, _ = self.bodies()
        markers = ["reset_release_gate_status()", "try_snapshot_optional_ticket(",
                   "locate_journal_item_by_ticket_locked(", "if (pending_active)",
                   "!ticket_has_engine_authority(ticket_snapshot)", "expire_locked()",
                   "poll_locked(helper_status)"]
        positions = [caller.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(caller.count("expire_locked()"), 1)
        self.assertEqual(caller.count("poll_locked(helper_status)"), 1)
        self.assertEqual(caller.count("locate_journal_item_by_ticket_locked("), 2)
        self.assertLess(caller.rindex("locate_journal_item_by_ticket_locked("),
                        caller.index("project_reconciled_journal_item_locked("))
        self.assertNotRegex(caller, r"terminal_known\s*=\s*[^;]*\.ok\(")
        self.assertNotIn("submit_observed(", caller)

    def test_single_nonterminal_snapshot_keeps_host_priority(self):
        """功能：固定 host/pending 共用一次状态快照，host 验证优先于 pending，终态另行投影。
        输入输出及副作用：读取分支结构和输出提交顺序；无状态修改。
        失败边界：未区分 NONE/PENDING phase、共用 completion/FIFO 消费或终态提前置位时失败。
        """
        _, projector = self.bodies()
        self.assertEqual(projector.count("snapshot_retained_operation_status_locked("), 1)
        self.assertEqual(projector.count("snapshot_retained_completion_locked("), 1)
        self.assertRegex(projector, r"if \(journal_item.state == "
                         r"RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED \|\|\s*pending_active\) begin\s*"
                         r"if \(journal_item.state == RDMA_CMQ_SUBMISSION_HOST_VISIBLE_NOT_PUBLISHED\) begin")
        self.assertIn("journal_item.completion_phase != RDMA_CMQ_COMPLETION_NONE", projector)
        self.assertIn("journal_item.completion_phase != RDMA_CMQ_COMPLETION_PENDING", projector)
        self.assertLess(projector.index("snapshot_retained_completion_locked("),
                        projector.index("terminal_known = 1'b1;"))
        self.assertNotRegex(projector, r"\b(?:engine_lock|terminal_fifo|transport|scheduler)\b")

    def test_public_characterization_registration(self):
        """功能：固定 25 场景/63 查询矩阵的独立注册及真实公开入口调用。
        输入输出及副作用：只读 package、manifest 与测试原文。
        失败边界：漏注册、调用内部 projector 自证、删除重复查询/FIFO/实际超时或运行父矩阵时失败。
        """
        name = "rdma_cmq_reconcile_delivery_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$",
                         (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        for marker in ("completed 25 CMQ reconcile scenarios and 63 queries",
                       "engine.reconcile_ticket(ticket, terminal_known, completion, status);",
                       "repeat (2)", "engine.seed_terminal_completion(", "#5ns;",
                       "engine.restore_fixture();", "query_calls != 63"):
            self.assertIn(marker, test)
        self.assertNotIn("project_reconciled_journal_item_locked(", test)
        self.assertNotIn("super.run_phase", test)


if __name__ == "__main__":
    unittest.main()
