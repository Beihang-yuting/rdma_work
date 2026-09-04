// 中文说明：将冻结的 dpu_common 身份快照转换为 RDMA 的不可变身份与 binding。
// 创建者：rdma_device_env；所有权：返回对象由调用方持有；生命周期：随调用方结束。
class rdma_dpu_identity_adapter extends uvm_object;
  `uvm_object_utils(rdma_dpu_identity_adapter)

  function new(string name = "rdma_dpu_identity_adapter"); super.new(name); endfunction

  static function rdma_status from_snapshot(
    dpu_device_snapshot snapshot,
    dpu_resource_snapshot resources,
    input dpu_function_key_t key,
    output rdma_function_identity identity,
    output rdma_function_binding binding
  );
    dpu_pcie_function_id_t pcie_id, parent_pcie_id;
    dpu_function_key_t funcs[$];
    dpu_function_key_t parent;
    int unsigned gid;
    string why;
    rdma_function_key_t rkey;
    longint unsigned uid;
    rdma_status status;

    identity = null; binding = null;
    if (snapshot == null || resources == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DPU snapshots are null");
    if (!snapshot.is_frozen() || !resources.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE, "DPU snapshots must be frozen");
    if (!snapshot.get_pcie_id(key, pcie_id, why))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
    if (!snapshot.get_global_function_id(key, gid, why))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);

    rkey.root_id = pcie_id.domain.segment_id;
    rkey.host_topology_key = pcie_id.domain.host_id;
    rkey.function_kind = (key.kind == DPU_FUNCTION_VF) ? RDMA_FUNCTION_VF : RDMA_FUNCTION_PF;
    rkey.vf_index = key.vf_id;
    rkey.bdf.segment = pcie_id.domain.segment_id;
    rkey.bdf.bus = pcie_id.bdf[15:8];
    rkey.bdf.device = pcie_id.bdf[7:3];
    rkey.bdf.function_num = pcie_id.bdf[2:0];
    rkey.parent_pf_bdf = '0;
    if (key.kind == DPU_FUNCTION_VF) begin
      snapshot.list_functions(funcs);
      foreach (funcs[i]) begin
        if (funcs[i].host_id == key.host_id && funcs[i].pf_id == key.pf_id &&
            funcs[i].kind == DPU_FUNCTION_PF) begin
          if (!snapshot.get_pcie_id(funcs[i], parent_pcie_id, why))
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
          rkey.parent_pf_bdf.segment = parent_pcie_id.domain.segment_id;
          rkey.parent_pf_bdf.bus = parent_pcie_id.bdf[15:8];
          rkey.parent_pf_bdf.device = parent_pcie_id.bdf[7:3];
          rkey.parent_pf_bdf.function_num = parent_pcie_id.bdf[2:0];
          break;
        end
      end
    end
    uid = (longint'(rkey.host_topology_key) << 32) |
          (longint'(rkey.root_id) << 16) | longint'(rkey.bdf);
    if (uid == 0) uid = longint'(gid) + 1;
    identity = rdma_function_identity::type_id::create("dpu_identity");
    status = identity.configure(rkey, gid, uid, 1, 0);
    if (!status.ok()) begin identity = null; return status; end
    binding = rdma_function_binding::type_id::create("dpu_binding");
    status = binding.configure_identity(identity);
    if (!status.ok()) begin identity = null; binding = null; return status; end
    binding.pcie.bdf = rkey.bdf;
    binding.pcie.parent_pf_bdf = rkey.parent_pf_bdf;
    binding.pcie.vf_index = rkey.vf_index;
    binding.host_id = rkey.host_topology_key;
    binding.pfvf_id = gid;
    return rdma_status::success();
  endfunction
endclass
