"""目录/层次：tests/unit；职责：固定 runtime 恢复授权的唯一规则与双入口交付边界。
依赖：unittest、既有 SV scanner；仅读取生产/测试，不运行仿真。
所有权与生命周期：不持有 runtime，不创建 status 或改写输入文件。
"""

import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class RuntimeCommitGateBoundaryTest(unittest.TestCase):
    """证据校验和授权消费同源，返回 status 的时机由公开入口保持。"""

    def declared(self):
        """功能：读取 runtime 单类方法，供边界断言复用。
        输入输出及副作用：无参数；返回名称到源码范围/正文的只读映射。
        失败边界：缺文件或方法扫描异常直接失败，不忽略不完整源码。
        """
        return methods(read_code(CORE / "rdma_queue_runtime.sv"))

    def test_one_authorization_rule(self):
        """功能：要求两入口只委托同一个持锁授权规则，不再各自判断 evidence/shadow。
        输入输出及副作用：扫描调用数及规则 token；只读。
        失败边界：重复规则、漏委托或 gate mutation 回到 facade 均失败。
        """
        declared = self.declared()
        shared = declared["enable_recovery_commit_locked"][2]
        for name in ("enable_recovery_commit", "enable_recovery_commit_noalloc"):
            body = declared[name][2]
            self.assertEqual(body.count("enable_recovery_commit_locked(message)"), 1)
            self.assertNotRegex(body, r"\b(?:pending_operation_state|recovery_commit_allowed|"
                                     r"recovery_retry_confirmed)\b")
        self.assertEqual(shared.count("recovery_commit_allowed = 1'b1;"), 1)
        self.assertEqual(shared.count("recovery_retry_confirmed = 1'b0;"), 1)
        self.assertIn("consumer_shadow_phase_valid(pending_operation_state, 1'b1)", shared)

    def test_shared_rule_does_not_own_lock_or_status(self):
        """功能：限制公共规则只返回 code/message 并原子更新两个授权位，不获取其它所有权。
        输入输出及副作用：只读 helper，核对原子拒绝与无对象构造边界。
        失败边界：分配、回调、释放锁、更新 pending/游标/状态或引入外部 I/O 时失败。
        """
        shared = self.declared()["enable_recovery_commit_locked"][2]
        self.assertIn("function rdma_status_code_e enable_recovery_commit_locked", shared)
        self.assertIn("output string message", shared)
        self.assertNotRegex(shared, r"\b(?:lock|acquire_lock|new|type_id|factory|"
                                   r"make_runtime_status|set_fields_noalloc|host_mem|pcie)\b")
        self.assertNotRegex(shared, r"(?:pending_operation_state\.\w+|consumer_index|"
                                   r"producer_index|used|state)\s*=(?!=)")
        self.assertLess(shared.rindex("return RDMA_SC_INVALID_STATE;"),
                        shared.index("recovery_retry_confirmed = 1'b0;"))

    def test_public_delivery_keeps_callback_window(self):
        """功能：保持普通入口的带 factory acquire、锁内 mutation、解锁后 status 构造顺序。
        输入输出及副作用：读取入口调用顺序与数量；不模拟 factory。
        失败边界：用 noalloc API 替代 acquire、提前构造最终 status 或缺锁释放均失败。
        """
        body = self.declared()["enable_recovery_commit"][2]
        self.assertLess(body.index("acquire_lock()"), body.index("enable_recovery_commit_locked("))
        self.assertLess(body.index("enable_recovery_commit_locked("), body.index("lock.put(1)"))
        self.assertLess(body.index("lock.put(1)"), body.index("make_runtime_status(code, message)"))
        self.assertEqual(body.count("make_runtime_status("), 1)
        self.assertEqual(body.count("lock.put(1)"), 1)

    def test_noalloc_delivery_keeps_null_busy_and_setter(self):
        """功能：保留 noalloc 的 null slot 首拒绝、直接 try_get 和解锁后原槽写入。
        输入输出及副作用：读取 noalloc 入口，只核对已有调用边界。
        失败边界：引入普通 acquire/factory、null 检查后移或变更布尔返回依据时失败。
        """
        body = self.declared()["enable_recovery_commit_noalloc"][2]
        self.assertLess(body.index("status_slot == null"), body.index("lock.try_get(1)"))
        self.assertLess(body.index("lock.try_get(1)"), body.index("enable_recovery_commit_locked("))
        self.assertLess(body.index("lock.put(1)"), body.index("set_fields_noalloc(status_slot, code, message)"))
        self.assertIn("return code == RDMA_SC_OK;", body)
        self.assertNotRegex(body, r"\b(?:acquire_lock|make_runtime_status|new|type_id)\b")

    def test_diagnostics_are_unique_and_ordered(self):
        """功能：固定缺 pending→shadow→MMIO→confirmation 的错误优先级和原文。
        输入输出及副作用：读取保留字符串的完整源码，四种诊断必须集中到 helper。
        失败边界：把失败改成关闭旧 gate、诊断重复或优先级颠倒时失败。
        """
        source = (CORE / "rdma_queue_runtime.sv").read_text()
        shared = source.split("protected function rdma_status_code_e enable_recovery_commit_locked", 1)[1]
        shared = shared.split("endfunction", 1)[0]
        messages = ("queue runtime has no pending recovery", "CQ shadow publication is incomplete",
                    "recovery commit lacks definitive MMIO evidence", "recovery commit lacks retry confirmation")
        positions = [shared.index(f'"{message}"') for message in messages]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("recovery_commit_allowed = 1'b0", shared)

    def test_registered_matrix_uses_public_apis(self):
        """功能：固定独立矩阵注册及两入口、重复授权、factory 与真实 consumer 流程。
        输入输出及副作用：读取 package、manifest 和测试源码；不执行测试。
        失败边界：漏注册、复跑父类、跳过原 API 或删关键矩阵维度均失败。
        """
        name = "rdma_runtime_commit_gate_test"
        package = (ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
        include = f'`include "unit/{name}.sv"'
        self.assertEqual(package.count(include), 1)
        self.assertLess(package.index('`include "unit/rdma_queue_runtime_test.sv"'), package.index(include))
        core = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text().split(
            "readonly CORE_TESTS=(", 1)[1].split("\n)", 1)[0]
        self.assertEqual(core.split().count(name), 1)
        source = read_code(ROOT / f"tests/unit/{name}.sv")
        for token in ("ev < 5", "shadow < 4", "confirmed < 2", "allowed < 2", "mode < 3",
                      "cases != 345", "#1us;", "runtime.enable_recovery_commit()",
                      "runtime.enable_recovery_commit_noalloc(status)", "runtime.hold_lock()",
                      "observer.free_at_create", "observer.flags_at_create",
                      "runtime.commit_consumer(pending.cursor)", "runtime.complete_recovery_retry()"):
            self.assertIn(token, source)
        self.assertNotIn("enable_recovery_commit_locked(", source)
        self.assertNotIn("super.run_phase", source)


if __name__ == "__main__":
    unittest.main()
