"""目录/层次：tests/unit；职责：守卫 shutdown 单出口和释放失败保留顺序。
依赖：unittest 与只读 SV 方法扫描；不替代 VCS 的释放回调/状态/重试验证。
所有权/生命周期：不创建 engine、adapter 或账本，不写工作树。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CmqShutdownDeliveryBoundaryTest(unittest.TestCase):
    """关闭期间始终持原锁，错误保留和成功清理分别有唯一业务出口。"""

    def body(self):
        """功能：读取 shutdown 的完整净化正文供结构断言。
        输入输出及副作用：无参数；返回只读文本，不运行 SV。
        失败边界：方法缺失或重名由扫描器拒绝，不使用空正文替代。
        """
        return methods(read_code(CORE / "rdma_cmq_engine.sv"))["shutdown"][2]

    def test_one_lock_exit_without_nested_control(self):
        """功能：固定单次业务段、六个 break 和唯一最终解锁。
        输入输出及副作用：读取正文与锁位置；不影响仿真。
        失败边界：增加内层循环/return/disable 或改变锁窗口即失败。
        """
        body = self.body()
        prefix, work = body.split("do begin : shutdown_transaction")
        work, tail = work.split("end while (1'b0);")
        self.assertEqual(prefix.count("engine_lock.get(1);"), 1)
        self.assertEqual(body.count("engine_lock.get(1);"), 1)
        self.assertEqual(body.count("engine_lock.put(1);"), 1)
        self.assertEqual(" ".join(tail.split()), "engine_lock.put(1); endtask")
        self.assertEqual(work.count("break;"), 6)
        self.assertNotRegex(work, r"\b(?:do|while|for|foreach|repeat|forever|return|disable|fork)\b")

    def test_admission_cancel_discard_release_order(self):
        """功能：固定 gate、空引擎、状态准入、best-effort cancel、FIFO 丢弃、release 顺序。
        输入输出及副作用：读取关键调用位置；不调用生产 helper 自证。
        失败边界：gate 之前清配置、改成严格 cancel 或在清 FIFO 前 release 均失败。
        """
        body = self.body()
        markers = ["reset_release_gate_status()", "RDMA_CMQ_ENGINE_UNCONFIGURED",
                   "engine_state inside", "cancel_generation_locked(",
                   "terminal_fifo.delete();", "diagnostic_fifo.delete();",
                   "late_final_fifo.delete();", "backing_mapping == null || host_mem == null",
                   "if (backing_release_opaque)", "host_mem.release_opaque(backing_mapping)"]
        positions = [body.index(marker) for marker in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertRegex(body, r"cancel_generation_locked\(\s*prepared_binding.generation, 1'b1\s*\)")
        self.assertEqual(body.count("clear_configuration();"), 2)

    def test_release_failure_is_one_authority_preservation(self):
        """功能：固定 null/非 OK 共用原 authority 保留；仅 null 构造新诊断。
        输入输出及副作用：检查两种 adapter 赋值、保留调用与状态构造次序。
        失败边界：非 OK 被快照/重建、丢失 opaque 位、空 authority 被冒认可释放均失败。
        """
        body = self.body()
        self.assertIn("status = host_mem.release_opaque(backing_mapping);", body)
        self.assertIn("status = host_mem.\\release (backing_mapping);", body)
        self.assertEqual(body.count("retain_release_authority("), 2)
        self.assertIn("retain_release_authority(backing_mapping, host_mem);", body)
        self.assertRegex(body, r"if \(status == null \|\| !status.ok\(\)\) begin\s*"
                         r"retain_release_authority\(backing_mapping, host_mem,\s*backing_release_opaque\);\s*"
                         r"if \(status == null\)\s*status = invalid_state\(\s*\);\s*break;")
        self.assertNotRegex(body, r"\b(?:release_status|snapshot|clone|new)\b")

    def test_independent_public_matrix_registered(self):
        """功能：检查 30 场景专项注册，且只从公开 shutdown 驱动真实清理。
        输入输出及副作用：只读 package、manifest 和专项源码。
        失败边界：漏注册、删除 adapter 锁断言、authority/journal 检查或直接调用内部清理则失败。
        """
        name = "rdma_cmq_shutdown_delivery_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$",
                         (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        for marker in ("completed 30 CMQ shutdown scenarios", "engine.shutdown(status);",
                       "engine.lock_tokens(0)", "engine.lock_tokens(1)", "engine.journal_preserved()",
                       "engine.retained_authority(mem, opaque)", "status != mem.failure"):
            self.assertIn(marker, test)
        for forbidden in ("super.run_phase", "retain_release_authority(", "clear_configuration("):
            self.assertNotIn(forbidden, test)


if __name__ == "__main__":
    unittest.main()
