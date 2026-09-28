"""目录/层次：tests/unit；职责：守卫 runtime 值投影与锁/账本 owner 的依赖分界。
依赖：unittest 与既有 SV 词法扫描器；只读门禁不代替真实 factory/recovery 仿真。
所有权/生命周期：不构造运行对象，不修改源码或外部依赖。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class RuntimeProjectorBoundaryTest(unittest.TestCase):
    """值复制不接管 mutable ledger；保留 status fallback 和原 factory callback 边界。"""

    def test_projector_has_no_instance_state(self):
        """功能：固定二十个迁移值方法和公开 cursor 比较实现为无实例的 static automatic 集合。
        输入输出及副作用：移除方法正文后比较类壳，只读取源码。
        失败边界：新增字段、锁、注册、继承或非 automatic 方法均拒绝。
        """
        code = read_code(CORE / "rdma_queue_runtime_projector.sv")
        declared = methods(code)
        self.assertEqual(len(declared), 21)
        lines = code.splitlines(keepends=True)
        for start, end, body in declared.values():
            self.assertRegex(body.lstrip(), r"^static function automatic\b")
            lines[start - 1:end] = ["\n"] * (end - start + 1)
        self.assertEqual(" ".join("".join(lines).split()),
                         "class rdma_queue_runtime_projector; endclass")

    def test_projector_cannot_reach_owner(self):
        """功能：禁止值层依赖 runtime/engine/adapter 或读写其锁、ledger 和当前 PI/CI。
        输入输出及副作用：检查净化源码中的类型和成员调用，只读。
        失败边界：反向 owner 引用、隐藏实例或 admission/query/commit/lock 调用均失败。
        """
        code = read_code(CORE / "rdma_queue_runtime_projector.sv")
        forbidden = set("""rdma_queue_runtime rdma_queue_data_engine rdma_resource_manager
            rdma_host_mem_api rdma_doorbell_scheduler lock semaphore slots pending_operation_state
            device_reservation host_produced producer_index consumer_index depth used registry""".split())
        self.assertFalse(set(re.findall(r"\b\w+\b", code)) & forbidden)
        self.assertNotRegex(code, r"\.\s*(?:query_\w+|commit_\w+|enter_recovery|try_get|put)\s*\(")

    def test_runtime_keeps_owner_and_only_public_cursor_wrapper(self):
        """功能：检查 runtime 仅以类型别名调用值层，公开 cursor_equal 兼容入口保留。
        输入输出及副作用：对照两类全部声明与调用，读取原锁和恢复门禁。
        失败边界：重复 protected 转发壳、未限定值调用或迁出 mutable admission 时失败。
        """
        projector = methods(read_code(CORE / "rdma_queue_runtime_projector.sv"))
        code = read_code(CORE / "rdma_queue_runtime.sv")
        runtime = methods(code)
        self.assertIn("typedef rdma_queue_runtime_projector value_ops;", code)
        self.assertEqual(projector.keys() & runtime.keys(), {"cursor_equal"})
        self.assertIn("return value_ops::cursor_equal(a, aw, b, bw);", runtime["cursor_equal"][2])
        for name in projector.keys() - {"cursor_equal"}:
            self.assertNotRegex(code, rf"(?<![\w:]){name}\s*\(")
        for name in ("acquire_lock", "pending_identity_matches_locked", "pending_cursor_geometry_valid",
                     "consumer_recovery_invariant_locked", "commit_producer", "recover"):
            self.assertIn(name, runtime)
        self.assertIn("lock.try_get(1)", runtime["acquire_lock"][2])

    def test_package_dependency_order(self):
        """功能：要求 transaction 值类型先于 projector，projector 先于 mutable runtime。
        输入输出及副作用：读取 core package 与新文件 include，保持唯一声明入口。
        失败边界：漏注册、重复、倒序或 projector 自行 include 实现时失败。
        """
        package = (CORE / "rdma_core_pkg.sv").read_text()
        entries = [f'`include "{name}.sv"' for name in (
            "rdma_queue_runtime_transaction_models", "rdma_queue_runtime_projector", "rdma_queue_runtime")]
        for entry in entries:
            self.assertEqual(package.count(entry), 1)
        positions = [package.index(entry) for entry in entries]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("`include", read_code(CORE / "rdma_queue_runtime_projector.sv"))

    def test_status_and_callback_contracts_remain_distinct(self):
        """功能：保持 runtime 独有的 status fallback 与无分配原位更新，不借用其它层的 null 策略。
        输入输出及副作用：读取 raw factory、make/set 和 pending clone 的输出时机，只读。
        失败边界：吞掉 factory 窗口、去掉 fallback、在 noalloc 中分配或提前交付 pending 均失败。
        """
        raw = (CORE / "rdma_queue_runtime_projector.sv").read_text()
        declared = methods(read_code(CORE / "rdma_queue_runtime_projector.sv"))
        self.assertIn('result = new("runtime_status_fallback");', raw)
        self.assertIn('"runtime_status"', raw)
        self.assertIn("factory.create_object_by_type(", declared["factory_create_object_nonfatal"][2])
        self.assertNotRegex(declared["set_runtime_status_noalloc"][2],
                            r"\b(?:new|factory|create|clone|do_copy)\b")
        body = declared["clone_pending_value"][2]
        self.assertLess(body.index("candidate.epoch_valid = source.epoch_valid;"),
                        body.index("copy = candidate;"))
        self.assertNotIn("rdma_queue_data_projector", raw)

    def test_independent_value_matrix_is_registered(self):
        """功能：固定无 runtime 实例的 send/recv、工厂故障及嵌套 automatic 隔离验证入口。
        输入输出及副作用：读取测试及 package/core 注册，只读。
        失败边界：漏注册、移除深复制/重入/factory 恢复或构造 runtime 作为值层依赖时失败。
        """
        name = "rdma_queue_runtime_projector_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        self.assertEqual(package.count(f'`include "unit/{name}.sv"'), 1)
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        core = manifest.split("readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        code = read_code(ROOT / f"tests/unit/{name}.sv")
        self.assertNotRegex(code, r"\brdma_queue_runtime\b|\brdma_queue_data_engine\b")
        for token in ("check_graph(1'b0)", "check_graph(1'b1)", "check_factory_faults(factory)",
                      "factory.inner_source", "factory.inner_copy", "factory.reenter = 1'b1",
                      "service.set_factory(saved_factory)"):
            self.assertIn(token, code)


if __name__ == "__main__":
    unittest.main()
