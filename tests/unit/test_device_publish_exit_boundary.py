"""目录/层次：tests/unit；职责：守卫设备发布写后恢复出口与写前取消/重放之间的边界。
依赖：unittest、既有 SV 词法工具；只读结构检查不替代真实 VCS factory/I/O 故障测试。
所有权与生命周期：不创建仿真资源，不修改被测文件或任何外部依赖。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class DevicePublishExitBoundaryTest(unittest.TestCase):
    """只收束四类失败续接，不扩展成通用事务状态机或改变 backend-started 的意义。"""

    def test_four_failures_share_one_evidence_exit(self):
        """功能：要求四类写后失败选择诊断后进入唯一状态复制与 recovery 尾段。
        输入输出及副作用：读取 write_commit_device_entry，检查一次循环和四个选择点；只读。
        失败边界：增加重复复制、丢失失败点、命名块 disable 或尾段遗漏 recovery 均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["write_commit_device_entry"][2]
        self.assertEqual(body.count("do begin : device_publish_io"), 1)
        self.assertEqual(body.count("copy_publish_status_into("), 1)
        self.assertEqual(len(re.findall(r"failure_copy_message\s*=", body)), 5)
        self.assertNotRegex(body, r"\bdisable\b")
        tail = body.split("end while (1'b0);", 1)[1]
        self.assertIn("prepared.pending.failure_status.message = failure_copy_message;", tail)
        self.assertRegex(tail, r"enter_device_publish_recovery\(attachment, prepared.pending, original_status,"
                         r"\s+RDMA_QUEUE_MMIO_NOT_APPLICABLE, recovery_status\);"
                         r"\s+status = recovery_status;\s+endtask\s*$")

    def test_backend_not_started_keeps_two_distinct_exits(self):
        """功能：守卫未开始 backend 的真实错误取消与异常成功恢复，禁止合并为同一策略。
        输入输出及副作用：检查两个 backend_write_started 分支及其直接 return；只读。
        失败边界：取消落入写后尾段、异常成功增加前置复制或错走 cancel 均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["write_commit_device_entry"][2]
        io = body.split("do begin : device_publish_io", 1)[1]
        self.assertEqual(io.count("if (!backend_write_started) begin"), 2)
        self.assertRegex(io, r"if \(!backend_write_started\) begin\s+"
                         r"finish_device_producer_cancel\([^;]+;\s+return;\s+end")
        special = io.split("if (!backend_write_started) begin", 2)[2]
        special = special.split("status = attachment.access.read(", 1)[0]
        self.assertIn("enter_device_publish_recovery(", special)
        self.assertNotIn("copy_publish_status_into(", special)
        self.assertNotIn("finish_device_producer_cancel(", special)
        self.assertRegex(special, r"status = recovery_status;\s+return;\s+end\s*$")

    def test_first_mismatch_exits_both_loops(self):
        """功能：锁定首个字节不一致只产生一次原始错误，然后跳过 producer commit。
        输入输出及副作用：检查 foreach 内 break 与紧邻的外层诊断 gate；只读。
        失败边界：内层继续比较、漏外层 break、使用跨调用 disable 或提前 commit 即失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["write_commit_device_entry"][2]
        compare = body.split("foreach (readback[i]) begin", 1)[1]
        compare = compare.split("status = attachment.runtime.commit_device_producer(", 1)[0]
        self.assertEqual(compare.count("original_status = bad("), 1)
        self.assertEqual(compare.count("break;"), 2)
        self.assertRegex(compare, r"break;\s+end\s+end\s+"
                         r"if \(failure_copy_message !=\s*\)\s+break;\s*$")

    def test_write_read_commit_and_success_return_order(self):
        """功能：守卫 prepare→write→read→compare→commit→result 的原业务顺序与成功旁路。
        输入输出及副作用：分别比较准备函数和 I/O task 的步骤，检查成功在循环内直接返回；只读。
        失败边界：任何重排、成功落入 recovery、或把业务逻辑移到恢复尾段即失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        prepare = declared["prepare_device_publish"][2]
        steps = ("prepare_device_pending(", "copy_image_bytes(", "clone_publish_image(",
                 "clone_publish_handle(")
        positions = [prepare.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        body = declared["write_commit_device_entry"][2]
        steps = ("prepare_device_publish(", "attachment.access.write_device(",
                 "attachment.access.read(", "foreach (readback[i])",
                 "attachment.runtime.commit_device_producer(", "result = prepared.candidate;")
        positions = [body.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        self.assertRegex(body, r"result = prepared.candidate;\s+status = rdma_status::success\(\);"
                         r"\s+return;\s+end while \(1'b0\);")

    def test_second_copy_and_replay_remain_separate(self):
        """功能：保留 enter recovery 内第二次字段读取/复制，不让 live 收尾接管 replay 策略。
        输入输出及副作用：读取 recovery/replay 方法及复制 wrapper；只读，不模拟 factory。
        失败边界：删除第二复制、直接安装 pending、移入 replay 或把复制改为无 factory 即失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        enter = declared["enter_device_publish_recovery"][2]
        self.assertLess(enter.index("copy_publish_status_into("),
                        enter.index("admit_device_publish_recovery("))
        copy = declared["copy_publish_status_into"][2]
        self.assertIn("value_ops::copy_status_fields(source, destination)", copy)
        self.assertIn("return rdma_status::success();", copy)
        replay = declared["replay_device_producer_pending"][2]
        self.assertNotIn("write_commit_device_entry(", replay)
        self.assertIn("enable_recovery_commit(", replay)
        self.assertIn("complete_recovery_retry(", replay)

    def test_fault_matrix_is_registered(self):
        """功能：确保三种队列的 30-case 动态矩阵作为独立 core 测试执行。
        输入输出及副作用：读取 package/manifest 与测试中的 factory、锁和 cleanup 断言；只读。
        失败边界：漏注册、删队列/模式、绕过目标事务或去掉资源回收检查时失败。
        """
        name = "rdma_device_publish_exit_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        self.assertEqual(package.count(f'`include "unit/{name}.sv"'), 1)
        core = manifest.split("readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        test = read_code(ROOT / f"tests/unit/{name}.sv")
        for contract in ("mode < 10", "RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_RUNTIME_CEQ",
                         "RDMA_QUEUE_RUNTIME_AEQ", "write_commit_device_entry(",
                         "factory.copied_values[0] != factory.copied_values[1]",
                         "target_runtime.set_test_hold(1'b0)", "mem.live_allocations() != 0"):
            self.assertIn(contract, test)


if __name__ == "__main__":
    unittest.main()
