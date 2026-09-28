"""目录/层次：tests/unit；职责：守卫 host producer 七类未提交失败共用出口的业务边界。
依赖：unittest、既有 SV 词法扫描器；只读结构门禁不替代真实 factory/I/O/recovery 仿真。
所有权与生命周期：不创建仿真资源，不修改被测文件或外部依赖。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class HostProducerExitBoundaryTest(unittest.TestCase):
    """统一恢复调用，不把不同阶段的 MMIO bit、诊断或已提交旁路合并成同一策略。"""

    def test_seven_failures_share_one_installer(self):
        """功能：固定七个失败 break 只进入一次原 recovery installer，不引入第二事务 owner。
        输入输出及副作用：读取 tail 的单次循环、break 与共同尾段；只读。
        失败边界：重复 installer、跨调用 disable、删除失败点或自行安装 runtime pending 均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["complete_host_producer_tail"][2]
        self.assertEqual(body.count("do begin : host_producer_io"), 1)
        self.assertEqual(body.count("break;"), 7)
        self.assertEqual(body.count("install_host_producer_recovery("), 1)
        self.assertNotRegex(body, r"\bdisable\b|\.enter_recovery\w*\(")
        tail = body.split("end while (1'b0);", 1)[1]
        self.assertRegex(tail, r"^\s*install_host_producer_recovery\(\s*"
                         r"attachment, queue_h, kind, cursor, offset, image, snapshot, signaled,\s*"
                         r"reservation_route, reservation_epoch, reservation_route_valid,\s*"
                         r"reservation_epoch_valid, recovery_mmio_maybe_submitted,\s*"
                         r"recovery_failure_label, status\);\s*endtask\s*$")

    def test_gate_without_prior_write_does_not_recover(self):
        """功能：入口 gate 在没有先前 SGB write 时直接拒绝，有副作用时才进入 NO_SUBMIT 恢复。
        输入输出及副作用：检查循环首段的 gate、null 归一化与 prior_host_write 分支；只读。
        失败边界：纯拒绝改为 pending、先写 WQE 再 gate、或默认 MMIO bit 改为 true 均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["complete_host_producer_tail"][2]
        gate = body.split("status = write_and_verify(", 1)[0]
        self.assertIn("recovery_mmio_maybe_submitted = 1'b0;", gate)
        self.assertIn("recovery_failure_label = write_failure_label;", gate)
        self.assertRegex(gate, r"status = validate_host_producer_reservation_window\(attachment, cursor\);")
        self.assertRegex(gate, r"if \(!prior_host_write\)\s+return;\s+break;\s+end\s*$")

    def test_failure_labels_and_mmio_stages_stay_distinct(self):
        """功能：锁定 result/handle/next 的原标签和 doorbell/commit 的 AMBIGUOUS bit。
        输入输出及副作用：统计诊断选择点，并把 bit=1 限定在两类后期失败中；只读。
        失败边界：错误标签混用、write 阶段标记 ambiguous，或提前标记 doorbell 成功时失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["complete_host_producer_tail"][2]
        labels = re.findall(r"recovery_failure_label = (\w+);", body)
        self.assertEqual(labels, ["write_failure_label", "result_name", "result_name",
                                  "next_name", "doorbell_failure_label", "commit_failure_label"])
        self.assertEqual(len(re.findall(r"recovery_mmio_maybe_submitted = 1'b1;\s*"
                                       r"recovery_failure_label = (?:doorbell|commit)_failure_label;\s*"
                                       r"break;", body)), 2)
        self.assertEqual(body.count("recovery_mmio_maybe_submitted = 1'b1;"), 2)

    def test_success_and_postcommit_failure_bypass_recovery(self):
        """功能：保证 ledger 已提交后只交付结果或保留直接失败，不回到未提交 installer。
        输入输出及副作用：检查候选字段填充后的无分配 status 与直接 return；只读。
        失败边界：已提交结果失败使用 break、成功落入尾段或用 factory 替代 make_direct 均失败。
        """
        body = methods(read_code(CORE / "rdma_queue_data_engine.sv"))["complete_host_producer_tail"][2]
        committed = body.split("result_candidate.wr_id = wr_id;", 1)[1].split("end while", 1)[0]
        self.assertNotIn("break;", committed)
        self.assertIn("result_candidate.status = rdma_status::make_direct(RDMA_SC_OK);", committed)
        self.assertEqual(committed.count("return;"), 2)
        self.assertRegex(committed, r"result = result_candidate;\s*status = result_candidate.status;"
                         r"\s*return;\s*$")

    def test_business_order_and_replay_remain_separate(self):
        """功能：守卫 gate→write→result→handle→next→doorbell→commit 顺序，保持 replay 的幂等门独立。
        输入输出及副作用：读取 tail、installer 与 replay 的关键调用；只读。
        失败边界：重排 factory/I/O、installer 丢失 route 覆盖或让 replay 再调用 live tail 即失败。
        """
        declared = methods(read_code(CORE / "rdma_queue_data_engine.sv"))
        body = declared["complete_host_producer_tail"][2]
        steps = ("validate_host_producer_reservation_window(", "write_and_verify(",
                 "value_ops::factory_create_object_nonfatal(", "clone_pending_handle_value(",
                 "make_next_poll_cursor_nonfatal(", "submit_producer_doorbell(",
                 "commit_host_producer_ledger(", "result_candidate.wr_id = wr_id;")
        positions = [body.index(step) for step in steps]
        self.assertEqual(positions, sorted(positions))
        installer = declared["install_host_producer_recovery"][2]
        self.assertLess(installer.index("value_ops::apply_host_producer_pending_route_epoch("),
                        installer.index("admit_host_producer_recovery("))
        replay = declared["replay_host_producer_pending"][2]
        self.assertNotIn("complete_host_producer_tail(", replay)
        self.assertIn("enable_recovery_commit(", replay)
        self.assertIn("complete_recovery_retry(", replay)

    def test_real_queue_fault_matrix_is_registered(self):
        """功能：确保独立矩阵用真实 SQ/RQ/SRQ、SGB 与公开恢复覆盖七个出口和未接管失败。
        输入输出及副作用：读取 package/manifest 顺序及测试关键断言；只读。
        失败边界：漏注册、SRQ helper 前置未满足、漏计数/阶段/确认/资源回收断言均失败。
        """
        name = "rdma_host_producer_exit_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        entry = f'`include "unit/{name}.sv"'
        self.assertEqual(package.count(entry), 1)
        self.assertLess(package.index('`include "unit/rdma_queue_data_engine_poll_test.sv"'),
                        package.index(entry))
        core = manifest.split("readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        test = " ".join(read_code(ROOT / f"tests/unit/{name}.sv").split())
        for contract in ("create_shared_srq_poll_route(", "destroy_shared_srq_poll_route(",
                         "complete_host_producer_tail(", "write_sgb_and_verify(",
                         "factory.pending_creates != (recovery ? 1 : 0)",
                         "probe.admission_calls != (recovery && !fail_pending ? 1 : 0)",
                         "pending.route != probe.frozen_route", "pending.reset_epoch != probe.frozen_epoch",
                         "RDMA_QUEUE_RECOVERY_RETRY_PENDING, 1'b0", "fixture.mem.live_allocations() != 0"):
            self.assertIn(contract, test)


if __name__ == "__main__":
    unittest.main()
