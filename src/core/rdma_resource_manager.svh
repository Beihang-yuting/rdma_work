// These are deliberately plain classes.  Capturing caller state must not
// dispatch through UVM clone/copy hooks that an untrusted public value can
// override, and the snapshots must never become publishable registry values.
class rdma_rm_handle_snapshot;
  rdma_handle object_ref;
  uvm_object_wrapper object_type;
  rdma_resource_kind_e kind;
  longint unsigned function_uid;
  int unsigned object_id;
  int unsigned generation;
endclass

class rdma_rm_mapping_snapshot;
  rdma_dma_mapping object_ref;
  uvm_object_wrapper object_type;
  rdma_rm_handle_snapshot function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  rdma_backing_addr_t backing_addr;
  rdma_iova_t iova;
  longint unsigned size;
  rdma_dma_direction_e direction;
  rdma_dma_permission_t permissions;
  rdma_mapping_state_e state;
  rdma_rm_handle_snapshot owner_h;
endclass

class rdma_rm_backing_ref_snapshot;
  rdma_backing_ref object_ref;
  uvm_object_wrapper object_type;
  rdma_rm_mapping_snapshot mapping;
  rdma_resource_ownership_e ownership;
  bit release_complete;
endclass

class rdma_rm_hmc_ref_snapshot;
  rdma_hmc_ref object_ref;
  uvm_object_wrapper object_type;
  rdma_rm_handle_snapshot owner;
  rdma_resource_kind_e object_kind;
  rdma_hmc_fvm_addr_t address;
  longint unsigned size;
  int unsigned first_pbl_index;
  rdma_resource_ownership_e ownership;
  bit release_complete;
endclass

class rdma_rm_bar_snapshot;
  rdma_bar_info object_ref;
  uvm_object_wrapper object_type;
  bit [2:0] bar_id;
  rdma_bar_addr_t base;
  longint unsigned size;
  bit enabled;
endclass

class rdma_rm_pcie_snapshot;
  rdma_pcie_identity object_ref;
  uvm_object_wrapper object_type;
  rdma_bdf_t bdf;
  rdma_bdf_t parent_pf_bdf;
  int unsigned vf_index;
  bit mse;
  bit bme;
  rdma_rm_bar_snapshot bar[6];
endclass

class rdma_rm_binding_snapshot;
  rdma_function_binding object_ref;
  uvm_object_wrapper object_type;
  longint unsigned function_uid;
  rdma_rm_pcie_snapshot pcie;
  bit [2:0] notify_bar_id;
  rdma_bar_addr_t notify_base;
  longint unsigned notify_size;
  int unsigned notify_table_sel;
  int unsigned notify_table_index;
  int unsigned host_id;
  int unsigned pfvf_id;
  int unsigned rdma_vf_id;
  int unsigned global_function_id;
  int unsigned vsi_id;
  int unsigned dma_domain_id;
  bit dma_domain_valid;
  rdma_binding_state_e state;
  int unsigned generation;
  rdma_rm_handle_snapshot owner_h;
  bit notify_valid;
  bit notify_ready;
  bit dmi_valid;
  bit dmi_ready;
  bit vft_valid;
  bit vft_ready;
endclass

class rdma_rm_resource_snapshot;
  rdma_resource object_ref;
  uvm_object_wrapper object_type;
  rdma_resource_kind_e kind;
  uvm_object graph_nodes[$];

  rdma_rm_handle_snapshot handle;
  rdma_rm_handle_snapshot owner;
  rdma_resource_state_e state;
  rdma_rm_backing_ref_snapshot backing_refs[$];
  rdma_rm_hmc_ref_snapshot hmc_refs[$];
  rdma_rm_handle_snapshot dependencies[$];
  longint unsigned outstanding_ids[$];
  rdma_hmc_fvm_addr_t hmc_fvm_addr;
  bit hmc_fvm_addr_valid;

  int unsigned depth;
  int unsigned producer_index;
  int unsigned consumer_index;
  bit producer_wrap;
  bit consumer_wrap;
  rdma_iova_t queue_iova;

  int unsigned local_function_id;
  int unsigned global_function_id;
  int unsigned rdma_vf_id;
  int unsigned vsi_id;
  int unsigned pfvf_id;
  rdma_rm_binding_snapshot binding;

  int unsigned local_pd_id;
  int unsigned global_pd_id;

  int unsigned local_mr_id;
  int unsigned global_mr_id;
  rdma_rm_handle_snapshot mr_pd_h;
  rdma_iova_t mr_iova;
  longint unsigned mr_length;
  bit [31:0] lkey;
  bit [31:0] rkey;
  rdma_rdma_access_t access;
  bit [11:0] mr_serial;

  int unsigned local_cq_id;
  int unsigned global_cq_id;
  rdma_rm_handle_snapshot ceq_h;

  int unsigned local_qp_id;
  int unsigned global_qp_id;
  rdma_transport_e transport;
  rdma_qp_state_e qp_state;
  int unsigned sq_depth;
  int unsigned rq_depth;
  int unsigned sq_producer_index;
  int unsigned sq_consumer_index;
  bit sq_wrap;
  bit sq_consumer_wrap;
  int unsigned rq_producer_index;
  int unsigned rq_consumer_index;
  bit rq_wrap;
  bit rq_consumer_wrap;
  rdma_iova_t sq_iova;
  rdma_iova_t rq_iova;
  rdma_rm_handle_snapshot qp_pd_h;
  rdma_rm_handle_snapshot send_cq_h;
  rdma_rm_handle_snapshot recv_cq_h;
  rdma_rm_handle_snapshot srq_h;

  int unsigned local_srq_id;
  int unsigned global_srq_id;
  int unsigned max_sge;
  rdma_rm_handle_snapshot srq_pd_h;

  int unsigned local_cmq_id;
  int unsigned global_cmq_id;
  int unsigned completion_producer_index;
  int unsigned completion_consumer_index;
  bit completion_wrap;
  bit completion_consumer_wrap;
  rdma_iova_t completion_iova;

  int unsigned local_ceq_id;
  int unsigned global_ceq_id;
  int unsigned local_aeq_id;
  int unsigned global_aeq_id;
endclass

class rdma_rm_opcode_snapshot;
  rdma_cmq_opcode_key object_ref;
  uvm_object_wrapper object_type;
  string profile_name;
  bit [31:0] opcode;
  string variant;
endclass

class rdma_rm_ticket_snapshot;
  rdma_cmq_ticket object_ref;
  uvm_object_wrapper object_type;
  longint unsigned command_id;
  rdma_rm_handle_snapshot function_h;
  rdma_rm_handle_snapshot cmq_h;
  longint unsigned slot_sequence;
  int unsigned sq_index;
  bit sq_wrap;
  rdma_rm_opcode_snapshot opcode_key;
  time absolute_deadline;
endclass

class rdma_rm_status_snapshot;
  rdma_status object_ref;
  uvm_object_wrapper object_type;
  rdma_status_category_e category;
  rdma_status_code_e code;
  bit [31:0] hardware_code;
  bit hardware_code_valid;
  rdma_engine_kind_e source_engine;
  bit [63:0] function_uid;
  bit [31:0] generation;
  bit [63:0] resource_id;
  bit [63:0] command_id;
  bit [63:0] wr_id;
  rdma_severity_e severity;
  bit retryable;
  string message;
endclass

class rdma_rm_recovery_snapshot;
  rdma_recovery_record object_ref;
  uvm_object_wrapper object_type;
  uvm_object graph_nodes[$];
  rdma_rm_handle_snapshot resource_h;
  rdma_hw_presence_e hardware_presence;
  rdma_control_step_e completed_steps[$];
  rdma_control_step_e pending_steps[$];
  rdma_rm_backing_ref_snapshot backing_refs[$];
  rdma_rm_hmc_ref_snapshot hmc_refs[$];
  rdma_rm_ticket_snapshot ambiguous_ticket;
  rdma_rm_status_snapshot primary_status;
  rdma_rm_status_snapshot rollback_statuses[$];
endclass

class rdma_resource_manager extends uvm_object;
  `uvm_object_utils(rdma_resource_manager)

  // Registry keys are exactly function_uid:generation:kind:object_id.
  protected rdma_resource registry[string];
  protected bit staged_allocations[string];
  protected rdma_recovery_record recovery_records[string];
  // The caller-owned reference is only a monotonic generation observer.  All
  // identity and configuration are read from the immutable deep-copy snapshot.
  protected rdma_function_binding generation_sources[string];
  protected rdma_function_binding binding_snapshots[string];
  protected int unsigned generation_high_water[string];
  protected bit generation_exhausted[string];
  protected bit known_generations[string];
  protected bit retired_generations[string];
  // Exact incarnation ownership is retained after release.  Including the
  // generation prevents a later Function generation from replacing an older
  // tombstone.
  protected rdma_function_handle incarnation_owners[string];
  protected rdma_handle incarnation_handles[string];

  // Local IDs are reusable and independent for every resource kind.  The
  // 28-bit serial component of object_id is monotonic and never reused; the
  // upper nibble carries kind so changing only handle.kind cannot alias a live
  // object from another independent pool.
  protected int unsigned next_local_id[rdma_resource_kind_e];
  protected int unsigned free_local_ids[rdma_resource_kind_e][$];
  protected bit fresh_local_id_exhausted[rdma_resource_kind_e];
  protected int unsigned next_object_serial[rdma_resource_kind_e];

  function new(string name = "rdma_resource_manager");
    super.new(name);
  endfunction

  protected function rdma_rm_handle_snapshot capture_handle_snapshot(
    rdma_handle source
  );
    rdma_rm_handle_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.kind = source.kind;
      snapshot.function_uid = source.function_uid;
      snapshot.object_id = source.object_id;
      snapshot.generation = source.generation;
    end
    return snapshot;
  endfunction

  protected function bit restore_handle_snapshot(
    rdma_rm_handle_snapshot snapshot
  );
    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    snapshot.object_ref.kind = snapshot.kind;
    snapshot.object_ref.function_uid = snapshot.function_uid;
    snapshot.object_ref.object_id = snapshot.object_id;
    snapshot.object_ref.generation = snapshot.generation;
    return snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit handle_snapshot_matches(
    rdma_handle value,
    rdma_rm_handle_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           value.kind == snapshot.kind &&
           value.function_uid == snapshot.function_uid &&
           value.object_id == snapshot.object_id &&
           value.generation == snapshot.generation;
  endfunction

  protected function rdma_rm_mapping_snapshot capture_mapping_snapshot(
    rdma_dma_mapping source
  );
    rdma_rm_mapping_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.function_h = capture_handle_snapshot(source.function_h);
      snapshot.requester_bdf = source.requester_bdf;
      snapshot.pasid_valid = source.pasid_valid;
      snapshot.pasid = source.pasid;
      snapshot.backing_addr = source.backing_addr;
      snapshot.iova = source.iova;
      snapshot.size = source.size;
      snapshot.direction = source.direction;
      snapshot.permissions = source.permissions;
      snapshot.state = source.state;
      snapshot.owner_h = capture_handle_snapshot(source.owner_h);
    end
    return snapshot;
  endfunction

  protected function bit restore_mapping_snapshot(
    rdma_rm_mapping_snapshot snapshot
  );
    rdma_function_handle function_h;
    bit ok;

    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    ok = restore_handle_snapshot(snapshot.function_h);
    ok = restore_handle_snapshot(snapshot.owner_h) && ok;
    if (snapshot.function_h.object_ref == null)
      snapshot.object_ref.function_h = null;
    else if (!$cast(function_h, snapshot.function_h.object_ref))
      ok = 1'b0;
    else
      snapshot.object_ref.function_h = function_h;
    snapshot.object_ref.requester_bdf = snapshot.requester_bdf;
    snapshot.object_ref.pasid_valid = snapshot.pasid_valid;
    snapshot.object_ref.pasid = snapshot.pasid;
    snapshot.object_ref.backing_addr = snapshot.backing_addr;
    snapshot.object_ref.iova = snapshot.iova;
    snapshot.object_ref.size = snapshot.size;
    snapshot.object_ref.direction = snapshot.direction;
    snapshot.object_ref.permissions = snapshot.permissions;
    snapshot.object_ref.state = snapshot.state;
    snapshot.object_ref.owner_h = snapshot.owner_h.object_ref;
    return ok && snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit mapping_snapshot_matches(
    rdma_dma_mapping value,
    rdma_rm_mapping_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           handle_snapshot_matches(value.function_h, snapshot.function_h) &&
           value.requester_bdf == snapshot.requester_bdf &&
           value.pasid_valid == snapshot.pasid_valid &&
           value.pasid == snapshot.pasid &&
           value.backing_addr == snapshot.backing_addr &&
           value.iova == snapshot.iova && value.size == snapshot.size &&
           value.direction == snapshot.direction &&
           value.permissions == snapshot.permissions &&
           value.state == snapshot.state &&
           handle_snapshot_matches(value.owner_h, snapshot.owner_h);
  endfunction

  protected function rdma_rm_backing_ref_snapshot
    capture_backing_ref_snapshot(rdma_backing_ref source);
    rdma_rm_backing_ref_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.mapping = capture_mapping_snapshot(source.mapping);
      snapshot.ownership = source.ownership;
      snapshot.release_complete = source.release_complete;
    end
    return snapshot;
  endfunction

  protected function bit restore_backing_ref_snapshot(
    rdma_rm_backing_ref_snapshot snapshot
  );
    bit ok;

    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    ok = restore_mapping_snapshot(snapshot.mapping);
    snapshot.object_ref.mapping = snapshot.mapping.object_ref;
    snapshot.object_ref.ownership = snapshot.ownership;
    snapshot.object_ref.release_complete = snapshot.release_complete;
    return ok && snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit backing_ref_snapshot_matches(
    rdma_backing_ref value,
    rdma_rm_backing_ref_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           mapping_snapshot_matches(value.mapping, snapshot.mapping) &&
           value.ownership == snapshot.ownership &&
           value.release_complete == snapshot.release_complete;
  endfunction

  protected function rdma_rm_hmc_ref_snapshot capture_hmc_ref_snapshot(
    rdma_hmc_ref source
  );
    rdma_rm_hmc_ref_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.owner = capture_handle_snapshot(source.owner);
      snapshot.object_kind = source.object_kind;
      snapshot.address = source.address;
      snapshot.size = source.size;
      snapshot.first_pbl_index = source.first_pbl_index;
      snapshot.ownership = source.ownership;
      snapshot.release_complete = source.release_complete;
    end
    return snapshot;
  endfunction

  protected function bit restore_hmc_ref_snapshot(
    rdma_rm_hmc_ref_snapshot snapshot
  );
    rdma_function_handle owner;
    bit ok;

    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    ok = restore_handle_snapshot(snapshot.owner);
    if (snapshot.owner.object_ref == null)
      snapshot.object_ref.owner = null;
    else if (!$cast(owner, snapshot.owner.object_ref))
      ok = 1'b0;
    else
      snapshot.object_ref.owner = owner;
    snapshot.object_ref.object_kind = snapshot.object_kind;
    snapshot.object_ref.address = snapshot.address;
    snapshot.object_ref.size = snapshot.size;
    snapshot.object_ref.first_pbl_index = snapshot.first_pbl_index;
    snapshot.object_ref.ownership = snapshot.ownership;
    snapshot.object_ref.release_complete = snapshot.release_complete;
    return ok && snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit hmc_ref_snapshot_matches(
    rdma_hmc_ref value,
    rdma_rm_hmc_ref_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           handle_snapshot_matches(value.owner, snapshot.owner) &&
           value.object_kind == snapshot.object_kind &&
           value.address == snapshot.address && value.size == snapshot.size &&
           value.first_pbl_index == snapshot.first_pbl_index &&
           value.ownership == snapshot.ownership &&
           value.release_complete == snapshot.release_complete;
  endfunction

  protected function rdma_rm_bar_snapshot capture_bar_snapshot(
    rdma_bar_info source
  );
    rdma_rm_bar_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.bar_id = source.bar_id;
      snapshot.base = source.base;
      snapshot.size = source.size;
      snapshot.enabled = source.enabled;
    end
    return snapshot;
  endfunction

  protected function bit restore_bar_snapshot(rdma_rm_bar_snapshot snapshot);
    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    snapshot.object_ref.bar_id = snapshot.bar_id;
    snapshot.object_ref.base = snapshot.base;
    snapshot.object_ref.size = snapshot.size;
    snapshot.object_ref.enabled = snapshot.enabled;
    return snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit bar_snapshot_matches(
    rdma_bar_info value,
    rdma_rm_bar_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           value.bar_id == snapshot.bar_id && value.base == snapshot.base &&
           value.size == snapshot.size && value.enabled == snapshot.enabled;
  endfunction

  protected function rdma_rm_pcie_snapshot capture_pcie_snapshot(
    rdma_pcie_identity source
  );
    rdma_rm_pcie_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.bdf = source.bdf;
      snapshot.parent_pf_bdf = source.parent_pf_bdf;
      snapshot.vf_index = source.vf_index;
      snapshot.mse = source.mse;
      snapshot.bme = source.bme;
      foreach (source.bar[i])
        snapshot.bar[i] = capture_bar_snapshot(source.bar[i]);
    end
    return snapshot;
  endfunction

  protected function bit restore_pcie_snapshot(
    rdma_rm_pcie_snapshot snapshot
  );
    bit ok;

    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    ok = 1'b1;
    snapshot.object_ref.bdf = snapshot.bdf;
    snapshot.object_ref.parent_pf_bdf = snapshot.parent_pf_bdf;
    snapshot.object_ref.vf_index = snapshot.vf_index;
    snapshot.object_ref.mse = snapshot.mse;
    snapshot.object_ref.bme = snapshot.bme;
    foreach (snapshot.object_ref.bar[i]) begin
      snapshot.object_ref.bar[i] = snapshot.bar[i].object_ref;
      ok = restore_bar_snapshot(snapshot.bar[i]) && ok;
    end
    return ok && snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit pcie_snapshot_matches(
    rdma_pcie_identity value,
    rdma_rm_pcie_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    if (value.get_object_type() != snapshot.object_type ||
        value.bdf != snapshot.bdf ||
        value.parent_pf_bdf != snapshot.parent_pf_bdf ||
        value.vf_index != snapshot.vf_index || value.mse != snapshot.mse ||
        value.bme != snapshot.bme)
      return 1'b0;
    foreach (value.bar[i]) begin
      if (!bar_snapshot_matches(value.bar[i], snapshot.bar[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function rdma_rm_binding_snapshot capture_binding_snapshot(
    rdma_function_binding source
  );
    rdma_rm_binding_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.function_uid = source.function_uid;
      snapshot.pcie = capture_pcie_snapshot(source.pcie);
      snapshot.notify_bar_id = source.notify_bar_id;
      snapshot.notify_base = source.notify_base;
      snapshot.notify_size = source.notify_size;
      snapshot.notify_table_sel = source.notify_table_sel;
      snapshot.notify_table_index = source.notify_table_index;
      snapshot.host_id = source.host_id;
      snapshot.pfvf_id = source.pfvf_id;
      snapshot.rdma_vf_id = source.rdma_vf_id;
      snapshot.global_function_id = source.global_function_id;
      snapshot.vsi_id = source.vsi_id;
      snapshot.dma_domain_id = source.dma_domain_id;
      snapshot.dma_domain_valid = source.dma_domain_valid;
      snapshot.state = source.state;
      snapshot.generation = source.generation;
      snapshot.owner_h = capture_handle_snapshot(source.owner_h);
      snapshot.notify_valid = source.notify_valid;
      snapshot.notify_ready = source.notify_ready;
      snapshot.dmi_valid = source.dmi_valid;
      snapshot.dmi_ready = source.dmi_ready;
      snapshot.vft_valid = source.vft_valid;
      snapshot.vft_ready = source.vft_ready;
    end
    return snapshot;
  endfunction

  protected function bit restore_binding_snapshot(
    rdma_rm_binding_snapshot snapshot
  );
    bit ok;

    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    ok = restore_pcie_snapshot(snapshot.pcie);
    ok = restore_handle_snapshot(snapshot.owner_h) && ok;
    snapshot.object_ref.function_uid = snapshot.function_uid;
    snapshot.object_ref.pcie = snapshot.pcie.object_ref;
    snapshot.object_ref.notify_bar_id = snapshot.notify_bar_id;
    snapshot.object_ref.notify_base = snapshot.notify_base;
    snapshot.object_ref.notify_size = snapshot.notify_size;
    snapshot.object_ref.notify_table_sel = snapshot.notify_table_sel;
    snapshot.object_ref.notify_table_index = snapshot.notify_table_index;
    snapshot.object_ref.host_id = snapshot.host_id;
    snapshot.object_ref.pfvf_id = snapshot.pfvf_id;
    snapshot.object_ref.rdma_vf_id = snapshot.rdma_vf_id;
    snapshot.object_ref.global_function_id = snapshot.global_function_id;
    snapshot.object_ref.vsi_id = snapshot.vsi_id;
    snapshot.object_ref.dma_domain_id = snapshot.dma_domain_id;
    snapshot.object_ref.dma_domain_valid = snapshot.dma_domain_valid;
    snapshot.object_ref.state = snapshot.state;
    snapshot.object_ref.generation = snapshot.generation;
    snapshot.object_ref.owner_h = snapshot.owner_h.object_ref;
    snapshot.object_ref.notify_valid = snapshot.notify_valid;
    snapshot.object_ref.notify_ready = snapshot.notify_ready;
    snapshot.object_ref.dmi_valid = snapshot.dmi_valid;
    snapshot.object_ref.dmi_ready = snapshot.dmi_ready;
    snapshot.object_ref.vft_valid = snapshot.vft_valid;
    snapshot.object_ref.vft_ready = snapshot.vft_ready;
    return ok && snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit binding_snapshot_matches(
    rdma_function_binding value,
    rdma_rm_binding_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           value.function_uid == snapshot.function_uid &&
           pcie_snapshot_matches(value.pcie, snapshot.pcie) &&
           value.notify_bar_id == snapshot.notify_bar_id &&
           value.notify_base == snapshot.notify_base &&
           value.notify_size == snapshot.notify_size &&
           value.notify_table_sel == snapshot.notify_table_sel &&
           value.notify_table_index == snapshot.notify_table_index &&
           value.host_id == snapshot.host_id &&
           value.pfvf_id == snapshot.pfvf_id &&
           value.rdma_vf_id == snapshot.rdma_vf_id &&
           value.global_function_id == snapshot.global_function_id &&
           value.vsi_id == snapshot.vsi_id &&
           value.dma_domain_id == snapshot.dma_domain_id &&
           value.dma_domain_valid == snapshot.dma_domain_valid &&
           value.state == snapshot.state &&
           value.generation == snapshot.generation &&
           handle_snapshot_matches(value.owner_h, snapshot.owner_h) &&
           value.notify_valid == snapshot.notify_valid &&
           value.notify_ready == snapshot.notify_ready &&
           value.dmi_valid == snapshot.dmi_valid &&
           value.dmi_ready == snapshot.dmi_ready &&
           value.vft_valid == snapshot.vft_valid &&
           value.vft_ready == snapshot.vft_ready;
  endfunction

  protected function rdma_rm_resource_snapshot capture_resource_snapshot(
    rdma_resource source
  );
    rdma_rm_resource_snapshot snapshot;
    rdma_queue_resource queue_value;
    rdma_function function_value;
    rdma_pd pd_value;
    rdma_mr mr_value;
    rdma_cq cq_value;
    rdma_qp qp_value;
    rdma_srq srq_value;
    rdma_cmq cmq_value;
    rdma_ceq ceq_value;
    rdma_aeq aeq_value;

    if (source == null)
      return null;
    snapshot = new;
    snapshot.object_ref = source;
    snapshot.object_type = source.get_object_type();
    snapshot.kind = source.resource_kind();
    snapshot.handle = capture_handle_snapshot(source.handle);
    snapshot.owner = capture_handle_snapshot(source.owner);
    snapshot.state = source.state;
    foreach (source.backing_refs[i])
      snapshot.backing_refs.push_back(
        capture_backing_ref_snapshot(source.backing_refs[i])
      );
    foreach (source.hmc_refs[i])
      snapshot.hmc_refs.push_back(capture_hmc_ref_snapshot(source.hmc_refs[i]));
    foreach (source.dependencies[i])
      snapshot.dependencies.push_back(
        capture_handle_snapshot(source.dependencies[i])
      );
    snapshot.outstanding_ids = source.outstanding_ids;
    snapshot.hmc_fvm_addr = source.hmc_fvm_addr;
    snapshot.hmc_fvm_addr_valid = source.hmc_fvm_addr_valid;

    case (snapshot.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(function_value, source))
          return null;
        snapshot.local_function_id = function_value.local_function_id;
        snapshot.global_function_id = function_value.global_function_id;
        snapshot.rdma_vf_id = function_value.rdma_vf_id;
        snapshot.vsi_id = function_value.vsi_id;
        snapshot.pfvf_id = function_value.pfvf_id;
        snapshot.binding = capture_binding_snapshot(function_value.binding);
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(pd_value, source))
          return null;
        snapshot.local_pd_id = pd_value.local_pd_id;
        snapshot.global_pd_id = pd_value.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(mr_value, source))
          return null;
        snapshot.local_mr_id = mr_value.local_mr_id;
        snapshot.global_mr_id = mr_value.global_mr_id;
        snapshot.mr_pd_h = capture_handle_snapshot(mr_value.pd_h);
        snapshot.mr_iova = mr_value.iova;
        snapshot.mr_length = mr_value.length;
        snapshot.lkey = mr_value.lkey;
        snapshot.rkey = mr_value.rkey;
        snapshot.access = mr_value.access;
        snapshot.mr_serial = mr_value.mr_serial;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq_value, source) || !$cast(queue_value, source))
          return null;
        snapshot.depth = queue_value.depth;
        snapshot.producer_index = queue_value.producer_index;
        snapshot.consumer_index = queue_value.consumer_index;
        snapshot.producer_wrap = queue_value.producer_wrap;
        snapshot.consumer_wrap = queue_value.consumer_wrap;
        snapshot.queue_iova = queue_value.queue_iova;
        snapshot.local_cq_id = cq_value.local_cq_id;
        snapshot.global_cq_id = cq_value.global_cq_id;
        snapshot.ceq_h = capture_handle_snapshot(cq_value.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(qp_value, source))
          return null;
        snapshot.local_qp_id = qp_value.local_qp_id;
        snapshot.global_qp_id = qp_value.global_qp_id;
        snapshot.transport = qp_value.transport;
        snapshot.qp_state = qp_value.qp_state;
        snapshot.sq_depth = qp_value.sq_depth;
        snapshot.rq_depth = qp_value.rq_depth;
        snapshot.sq_producer_index = qp_value.sq_producer_index;
        snapshot.sq_consumer_index = qp_value.sq_consumer_index;
        snapshot.sq_wrap = qp_value.sq_wrap;
        snapshot.sq_consumer_wrap = qp_value.sq_consumer_wrap;
        snapshot.rq_producer_index = qp_value.rq_producer_index;
        snapshot.rq_consumer_index = qp_value.rq_consumer_index;
        snapshot.rq_wrap = qp_value.rq_wrap;
        snapshot.rq_consumer_wrap = qp_value.rq_consumer_wrap;
        snapshot.sq_iova = qp_value.sq_iova;
        snapshot.rq_iova = qp_value.rq_iova;
        snapshot.qp_pd_h = capture_handle_snapshot(qp_value.pd_h);
        snapshot.send_cq_h = capture_handle_snapshot(qp_value.send_cq_h);
        snapshot.recv_cq_h = capture_handle_snapshot(qp_value.recv_cq_h);
        snapshot.srq_h = capture_handle_snapshot(qp_value.srq_h);
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq_value, source) || !$cast(queue_value, source))
          return null;
        snapshot.depth = queue_value.depth;
        snapshot.producer_index = queue_value.producer_index;
        snapshot.consumer_index = queue_value.consumer_index;
        snapshot.producer_wrap = queue_value.producer_wrap;
        snapshot.consumer_wrap = queue_value.consumer_wrap;
        snapshot.queue_iova = queue_value.queue_iova;
        snapshot.local_srq_id = srq_value.local_srq_id;
        snapshot.global_srq_id = srq_value.global_srq_id;
        snapshot.max_sge = srq_value.max_sge;
        snapshot.srq_pd_h = capture_handle_snapshot(srq_value.pd_h);
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(cmq_value, source) || !$cast(queue_value, source))
          return null;
        snapshot.depth = queue_value.depth;
        snapshot.producer_index = queue_value.producer_index;
        snapshot.consumer_index = queue_value.consumer_index;
        snapshot.producer_wrap = queue_value.producer_wrap;
        snapshot.consumer_wrap = queue_value.consumer_wrap;
        snapshot.queue_iova = queue_value.queue_iova;
        snapshot.local_cmq_id = cmq_value.local_cmq_id;
        snapshot.global_cmq_id = cmq_value.global_cmq_id;
        snapshot.completion_producer_index =
          cmq_value.completion_producer_index;
        snapshot.completion_consumer_index =
          cmq_value.completion_consumer_index;
        snapshot.completion_wrap = cmq_value.completion_wrap;
        snapshot.completion_consumer_wrap =
          cmq_value.completion_consumer_wrap;
        snapshot.completion_iova = cmq_value.completion_iova;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq_value, source) || !$cast(queue_value, source))
          return null;
        snapshot.depth = queue_value.depth;
        snapshot.producer_index = queue_value.producer_index;
        snapshot.consumer_index = queue_value.consumer_index;
        snapshot.producer_wrap = queue_value.producer_wrap;
        snapshot.consumer_wrap = queue_value.consumer_wrap;
        snapshot.queue_iova = queue_value.queue_iova;
        snapshot.local_ceq_id = ceq_value.local_ceq_id;
        snapshot.global_ceq_id = ceq_value.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq_value, source) || !$cast(queue_value, source))
          return null;
        snapshot.depth = queue_value.depth;
        snapshot.producer_index = queue_value.producer_index;
        snapshot.consumer_index = queue_value.consumer_index;
        snapshot.producer_wrap = queue_value.producer_wrap;
        snapshot.consumer_wrap = queue_value.consumer_wrap;
        snapshot.queue_iova = queue_value.queue_iova;
        snapshot.local_aeq_id = aeq_value.local_aeq_id;
        snapshot.global_aeq_id = aeq_value.global_aeq_id;
      end
      default: return null;
    endcase
    collect_resource_graph(source, snapshot.graph_nodes);
    return snapshot;
  endfunction

  protected function bit restore_resource_snapshot(
    rdma_rm_resource_snapshot snapshot
  );
    rdma_function_handle owner;
    rdma_queue_resource queue_value;
    rdma_function function_value;
    rdma_pd pd_value;
    rdma_mr mr_value;
    rdma_cq cq_value;
    rdma_qp qp_value;
    rdma_srq srq_value;
    rdma_cmq cmq_value;
    rdma_ceq ceq_value;
    rdma_aeq aeq_value;
    bit ok;

    if (snapshot == null || snapshot.object_ref == null)
      return 1'b0;
    ok = restore_handle_snapshot(snapshot.handle);
    ok = restore_handle_snapshot(snapshot.owner) && ok;
    snapshot.object_ref.handle = snapshot.handle.object_ref;
    if (snapshot.owner.object_ref == null)
      snapshot.object_ref.owner = null;
    else if (!$cast(owner, snapshot.owner.object_ref))
      ok = 1'b0;
    else
      snapshot.object_ref.owner = owner;
    snapshot.object_ref.state = snapshot.state;
    snapshot.object_ref.backing_refs.delete();
    foreach (snapshot.backing_refs[i]) begin
      ok = restore_backing_ref_snapshot(snapshot.backing_refs[i]) && ok;
      snapshot.object_ref.backing_refs.push_back(
        snapshot.backing_refs[i].object_ref
      );
    end
    snapshot.object_ref.hmc_refs.delete();
    foreach (snapshot.hmc_refs[i]) begin
      ok = restore_hmc_ref_snapshot(snapshot.hmc_refs[i]) && ok;
      snapshot.object_ref.hmc_refs.push_back(snapshot.hmc_refs[i].object_ref);
    end
    snapshot.object_ref.dependencies.delete();
    foreach (snapshot.dependencies[i]) begin
      ok = restore_handle_snapshot(snapshot.dependencies[i]) && ok;
      snapshot.object_ref.dependencies.push_back(
        snapshot.dependencies[i].object_ref
      );
    end
    snapshot.object_ref.outstanding_ids = snapshot.outstanding_ids;
    snapshot.object_ref.hmc_fvm_addr = snapshot.hmc_fvm_addr;
    snapshot.object_ref.hmc_fvm_addr_valid = snapshot.hmc_fvm_addr_valid;

    case (snapshot.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(function_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          ok = restore_binding_snapshot(snapshot.binding) && ok;
          function_value.local_function_id = snapshot.local_function_id;
          function_value.global_function_id = snapshot.global_function_id;
          function_value.rdma_vf_id = snapshot.rdma_vf_id;
          function_value.vsi_id = snapshot.vsi_id;
          function_value.pfvf_id = snapshot.pfvf_id;
          function_value.binding = snapshot.binding.object_ref;
        end
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(pd_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          pd_value.local_pd_id = snapshot.local_pd_id;
          pd_value.global_pd_id = snapshot.global_pd_id;
        end
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(mr_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          ok = restore_handle_snapshot(snapshot.mr_pd_h) && ok;
          mr_value.local_mr_id = snapshot.local_mr_id;
          mr_value.global_mr_id = snapshot.global_mr_id;
          mr_value.pd_h = snapshot.mr_pd_h.object_ref;
          mr_value.iova = snapshot.mr_iova;
          mr_value.length = snapshot.mr_length;
          mr_value.lkey = snapshot.lkey;
          mr_value.rkey = snapshot.rkey;
          mr_value.access = snapshot.access;
          mr_value.mr_serial = snapshot.mr_serial;
        end
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq_value, snapshot.object_ref) ||
            !$cast(queue_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          ok = restore_handle_snapshot(snapshot.ceq_h) && ok;
          queue_value.depth = snapshot.depth;
          queue_value.producer_index = snapshot.producer_index;
          queue_value.consumer_index = snapshot.consumer_index;
          queue_value.producer_wrap = snapshot.producer_wrap;
          queue_value.consumer_wrap = snapshot.consumer_wrap;
          queue_value.queue_iova = snapshot.queue_iova;
          cq_value.local_cq_id = snapshot.local_cq_id;
          cq_value.global_cq_id = snapshot.global_cq_id;
          cq_value.ceq_h = snapshot.ceq_h.object_ref;
        end
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(qp_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          ok = restore_handle_snapshot(snapshot.qp_pd_h) && ok;
          ok = restore_handle_snapshot(snapshot.send_cq_h) && ok;
          ok = restore_handle_snapshot(snapshot.recv_cq_h) && ok;
          ok = restore_handle_snapshot(snapshot.srq_h) && ok;
          qp_value.local_qp_id = snapshot.local_qp_id;
          qp_value.global_qp_id = snapshot.global_qp_id;
          qp_value.transport = snapshot.transport;
          qp_value.qp_state = snapshot.qp_state;
          qp_value.sq_depth = snapshot.sq_depth;
          qp_value.rq_depth = snapshot.rq_depth;
          qp_value.sq_producer_index = snapshot.sq_producer_index;
          qp_value.sq_consumer_index = snapshot.sq_consumer_index;
          qp_value.sq_wrap = snapshot.sq_wrap;
          qp_value.sq_consumer_wrap = snapshot.sq_consumer_wrap;
          qp_value.rq_producer_index = snapshot.rq_producer_index;
          qp_value.rq_consumer_index = snapshot.rq_consumer_index;
          qp_value.rq_wrap = snapshot.rq_wrap;
          qp_value.rq_consumer_wrap = snapshot.rq_consumer_wrap;
          qp_value.sq_iova = snapshot.sq_iova;
          qp_value.rq_iova = snapshot.rq_iova;
          qp_value.pd_h = snapshot.qp_pd_h.object_ref;
          qp_value.send_cq_h = snapshot.send_cq_h.object_ref;
          qp_value.recv_cq_h = snapshot.recv_cq_h.object_ref;
          qp_value.srq_h = snapshot.srq_h.object_ref;
        end
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq_value, snapshot.object_ref) ||
            !$cast(queue_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          ok = restore_handle_snapshot(snapshot.srq_pd_h) && ok;
          queue_value.depth = snapshot.depth;
          queue_value.producer_index = snapshot.producer_index;
          queue_value.consumer_index = snapshot.consumer_index;
          queue_value.producer_wrap = snapshot.producer_wrap;
          queue_value.consumer_wrap = snapshot.consumer_wrap;
          queue_value.queue_iova = snapshot.queue_iova;
          srq_value.local_srq_id = snapshot.local_srq_id;
          srq_value.global_srq_id = snapshot.global_srq_id;
          srq_value.max_sge = snapshot.max_sge;
          srq_value.pd_h = snapshot.srq_pd_h.object_ref;
        end
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(cmq_value, snapshot.object_ref) ||
            !$cast(queue_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          queue_value.depth = snapshot.depth;
          queue_value.producer_index = snapshot.producer_index;
          queue_value.consumer_index = snapshot.consumer_index;
          queue_value.producer_wrap = snapshot.producer_wrap;
          queue_value.consumer_wrap = snapshot.consumer_wrap;
          queue_value.queue_iova = snapshot.queue_iova;
          cmq_value.local_cmq_id = snapshot.local_cmq_id;
          cmq_value.global_cmq_id = snapshot.global_cmq_id;
          cmq_value.completion_producer_index =
            snapshot.completion_producer_index;
          cmq_value.completion_consumer_index =
            snapshot.completion_consumer_index;
          cmq_value.completion_wrap = snapshot.completion_wrap;
          cmq_value.completion_consumer_wrap =
            snapshot.completion_consumer_wrap;
          cmq_value.completion_iova = snapshot.completion_iova;
        end
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq_value, snapshot.object_ref) ||
            !$cast(queue_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          queue_value.depth = snapshot.depth;
          queue_value.producer_index = snapshot.producer_index;
          queue_value.consumer_index = snapshot.consumer_index;
          queue_value.producer_wrap = snapshot.producer_wrap;
          queue_value.consumer_wrap = snapshot.consumer_wrap;
          queue_value.queue_iova = snapshot.queue_iova;
          ceq_value.local_ceq_id = snapshot.local_ceq_id;
          ceq_value.global_ceq_id = snapshot.global_ceq_id;
        end
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq_value, snapshot.object_ref) ||
            !$cast(queue_value, snapshot.object_ref))
          ok = 1'b0;
        else begin
          queue_value.depth = snapshot.depth;
          queue_value.producer_index = snapshot.producer_index;
          queue_value.consumer_index = snapshot.consumer_index;
          queue_value.producer_wrap = snapshot.producer_wrap;
          queue_value.consumer_wrap = snapshot.consumer_wrap;
          queue_value.queue_iova = snapshot.queue_iova;
          aeq_value.local_aeq_id = snapshot.local_aeq_id;
          aeq_value.global_aeq_id = snapshot.global_aeq_id;
        end
      end
      default: ok = 1'b0;
    endcase
    return ok &&
           snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit resource_snapshot_matches(
    rdma_resource value,
    rdma_rm_resource_snapshot snapshot
  );
    rdma_queue_resource queue_value;
    rdma_function function_value;
    rdma_pd pd_value;
    rdma_mr mr_value;
    rdma_cq cq_value;
    rdma_qp qp_value;
    rdma_srq srq_value;
    rdma_cmq cmq_value;
    rdma_ceq ceq_value;
    rdma_aeq aeq_value;

    if (snapshot == null || value != snapshot.object_ref || value == null)
      return 1'b0;
    if (value.get_object_type() != snapshot.object_type ||
        value.resource_kind() != snapshot.kind ||
        !handle_snapshot_matches(value.handle, snapshot.handle) ||
        !handle_snapshot_matches(value.owner, snapshot.owner) ||
        value.state != snapshot.state ||
        value.backing_refs.size() != snapshot.backing_refs.size() ||
        value.hmc_refs.size() != snapshot.hmc_refs.size() ||
        value.dependencies.size() != snapshot.dependencies.size() ||
        value.outstanding_ids.size() != snapshot.outstanding_ids.size() ||
        value.hmc_fvm_addr != snapshot.hmc_fvm_addr ||
        value.hmc_fvm_addr_valid != snapshot.hmc_fvm_addr_valid)
      return 1'b0;
    foreach (value.backing_refs[i]) begin
      if (!backing_ref_snapshot_matches(value.backing_refs[i],
                                        snapshot.backing_refs[i]))
        return 1'b0;
    end
    foreach (value.hmc_refs[i]) begin
      if (!hmc_ref_snapshot_matches(value.hmc_refs[i], snapshot.hmc_refs[i]))
        return 1'b0;
    end
    foreach (value.dependencies[i]) begin
      if (!handle_snapshot_matches(value.dependencies[i],
                                   snapshot.dependencies[i]))
        return 1'b0;
    end
    foreach (value.outstanding_ids[i]) begin
      if (value.outstanding_ids[i] != snapshot.outstanding_ids[i])
        return 1'b0;
    end

    case (snapshot.kind)
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(function_value, value))
          return 1'b0;
        return function_value.local_function_id == snapshot.local_function_id &&
               function_value.global_function_id ==
                 snapshot.global_function_id &&
               function_value.rdma_vf_id == snapshot.rdma_vf_id &&
               function_value.vsi_id == snapshot.vsi_id &&
               function_value.pfvf_id == snapshot.pfvf_id &&
               binding_snapshot_matches(function_value.binding,
                                        snapshot.binding);
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(pd_value, value))
          return 1'b0;
        return pd_value.local_pd_id == snapshot.local_pd_id &&
               pd_value.global_pd_id == snapshot.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(mr_value, value))
          return 1'b0;
        return mr_value.local_mr_id == snapshot.local_mr_id &&
               mr_value.global_mr_id == snapshot.global_mr_id &&
               handle_snapshot_matches(mr_value.pd_h, snapshot.mr_pd_h) &&
               mr_value.iova == snapshot.mr_iova &&
               mr_value.length == snapshot.mr_length &&
               mr_value.lkey == snapshot.lkey && mr_value.rkey == snapshot.rkey &&
               mr_value.access == snapshot.access &&
               mr_value.mr_serial == snapshot.mr_serial;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq_value, value) || !$cast(queue_value, value))
          return 1'b0;
        return queue_value.depth == snapshot.depth &&
               queue_value.producer_index == snapshot.producer_index &&
               queue_value.consumer_index == snapshot.consumer_index &&
               queue_value.producer_wrap == snapshot.producer_wrap &&
               queue_value.consumer_wrap == snapshot.consumer_wrap &&
               queue_value.queue_iova == snapshot.queue_iova &&
               cq_value.local_cq_id == snapshot.local_cq_id &&
               cq_value.global_cq_id == snapshot.global_cq_id &&
               handle_snapshot_matches(cq_value.ceq_h, snapshot.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(qp_value, value))
          return 1'b0;
        return qp_value.local_qp_id == snapshot.local_qp_id &&
               qp_value.global_qp_id == snapshot.global_qp_id &&
               qp_value.transport == snapshot.transport &&
               qp_value.qp_state == snapshot.qp_state &&
               qp_value.sq_depth == snapshot.sq_depth &&
               qp_value.rq_depth == snapshot.rq_depth &&
               qp_value.sq_producer_index == snapshot.sq_producer_index &&
               qp_value.sq_consumer_index == snapshot.sq_consumer_index &&
               qp_value.sq_wrap == snapshot.sq_wrap &&
               qp_value.sq_consumer_wrap == snapshot.sq_consumer_wrap &&
               qp_value.rq_producer_index == snapshot.rq_producer_index &&
               qp_value.rq_consumer_index == snapshot.rq_consumer_index &&
               qp_value.rq_wrap == snapshot.rq_wrap &&
               qp_value.rq_consumer_wrap == snapshot.rq_consumer_wrap &&
               qp_value.sq_iova == snapshot.sq_iova &&
               qp_value.rq_iova == snapshot.rq_iova &&
               handle_snapshot_matches(qp_value.pd_h, snapshot.qp_pd_h) &&
               handle_snapshot_matches(qp_value.send_cq_h,
                                       snapshot.send_cq_h) &&
               handle_snapshot_matches(qp_value.recv_cq_h,
                                       snapshot.recv_cq_h) &&
               handle_snapshot_matches(qp_value.srq_h, snapshot.srq_h);
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq_value, value) || !$cast(queue_value, value))
          return 1'b0;
        return queue_value.depth == snapshot.depth &&
               queue_value.producer_index == snapshot.producer_index &&
               queue_value.consumer_index == snapshot.consumer_index &&
               queue_value.producer_wrap == snapshot.producer_wrap &&
               queue_value.consumer_wrap == snapshot.consumer_wrap &&
               queue_value.queue_iova == snapshot.queue_iova &&
               srq_value.local_srq_id == snapshot.local_srq_id &&
               srq_value.global_srq_id == snapshot.global_srq_id &&
               srq_value.max_sge == snapshot.max_sge &&
               handle_snapshot_matches(srq_value.pd_h, snapshot.srq_pd_h);
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(cmq_value, value) || !$cast(queue_value, value))
          return 1'b0;
        return queue_value.depth == snapshot.depth &&
               queue_value.producer_index == snapshot.producer_index &&
               queue_value.consumer_index == snapshot.consumer_index &&
               queue_value.producer_wrap == snapshot.producer_wrap &&
               queue_value.consumer_wrap == snapshot.consumer_wrap &&
               queue_value.queue_iova == snapshot.queue_iova &&
               cmq_value.local_cmq_id == snapshot.local_cmq_id &&
               cmq_value.global_cmq_id == snapshot.global_cmq_id &&
               cmq_value.completion_producer_index ==
                 snapshot.completion_producer_index &&
               cmq_value.completion_consumer_index ==
                 snapshot.completion_consumer_index &&
               cmq_value.completion_wrap == snapshot.completion_wrap &&
               cmq_value.completion_consumer_wrap ==
                 snapshot.completion_consumer_wrap &&
               cmq_value.completion_iova == snapshot.completion_iova;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq_value, value) || !$cast(queue_value, value))
          return 1'b0;
        return queue_value.depth == snapshot.depth &&
               queue_value.producer_index == snapshot.producer_index &&
               queue_value.consumer_index == snapshot.consumer_index &&
               queue_value.producer_wrap == snapshot.producer_wrap &&
               queue_value.consumer_wrap == snapshot.consumer_wrap &&
               queue_value.queue_iova == snapshot.queue_iova &&
               ceq_value.local_ceq_id == snapshot.local_ceq_id &&
               ceq_value.global_ceq_id == snapshot.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq_value, value) || !$cast(queue_value, value))
          return 1'b0;
        return queue_value.depth == snapshot.depth &&
               queue_value.producer_index == snapshot.producer_index &&
               queue_value.consumer_index == snapshot.consumer_index &&
               queue_value.producer_wrap == snapshot.producer_wrap &&
               queue_value.consumer_wrap == snapshot.consumer_wrap &&
               queue_value.queue_iova == snapshot.queue_iova &&
               aeq_value.local_aeq_id == snapshot.local_aeq_id &&
               aeq_value.global_aeq_id == snapshot.global_aeq_id;
      end
      default: return 1'b0;
    endcase
  endfunction

  protected function bit valid_kind(rdma_resource_kind_e kind);
    return kind inside {RDMA_RESOURCE_FUNCTION, RDMA_RESOURCE_PD,
                        RDMA_RESOURCE_MR, RDMA_RESOURCE_CQ,
                        RDMA_RESOURCE_QP, RDMA_RESOURCE_SRQ,
                        RDMA_RESOURCE_CMQ, RDMA_RESOURCE_CEQ,
                        RDMA_RESOURCE_AEQ};
  endfunction

  protected function int unsigned local_id_limit(
    rdma_resource_kind_e kind
  );
    case (kind)
      RDMA_RESOURCE_PD: return 16'hffff;
      RDMA_RESOURCE_MR: return 24'hff_ffff;
      default: return 32'hffff_ffff;
    endcase
  endfunction

  protected function rdma_status local_id_status(
    rdma_resource_kind_e kind,
    output bit has_free_id
  );
    int unsigned limit;

    limit = local_id_limit(kind);
    has_free_id = free_local_ids.exists(kind) &&
                  free_local_ids[kind].size() != 0;
    if (has_free_id) begin
      if (free_local_ids[kind][0] > limit)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "resource free-list local ID exceeds the hardware width"
        );
      return rdma_status::success();
    end
    if ((fresh_local_id_exhausted.exists(kind) &&
         fresh_local_id_exhausted[kind]) || next_local_id[kind] > limit)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource local ID pool is exhausted");
    return rdma_status::success();
  endfunction

  protected function void consume_local_id(
    rdma_resource_kind_e kind,
    bit has_free_id,
    output int unsigned local_id
  );
    int unsigned limit;

    if (has_free_id) begin
      local_id = free_local_ids[kind].pop_front();
      return;
    end
    limit = local_id_limit(kind);
    local_id = next_local_id[kind];
    if (local_id == limit)
      fresh_local_id_exhausted[kind] = 1'b1;
    else
      next_local_id[kind]++;
  endfunction

  protected function string resource_key(rdma_handle handle);
    return $sformatf("%016h:%08h:%01h:%08h", handle.function_uid,
                     handle.generation, handle.kind, handle.object_id);
  endfunction

  protected function string incarnation_key(rdma_handle handle);
    return resource_key(handle);
  endfunction

  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  protected function string function_generation_key(
    rdma_function_handle owner
  );
    return $sformatf("%016h:%08h:%08h", owner.function_uid,
                     owner.object_id, owner.generation);
  endfunction

  protected function rdma_resource clone_resource_value(
    rdma_resource source,
    string copy_label
  );
    uvm_object cloned_object;
    rdma_resource cloned_resource;

    if (source == null)
      return null;
    cloned_object = source.clone();
    if (cloned_object == null || cloned_object == source ||
        !$cast(cloned_resource, cloned_object) ||
        cloned_resource.get_object_type() != source.get_object_type())
      `uvm_fatal("RM_COPY_TYPE",
                 {copy_label, " resource clone type mismatch"})
    return cloned_resource;
  endfunction

  protected function rdma_recovery_record clone_recovery_value(
    rdma_recovery_record source,
    string copy_label
  );
    uvm_object cloned_object;
    rdma_recovery_record cloned_recovery;

    if (source == null)
      return null;
    cloned_object = source.clone();
    if (cloned_object == null || cloned_object == source ||
        !$cast(cloned_recovery, cloned_object) ||
        cloned_recovery.get_object_type() != source.get_object_type())
      `uvm_fatal("RM_COPY_TYPE",
                 {copy_label, " recovery record clone mismatch"})
    return cloned_recovery;
  endfunction

  protected function bit same_outstanding_ids(
    rdma_resource lhs,
    rdma_resource rhs
  );
    if (lhs == null || rhs == null ||
        lhs.outstanding_ids.size() != rhs.outstanding_ids.size())
      return 1'b0;
    foreach (lhs.outstanding_ids[i]) begin
      if (lhs.outstanding_ids[i] != rhs.outstanding_ids[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_handle_instance(rdma_handle lhs,
                                               rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.same_instance(rhs);
  endfunction

  protected function bit same_handle_value(rdma_handle lhs,
                                            rdma_handle rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.get_object_type() == rhs.get_object_type() &&
           lhs.same_instance(rhs);
  endfunction

  protected function bit same_dependency_topology(rdma_resource lhs,
                                                  rdma_resource rhs);
    if (lhs == null || rhs == null ||
        lhs.dependencies.size() != rhs.dependencies.size())
      return 1'b0;
    foreach (lhs.dependencies[i]) begin
      if (!same_handle_instance(lhs.dependencies[i], rhs.dependencies[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_binding_identity(rdma_function_binding lhs,
                                               rdma_function_binding rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.get_object_type() != rhs.get_object_type() ||
        lhs.function_uid != rhs.function_uid ||
        lhs.notify_bar_id != rhs.notify_bar_id ||
        lhs.notify_base != rhs.notify_base ||
        lhs.notify_size != rhs.notify_size ||
        lhs.notify_table_sel != rhs.notify_table_sel ||
        lhs.notify_table_index != rhs.notify_table_index ||
        lhs.host_id != rhs.host_id || lhs.pfvf_id != rhs.pfvf_id ||
        lhs.rdma_vf_id != rhs.rdma_vf_id ||
        lhs.global_function_id != rhs.global_function_id ||
        lhs.vsi_id != rhs.vsi_id ||
        lhs.dma_domain_id != rhs.dma_domain_id ||
        lhs.dma_domain_valid != rhs.dma_domain_valid ||
        lhs.state != rhs.state || lhs.generation != rhs.generation ||
        lhs.notify_valid != rhs.notify_valid ||
        lhs.notify_ready != rhs.notify_ready ||
        lhs.dmi_valid != rhs.dmi_valid || lhs.dmi_ready != rhs.dmi_ready ||
        lhs.vft_valid != rhs.vft_valid || lhs.vft_ready != rhs.vft_ready ||
        !same_handle_value(lhs.owner_h, rhs.owner_h))
      return 1'b0;
    if (lhs.pcie == null || rhs.pcie == null)
      return lhs.pcie == rhs.pcie;
    if (lhs.pcie.get_object_type() != rhs.pcie.get_object_type() ||
        lhs.pcie.bdf != rhs.pcie.bdf ||
        lhs.pcie.parent_pf_bdf != rhs.pcie.parent_pf_bdf ||
        lhs.pcie.vf_index != rhs.pcie.vf_index ||
        lhs.pcie.mse != rhs.pcie.mse || lhs.pcie.bme != rhs.pcie.bme)
      return 1'b0;
    foreach (lhs.pcie.bar[i]) begin
      if (lhs.pcie.bar[i] == null || rhs.pcie.bar[i] == null) begin
        if (lhs.pcie.bar[i] != rhs.pcie.bar[i])
          return 1'b0;
      end
      else if (lhs.pcie.bar[i].get_object_type() !=
                 rhs.pcie.bar[i].get_object_type() ||
               lhs.pcie.bar[i].bar_id != rhs.pcie.bar[i].bar_id ||
               lhs.pcie.bar[i].base != rhs.pcie.bar[i].base ||
               lhs.pcie.bar[i].size != rhs.pcie.bar[i].size ||
               lhs.pcie.bar[i].enabled != rhs.pcie.bar[i].enabled)
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function rdma_status publication_identity_status(
    rdma_resource candidate,
    rdma_resource authoritative
  );
    rdma_function candidate_function;
    rdma_function authoritative_function;
    rdma_pd candidate_pd;
    rdma_pd authoritative_pd;
    rdma_mr candidate_mr;
    rdma_mr authoritative_mr;
    rdma_cq candidate_cq;
    rdma_cq authoritative_cq;
    rdma_qp candidate_qp;
    rdma_qp authoritative_qp;
    rdma_srq candidate_srq;
    rdma_srq authoritative_srq;
    rdma_cmq candidate_cmq;
    rdma_cmq authoritative_cmq;
    rdma_ceq candidate_ceq;
    rdma_ceq authoritative_ceq;
    rdma_aeq candidate_aeq;
    rdma_aeq authoritative_aeq;
    bit fields_match;

    if (candidate == null || authoritative == null ||
        candidate.get_object_type() != authoritative.get_object_type() ||
        candidate.resource_kind() != authoritative.resource_kind() ||
        !same_handle_instance(candidate.handle, authoritative.handle) ||
        !same_handle_instance(candidate.owner, authoritative.owner) ||
        !same_dependency_topology(candidate, authoritative) ||
        !same_outstanding_ids(candidate, authoritative))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource identity or topology changed"
      );

    fields_match = 1'b0;
    case (authoritative.resource_kind())
      RDMA_RESOURCE_FUNCTION: begin
        if ($cast(candidate_function, candidate) &&
            $cast(authoritative_function, authoritative))
          fields_match = candidate_function.local_function_id ==
                      authoritative_function.local_function_id &&
                    candidate_function.global_function_id ==
                      authoritative_function.global_function_id &&
                    candidate_function.rdma_vf_id ==
                      authoritative_function.rdma_vf_id &&
                    candidate_function.vsi_id == authoritative_function.vsi_id &&
                    candidate_function.pfvf_id ==
                      authoritative_function.pfvf_id &&
                    same_binding_identity(candidate_function.binding,
                                          authoritative_function.binding);
      end
      RDMA_RESOURCE_PD: begin
        if ($cast(candidate_pd, candidate) &&
            $cast(authoritative_pd, authoritative))
          fields_match = candidate_pd.local_pd_id == authoritative_pd.local_pd_id &&
                    candidate_pd.global_pd_id == authoritative_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if ($cast(candidate_mr, candidate) &&
            $cast(authoritative_mr, authoritative))
          fields_match = candidate_mr.local_mr_id == authoritative_mr.local_mr_id &&
                    candidate_mr.global_mr_id == authoritative_mr.global_mr_id &&
                    same_handle_instance(candidate_mr.pd_h,
                                         authoritative_mr.pd_h);
      end
      RDMA_RESOURCE_CQ: begin
        if ($cast(candidate_cq, candidate) &&
            $cast(authoritative_cq, authoritative))
          fields_match = candidate_cq.local_cq_id == authoritative_cq.local_cq_id &&
                    candidate_cq.global_cq_id == authoritative_cq.global_cq_id &&
                    same_handle_instance(candidate_cq.ceq_h,
                                         authoritative_cq.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if ($cast(candidate_qp, candidate) &&
            $cast(authoritative_qp, authoritative))
          fields_match = candidate_qp.local_qp_id == authoritative_qp.local_qp_id &&
                    candidate_qp.global_qp_id == authoritative_qp.global_qp_id &&
                    same_handle_instance(candidate_qp.pd_h,
                                         authoritative_qp.pd_h) &&
                    same_handle_instance(candidate_qp.send_cq_h,
                                         authoritative_qp.send_cq_h) &&
                    same_handle_instance(candidate_qp.recv_cq_h,
                                         authoritative_qp.recv_cq_h) &&
                    same_handle_instance(candidate_qp.srq_h,
                                         authoritative_qp.srq_h);
      end
      RDMA_RESOURCE_SRQ: begin
        if ($cast(candidate_srq, candidate) &&
            $cast(authoritative_srq, authoritative))
          fields_match = candidate_srq.local_srq_id ==
                      authoritative_srq.local_srq_id &&
                    candidate_srq.global_srq_id ==
                      authoritative_srq.global_srq_id &&
                    same_handle_instance(candidate_srq.pd_h,
                                         authoritative_srq.pd_h);
      end
      RDMA_RESOURCE_CMQ: begin
        if ($cast(candidate_cmq, candidate) &&
            $cast(authoritative_cmq, authoritative))
          fields_match = candidate_cmq.local_cmq_id ==
                      authoritative_cmq.local_cmq_id &&
                    candidate_cmq.global_cmq_id ==
                      authoritative_cmq.global_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if ($cast(candidate_ceq, candidate) &&
            $cast(authoritative_ceq, authoritative))
          fields_match = candidate_ceq.local_ceq_id ==
                      authoritative_ceq.local_ceq_id &&
                    candidate_ceq.global_ceq_id ==
                      authoritative_ceq.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if ($cast(candidate_aeq, candidate) &&
            $cast(authoritative_aeq, authoritative))
          fields_match = candidate_aeq.local_aeq_id ==
                      authoritative_aeq.local_aeq_id &&
                    candidate_aeq.global_aeq_id ==
                      authoritative_aeq.global_aeq_id;
      end
    endcase
    if (!fields_match)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "published resource manager-owned fields changed"
      );
    return rdma_status::success();
  endfunction

  protected function rdma_status clone_public_resource_value(
    rdma_resource source,
    string copy_label,
    output rdma_resource result
  );
    uvm_object cloned_object;
    rdma_rm_resource_snapshot snapshot;
    rdma_status status;
    bit source_mutated;
    bit source_restored;

    result = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {copy_label, " resource is null"});
    snapshot = capture_resource_snapshot(source);
    if (snapshot == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource pre-clone snapshot failed"}
      );
    cloned_object = source.clone();
    // Detect against the pre-clone value before repair, then repair on every
    // normal clone return path before inspecting or publishing the result.
    source_mutated = !resource_snapshot_matches(source, snapshot);
    source_restored = restore_resource_snapshot(snapshot);
    source_restored = resource_snapshot_matches(source, snapshot) &&
                      source_restored;
    if (!source_restored) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " resource source restoration failed"}
      );
    end
    if (source_mutated) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource clone mutated its source"}
      );
    end
    if (cloned_object == null || cloned_object == source ||
        !$cast(result, cloned_object) ||
        result.get_object_type() != snapshot.object_type) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource clone is not a detached exact-type value"}
      );
    end
    status = publication_identity_status(result, source);
    if (!status.ok()) begin
      result = null;
      return status;
    end
    if (!same_resource_value(result, source)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource clone changed validated fields"}
      );
    end
    if (!resource_graph_detached_from_nodes(result, snapshot.graph_nodes)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " resource clone retained caller-owned aliases"}
      );
    end
    return rdma_status::success();
  endfunction

  protected function rdma_rm_opcode_snapshot capture_opcode_snapshot(
    rdma_cmq_opcode_key source
  );
    rdma_rm_opcode_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.profile_name = source.profile_name;
      snapshot.opcode = source.opcode;
      snapshot.variant = source.variant;
    end
    return snapshot;
  endfunction

  protected function bit restore_opcode_snapshot(
    rdma_rm_opcode_snapshot snapshot
  );
    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    snapshot.object_ref.profile_name = snapshot.profile_name;
    snapshot.object_ref.opcode = snapshot.opcode;
    snapshot.object_ref.variant = snapshot.variant;
    return snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit opcode_snapshot_matches(
    rdma_cmq_opcode_key value,
    rdma_rm_opcode_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           value.profile_name == snapshot.profile_name &&
           value.opcode == snapshot.opcode &&
           value.variant == snapshot.variant;
  endfunction

  protected function rdma_rm_ticket_snapshot capture_ticket_snapshot(
    rdma_cmq_ticket source
  );
    rdma_rm_ticket_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.command_id = source.command_id;
      snapshot.function_h = capture_handle_snapshot(source.function_h);
      snapshot.cmq_h = capture_handle_snapshot(source.cmq_h);
      snapshot.slot_sequence = source.slot_sequence;
      snapshot.sq_index = source.sq_index;
      snapshot.sq_wrap = source.sq_wrap;
      snapshot.opcode_key = capture_opcode_snapshot(source.opcode_key);
      snapshot.absolute_deadline = source.absolute_deadline;
    end
    return snapshot;
  endfunction

  protected function bit restore_ticket_snapshot(
    rdma_rm_ticket_snapshot snapshot
  );
    rdma_function_handle function_h;
    bit ok;

    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    ok = restore_handle_snapshot(snapshot.function_h);
    ok = restore_handle_snapshot(snapshot.cmq_h) && ok;
    ok = restore_opcode_snapshot(snapshot.opcode_key) && ok;
    snapshot.object_ref.command_id = snapshot.command_id;
    if (snapshot.function_h.object_ref == null)
      snapshot.object_ref.function_h = null;
    else if (!$cast(function_h, snapshot.function_h.object_ref))
      ok = 1'b0;
    else
      snapshot.object_ref.function_h = function_h;
    snapshot.object_ref.cmq_h = snapshot.cmq_h.object_ref;
    snapshot.object_ref.slot_sequence = snapshot.slot_sequence;
    snapshot.object_ref.sq_index = snapshot.sq_index;
    snapshot.object_ref.sq_wrap = snapshot.sq_wrap;
    snapshot.object_ref.opcode_key = snapshot.opcode_key.object_ref;
    snapshot.object_ref.absolute_deadline = snapshot.absolute_deadline;
    return snapshot.object_ref.get_object_type() == snapshot.object_type && ok;
  endfunction

  protected function bit ticket_snapshot_matches(
    rdma_cmq_ticket value,
    rdma_rm_ticket_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           value.command_id == snapshot.command_id &&
           handle_snapshot_matches(value.function_h, snapshot.function_h) &&
           handle_snapshot_matches(value.cmq_h, snapshot.cmq_h) &&
           value.slot_sequence == snapshot.slot_sequence &&
           value.sq_index == snapshot.sq_index &&
           value.sq_wrap == snapshot.sq_wrap &&
           opcode_snapshot_matches(value.opcode_key, snapshot.opcode_key) &&
           value.absolute_deadline == snapshot.absolute_deadline;
  endfunction

  protected function rdma_rm_status_snapshot capture_status_snapshot(
    rdma_status source
  );
    rdma_rm_status_snapshot snapshot;

    snapshot = new;
    snapshot.object_ref = source;
    if (source != null) begin
      snapshot.object_type = source.get_object_type();
      snapshot.category = source.category;
      snapshot.code = source.code;
      snapshot.hardware_code = source.hardware_code;
      snapshot.hardware_code_valid = source.hardware_code_valid;
      snapshot.source_engine = source.source_engine;
      snapshot.function_uid = source.function_uid;
      snapshot.generation = source.generation;
      snapshot.resource_id = source.resource_id;
      snapshot.command_id = source.command_id;
      snapshot.wr_id = source.wr_id;
      snapshot.severity = source.severity;
      snapshot.retryable = source.retryable;
      snapshot.message = source.message;
    end
    return snapshot;
  endfunction

  protected function bit restore_status_snapshot(
    rdma_rm_status_snapshot snapshot
  );
    if (snapshot == null)
      return 1'b0;
    if (snapshot.object_ref == null)
      return 1'b1;
    snapshot.object_ref.category = snapshot.category;
    snapshot.object_ref.code = snapshot.code;
    snapshot.object_ref.hardware_code = snapshot.hardware_code;
    snapshot.object_ref.hardware_code_valid = snapshot.hardware_code_valid;
    snapshot.object_ref.source_engine = snapshot.source_engine;
    snapshot.object_ref.function_uid = snapshot.function_uid;
    snapshot.object_ref.generation = snapshot.generation;
    snapshot.object_ref.resource_id = snapshot.resource_id;
    snapshot.object_ref.command_id = snapshot.command_id;
    snapshot.object_ref.wr_id = snapshot.wr_id;
    snapshot.object_ref.severity = snapshot.severity;
    snapshot.object_ref.retryable = snapshot.retryable;
    snapshot.object_ref.message = snapshot.message;
    return snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit status_snapshot_matches(
    rdma_status value,
    rdma_rm_status_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref)
      return 1'b0;
    if (value == null)
      return 1'b1;
    return value.get_object_type() == snapshot.object_type &&
           value.category == snapshot.category && value.code == snapshot.code &&
           value.hardware_code == snapshot.hardware_code &&
           value.hardware_code_valid == snapshot.hardware_code_valid &&
           value.source_engine == snapshot.source_engine &&
           value.function_uid == snapshot.function_uid &&
           value.generation == snapshot.generation &&
           value.resource_id == snapshot.resource_id &&
           value.command_id == snapshot.command_id &&
           value.wr_id == snapshot.wr_id &&
           value.severity == snapshot.severity &&
           value.retryable == snapshot.retryable &&
           value.message == snapshot.message;
  endfunction

  protected function bit same_status_value(rdma_status lhs,
                                            rdma_status rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.get_object_type() == rhs.get_object_type() &&
           lhs.category == rhs.category && lhs.code == rhs.code &&
           lhs.hardware_code == rhs.hardware_code &&
           lhs.hardware_code_valid == rhs.hardware_code_valid &&
           lhs.source_engine == rhs.source_engine &&
           lhs.function_uid == rhs.function_uid &&
           lhs.generation == rhs.generation &&
           lhs.resource_id == rhs.resource_id &&
           lhs.command_id == rhs.command_id && lhs.wr_id == rhs.wr_id &&
           lhs.severity == rhs.severity && lhs.retryable == rhs.retryable &&
           lhs.message == rhs.message;
  endfunction

  protected function bit same_ticket_value(rdma_cmq_ticket lhs,
                                            rdma_cmq_ticket rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.get_object_type() != rhs.get_object_type() ||
        lhs.command_id != rhs.command_id ||
        !same_handle_value(lhs.function_h, rhs.function_h) ||
        !same_handle_value(lhs.cmq_h, rhs.cmq_h) ||
        lhs.slot_sequence != rhs.slot_sequence ||
        lhs.sq_index != rhs.sq_index || lhs.sq_wrap != rhs.sq_wrap ||
        lhs.absolute_deadline != rhs.absolute_deadline)
      return 1'b0;
    if (lhs.opcode_key == null || rhs.opcode_key == null)
      return lhs.opcode_key == rhs.opcode_key;
    return lhs.opcode_key.get_object_type() ==
             rhs.opcode_key.get_object_type() &&
           lhs.opcode_key.profile_name == rhs.opcode_key.profile_name &&
           lhs.opcode_key.opcode == rhs.opcode_key.opcode &&
           lhs.opcode_key.variant == rhs.opcode_key.variant;
  endfunction

  protected function bit same_mapping_value(rdma_dma_mapping lhs,
                                             rdma_dma_mapping rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.get_object_type() != rhs.get_object_type() ||
        !same_handle_instance(lhs.function_h, rhs.function_h) ||
        !same_handle_instance(lhs.owner_h, rhs.owner_h))
      return 1'b0;
    if (lhs.function_h != null &&
        lhs.function_h.get_object_type() != rhs.function_h.get_object_type())
      return 1'b0;
    if (lhs.owner_h != null &&
        lhs.owner_h.get_object_type() != rhs.owner_h.get_object_type())
      return 1'b0;
    return lhs.requester_bdf == rhs.requester_bdf &&
           lhs.pasid_valid == rhs.pasid_valid && lhs.pasid == rhs.pasid &&
           lhs.backing_addr == rhs.backing_addr && lhs.iova == rhs.iova &&
           lhs.size == rhs.size && lhs.direction == rhs.direction &&
           lhs.permissions == rhs.permissions && lhs.state == rhs.state;
  endfunction

  protected function bit same_backing_ref_value(rdma_backing_ref lhs,
                                                 rdma_backing_ref rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    return lhs.get_object_type() == rhs.get_object_type() &&
           lhs.ownership == rhs.ownership &&
           lhs.release_complete == rhs.release_complete &&
           same_mapping_value(lhs.mapping, rhs.mapping);
  endfunction

  protected function bit same_hmc_ref_value(rdma_hmc_ref lhs,
                                             rdma_hmc_ref rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.get_object_type() != rhs.get_object_type() ||
        !same_handle_instance(lhs.owner, rhs.owner))
      return 1'b0;
    if (lhs.owner != null &&
        lhs.owner.get_object_type() != rhs.owner.get_object_type())
      return 1'b0;
    return lhs.object_kind == rhs.object_kind &&
           lhs.address == rhs.address && lhs.size == rhs.size &&
           lhs.first_pbl_index == rhs.first_pbl_index &&
           lhs.ownership == rhs.ownership &&
           lhs.release_complete == rhs.release_complete;
  endfunction

  protected function bit same_resource_base_value(rdma_resource lhs,
                                                   rdma_resource rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.get_object_type() != rhs.get_object_type() ||
        lhs.resource_kind() != rhs.resource_kind() ||
        !same_handle_value(lhs.handle, rhs.handle) ||
        !same_handle_value(lhs.owner, rhs.owner) ||
        lhs.state != rhs.state ||
        lhs.hmc_fvm_addr != rhs.hmc_fvm_addr ||
        lhs.hmc_fvm_addr_valid != rhs.hmc_fvm_addr_valid ||
        lhs.backing_refs.size() != rhs.backing_refs.size() ||
        lhs.hmc_refs.size() != rhs.hmc_refs.size() ||
        lhs.dependencies.size() != rhs.dependencies.size() ||
        lhs.outstanding_ids.size() != rhs.outstanding_ids.size())
      return 1'b0;
    foreach (lhs.backing_refs[i]) begin
      if (!same_backing_ref_value(lhs.backing_refs[i],
                                  rhs.backing_refs[i]))
        return 1'b0;
    end
    foreach (lhs.hmc_refs[i]) begin
      if (!same_hmc_ref_value(lhs.hmc_refs[i], rhs.hmc_refs[i]))
        return 1'b0;
    end
    foreach (lhs.dependencies[i]) begin
      if (!same_handle_value(lhs.dependencies[i], rhs.dependencies[i]))
        return 1'b0;
    end
    foreach (lhs.outstanding_ids[i]) begin
      if (lhs.outstanding_ids[i] != rhs.outstanding_ids[i])
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit same_queue_resource_value(rdma_resource lhs,
                                                    rdma_resource rhs);
    rdma_queue_resource lhs_queue;
    rdma_queue_resource rhs_queue;

    if (!$cast(lhs_queue, lhs) || !$cast(rhs_queue, rhs))
      return 1'b0;
    return lhs_queue.depth == rhs_queue.depth &&
           lhs_queue.producer_index == rhs_queue.producer_index &&
           lhs_queue.consumer_index == rhs_queue.consumer_index &&
           lhs_queue.producer_wrap == rhs_queue.producer_wrap &&
           lhs_queue.consumer_wrap == rhs_queue.consumer_wrap &&
           lhs_queue.queue_iova == rhs_queue.queue_iova;
  endfunction

  protected function bit same_resource_value(rdma_resource lhs,
                                              rdma_resource rhs);
    rdma_function lhs_function;
    rdma_function rhs_function;
    rdma_pd lhs_pd;
    rdma_pd rhs_pd;
    rdma_mr lhs_mr;
    rdma_mr rhs_mr;
    rdma_cq lhs_cq;
    rdma_cq rhs_cq;
    rdma_qp lhs_qp;
    rdma_qp rhs_qp;
    rdma_srq lhs_srq;
    rdma_srq rhs_srq;
    rdma_cmq lhs_cmq;
    rdma_cmq rhs_cmq;
    rdma_ceq lhs_ceq;
    rdma_ceq rhs_ceq;
    rdma_aeq lhs_aeq;
    rdma_aeq rhs_aeq;

    if (!same_resource_base_value(lhs, rhs))
      return 1'b0;
    case (rhs.resource_kind())
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(lhs_function, lhs) || !$cast(rhs_function, rhs))
          return 1'b0;
        return lhs_function.local_function_id ==
                 rhs_function.local_function_id &&
               lhs_function.global_function_id ==
                 rhs_function.global_function_id &&
               lhs_function.rdma_vf_id == rhs_function.rdma_vf_id &&
               lhs_function.vsi_id == rhs_function.vsi_id &&
               lhs_function.pfvf_id == rhs_function.pfvf_id &&
               same_binding_identity(lhs_function.binding,
                                     rhs_function.binding);
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(lhs_pd, lhs) || !$cast(rhs_pd, rhs))
          return 1'b0;
        return lhs_pd.local_pd_id == rhs_pd.local_pd_id &&
               lhs_pd.global_pd_id == rhs_pd.global_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(lhs_mr, lhs) || !$cast(rhs_mr, rhs))
          return 1'b0;
        return lhs_mr.local_mr_id == rhs_mr.local_mr_id &&
               lhs_mr.global_mr_id == rhs_mr.global_mr_id &&
               same_handle_value(lhs_mr.pd_h, rhs_mr.pd_h) &&
               lhs_mr.iova == rhs_mr.iova &&
               lhs_mr.length == rhs_mr.length &&
               lhs_mr.lkey == rhs_mr.lkey &&
               lhs_mr.rkey == rhs_mr.rkey &&
               lhs_mr.access == rhs_mr.access &&
               lhs_mr.mr_serial == rhs_mr.mr_serial;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(lhs_cq, lhs) || !$cast(rhs_cq, rhs))
          return 1'b0;
        return same_queue_resource_value(lhs, rhs) &&
               lhs_cq.local_cq_id == rhs_cq.local_cq_id &&
               lhs_cq.global_cq_id == rhs_cq.global_cq_id &&
               same_handle_value(lhs_cq.ceq_h, rhs_cq.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(lhs_qp, lhs) || !$cast(rhs_qp, rhs))
          return 1'b0;
        return lhs_qp.local_qp_id == rhs_qp.local_qp_id &&
               lhs_qp.global_qp_id == rhs_qp.global_qp_id &&
               lhs_qp.transport == rhs_qp.transport &&
               lhs_qp.qp_state == rhs_qp.qp_state &&
               lhs_qp.sq_depth == rhs_qp.sq_depth &&
               lhs_qp.rq_depth == rhs_qp.rq_depth &&
               lhs_qp.sq_producer_index == rhs_qp.sq_producer_index &&
               lhs_qp.sq_consumer_index == rhs_qp.sq_consumer_index &&
               lhs_qp.sq_wrap == rhs_qp.sq_wrap &&
               lhs_qp.sq_consumer_wrap == rhs_qp.sq_consumer_wrap &&
               lhs_qp.rq_producer_index == rhs_qp.rq_producer_index &&
               lhs_qp.rq_consumer_index == rhs_qp.rq_consumer_index &&
               lhs_qp.rq_wrap == rhs_qp.rq_wrap &&
               lhs_qp.rq_consumer_wrap == rhs_qp.rq_consumer_wrap &&
               lhs_qp.sq_iova == rhs_qp.sq_iova &&
               lhs_qp.rq_iova == rhs_qp.rq_iova &&
               same_handle_value(lhs_qp.pd_h, rhs_qp.pd_h) &&
               same_handle_value(lhs_qp.send_cq_h, rhs_qp.send_cq_h) &&
               same_handle_value(lhs_qp.recv_cq_h, rhs_qp.recv_cq_h) &&
               same_handle_value(lhs_qp.srq_h, rhs_qp.srq_h);
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(lhs_srq, lhs) || !$cast(rhs_srq, rhs))
          return 1'b0;
        return same_queue_resource_value(lhs, rhs) &&
               lhs_srq.local_srq_id == rhs_srq.local_srq_id &&
               lhs_srq.global_srq_id == rhs_srq.global_srq_id &&
               lhs_srq.max_sge == rhs_srq.max_sge &&
               same_handle_value(lhs_srq.pd_h, rhs_srq.pd_h);
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(lhs_cmq, lhs) || !$cast(rhs_cmq, rhs))
          return 1'b0;
        return same_queue_resource_value(lhs, rhs) &&
               lhs_cmq.local_cmq_id == rhs_cmq.local_cmq_id &&
               lhs_cmq.global_cmq_id == rhs_cmq.global_cmq_id &&
               lhs_cmq.completion_producer_index ==
                 rhs_cmq.completion_producer_index &&
               lhs_cmq.completion_consumer_index ==
                 rhs_cmq.completion_consumer_index &&
               lhs_cmq.completion_wrap == rhs_cmq.completion_wrap &&
               lhs_cmq.completion_consumer_wrap ==
                 rhs_cmq.completion_consumer_wrap &&
               lhs_cmq.completion_iova == rhs_cmq.completion_iova;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(lhs_ceq, lhs) || !$cast(rhs_ceq, rhs))
          return 1'b0;
        return same_queue_resource_value(lhs, rhs) &&
               lhs_ceq.local_ceq_id == rhs_ceq.local_ceq_id &&
               lhs_ceq.global_ceq_id == rhs_ceq.global_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(lhs_aeq, lhs) || !$cast(rhs_aeq, rhs))
          return 1'b0;
        return same_queue_resource_value(lhs, rhs) &&
               lhs_aeq.local_aeq_id == rhs_aeq.local_aeq_id &&
               lhs_aeq.global_aeq_id == rhs_aeq.global_aeq_id;
      end
      default: return 1'b0;
    endcase
  endfunction

  protected function void collect_mapping_graph(
    rdma_dma_mapping value,
    ref uvm_object nodes[$]
  );
    if (value == null)
      return;
    nodes.push_back(value);
    if (value.function_h != null)
      nodes.push_back(value.function_h);
    if (value.owner_h != null)
      nodes.push_back(value.owner_h);
  endfunction

  protected function void collect_backing_ref_graph(
    rdma_backing_ref value,
    ref uvm_object nodes[$]
  );
    if (value == null)
      return;
    nodes.push_back(value);
    collect_mapping_graph(value.mapping, nodes);
  endfunction

  protected function void collect_hmc_ref_graph(
    rdma_hmc_ref value,
    ref uvm_object nodes[$]
  );
    if (value == null)
      return;
    nodes.push_back(value);
    if (value.owner != null)
      nodes.push_back(value.owner);
  endfunction

  protected function void collect_resource_graph(
    rdma_resource value,
    ref uvm_object nodes[$]
  );
    rdma_function function_value;
    rdma_mr mr_value;
    rdma_cq cq_value;
    rdma_qp qp_value;
    rdma_srq srq_value;

    if (value == null)
      return;
    nodes.push_back(value);
    if (value.handle != null)
      nodes.push_back(value.handle);
    if (value.owner != null)
      nodes.push_back(value.owner);
    foreach (value.backing_refs[i])
      collect_backing_ref_graph(value.backing_refs[i], nodes);
    foreach (value.hmc_refs[i])
      collect_hmc_ref_graph(value.hmc_refs[i], nodes);
    foreach (value.dependencies[i]) begin
      if (value.dependencies[i] != null)
        nodes.push_back(value.dependencies[i]);
    end
    case (value.resource_kind())
      RDMA_RESOURCE_FUNCTION: begin
        if ($cast(function_value, value) && function_value.binding != null) begin
          nodes.push_back(function_value.binding);
          if (function_value.binding.owner_h != null)
            nodes.push_back(function_value.binding.owner_h);
          if (function_value.binding.pcie != null) begin
            nodes.push_back(function_value.binding.pcie);
            foreach (function_value.binding.pcie.bar[i]) begin
              if (function_value.binding.pcie.bar[i] != null)
                nodes.push_back(function_value.binding.pcie.bar[i]);
            end
          end
        end
      end
      RDMA_RESOURCE_MR: begin
        if ($cast(mr_value, value) && mr_value.pd_h != null)
          nodes.push_back(mr_value.pd_h);
      end
      RDMA_RESOURCE_CQ: begin
        if ($cast(cq_value, value) && cq_value.ceq_h != null)
          nodes.push_back(cq_value.ceq_h);
      end
      RDMA_RESOURCE_QP: begin
        if ($cast(qp_value, value)) begin
          if (qp_value.pd_h != null)
            nodes.push_back(qp_value.pd_h);
          if (qp_value.send_cq_h != null)
            nodes.push_back(qp_value.send_cq_h);
          if (qp_value.recv_cq_h != null)
            nodes.push_back(qp_value.recv_cq_h);
          if (qp_value.srq_h != null)
            nodes.push_back(qp_value.srq_h);
        end
      end
      RDMA_RESOURCE_SRQ: begin
        if ($cast(srq_value, value) && srq_value.pd_h != null)
          nodes.push_back(srq_value.pd_h);
      end
    endcase
  endfunction

  protected function bit resource_graph_detached_from_nodes(
    rdma_resource result,
    ref uvm_object source_nodes[$]
  );
    uvm_object result_nodes[$];

    if (result == null)
      return 1'b0;
    collect_resource_graph(result, result_nodes);
    foreach (result_nodes[i]) begin
      foreach (source_nodes[j]) begin
        if (result_nodes[i] == source_nodes[j])
          return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  protected function bit same_recovery_value(rdma_recovery_record lhs,
                                              rdma_recovery_record rhs);
    if (lhs == null || rhs == null)
      return lhs == rhs;
    if (lhs.get_object_type() != rhs.get_object_type() ||
        !same_handle_value(lhs.resource_h, rhs.resource_h) ||
        lhs.hardware_presence != rhs.hardware_presence ||
        lhs.completed_steps.size() != rhs.completed_steps.size() ||
        lhs.pending_steps.size() != rhs.pending_steps.size() ||
        lhs.backing_refs.size() != rhs.backing_refs.size() ||
        lhs.hmc_refs.size() != rhs.hmc_refs.size() ||
        lhs.rollback_statuses.size() != rhs.rollback_statuses.size() ||
        !same_ticket_value(lhs.ambiguous_ticket, rhs.ambiguous_ticket) ||
        !same_status_value(lhs.primary_status, rhs.primary_status))
      return 1'b0;
    foreach (lhs.completed_steps[i]) begin
      if (lhs.completed_steps[i] != rhs.completed_steps[i])
        return 1'b0;
    end
    foreach (lhs.pending_steps[i]) begin
      if (lhs.pending_steps[i] != rhs.pending_steps[i])
        return 1'b0;
    end
    foreach (lhs.backing_refs[i]) begin
      if (!same_backing_ref_value(lhs.backing_refs[i],
                                  rhs.backing_refs[i]))
        return 1'b0;
    end
    foreach (lhs.hmc_refs[i]) begin
      if (!same_hmc_ref_value(lhs.hmc_refs[i], rhs.hmc_refs[i]))
        return 1'b0;
    end
    foreach (lhs.rollback_statuses[i]) begin
      if (!same_status_value(lhs.rollback_statuses[i],
                             rhs.rollback_statuses[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function void collect_ticket_graph(
    rdma_cmq_ticket value,
    ref uvm_object nodes[$]
  );
    if (value == null)
      return;
    nodes.push_back(value);
    if (value.function_h != null)
      nodes.push_back(value.function_h);
    if (value.cmq_h != null)
      nodes.push_back(value.cmq_h);
    if (value.opcode_key != null)
      nodes.push_back(value.opcode_key);
  endfunction

  protected function void collect_recovery_graph(
    rdma_recovery_record value,
    ref uvm_object nodes[$]
  );
    if (value == null)
      return;
    nodes.push_back(value);
    if (value.resource_h != null)
      nodes.push_back(value.resource_h);
    foreach (value.backing_refs[i])
      collect_backing_ref_graph(value.backing_refs[i], nodes);
    foreach (value.hmc_refs[i])
      collect_hmc_ref_graph(value.hmc_refs[i], nodes);
    collect_ticket_graph(value.ambiguous_ticket, nodes);
    if (value.primary_status != null)
      nodes.push_back(value.primary_status);
    foreach (value.rollback_statuses[i]) begin
      if (value.rollback_statuses[i] != null)
        nodes.push_back(value.rollback_statuses[i]);
    end
  endfunction

  protected function rdma_rm_recovery_snapshot capture_recovery_snapshot(
    rdma_recovery_record source
  );
    rdma_rm_recovery_snapshot snapshot;

    if (source == null)
      return null;
    snapshot = new;
    snapshot.object_ref = source;
    snapshot.object_type = source.get_object_type();
    snapshot.resource_h = capture_handle_snapshot(source.resource_h);
    snapshot.hardware_presence = source.hardware_presence;
    snapshot.completed_steps = source.completed_steps;
    snapshot.pending_steps = source.pending_steps;
    foreach (source.backing_refs[i])
      snapshot.backing_refs.push_back(
        capture_backing_ref_snapshot(source.backing_refs[i])
      );
    foreach (source.hmc_refs[i])
      snapshot.hmc_refs.push_back(capture_hmc_ref_snapshot(source.hmc_refs[i]));
    snapshot.ambiguous_ticket = capture_ticket_snapshot(source.ambiguous_ticket);
    snapshot.primary_status = capture_status_snapshot(source.primary_status);
    foreach (source.rollback_statuses[i])
      snapshot.rollback_statuses.push_back(
        capture_status_snapshot(source.rollback_statuses[i])
      );
    collect_recovery_graph(source, snapshot.graph_nodes);
    return snapshot;
  endfunction

  protected function bit restore_recovery_snapshot(
    rdma_rm_recovery_snapshot snapshot
  );
    bit ok;

    if (snapshot == null || snapshot.object_ref == null)
      return 1'b0;
    ok = restore_handle_snapshot(snapshot.resource_h);
    ok = restore_ticket_snapshot(snapshot.ambiguous_ticket) && ok;
    ok = restore_status_snapshot(snapshot.primary_status) && ok;
    snapshot.object_ref.resource_h = snapshot.resource_h.object_ref;
    snapshot.object_ref.hardware_presence = snapshot.hardware_presence;
    snapshot.object_ref.completed_steps = snapshot.completed_steps;
    snapshot.object_ref.pending_steps = snapshot.pending_steps;
    snapshot.object_ref.backing_refs.delete();
    foreach (snapshot.backing_refs[i]) begin
      ok = restore_backing_ref_snapshot(snapshot.backing_refs[i]) && ok;
      snapshot.object_ref.backing_refs.push_back(
        snapshot.backing_refs[i].object_ref
      );
    end
    snapshot.object_ref.hmc_refs.delete();
    foreach (snapshot.hmc_refs[i]) begin
      ok = restore_hmc_ref_snapshot(snapshot.hmc_refs[i]) && ok;
      snapshot.object_ref.hmc_refs.push_back(snapshot.hmc_refs[i].object_ref);
    end
    snapshot.object_ref.ambiguous_ticket =
      snapshot.ambiguous_ticket.object_ref;
    snapshot.object_ref.primary_status = snapshot.primary_status.object_ref;
    snapshot.object_ref.rollback_statuses.delete();
    foreach (snapshot.rollback_statuses[i]) begin
      ok = restore_status_snapshot(snapshot.rollback_statuses[i]) && ok;
      snapshot.object_ref.rollback_statuses.push_back(
        snapshot.rollback_statuses[i].object_ref
      );
    end
    return ok &&
           snapshot.object_ref.get_object_type() == snapshot.object_type;
  endfunction

  protected function bit recovery_snapshot_matches(
    rdma_recovery_record value,
    rdma_rm_recovery_snapshot snapshot
  );
    if (snapshot == null || value != snapshot.object_ref || value == null)
      return 1'b0;
    if (value.get_object_type() != snapshot.object_type ||
        !handle_snapshot_matches(value.resource_h, snapshot.resource_h) ||
        value.hardware_presence != snapshot.hardware_presence ||
        value.completed_steps.size() != snapshot.completed_steps.size() ||
        value.pending_steps.size() != snapshot.pending_steps.size() ||
        value.backing_refs.size() != snapshot.backing_refs.size() ||
        value.hmc_refs.size() != snapshot.hmc_refs.size() ||
        value.rollback_statuses.size() != snapshot.rollback_statuses.size() ||
        !ticket_snapshot_matches(value.ambiguous_ticket,
                                 snapshot.ambiguous_ticket) ||
        !status_snapshot_matches(value.primary_status,
                                 snapshot.primary_status))
      return 1'b0;
    foreach (value.completed_steps[i]) begin
      if (value.completed_steps[i] != snapshot.completed_steps[i])
        return 1'b0;
    end
    foreach (value.pending_steps[i]) begin
      if (value.pending_steps[i] != snapshot.pending_steps[i])
        return 1'b0;
    end
    foreach (value.backing_refs[i]) begin
      if (!backing_ref_snapshot_matches(value.backing_refs[i],
                                        snapshot.backing_refs[i]))
        return 1'b0;
    end
    foreach (value.hmc_refs[i]) begin
      if (!hmc_ref_snapshot_matches(value.hmc_refs[i], snapshot.hmc_refs[i]))
        return 1'b0;
    end
    foreach (value.rollback_statuses[i]) begin
      if (!status_snapshot_matches(value.rollback_statuses[i],
                                   snapshot.rollback_statuses[i]))
        return 1'b0;
    end
    return 1'b1;
  endfunction

  protected function bit recovery_graph_detached_from_nodes(
    rdma_recovery_record result,
    ref uvm_object source_nodes[$]
  );
    uvm_object result_nodes[$];

    if (result == null)
      return 1'b0;
    collect_recovery_graph(result, result_nodes);
    foreach (result_nodes[i]) begin
      foreach (source_nodes[j]) begin
        if (result_nodes[i] == source_nodes[j])
          return 1'b0;
      end
    end
    return 1'b1;
  endfunction

  protected function rdma_status clone_public_recovery_value(
    rdma_recovery_record source,
    string copy_label,
    output rdma_recovery_record result
  );
    uvm_object cloned_object;
    rdma_rm_recovery_snapshot snapshot;
    bit source_mutated;
    bit source_restored;

    result = null;
    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               {copy_label, " recovery record is null"});
    snapshot = capture_recovery_snapshot(source);
    if (snapshot == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery pre-clone snapshot failed"}
      );
    cloned_object = source.clone();
    // Recovery records receive the same caller-restoration guarantee as
    // resource values, including every nested reference and scalar.
    source_mutated = !recovery_snapshot_matches(source, snapshot);
    source_restored = restore_recovery_snapshot(snapshot);
    source_restored = recovery_snapshot_matches(source, snapshot) &&
                      source_restored;
    if (!source_restored) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {copy_label, " recovery source restoration failed"}
      );
    end
    if (source_mutated) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery clone mutated its source"}
      );
    end
    if (cloned_object == null || cloned_object == source ||
        !$cast(result, cloned_object) ||
        result.get_object_type() != snapshot.object_type) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label,
         " recovery clone is not a detached exact-type value"}
      );
    end
    if (!same_recovery_value(result, source)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery clone changed validated fields"}
      );
    end
    if (!recovery_graph_detached_from_nodes(result, snapshot.graph_nodes)) begin
      result = null;
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        {copy_label, " recovery clone retained caller-owned aliases"}
      );
    end
    return rdma_status::success();
  endfunction

  protected function bit recovery_ready(rdma_recovery_record recovery);
    return recovery != null &&
           recovery.hardware_presence == RDMA_HW_PRESENCE_ABSENT &&
           recovery.pending_steps.size() == 0;
  endfunction

  protected function rdma_function_binding clone_binding_value(
    rdma_function_binding source,
    string copy_label
  );
    uvm_object cloned_object;
    rdma_function_binding cloned_binding;

    if (source == null)
      return null;
    cloned_object = source.clone();
    if (cloned_object == null || cloned_object == source ||
        !$cast(cloned_binding, cloned_object) ||
        cloned_binding.get_object_type() != source.get_object_type())
      `uvm_fatal("RM_COPY_TYPE",
                 {copy_label, " Function binding clone mismatch"})
    return cloned_binding;
  endfunction

  protected function bit source_key(
    rdma_function_binding binding,
    output string key
  );
    key = "";
    foreach (generation_sources[candidate_key]) begin
      if (generation_sources[candidate_key] == binding) begin
        key = candidate_key;
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  protected function void refresh_generation(string key);
    int unsigned observed_generation;

    if (!generation_sources.exists(key) ||
        generation_sources[key] == null)
      return;
    observed_generation = generation_sources[key].generation;
    if (generation_high_water.exists(key) &&
        generation_high_water[key] == 32'hffff_ffff &&
        observed_generation == 0)
      generation_exhausted[key] = 1'b1;
    if (!generation_high_water.exists(key) ||
        observed_generation > generation_high_water[key])
      generation_high_water[key] = observed_generation;
  endfunction

  protected function rdma_status binding_context_status(
    rdma_function_binding binding,
    output rdma_function_binding trusted_binding,
    output rdma_function_handle owner,
    output string key,
    output bit registration_needed
  );
    rdma_status status;
    int unsigned observed_generation;
    bit source_is_known;

    trusted_binding = null;
    owner = null;
    key = "";
    registration_needed = 1'b0;
    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "function binding is null");

    source_is_known = source_key(binding, key);
    if (!source_is_known) begin
      key = $sformatf("%016h:%08h", binding.function_uid,
                      binding.global_function_id);
      if (binding_snapshots.exists(key))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "Function generation source is not the registered binding"
        );
    end

    if (!binding_snapshots.exists(key)) begin
      status = binding.validate();
      if (!status.ok())
        return status;
      if (binding.state != RDMA_BIND_ACTIVE)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "function binding is not ACTIVE");
      trusted_binding = clone_binding_value(binding, "new binding");
      observed_generation = binding.generation;
      registration_needed = 1'b1;
    end
    else begin
      trusted_binding = clone_binding_value(binding_snapshots[key],
                                            "trusted binding");
      observed_generation = binding.generation;
      if (!generation_high_water.exists(key))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "Function generation ledger is missing");
      if (generation_exhausted.exists(key))
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function generation counter is permanently exhausted"
        );
      if (observed_generation < generation_high_water[key]) begin
        if (generation_high_water[key] == 32'hffff_ffff &&
            observed_generation == 0) begin
          generation_exhausted[key] = 1'b1;
          return rdma_status::make(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "Function generation wrapped after 32-bit exhaustion"
          );
        end
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "Function generation moved backwards");
      end
      if (observed_generation > generation_high_water[key])
        generation_high_water[key] = observed_generation;
    end

    trusted_binding.generation = observed_generation;
    trusted_binding.owner_h = trusted_binding.make_handle();
    owner = trusted_binding.make_handle();
    if (retired_generations.exists(function_generation_key(owner)))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is retired");
    status = trusted_binding.validate();
    if (!status.ok())
      return status;
    if (trusted_binding.state != RDMA_BIND_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "function binding is not ACTIVE");
    return rdma_status::success();
  endfunction

  protected function void register_binding_context(
    rdma_function_binding source,
    rdma_function_binding trusted_binding,
    rdma_function_handle owner,
    string key
  );
    generation_sources[key] = source;
    binding_snapshots[key] = clone_binding_value(trusted_binding,
                                                 "binding registry");
    generation_high_water[key] = owner.generation;
  endfunction

  protected function rdma_status active_binding_status(
    rdma_function_binding binding,
    output rdma_function_handle owner
  );
    rdma_function_binding trusted_binding;
    string key;
    bit registration_needed;

    return binding_context_status(binding, trusted_binding, owner, key,
                                  registration_needed);
  endfunction

  protected function rdma_status owner_binding_status(
    rdma_function_handle owner
  );
    string key;
    string generation_key;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registry owner is not a Function handle");
    key = function_key(owner);
    if (!binding_snapshots.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function binding is not registered");
    refresh_generation(key);
    generation_key = function_generation_key(owner);
    if (retired_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is retired");
    if (generation_exhausted.exists(key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation counter is exhausted");
    if (!generation_high_water.exists(key) ||
        generation_high_water[key] != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is not current");
    return rdma_status::success();
  endfunction

  protected function bit has_conflicting_generation(
    rdma_function_handle owner
  );
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          registry[key].owner.function_uid == owner.function_uid &&
          registry[key].owner.object_id == owner.object_id &&
          registry[key].owner.kind == owner.kind &&
          registry[key].owner.generation != owner.generation)
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function rdma_status reserve_identity(
    rdma_function_binding binding,
    rdma_resource_kind_e kind,
    output rdma_function_handle owner,
    output rdma_handle handle,
    output int unsigned local_id
  );
    rdma_status status;
    rdma_function_binding trusted_binding;
    int unsigned serial;
    string owner_key;
    bit registration_needed;
    bit has_free_id;

    owner = null;
    handle = null;
    local_id = '0;
    status = binding_context_status(binding, trusted_binding, owner,
                                    owner_key, registration_needed);
    if (!status.ok())
      return status;
    if (!valid_kind(kind) || kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "object resource kind is invalid");

    serial = next_object_serial[kind];
    if (serial == 0)
      serial = 1;
    if (serial > 32'h0fff_ffff)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "resource incarnation serial is exhausted");
    status = local_id_status(kind, has_free_id);
    if (!status.ok())
      return status;

    if (has_conflicting_generation(owner))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    if (registration_needed)
      register_binding_context(binding, trusted_binding, owner, owner_key);

    consume_local_id(kind, has_free_id, local_id);
    next_object_serial[kind] = serial + 1'b1;

    handle = rdma_handle::type_id::create("resource_handle");
    handle.kind = kind;
    handle.function_uid = owner.function_uid;
    handle.object_id = {kind, serial[27:0]};
    handle.generation = owner.generation;
    return rdma_status::success();
  endfunction

  protected function void register_resource(rdma_resource resource);
    string key;

    key = resource_key(resource.handle);
    registry[key] = clone_resource_value(resource, "registry");
    incarnation_owners[incarnation_key(resource.handle)] =
      rdma_clone_function_handle_value(resource.owner,
                                        "resource incarnation owner");
    incarnation_handles[incarnation_key(resource.handle)] =
      rdma_clone_handle_value(resource.handle, "resource incarnation");
    known_generations[function_generation_key(resource.owner)] = 1'b1;
  endfunction

  protected function bit related_incarnation_owner(
    rdma_handle handle,
    output rdma_function_handle owner
  );
    owner = null;
    foreach (incarnation_handles[key]) begin
      if (incarnation_handles[key] == null ||
          !incarnation_owners.exists(key) ||
          incarnation_owners[key] == null)
        continue;
      if (incarnation_handles[key].function_uid == handle.function_uid &&
          incarnation_handles[key].kind == handle.kind &&
          incarnation_handles[key].object_id == handle.object_id) begin
        owner = incarnation_owners[key];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  protected function rdma_status dependency_status(
    rdma_function_handle owner,
    rdma_handle dependency,
    rdma_resource_kind_e expected_kind,
    bit allow_null
  );
    rdma_resource dependency_resource;
    rdma_status status;

    if (dependency == null) begin
      if (allow_null)
        return rdma_status::success();
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "required resource dependency is null");
    end
    if (dependency.kind != expected_kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency kind is invalid");
    status = lookup(dependency, dependency_resource);
    if (!status.ok())
      return status;
    if (dependency_resource.state inside {RDMA_RESOURCE_QUIESCING,
                                          RDMA_RESOURCE_ERROR})
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "closing or failed dependency cannot admit new resources"
      );
    if (dependency_resource.owner == null ||
        !dependency_resource.owner.same_instance(owner))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource dependency has another owner");
    return rdma_status::success();
  endfunction

  protected function int unsigned resource_local_id(rdma_resource resource);
    rdma_pd pd;
    rdma_mr mr;
    rdma_cq cq;
    rdma_qp qp;
    rdma_srq srq;
    rdma_cmq cmq;
    rdma_ceq ceq;
    rdma_aeq aeq;
    rdma_function function_resource;

    case (resource.resource_kind())
      RDMA_RESOURCE_FUNCTION: begin
        if (!$cast(function_resource, resource))
          `uvm_fatal("RM_TYPE", "Function resource type mismatch")
        return function_resource.local_function_id;
      end
      RDMA_RESOURCE_PD: begin
        if (!$cast(pd, resource))
          `uvm_fatal("RM_TYPE", "PD resource type mismatch")
        return pd.local_pd_id;
      end
      RDMA_RESOURCE_MR: begin
        if (!$cast(mr, resource))
          `uvm_fatal("RM_TYPE", "MR resource type mismatch")
        return mr.local_mr_id;
      end
      RDMA_RESOURCE_CQ: begin
        if (!$cast(cq, resource))
          `uvm_fatal("RM_TYPE", "CQ resource type mismatch")
        return cq.local_cq_id;
      end
      RDMA_RESOURCE_QP: begin
        if (!$cast(qp, resource))
          `uvm_fatal("RM_TYPE", "QP resource type mismatch")
        return qp.local_qp_id;
      end
      RDMA_RESOURCE_SRQ: begin
        if (!$cast(srq, resource))
          `uvm_fatal("RM_TYPE", "SRQ resource type mismatch")
        return srq.local_srq_id;
      end
      RDMA_RESOURCE_CMQ: begin
        if (!$cast(cmq, resource))
          `uvm_fatal("RM_TYPE", "CMQ resource type mismatch")
        return cmq.local_cmq_id;
      end
      RDMA_RESOURCE_CEQ: begin
        if (!$cast(ceq, resource))
          `uvm_fatal("RM_TYPE", "CEQ resource type mismatch")
        return ceq.local_ceq_id;
      end
      RDMA_RESOURCE_AEQ: begin
        if (!$cast(aeq, resource))
          `uvm_fatal("RM_TYPE", "AEQ resource type mismatch")
        return aeq.local_aeq_id;
      end
    endcase
    `uvm_fatal("RM_KIND", "resource kind has no local ID pool")
    return '0;
  endfunction

  protected function bit resource_depends_on(
    rdma_resource candidate,
    rdma_handle dependency
  );
    if (candidate == null || dependency == null)
      return 1'b0;
    foreach (candidate.dependencies[i]) begin
      if (candidate.dependencies[i] != null &&
          candidate.dependencies[i].same_instance(dependency))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function bit has_dependents(rdma_resource resource);
    foreach (registry[key]) begin
      if (registry[key] == resource)
        continue;
      if (resource_depends_on(registry[key], resource.handle))
        return 1'b1;
      if (resource.resource_kind() == RDMA_RESOURCE_FUNCTION &&
          registry[key].owner != null &&
          registry[key].owner.same_instance(resource.handle))
        return 1'b1;
    end
    return 1'b0;
  endfunction

  protected function void force_release_key(string key);
    rdma_resource resource;
    rdma_resource_kind_e kind;
    int unsigned local_id;

    resource = registry[key];
    kind = resource.resource_kind();
    local_id = resource_local_id(resource);
    if (local_id > local_id_limit(kind))
      `uvm_fatal("RM_LOCAL_ID",
                 "authoritative local ID exceeds its hardware width")
    foreach (free_local_ids[kind][i]) begin
      if (free_local_ids[kind][i] == local_id)
        `uvm_fatal("RM_LOCAL_ID",
                   "authoritative local ID is already on the free list")
    end
    resource.state = RDMA_RESOURCE_RELEASED;
    recovery_records.delete(key);
    staged_allocations.delete(key);
    free_local_ids[kind].push_back(local_id);
    registry.delete(key);
  endfunction

  function rdma_status create_function(
    rdma_function_binding binding,
    output rdma_function function_resource
  );
    rdma_status status;
    rdma_function authoritative;
    rdma_function_binding trusted_binding;
    rdma_resource published;
    rdma_function_handle owner;
    string key;
    string owner_key;
    int unsigned local_id;
    bit registration_needed;
    bit has_free_id;

    function_resource = null;
    status = binding_context_status(binding, trusted_binding, owner,
                                    owner_key, registration_needed);
    if (!status.ok())
      return status;
    key = resource_key(owner);
    if (registry.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function incarnation already exists");
    if (has_conflicting_generation(owner))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "older Function generation still owns live resources"
      );
    if (incarnation_owners.exists(incarnation_key(owner)))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function incarnation was already released");
    status = local_id_status(RDMA_RESOURCE_FUNCTION, has_free_id);
    if (!status.ok())
      return status;
    if (registration_needed)
      register_binding_context(binding, trusted_binding, owner, owner_key);
    consume_local_id(RDMA_RESOURCE_FUNCTION, has_free_id, local_id);
    authoritative = rdma_function::type_id::create("function_resource");
    authoritative.handle = owner;
    authoritative.owner = rdma_clone_function_handle_value(owner,
                                                             "Function owner");
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_function_id = local_id;
    authoritative.global_function_id = owner.object_id;
    authoritative.rdma_vf_id = trusted_binding.rdma_vf_id;
    authoritative.vsi_id = trusted_binding.vsi_id;
    authoritative.pfvf_id = trusted_binding.pfvf_id;
    authoritative.binding = clone_binding_value(trusted_binding,
                                                  "Function resource");
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create Function");
    if (!$cast(function_resource, published))
      `uvm_fatal("RM_COPY_TYPE", "published Function type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_pd(
    rdma_function_binding binding,
    output rdma_pd pd
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_pd authoritative;
    rdma_resource published;
    int unsigned local_id;

    pd = null;
    status = reserve_identity(binding, RDMA_RESOURCE_PD, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_pd::type_id::create("pd");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_pd_id = local_id;
    authoritative.global_pd_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create PD");
    if (!$cast(pd, published))
      `uvm_fatal("RM_COPY_TYPE", "published PD type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_mr(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_mr mr
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_mr authoritative;
    rdma_resource published;
    int unsigned local_id;

    mr = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_MR, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_mr::type_id::create("mr");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_mr_id = local_id;
    authoritative.global_mr_id = handle.object_id;
    authoritative.pd_h = rdma_clone_handle_value(pd_h, "MR PD");
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(pd_h, "MR dependency")
    );
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create MR");
    if (!$cast(mr, published))
      `uvm_fatal("RM_COPY_TYPE", "published MR type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_cq(
    rdma_function_binding binding,
    rdma_handle ceq_h,
    output rdma_cq cq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_cq authoritative;
    rdma_resource published;
    int unsigned local_id;

    cq = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, ceq_h, RDMA_RESOURCE_CEQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_CQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_cq::type_id::create("cq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cq_id = local_id;
    authoritative.global_cq_id = handle.object_id;
    if (ceq_h != null) begin
      authoritative.ceq_h = rdma_clone_handle_value(ceq_h, "CQ CEQ");
      authoritative.dependencies.push_back(
        rdma_clone_handle_value(ceq_h, "CQ dependency")
      );
    end
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create CQ");
    if (!$cast(cq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_qp(
    rdma_function_binding binding,
    rdma_handle pd_h,
    rdma_handle send_cq_h,
    rdma_handle recv_cq_h,
    rdma_handle srq_h,
    output rdma_qp qp
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_qp authoritative;
    rdma_resource published;
    int unsigned local_id;

    qp = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, send_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, recv_cq_h, RDMA_RESOURCE_CQ, 1'b0);
    if (!status.ok())
      return status;
    status = dependency_status(owner, srq_h, RDMA_RESOURCE_SRQ, 1'b1);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_QP, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_qp::type_id::create("qp");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_qp_id = local_id;
    authoritative.global_qp_id = handle.object_id;
    authoritative.pd_h = rdma_clone_handle_value(pd_h, "QP PD");
    authoritative.send_cq_h = rdma_clone_handle_value(send_cq_h,
                                                       "QP send CQ");
    authoritative.recv_cq_h = rdma_clone_handle_value(recv_cq_h,
                                                       "QP receive CQ");
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(pd_h, "QP PD dependency")
    );
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(send_cq_h, "QP send CQ dependency")
    );
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(recv_cq_h, "QP receive CQ dependency")
    );
    if (srq_h != null) begin
      authoritative.srq_h = rdma_clone_handle_value(srq_h, "QP SRQ");
      authoritative.dependencies.push_back(
        rdma_clone_handle_value(srq_h, "QP SRQ dependency")
      );
    end
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create QP");
    if (!$cast(qp, published))
      `uvm_fatal("RM_COPY_TYPE", "published QP type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_srq(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_srq srq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_srq authoritative;
    rdma_resource published;
    int unsigned local_id;

    srq = null;
    status = active_binding_status(binding, owner);
    if (!status.ok())
      return status;
    status = dependency_status(owner, pd_h, RDMA_RESOURCE_PD, 1'b0);
    if (!status.ok())
      return status;
    status = reserve_identity(binding, RDMA_RESOURCE_SRQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_srq::type_id::create("srq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_srq_id = local_id;
    authoritative.global_srq_id = handle.object_id;
    authoritative.pd_h = rdma_clone_handle_value(pd_h, "SRQ PD");
    authoritative.dependencies.push_back(
      rdma_clone_handle_value(pd_h, "SRQ dependency")
    );
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create SRQ");
    if (!$cast(srq, published))
      `uvm_fatal("RM_COPY_TYPE", "published SRQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_cmq(
    rdma_function_binding binding,
    output rdma_cmq cmq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_cmq authoritative;
    rdma_resource published;
    int unsigned local_id;

    cmq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_CMQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_cmq::type_id::create("cmq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_cmq_id = local_id;
    authoritative.global_cmq_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create CMQ");
    if (!$cast(cmq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CMQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_ceq(
    rdma_function_binding binding,
    output rdma_ceq ceq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_ceq authoritative;
    rdma_resource published;
    int unsigned local_id;

    ceq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_CEQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_ceq::type_id::create("ceq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_ceq_id = local_id;
    authoritative.global_ceq_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create CEQ");
    if (!$cast(ceq, published))
      `uvm_fatal("RM_COPY_TYPE", "published CEQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status create_aeq(
    rdma_function_binding binding,
    output rdma_aeq aeq
  );
    rdma_status status;
    rdma_function_handle owner;
    rdma_handle handle;
    rdma_aeq authoritative;
    rdma_resource published;
    int unsigned local_id;

    aeq = null;
    status = reserve_identity(binding, RDMA_RESOURCE_AEQ, owner, handle,
                              local_id);
    if (!status.ok())
      return status;
    authoritative = rdma_aeq::type_id::create("aeq");
    authoritative.handle = handle;
    authoritative.owner = owner;
    authoritative.state = RDMA_RESOURCE_ALLOCATED;
    authoritative.local_aeq_id = local_id;
    authoritative.global_aeq_id = handle.object_id;
    register_resource(authoritative);
    published = clone_resource_value(authoritative, "create AEQ");
    if (!$cast(aeq, published))
      `uvm_fatal("RM_COPY_TYPE", "published AEQ type mismatch")
    return rdma_status::success();
  endfunction

  function rdma_status lookup(
    rdma_handle handle,
    output rdma_resource resource
  );
    string key;
    string incarnation;
    rdma_resource authoritative;
    rdma_function_handle owner;
    rdma_status status;

    resource = null;
    if (handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is null");
    if (!valid_kind(handle.kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle kind is invalid");
    if (handle.kind != RDMA_RESOURCE_FUNCTION &&
        handle.object_id[31:28] != handle.kind)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource incarnation kind prefix is invalid");

    key = resource_key(handle);
    if (registry.exists(key)) begin
      authoritative = registry[key];
      if (authoritative == null || authoritative.handle == null ||
          !authoritative.handle.same_instance(handle))
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "registry identity is inconsistent");
      status = owner_binding_status(authoritative.owner);
      if (!status.ok())
        return status;
      resource = clone_resource_value(authoritative, "lookup");
      return rdma_status::success();
    end

    incarnation = incarnation_key(handle);
    if (!incarnation_owners.exists(incarnation)) begin
      if (related_incarnation_owner(handle, owner))
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "resource handle generation is stale");
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "resource handle is unknown or forged");
    end
    owner = incarnation_owners[incarnation];
    status = owner_binding_status(owner);
    if (status.code == RDMA_SC_STALE_GENERATION)
      return status;
    if (!status.ok())
      return status;
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "resource handle has been released");
  endfunction

  virtual function rdma_status stage_allocated(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource prepared;
    rdma_resource replacement;
    rdma_status status;
    string key;

    if (candidate == null || candidate.handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "staged resource candidate is null");
    if (candidate.state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "staged candidate must be ALLOCATED");
    status = lookup(candidate.handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(candidate.handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "registry resource is not ALLOCATED");
    status = publication_identity_status(candidate, authoritative);
    if (!status.ok())
      return status;
    status = clone_public_resource_value(candidate, "stage allocated",
                                         replacement);
    if (!status.ok())
      return status;
    if (replacement.resource_kind() != RDMA_RESOURCE_PD) begin
      status = clone_public_resource_value(replacement, "stage prepared",
                                           prepared);
      if (!status.ok())
        return status;
      prepared.state = RDMA_RESOURCE_PROGRAMMED;
      status = prepared.validate();
      if (status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "prepared staged candidate validation returned null"
        );
      if (!status.ok())
        return status;
    end
    replacement.state = RDMA_RESOURCE_ALLOCATED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "staged candidate validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    staged_allocations[key] = 1'b1;
    return rdma_status::success();
  endfunction

  virtual function rdma_status commit_programmed(rdma_resource candidate);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    if (candidate == null || candidate.handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "programmed resource candidate is null");
    if (candidate.state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "programmed candidate must be ALLOCATED");
    status = lookup(candidate.handle, authoritative);
    if (!status.ok())
      return status;
    if (authoritative.resource_kind() == RDMA_RESOURCE_PD)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "PD transitions directly from ALLOCATED to ACTIVE"
      );
    key = resource_key(candidate.handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED ||
        !staged_allocations.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only a staged ALLOCATED resource can be programmed"
      );
    status = publication_identity_status(candidate, authoritative);
    if (!status.ok())
      return status;
    status = clone_public_resource_value(candidate, "commit programmed",
                                         replacement);
    if (!status.ok())
      return status;
    replacement.state = RDMA_RESOURCE_PROGRAMMED;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "programmed candidate validation returned null"
      );
    if (!status.ok())
      return status;
    registry[key] = replacement;
    staged_allocations.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status activate(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (handle.kind == RDMA_RESOURCE_PD) begin
      if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "PD activation requires ALLOCATED state"
        );
    end
    else if (registry[key].state != RDMA_RESOURCE_PROGRAMMED) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "non-PD activation requires PROGRAMMED state"
      );
    end
    replacement = clone_resource_value(registry[key], "activate");
    replacement.state = RDMA_RESOURCE_ACTIVE;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "active resource validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    staged_allocations.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status begin_quiesce(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (registry[key].state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only ACTIVE resource can begin quiesce");
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    registry[key].state = RDMA_RESOURCE_QUIESCING;
    return rdma_status::success();
  endfunction

  virtual function rdma_status restore_active(rdma_handle handle);
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (registry[key].state != RDMA_RESOURCE_QUIESCING)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only QUIESCING resource can be restored ACTIVE"
      );
    replacement = clone_resource_value(registry[key], "restore active");
    replacement.state = RDMA_RESOURCE_ACTIVE;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "restored resource validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  virtual function rdma_status mark_error(
    rdma_handle handle,
    rdma_recovery_record recovery
  );
    rdma_resource replacement;
    rdma_recovery_record recovery_copy;
    rdma_function_handle related_owner;
    rdma_status status;
    string key;

    if (handle == null || recovery == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error handle or recovery record is null");
    if (!valid_kind(handle.kind) ||
        (handle.kind != RDMA_RESOURCE_FUNCTION &&
         handle.object_id[31:28] != handle.kind))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource handle is malformed");
    key = resource_key(handle);
    if (!registry.exists(key)) begin
      if (related_incarnation_owner(handle, related_owner))
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "error resource generation is stale");
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "error resource incarnation is unknown");
    end
    if (registry[key] == null || registry[key].handle == null ||
        !registry[key].handle.same_instance(handle))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "error registry identity is inconsistent");
    status = clone_public_recovery_value(recovery, "mark error",
                                         recovery_copy);
    if (!status.ok())
      return status;
    if (recovery_copy.resource_h == null ||
        !recovery_copy.resource_h.same_instance(handle))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "recovery record does not match the resource incarnation"
      );
    status = recovery_copy.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "recovery validation returned null");
    if (!status.ok())
      return status;
    if (registry[key].resource_kind() == RDMA_RESOURCE_MR &&
        registry[key].state == RDMA_RESOURCE_ALLOCATED &&
        !staged_allocations.exists(key))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "ALLOCATED MR requires staged key authority before ERROR"
      );
    replacement = clone_resource_value(registry[key], "mark error");
    replacement.state = RDMA_RESOURCE_ERROR;
    status = replacement.validate();
    if (status == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ERROR resource validation returned null");
    if (!status.ok())
      return status;
    registry[key] = replacement;
    recovery_records[key] = recovery_copy;
    staged_allocations.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status lookup_recovery(
    rdma_handle handle,
    output rdma_recovery_record recovery
  );
    rdma_resource authoritative;
    rdma_status status;
    string key;

    recovery = null;
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (!recovery_records.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource has no recovery record");
    recovery = clone_recovery_value(recovery_records[key],
                                    "lookup recovery");
    return rdma_status::success();
  endfunction

  virtual function rdma_status clear_recovery(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (registry[key].state != RDMA_RESOURCE_ERROR)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "only ERROR resource recovery can be cleared");
    if (!recovery_records.exists(key))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource has no recovery record");
    if (!recovery_ready(recovery_records[key]))
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "recovery cannot be cleared before hardware absence is proven"
      );
    recovery_records.delete(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status finalize_release(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    if (handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    key = resource_key(handle);
    if (registry[key].state == RDMA_RESOURCE_ERROR) begin
      if (!recovery_records.exists(key) ||
          !recovery_ready(recovery_records[key]))
        return rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "ERROR resource still requires recovery"
        );
    end
    else if (registry[key].state != RDMA_RESOURCE_QUIESCING) begin
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only QUIESCING or recovered ERROR resource can be finalized"
      );
    end
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    force_release_key(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status release_reserved(rdma_handle handle);
    rdma_resource authoritative;
    rdma_status status;
    string key;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    if (handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    key = resource_key(handle);
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only an ALLOCATED reservation can be rolled back"
      );
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "resource still has live dependents");
    if (registry[key].outstanding_ids.size() != 0)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "resource still has outstanding operations"
      );
    force_release_key(key);
    return rdma_status::success();
  endfunction

  virtual function rdma_status track_outstanding(
    rdma_handle handle,
    longint unsigned outstanding_id
  );
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;

    if (outstanding_id == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "outstanding operation ID is zero");
    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    if (registry[key].state != RDMA_RESOURCE_ACTIVE)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "only ACTIVE resources accept outstanding operations"
      );
    foreach (registry[key].outstanding_ids[i]) begin
      if (registry[key].outstanding_ids[i] == outstanding_id)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "outstanding operation ID is already tracked"
        );
    end
    replacement = clone_resource_value(registry[key], "track outstanding");
    replacement.outstanding_ids.push_back(outstanding_id);
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  virtual function rdma_status retire_outstanding(
    rdma_handle handle,
    longint unsigned outstanding_id
  );
    rdma_resource authoritative;
    rdma_resource replacement;
    rdma_status status;
    string key;
    int found_index;

    status = lookup(handle, authoritative);
    if (!status.ok())
      return status;
    key = resource_key(handle);
    found_index = -1;
    foreach (registry[key].outstanding_ids[i]) begin
      if (registry[key].outstanding_ids[i] == outstanding_id) begin
        found_index = i;
        break;
      end
    end
    if (found_index < 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "outstanding operation ID is not tracked"
      );
    replacement = clone_resource_value(registry[key], "retire outstanding");
    replacement.outstanding_ids.delete(found_index);
    registry[key] = replacement;
    return rdma_status::success();
  endfunction

  function rdma_status freeze(rdma_handle handle);
    rdma_resource candidate;
    rdma_status status;

    status = lookup(handle, candidate);
    if (!status.ok())
      return status;
    return commit_programmed(candidate);
  endfunction

  function rdma_status \release (rdma_handle handle);
    rdma_resource ignored;
    rdma_status status;
    string key;

    status = lookup(handle, ignored);
    if (!status.ok())
      return status;
    if (handle.kind == RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function resources require privileged Function teardown"
      );
    key = resource_key(handle);
    if (registry[key].state == RDMA_RESOURCE_ERROR)
      return rdma_status::make(
        RDMA_SC_RECOVERY_REQUIRED,
        "ERROR resource requires recovery finalization"
      );
    if (registry[key].state != RDMA_RESOURCE_ALLOCATED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "frozen resource requires Function teardown");
    if (has_dependents(registry[key]))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "resource still has live dependents");
    force_release_key(key);
    return rdma_status::success();
  endfunction

  function rdma_status release_function(rdma_function_handle owner);
    bit selected[string];
    string release_order[$];
    string owner_key;
    string generation_key;
    int unsigned target_count;
    bit progress;
    bit blocked;

    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function teardown handle is invalid");
    owner_key = function_key(owner);
    generation_key = function_generation_key(owner);
    if (!binding_snapshots.exists(owner_key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function teardown identity is unknown");
    refresh_generation(owner_key);
    if (retired_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function generation is already retired");
    if (!known_generations.exists(generation_key))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function generation was never registered");

    target_count = 0;
    foreach (registry[key]) begin
      if (registry[key].owner != null &&
          registry[key].owner.same_instance(owner))
        target_count++;
    end

    while (release_order.size() < target_count) begin
      progress = 1'b0;
      foreach (registry[key]) begin
        if (selected.exists(key) || registry[key].owner == null ||
            !registry[key].owner.same_instance(owner))
          continue;
        blocked = 1'b0;
        foreach (registry[other_key]) begin
          if (key == other_key || selected.exists(other_key) ||
              registry[other_key].owner == null ||
              !registry[other_key].owner.same_instance(owner))
            continue;
          if (resource_depends_on(registry[other_key],
                                  registry[key].handle))
            blocked = 1'b1;
          if (registry[key].resource_kind() == RDMA_RESOURCE_FUNCTION &&
              registry[other_key].resource_kind() !=
                RDMA_RESOURCE_FUNCTION)
            blocked = 1'b1;
        end
        if (!blocked) begin
          selected[key] = 1'b1;
          release_order.push_back(key);
          progress = 1'b1;
        end
      end
      if (!progress)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "resource dependency graph has a cycle");
    end

    foreach (release_order[i])
      force_release_key(release_order[i]);
    retired_generations[generation_key] = 1'b1;
    return rdma_status::success();
  endfunction

  function rdma_status check_leaks(
    output int unsigned leak_count,
    input rdma_function_handle owner = null
  );
    leak_count = 0;
    if (owner != null && owner.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "leak filter is not a Function handle");
    foreach (registry[key]) begin
      if (owner == null ||
          (registry[key].owner != null &&
           registry[key].owner.same_instance(owner)))
        leak_count++;
    end
    if (leak_count != 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               $sformatf("%0d RDMA resources leaked",
                                         leak_count));
    return rdma_status::success();
  endfunction
endclass
