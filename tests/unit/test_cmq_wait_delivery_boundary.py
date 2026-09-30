"""目录/层次：tests/unit；职责：守卫 CMQ wait 两层退出及唯一轮询让锁窗口。
依赖：unittest 和 SV 方法扫描器；仅读取生产/测试注册，不替代动态并发验证。
所有权/生命周期：不创建引擎、锁、adapter 或可变账本，不写工作树。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CmqWaitDeliveryBoundaryTest(unittest.TestCase):
    """准入段与轮询的 break 都通向最终解锁，continue 只能进入下一轮观察。"""

    def body(self):
        """功能：提取 wait_for 的净化完整正文，供结构契约检查。
        输入输出及副作用：无参数，返回方法字符串；只读 engine。
        失败边界：缺失或重名由扫描器拒绝，不用空正文掩盖丢失入口。
        """
        return methods(read_code(CORE / "rdma_cmq_engine.sv"))["wait_for"][2]

    def test_two_level_exit_and_single_release_window(self):
        """功能：固定单次准入、原 forever、32 个退出及唯一 put/delay/get 窗口。
        输入输出及副作用：只读控制流与锁调用位置；不运行仿真。
        失败边界：新增循环改变 break/continue 目标、轮询后插入动作、加入 disable 或遗留 return 时失败。
        """
        body = self.body()
        self.assertEqual(body.count("break;"), 32)
        self.assertEqual(body.count("continue;"), 1)
        self.assertNotRegex(body, r"\b(?:for|foreach|repeat|fork|join|disable|return)\b")
        prefix, session = body.split("do begin : wait_session")
        work, tail = session.split("end while (1'b0);")
        admission, iteration = work.split("forever begin : wait_iteration")
        self.assertNotRegex(admission + iteration, r"\b(?:do|while|forever)\b")
        depth = 1
        for token in re.finditer(r"\b(?:begin|end)\b", iteration):
            depth += 1 if token.group() == "begin" else -1
            if depth == 0:
                self.assertEqual(iteration[token.end():].strip(), "")
                break
        else:
            self.fail("wait iteration has no matching end")
        self.assertEqual(prefix.count("engine_lock.get(1);"), 1)
        self.assertEqual(body.count("engine_lock.get(1);"), 2)
        self.assertEqual(body.count("engine_lock.put(1);"), 2)
        self.assertEqual(" ".join(tail.split()), "engine_lock.put(1); endtask")
        self.assertRegex(iteration, r"engine_lock.put\(1\);\s*#\(wait_time\);\s*"
                         r"engine_lock.get\(1\);\s*status = reset_release_gate_status\(\);")

    def test_retained_authority_and_timed_poll_order(self):
        """功能：固定 ticket 冻结、retained 优先和每轮 expiry/poll、deadline、让锁后重验顺序。
        输入输出及副作用：读取关键调用位置与次数；不修改 journal。
        失败边界：按返回 status 推断终态、漏重验或重排轮询/等待时失败。
        """
        body = self.body()
        self.assertLess(body.index("checked_completion_ticket_snapshot("),
                        body.index("locate_journal_item_by_ticket_locked("))
        _, iteration = body.split("forever begin : wait_iteration")
        markers = ["locate_journal_item_by_ticket_locked(",
                   "!ticket_has_engine_authority(ticket_snapshot)",
                   "expire_locked()", "poll_locked(poll_status)",
                   "remaining = ticket_snapshot.absolute_deadline - $time;", "#(wait_time);"]
        positions = [iteration.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(body.count("locate_journal_item_by_ticket_locked("), 5)
        self.assertLess(body.index("#(wait_time);"), body.rindex("locate_journal_item_by_ticket_locked("))
        self.assertIn("wait_time = (remaining < 1ns) ? remaining : 1ns;", body)

    def test_retained_and_legacy_delivery_remain_distinct(self):
        """功能：固定三处 retained 投影的消费策略与 legacy FIFO 原对象转移。
        输入输出及副作用：只读 helper 调用、FIFO 操作及输出赋值。
        失败边界：reset 竞争分支消费 FIFO、legacy 被改成重复快照或 wait 重发命令时失败。
        """
        body = self.body()
        self.assertEqual(body.count("project_wait_retained_completion_locked("), 3)
        self.assertRegex(body, r"project_wait_retained_completion_locked\(\s*"
                         r"current_batch, current_item, ticket_snapshot, 1'b0,")
        self.assertEqual(body.count("terminal_fifo.delete(fifo_index);"), 1)
        self.assertIn("completion = terminal_fifo[fifo_index];", body)
        self.assertNotRegex(body, r"\b(?:transport|scheduler|submit_observed|submit_batch_observed)\b")

    def test_public_matrix_registration_and_concurrency(self):
        """功能：固定 31 场景/65 次 wait 的独立注册和公开并发调用。
        输入输出及副作用：只读 package、manifest 与专项；不复用内部 projector 自证。
        失败边界：删除双等待者、等待期注入、修复再试、锁清理或漏注册时失败。
        """
        name = "rdma_cmq_wait_delivery_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$",
                         (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        for marker in ("completed 31 CMQ wait scenarios and 65 calls", "#100ps;",
                       "engine.wait_for(ticket, completion, status);", "check_concurrent_waiters();",
                       "engine.wait_for(submitted.ticket, first_completion, first_status);",
                       "engine.wait_for(submitted.ticket, second_completion, second_status);",
                       "engine.restore_fixture();", "wait_calls != 65"):
            self.assertIn(marker, test)
        self.assertNotIn("project_wait_retained_completion_locked(", test)
        self.assertNotIn("super.run_phase", test)


if __name__ == "__main__":
    unittest.main()
