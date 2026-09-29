"""目录/层次：tests/unit；职责：守卫 barrier 限时能力与门铃发布业务的边界。
依赖：unittest、既有 SV scanner；只读源码，动态取消和 deadline 仍由 VCS 验证。
所有权与生命周期：不创建 adapter、不访问远端，不保存业务状态或修改输入。
"""

import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class DoorbellBarrierBoundaryTest(unittest.TestCase):
    """只有 barrier 共用 worker/timer；MMIO 可见性与 Function 锁仍由原业务层负责。"""

    def declared(self):
        """功能：只提取 scheduler 方法，排除同文件值类的同名 new/do_copy。
        输入输出及副作用：无输入，读取 scheduler 并返回方法表；只读。
        失败边界：类声明缺失或出现重名方法时直接失败，不返回不完整方法集。
        """
        code = read_code(CORE / "rdma_doorbell_scheduler.sv")
        return methods(code.split("class rdma_doorbell_scheduler extends", 1)[1])

    def test_one_barrier_execution_path(self):
        """功能：要求两个 barrier 共用一个执行入口，删除旧 helper 而非保留转发壳。
        输入输出及副作用：扫描方法表与 shared task，核对每种 PCIe barrier 只有一个调用。
        失败边界：旧 helper 重现、缺少分派分支或新增 barrier 调用均失败。
        """
        declared = self.declared()
        self.assertNotIn("dma_barrier_before_deadline", declared)
        self.assertNotIn("mmio_barrier_before_deadline", declared)
        shared = declared["barrier_before_deadline"][2]
        self.assertIn("bit dma_visibility", shared)
        for method in ("dma_visibility_barrier", "mmio_ordering_barrier"):
            self.assertEqual(shared.count(f"pcie.{method}(function_h, worker_status)"), 1)
        self.assertEqual(declared["submit_locked"][2].count("barrier_before_deadline("), 2)

    def test_cancellation_scope_is_invocation_local(self):
        """功能：固定两层 fork 的取消域，避免一个 barrier 超时误杀同 task 的并发调用。
        输入输出及副作用：读取 shared task 的 worker/timer 与 join 结构；只读。
        失败边界：取消移到外层、使用具名 disable、共享完成位或增加后台线程时失败。
        """
        body = self.declared()["barrier_before_deadline"][2]
        self.assertRegex(body, r"fork\s+begin\s*:\s*barrier_deadline_scope\s+fork")
        self.assertRegex(body, r"join_any\s+disable fork;\s+end\s+join")
        self.assertEqual(body.count("disable fork;"), 1)
        self.assertNotRegex(body, r"disable\s+(?!fork\b)\w+")
        self.assertIn("worker_done = 1'b0;", body)
        self.assertIn("worker_done = 1'b1;", body)
        self.assertIn("bit worker_done;", body)

    def test_one_remaining_budget_and_original_diagnostics(self):
        """功能：保持 deadline 只计算一次剩余预算，入口拒绝/等待超时及空状态各有原诊断。
        输入输出及副作用：读取 shared task 和字符串，不调用仿真或时间服务。
        失败边界：重置总预算、删除 timer、吞掉后端 status 或改变两类诊断时失败。
        """
        body = self.declared()["barrier_before_deadline"][2]
        self.assertEqual(body.count("deadline_remaining(deadline, remaining)"), 1)
        self.assertIn("#(remaining);", body)
        self.assertEqual(body.count("status = timeout_status(operation);"), 2)
        self.assertIn("status = worker_status;", body)
        self.assertNotRegex(body, r"\bdeadline\s*=")
        source = (CORE / "rdma_doorbell_scheduler.sv").read_text()
        for message in ("DMA visibility barrier", "MMIO ordering barrier",
                        "PCIe DMA barrier returned null status",
                        "PCIe MMIO barrier returned null status"):
            self.assertIn(f'"{message}"', source)

    def test_effect_and_write_stay_outside_barrier_helper(self):
        """功能：限制 shared task 为 barrier 能力，不取得 effect、observer、Function lock 或 MMIO 写入权。
        输入输出及副作用：检查 helper 禁用标识符以及 submit_locked 的显式二态选择。
        失败边界：混入 MMIO write、factory、owner/账本字段或颠倒 DMA/MMIO 顺序时失败。
        """
        declared = self.declared()
        body = declared["barrier_before_deadline"][2]
        self.assertNotRegex(body, r"\b(?:submission_effect|observer|function_locks|host_mem|"
                                r"mmio_write|factory|type_id|semaphore)\b")
        submit = declared["submit_locked"][2]
        self.assertLess(submit.index(".dma_visibility(1'b1)"),
                        submit.index(".dma_visibility(1'b0)"))
        self.assertLess(submit.index(".dma_visibility(1'b0)"), submit.index("mmio_write_before_deadline("))
        self.assertIn("RDMA_SUBMIT_EFFECT_HOST_MEMORY_ORDERED", submit)
        write = declared["mmio_write_before_deadline"][2]
        self.assertIn("observer.before_mmio_maybe_visible();", write)
        self.assertIn("RDMA_SUBMIT_EFFECT_MMIO_MAYBE_VISIBLE", write)

    def test_focused_test_is_registered_after_fixture(self):
        """功能：保证新专项复用已定义 fixture，并由完整 core exact-once 执行。
        输入输出及副作用：读取 package 和 core manifest，只检查 include/注册顺序。
        失败边界：漏注册、重复注册或子类先于父类声明时失败。
        """
        name = "rdma_doorbell_barrier_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        include = f'`include "unit/{name}.sv"'
        self.assertEqual(package.count(include), 1)
        self.assertLess(package.index('`include "unit/rdma_doorbell_scheduler_test.sv"'),
                        package.index(include))
        core = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text().split(
            "readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)

    def test_matrix_checks_late_workers_peer_and_lock_reuse(self):
        """功能：固定 23-case 策略/故障/总预算矩阵和取消后的动态证据，不允许只断言返回错误。
        输入输出及副作用：读取新 test；核对公共入口、延迟完成数、peer/sibling、锁重用与 watchdog。
        失败边界：删除关键维度/断言、调用 protected helper 替代业务入口或遗失 watchdog 时失败。
        """
        source = read_code(ROOT / "tests/unit/rdma_doorbell_barrier_test.sv")
        for token in ("p < 4", "stage <= 2", "mode <= 4", "cases != 23", "#2us;",
                      "scheduler.submit_observed(", "pcie.completed(a.function_uid) != 0",
                      "pcie.completed(b.function_uid) != 1", "!sibling_finished",
                      "a_finished_at - started_at != 5ns", "b_finished_at - started_at != 9ns",
                      "pcie.calls.size() != 5", "#10ns;", "result.status.convert2string()"):
            self.assertIn(token, source)
        self.assertNotIn("barrier_before_deadline(", source)


if __name__ == "__main__":
    unittest.main()
