// 目录：src/integration/，位于 dpu_common 冻结快照和 RDMA 类型之间的适配层。
// 职责：只读投影 Host/PF/VF、BDF、global Function ID、BAR、DMA domain 和能力，
//       生成 RDMA identity/binding；不修改 dpu_common，也不伪造缺失硬件资源。
// 依赖：dpu_common device/resource snapshot、rdma_function_identity/binding 类型。
// 所有权与生命周期：输入快照由 dpu_common 环境拥有；返回 identity/binding 由调用方
//       拥有并可在本环境生命周期内保存，适配器本身不持有底层资源。
class rdma_dpu_identity_adapter extends uvm_object;
  `uvm_object_utils(rdma_dpu_identity_adapter)

  // 功能：构造无状态适配器对象；所有实际工作由以下两个静态投影函数完成。
  function new(string name = "rdma_dpu_identity_adapter");
    super.new(name);
  endfunction

  // 仅投影身份时使用的轻量入口。Device env 在建立 reset ledger 时不应
  // 要求每个 Function 都已经分配 RDMA BAR；真正创建 binding 时仍使用
  // from_snapshot()，由该入口之外的资源投影路径执行完整校验。
  // 功能：从冻结 device snapshot 读取一个 PF/VF 的 PCIe ID 和 global Function ID，
  //       生成可供 reset/route ledger 使用的 RDMA identity。
  // 输入/输出：key 指定 dpu_common Function，identity 返回新克隆；函数不修改 snapshot。
  // 边界：快照未冻结、key 不存在、VF parent 域不一致或 identity 配置失败时返回错误。
  static function rdma_status identity_from_snapshot(
    dpu_device_snapshot snapshot,
    input dpu_function_key_t key,
    output rdma_function_identity identity
  );
    dpu_pcie_function_id_t pcie_id, parent_pcie_id;
    dpu_function_key_t funcs[$];
    rdma_function_key_t rkey;
    int unsigned gid;
    longint unsigned uid;
    rdma_status status;
    string why;
    bit parent_found;

    identity = null;
    if (snapshot == null || !snapshot.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DPU device snapshot must be frozen");
    if (!snapshot.get_pcie_id(key, pcie_id, why))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
    if (!snapshot.get_global_function_id(key, gid, why))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);

    rkey.root_id = pcie_id.domain.segment_id;
    rkey.host_topology_key = pcie_id.domain.host_id;
    rkey.function_kind = (key.kind == DPU_FUNCTION_VF) ?
                         RDMA_FUNCTION_VF : RDMA_FUNCTION_PF;
    rkey.vf_index = key.vf_id;
    rkey.bdf.segment = pcie_id.domain.segment_id;
    rkey.bdf.bus = pcie_id.bdf[15:8];
    rkey.bdf.device = pcie_id.bdf[7:3];
    rkey.bdf.function_num = pcie_id.bdf[2:0];
    rkey.parent_pf_bdf = '0;
    parent_found = 1'b0;
    if (key.kind == DPU_FUNCTION_VF) begin
      snapshot.list_functions(funcs);
      foreach (funcs[i]) begin
        if (funcs[i].host_id == key.host_id &&
            funcs[i].pf_id == key.pf_id &&
            funcs[i].kind == DPU_FUNCTION_PF) begin
          if (!snapshot.get_pcie_id(funcs[i], parent_pcie_id, why))
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
          if (parent_pcie_id.domain.host_id != pcie_id.domain.host_id ||
              parent_pcie_id.domain.segment_id != pcie_id.domain.segment_id)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "VF parent domain mismatch");
          rkey.parent_pf_bdf.segment = parent_pcie_id.domain.segment_id;
          rkey.parent_pf_bdf.bus = parent_pcie_id.bdf[15:8];
          rkey.parent_pf_bdf.device = parent_pcie_id.bdf[7:3];
          rkey.parent_pf_bdf.function_num = parent_pcie_id.bdf[2:0];
          parent_found = 1'b1;
          break;
        end
      end
    end
    if ((key.kind == DPU_FUNCTION_VF) && !parent_found)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF parent PF not found");

    // UID 由完整 route 形成；global ID 只作为理论上全零 route 的兜底，
    // 避免把两个 Host/segment 的同一 BDF 误合并为同一个 Function。
    uid = (longint'(rkey.host_topology_key) << 32) |
          (longint'(rkey.root_id) << 16) | longint'(rkey.bdf);
    if (uid == 0)
      uid = longint'(gid) + 1;
    identity = rdma_function_identity::type_id::create("dpu_identity");
    status = identity.configure(rkey, gid, uid, 1, 0);
    if (!status.ok()) begin
      identity = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：从冻结 device/resource snapshot 完整投影 Function identity 与 PCIe binding，
  //       包括真实 BAR、mailbox notify aperture、MSI-X、DMA segment 和队列能力上限。
  // 输入/输出：snapshot/resources 必须相互引用一致；identity、binding 返回由调用方拥有的对象。
  // 边界：缺失/重复/零长度 BAR、能力为零、VF parent 域不一致或最终 binding 校验失败时拒绝。
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
    dpu_bar_pair_lease_t device_bar;
    dpu_bar_pair_lease_t mailbox_bar;
    dpu_bar_pair_lease_t msix_bar;
    dpu_dut_caps caps;
    int unsigned gid;
    string why;
    rdma_function_key_t rkey;
    longint unsigned uid;
    rdma_status status;
    bit parent_found;

    identity = null; binding = null;
    if (snapshot == null || resources == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "DPU snapshots are null");
    if (!snapshot.is_frozen() || !resources.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE, "DPU snapshots must be frozen");
    if (!resources.references_device_snapshot(snapshot))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "DPU resource/device snapshots are incoherent");
    if (!snapshot.get_pcie_id(key, pcie_id, why))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
    if (!snapshot.get_global_function_id(key, gid, why))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, why);
    // BAR 是 dpu_common 的唯一物理地址权威。RDMA 只复制冻结值，不能
    // 用默认地址或固定长度“补”出一个看似可用的 PCIe aperture。
    if (!snapshot.get_bar(key, DPU_BAR_DEVICE_MEMORY, device_bar, why))
      return rdma_status::make(RDMA_SC_INVALID_STATE, why);
    if (!snapshot.get_bar(key, DPU_BAR_MAILBOX, mailbox_bar, why))
      return rdma_status::make(RDMA_SC_INVALID_STATE, why);
    if (!snapshot.get_bar(key, DPU_BAR_MSIX, msix_bar, why))
      return rdma_status::make(RDMA_SC_INVALID_STATE, why);
    if (device_bar.even_bar_id >= 6 || mailbox_bar.even_bar_id >= 6 ||
        msix_bar.even_bar_id >= 6)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "snapshot BAR index is outside BAR[0:5]");
    if (device_bar.size == 0 || mailbox_bar.size == 0 || msix_bar.size == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "snapshot BAR size is zero");
    if (device_bar.even_bar_id == mailbox_bar.even_bar_id ||
        device_bar.even_bar_id == msix_bar.even_bar_id ||
        mailbox_bar.even_bar_id == msix_bar.even_bar_id)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "snapshot BAR roles share an even BAR index");

    rkey.root_id = pcie_id.domain.segment_id;
    rkey.host_topology_key = pcie_id.domain.host_id;
    rkey.function_kind = (key.kind == DPU_FUNCTION_VF) ? RDMA_FUNCTION_VF : RDMA_FUNCTION_PF;
    rkey.vf_index = key.vf_id;
    rkey.bdf.segment = pcie_id.domain.segment_id;
    rkey.bdf.bus = pcie_id.bdf[15:8];
    rkey.bdf.device = pcie_id.bdf[7:3];
    rkey.bdf.function_num = pcie_id.bdf[2:0];
    rkey.parent_pf_bdf = '0;
    parent_found = 1'b0;
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
          if (parent_pcie_id.domain.host_id != pcie_id.domain.host_id ||
              parent_pcie_id.domain.segment_id != pcie_id.domain.segment_id)
            return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "VF parent domain mismatch");
          parent_found = 1'b1;
          break;
        end
      end
    end
    if (key.kind == DPU_FUNCTION_VF && !parent_found)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "VF parent PF not found");
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
    binding.queue_dma.requester_bdf = rkey.bdf;
    binding.queue_dma.dma_domain_valid = 1'b1;
    // dpu_common 的 domain key 由 Host+segment 定义；RDMA 的 DMA domain
    // 使用 segment，Host 隔离由 route.host_topology_key 同时承担。
    binding.queue_dma.dma_domain_id = pcie_id.domain.segment_id;
    caps = snapshot.snapshot_dut_caps();
    if (caps == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "snapshot DUT capabilities are unavailable");
    if ((caps.max_vio_net_qpairs_per_device == 0) ||
        (caps.global_msix_vector_count == 0))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "snapshot queue capability is zero");
    // dpu_common 当前没有 RDMA 专用 CQ/SRQ 字段，因此采用其设备级 VIO
    // qpair/MSI-X 上限作为保守上界；ring/SGB 上限直接受实际 device BAR
    // aperture 约束，后续专用 RDMA capability 可在此处替换而不改路由。
    binding.queue_caps.min_cq_depth = 1;
    binding.queue_caps.max_cq_depth = caps.max_vio_net_qpairs_per_device;
    binding.queue_caps.min_srq_depth = 1;
    binding.queue_caps.max_srq_depth = caps.max_vio_net_qpairs_per_device;
    binding.queue_caps.max_ceq_depth = caps.global_msix_vector_count;
    binding.queue_caps.max_aeq_depth = caps.global_msix_vector_count;
    binding.queue_caps.max_wq_sge = 1;
    binding.queue_caps.max_queue_ring_bytes = device_bar.size;
    binding.queue_caps.max_sgb_bytes = device_bar.size;

    binding.pcie.bar[device_bar.even_bar_id].base.value = device_bar.base;
    binding.pcie.bar[device_bar.even_bar_id].size = device_bar.size;
    binding.pcie.bar[device_bar.even_bar_id].enabled = 1'b1;
    binding.pcie.bar[mailbox_bar.even_bar_id].base.value = mailbox_bar.base;
    binding.pcie.bar[mailbox_bar.even_bar_id].size = mailbox_bar.size;
    binding.pcie.bar[mailbox_bar.even_bar_id].enabled = 1'b1;
    binding.pcie.bar[msix_bar.even_bar_id].base.value = msix_bar.base;
    binding.pcie.bar[msix_bar.even_bar_id].size = msix_bar.size;
    binding.pcie.bar[msix_bar.even_bar_id].enabled = 1'b1;
    binding.notify_bar_id = mailbox_bar.even_bar_id;
    binding.notify_base.value = mailbox_bar.base;
    binding.notify_size = mailbox_bar.size;
    status = binding.validate();
    if (!status.ok()) begin identity = null; binding = null; return status; end
    return rdma_status::success();
  endfunction
endclass
