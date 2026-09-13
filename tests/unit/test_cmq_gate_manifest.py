# 目录/层次：tests/unit，CMQ gate 与 engine 物理进程控制器的单元门禁。
# 文件职责：冻结公开 logical 清单、engine fixture 分片，以及 runner 的 strict
#   all-of 行为。
# 主要依赖：Python unittest、临时文件系统、sim/Makefile、进程清单和 shell
#   runner。
# 资源所有权：仓库输入均为只读引用；TemporaryDirectory 独占并自动回收伪
#   simulator、checker 与日志。
"""CMQ 专用 gate 清单与物理进程控制器的完整性测试。"""

import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]

ENGINE_LOGICAL_TEST = "rdma_cmq_engine_test"
ENGINE_LOGICAL_RUNNER = ROOT / "scripts" / "run_core_logical_test.sh"

ENGINE_PROCESS_TESTS = [
    "rdma_cmq_engine_test",
    "rdma_cmq_engine_capacity_process_test",
    "rdma_cmq_engine_submission_process_test",
    "rdma_cmq_engine_submission_continuation_process_test",
    "rdma_cmq_engine_invariant_process_test",
    "rdma_cmq_engine_raw_snapshot_process_test",
    "rdma_cmq_engine_poll_fault_process_test",
    "rdma_cmq_engine_poison_reset_process_test",
    "rdma_cmq_engine_wrap_process_test",
    "rdma_cmq_engine_wrap_publication_process_test",
    "rdma_cmq_engine_journal_process_test",
    "rdma_cmq_engine_mmio_arm_process_test",
    "rdma_cmq_engine_hostile_factory_process_test",
]

ENGINE_FIXTURES = [
    "check_transport_facade_contract",
    "check_transport_engine_lifecycle",
    "check_success_and_detachment",
    "check_preallocation_rejections",
    "check_pasid_normalization_and_busy_prepare",
    "check_allocation_and_rollback_failures",
    "check_null_status_guards",
    "check_prepared_shutdown_lifecycle",
    "check_shutdown_release_retry",
    "check_active_shutdown_release_retry",
    "check_null_shutdown_release_retry",
    "check_missing_host_mem_shutdown",
    "check_activation_guards",
    "check_batch_compaction_and_doorbell",
    "check_observed_batch_table",
    "check_full_initial_capacity_and_shutdown_reset",
    "check_empty_invalid_and_state_rejections",
    "check_poll_empty_ledger_and_partial_drain",
    "check_pre_read_poll_ledger_fail_closed",
    "check_submit_wrapper_and_snapshot_detachment",
    "check_null_compose_transaction_abort",
    "check_nested_command_snapshot_failures",
    "check_mutating_clone_source_restoration",
    "check_qpc_context_snapshot_failures",
    "check_transaction_failure_atomicity",
    "check_profile_wide_cqe_format_authority",
    "check_observed_transport_failure_retention",
    "check_doorbell_authority_isolation",
    "check_submission_validation_and_profile_metadata",
    "check_profile_hook_snapshot_contract",
    "check_stateful_profile_snapshot_rechecks",
    "check_exact_type_profile_delegation",
    "check_internal_invariant_batch_abort",
    "check_timeout_quarantine_and_late_diagnostic",
    "check_expire_snapshot_failure_is_atomic_and_retryable",
    "check_late_diagnostic_snapshot_failure_is_retryable",
    "check_command_incarnation_exhaustion",
    "check_incarnation_survives_reprepare",
    "check_max_dependency_id_boundary",
    "check_counter_invariants_poison_before_transport",
    "check_poll_raw_snapshot_rejects_self_clone_mutation",
    "check_poll_payload_retained_self_clone_is_detached",
    "check_poll_payload_hook_contract_failures",
    "check_poll_decoded_status_contract_failures",
    "check_poll_ticket_root_is_explicitly_constructed",
    "check_retirement_preflight_poison_atomicity",
    "check_cqe_poison_isolation_and_snapshot_detachment",
    "check_poison_shutdown_release_retry_preserves_snapshot",
    "check_wait_rejects_x_deadline_without_side_effects",
    "check_wait_poison_lifecycle_boundaries",
    "check_wait_for_caller_ticket_detachment",
    "check_wait_for_fifo_and_deadline",
    "check_cancel_reset_and_shutdown_lifecycle",
    "check_strict_cancel_audits_complete_ledger",
    "check_strict_cancel_audits_exact_membership",
    "check_poison_recovery_rejects_x_tickets",
    "check_poisoned_ledger_reset_recovery",
    "check_reset_fifo_retry_and_reprepare",
    "check_poll_backing_out_of_order_and_owner_wrap",
    "check_retire_then_wrap_publication",
    "check_journal_identity_and_counter_contract",
    "check_submission_journal_storage_and_queries",
    "check_pre_mmio_arm_capability",
    "check_journal_hostile_factory_snapshots_last",
]


class CmqGateManifestTest(unittest.TestCase):
    """验证 manifest 顺序、唯一性以及 UVM 注册闭合。"""

    # 功能：读取清单中的非注释测试名，保持与 shell gate 相同的过滤规则。
    # 输入输出及副作用：无显式输入；返回字符串列表，不写入文件或修改环境。
    # 失败边界：不存在文件时由 Path.read_text 抛出异常，测试明确失败。
    def _rows(self):
        lines = (ROOT / "sim" / "cmq_gate.list").read_text().splitlines()
        return [line.strip() for line in lines
                if line.strip() and not line.lstrip().startswith("#")]

    # 功能：读取 engine 逻辑测试的物理进程清单，按 runner 的注释/空行规则返回顺序列表。
    # 输入输出及副作用：无显式输入；返回物理 UVM test 名列表，不写文件或环境。
    # 失败边界：清单缺失或不可读时由 Path.read_text 抛出异常，使 inventory 测试失败关闭。
    def _engine_process_rows(self):
        path = ROOT / "sim" / "rdma_cmq_engine_process.list"
        lines = path.read_text().splitlines()
        return [line.split("#", 1)[0].strip() for line in lines
                if line.split("#", 1)[0].strip()]

    # 功能：从 SystemVerilog 源码中提取指定 UVM test class 的完整声明体，供注册和 run_phase 清单审计。
    # 输入输出及副作用：name/source 为只读输入；返回首个匹配 class 的正文字符串，不修改源码。
    # 失败边界：类缺失、继承声明损坏或 endclass 缺失时立即断言失败，不回退到相邻类。
    def _class_body(self, name, source):
        match = re.search(
            rf"\bclass\s+{re.escape(name)}\s+extends\s+"
            rf"[A-Za-z_][A-Za-z0-9_]*\s*;(.*?)\bendclass\b",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, f"missing UVM process class {name}")
        return match.group(1)

    # 功能：提取 Makefile 指定 target 的 recipe 文本，验证三条 core runner 路径共享同一逻辑展开入口。
    # 输入输出及副作用：name/source 为只读输入；返回目标到下一顶层 target 之间的文本，不执行 make。
    # 失败边界：target 缺失或正文为空时断言失败；不会误把后续 target 的调用计入当前路径。
    def _make_target_body(self, name, source):
        match = re.search(
            rf"(?m)^{re.escape(name)}:\s*[^\n]*\n(.*?)(?=^[A-Za-z0-9_.-]+:|\Z)",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, f"missing Make target {name}")
        self.assertTrue(match.group(1).strip(), f"empty Make target {name}")
        return match.group(1)

    # 功能：确认 gate 清单与固定 CMQ 测试顺序完全一致，并拒绝重复或非法 token。
    # 输入输出及副作用：读取仓库文本；断言失败只影响当前 unittest，不产生外部副作用。
    # 失败边界：缺项、额外项、重复项或不符合 SV 标识符规则时测试失败。
    def test_exact_rows(self):
        expected = [
            "rdma_cmq_codec_test",
            "rdma_cmq_completion_test",
            "rdma_cmq_profile_test",
            "rdma_doorbell_codec_test",
            "rdma_cmq_engine_test",
            "rdma_cmq_driver_field_mutation_test",
        ]
        rows = self._rows()
        self.assertEqual(rows, expected)
        self.assertEqual(len(rows), len(set(rows)))
        self.assertTrue(all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", row)
                            for row in rows))

    # 功能：确认每个清单测试已在 rdma_unit_test_pkg 中 include 且 mutation test 已进入 CORE_TESTS。
    # 输入输出及副作用：读取 package 与 regression shell 文本；不修改任何文件。
    # 失败边界：include 缺失、顺序不邻接或 CORE_TESTS 未注册时测试失败。
    def test_registration(self):
        package = (ROOT / "tests" / "rdma_unit_test_pkg.sv").read_text()
        regression = (ROOT / "scripts" / "run_queue_lifecycle_regression53.sh").read_text()
        for name in self._rows():
            self.assertRegex(package, rf'include "unit/{name}\.sv"')
        self.assertIn("rdma_cmq_driver_field_mutation_test", regression)
        profile_pos = regression.index("rdma_cmq_profile_test")
        mutation_pos = regression.index("rdma_cmq_driver_field_mutation_test")
        self.assertGreater(mutation_pos, profile_pos)

    # 功能：冻结一个 engine 逻辑行到十三物理进程的合法、唯一且有序映射，防止 process shard 泄漏到公开 gate。
    # 输入输出及副作用：读取 process/cmq/CORE_TESTS 清单并执行断言；不修改 runner 或清单。
    # 失败边界：物理项缺失、重复、非法、乱序，或逻辑行不再 exact-once 时测试失败。
    def test_engine_process_manifest(self):
        process_rows = self._engine_process_rows()
        self.assertEqual(process_rows, ENGINE_PROCESS_TESTS)
        self.assertEqual(len(process_rows), 13)
        self.assertEqual(len(process_rows), len(set(process_rows)))
        self.assertTrue(all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", row)
                            for row in process_rows))

        logical_rows = self._rows()
        regression = (ROOT / "scripts" /
                      "run_queue_lifecycle_regression53.sh").read_text()
        core_block = re.search(
            r"readonly CORE_TESTS=\((.*?)\n\)", regression, re.DOTALL
        )
        self.assertIsNotNone(core_block)
        self.assertEqual(logical_rows.count(ENGINE_LOGICAL_TEST), 1)
        self.assertEqual(core_block.group(1).count(ENGINE_LOGICAL_TEST), 1)
        for process_test in ENGINE_PROCESS_TESTS[1:]:
            self.assertNotIn(process_test, logical_rows)
            self.assertNotIn(process_test, core_block.group(1))

    # 功能：冻结十三 leaf 的 UVM 注册及 run_phase 展平后六十四个逻辑 fixture 的 exact-once 原始顺序。
    # 输入输出及副作用：只读解析 engine test 源码并断言 class/宏/调用列表；不运行仿真。
    # 失败边界：leaf 未注册、fixture 漏跑/重复/乱序或被跨 shard 拆分时测试失败。
    def test_engine_process_fixture_inventory(self):
        source = (ROOT / "tests" / "unit" /
                  "rdma_cmq_engine_test.sv").read_text()
        flattened_calls = []
        for process_test in self._engine_process_rows():
            body = self._class_body(process_test, source)
            self.assertRegex(
                body,
                rf"`uvm_component_utils\(\s*{re.escape(process_test)}\s*\)",
            )
            run_phase = re.search(
                r"\bvirtual\s+task\s+run_phase\s*\([^;]+;"
                r"(.*?)\bendtask\b",
                body,
                flags=re.DOTALL,
            )
            self.assertIsNotNone(
                run_phase, f"missing run_phase in {process_test}"
            )
            for fixture, arguments in re.findall(
                    r"\b(check_[A-Za-z0-9_]+)\s*\(([^;]*)\)\s*;",
                    run_phase.group(1)):
                if fixture == "check_observed_transport_failure_retention":
                    if fixture not in flattened_calls:
                        flattened_calls.append(fixture)
                else:
                    self.assertEqual(arguments.strip(), "")
                    flattened_calls.append(fixture)

        self.assertEqual(flattened_calls, ENGINE_FIXTURES)
        self.assertEqual(len(flattened_calls), 64)
        self.assertEqual(len(flattened_calls), len(set(flattened_calls)))

    # 功能：证明 observed retention 的两个物理调用以 inclusive bounds 有序、无重叠地精确覆盖 row 0..14。
    # 输入输出及副作用：只读解析十三个 leaf 的 run_phase 与 bounded task 声明；返回 unittest 断言结果，不运行仿真。
    # 失败边界：task 不是显式双边界接口、range 数量/顺序/调用 leaf 漂移，或出现 gap/overlap/越界时测试失败。
    def test_observed_retention_range_partition(self):
        source = (ROOT / "tests" / "unit" /
                  "rdma_cmq_engine_test.sv").read_text()
        self.assertRegex(
            source,
            r"task\s+automatic\s+check_observed_transport_failure_retention"
            r"\s*\(\s*input\s+int\s+unsigned\s+first_fault\s*,\s*"
            r"input\s+int\s+unsigned\s+last_fault\s*\)\s*;",
        )

        calls = []
        for process_test in self._engine_process_rows():
            body = self._class_body(process_test, source)
            run_phase = re.search(
                r"\bvirtual\s+task\s+run_phase\s*\([^;]+;"
                r"(.*?)\bendtask\b",
                body,
                flags=re.DOTALL,
            )
            self.assertIsNotNone(
                run_phase, f"missing run_phase in {process_test}"
            )
            for low, high in re.findall(
                    r"\bcheck_observed_transport_failure_retention\s*\("
                    r"\s*(\d+)\s*,\s*(\d+)\s*\)\s*;",
                    run_phase.group(1)):
                calls.append((process_test, int(low), int(high)))

        self.assertEqual(
            calls,
            [
                ("rdma_cmq_engine_submission_process_test", 0, 2),
                ("rdma_cmq_engine_submission_continuation_process_test",
                 3, 14),
            ],
        )
        coverage = []
        previous_high = -1
        for _, low, high in calls:
            self.assertEqual(low, previous_high + 1)
            self.assertLessEqual(low, high)
            coverage.extend(range(low, high + 1))
            previous_high = high
        self.assertEqual(coverage, list(range(15)))

        continuation = self._class_body(
            "rdma_cmq_engine_submission_continuation_process_test", source
        )
        self.assertNotIn("seed_submission_factory_epoch()", continuation)

    # 功能：确认 direct core、core regression 与 cmq_gate 都调用唯一
    #   RUN_CORE_LOGICAL_TEST fan-out。
    # 输入输出及副作用：只读 Makefile 并检查 shell controller 绑定和三处调用；
    #   不启动编译或 simulator。
    # 失败边界：controller 路径未固定、helper 未传完整参数，或任一路径绕过
    #   统一调用时测试失败。
    def test_engine_runner_uses_one_fanout(self):
        makefile = (ROOT / "sim" / "Makefile").read_text()
        helper = re.search(
            r"(?m)^define RUN_CORE_LOGICAL_TEST\s*$"
            r"(.*?)^endef\s*$",
            makefile,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(helper, "missing shared core logical runner")
        self.assertRegex(
            makefile,
            r"(?m)^ENGINE_PROCESS_LIST\s*:=\s*"
            r"rdma_cmq_engine_process\.list\s*$",
        )
        self.assertRegex(
            makefile,
            r"(?m)^CORE_LOGICAL_RUNNER\s*:=\s*"
            r"\.\./scripts/run_core_logical_test\.sh\s*$",
        )
        for argument in (
                '"$(strip $(1))"',
                '"$(strip $(2))"',
                '"$(ENGINE_PROCESS_LIST)"',
                '"../scripts/check_uvm_summary.sh"'):
            self.assertIn(argument, helper.group(1))

        invocation = "$(call RUN_CORE_LOGICAL_TEST,"
        core_body = self._make_target_body("core", makefile)
        cmq_body = self._make_target_body("cmq_gate", makefile)
        self.assertEqual(core_body.count(invocation), 2)
        self.assertEqual(cmq_body.count(invocation), 1)
        self.assertEqual(makefile.count(invocation), 3)

    # 功能：用可控 simulator/checker 执行 runner，证明普通 self-map 与 engine
    #   十三片 strict all-of。
    # 输入输出及副作用：在 TemporaryDirectory 创建伪程序、清单、调用记录与
    #   日志；返回 unittest 断言结果并自动回收。
    # 失败边界：任一 leaf 未尝试、checker 非恰好一次、日志复用、失败码丢失
    #   或 logical 误报成功时测试失败。
    def test_engine_runner_executes_strict_all_of(self):
        self.assertTrue(
            ENGINE_LOGICAL_RUNNER.is_file(),
            f"missing core logical runner {ENGINE_LOGICAL_RUNNER}",
        )

        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp)
            manifest = temp_root / "engine_process.list"
            checker = temp_root / "check_summary.sh"

            manifest.write_text(
                "\n".join(ENGINE_PROCESS_TESTS) + "\n", encoding="utf-8"
            )
            checker.write_text(
                """#!/usr/bin/env bash
set -u
log_path="$1"
printf '%s\n' "$log_path" >> "$FAKE_CHECKER_CALLS"
if [[ "$(basename "$log_path")" == "$FAKE_CHECKER_FAIL.log" ]]; then
  exit 9
fi
""",
                encoding="utf-8",
            )
            checker.chmod(0o755)

            scenarios = [
                ("ordinary_success", "rdma_smoke_test",
                 ["rdma_smoke_test"], "", "", 0),
                ("engine_success", ENGINE_LOGICAL_TEST,
                 ENGINE_PROCESS_TESTS, "", "", 0),
                ("simulator_failure", ENGINE_LOGICAL_TEST,
                 ENGINE_PROCESS_TESTS, ENGINE_PROCESS_TESTS[2], "", 1),
                ("checker_failure", ENGINE_LOGICAL_TEST,
                 ENGINE_PROCESS_TESTS, "", ENGINE_PROCESS_TESTS[9], 1),
            ]
            for (scenario, logical_test, expected_tests, simulator_fail,
                 checker_fail, expected_status) in scenarios:
                build = temp_root / scenario
                build.mkdir()
                simulator_calls = temp_root / f"{scenario}.simulator.calls"
                checker_calls = temp_root / f"{scenario}.checker.calls"
                simulator = build / "simv"
                simulator.write_text(
                    """#!/usr/bin/env bash
set -u
test_name=""
for argument in "$@"; do
  case "$argument" in
    +UVM_TESTNAME=*) test_name="${argument#+UVM_TESTNAME=}" ;;
  esac
done
printf '%s\n' "$test_name" >> "$FAKE_SIMULATOR_CALLS"
printf 'SIMULATOR TEST %s\n' "$test_name"
if [[ "$test_name" == "$FAKE_SIMULATOR_FAIL" ]]; then
  exit 7
fi
""",
                    encoding="utf-8",
                )
                simulator.chmod(0o755)

                environment = dict(os.environ)
                environment.update({
                    "FAKE_SIMULATOR_CALLS": str(simulator_calls),
                    "FAKE_CHECKER_CALLS": str(checker_calls),
                    "FAKE_SIMULATOR_FAIL": simulator_fail,
                    "FAKE_CHECKER_FAIL": checker_fail,
                })
                result = subprocess.run(
                    [
                        str(ENGINE_LOGICAL_RUNNER),
                        logical_test,
                        str(build),
                        str(manifest),
                        str(checker),
                    ],
                    cwd=ROOT / "sim",
                    env=environment,
                    text=True,
                    capture_output=True,
                    check=False,
                )

                self.assertEqual(
                    result.returncode,
                    expected_status,
                    result.stdout + result.stderr,
                )
                self.assertEqual(
                    simulator_calls.read_text(encoding="utf-8").splitlines(),
                    expected_tests,
                )
                expected_logs = [
                    str(build / f"{name}.log")
                    for name in expected_tests
                ]
                self.assertEqual(
                    checker_calls.read_text(encoding="utf-8").splitlines(),
                    expected_logs,
                )
                self.assertEqual(
                    sorted(path.name for path in build.glob("*.log")),
                    sorted(f"{name}.log" for name in expected_tests),
                )
                for name in expected_tests:
                    self.assertEqual(
                        (build / f"{name}.log").read_text(encoding="utf-8"),
                        f"SIMULATOR TEST {name}\n",
                    )

                transcript = result.stdout + result.stderr
                if expected_status == 0:
                    self.assertIn(
                        f"LOGICAL PASS logical={logical_test} "
                        f"processes={len(expected_tests)}",
                        transcript,
                    )
                    self.assertNotIn("PROCESS FAIL", transcript)
                else:
                    self.assertIn(
                        f"LOGICAL FAIL logical={logical_test} "
                        f"processes={len(expected_tests)}",
                        transcript,
                    )
                    self.assertNotIn("LOGICAL PASS", transcript)

                if simulator_fail:
                    self.assertIn(
                        f"physical={simulator_fail} simulator=7 summary=0",
                        transcript,
                    )
                if checker_fail:
                    self.assertIn(
                        f"physical={checker_fail} simulator=0 summary=9",
                        transcript,
                    )

    # 功能：验证 runner 对缺失 CLI 参数和非十三项 engine manifest 失败关闭，
    #   不启动任何 simulator。
    # 输入输出及副作用：在 TemporaryDirectory 创建空可执行依赖和畸形清单；
    #   捕获子进程状态与诊断后自动回收。
    # 失败边界：参数数量或 manifest cardinality 错误未返回 2，或错误输入触发
    #   simulator 时测试失败。
    def test_engine_runner_rejects_invalid_inputs(self):
        self.assertTrue(
            ENGINE_LOGICAL_RUNNER.is_file(),
            f"missing core logical runner {ENGINE_LOGICAL_RUNNER}",
        )

        missing_arguments = subprocess.run(
            [str(ENGINE_LOGICAL_RUNNER)],
            cwd=ROOT / "sim",
            text=True,
            capture_output=True,
            check=False,
        )
        self.assertEqual(missing_arguments.returncode, 2)
        self.assertIn("Usage:", missing_arguments.stderr)

        with tempfile.TemporaryDirectory() as temp:
            temp_root = Path(temp)
            build = temp_root / "build"
            build.mkdir()
            simulator = build / "simv"
            checker = temp_root / "checker.sh"
            manifest = temp_root / "malformed.list"
            simulator.write_text(
                "#!/usr/bin/env bash\nexit 99\n", encoding="utf-8"
            )
            checker.write_text(
                "#!/usr/bin/env bash\nexit 99\n", encoding="utf-8"
            )
            manifest.write_text(
                "\n".join(ENGINE_PROCESS_TESTS[:-1]) + "\n",
                encoding="utf-8",
            )
            simulator.chmod(0o755)
            checker.chmod(0o755)

            malformed_manifest = subprocess.run(
                [
                    str(ENGINE_LOGICAL_RUNNER),
                    ENGINE_LOGICAL_TEST,
                    str(build),
                    str(manifest),
                    str(checker),
                ],
                cwd=ROOT / "sim",
                text=True,
                capture_output=True,
                check=False,
            )
            self.assertEqual(malformed_manifest.returncode, 2)
            self.assertIn("exactly thirteen", malformed_manifest.stderr)


if __name__ == "__main__":
    unittest.main()
