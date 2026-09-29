"""目录/层次：tests/unit；职责：固定 CMQ execute 的单一 observation 出口。
依赖：unittest 与 SV 方法扫描器；只读生产和测试源码，不代替动态等待/复位验证。
所有权/生命周期：不创建仿真对象或改写工作树，不拥有 engine authority。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CmqExecuteObservationBoundaryTest(unittest.TestCase):
    """生命周期策略留在业务入口，快照/回退仅有一个出口，不引入辅助状态 owner。"""

    def body(self):
        """功能：取得 execute_observed 的净化正文用于边界检查。
        输入输出及副作用：无参数，返回方法字符串；只读 CMQ engine。
        失败边界：入口不存在或重复时由扫描器/索引报错，不返回空替身。
        """
        return methods(read_code(CORE / "rdma_cmq_engine.sv"))["execute_observed"][2]

    def test_one_projection_with_fail_closed_fallback(self):
        """功能：锁定单次构造、null item 跳过和 submitted 回退的统一出口。
        输入输出及副作用：只读源码计数与末尾语句；不调用 DUT。
        失败边界：重复 builder、丢失 null 门禁/错误分流或返回前未解锁时失败。
        """
        body = self.body()
        self.assertEqual(body.count("build_observed_result_locked("), 1)
        self.assertRegex(body, r"snapshot_status = \(journal_item == null\) \? null :\s*"
                         r"build_observed_result_locked\(\s*batch_record, journal_item, "
                         r"observation_code, observation_message, result\s*\);")
        self.assertRegex(body, r"if \(snapshot_status == null \|\| !snapshot_status.ok\(\)\) begin\s*"
                         r"result = submitted;\s*result.observation_status = rdma_cmq_direct_status\(\s*"
                         r"RDMA_SC_INVALID_STATE,\s*\(snapshot_status == null\) \? "
                         r"snapshot_failure_message : snapshot_status.message\s*\);\s*end\s*"
                         r"engine_lock.put\(1\);\s*endtask\s*$")

    def test_wait_remains_outside_lock_and_relocates_authority(self):
        """功能：固定 submit/身份验证/等待/重定位/快照顺序，不使用 wait 输出作交付源。
        输入输出及副作用：只读各阶段语句位置；无状态修改。
        失败边界：多次 submit/wait、等待前未解锁或交付 wait 的临时 completion 时失败。
        """
        body = self.body()
        self.assertEqual(body.count("submit_observed(command, submitted);"), 1)
        self.assertEqual(body.count("wait_for(submitted.ticket, waited_completion, waited_status);"), 1)
        self.assertLess(body.index("validate_observed_item_locked("), body.index("armed_pending ="))
        self.assertRegex(body, r"armed_pending = journal_item.state inside \{\s*"
                         r"RDMA_CMQ_SUBMISSION_PUBLISH_AMBIGUOUS,\s*"
                         r"RDMA_CMQ_SUBMISSION_PUBLISH_CONFIRMED\s*\} && "
                         r"journal_item.completion_phase == RDMA_CMQ_COMPLETION_PENDING;")
        decision = body[body.index("armed_pending ="):body.index("waited_completion = null;")]
        self.assertLess(decision.index("engine_lock.put(1);"), decision.index("if (!armed_pending)"))
        self.assertRegex(body, r"wait_for\(submitted.ticket, waited_completion, waited_status\);\s*"
                         r"engine_lock.get\(1\);\s*lookup_status = locate_journal_item_by_ticket_locked\(")
        self.assertNotIn("result.completion = waited_completion", body)
        self.assertNotIn("last_", body)

    def test_five_policy_diagnostics_remain_distinct(self):
        """功能：固定五种 retained 观测策略各自的 code、成功及 null-snapshot 文案。
        输入输出及副作用：从原文抽取三字段赋值组，与独立常量表比较。
        失败边界：合并不同诊断、顺序改变或新增未预期策略都失败。
        """
        source = (CORE / "rdma_cmq_engine.sv").read_text()
        found = re.findall(r'observation_code = (RDMA_SC_\w+);\s*'
                           r'observation_message = "([^"]*)";\s*'
                           r'snapshot_failure_message = "([^"]*)";', source)
        self.assertEqual(found, [
            ("RDMA_SC_INVALID_STATE", "CMQ observed item has pending external effect",
             "CMQ observed pending item snapshot returned null status"),
            ("RDMA_SC_OK", "CMQ retained host-visible journal observed",
             "CMQ retained host-visible snapshot returned null status"),
            ("RDMA_SC_OK", "CMQ retained journal completion observed",
             "CMQ retained completion snapshot returned null status"),
            ("RDMA_SC_OK", "CMQ retained journal completion observed after wait",
             "CMQ retained completion snapshot returned null status"),
            ("RDMA_SC_INVALID_STATE", "CMQ observed wait produced no retained completion",
             "CMQ observed wait produced no retained snapshot"),
        ])

    def test_public_characterization_registration(self):
        """功能：固定独立 24-case 测试注册，确保真实 wait、profile 故障及锁泄漏断言存在。
        输入输出及副作用：只读 package、manifest 和测试原文。
        失败边界：遗漏/重复注册、改为直接调 builder 或重复运行父矩阵时失败。
        """
        name = "rdma_cmq_execute_observation_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text().count(f'"unit/{name}.sv"'), 1)
        self.assertEqual(len(re.findall(rf"^  {name}$",
                         (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text(), re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        for marker in ("completed 24 CMQ execute observation cases",
                       "engine.execute_observed(command, result);", "engine_lock.try_get(1)",
                       "RDMA_CMQ_TEST_HOOK_NULL_STATUS", "engine.hide_ticket_index();"):
            self.assertIn(marker, test)
        self.assertNotIn("build_observed_result_locked(", test)
        self.assertNotIn("super.run_phase", test)


if __name__ == "__main__":
    unittest.main()
