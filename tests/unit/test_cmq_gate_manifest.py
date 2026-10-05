# 目录/层次：tests/unit，CMQ gate 与 engine 物理进程控制器的单元门禁。
# 文件职责：冻结公开 logical 清单、engine 完整动作分片、protected seam、
#   typed-snapshot/body-value/journal-value、recovery ordered tuple 与 submit
#   transport 判定的调用顺序，以及 runner 的 strict all-of 行为。
# 主要依赖：Python unittest、临时文件系统、CMQ engine/测试源码、sim/Makefile、
#   进程清单和 shell runner。
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
    "rdma_cmq_engine_base_suffix_process_test",
    "rdma_cmq_engine_capacity_process_test",
    "rdma_cmq_engine_submission_process_test",
    "rdma_cmq_engine_submission_matrix_process_test",
    "rdma_cmq_engine_profile_wide_process_test",
    "rdma_cmq_engine_retention_prefix_process_test",
    "rdma_cmq_engine_submission_continuation_process_test",
    "rdma_cmq_engine_submission_profile_process_test",
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
    "check_execute_observed_null_envelope",
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
    "check_reset_release_reentrant_drift_is_safe",
    "check_reset_timeout_tombstone_isolated",
    "check_timeout_fifo_survives_wait_target_and_reset",
    "check_poll_backing_out_of_order_and_owner_wrap",
    "check_retire_then_wrap_publication",
    "check_journal_identity_and_counter_contract",
    "check_submission_journal_storage_and_queries",
    "check_pre_mmio_arm_capability",
    "check_journal_hostile_factory_snapshots_last",
]

ENGINE_PROCESS_ACTIONS = {
    "rdma_cmq_engine_test": (
        "check:check_transport_facade_contract()",
        "check:check_transport_engine_lifecycle()",
        "check:check_success_and_detachment()",
        "check:check_preallocation_rejections()",
        "check:check_pasid_normalization_and_busy_prepare()",
        "check:check_allocation_and_rollback_failures()",
        "check:check_null_status_guards()",
        "check:check_prepared_shutdown_lifecycle()",
    ),
    "rdma_cmq_engine_base_suffix_process_test": (
        "check:check_shutdown_release_retry()",
        "check:check_active_shutdown_release_retry()",
        "check:check_null_shutdown_release_retry()",
        "check:check_missing_host_mem_shutdown()",
        "check:check_activation_guards()",
        "check:check_batch_compaction_and_doorbell()",
        "check:check_observed_batch_table()",
        "check:check_execute_observed_null_envelope()",
    ),
    "rdma_cmq_engine_capacity_process_test": (
        "check:check_full_initial_capacity_and_shutdown_reset()",
    ),
    "rdma_cmq_engine_submission_process_test": (
        "check:check_empty_invalid_and_state_rejections()",
        "check:check_poll_empty_ledger_and_partial_drain()",
        "check:check_pre_read_poll_ledger_fail_closed()",
        "check:check_submit_wrapper_and_snapshot_detachment()",
        "check:check_null_compose_transaction_abort()",
    ),
    "rdma_cmq_engine_submission_matrix_process_test": (
        "check:check_nested_command_snapshot_failures()",
        "check:check_mutating_clone_source_restoration()",
        "check:check_qpc_context_snapshot_failures()",
        "check:check_transaction_failure_atomicity()",
    ),
    "rdma_cmq_engine_profile_wide_process_test": (
        "check:check_profile_wide_cqe_format_authority()",
    ),
    "rdma_cmq_engine_retention_prefix_process_test": (
        "check:check_observed_transport_failure_retention(0,2)",
    ),
    "rdma_cmq_engine_submission_continuation_process_test": (
        "check:check_observed_transport_failure_retention(3,14)",
        "check:check_doorbell_authority_isolation()",
        "check:check_submission_validation_and_profile_metadata()",
    ),
    "rdma_cmq_engine_submission_profile_process_test": (
        "check:check_profile_hook_snapshot_contract()",
        "check:check_stateful_profile_snapshot_rechecks()",
        "check:check_exact_type_profile_delegation()",
    ),
    "rdma_cmq_engine_invariant_process_test": (
        "check:check_internal_invariant_batch_abort()",
        "check:check_timeout_quarantine_and_late_diagnostic()",
        "check:check_expire_snapshot_failure_is_atomic_and_retryable()",
        "check:check_late_diagnostic_snapshot_failure_is_retryable()",
        "check:check_command_incarnation_exhaustion()",
        "check:check_incarnation_survives_reprepare()",
        "check:check_max_dependency_id_boundary()",
        "check:check_counter_invariants_poison_before_transport()",
    ),
    "rdma_cmq_engine_raw_snapshot_process_test": (
        "recovery:run_task16_recovery_shape_digest_and_authority()",
        "seed:submission",
        "check:check_poll_raw_snapshot_rejects_self_clone_mutation()",
        "check:check_poll_payload_retained_self_clone_is_detached()",
    ),
    "rdma_cmq_engine_poll_fault_process_test": (
        "recovery:run_task16_recovery_owner_batch_atomicity()",
        "seed:raw",
        "check:check_poll_payload_hook_contract_failures()",
        "check:check_poll_decoded_status_contract_failures()",
        "check:check_poll_ticket_root_is_explicitly_constructed()",
    ),
    "rdma_cmq_engine_poison_reset_process_test": (
        "seed:raw",
        "check:check_retirement_preflight_poison_atomicity()",
        "check:check_cqe_poison_isolation_and_snapshot_detachment()",
        "check:check_poison_shutdown_release_retry_preserves_snapshot()",
        "check:check_wait_rejects_x_deadline_without_side_effects()",
        "check:check_wait_poison_lifecycle_boundaries()",
        "check:check_wait_for_caller_ticket_detachment()",
        "check:check_wait_for_fifo_and_deadline()",
        "check:check_cancel_reset_and_shutdown_lifecycle()",
        "check:check_strict_cancel_audits_complete_ledger()",
        "check:check_strict_cancel_audits_exact_membership()",
        "check:check_poison_recovery_rejects_x_tickets()",
        "check:check_poisoned_ledger_reset_recovery()",
        "check:check_reset_fifo_retry_and_reprepare()",
        "check:check_reset_release_reentrant_drift_is_safe()",
        "check:check_reset_timeout_tombstone_isolated()",
        "check:check_timeout_fifo_survives_wait_target_and_reset()",
    ),
    "rdma_cmq_engine_wrap_process_test": (
        "recovery:run_task16_recovery_staging_and_deadline_rejections()",
        "seed:raw",
        "check:check_poll_backing_out_of_order_and_owner_wrap()",
    ),
    "rdma_cmq_engine_wrap_publication_process_test": (
        "recovery:run_task16_recovery_minimum_deadline_and_ordered_effect()",
        "seed:raw",
        "check:check_retire_then_wrap_publication()",
    ),
    "rdma_cmq_engine_journal_process_test": (
        "recovery:run_task16_recovery_unobserved_effect_chain()",
        "seed:raw",
        "check:check_journal_identity_and_counter_contract()",
        "check:check_submission_journal_storage_and_queries()",
    ),
    "rdma_cmq_engine_mmio_arm_process_test": (
        "seed:raw",
        "check:check_pre_mmio_arm_capability()",
        "nested-last:check_pre_mmio_arm_capability->"
        "run_task16_recovery_concurrent_cas_winner()",
    ),
    "rdma_cmq_engine_hostile_factory_process_test": (
        "seed:raw",
        "check:check_journal_hostile_factory_snapshots_last()",
    ),
}

ENGINE_PROTECTED_VIRTUAL_SEAMS = {
    "build_runtime_desc": (
        "protected virtual function rdma_status build_runtime_desc("
        "rdma_dma_request_context request_context,rdma_cmq cmq,"
        "rdma_dma_mapping mapping,output rdma_cmq_runtime_desc runtime);"
    ),
    "publish_runtime_snapshot": (
        "protected virtual function rdma_status publish_runtime_snapshot("
        "rdma_cmq_runtime_desc source,"
        "output rdma_cmq_runtime_desc snapshot);"
    ),
    "make_recovery_result_locked": (
        "protected virtual function rdma_cmq_execution_result "
        "make_recovery_result_locked(input string name);"
    ),
    "make_recovery_owner_locked": (
        "protected virtual function rdma_cmq_recovery_owner "
        "make_recovery_owner_locked(input string name,"
        "input rdma_cmq_recovery_owner source);"
    ),
    "make_recovery_doorbell_locked": (
        "protected virtual function rdma_doorbell_desc "
        "make_recovery_doorbell_locked(input string name);"
    ),
    "make_recovery_observer_locked": (
        "protected virtual function rdma_cmq_mmio_arm_observer "
        "make_recovery_observer_locked(input string name);"
    ),
}


MODEL_TYPED_SNAPSHOT_INCLUDE_ORDER = [
    "rdma_cmq_engine_models.sv",
    "rdma_cmq_execution_models.sv",
    "rdma_cmq_value_contract.sv",
    "rdma_cmq_typed_snapshot_contract.sv",
    "rdma_control_plane_models.sv",
]

FINAL_CMQ_ROWS = [
    "rdma_cmq_engine_models_test",
    "rdma_cmq_codec_test",
    "rdma_cmq_completion_test",
    "rdma_cmq_profile_test",
    "rdma_doorbell_codec_test",
    "rdma_doorbell_scheduler_test",
    "rdma_queue_data_engine_post_test",
    "rdma_cmq_engine_test",
    "rdma_cmq_port_test",
    "rdma_control_plane_cmq_engine_test",
    "rdma_cmq_driver_field_mutation_test",
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

    # 功能：从 --list 所用的回归脚本提取 ENGINE_PROCESS_TESTS，验证公开发现清单
    #   与 logical runner 的 physical inventory 保持同一顺序。
    # 输入/输出及副作用：仅读取回归脚本文本；返回 ENGINE_PROCESS_TESTS 的标识符列表，
    #   不执行 shell、VCS 或写入仓库。
    # 失败边界：数组声明缺失、未闭合或包含空白/非法 token 时由调用断言失败，
    #   不回退到 CORE_TESTS 或 process list 的其他段落。
    def _regression_engine_process_rows(self):
        source = (ROOT / "scripts" /
                  "run_queue_lifecycle_regression53.sh").read_text()
        match = re.search(
            r"readonly ENGINE_PROCESS_TESTS=\((.*?)\n\)",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, "missing ENGINE_PROCESS_TESTS manifest")
        return [
            line.strip()
            for line in match.group(1).splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]

    # 功能：从 SystemVerilog 源码提取指定派生 class 的完整声明体，供 process
    #   run_phase 清单或 production engine seam 审计。
    # 输入/输出及副作用：name/source 为只读输入；返回首个匹配 class 的正文字符串，
    #   不修改源码或实例化 UVM 对象。
    # 失败边界：类缺失、继承声明损坏或 endclass 缺失时立即断言失败，不回退到相邻类。
    def _class_body(self, name, source):
        match = re.search(
            rf"\bclass\s+{re.escape(name)}\s+extends\s+"
            rf"[A-Za-z_][A-Za-z0-9_]*\s*;(.*?)\bendclass\b",
            source,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(match, f"missing SystemVerilog class {name}")
        return match.group(1)

    # 功能：移除 SystemVerilog 行注释与块注释，同时保留换行边界，供 exact-count
    #   静态门禁避免把注释中的伪声明或伪调用当成实现。
    # 输入/输出及副作用：source 为只读字符串；返回去注释副本，不修改仓库文件。
    # 失败/边界：仅用于受控仓库源码的结构 token 扫描；不展开宏，也不解析字符串内
    #   的注释标记，调用方不得把结果当成通用 SystemVerilog parser。
    def _without_sv_comments(self, source):
        source = re.sub(r"/\*.*?\*/", "", source, flags=re.DOTALL)
        return re.sub(r"//[^\n]*(?:\n|\Z)", "\n", source)

    # 功能：从指定 physical process 的 run_phase 提取全部直接动作，并把 check、
    #   recovery 与 factory seed 规范化为可逐项比较的 schedule token。
    # 输入/输出及副作用：name/source 为只读输入；返回 objection 之间的有序 token
    #   列表，不执行 SystemVerilog、不修改 factory 或仓库文件。
    # 失败边界：run_phase 缺失/重复、objection 骨架漂移、出现未识别语句或动作参数
    #   变化时立即断言失败，不静默忽略新增业务调用。
    def _run_phase_action_tokens(self, name, source):
        body = self._class_body(name, source)
        run_phases = re.findall(
            r"\bvirtual\s+task\s+run_phase\s*\([^;]+;"
            r"(.*?)\bendtask\b",
            body,
            flags=re.DOTALL,
        )
        self.assertEqual(len(run_phases), 1, f"invalid run_phase count in {name}")

        phase_body = re.sub(r"/\*.*?\*/", "", run_phases[0],
                            flags=re.DOTALL)
        phase_body = re.sub(r"//[^\n]*(?:\n|\Z)", "\n", phase_body)
        statement_pattern = re.compile(
            r"(?m)^[ \t]*"
            r"([A-Za-z_][A-Za-z0-9_]*(?:\.[A-Za-z_][A-Za-z0-9_]*)?)"
            r"\s*\(([^;]*)\)\s*;[ \t]*(?:\n|\Z)"
        )
        statements = [
            (match.group(1), re.sub(r"\s+", "", match.group(2)))
            for match in statement_pattern.finditer(phase_body)
        ]
        residue = statement_pattern.sub("", phase_body)
        self.assertEqual(
            residue.strip(), "", f"unsupported run_phase syntax in {name}"
        )
        self.assertGreaterEqual(len(statements), 2, name)
        self.assertEqual(statements[0], ("phase.raise_objection", "this"), name)
        self.assertEqual(statements[-1], ("phase.drop_objection", "this"), name)

        tokens = []
        for action, arguments in statements[1:-1]:
            if action == "seed_submission_factory_epoch":
                token = "seed:submission"
                if arguments:
                    token = f"{token}({arguments})"
            elif action == "seed_raw_snapshot_factory_epoch":
                token = "seed:raw"
                if arguments:
                    token = f"{token}({arguments})"
            elif action.startswith("run_task16_recovery_"):
                token = f"recovery:{action}({arguments})"
            elif action.startswith("check_"):
                token = f"check:{action}({arguments})"
            else:
                token = f"unexpected:{action}({arguments})"
            tokens.append(token)
        return tokens

    # 功能：确认 fixture C66 在 legacy engine cleanup 后把 holder-backed CAS recovery
    #   作为 task 内最后动作，并返回对应 nested-last schedule token。
    # 输入/输出及副作用：source 为 engine test 源码只读输入；返回固定 R06 token，
    #   不执行 cleanup、CAS、线程同步或 DUT I/O。
    # 失败边界：C66 task 缺失/重复、R06 调用不是唯一 recovery、cleanup 顺序漂移，
    #   或 R06 后仍有语句时断言失败。
    def _nested_mmio_recovery_token(self, source):
        task_bodies = re.findall(
            r"\btask\s+automatic\s+check_pre_mmio_arm_capability\s*"
            r"\([^;]*\)\s*;(.*?)\bendtask\b",
            source,
            flags=re.DOTALL,
        )
        self.assertEqual(len(task_bodies), 1, "invalid C66 task count")
        task_body = re.sub(r"/\*.*?\*/", "", task_bodies[0],
                           flags=re.DOTALL)
        task_body = re.sub(r"//[^\n]*(?:\n|\Z)", "\n", task_body)
        recovery_calls = re.findall(
            r"\b(run_task16_recovery_[A-Za-z0-9_]+)\s*\(\s*\)\s*;",
            task_body,
        )
        recovery_name = "run_task16_recovery_concurrent_cas_winner"
        self.assertEqual(recovery_calls, [recovery_name])
        self.assertRegex(
            task_body,
            r"engine\s*\.\s*shutdown\s*\(\s*status\s*\)\s*;\s*"
            r"expect_status\s*\(\s*\"MMIO_ARM_SHUTDOWN\"\s*,\s*status\s*,\s*"
            r"RDMA_SC_OK\s*\)\s*;\s*"
            rf"{recovery_name}\s*\(\s*\)\s*;\s*\Z",
        )
        return (
            "nested-last:check_pre_mmio_arm_capability->"
            f"{recovery_name}()"
        )

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

    # 功能：从 core 回归数组提取公开 logical test 名，核对 CMQ manifest 的每一行
    #   都由统一 core runner 执行一次。
    # 输入/输出及副作用：source 为 Make/runner 文本的只读输入；返回 CORE_TESTS
    #   数组中的顺序列表，不启动仿真或修改文件。
    # 失败边界：CORE_TESTS 声明缺失、闭合括号缺失或 token 不是合法 SV 标识符时
    #   返回空列表并由调用测试明确失败。
    def _core_rows(self):
        source = (ROOT / "scripts" / "run_queue_lifecycle_regression53.sh").read_text()
        match = re.search(
            r"readonly CORE_TESTS=\((.*?)\n\)", source, flags=re.DOTALL
        )
        self.assertIsNotNone(match, "missing CORE_TESTS manifest")
        return [
            line.strip()
            for line in match.group(1).splitlines()
            if line.strip() and not line.lstrip().startswith("#")
        ]

    # 功能：确认 gate 清单与固定 CMQ 测试顺序完全一致，并拒绝重复或非法 token。
    # 输入输出及副作用：读取仓库文本；断言失败只影响当前 unittest，不产生外部副作用。
    # 失败边界：缺项、额外项、重复项或不符合 SV 标识符规则时测试失败。
    def test_exact_rows(self):
        expected = FINAL_CMQ_ROWS
        rows = self._rows()
        self.assertEqual(rows, expected)
        self.assertEqual(len(rows), len(set(rows)))
        self.assertTrue(all(re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", row)
                            for row in rows))

    # 功能：确认最终 CMQ gate 的每个 logical test 在 core regression 中注册且只
    #   出现一次，防止 manifest 看似扩展但实际被 runner 遗漏。
    # 输入/输出及副作用：只读 gate、runner 和 Makefile 文本；不执行 VCS 或修改
    #   测试清单。
    # 失败边界：CMQ 行缺少 include、CORE_TESTS 中缺失/重复、Make target 仍固定
    #   旧数量或未逐行校验时测试失败。
    def test_final_rows_are_registered_in_core_gate(self):
        rows = self._rows()
        core_rows = self._core_rows()
        package = (ROOT / "tests" / "rdma_unit_test_pkg.sv").read_text()
        makefile = (ROOT / "sim" / "Makefile").read_text()
        cmq_body = self._make_target_body("cmq_gate", makefile)

        self.assertEqual(rows, FINAL_CMQ_ROWS)
        for row in FINAL_CMQ_ROWS:
            self.assertEqual(core_rows.count(row), 1, row)
            self.assertRegex(package, rf'include "unit/{re.escape(row)}\.sv"')
        self.assertRegex(cmq_body, r"\$\{#cmq_tests\[@\]\} == 11")
        self.assertNotIn("requires exactly six tests", cmq_body)

    # 功能：检查 README 与验证记录公开 CMQ 的真实驱动归档、observed API、journal/
    #   fence 语义和最终证据入口，确保使用者不会把旧的六项 gate 当作完整契约。
    # 输入/输出及副作用：仅读取两个 Markdown 文件并断言关键锚点，不写入文档或
    #   产生构建产物。
    # 失败边界：入口链接、归档标识、observed execution、journal/fence 语义或
    #   verification record 缺失时 fail-closed。
    def test_documentation_contract(self):
        readme = (ROOT / "README.md").read_text(encoding="utf-8")
        record_path = ROOT / "docs" / "rdma-cmq-contract-foundation-verification.md"
        self.assertTrue(record_path.is_file(), "missing CMQ verification record")
        record = record_path.read_text(encoding="utf-8")

        for needle in (
                "rdma-cmq-contract-foundation-verification.md",
                "dpu_kernel_rdma-version_0.1.34",
                "execute_observed",
                "journal",
                "fence",
        ):
            self.assertIn(needle, readme, needle)
        for needle in (
                "rdma_cmq_engine_models_test",
                "submission_effect",
                "reset",
                "RDMA_ARCHIVE_SHA256",
                "UVM_WARNING",
                "UVM_ERROR",
                "UVM_FATAL",
        ):
            self.assertIn(needle, record, needle)

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

    # 功能：冻结一个 engine 逻辑行到十八物理进程的合法、唯一且有序映射，确保
    #   base 后八项、profile-wide 与 retention 前缀各自拥有独立 simulator lifetime。
    # 输入输出及副作用：读取 process/cmq/CORE_TESTS 清单并执行断言；不修改 runner 或清单。
    # 失败边界：物理项缺失、重复、非法、乱序，或逻辑行不再 exact-once 时测试失败。
    def test_engine_process_manifest(self):
        process_rows = self._engine_process_rows()
        self.assertEqual(process_rows, ENGINE_PROCESS_TESTS)
        self.assertEqual(
            self._regression_engine_process_rows(), ENGINE_PROCESS_TESTS
        )
        self.assertEqual(len(process_rows), 18)
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

    # 功能：冻结十八个 physical process 的完整业务动作顺序，包括 bounded retention、
    #   R01–R05、submission/raw seed，以及 C66 cleanup 后 nested-last R06。
    # 输入/输出及副作用：只读 engine test 源码与显式 schedule authority；逐 leaf
    #   exact-equal，不运行 simulator、factory override 或 recovery I/O。
    # 失败边界：leaf 迁移、动作增删/乱序、range 参数变化、seed epoch 漂移，或
    #   C66 cleanup/R06 末尾关系被破坏时测试失败。
    def test_engine_process_action_schedule(self):
        source = (ROOT / "tests" / "unit" /
                  "rdma_cmq_engine_test.sv").read_text()
        self.assertEqual(
            list(ENGINE_PROCESS_ACTIONS), ENGINE_PROCESS_TESTS
        )

        for process_test in ENGINE_PROCESS_TESTS:
            actual = self._run_phase_action_tokens(process_test, source)
            if process_test == "rdma_cmq_engine_mmio_arm_process_test":
                actual.append(self._nested_mmio_recovery_token(source))
            self.assertEqual(
                tuple(actual),
                ENGINE_PROCESS_ACTIONS[process_test],
                process_test,
            )

    # 功能：冻结 rdma_cmq_engine 被测试子类 override 的六个 protected virtual seam，
    #   包括名称、返回类型、visibility、virtual dispatch 与关键参数 direction。
    # 输入/输出及副作用：仅读取 production engine 源码并规范化声明空白；不编译、
    #   不实例化 engine，也不修改 override 或 fault-injection 状态。
    # 失败边界：seam 缺失/重复、移出 engine、降为 non-virtual/private，或返回值、
    #   参数类型/direction/顺序变化时 fail-closed。
    def test_engine_protected_virtual_seam_abi(self):
        source = (ROOT / "src" / "core" / "rdma_cmq_engine.sv").read_text()
        engine_body = self._class_body("rdma_cmq_engine", source)

        for seam_name, expected in ENGINE_PROTECTED_VIRTUAL_SEAMS.items():
            declarations = re.findall(
                r"(?m)^[ \t]*(protected\s+virtual\s+function\s+"
                r"[A-Za-z_][A-Za-z0-9_]*\s+"
                rf"{re.escape(seam_name)}\s*\([^;]*\)\s*;)",
                engine_body,
                flags=re.DOTALL,
            )
            self.assertEqual(
                len(declarations), 1, f"invalid seam declaration {seam_name}"
            )
            actual = re.sub(r"\s+", " ", declarations[0].strip())
            actual = re.sub(r"\s*([(),;])\s*", r"\1", actual)
            self.assertEqual(actual, expected, seam_name)

    # 功能：冻结 model package 中 engine-model/execution/value/typed-snapshot/control-plane 五个 include 的唯一相邻顺序。
    # 输入/输出及副作用：只读 rdma_model_pkg.sv 并提取 include token；不展开宏、不创建编译产物。
    # 失败/边界：任一 include 缺失/重复、typed contract 未紧跟 value contract，或 control-plane 被移到 typed contract 之前时失败。
    def test_typed_snapshot_model_include_order(self):
        source = (ROOT / "src" / "model" / "rdma_model_pkg.sv").read_text()
        includes = re.findall(r'`include\s+"([^"]+)"', source)

        for name in MODEL_TYPED_SNAPSHOT_INCLUDE_ORDER:
            self.assertEqual(includes.count(name), 1, name)
        first = includes.index(MODEL_TYPED_SNAPSHOT_INCLUDE_ORDER[0])
        self.assertEqual(
            includes[first:first + len(MODEL_TYPED_SNAPSHOT_INCLUDE_ORDER)],
            MODEL_TYPED_SNAPSHOT_INCLUDE_ORDER,
        )

    # 功能：冻结十八 leaf 的 UVM 注册及 run_phase 展平后六十八个逻辑 fixture 的
    #   exact-once 原始顺序，避免 base 后八项、profile-wide 或 retention 前缀重新共处。
    # 输入输出及副作用：只读解析 engine test 源码并断言 class/宏/调用列表；不运行仿真。
    # 失败边界：leaf 未注册、fixture 漏跑/重复/乱序或被跨 shard 拆分时测试失败。
    def test_engine_process_fixture_inventory(self):
        source = (ROOT / "tests" / "unit" /
                  "rdma_cmq_engine_test.sv").read_text()
        flattened_calls = []
        for process_test in ENGINE_PROCESS_TESTS:
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
        self.assertEqual(len(flattened_calls), 68)
        self.assertEqual(len(flattened_calls), len(set(flattened_calls)))

        base = self._class_body(ENGINE_LOGICAL_TEST, source)
        suffix = self._class_body(
            "rdma_cmq_engine_base_suffix_process_test", source
        )
        for body, expected_calls in (
                (base, ENGINE_FIXTURES[:8]),
                (suffix, ENGINE_FIXTURES[8:16])):
            run_phase = re.search(
                r"\bvirtual\s+task\s+run_phase\s*\([^;]+;"
                r"(.*?)\bendtask\b",
                body,
                flags=re.DOTALL,
            )
            self.assertIsNotNone(run_phase)
            calls = re.findall(
                r"\b(check_[A-Za-z0-9_]+)\s*\(([^;]*)\)\s*;",
                run_phase.group(1),
            )
            self.assertTrue(
                all(arguments.strip() == "" for _, arguments in calls)
            )
            self.assertEqual(
                [fixture for fixture, _ in calls],
                expected_calls,
            )

        profile_wide = self._class_body(
            "rdma_cmq_engine_profile_wide_process_test", source
        )
        profile_calls = re.findall(
            r"\b(check_[A-Za-z0-9_]+)\s*\(([^;]*)\)\s*;",
            re.search(
                r"\bvirtual\s+task\s+run_phase\s*\([^;]+;"
                r"(.*?)\bendtask\b",
                profile_wide,
                flags=re.DOTALL,
            ).group(1),
        )
        self.assertEqual(
            profile_calls,
            [("check_profile_wide_cqe_format_authority", "")],
        )

    # 功能：证明 observed retention 的两个物理调用以 inclusive bounds 有序、无重叠地精确覆盖 row 0..14。
    # 输入输出及副作用：只读解析十四个 leaf 的 run_phase 与 bounded task 声明；返回 unittest 断言结果，不运行仿真。
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
                ("rdma_cmq_engine_retention_prefix_process_test", 0, 2),
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
    #   十八片 strict all-of。
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

    # 功能：验证 runner 对缺失 CLI 参数和非十八项 engine manifest 失败关闭，
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
        runner_source = ENGINE_LOGICAL_RUNNER.read_text(encoding="utf-8")
        self.assertIn("${#physical_tests[@]} != 18", runner_source)
        self.assertIn(
            "engine process manifest requires exactly eighteen tests",
            runner_source,
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
            self.assertIn("exactly eighteen", malformed_manifest.stderr)

if __name__ == "__main__":
    unittest.main()
