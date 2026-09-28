"""目录/层次：tests/unit；职责：守卫设备发布准备值与取消、I/O、恢复的职责分界。
依赖：unittest 与既有 SV 词法扫描器；只读生产/测试源码，不替代 VCS 故障矩阵。
所有权与生命周期：不创建仿真对象、不修改文件或外部依赖。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class DevicePublishPrepareBoundaryTest(unittest.TestCase):
    """准备值是一次调用的局部记录，不是额外 factory 对象、owner 或事务状态机。"""

    def test_record_has_only_prepared_values(self):
        """功能：固定值记录只聚合六个原局部结果，不引入 runtime/access/锁或实例状态。
        输入输出及副作用：读取 engine 的 typedef 和使用位置；只读。
        失败边界：新增字段、factory 注册、改为 class 或方法外实例化该记录时失败。
        """
        code = read_code(CORE / "rdma_queue_data_engine.sv")
        record = re.search(r"typedef struct\s*\{([^{}]+)\}\s*device_publish_prepared_t;", code)
        self.assertIsNotNone(record)
        self.assertEqual(" ".join(record[1].split()),
                         "rdma_queue_pending_operation pending; "
                         "rdma_queue_device_publish_result candidate; rdma_hw_image detached_image; "
                         "rdma_handle detached_queue; byte data[]; string cancel_context;")
        for _, _, body in methods(code).values():
            code = code.replace(body, "")
        self.assertEqual(code.count("device_publish_prepared_t"), 1)

    def test_prepare_has_no_cancel_io_or_publication(self):
        """功能：限制准备函数只能校验/构造原有证据，取消、写入、提交与发布仍属于 caller。
        输入输出及副作用：检查函数返回 bit、output 值与禁用的操作；只读。
        失败边界：变为 task/公开接口、增加成功 status factory 或提前发布候选均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["prepare_device_publish"][2]
        self.assertRegex(body, r"^\s*protected function bit prepare_device_publish\(")
        self.assertIn("output device_publish_prepared_t prepared", body)
        for forbidden in ("finish_device_producer_cancel(", "enter_device_publish_recovery(",
                          ".write_device(", ".read(", ".commit_device_producer(",
                          "prepared.candidate.queue_h =", "result ="):
            self.assertNotIn(forbidden, body)
        self.assertRegex(body, r"return 1'b1;\s+endfunction\s*$")
        self.assertEqual(body.count("rdma_status::success("), 1)

    def test_ownership_precedes_cancel_permission(self):
        """功能：入口/geometry/reservation query/归属拒绝全部先返回，不能取消其它调用的槽位。
        输入输出及副作用：检查第一个非空 cancel_context 前的四个提前返回；只读。
        失败边界：跳过归属查询、提前授权取消或入口依赖 pending 非空来推断权限时失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["prepare_device_publish"][2]
        prefix = body.split("raw_next = value_ops::factory_create_object_nonfatal(", 1)[0]
        self.assertEqual(prefix.count("return 1'b0;"), 4)
        self.assertEqual(prefix.count("prepared.cancel_context ="), 1)
        self.assertIn("attachment.runtime.query_device_reservation(", prefix)
        self.assertIn("!value_ops::same_cursor_value(current_reservation, reservation)", prefix)

    def test_nine_cancellations_retain_evidence_distinction(self):
        """功能：固定九个准备失败续接，next/pending 失败传空证据，其余失败保留完整 pending。
        输入输出及副作用：读取所有 context/return 选择点并检查清空位置；只读。
        失败边界：遗漏续接、把残缺证据传给恢复，或清掉完整 pending 时失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["prepare_device_publish"][2]
        self.assertEqual(body.count("prepared.cancel_context ="), 10)
        self.assertEqual(body.count("return 1'b0;"), 13)
        self.assertEqual(body.count("prepared.pending = null;"), 3)
        self.assertEqual(len(re.findall(r"prepared.pending = null;\s*"
                                       r"prepared.cancel_context =\s*;\s*return 1'b0;", body)), 2)
        tail = body.split("prepared.pending = null;", 3)[3]
        self.assertNotRegex(tail, r"prepared.pending\s*=")

    def test_caller_uses_bit_and_one_prepare_cancel(self):
        """功能：caller 按 bit 完成标志而非 status.ok 决定是否继续，统一处理九类取消。
        输入输出及副作用：读取 I/O 前缀，核对取消参数和无条件早退；只读。
        失败边界：OK 但缺证据时继续 I/O、重复取消或丢失原 status/context 均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["write_commit_device_entry"][2]
        prefix = body.split("prepared.pending.device_write_attempted =", 1)[0]
        self.assertEqual(prefix.count("finish_device_producer_cancel("), 1)
        self.assertRegex(prefix, r"if \(!prepare_device_publish\(attachment, reservation, image, "
                         r"prepared, status\)\) begin\s+if \(prepared.cancel_context !=\s*\) begin\s+"
                         r"original_status = status;\s+finish_device_producer_cancel\(attachment, "
                         r"reservation, prepared.pending,\s+original_status, prepared.cancel_context, "
                         r"status\);\s+end\s+return;\s+end\s*$")
        self.assertNotIn("status.ok()", prefix)

    def test_prepare_fault_matrix_is_registered(self):
        """功能：确保三队列准备故障矩阵独立注册，覆盖真实取消、null/BUSY、retry 和 abort。
        输入输出及副作用：读取 package、core 清单与动态测试的关键断言；只读。
        失败边界：漏注册、取消未计数、漏零 I/O/信用/预留/证据/清理断言或取消故障未触发时失败。
        """
        name = "rdma_device_publish_prepare_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        self.assertEqual(package.count(f'`include "unit/{name}.sv"'), 1)
        core = manifest.split("readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        body = read_code(ROOT / f"tests/unit/{name}.sv")
        for contract in ("RDMA_QUEUE_RUNTIME_CQ, RDMA_QUEUE_RUNTIME_CEQ, RDMA_QUEUE_RUNTIME_AEQ",
                         "write_commit_device_entry(", "probe.cancel_calls != (entry_reject ? 0 : 1)",
                         "fixture.mem.calls.size() != calls_before", "!factory.fired",
                         "pending.device_write_attempted", "RDMA_QUEUE_MMIO_NO_SUBMIT",
                         "RDMA_QUEUE_RECOVERY_RETRY_PENDING", "RDMA_QUEUE_RECOVERY_ABORT_AND_DETACH",
                         "fixture.mem.live_allocations() != 0", "cancel_mode == 1",
                         "cancel_mode == 2", "runtime_ref.depth = 0", "source_image.length = 0"):
            self.assertIn(contract, " ".join(body.split()))


if __name__ == "__main__":
    unittest.main()
