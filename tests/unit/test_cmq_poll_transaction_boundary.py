"""目录/层次：tests/unit；职责：固定 CMQ 完成事务的阶段边界与唯一提交顺序。
依赖：unittest、既有 SV scanner；只读源码，不代替 VCS 的回调/poison/恢复验证。
所有权与生命周期：不持有 engine，不创建状态或修改工程文件。
"""

import re
import unittest

from tests.unit.test_queue_data_projector_boundary import CORE, ROOT, methods, read_code


class CmqPollTransactionBoundaryTest(unittest.TestCase):
    """守卫按业务阶段组织的 drain，防止回退为循环内堆叠全部细节。"""

    def declared(self):
        """功能：提取 engine 的方法，供完成路径结构断言复用。
        输入输出及副作用：无输入，返回只读方法映射；不启动仿真。
        失败边界：源文件缺失、方法重名或扫描错误直接失败。
        """
        return methods(read_code(CORE / "rdma_cmq_engine.sv"))

    def test_drain_orders_stages_and_retires_only_after_commit(self):
        """功能：固定 drain 的读取、匹配、提交、consume 与 retire 顺序。
        输入输出及副作用：读取 poll_locked；检查失败显式 break 而非重判构造结果。
        失败边界：循环重新承载 codec/ledger 细节、提前回收或超过 75 行时失败。
        """
        start, end, body = self.declared()["poll_locked"]
        calls = ["read_polled_cqe_locked(", "match_polled_cqe_locked(",
                 "commit_polled_completion_locked(", "cq_consume_seq++",
                 "commit_retired_prefix(stage.retire_seq)"]
        self.assertEqual([body.index(call) for call in calls],
                         sorted(body.index(call) for call in calls))
        self.assertRegex(body, r"if \(!ready\)\s+break;")
        self.assertRegex(body, r"if \(!match_polled_cqe_locked\([^;]+\)\)\s+break;")
        self.assertRegex(body, r"if \(status == null \|\| !status.ok\(\)\) begin")
        self.assertNotRegex(body, r"\b(?:inspect_cqe|entry_registry|token_in_use|poison)\b")
        self.assertLessEqual(end - start + 1, 75)

    def test_read_preserves_inspection_priority_and_explicit_readiness(self):
        """功能：固定读取、快照、inspect、raw 不变性和 inspect status 的优先级。
        输入输出及副作用：只读 read helper，确认 ready 仅在末尾放行。
        失败边界：错误路径沿用 profile.ready、提前解码命令或推进账本时失败。
        """
        body = self.declared()["read_polled_cqe_locked"][2]
        calls = ["host_mem.read(", "make_raw_cqe_image(", "checked_image_snapshot(",
                 "profile.inspect_cqe(", "same_image_value(", "inspect_status == null",
                 "!inspect_status.ok()", "!inspected_ready", "ready = 1'b1"]
        self.assertEqual([body.index(call) for call in calls],
                         sorted(body.index(call) for call in calls))
        self.assertEqual(body.count("ready = 1'b1"), 1)
        self.assertLess(body.index("ready = 1'b0"), body.index("host_mem.read("))
        self.assertNotRegex(body, r"\b(?:commit_retired_prefix|command_registry|"
                                 r"commit_polled_completion_locked)\b")

    def test_match_stages_only_after_all_authority_checks(self):
        """功能：保持命令关联校验次序及 normal/late 共用的 token incarnation 规则。
        输入输出及副作用：检查 match 的匹配条件、候选发布点和布尔结果；只读。
        失败边界：匹配阶段写入完成账本、添加对象构造或把失败误判为可提交时失败。
        """
        body = self.declared()["match_polled_cqe_locked"][2]
        checks = ["decoded == null", "entry_registry.exists", "record == null",
                  "decoded.command_status == null", "decoded.validate()",
                  "decoded_status_contract(", "record.expected.hardware_opcode",
                  "cq_consume_seq ==", "command_registry.exists", "token_in_use[",
                  "prospective_retirement_status(", "stage =", "return 1'b1;"]
        self.assertEqual([body.index(check) for check in checks],
                         sorted(body.index(check) for check in checks))
        self.assertEqual(body.count("token_incarnation[token_index]"), 1)
        self.assertEqual(body.count("return 1'b1;"), 1)
        self.assertNotRegex(body, r"\b(?:new|type_id|success|commit_runtime_journal_transition_locked)\b")
        self.assertNotRegex(body, r"(?:record\.state|token_in_use\[[^]]+\]|cq_consume_seq)\s*=(?!=)")

    def test_completion_build_and_commit_are_shared(self):
        """功能：固定 late 决策冻结、diagnostic→completion→journal→FIFO→token→slot 的顺序。
        输入输出及副作用：只读 commit helper，检查单一构造与 journal 调用。
        失败边界：回调后重选 late 分支、重复 completion 构造或提前释放 token 时失败。
        """
        body = self.declared()["commit_polled_completion_locked"][2]
        calls = ["late =", "make_late_diagnostic(", "make_polled_completion(",
                 "commit_polled_journal_transition_locked(", "diagnostic_fifo.push_back(",
                 "terminal_fifo.push_back(", "token_in_use[token_index] =", "record.state ="]
        self.assertEqual([body.index(call) for call in calls],
                         sorted(body.index(call) for call in calls))
        self.assertEqual(body.count("make_polled_completion("), 1)
        self.assertEqual(body.count("commit_polled_journal_transition_locked("), 1)
        self.assertEqual(body.count("late ="), 1)
        self.assertNotIn("record.state", body.split("make_late_diagnostic(", 1)[1]
                         .split("record.state =", 1)[0])

    def test_stage_does_not_add_an_owner_or_lock(self):
        """功能：候选仅含调用期非拥有引用与三个定位值，engine 保留唯一锁和账本。
        输入输出及副作用：扫描 struct 与阶段 helper；不执行任何状态迁移。
        失败边界：stage 膨胀为 runtime/journal owner，或阶段内获取/释放锁时失败。
        """
        models = read_code(CORE / "rdma_cmq_engine_transaction_models.sv")
        stage = re.search(r"typedef struct \{([^{}]*)\}\s*rdma_cmq_polled_completion_stage_t;",
                          models).group(1)
        self.assertEqual(" ".join(stage.split()),
                         "rdma_cmq_slot_record record; string software_key; "
                         "int unsigned token_index; longint unsigned retire_seq;")
        for name in ("read_polled_cqe_locked", "match_polled_cqe_locked",
                     "commit_polled_completion_locked"):
            self.assertNotRegex(self.declared()[name][2], r"\b(?:semaphore|engine_lock)\b")

    def test_public_flow_matrix_is_registered_once(self):
        """功能：专项独立注册，确保正常/晚到、wrap 和四种后项结果都实际进入仿真。
        输入输出及副作用：读取 package、core manifest 与专项源码；只读。
        失败边界：漏注册、重复注册、调用父 run_phase 或靠 seed counter 代替真实 wrap 时失败。
        """
        name = "rdma_cmq_poll_transaction_test"
        self.assertEqual((ROOT / "tests/rdma_unit_test_pkg.sv").read_text()
                         .count(f'"unit/{name}.sv"'), 1)
        manifest = (ROOT / "scripts/run_queue_lifecycle_regression53.sh").read_text()
        self.assertEqual(len(re.findall(rf"^  {name}$", manifest, re.M)), 1)
        test = (ROOT / f"tests/unit/{name}.sv").read_text()
        self.assertIn("completed 16 CMQ poll transaction cases", test)
        self.assertIn("prime_wrap(engine, mem, profile, active_binding);", test)
        self.assertNotIn("super.run_phase", test)
        self.assertNotRegex(read_code(ROOT / f"tests/unit/{name}.sv"), r"\bseed_\w+\s*\(")


if __name__ == "__main__":
    unittest.main()
