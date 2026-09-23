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

ENGINE_TYPED_SNAPSHOT_SEAMS = {
    "checked_function_snapshot": (
        "protected function rdma_status checked_function_snapshot("
        "rdma_function_handle source,string label,"
        "rdma_status_code_e failure_code,"
        "output rdma_function_handle snapshot);"
    ),
    "checked_handle_snapshot": (
        "protected function rdma_status checked_handle_snapshot("
        "rdma_handle source,string label,rdma_status_code_e failure_code,"
        "output rdma_handle snapshot);"
    ),
    "checked_opcode_snapshot": (
        "protected function rdma_status checked_opcode_snapshot("
        "rdma_cmq_opcode_key source,string label,"
        "rdma_status_code_e failure_code,"
        "output rdma_cmq_opcode_key snapshot);"
    ),
    "checked_expected_snapshot": (
        "protected function rdma_status checked_expected_snapshot("
        "rdma_cmq_expected_response source,string label,"
        "rdma_status_code_e failure_code,"
        "output rdma_cmq_expected_response snapshot);"
    ),
    "checked_image_snapshot": (
        "protected function rdma_status checked_image_snapshot("
        "rdma_hw_image source,string label,rdma_status_code_e failure_code,"
        "output rdma_hw_image snapshot);"
    ),
    "checked_canonical_image_snapshot": (
        "protected function rdma_status checked_canonical_image_snapshot("
        "rdma_hw_image source,string label,rdma_status_code_e failure_code,"
        "output rdma_hw_image snapshot);"
    ),
}

ENGINE_BODY_VALUE_SEAMS = {
    "handle_value_key": (
        "function automatic string "
        "rdma_cmq_handle_value_key(input rdma_handle handle);",
        "protected function automatic string "
        "handle_value_key(rdma_handle handle);",
        "return rdma_cmq_handle_value_key(handle);",
    ),
    "has_exact_object_type": (
        "function automatic bit rdma_cmq_has_exact_object_type("
        "input uvm_object value,input uvm_object_wrapper expected_type);",
        "protected function automatic bit has_exact_object_type("
        "uvm_object value,uvm_object_wrapper expected_type);",
        "return rdma_cmq_has_exact_object_type(value,expected_type);",
    ),
    "has_optional_exact_object_type": (
        "function automatic bit rdma_cmq_has_optional_exact_object_type("
        "input uvm_object value,input uvm_object_wrapper expected_type);",
        "protected function automatic bit has_optional_exact_object_type("
        "uvm_object value,uvm_object_wrapper expected_type);",
        "return rdma_cmq_has_optional_exact_object_type("
        "value,expected_type);",
    ),
    "core_body_shell_is_exact": (
        "function automatic bit rdma_cmq_core_body_shell_is_exact("
        "input rdma_hw_model body);",
        "protected function automatic bit core_body_shell_is_exact("
        "rdma_hw_model body);",
        "return rdma_cmq_core_body_shell_is_exact(body);",
    ),
    "nested_value_key": (
        "function automatic string rdma_cmq_nested_value_key("
        "input uvm_object value);",
        "protected function automatic string nested_value_key("
        "uvm_object value);",
        "return rdma_cmq_nested_value_key(value);",
    ),
    "body_value_key": (
        "function automatic string rdma_cmq_body_value_key("
        "input rdma_hw_model body);",
        "protected function automatic string body_value_key("
        "rdma_hw_model body);",
        "return rdma_cmq_body_value_key(body);",
    ),
    "append_body_graph_nodes": (
        "function automatic void rdma_cmq_append_body_graph_nodes("
        "input rdma_hw_model body,ref uvm_object nodes[$]);",
        "protected function automatic void append_body_graph_nodes("
        "rdma_hw_model body,ref uvm_object nodes[$]);",
        "rdma_cmq_append_body_graph_nodes(body,nodes);",
    ),
}

ENGINE_JOURNAL_VALUE_SEAMS = {
    "same_journal_owner_value": (
        "function automatic bit rdma_cmq_same_journal_owner_value("
        "input rdma_cmq_recovery_owner lhs,"
        "input rdma_cmq_recovery_owner rhs);",
        "protected function bit same_journal_owner_value("
        "rdma_cmq_recovery_owner lhs,rdma_cmq_recovery_owner rhs);",
        "return rdma_cmq_same_journal_owner_value(lhs,rhs);",
    ),
    "same_journal_owner_detached_value": (
        "function automatic bit rdma_cmq_same_journal_owner_detached_value("
        "input rdma_cmq_recovery_owner lhs,"
        "input rdma_cmq_recovery_owner rhs);",
        "protected function bit same_journal_owner_detached_value("
        "input rdma_cmq_recovery_owner lhs,"
        "input rdma_cmq_recovery_owner rhs);",
        "return rdma_cmq_same_journal_owner_detached_value(lhs,rhs);",
    ),
    "same_journal_dma_context_value": (
        "function automatic bit rdma_cmq_same_journal_dma_context_value("
        "input rdma_dma_request_context lhs,"
        "input rdma_dma_request_context rhs);",
        "protected function bit same_journal_dma_context_value("
        "rdma_dma_request_context lhs,rdma_dma_request_context rhs);",
        "return rdma_cmq_same_journal_dma_context_value(lhs,rhs);",
    ),
    "same_journal_dma_context_detached_value": (
        "function automatic bit "
        "rdma_cmq_same_journal_dma_context_detached_value("
        "input rdma_dma_request_context lhs,"
        "input rdma_dma_request_context rhs);",
        "protected function bit same_journal_dma_context_detached_value("
        "input rdma_dma_request_context lhs,"
        "input rdma_dma_request_context rhs);",
        "return rdma_cmq_same_journal_dma_context_detached_value(lhs,rhs);",
    ),
    "same_journal_mapping_public_value": (
        "function automatic bit rdma_cmq_same_journal_mapping_public_value("
        "input rdma_dma_mapping lhs,input rdma_dma_mapping rhs);",
        "protected function bit same_journal_mapping_public_value("
        "rdma_dma_mapping lhs,rdma_dma_mapping rhs);",
        "return rdma_cmq_same_journal_mapping_public_value(lhs,rhs);",
    ),
    "same_journal_command_identity_value": (
        "function automatic bit "
        "rdma_cmq_same_journal_command_identity_value("
        "input rdma_cmq_command_identity lhs,"
        "input rdma_cmq_command_identity rhs);",
        "protected function bit same_journal_command_identity_value("
        "rdma_cmq_command_identity lhs,rdma_cmq_command_identity rhs);",
        "return rdma_cmq_same_journal_command_identity_value(lhs,rhs);",
    ),
    "same_journal_binding_value": (
        "function automatic bit rdma_cmq_same_journal_binding_value("
        "input rdma_function_binding lhs,"
        "input rdma_function_binding rhs);",
        "protected function bit same_journal_binding_value("
        "input rdma_function_binding lhs,"
        "input rdma_function_binding rhs);",
        "return rdma_cmq_same_journal_binding_value(lhs,rhs);",
    ),
    "same_reset_isolation_proof_value": (
        "function automatic bit "
        "rdma_cmq_same_reset_isolation_proof_value("
        "input rdma_cmq_reset_isolation_proof lhs,"
        "input rdma_cmq_reset_isolation_proof rhs);",
        "protected function bit same_reset_isolation_proof_value("
        "input rdma_cmq_reset_isolation_proof lhs,"
        "input rdma_cmq_reset_isolation_proof rhs);",
        "return rdma_cmq_same_reset_isolation_proof_value(lhs,rhs);",
    ),
}

ENGINE_JOURNAL_HANDLE_PATHS = {
    "same_journal_owner_value": (
        ("lhs.resource_h.same_instance(rhs.resource_h)",),
        ("rdma_cmq_same_handle_value(",),
    ),
    "same_journal_owner_detached_value": (
        ("rdma_cmq_same_handle_value(lhs.resource_h,rhs.resource_h)",),
        (".same_instance(",),
    ),
    "same_journal_dma_context_value": (
        (
            "lhs.function_h.same_instance(rhs.function_h)",
            "lhs.owner_h.same_instance(rhs.owner_h)",
        ),
        ("rdma_cmq_same_handle_value(",),
    ),
    "same_journal_dma_context_detached_value": (
        (
            "rdma_cmq_same_handle_value(lhs.function_h,rhs.function_h)",
            "rdma_cmq_same_handle_value(lhs.owner_h,rhs.owner_h)",
        ),
        (".same_instance(",),
    ),
    "same_journal_mapping_public_value": (
        (
            "lhs.function_h.same_instance(rhs.function_h)",
            "lhs.owner_h.same_instance(rhs.owner_h)",
        ),
        ("rdma_cmq_same_handle_value(",),
    ),
    "same_journal_binding_value": (
        (
            "lhs.get_object_type()!=rdma_function_binding::get_type()",
            "rhs.get_object_type()!=rdma_function_binding::get_type()",
            "lhs.snapshot_identity_nonfatal(lhs_identity)",
            "rhs.snapshot_identity_nonfatal(rhs_identity)",
            "lhs_status==null",
            "!lhs_status.ok()",
            "rhs_status==null",
            "!rhs_status.ok()",
            "lhs_identity==null",
            "rhs_identity==null",
            "lhs_identity.same_incarnation(rhs_identity)",
            "lhs.interrupt_vectors.size()!=rhs.interrupt_vectors.size()",
            "lhs.owner_h.get_object_type()!=rhs.owner_h.get_object_type()",
            "lhs.owner_h.same_instance(rhs.owner_h)",
            "foreach(lhs.pcie.bar[i])",
            "foreach(lhs.interrupt_vectors[i])",
        ),
        (
            "snapshot_complete_nonfatal(",
            "function_identity_snapshot(",
            ".validate(",
            "rdma_cmq_append_function_binding_v1(",
        ),
    ),
    "same_reset_isolation_proof_value": (
        (
            "lhs.isolated_identity.same_incarnation("
            "rhs.isolated_identity)",
            "lhs.replacement_identity.same_incarnation("
            "rhs.replacement_identity)",
            "lhs.isolated_request_indices.size()!="
            "rhs.isolated_request_indices.size()",
            "lhs.isolated_image_digests.size()!="
            "rhs.isolated_image_digests.size()",
            "lhs.isolated_authority_digests.size()!="
            "rhs.isolated_authority_digests.size()",
            "lhs.isolated_recovery_owners.size()!="
            "rhs.isolated_recovery_owners.size()",
            "foreach(lhs.isolated_request_indices[i])",
            "rdma_cmq_same_journal_owner_value("
            "lhs.isolated_recovery_owners[i],"
            "rhs.isolated_recovery_owners[i])",
        ),
        ("rdma_cmq_same_journal_owner_detached_value(",),
    ),
}

JOURNAL_BINDING_COMPARATOR_CHECKS = (
    "JOURNAL_BINDING_COMPARATOR_FIXTURE_DETACHED",
    "JOURNAL_BINDING_COMPARATOR_NULL_BOTH",
    "JOURNAL_BINDING_COMPARATOR_NULL_LHS",
    "JOURNAL_BINDING_COMPARATOR_NULL_RHS",
    "JOURNAL_BINDING_COMPARATOR_EQUAL",
    "JOURNAL_BINDING_COMPARATOR_ALIAS_EQUAL",
    "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_SETUP",
    "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_LHS",
    "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_RHS",
    "JOURNAL_BINDING_COMPARATOR_OUTER_SUBTYPE_BOTH",
    "JOURNAL_BINDING_COMPARATOR_PCIE_NULL_LHS",
    "JOURNAL_BINDING_COMPARATOR_PCIE_NULL_RHS",
    "JOURNAL_BINDING_COMPARATOR_PCIE_NULL_BOTH",
    "JOURNAL_BINDING_COMPARATOR_INVALID_IDENTITY_EQUAL",
    "JOURNAL_BINDING_COMPARATOR_IDENTITY_SUBTYPE_BOTH",
    "JOURNAL_BINDING_COMPARATOR_IDENTITY_SUBTYPE_LHS",
    "JOURNAL_BINDING_COMPARATOR_IDENTITY_SUBTYPE_RHS",
    "JOURNAL_BINDING_COMPARATOR_IDENTITY_RESET_EPOCH",
    "JOURNAL_BINDING_COMPARATOR_IDENTITY_ROUTE",
    "JOURNAL_BINDING_COMPARATOR_PCIE_SUBTYPE_EXTENSION_IGNORED",
    "JOURNAL_BINDING_COMPARATOR_PCIE_SUBTYPE_BASE",
    "JOURNAL_BINDING_COMPARATOR_PCIE_BASE_SUBTYPE",
    "JOURNAL_BINDING_COMPARATOR_PCIE_SUBTYPE_FIXTURE",
    "JOURNAL_BINDING_COMPARATOR_BAR_SUBTYPE_EXTENSION_IGNORED",
    "JOURNAL_BINDING_COMPARATOR_BAR_SUBTYPE_BASE",
    "JOURNAL_BINDING_COMPARATOR_BAR_BASE_SUBTYPE",
    "JOURNAL_BINDING_COMPARATOR_BAR_SUBTYPE_FIXTURE",
    "JOURNAL_BINDING_COMPARATOR_FUNCTION_UID",
    "JOURNAL_BINDING_COMPARATOR_PCIE_BDF",
    "JOURNAL_BINDING_COMPARATOR_PCIE_PARENT_BDF",
    "JOURNAL_BINDING_COMPARATOR_PCIE_VF_INDEX",
    "JOURNAL_BINDING_COMPARATOR_PCIE_MSE",
    "JOURNAL_BINDING_COMPARATOR_PCIE_BME",
    "JOURNAL_BINDING_COMPARATOR_NOTIFY_BAR_ID",
    "JOURNAL_BINDING_COMPARATOR_NOTIFY_BASE",
    "JOURNAL_BINDING_COMPARATOR_NOTIFY_SIZE",
    "JOURNAL_BINDING_COMPARATOR_NOTIFY_TABLE_SEL",
    "JOURNAL_BINDING_COMPARATOR_NOTIFY_TABLE_INDEX",
    "JOURNAL_BINDING_COMPARATOR_HOST_ID",
    "JOURNAL_BINDING_COMPARATOR_PFVF_ID",
    "JOURNAL_BINDING_COMPARATOR_RDMA_VF_ID",
    "JOURNAL_BINDING_COMPARATOR_GLOBAL_FUNCTION_ID",
    "JOURNAL_BINDING_COMPARATOR_VSI_ID",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_REQUESTER_BDF",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_PASID_VALID",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_PASID",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_DOMAIN_VALID",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_DMA_DOMAIN_ID",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MIN_CQ",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_CQ",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MIN_SRQ",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_SRQ",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_CEQ",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_AEQ",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_WQ_SGE",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_RING_BYTES",
    "JOURNAL_BINDING_COMPARATOR_QUEUE_CAP_MAX_SGB_BYTES",
    "JOURNAL_BINDING_COMPARATOR_BAR_NULL_LHS",
    "JOURNAL_BINDING_COMPARATOR_BAR_NULL_RHS",
    "JOURNAL_BINDING_COMPARATOR_BAR_NULL_BOTH",
    "JOURNAL_BINDING_COMPARATOR_BAR5_ID",
    "JOURNAL_BINDING_COMPARATOR_BAR5_BASE",
    "JOURNAL_BINDING_COMPARATOR_BAR5_SIZE",
    "JOURNAL_BINDING_COMPARATOR_BAR5_ENABLED",
    "JOURNAL_BINDING_COMPARATOR_BAR_ORDER",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_RHS_EXTRA",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_LHS_EXTRA",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_CARDINALITY_RESTORED",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_FUNCTION_LOCAL",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_HARDWARE_EQ",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_MSIX_INDEX",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_ENABLED",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_ORDER",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_RESTORED",
    "JOURNAL_BINDING_COMPARATOR_VECTOR_BOTH_EMPTY",
    "JOURNAL_BINDING_COMPARATOR_STATE",
    "JOURNAL_BINDING_COMPARATOR_GENERATION",
    "JOURNAL_BINDING_COMPARATOR_NOTIFY_VALID",
    "JOURNAL_BINDING_COMPARATOR_NOTIFY_READY",
    "JOURNAL_BINDING_COMPARATOR_DMI_VALID",
    "JOURNAL_BINDING_COMPARATOR_DMI_READY",
    "JOURNAL_BINDING_COMPARATOR_VFT_VALID",
    "JOURNAL_BINDING_COMPARATOR_VFT_READY",
    "JOURNAL_BINDING_COMPARATOR_OWNER_NULL_RHS",
    "JOURNAL_BINDING_COMPARATOR_OWNER_NULL_LHS",
    "JOURNAL_BINDING_COMPARATOR_OWNER_NULL_BOTH",
    "JOURNAL_BINDING_COMPARATOR_OWNER_INCARNATION",
    "JOURNAL_BINDING_COMPARATOR_OWNER_WRAPPER",
    "JOURNAL_BINDING_COMPARATOR_OWNER_SUBTYPE_EXTENSION_IGNORED",
    "JOURNAL_BINDING_COMPARATOR_OWNER_SUBTYPE_NO_CLONE",
    "JOURNAL_BINDING_COMPARATOR_VALIDATOR_INVALID_EQUAL",
    "JOURNAL_BINDING_COMPARATOR_RESTORED",
)

JOURNAL_ORDERED_TUPLE_CHECKS = (
    "JOURNAL_ORDERED_TUPLE_NULL_BOTH",
    "JOURNAL_ORDERED_TUPLE_NULL_REQUEST",
    "JOURNAL_ORDERED_TUPLE_NULL_RECORD",
    "JOURNAL_ORDERED_TUPLE_EMPTY_BOTH",
    "JOURNAL_ORDERED_TUPLE_EMPTY_REQUEST",
    "JOURNAL_ORDERED_TUPLE_EMPTY_RECORD",
    "JOURNAL_ORDERED_TUPLE_SINGLE_EQUAL",
    "JOURNAL_ORDERED_TUPLE_MULTI_EQUAL_IGNORES_OTHER_FIELDS",
    "JOURNAL_ORDERED_TUPLE_REQUEST_EXTRA",
    "JOURNAL_ORDERED_TUPLE_RECORD_EXTRA",
    "JOURNAL_ORDERED_TUPLE_CARDINALITY_RESTORED",
    "JOURNAL_ORDERED_TUPLE_NULL_REQUEST_ITEM",
    "JOURNAL_ORDERED_TUPLE_NULL_RECORD_ITEM",
    "JOURNAL_ORDERED_TUPLE_NULL_BOTH_ITEMS",
    "JOURNAL_ORDERED_TUPLE_REQUEST_INDEX",
    "JOURNAL_ORDERED_TUPLE_IMAGE_DIGEST",
    "JOURNAL_ORDERED_TUPLE_AUTHORITY_DIGEST",
    "JOURNAL_ORDERED_TUPLE_ORDER",
    "JOURNAL_ORDERED_TUPLE_DUPLICATE_EQUAL",
    "JOURNAL_ORDERED_TUPLE_DIGEST_X_NORMALIZATION",
    "JOURNAL_ORDERED_TUPLE_NORMALIZED_DIGEST_EQUAL",
    "JOURNAL_ORDERED_TUPLE_RESTORED",
)

# 设计说明：九号 leaf 不再经 engine protected wrapper 转发，package 谓词只做
# null/cardinality 前置防护及有序三列比较；保留 case inequality 的源码拼写。
ORDERED_TUPLE_PACKAGE_DECL = (
    "function automatic bit "
    "rdma_cmq_recovery_batch_ordered_item_tuple_matches("
    "input rdma_cmq_submission_recovery_request request,"
    "input rdma_cmq_batch_submission_record journal_record);"
)

ORDERED_TUPLE_PACKAGE_BODY = (
    "if(request==null||journal_record==null||request.items.size()==0||"
    "request.items.size()!=journal_record.items.size())return1'b0;"
    "foreach(request.items[i])begin"
    "if(request.items[i]==null||journal_record.items[i]==null||"
    "request.items[i].request_index!=journal_record.items[i].request_index||"
    "request.items[i].image_digest!==journal_record.items[i].image_digest||"
    "request.items[i].authority_digest!=="
    "journal_record.items[i].authority_digest)return1'b0;"
    "endreturn1'b1;"
)

# 设计说明：这四段仍属于 engine protected validator，完整冻结短路操作数及
# INVALID_ARGUMENT 文案；仅把第五段 foreach 交给新只读 package predicate。
RECOVERY_BATCH_GRAPH_GATE = (
    "if(request==null||journal_record==null||"
    "request.expected_function_identity==null||"
    "journal_record.function_identity==null||request.binding==null||"
    "journal_record.binding==null||request.cmq_h==null||"
    "journal_record.cmq_h==null||request.doorbell_image==null||"
    "journal_record.doorbell_image==null||request.items.size()==0||"
    "request.items.size()!=journal_record.items.size())"
    "returnjournal_status(RDMA_SC_INVALID_ARGUMENT,"
    '"CMQrecoverybatchfull-valuegraphisincomplete");'
)

RECOVERY_BATCH_CARRIED_DIGEST_GATE = (
    "if(request.batch_digest!==recomputed_request_batch_digest||"
    "journal_record.batch_digest!==recomputed_journal_batch_digest)"
    "returnjournal_status(RDMA_SC_INVALID_ARGUMENT,"
    '"CMQrecoverybatchcarrieddigestdoesnotmatchitsgraph");'
)

RECOVERY_BATCH_CROSS_DIGEST_GATE = (
    "if(recomputed_request_batch_digest!==recomputed_journal_batch_digest)"
    "returnjournal_status(RDMA_SC_INVALID_ARGUMENT,"
    '"CMQrecoveryrequestandjournalbatchdigestsdisagree");'
)

RECOVERY_BATCH_FULL_VALUE_GATE = (
    "if(request.batch_key!=journal_record.batch_key||"
    "request.batch_id!=journal_record.batch_id||"
    "!request.expected_function_identity.same_incarnation("
    "journal_record.function_identity)||"
    "!same_journal_binding_value(request.binding,journal_record.binding)||"
    "!same_handle(request.cmq_h,journal_record.cmq_h)||"
    "!same_image_value(request.doorbell_image,journal_record.doorbell_image)||"
    "request.final_pi!=journal_record.final_pi||"
    "request.final_polarity!=journal_record.final_polarity||"
    "request.start_sequence!=journal_record.start_sequence||"
    "request.end_sequence!=journal_record.end_sequence)"
    "returnjournal_status(RDMA_SC_INVALID_ARGUMENT,"
    '"CMQrecoveryrequestandjournalbatchfullvaluesdisagree");'
)

RECOVERY_BATCH_ORDERED_TUPLE_GATE = (
    "if(!rdma_cmq_recovery_batch_ordered_item_tuple_matches("
    "request,journal_record))"
    "returnjournal_status(RDMA_SC_INVALID_ARGUMENT,"
    '"CMQrecoverybatchordereditemtupledisagrees");'
    "returnjournal_status(RDMA_SC_OK);"
)

RESET_PROOF_COMPARATOR_CHECKS = (
    "RESET_PROOF_COMPARATOR_NULL_BOTH",
    "RESET_PROOF_COMPARATOR_NULL_LHS",
    "RESET_PROOF_COMPARATOR_NULL_RHS",
    "RESET_PROOF_COMPARATOR_EQUAL",
    "RESET_PROOF_COMPARATOR_ISOLATED_NULL_LHS",
    "RESET_PROOF_COMPARATOR_ISOLATED_NULL_RHS",
    "RESET_PROOF_COMPARATOR_ISOLATED_NULL_BOTH",
    "RESET_PROOF_COMPARATOR_PROOF_KEY",
    "RESET_PROOF_COMPARATOR_PROOF_ID",
    "RESET_PROOF_COMPARATOR_BATCH_KEY",
    "RESET_PROOF_COMPARATOR_BATCH_ID",
    "RESET_PROOF_COMPARATOR_ATTEMPT_ID",
    "RESET_PROOF_COMPARATOR_ENGINE_INSTANCE",
    "RESET_PROOF_COMPARATOR_ENGINE_INCARNATION",
    "RESET_PROOF_COMPARATOR_ISOLATED_INCARNATION",
    "RESET_PROOF_COMPARATOR_REPLACEMENT_NULL_RHS",
    "RESET_PROOF_COMPARATOR_REPLACEMENT_NULL_LHS",
    "RESET_PROOF_COMPARATOR_REPLACEMENT_NULL_BOTH",
    "RESET_PROOF_COMPARATOR_REPLACEMENT_INCARNATION",
    "RESET_PROOF_COMPARATOR_BATCH_DIGEST",
    "RESET_PROOF_COMPARATOR_PROOF_DIGEST",
    "RESET_PROOF_COMPARATOR_STATE",
    "RESET_PROOF_COMPARATOR_BACKING_RELEASE",
    "RESET_PROOF_COMPARATOR_REQUEST_CARDINALITY",
    "RESET_PROOF_COMPARATOR_IMAGE_CARDINALITY",
    "RESET_PROOF_COMPARATOR_AUTHORITY_CARDINALITY",
    "RESET_PROOF_COMPARATOR_OWNER_CARDINALITY",
    "RESET_PROOF_COMPARATOR_REQUEST_INDEX",
    "RESET_PROOF_COMPARATOR_IMAGE_DIGEST",
    "RESET_PROOF_COMPARATOR_AUTHORITY_DIGEST",
    "RESET_PROOF_COMPARATOR_OWNER_VALUE",
    "RESET_PROOF_COMPARATOR_TUPLE_ORDER",
    "RESET_PROOF_COMPARATOR_RESTORED",
    "RESET_PROOF_COMPARATOR_SUBTYPE_EXTENSION_IGNORED",
    "RESET_PROOF_COMPARATOR_BASE_SUBTYPE",
    "RESET_PROOF_COMPARATOR_SUBTYPE_BASE",
    "RESET_PROOF_COMPARATOR_INVALID_EQUAL",
)

MODEL_JOURNAL_VALUE_INCLUDE_ORDER = [
    "rdma_control_plane_models.sv",
    "rdma_cmq_journal_value_contract.sv",
    "rdma_queue_models.sv",
]

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

    # 功能：冻结六个 typed snapshot engine protected wrapper 的名称、返回类型与参数 ABI。
    # 输入/输出及副作用：只读 engine 源码，规范化空白后与冻结声明逐项比较；不编译或改写文件。
    # 失败/边界：wrapper 缺失/重复、移出 protected、改名、返回类型或参数 direction/顺序漂移时 fail-closed。
    def test_engine_typed_snapshot_protected_seam_abi(self):
        source = (ROOT / "src" / "core" / "rdma_cmq_engine.sv").read_text()
        engine_body = self._class_body("rdma_cmq_engine", source)

        for seam_name, expected in ENGINE_TYPED_SNAPSHOT_SEAMS.items():
            declarations = re.findall(
                r"(?m)^[ \t]*(protected\s+function\s+"
                r"rdma_status\s+"
                rf"{re.escape(seam_name)}\s*\([^;]*\)\s*;)",
                engine_body,
                flags=re.DOTALL,
            )
            self.assertEqual(
                len(declarations), 1, f"invalid typed seam {seam_name}"
            )
            actual = re.sub(r"\s+", " ", declarations[0].strip())
            actual = re.sub(r"\s*([(),;])\s*", r"\1", actual)
            self.assertEqual(actual, expected, seam_name)

    # 功能：冻结 typed-snapshot package 的六个 helper 清单、新 expected signature、
    #   六个 engine 薄转发，以及 direct expected check 的 exact-once 调度。
    # 输入/输出及副作用：只读 typed contract、engine 与 model test 源码并规范化声明/函数体；
    #   不执行 SystemVerilog、factory、clone 或任何仓库写入。
    # 失败/边界：helper 缺失/额外/重复、expected direction 漂移、engine wrapper 长回实现，
    #   或 direct check 缺失/重复/未进入 run_phase 时 fail-closed。
    def test_typed_snapshot_package_inventory_and_thin_forwarders(self):
        typed_source = (ROOT / "src" / "model" /
                        "rdma_cmq_typed_snapshot_contract.sv").read_text()
        engine_source = (ROOT / "src" / "core" /
                         "rdma_cmq_engine.sv").read_text()
        model_test_source = (ROOT / "tests" / "unit" /
                             "rdma_cmq_engine_models_test.sv").read_text()
        engine_body = self._class_body("rdma_cmq_engine", engine_source)
        typed_code = self._without_sv_comments(typed_source)
        model_test_code = self._without_sv_comments(model_test_source)

        helper_names = re.findall(
            r"(?m)^[ \t]*function\s+(?:automatic\s+)?"
            r"[A-Za-z_][A-Za-z0-9_]*\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*\(",
            typed_code,
        )
        self.assertEqual(
            helper_names,
            [
                "rdma_cmq_checked_function_snapshot",
                "rdma_cmq_checked_handle_snapshot",
                "rdma_cmq_checked_opcode_snapshot",
                "rdma_cmq_checked_expected_snapshot",
                "rdma_cmq_checked_image_snapshot",
                "rdma_cmq_checked_canonical_image_snapshot",
            ],
        )

        expected_declarations = re.findall(
            r"(?m)^[ \t]*(function\s+automatic\s+rdma_status\s+"
            r"rdma_cmq_checked_expected_snapshot\s*\([^;]*\)\s*;)",
            typed_code,
            flags=re.DOTALL,
        )
        self.assertEqual(len(expected_declarations), 1)
        actual = re.sub(r"\s+", " ", expected_declarations[0].strip())
        actual = re.sub(r"\s*([(),;])\s*", r"\1", actual)
        self.assertEqual(
            actual,
            "function automatic rdma_status "
            "rdma_cmq_checked_expected_snapshot("
            "input rdma_cmq_expected_response source,input string label,"
            "input rdma_status_code_e failure_code,"
            "output rdma_cmq_expected_response snapshot);",
        )

        for seam_name in ENGINE_TYPED_SNAPSHOT_SEAMS:
            wrapper_bodies = re.findall(
                r"(?m)^[ \t]*protected\s+function\s+rdma_status\s+"
                rf"{re.escape(seam_name)}\s*\([^;]*\)\s*;"
                r"(.*?)^[ \t]*endfunction\b",
                engine_body,
                flags=re.DOTALL,
            )
            self.assertEqual(len(wrapper_bodies), 1, seam_name)
            body = re.sub(r"/\*.*?\*/", "", wrapper_bodies[0],
                          flags=re.DOTALL)
            body = re.sub(r"//[^\n]*(?:\n|\Z)", "\n", body)
            body = re.sub(r"\s+", " ", body.strip())
            body = re.sub(r"\s*([(),;])\s*", r"\1", body)
            self.assertEqual(
                body,
                f"return rdma_cmq_{seam_name}(source,label,"
                "failure_code,snapshot);",
                seam_name,
            )

        check_declarations = re.findall(
            r"\bfunction\s+automatic\s+void\s+"
            r"check_typed_expected_snapshot_contract\s*\(\s*\)\s*;",
            model_test_code,
        )
        self.assertEqual(len(check_declarations), 1)
        model_test_body = self._class_body(
            "rdma_cmq_engine_models_test", model_test_code
        )
        run_phase = re.findall(
            r"\btask\s+run_phase\s*\([^;]+;"
            r"(.*?)\bendtask\b",
            model_test_body,
            flags=re.DOTALL,
        )
        self.assertEqual(len(run_phase), 1)
        self.assertEqual(
            len(re.findall(
                r"\bcheck_typed_expected_snapshot_contract\s*\(\s*\)\s*;",
                run_phase[0],
            )),
            1,
        )

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

    # 功能：冻结 body-value model contract 的七个 helper、engine protected ABI、
    #   单语句转发、queue-model 后置 include 与 direct check 的 exact-once 调度。
    # 输入/输出及副作用：只读新 contract、model package、engine 和 model test；
    #   规范化注释/空白后比较，不运行 SystemVerilog 或修改仓库。
    # 失败/边界：文件缺失、helper 额外/漏项/乱序、签名或 ref direction 漂移、
    #   wrapper 长回实现、include 前置/重复，或 direct check 未恰好调度一次时失败。
    def test_body_value_contract_inventory_and_thin_forwarders(self):
        contract_path = (ROOT / "src" / "model" /
                         "rdma_cmq_body_value_contract.sv")
        self.assertTrue(contract_path.is_file(), "missing body value contract")
        contract_source = contract_path.read_text()
        package_source = (ROOT / "src" / "model" /
                          "rdma_model_pkg.sv").read_text()
        engine_source = (ROOT / "src" / "core" /
                         "rdma_cmq_engine.sv").read_text()
        model_test_source = (ROOT / "tests" / "unit" /
                             "rdma_cmq_engine_models_test.sv").read_text()
        contract_code = self._without_sv_comments(contract_source)
        package_code = self._without_sv_comments(package_source)
        engine_body = self._class_body("rdma_cmq_engine", engine_source)
        model_test_code = self._without_sv_comments(model_test_source)

        helper_names = re.findall(
            r"(?m)^[ \t]*function\s+(?:automatic\s+)?"
            r"[A-Za-z_][A-Za-z0-9_]*\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*\(",
            contract_code,
        )
        self.assertEqual(
            helper_names,
            [f"rdma_cmq_{name}" for name in ENGINE_BODY_VALUE_SEAMS],
        )

        for seam_name, (package_decl, engine_decl, wrapper_body) in (
                ENGINE_BODY_VALUE_SEAMS.items()):
            package_matches = re.findall(
                r"(?m)^[ \t]*(function\s+automatic\s+"
                r"[A-Za-z_][A-Za-z0-9_]*\s+"
                rf"rdma_cmq_{re.escape(seam_name)}\s*\([^;]*\)\s*;)",
                contract_code,
                flags=re.DOTALL,
            )
            self.assertEqual(len(package_matches), 1, seam_name)
            actual_package = re.sub(
                r"\s+", " ", package_matches[0].strip()
            )
            actual_package = re.sub(
                r"\s*([(),;])\s*", r"\1", actual_package
            )
            self.assertEqual(actual_package, package_decl, seam_name)

            wrapper_matches = re.findall(
                r"(?m)^[ \t]*(protected\s+function\s+automatic\s+"
                r"[A-Za-z_][A-Za-z0-9_]*\s+"
                rf"{re.escape(seam_name)}\s*\([^;]*\)\s*;)"
                r"(.*?)^[ \t]*endfunction\b",
                engine_body,
                flags=re.DOTALL,
            )
            self.assertEqual(len(wrapper_matches), 1, seam_name)
            actual_engine = re.sub(
                r"\s+", " ", wrapper_matches[0][0].strip()
            )
            actual_engine = re.sub(
                r"\s*([(),;])\s*", r"\1", actual_engine
            )
            self.assertEqual(actual_engine, engine_decl, seam_name)
            actual_body = self._without_sv_comments(wrapper_matches[0][1])
            actual_body = re.sub(r"\s+", " ", actual_body.strip())
            actual_body = re.sub(
                r"\s*([(),;])\s*", r"\1", actual_body
            )
            self.assertEqual(actual_body, wrapper_body, seam_name)

        includes = re.findall(r'`include\s+"([^"]+)"', package_code)
        self.assertEqual(includes.count("rdma_queue_models.sv"), 1)
        self.assertEqual(
            includes.count("rdma_cmq_body_value_contract.sv"), 1
        )
        queue_index = includes.index("rdma_queue_models.sv")
        self.assertEqual(
            includes[queue_index:queue_index + 2],
            ["rdma_queue_models.sv", "rdma_cmq_body_value_contract.sv"],
        )
        self.assertNotRegex(
            contract_code,
            r"\bprofile\b|rdma_codec_pkg|rdma_core_pkg",
        )

        declarations = re.findall(
            r"\bfunction\s+automatic\s+void\s+"
            r"check_body_value_contract\s*\(\s*\)\s*;",
            model_test_code,
        )
        self.assertEqual(len(declarations), 1)
        model_test_body = self._class_body(
            "rdma_cmq_engine_models_test", model_test_code
        )
        run_phase = re.findall(
            r"\btask\s+run_phase\s*\([^;]+;"
            r"(.*?)\bendtask\b",
            model_test_body,
            flags=re.DOTALL,
        )
        self.assertEqual(len(run_phase), 1)
        self.assertEqual(
            len(re.findall(
                r"\bcheck_body_value_contract\s*\(\s*\)\s*;",
                run_phase[0],
            )),
            1,
        )

    # 功能：冻结 journal-value contract 九个有序 helper（八个 protected 转发及
    #   最后一个 direct ordered-item predicate）、既有 engine seam、恢复认证与
    #   RETRY 准入中的 binding 校验调用点。
    # 输入/输出及副作用：只读新 contract、model package、engine 与 model test 文件，
    #   去除注释/空白后断言前置错误优先级、sole caller、direct ID 和调度；不运行仿真。
    # 失败/边界：文件缺失、helper 增删/乱序、签名漂移、wrapper 长回实现、引入
    #   clone/factory/codec/core/profile、binding 外 status/snapshot、认证阶段
    #   绕过既有完整值比较、RETRY 不按独立准入 bit 回填退出或 18/68 漂移时失败关闭。
    def test_journal_value_contract_inventory_and_thin_forwarders(self):
        contract_path = (ROOT / "src" / "model" /
                         "rdma_cmq_journal_value_contract.sv")
        self.assertTrue(
            contract_path.is_file(), "missing journal value contract"
        )
        contract_source = contract_path.read_text()
        package_source = (ROOT / "src" / "model" /
                          "rdma_model_pkg.sv").read_text()
        engine_source = (ROOT / "src" / "core" /
                         "rdma_cmq_engine.sv").read_text()
        model_test_source = (ROOT / "tests" / "unit" /
                             "rdma_cmq_engine_models_test.sv").read_text()
        contract_code = self._without_sv_comments(contract_source)
        package_code = self._without_sv_comments(package_source)
        engine_body = self._class_body("rdma_cmq_engine", engine_source)
        engine_code = self._without_sv_comments(engine_body)
        model_test_code = self._without_sv_comments(model_test_source)

        helper_names = re.findall(
            r"(?m)^[ \t]*function\s+(?:automatic\s+)?"
            r"[A-Za-z_][A-Za-z0-9_]*\s+"
            r"([A-Za-z_][A-Za-z0-9_]*)\s*\(",
            contract_code,
        )
        self.assertEqual(
            helper_names,
            [f"rdma_cmq_{name}" for name in ENGINE_JOURNAL_VALUE_SEAMS] +
            ["rdma_cmq_recovery_batch_ordered_item_tuple_matches"],
        )

        for seam_name, (package_decl, engine_decl, wrapper_body) in (
                ENGINE_JOURNAL_VALUE_SEAMS.items()):
            package_matches = re.findall(
                r"(?m)^[ \t]*(function\s+automatic\s+bit\s+"
                rf"rdma_cmq_{re.escape(seam_name)}\s*\([^;]*\)\s*;)"
                r"(.*?)^[ \t]*endfunction\b",
                contract_code,
                flags=re.DOTALL,
            )
            self.assertEqual(len(package_matches), 1, seam_name)
            actual_package = re.sub(
                r"\s+", " ", package_matches[0][0].strip()
            )
            actual_package = re.sub(
                r"\s*([(),;])\s*", r"\1", actual_package
            )
            self.assertEqual(actual_package, package_decl, seam_name)
            compact_package_body = re.sub(
                r"\s+", "", package_matches[0][1]
            )
            status_locals = re.findall(
                r"(?m)^[ \t]*rdma_status\s+"
                r"([A-Za-z_][A-Za-z0-9_]*)\s*;",
                package_matches[0][1],
            )
            snapshot_calls = [
                name
                for name in re.findall(
                    r"\b([A-Za-z_][A-Za-z0-9_]*)\s*\(",
                    package_matches[0][1],
                )
                if "snapshot" in name
            ]
            if seam_name == "same_journal_binding_value":
                self.assertEqual(
                    status_locals, ["lhs_status", "rhs_status"], seam_name
                )
                self.assertEqual(
                    len(re.findall(
                        r"\brdma_status\b", package_matches[0][1]
                    )),
                    2,
                    seam_name,
                )
                self.assertEqual(
                    snapshot_calls,
                    ["snapshot_identity_nonfatal"] * 2,
                    seam_name,
                )
            else:
                self.assertEqual(status_locals, [], seam_name)
                self.assertNotRegex(
                    package_matches[0][1], r"\brdma_status\b", seam_name
                )
                self.assertEqual(snapshot_calls, [], seam_name)
            required_tokens, forbidden_tokens = (
                ENGINE_JOURNAL_HANDLE_PATHS.get(seam_name, ((), ()))
            )
            for token in required_tokens:
                self.assertEqual(
                    compact_package_body.count(token), 1,
                    f"{seam_name}: required handle path {token}",
                )
            for token in forbidden_tokens:
                self.assertNotIn(
                    token, compact_package_body,
                    f"{seam_name}: forbidden handle path {token}",
                )
            if seam_name == "same_journal_binding_value":
                token_positions = [
                    compact_package_body.index(token)
                    for token in required_tokens
                ]
                self.assertEqual(
                    token_positions,
                    sorted(token_positions),
                    "binding snapshot/status/identity/loop order drifted",
                )

            wrapper_matches = re.findall(
                r"(?m)^[ \t]*(protected\s+function\s+bit\s+"
                rf"{re.escape(seam_name)}\s*\([^;]*\)\s*;)"
                r"(.*?)^[ \t]*endfunction\b",
                engine_body,
                flags=re.DOTALL,
            )
            self.assertEqual(len(wrapper_matches), 1, seam_name)
            actual_engine = re.sub(
                r"\s+", " ", wrapper_matches[0][0].strip()
            )
            actual_engine = re.sub(
                r"\s*([(),;])\s*", r"\1", actual_engine
            )
            self.assertEqual(actual_engine, engine_decl, seam_name)
            actual_body = self._without_sv_comments(wrapper_matches[0][1])
            actual_body = re.sub(r"\s+", " ", actual_body.strip())
            actual_body = re.sub(
                r"\s*([(),;])\s*", r"\1", actual_body
            )
            self.assertEqual(actual_body, wrapper_body, seam_name)

        ordered_helpers = re.findall(
            r"(?m)^[ \t]*(function\s+automatic\s+bit\s+"
            r"rdma_cmq_recovery_batch_ordered_item_tuple_matches\s*"
            r"\([^;]*\)\s*;)"
            r"(.*?)^[ \t]*endfunction\b",
            contract_code,
            flags=re.DOTALL,
        )
        self.assertEqual(len(ordered_helpers), 1)
        ordered_decl = re.sub(r"\s+", " ", ordered_helpers[0][0].strip())
        ordered_decl = re.sub(r"\s*([(),;])\s*", r"\1", ordered_decl)
        self.assertEqual(ordered_decl, ORDERED_TUPLE_PACKAGE_DECL)
        ordered_body = re.sub(r"\s+", "", ordered_helpers[0][1])
        self.assertEqual(ordered_body, ORDERED_TUPLE_PACKAGE_BODY)
        self.assertNotRegex(
            ordered_helpers[0][1],
            r"\brdma_status\b|\bnew\b|\b(?:clone|copy|validate)\s*\(|"
            r"\b[A-Za-z_][A-Za-z0-9_]*snapshot[A-Za-z0-9_]*\s*\(|"
            r"\b(?:task|class)\b",
        )

        self.assertEqual(
            len(re.findall(
                r"\bsame_journal_binding_value\s*\(", engine_code
            )),
            3,
        )
        self.assertEqual(
            len(re.findall(
                r"\brdma_cmq_same_journal_binding_value\s*\(",
                engine_code,
            )),
            1,
        )

        batch_callers = re.findall(
            r"\bprotected\s+function\s+rdma_status\s+"
            r"validate_recovery_batch_match_locked\s*\([^;]*\)\s*;"
            r"(.*?)\bendfunction\b",
            engine_code,
            flags=re.DOTALL,
        )
        recovery_callers = re.findall(
            r"\btask\s+recover_submission_observed\s*\([^;]*\)\s*;"
            r"(.*?)\bendtask\b",
            engine_code,
            flags=re.DOTALL,
        )
        authentication_callers = re.findall(
            r"\bprotected\s+function\s+automatic\s+rdma_status\s+"
            r"authenticate_recovery_graphs_locked\s*\(([^;]*)\)\s*;"
            r"(.*?)\bendfunction\b",
            engine_code,
            flags=re.DOTALL,
        )
        retry_admission_callers = re.findall(
            r"\bprotected\s+function\s+automatic\s+bit\s+"
            r"admit_retry_live_authority_locked\s*\(([^;]*)\)\s*;"
            r"(.*?)\bendfunction\b",
            engine_code,
            flags=re.DOTALL,
        )
        recovery_stage_callers = re.findall(
            r"\bprotected\s+function\s+automatic\s+bit\s+"
            r"stage_recovery_candidate_locked\s*\(([^;]*)\)\s*;"
            r"(.*?)\bendfunction\b",
            engine_code,
            flags=re.DOTALL,
        )
        reset_runtime_matchers = re.findall(
            r"\bprotected\s+function\s+automatic\s+bit\s+"
            r"reset_candidate_runtime_matches_locked\s*\(([^;]*)\)\s*;"
            r"(.*?)\bendfunction\b",
            engine_code,
            flags=re.DOTALL,
        )
        reset_tasks = re.findall(
            r"\btask\s+reset_observed\s*\([^;]*\)\s*;"
            r"(.*?)\bendtask\b",
            engine_code,
            flags=re.DOTALL,
        )
        expiry_stagers = re.findall(
            r"\bprotected\s+function\s+automatic\s+rdma_status\s+"
            r"stage_expiry_candidates_locked\s*\(([^;]*)\)\s*;"
            r"(.*?)\bendfunction\b",
            engine_code,
            flags=re.DOTALL,
        )
        expiry_functions = re.findall(
            r"\bprotected\s+function\s+rdma_status\s+expire_locked\s*"
            r"\([^;]*\)\s*;"
            r"(.*?)\bendfunction\b",
            engine_code,
            flags=re.DOTALL,
        )
        self.assertEqual(len(batch_callers), 1)
        self.assertEqual(len(recovery_callers), 1)
        self.assertEqual(len(authentication_callers), 1)
        self.assertEqual(len(retry_admission_callers), 1)
        self.assertEqual(len(recovery_stage_callers), 1)
        self.assertEqual(len(reset_runtime_matchers), 1)
        self.assertEqual(len(reset_tasks), 1)
        self.assertEqual(len(expiry_stagers), 1)
        self.assertEqual(len(expiry_functions), 1)
        self.assertEqual(
            re.sub(r"\s+", "", authentication_callers[0][0]),
            "inputrdma_cmq_submission_recovery_requestrequest,"
            "inputrdma_cmq_batch_submission_recordrecord,"
            "inputrdma_cmq_hw_profileprofile_service",
        )
        for caller_body in (batch_callers[0], retry_admission_callers[0][1]):
            self.assertEqual(
                len(re.findall(
                    r"\bsame_journal_binding_value\s*\(", caller_body
                )),
                1,
            )

        compact_batch_caller = re.sub(r"\s+", "", batch_callers[0])
        self.assertIn(
            "if(request.batch_key!=journal_record.batch_key||"
            "request.batch_id!=journal_record.batch_id||"
            "!request.expected_function_identity.same_incarnation("
            "journal_record.function_identity)||"
            "!same_journal_binding_value(request.binding,"
            "journal_record.binding)||"
            "!same_handle(request.cmq_h,journal_record.cmq_h)||"
            "!same_image_value(request.doorbell_image,"
            "journal_record.doorbell_image)||"
            "request.final_pi!=journal_record.final_pi||"
            "request.final_polarity!=journal_record.final_polarity||"
            "request.start_sequence!=journal_record.start_sequence||"
            "request.end_sequence!=journal_record.end_sequence)",
            compact_batch_caller,
        )
        self.assertIn(
            "request.end_sequence!=journal_record.end_sequence)"
            "returnjournal_status(RDMA_SC_INVALID_ARGUMENT,"
            '"CMQrecoveryrequestandjournalbatchfullvaluesdisagree");',
            compact_batch_caller,
        )
        self.assertEqual(
            compact_batch_caller,
            RECOVERY_BATCH_GRAPH_GATE + RECOVERY_BATCH_CARRIED_DIGEST_GATE +
            RECOVERY_BATCH_CROSS_DIGEST_GATE +
            RECOVERY_BATCH_FULL_VALUE_GATE +
            RECOVERY_BATCH_ORDERED_TUPLE_GATE,
        )
        for seam_name, expected_count in (
                ("same_journal_binding_value", 1),
                ("same_handle", 1),
                ("same_image_value", 1),
                ("journal_status", 6)):
            self.assertEqual(
                len(re.findall(
                    rf"\b{seam_name}\s*\(", batch_callers[0]
                )),
                expected_count,
                seam_name,
            )
        self.assertEqual(
            len(re.findall(
                r"\brdma_cmq_recovery_batch_ordered_item_tuple_matches\s*\(",
                engine_code,
            )),
            1,
        )
        self.assertEqual(
            len(re.findall(
                r"\bvalidate_recovery_batch_match_locked\s*\(",
                engine_code,
            )),
            2,
        )
        self.assertEqual(
            len(re.findall(
                r"\bvalidate_recovery_batch_match_locked\s*\(",
                authentication_callers[0][1],
            )),
            1,
        )
        self.assertEqual(
            len(re.findall(
                r"\bvalidate_recovery_item_match_locked\s*\(",
                engine_code,
            )),
            2,
        )
        self.assertEqual(
            len(re.findall(
                r"\bvalidate_recovery_item_match_locked\s*\(",
                authentication_callers[0][1],
            )),
            1,
        )

        compact_recovery_caller = re.sub(r"\s+", "", recovery_callers[0])
        compact_authentication_caller = re.sub(
            r"\s+", "", authentication_callers[0][1]
        )
        self.assertIn(
            "nested_status=validate_recovery_batch_match_locked("
            "request,record,request_batch_digest,journal_batch_digest);"
            "if(nested_status==null||!nested_status.ok())begin"
            "status=(nested_status==null)?journal_status("
            "RDMA_SC_INVALID_STATE,"
            '"CMQrecoverybatchfull-valuecomparisonreturnednullstatus"):'
            "journal_status(nested_status.code,nested_status.message);"
            "returnstatus;end",
            compact_authentication_caller,
        )
        self.assertIn(
            "foreach(request.items[i])begin"
            "nested_status=validate_recovery_item_match_locked("
            "request.items[i],record.items[i],request_image_digests[i],"
            "request_authority_digests[i],journal_image_digests[i],"
            "journal_authority_digests[i]);",
            compact_authentication_caller,
        )
        self.assertLess(
            compact_authentication_caller.index(
                "nested_status=validate_recovery_item_match_locked("
            ),
            compact_authentication_caller.index(
                "nested_status=validate_recovery_batch_match_locked("
            ),
        )
        self.assertEqual(
            len(re.findall(
                r"\bauthenticate_recovery_graphs_locked\s*\(",
                engine_code,
            )),
            2,
        )
        self.assertEqual(
            len(re.findall(
                r"\bauthenticate_recovery_graphs_locked\s*\(",
                recovery_callers[0],
            )),
            1,
        )
        self.assertNotRegex(
            recovery_callers[0],
            r"\bvalidate_recovery_(?:item|batch)_match_locked\s*\(",
        )
        self.assertNotRegex(
            authentication_callers[0][1],
            r"\b(?:engine_lock|reject_recovery_results_locked|"
            r"submission_journal|preallocated_publish_batches|"
            r"arm_observers|transport)\b",
        )
        self.assertIn(
            "status=authenticate_recovery_graphs_locked("
            "request,record,profile_service);"
            "if(status==null||!status.ok())begin"
            "if(status==null)status=journal_status("
            "RDMA_SC_INVALID_STATE,"
            '"CMQrecoverygraphauthenticationreturnednullstatus");'
            "reject_recovery_results_locked(results,status.code,"
            "status.message);engine_lock.put(1);return;end",
            compact_recovery_caller,
        )
        self.assertLess(
            compact_recovery_caller.index(
                "profile_service=journal_profile_by_batch[record.batch_key];"
            ),
            compact_recovery_caller.index(
                "status=authenticate_recovery_graphs_locked("
            ),
        )
        self.assertLess(
            compact_recovery_caller.index(
                "status=authenticate_recovery_graphs_locked("
            ),
            compact_recovery_caller.index(
                "owner_status=record.items[i].recovery_owner.validate_frozen("
            ),
        )
        compact_retry_admission = re.sub(
            r"\s+", "", retry_admission_callers[0][1]
        )
        self.assertIn(
            "if(engine_state!=RDMA_CMQ_ENGINE_ACTIVE||"
            "prepared_binding==null||dma_context==null||"
            "cmq_snapshot==null||backing_mapping==null||"
            "transport==null||profile==null||"
            "!same_journal_binding_value(prepared_binding,record.binding)||"
            "!same_handle(cmq_snapshot.handle,record.cmq_h))begin",
            compact_retry_admission,
        )
        self.assertIn(
            "!same_handle(cmq_snapshot.handle,record.cmq_h))begin"
            "status=journal_status(RDMA_SC_INVALID_STATE,"
            '"CMQrecoveryliveFunctionorCMQauthoritydrifted");'
            "return1'b0;end",
            compact_retry_admission,
        )
        self.assertIn(
            "if(!admit_retry_live_authority_locked("
            "request,record,profile_service,preallocated,status))begin"
            "reject_recovery_results_locked(results,status.code,"
            "status.message);engine_lock.put(1);return;end",
            compact_recovery_caller,
        )
        compact_recovery_stage = re.sub(
            r"\s+", "", recovery_stage_callers[0][1]
        )
        for required in (
            "minimum_remaining=0;",
            "CMQrecoveryticketdeadlinecontainsX/Z",
            "make_recovery_doorbell_locked(",
            "checked_doorbell_desc_snapshot(",
            "observer.configure(",
        ):
            self.assertIn(required, compact_recovery_stage)
        self.assertNotRegex(
            recovery_stage_callers[0][1],
            r"\bengine_lock\.(?:get|put)\s*\(|"
            r"\battempt_id_counter\b|\btransport\.submit_observed\s*\(",
        )
        self.assertIn(
            "if(!stage_recovery_candidate_locked("
            "record,candidate_attempt,recovery_stage,status))begin"
            "reject_recovery_results_locked(results,status.code,status.message);"
            "engine_lock.put(1);return;end",
            compact_recovery_caller,
        )

        compact_reset_matcher = re.sub(
            r"\s+", "", reset_runtime_matchers[0][1]
        )
        self.assertIn(
            "backing_mapping===candidate.runtime_backing_mapping&&"
            "host_mem===candidate.runtime_host_mem",
            compact_reset_matcher,
        )
        self.assertIn(
            "retained_row!==candidate.batches[b].quarantined_record",
            compact_reset_matcher,
        )
        self.assertNotRegex(
            reset_runtime_matchers[0][1],
            r"\bengine_lock\.(?:get|put)\s*\(|"
            r"\brelease_opaque\s*\(|\bpoison_released_runtime_drift_locked\s*\(|"
            r"\bcommit_reset_candidate_locked\s*\(",
        )
        compact_reset_task = re.sub(r"\s+", "", reset_tasks[0])
        self.assertIn(
            "candidate_runtime_unchanged="
            "reset_candidate_runtime_matches_locked(candidate);",
            compact_reset_task,
        )
        self.assertLess(
            compact_reset_task.index(
                "candidate_runtime_unchanged="
                "reset_candidate_runtime_matches_locked(candidate);"
            ),
            compact_reset_task.index(
                "poison_released_runtime_drift_locked();"
            ),
        )
        self.assertLess(
            compact_reset_task.index(
                "candidate_runtime_unchanged="
                "reset_candidate_runtime_matches_locked(candidate);"
            ),
            compact_reset_task.index(
                "commit_reset_candidate_locked(candidate);"
            ),
        )

        compact_expiry_stager = re.sub(r"\s+", "", expiry_stagers[0][1])
        for required in (
            "poll_ledger_status(ledger_used)",
            "make_timeout_completion(record,timeout_completion)",
            "stage_runtime_journal_transition_locked(",
            "stage.staged_completions.push_back(timeout_completion);",
        ):
            self.assertIn(required, compact_expiry_stager)
        self.assertNotRegex(
            expiry_stagers[0][1],
            r"\b(?:commit_runtime_journal_transition_locked|"
            r"terminal_fifo\.push_back|command_registry\.delete|"
            r"engine_lock\.(?:get|put))\b",
        )
        compact_expiry = re.sub(r"\s+", "", expiry_functions[0])
        self.assertIn(
            "status=stage_expiry_candidates_locked(stage);",
            compact_expiry,
        )
        self.assertLess(
            compact_expiry.index("stage_expiry_candidates_locked(stage);"),
            compact_expiry.index(
                "commit_runtime_journal_transition_locked("
            ),
        )
        self.assertLess(
            compact_expiry.index(
                "commit_runtime_journal_transition_locked("
            ),
            compact_expiry.index("terminal_fifo.push_back("),
        )

        includes = re.findall(r'`include\s+"([^"]+)"', package_code)
        for name in MODEL_JOURNAL_VALUE_INCLUDE_ORDER:
            self.assertEqual(includes.count(name), 1, name)
        first = includes.index(MODEL_JOURNAL_VALUE_INCLUDE_ORDER[0])
        self.assertEqual(
            includes[first:first + len(MODEL_JOURNAL_VALUE_INCLUDE_ORDER)],
            MODEL_JOURNAL_VALUE_INCLUDE_ORDER,
        )
        self.assertNotRegex(
            contract_code,
            r"\brdma_codec_pkg\b|\brdma_core_pkg\b|"
            r"\brdma_cmq_hw_profile\b",
        )
        self.assertNotRegex(
            contract_code,
            r"\bclone\s*\(|\bcopy\s*\(|\bnew\b|"
            r"\btype_id\s*::\s*create\b|"
            r"\b[A-Za-z_][A-Za-z0-9_]*factory[A-Za-z0-9_]*\b|"
            r"\b[A-Za-z_][A-Za-z0-9_]*validate[A-Za-z0-9_]*\s*\(|"
            r"\b(?:snapshot_release_authority|release_authority_status|"
            r"release_completion_status)\b|\b(?:task|class)\b|"
            r"\$[A-Za-z_]|`[A-Za-z_]",
        )
        self.assertEqual(
            len(re.findall(r"\bfunction\b", contract_code)),
            len(ENGINE_JOURNAL_VALUE_SEAMS) + 1,
        )
        self.assertEqual(
            len(re.findall(r"\bendfunction\b", contract_code)),
            len(ENGINE_JOURNAL_VALUE_SEAMS) + 1,
        )

        model_test_body = self._class_body(
            "rdma_cmq_engine_models_test", model_test_code
        )
        run_phase = re.findall(
            r"\btask\s+run_phase\s*\([^;]+;"
            r"(.*?)\bendtask\b",
            model_test_body,
            flags=re.DOTALL,
        )
        self.assertEqual(len(run_phase), 1)
        for check_name in (
            "check_journal_value_contract",
            "check_journal_binding_comparator_contract",
            "check_journal_ordered_item_tuple_contract",
            "check_reset_proof_comparator_contract",
            "check_submission_effect_ordering",
        ):
            declarations = re.findall(
                r"\bfunction\s+automatic\s+void\s+"
                rf"{re.escape(check_name)}\s*\(\s*\)\s*;",
                model_test_body,
            )
            self.assertEqual(len(declarations), 1, check_name)
            self.assertEqual(
                len(re.findall(
                    rf"\b{re.escape(check_name)}\s*\(\s*\)\s*;",
                    run_phase[0],
                )),
                1,
                check_name,
            )
        self.assertRegex(
            run_phase[0],
            r"\bcheck_journal_value_contract\s*\(\s*\)\s*;\s*"
            r"check_journal_binding_comparator_contract\s*\(\s*\)\s*;\s*"
            r"check_journal_ordered_item_tuple_contract\s*\(\s*\)\s*;\s*"
            r"check_reset_proof_comparator_contract\s*\(\s*\)\s*;\s*"
            r"check_submission_effect_ordering\s*\(\s*\)\s*;",
        )

        binding_checks = re.findall(
            r"\bfunction\s+automatic\s+void\s+"
            r"check_journal_binding_comparator_contract\s*\(\s*\)\s*;"
            r"(.*?)\bendfunction\b",
            model_test_body,
            flags=re.DOTALL,
        )
        self.assertEqual(len(binding_checks), 1)
        self.assertEqual(
            tuple(re.findall(
                r'"(JOURNAL_BINDING_COMPARATOR_[A-Z0-9_]+)"',
                binding_checks[0],
            )),
            JOURNAL_BINDING_COMPARATOR_CHECKS,
        )

        ordered_checks = re.findall(
            r"\bfunction\s+automatic\s+void\s+"
            r"check_journal_ordered_item_tuple_contract\s*\(\s*\)\s*;"
            r"(.*?)\bendfunction\b",
            model_test_body,
            flags=re.DOTALL,
        )
        self.assertEqual(len(ordered_checks), 1)
        self.assertEqual(
            tuple(re.findall(
                r'"(JOURNAL_ORDERED_TUPLE_[A-Z0-9_]+)"',
                ordered_checks[0],
            )),
            JOURNAL_ORDERED_TUPLE_CHECKS,
        )

        reset_checks = re.findall(
            r"\bfunction\s+automatic\s+void\s+"
            r"check_reset_proof_comparator_contract\s*\(\s*\)\s*;"
            r"(.*?)\bendfunction\b",
            model_test_body,
            flags=re.DOTALL,
        )
        self.assertEqual(len(reset_checks), 1)
        self.assertEqual(
            tuple(re.findall(
                r'"(RESET_PROOF_COMPARATOR_[A-Z0-9_]+)"',
                reset_checks[0],
            )),
            RESET_PROOF_COMPARATOR_CHECKS,
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

    # 功能：冻结 observed submit 的原锁内 transport → 解码 → PRE 回滚 → owner
    #   候选扫描 → effect 分类 → retained result 顺序，防止分类移动提交点。
    # 输入/输出及副作用：仅读取 engine/test 源码，核对 helper 唯一性、read-only
    #   helper 边界、锁获取/最终释放、原位 retained 提交及前缀 leaf 内的一次
    #   direct 表；不运行仿真或更改 UVM 清单。
    # 失败边界：PRE 先于 owner/classifier、分类先于四字段原位提交、提交先于
    #   detached result/最终解锁、18/68 动作中测试的嵌入位置，或 helper 触及
    #   mutable engine ledger/锁发生漂移时 fail-closed。
    def test_observed_submit_transport_decision_stage_order(self):
        source = (ROOT / "src" / "core" / "rdma_cmq_engine.sv").read_text()
        engine = self._class_body("rdma_cmq_engine", source)
        engine_test = (ROOT / "tests" / "unit" /
                       "rdma_cmq_engine_test.sv").read_text()
        submit = re.search(
            r"\btask\s+submit_batch_observed\s*\([^;]*;(?P<body>.*?)"
            r"\bendtask\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(submit, "missing observed submit entry")
        body = re.sub(r"//[^\n]*", "", submit.group("body"))

        helper_names = (
            "decode_observed_transport_evidence",
            "classify_observed_transport_effect",
        )
        for name in helper_names:
            helper = re.findall(
                rf"\bprotected\s+function\s+(?:automatic\s+)?"
                rf"void\s+{name}\s*\([^;]*;(?P<body>.*?)"
                rf"\bendfunction\b",
                engine,
                flags=re.DOTALL,
            )
            self.assertEqual(len(helper), 1, f"invalid {name} helper")
            helper_body = re.sub(r"//[^\n]*", "", helper[0])
            self.assertNotRegex(
                helper_body,
                r"\b(?:engine_lock|submission_journal|"
                r"journal_batch_by_ticket|preallocated_publish_batches|"
                r"arm_observers|fenced_batch_key|publish_seq|"
                r"token_in_use|command_registry|entry_registry)\b",
                f"{name} moved mutable engine ownership",
            )
            self.assertEqual(
                len(re.findall(rf"\b{name}\s*\(", body)),
                1,
                f"{name} callsite must be unique",
            )

        stages = (
            r"\bengine_lock\.get\s*\(\s*1\s*\)\s*;",
            r"\binstall_submission_journal_locked\s*\(",
            r"\btransport\.submit_observed\s*\(",
            r"\bdecode_observed_transport_evidence\s*\(",
            r"\bif\s*\(\s*evidence\.rollback_pre\s*\)",
            r"\bretry_safe\s*=\s*1'b1\s*;",
            r"\bclassify_observed_transport_effect\s*\(",
            r"\bretained_record\.state\s*=\s*decision\.state\s*;",
            r"\bretained_record\.publication_retry_safe\s*=\s*"
            r"decision\.publication_retry_safe\s*;",
            r"\bretained_record\.submission_effect\s*=\s*"
            r"decision\.cumulative_effect\s*;",
            r"\bretained_record\.attempt_effect\s*=\s*"
            r"decision\.attempt_effect\s*;",
            r"\bbuild_observed_result_locked\s*\(",
        )
        positions = []
        for pattern in stages:
            found = re.search(pattern, body)
            self.assertIsNotNone(found, f"missing observed submit stage {pattern}")
            positions.append(found.start())
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(
            len(re.findall(r"\bengine_lock\.get\s*\(\s*1\s*\)", body)),
            1,
        )
        self.assertRegex(
            body,
            r"\bresults\[request_index\]\s*=\s*detached_result\s*;\s*"
            r"end\s*batch_status\s*=\s*"
            r"rdma_cmq_direct_status\s*\(\s*RDMA_SC_OK\s*\)\s*;\s*"
            r"engine_lock\.put\s*\(\s*1\s*\)\s*;\s*$",
        )

        retention = re.search(
            r"\btask\s+automatic\s+"
            r"check_observed_transport_failure_retention\s*\([^;]*;"
            r"(?P<body>.*?)\bendtask\b",
            engine_test,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(retention)
        self.assertRegex(
            retention.group("body"),
            r"if\s*\(\s*first_fault\s*==\s*0\s*\)\s*"
            r"check_observed_transport_decision_direct_contract\s*\(\s*\)\s*;",
        )
        self.assertEqual(
            len(re.findall(
                r"\bcheck_observed_transport_decision_direct_contract\s*\(",
                retention.group("body"),
            )),
            1,
        )

    # 功能：冻结 observed submit 的逐项候选暂存为单个锁内阶段，确保局部
    #   continue 与整批 break 仍在原索引顺序下发生，失败回填仍由原 task 负责。
    # 输入输出及副作用：只读 engine 源码及本文件已冻结的进程清单；核对调用期
    #   context、唯一 helper、关键分支顺序及唯一 journal 安装，不运行仿真。
    # 失败边界：helper 触碰共享账本、搬走锁/transport/失败回填，或逐项阶段
    #   移至无候选快速返回之后时失败；不会改写被测文件。
    def test_observed_submit_candidate_stage_order(self):
        source = (ROOT / "src" / "core" / "rdma_cmq_engine.sv").read_text()
        engine = self._class_body("rdma_cmq_engine", source)
        self.assertIsNotNone(
            re.search(
                r"\btypedef\s+struct\s*\{[^}]*\}\s*"
                r"rdma_cmq_submit_candidate_stage_t\s*;",
                source,
            ),
            "missing call-local candidate-stage context",
        )
        helper = re.findall(
            r"\bprotected\s+function\s+(?:automatic\s+)?void\s+"
            r"stage_observed_candidates_locked\s*\([^;]*;(?P<body>.*?)"
            r"\bendfunction\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertEqual(len(helper), 1)
        helper_body = re.sub(r"//[^\n]*", "", helper[0])
        for pattern in (
            r"\bforeach\s*\(\s*commands\[i\]\s*\)",
            r"\bsnapshot_command_value\s*\(",
            r"\bcommand_identity\.capture_from\s*\(",
            r"\bif\s*\(\s*command_snapshot\.function_h\.kind",
            r"\bif\s*\(\s*\$isunknown\(command_snapshot\.timeout\)",
            r"\bprofile\.compose_sqe\s*\(",
            r"\bchecked_expected_snapshot\s*\(",
            r"\bitem\s*=\s*new\s*\(",
            r"\bpush_back\s*\(\s*item\s*\)",
            r"\bpush_back\s*\(\s*publish_item\s*\)",
            r"\bpush_back\s*\(\s*dependency_snapshot\s*\)",
        ):
            self.assertRegex(helper_body, pattern)
        self.assertEqual(len(re.findall(r"\bcontinue\s*;", helper_body)), 11)
        self.assertEqual(len(re.findall(r"\bbreak\s*;", helper_body)), 20)
        self.assertEqual(
            len(re.findall(r"\bpoison_status\s*\(", helper_body)), 2
        )
        self.assertNotRegex(
            helper_body,
            r"\b(?:engine_lock|submission_journal|journal_batch_by_ticket|"
            r"preallocated_publish_batches|arm_observers|fenced_batch_key|"
            r"transport|install_submission_journal_locked)\b",
        )

        submit = re.search(
            r"\btask\s+submit_batch_observed\s*\([^;]*;(?P<body>.*?)"
            r"\bendtask\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(submit)
        body = re.sub(r"//[^\n]*", "", submit.group("body"))
        stages = (
            r"\bengine_lock\.get\s*\(\s*1\s*\)",
            r"\bstage_observed_candidates_locked\s*\(",
            r"\bif\s*\(\s*!transaction_failed\s*&&\s*"
            r"record_candidate\.items\.size\(\)\s*==\s*0\s*\)",
            r"\ballocate_batch_identity_locked\s*\(",
            r"\binstall_submission_journal_locked\s*\(",
            r"\btransport\.submit_observed\s*\(",
        )
        positions = []
        for pattern in stages:
            found = re.search(pattern, body)
            self.assertIsNotNone(found, f"missing candidate stage {pattern}")
            positions.append(found.start())
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(
            len(re.findall(r"\bstage_observed_candidates_locked\s*\(", body)), 1
        )
        self.assertEqual(
            len(re.findall(r"\binstall_submission_journal_locked\s*\(", body)),
            1,
        )
        self.assertNotRegex(body, r"\bforeach\s*\(\s*commands\[i\]\s*\)")
        self.assertIsNotNone(
            re.search(
                r"\bif\s*\(\s*transaction_failed\s*\)\s*begin\s*"
                r"if\s*\(\s*transaction_status\s*==\s*null\s*\).*?"
                r"\bif\s*\(\s*!local_result_finalized\[i\]\s*\).*?"
                r"\bengine_lock\.put\s*\(\s*1\s*\)",
                body,
                flags=re.DOTALL,
            ),
            "candidate failure fanout left the submit task",
        )

    # 功能：冻结 observed submit 在锁内单次调用的 admission 早退阶段，保持
    #   reset-release、ACTIVE、完整 authority、fence、Function 和 ring 的拒绝顺序。
    # 输入输出及副作用：只读 engine 的 helper/task 文本，核对 ref 输出、fence
    #   特例和早退解锁仍由 task 执行，ID/journal/transport 在准入后；不运行仿真。
    # 失败边界：helper 重取锁/直接安装账本、早退优先级漂移、fence 走事务失败
    #   回填、或锁内入口被重复调用时失败；该检查不会修改任何 DUT 状态。
    def test_observed_submit_locked_admission_stage(self):
        source = (ROOT / "src" / "core" / "rdma_cmq_engine.sv").read_text()
        engine = self._class_body("rdma_cmq_engine", source)
        helpers = re.findall(
            r"\bprotected\s+function\s+(?:automatic\s+)?bit\s+"
            r"admit_observed_batch_locked\s*\([^;]*;(?P<body>.*?)"
            r"\bendfunction\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertEqual(len(helpers), 1, "missing unique locked admission")
        signature = re.search(
            r"\bprotected\s+function\s+(?:automatic\s+)?bit\s+"
            r"admit_observed_batch_locked\s*\((?P<args>[^;]*)\)\s*;",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(signature)
        for pattern in (
            r"\bref\s+rdma_cmq_execution_result\s+results\s*\[\s*\]",
            r"\bref\s+rdma_status\s+batch_status\b",
            r"\boutput\s+rdma_function_handle\s+active_function\b",
            r"\boutput\s+longint\s+unsigned\s+used\b",
        ):
            self.assertRegex(signature.group("args"), pattern)
        self.assertNotIn("/*", helpers[0], "admission inspection skips block comments")
        helper = re.sub(r"//[^\n]*", "", helpers[0])
        stages = (
            r"\bstatus\s*=\s*reset_release_gate_status\s*\(",
            r"\bif\s*\(\s*engine_state\s*!=\s*RDMA_CMQ_ENGINE_ACTIVE",
            r"\bif\s*\(\s*prepared_binding\s*==\s*null",
            r"\bif\s*\(\s*fenced_batch_key\.len\(\)\s*!=\s*0",
            r"\bactive_function\s*=\s*prepared_binding\.make_handle\s*\(",
            r"\bstatus\s*=\s*ring_used\s*\(",
            r"\breturn\s+1'b1\s*;",
        )
        positions = []
        for pattern in stages:
            found = re.search(pattern, helper)
            self.assertIsNotNone(found, f"missing admission step {pattern}")
            positions.append(found.start())
        self.assertEqual(positions, sorted(positions))
        reject_positions = [
            found.start()
            for found in re.finditer(r"\breturn\s+1'b0\s*;", helper)
        ]
        self.assertEqual(len(reject_positions), 6)
        for index, reject in enumerate(reject_positions):
            self.assertGreater(reject, positions[index])
            self.assertLess(reject, positions[index + 1])
        self.assertEqual(len(re.findall(r"\breturn\s+1'b1\s*;", helper)), 1)
        for authority in (
            "prepared_binding", "dma_context", "cmq_snapshot",
            "backing_mapping", "transport", "profile",
        ):
            self.assertRegex(helper, rf"\b{authority}\s*==\s*null")
        for message in (
            "CMQ submit requires an ACTIVE engine",
            "CMQ ACTIVE publication authority is missing",
            "CMQ submission is fenced by a retained batch",
            "CMQ ACTIVE Function handle is missing",
        ):
            self.assertIn(message, helper)
        self.assertRegex(
            helper,
            r"\bresults\[i\]\.status\s*=\s*rdma_cmq_direct_status\s*"
            r"\(\s*RDMA_SC_RESOURCE_BUSY",
        )
        self.assertRegex(
            helper,
            r"\bbatch_status\s*=\s*rdma_cmq_direct_status\s*"
            r"\(\s*RDMA_SC_OK\s*\)",
        )
        self.assertRegex(
            helper,
            r"\bstatus\s*=\s*ring_used\s*\(\s*used\s*\)",
        )
        for copy_name in (
            "cmq_reset_release_gate_batch_status",
            "cmq_reset_release_gate_item_",
            "cmq_inactive_item_",
            "cmq_missing_authority_item_",
            "cmq_missing_function_item_",
            "cmq_ring_status",
            "cmq_ring_item_",
        ):
            self.assertIn(copy_name, helper)
        self.assertRegex(helper, r"\bif\s*\(\s*active_function\s*==\s*null\s*\)")
        self.assertRegex(
            helper,
            r"\bif\s*\(\s*status\s*==\s*null\s*\|\|\s*!status\.ok\(\)\s*\)",
        )
        self.assertNotRegex(
            helper,
            r"\b(?:engine_lock|submission_journal|journal_batch_by_ticket|"
            r"preallocated_publish_batches|arm_observers|"
            r"allocate_batch_identity_locked|install_submission_journal_locked)\b"
            r"|\btransport\s*\.\s*submit_observed\s*\(",
        )

        submit = re.search(
            r"\btask\s+submit_batch_observed\s*\([^;]*;(?P<body>.*?)"
            r"\bendtask\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(submit)
        body = re.sub(r"//[^\n]*", "", submit.group("body"))
        task_stages = (
            r"\bif\s*\(\s*commands\.size\(\)\s*==\s*0\s*\)",
            r"\bengine_lock\.get\s*\(\s*1\s*\)",
            r"\bif\s*\(\s*!admit_observed_batch_locked\s*\(",
            r"\bstatus\s*=\s*prepared_binding\.snapshot_complete_nonfatal",
            r"\bstage_observed_candidates_locked\s*\(",
            r"\ballocate_batch_identity_locked\s*\(",
            r"\binstall_submission_journal_locked\s*\(",
            r"\btransport\.submit_observed\s*\(",
        )
        positions = []
        for pattern in task_stages:
            found = re.search(pattern, body)
            self.assertIsNotNone(found, f"missing submit stage {pattern}")
            positions.append(found.start())
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(
            len(re.findall(r"\badmit_observed_batch_locked\s*\(", body)),
            1,
        )
        self.assertIsNotNone(
            re.search(
                r"\bif\s*\(\s*!admit_observed_batch_locked\s*\("
                r"[^;]*\)\s*\)\s*begin\s*engine_lock\.put\s*\(\s*1\s*\)"
                r"\s*;\s*return\s*;\s*end",
                body,
                flags=re.DOTALL,
            ),
            "locked admission reject must unlock once in submit task",
        )
        self.assertNotRegex(body, r"\bstatus\s*=\s*ring_used\s*\(")

    # 功能：冻结 observed submit 在候选压缩与身份分配之间的 doorbell image 阶段，
    #   保留 detached handle 的篡改优先级和两次 metadata 检查。
    # 输入输出及副作用：只读 engine helper/task 源码；核对最终 image/cursor 输出
    #   回到原 task、事务失败状态 ref 回传和锁内唯一阶段调用，不运行仿真。
    # 失败边界：篡改检查后移、null-status 提前、重复/遗漏 metadata 校验、
    #   ID/账本/transport 进入 helper 或跨越原 all-local 快路时失败。
    def test_observed_submit_doorbell_image_stage(self):
        source = (ROOT / "src" / "core" / "rdma_cmq_engine.sv").read_text()
        engine = self._class_body("rdma_cmq_engine", source)
        helper_match = re.search(
            r"\bprotected\s+function\s+automatic\s+void\s+"
            r"stage_observed_doorbell_image_locked\s*\("
            r"(?P<args>[^;]*)\)\s*;(?P<body>.*?)\bendfunction\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(helper_match, "missing locked doorbell image stage")
        self.assertEqual(
            len(re.findall(r"\bstage_observed_doorbell_image_locked\s*\(", engine)),
            2,
            "doorbell image helper must have one declaration and one call",
        )
        args = helper_match.group("args")
        for pattern in (
            r"\binput\s+int\s+unsigned\s+admitted_count\b",
            r"\boutput\s+longint\s+unsigned\s+final_sequence\b",
            r"\boutput\s+int\s+unsigned\s+final_pi\b",
            r"\boutput\s+bit\s+final_polarity\b",
            r"\boutput\s+rdma_hw_image\s+doorbell_snapshot\b",
            r"\bref\s+rdma_status\s+transaction_status\b",
            r"\bref\s+bit\s+transaction_failed\b",
        ):
            self.assertRegex(args, pattern)
        helper = re.sub(r"//[^\n]*", "", helper_match.group("body"))
        stages = (
            r"\bfinal_sequence\s*=\s*publish_seq\s*\+\s*admitted_count\s*;",
            r"\bstatus\s*=\s*checked_handle_snapshot\s*\(",
            r"\bstatus\s*=\s*profile\.encode_doorbell\s*\(",
            r"\bif\s*\(\s*!same_handle\s*\(",
            r"\belse\s+if\s*\(\s*status\s*==\s*null\s*\|\|\s*!status\.ok\(\)",
            r"\bstatus\s*=\s*doorbell_metadata_status\s*\(\s*doorbell_image\s*\)",
            r"\bstatus\s*=\s*checked_canonical_image_snapshot\s*\(",
            r"\bstatus\s*=\s*doorbell_metadata_status\s*\(\s*doorbell_snapshot\s*\)",
        )
        positions = []
        for pattern in stages:
            found = re.search(pattern, helper)
            self.assertIsNotNone(found, f"missing doorbell image step {pattern}")
            positions.append(found.start())
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(
            len(re.findall(r"\bif\s*\(\s*!transaction_failed\s*\)\s*begin", helper)),
            5,
            "each doorbell stage must retain its original failure guard",
        )
        self.assertEqual(len(re.findall(r"\bdoorbell_metadata_status\s*\(", helper)), 2)
        for pattern in (
            r"\bfinal_pi\s*=\s*final_sequence\s*%\s*CMQ_DEPTH\s*;",
            r"\bfinal_polarity\s*=\s*\(\s*final_sequence\s*/\s*CMQ_DEPTH\s*\)"
            r"\s*&\s*1'b1\s*;",
            r"\bprofile\.encode_doorbell\s*\(\s*doorbell_encode_target\s*,"
            r"\s*final_pi\s*,\s*final_polarity\s*,\s*doorbell_image\s*\)",
        ):
            self.assertRegex(helper, pattern)
        for message in (
            "CMQ doorbell encoder changed its detached handle input",
            "CMQ doorbell encoding returned null status",
            "CMQ doorbell profile output is invalid: ",
            "CMQ doorbell snapshot metadata is invalid: ",
            "cmq_doorbell_handle_status",
            "cmq_doorbell_encode_status",
            "cmq_doorbell_snapshot_status",
        ):
            self.assertIn(message, helper)
        self.assertNotRegex(
            helper,
            r"\b(?:engine_lock|submission_journal|journal_batch_by_ticket|"
            r"preallocated_publish_batches|allocate_batch_identity_locked|"
            r"allocate_attempt_id_locked|install_submission_journal_locked)\b"
            r"|\btransport\s*\.\s*submit_observed\s*\(",
        )

        submit = re.search(
            r"\btask\s+submit_batch_observed\s*\([^;]*;(?P<body>.*?)"
            r"\bendtask\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(submit)
        body = re.sub(r"//[^\n]*", "", submit.group("body"))
        task_stages = (
            r"\bstage_observed_candidates_locked\s*\(",
            r"\bif\s*\(\s*!transaction_failed\s*&&\s*"
            r"record_candidate\.items\.size\(\)\s*==\s*0\s*\)",
            r"\bstage_observed_doorbell_image_locked\s*\(",
            r"\bstage_observed_doorbell_descriptor_locked\s*\(",
            r"\ballocate_batch_identity_locked\s*\(",
            r"\binstall_submission_journal_locked\s*\(",
            r"\btransport\.submit_observed\s*\(",
        )
        positions = []
        for pattern in task_stages:
            found = re.search(pattern, body)
            self.assertIsNotNone(found, f"missing submit stage {pattern}")
            positions.append(found.start())
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(
            len(re.findall(r"\bstage_observed_doorbell_image_locked\s*\(", body)),
            1,
        )
        self.assertIsNotNone(
            re.search(
                r"\bif\s*\(\s*!transaction_failed\s*\)\s*begin\s*"
                r"stage_observed_doorbell_image_locked\s*\(\s*"
                r"record_candidate\.items\.size\(\)\s*,\s*final_sequence\s*,"
                r"\s*final_pi\s*,\s*final_polarity\s*,\s*doorbell_snapshot\s*,"
                r"\s*transaction_status\s*,\s*transaction_failed\s*\)\s*;"
                r"\s*end",
                body,
                flags=re.DOTALL,
            ),
            "pre-ID doorbell stage must run exactly once after candidate success",
        )
        self.assertNotRegex(body, r"\bstatus\s*=\s*profile\.encode_doorbell\s*\(")
        self.assertNotRegex(body, r"\bfinal_sequence\s*=\s*publish_seq\s*\+")

    # 功能：冻结 observed submit 的最短 deadline 和 doorbell descriptor 在同一
    #   锁内、image 成功之后及 batch ID 分配之前的先后次序与失败优先级。
    # 输入/输出及副作用：只读 engine helper/task 文本，检查按序扫描、factory
    #   candidate、Function/target 快照、完整 descriptor 配置与唯一调用；不运行仿真。
    # 失败/边界：过期时仍构造 descriptor、漏算最短剩余时间、改变两次 nested
    #   snapshot 顺序、让 helper 分配 ID/安装账本或 task 重复构造 descriptor 均失败。
    def test_observed_submit_doorbell_descriptor_stage(self):
        source = (ROOT / "src" / "core" / "rdma_cmq_engine.sv").read_text()
        engine = self._class_body("rdma_cmq_engine", source)
        helper_match = re.search(
            r"\bprotected\s+function\s+automatic\s+void\s+"
            r"stage_observed_doorbell_descriptor_locked\s*\("
            r"(?P<args>[^;]*)\)\s*;(?P<body>.*?)\bendfunction\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(helper_match, "missing locked descriptor stage")
        args = helper_match.group("args")
        for pattern in (
            r"\binput\s+rdma_cmq_batch_submission_record\s+record_candidate\b",
            r"\binput\s+rdma_function_handle\s+active_function\b",
            r"\binput\s+rdma_hw_image\s+doorbell_snapshot\b",
            r"\binput\s+rdma_doorbell_dependency\s+dependencies\s*\[\s*\$\s*\]",
            r"\boutput\s+rdma_doorbell_desc\s+doorbell_snapshot_desc\b",
            r"\bref\s+rdma_status\s+transaction_status\b",
            r"\bref\s+bit\s+transaction_failed\b",
        ):
            self.assertRegex(args, pattern)
        helper = re.sub(r"//[^\n]*", "", helper_match.group("body"))
        stages = (
            r"\bminimum_remaining\s*=\s*0\s*;",
            r"\bforeach\s*\(\s*record_candidate\.items\[i\]\s*\)",
            r"\bif\s*\(\s*\$time\s*>=\s*"
            r"record_candidate\.items\[i\]\.ticket\.absolute_deadline\s*\)",
            r"\bremaining\s*=\s*record_candidate\.items\[i\]\.ticket\."
            r"absolute_deadline\s*-\s*\$time\s*;",
            r"\bif\s*\(\s*minimum_remaining\s*==\s*0\s*\|\|\s*"
            r"remaining\s*<\s*minimum_remaining\s*\)",
            r"\bdoorbell_candidate\s*=\s*rdma_doorbell_desc::type_id::create\s*\(",
            r"\bstatus\s*=\s*checked_function_snapshot\s*\(",
            r"\bstatus\s*=\s*checked_handle_snapshot\s*\(",
            r"\bdoorbell_candidate\.dependencies\s*=\s*dependencies\s*;",
            r"\bdoorbell_candidate\.timeout\s*=\s*minimum_remaining\s*;",
            r"\bstatus\s*=\s*checked_doorbell_desc_snapshot\s*\(",
        )
        positions = []
        for pattern in stages:
            found = re.search(pattern, helper)
            self.assertIsNotNone(found, f"missing descriptor step {pattern}")
            positions.append(found.start())
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(
            len(re.findall(r"\bif\s*\(\s*!transaction_failed\s*\)\s*begin", helper)),
            5,
            "deadline and descriptor must retain five guarded stages",
        )
        for message in (
            "CMQ batch deadline expired before publication",
            "CMQ doorbell descriptor construction failed",
            "cmq_doorbell_function_status",
            "cmq_doorbell_target_status",
            "cmq_doorbell_descriptor_status",
        ):
            self.assertIn(message, helper)
        self.assertNotRegex(
            helper,
            r"\b(?:engine_lock|submission_journal|journal_batch_by_ticket|"
            r"preallocated_publish_batches|allocate_batch_identity_locked|"
            r"allocate_attempt_id_locked|install_submission_journal_locked)\b"
            r"|\btransport\s*\.\s*submit_observed\s*\(",
        )

        submit = re.search(
            r"\btask\s+submit_batch_observed\s*\([^;]*;(?P<body>.*?)"
            r"\bendtask\b",
            engine,
            flags=re.DOTALL,
        )
        self.assertIsNotNone(submit)
        body = re.sub(r"//[^\n]*", "", submit.group("body"))
        self.assertEqual(
            len(re.findall(r"\bstage_observed_doorbell_descriptor_locked\s*\(", body)),
            1,
        )
        self.assertNotRegex(body, r"\bminimum_remaining\s*=|\bdoorbell_candidate\s*=")
        self.assertNotRegex(body, r"\bchecked_doorbell_desc_snapshot\s*\(")
        self.assertIsNotNone(
            re.search(
                r"\bif\s*\(\s*transaction_failed\s*\)\s*begin\s*"
                r"if\s*\(\s*transaction_status\s*==\s*null\s*\).*?"
                r"\bif\s*\(\s*!local_result_finalized\[i\]\s*\).*?"
                r"\bengine_lock\.put\s*\(\s*1\s*\)",
                body,
                flags=re.DOTALL,
            ),
            "pre-ID descriptor failures must use the task's original fanout",
        )

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
