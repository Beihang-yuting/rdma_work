// 目录：src/integration/，位于 dpu_common 适配层的设备级组合入口。
// 职责：校验冻结的 dpu_common 设备/资源快照，枚举全部 PF/VF，并为每个
//       Function 建立 RDMA identity 与统一 reset coordinator 注册表。
// 依赖：rdma_dpu_identity_adapter、rdma_host_mem_router、rdma_pcie_router，
//       以及 dpu_common 的 dpu_device_snapshot/resource_snapshot。
// 所有权与生命周期：外部快照和 router 由调用方拥有；本对象保存非拥有快照引用，
//       identity ledger 由本对象创建并在环境生命周期内持有，get_identity() 返回副本。

// 复位范围只在 device env 内部使用，避免把 dpu_common 的 reset 枚举和 RDMA
// context 状态耦合；coordinator 仍是 epoch 数值的唯一发布者。
typedef enum bit [1:0] {
  RDMA_ENV_RESET_VF = 2'd0,
  RDMA_ENV_RESET_PF = 2'd1,
  RDMA_ENV_RESET_HOST = 2'd2,
  RDMA_ENV_RESET_DEVICE = 2'd3
} rdma_device_reset_scope_e;

// 设计说明：reset candidate 会经过可由 UVM factory 替换的 prepare/validate
// virtual seam；如果把 candidate 句柄直接保存到下一阶段，后一个 context 可以在
// 前一个 candidate 已验证后重新改写它。该 fingerprint 由 device env 独占，保存
// prepare 返回时的预期 incarnation、binding route/owner 镜像和 source 哨兵；它不
// 暴露给 context subclass，也不参与 epoch 后的分配路径。所有 compare 都是本类
// non-virtual、无回调的值检查，因而能在唯一 epoch side effect 前捕获跨 candidate 漂移。
class rdma_reset_candidate_fingerprint extends uvm_object;
  `uvm_object_utils(rdma_reset_candidate_fingerprint)

  rdma_function_identity expected_identity;
  rdma_function_identity expected_binding_identity;
  rdma_function_identity expected_source_identity;
  rdma_function_identity expected_source_identity_value;
  rdma_function_binding expected_source_binding;
  rdma_function_binding expected_source_binding_value;
  rdma_function_identity expected_candidate_identity_ref;
  rdma_function_binding expected_candidate_binding_ref;
  rdma_function_identity expected_candidate_binding_snapshot_ref;
  rdma_pcie_identity expected_candidate_pcie_ref;
  rdma_handle expected_candidate_owner_ref;
  rdma_function_binding expected_binding_value;
  rdma_function_context_state_e expected_source_state;
  uvm_object_wrapper expected_binding_type;
  bit expected_pcie_present;
  rdma_bdf_t expected_pcie_bdf;
  rdma_bdf_t expected_parent_pf_bdf;
  int unsigned expected_vf_index;
  bit expected_pcie_mse;
  bit expected_pcie_bme;
  longint unsigned expected_binding_uid;
  int unsigned expected_binding_global_id;
  int unsigned expected_binding_generation;
  rdma_binding_state_e expected_binding_state;
  bit expected_owner_present;
  uvm_object_wrapper expected_owner_type;
  rdma_resource_kind_e expected_owner_kind;
  longint unsigned expected_owner_uid;
  int unsigned expected_owner_object_id;
  int unsigned expected_owner_generation;
  bit captured;

  // 功能：构造空的 candidate fingerprint，所有 authority/owner 字段均置为未捕获状态。
  // 输入/输出及副作用：name（输入）；new 初始化 UVM 名称、空 identity/source 引用和
  //   标志字段，不修改 candidate、context 或 coordinator，也不取得外部资源所有权。
  // 失败/边界：新对象不能直接用于 verify；必须先由 capture() 在 epoch 发布前完成
  //   一次完整捕获，捕获失败时调用方应丢弃本对象并恢复 quiesce。
  function new(string name = "rdma_reset_candidate_fingerprint");
    super.new(name);
    expected_identity = null;
    expected_binding_identity = null;
    expected_source_identity = null;
    expected_source_identity_value = null;
    expected_source_binding = null;
    expected_source_binding_value = null;
    expected_candidate_identity_ref = null;
    expected_candidate_binding_ref = null;
    expected_candidate_binding_snapshot_ref = null;
    expected_candidate_pcie_ref = null;
    expected_candidate_owner_ref = null;
    expected_binding_value = null;
    expected_source_state = RDMA_CONTEXT_DISCOVERED;
    expected_binding_type = null;
    expected_pcie_present = 1'b0;
    expected_pcie_bdf = '0;
    expected_parent_pf_bdf = '0;
    expected_vf_index = '0;
    expected_pcie_mse = 1'b0;
    expected_pcie_bme = 1'b0;
    expected_binding_uid = 0;
    expected_binding_global_id = 0;
    expected_binding_generation = 0;
    expected_binding_state = RDMA_BIND_DISCOVERED;
    expected_owner_present = 1'b0;
    expected_owner_type = null;
    expected_owner_kind = RDMA_RESOURCE_FUNCTION;
    expected_owner_uid = 0;
    expected_owner_object_id = 0;
    expected_owner_generation = 0;
    captured = 1'b0;
  endfunction

  // 功能：把 identity 的五组值字段复制到 env-owned detached snapshot，避免 seal 与
  //       candidate 的可变句柄共享对象。
  // 输入/输出及副作用：source（输入）、name（输入）；返回新建 identity 值快照，不修改
  //   source 或任何外部 ledger；该函数只使用直接构造和字段赋值，不调用 factory clone。
  // 失败/边界：source 为 null 时返回 null；返回值只代表字段复制成功，不替代调用方对
  //   route、UID、generation 和 reset_epoch 的业务校验。
  protected static function rdma_function_identity copy_identity_value(
    rdma_function_identity source,
    string name
  );
    rdma_function_identity copy;

    if (source == null)
      return null;
    copy = new(name);
    copy.key = source.key;
    copy.global_function_id = source.global_function_id;
    copy.function_uid = source.function_uid;
    copy.generation = source.generation;
    copy.reset_epoch = source.reset_epoch;
    return copy;
  endfunction

  // 功能：逐字段比较 reset candidate 的完整 binding 公开值图，覆盖 PCIe/BAR、notify、
  //       queue DMA/能力、interrupt vector、owner、生命周期和 readiness 字段。
  // 输入/输出及副作用：expected（输入）是 capture() 期间构造的 detached binding；actual
  //   （输入）是 virtual callback 后仍待提交的 candidate binding；identity（输入）是预期
  //   binding incarnation。函数只读对象并返回 bit，不调用 validate、clone、factory 或外部 router。
  // 失败/边界：任一对象/嵌套值缺失、identity 镜像不一致、BAR/vector 顺序或任意公开字段漂移
  //   返回 0；该比较不替代 capture 阶段对 source graph 的完整性检查。
  protected static function bit binding_value_matches(
    rdma_function_binding expected,
    rdma_function_binding actual,
    rdma_function_identity identity
  );
    if (expected == null || actual == null || identity == null ||
        expected.pcie == null || actual.pcie == null ||
        !expected.matches_identity_snapshot(identity) ||
        !actual.matches_identity_snapshot(identity))
      return 1'b0;
    if (expected.function_uid != actual.function_uid ||
        expected.pcie.bdf != actual.pcie.bdf ||
        expected.pcie.parent_pf_bdf != actual.pcie.parent_pf_bdf ||
        expected.pcie.vf_index != actual.pcie.vf_index ||
        expected.pcie.mse != actual.pcie.mse ||
        expected.pcie.bme != actual.pcie.bme ||
        expected.notify_bar_id != actual.notify_bar_id ||
        expected.notify_base != actual.notify_base ||
        expected.notify_size != actual.notify_size ||
        expected.notify_table_sel != actual.notify_table_sel ||
        expected.notify_table_index != actual.notify_table_index ||
        expected.host_id != actual.host_id ||
        expected.pfvf_id != actual.pfvf_id ||
        expected.rdma_vf_id != actual.rdma_vf_id ||
        expected.global_function_id != actual.global_function_id ||
        expected.vsi_id != actual.vsi_id ||
        expected.queue_dma != actual.queue_dma ||
        expected.queue_caps != actual.queue_caps ||
        expected.interrupt_vectors.size() != actual.interrupt_vectors.size() ||
        expected.state != actual.state ||
        expected.generation != actual.generation ||
        expected.notify_valid != actual.notify_valid ||
        expected.notify_ready != actual.notify_ready ||
        expected.dmi_valid != actual.dmi_valid ||
        expected.dmi_ready != actual.dmi_ready ||
        expected.vft_valid != actual.vft_valid ||
        expected.vft_ready != actual.vft_ready ||
        ((expected.owner_h == null) != (actual.owner_h == null)))
      return 1'b0;
    foreach (expected.pcie.bar[i]) begin
      if (expected.pcie.bar[i] == null || actual.pcie.bar[i] == null ||
          expected.pcie.bar[i].bar_id != actual.pcie.bar[i].bar_id ||
          expected.pcie.bar[i].base != actual.pcie.bar[i].base ||
          expected.pcie.bar[i].size != actual.pcie.bar[i].size ||
          expected.pcie.bar[i].enabled != actual.pcie.bar[i].enabled)
        return 1'b0;
    end
    foreach (expected.interrupt_vectors[i]) begin
      if (expected.interrupt_vectors[i].function_local_vector !=
            actual.interrupt_vectors[i].function_local_vector ||
          expected.interrupt_vectors[i].hardware_eq_vector !=
            actual.interrupt_vectors[i].hardware_eq_vector ||
          expected.interrupt_vectors[i].msix_table_index !=
            actual.interrupt_vectors[i].msix_table_index ||
          expected.interrupt_vectors[i].enabled !=
            actual.interrupt_vectors[i].enabled)
        return 1'b0;
    end
    if (expected.owner_h != null &&
        (expected.owner_h.kind != actual.owner_h.kind ||
         expected.owner_h.function_uid != actual.owner_h.function_uid ||
         expected.owner_h.object_id != actual.owner_h.object_id ||
         expected.owner_h.generation != actual.owner_h.generation))
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：复制 binding 的完整公开值图，建立 reset seal 专用 detached snapshot；该路径
  //       校验 identity/PCIe/BAR/owner 图的结构和镜像一致性，但不把 ACTIVE readiness
  //       （MSE/BME、notify/DMI/VFT ready）误当成 reset capture 的前置条件。
  // 输入/输出及副作用：source（输入）为 context 或 candidate binding；name（输入）为
  //   snapshot 名称；snapshot（输出）获得独立 identity、PCIe/BAR、queue/vector、owner
  //   和 readiness 值，不修改 source、context、router 或 coordinator。
  // 失败/边界：source/identity/PCIe/BAR 缺失、identity snapshot 或 owner 类型不支持、
  //   UID/generation/route 镜像不一致时返回 INVALID_STATE/INVALID_ARGUMENT；该 helper
  //   不调用 source.validate()，因此调用方仍须由 binding_value_matches() 做最终值比对。
  protected static function rdma_status snapshot_binding_value_graph(
    rdma_function_binding source,
    string name,
    output rdma_function_binding snapshot
  );
    rdma_function_identity identity_snapshot;
    rdma_function_handle function_owner_snapshot;
    rdma_handle owner_snapshot;
    rdma_status status;

    snapshot = null;
    if (source == null || source.pcie == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset binding value graph source or PCIe identity is missing"
      );
    if (source.pcie.get_object_type() != rdma_pcie_identity::get_type())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset binding value graph PCIe subtype is unsupported"
      );
    foreach (source.pcie.bar[i]) begin
      if (source.pcie.bar[i] == null ||
          source.pcie.bar[i].get_object_type() != rdma_bar_info::get_type())
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          $sformatf("reset binding value graph BAR %0d is incomplete", i)
        );
    end
    status = source.snapshot_identity_nonfatal(identity_snapshot);
    if (status == null || !status.ok() || identity_snapshot == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        status == null ?
          "reset binding value graph identity snapshot returned null" :
          status.message
      );

    snapshot = new(name);
    if (snapshot == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "reset binding value graph allocation failed"
      );
    status = snapshot.configure_identity(identity_snapshot);
    if (status == null || !status.ok())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        status == null ?
          "reset binding value graph identity configuration returned null" :
          status.message
      );

    snapshot.function_uid = source.function_uid;
    snapshot.pcie.bdf = source.pcie.bdf;
    snapshot.pcie.parent_pf_bdf = source.pcie.parent_pf_bdf;
    snapshot.pcie.vf_index = source.pcie.vf_index;
    snapshot.pcie.mse = source.pcie.mse;
    snapshot.pcie.bme = source.pcie.bme;
    foreach (source.pcie.bar[i]) begin
      snapshot.pcie.bar[i].bar_id = source.pcie.bar[i].bar_id;
      snapshot.pcie.bar[i].base = source.pcie.bar[i].base;
      snapshot.pcie.bar[i].size = source.pcie.bar[i].size;
      snapshot.pcie.bar[i].enabled = source.pcie.bar[i].enabled;
    end
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
    snapshot.queue_dma = source.queue_dma;
    snapshot.queue_caps = source.queue_caps;
    snapshot.interrupt_vectors = source.interrupt_vectors;
    snapshot.state = source.state;
    snapshot.generation = source.generation;
    snapshot.notify_valid = source.notify_valid;
    snapshot.notify_ready = source.notify_ready;
    snapshot.dmi_valid = source.dmi_valid;
    snapshot.dmi_ready = source.dmi_ready;
    snapshot.vft_valid = source.vft_valid;
    snapshot.vft_ready = source.vft_ready;

    if (source.owner_h == null) begin
      snapshot.owner_h = null;
    end
    else if (source.owner_h.get_object_type() ==
             rdma_function_handle::get_type()) begin
      function_owner_snapshot = new("reset_binding_function_owner_value");
      if (function_owner_snapshot == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "reset binding function owner value allocation failed"
        );
      function_owner_snapshot.kind = source.owner_h.kind;
      function_owner_snapshot.function_uid = source.owner_h.function_uid;
      function_owner_snapshot.object_id = source.owner_h.object_id;
      function_owner_snapshot.generation = source.owner_h.generation;
      snapshot.owner_h = function_owner_snapshot;
    end
    else if (source.owner_h.get_object_type() == rdma_handle::get_type()) begin
      owner_snapshot = new("reset_binding_owner_value");
      if (owner_snapshot == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "reset binding owner value allocation failed"
        );
      owner_snapshot.kind = source.owner_h.kind;
      owner_snapshot.function_uid = source.owner_h.function_uid;
      owner_snapshot.object_id = source.owner_h.object_id;
      owner_snapshot.generation = source.owner_h.generation;
      snapshot.owner_h = owner_snapshot;
    end
    else
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "reset binding owner subtype is unsupported"
      );

    if (snapshot.function_uid != source.function_uid ||
        snapshot.global_function_id != source.global_function_id ||
        snapshot.generation != source.generation ||
        !snapshot.matches_identity_snapshot(identity_snapshot) ||
        ((snapshot.owner_h == null) != (source.owner_h == null)))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset binding value graph mirror verification failed"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 virtual validate_reset_candidate() 之前，根据旧 identity 和 coordinator
  //       preview 的 next generation/epoch 记录候选预期值及 source/binding/owner 哨兵，
  //       建立防止后续 hostile callback 改写早期 candidate 的 env-owned seal。
  // 输入/输出及副作用：candidate、previous_identity、next_generation、next_epoch、
  //   expected_source_identity、expected_source_binding、expected_source_state（输入）；
  //   成功时写入本 fingerprint 的 detached identity 与公开 route/owner 镜像并返回 OK，
  //   不修改 candidate/context。
  // 失败/边界：candidate、旧 identity、binding、owner 或 binding identity snapshot 缺失、
  //   candidate identity/binding 与 preview incarnation 不一致、PCIe route 不完整时返回
  //   INVALID_STATE；调用方不得在失败后调用 virtual validate 或发布 epoch。
  function rdma_status capture(
    rdma_function_reset_candidate candidate,
    rdma_function_identity previous_identity_arg,
    int unsigned next_generation,
    rdma_reset_epoch_t next_epoch,
    rdma_function_identity expected_source_identity_arg,
    rdma_function_binding expected_source_binding_arg,
    rdma_function_context_state_e expected_source_state_arg
  );
    rdma_function_identity candidate_binding_identity;
    rdma_function_identity expected_next_identity;
    rdma_status expected_identity_status;
    rdma_status binding_snapshot_status;
    rdma_status source_binding_snapshot_status;

    captured = 1'b0;
    expected_identity = null;
    expected_binding_identity = null;
    expected_source_identity = expected_source_identity_arg;
    expected_source_identity_value = null;
    expected_source_binding = expected_source_binding_arg;
    expected_source_binding_value = null;
    expected_candidate_identity_ref = null;
    expected_candidate_binding_ref = null;
    expected_candidate_binding_snapshot_ref = null;
    expected_candidate_pcie_ref = null;
    expected_candidate_owner_ref = null;
    expected_binding_value = null;
    expected_source_state = expected_source_state_arg;
    if (candidate == null || previous_identity_arg == null ||
        next_generation == 0 ||
        expected_source_identity_arg == null ||
        expected_source_binding_arg == null ||
        candidate.identity == null || candidate.binding == null ||
        candidate.binding_identity_snapshot == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset candidate fingerprint capture received incomplete graph"
      );
    expected_next_identity = copy_identity_value(
      previous_identity_arg, "reset_candidate_expected_identity_seed");
    if (expected_next_identity == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "reset candidate fingerprint identity seed allocation failed"
      );
    expected_next_identity.generation = next_generation;
    expected_next_identity.reset_epoch = next_epoch;
    expected_identity_status = expected_next_identity.validate();
    if (expected_identity_status == null || !expected_identity_status.ok())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset candidate fingerprint preview identity is invalid"
      );
    if (!candidate.identity.same_incarnation(expected_next_identity) ||
        !candidate.binding_identity_snapshot.same_incarnation(
          expected_next_identity
        ))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset candidate identity disagrees with previewed incarnation"
      );

    candidate_binding_identity = candidate.binding.identity_snapshot();
    if (candidate_binding_identity == null ||
        !candidate_binding_identity.same_incarnation(expected_next_identity) ||
        !candidate.binding.matches_identity_snapshot(expected_next_identity))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset candidate binding disagrees with previewed incarnation"
      );
    if (candidate.source_identity != expected_source_identity_arg ||
        candidate.source_binding != expected_source_binding_arg ||
        candidate.source_state != expected_source_state_arg)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset candidate source sentinel changed during prepare"
      );
    if (candidate.binding.owner_h == null ||
        !candidate.binding.accepts_noalloc(candidate.binding.owner_h))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset candidate owner handle is invalid during capture"
      );

    expected_identity = copy_identity_value(
      expected_next_identity, "reset_candidate_expected_identity");
    expected_binding_identity = copy_identity_value(
      candidate_binding_identity, "reset_candidate_expected_binding_identity");
    expected_source_identity_value = copy_identity_value(
      expected_source_identity_arg, "reset_candidate_expected_source_identity");
    if (expected_identity == null || expected_binding_identity == null ||
        expected_source_identity_value == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "reset candidate fingerprint identity allocation failed"
      );

    // binding 的 queue/capability/vector/readiness/BAR 值必须在 validate seam 之前
    // 变成 detached expected graph；verify 只读该 graph，避免 validate 后只比 UID/route
    // 而放过公开值图漂移。source 也保存一份 detached 值，捕获 callback 对旧 authority
    // 的原地改写。该 accessor 在 capture 阶段运行，失败时不触碰 context 或 epoch。
    expected_binding_value = null;
    expected_source_binding_value = null;
    binding_snapshot_status = snapshot_binding_value_graph(
      candidate.binding,
      "reset_candidate_expected_binding_value",
      expected_binding_value
    );
    source_binding_snapshot_status = snapshot_binding_value_graph(
      expected_source_binding_arg,
      "reset_candidate_expected_source_binding_value",
      expected_source_binding_value
    );
    if (binding_snapshot_status == null || !binding_snapshot_status.ok() ||
        source_binding_snapshot_status == null ||
        !source_binding_snapshot_status.ok())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {"reset candidate binding fingerprint snapshot is invalid; candidate=",
         binding_snapshot_status == null ? "null" :
           binding_snapshot_status.message,
         "; source=",
         source_binding_snapshot_status == null ? "null" :
           source_binding_snapshot_status.message}
      );

    expected_candidate_identity_ref = candidate.identity;
    expected_candidate_binding_ref = candidate.binding;
    expected_candidate_binding_snapshot_ref = candidate.binding_identity_snapshot;
    expected_candidate_pcie_ref = candidate.binding.pcie;
    expected_candidate_owner_ref = candidate.binding.owner_h;

    // get_object_type() 返回 factory 注册的动态 wrapper；保存 wrapper 而不是
    // get_type_name() 字符串，避免 hostile subclass 通过 virtual type-name 覆盖
    // 伪造同名类型。wrapper 句柄只作 exact identity 比较，不取得 factory 所有权。
    expected_binding_type = candidate.binding.get_object_type();
    if (expected_binding_type == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset candidate binding dynamic type is unavailable"
      );
    expected_pcie_present = candidate.binding.pcie != null;
    if (expected_pcie_present) begin
      expected_pcie_bdf = candidate.binding.pcie.bdf;
      expected_parent_pf_bdf = candidate.binding.pcie.parent_pf_bdf;
      expected_vf_index = candidate.binding.pcie.vf_index;
      expected_pcie_mse = candidate.binding.pcie.mse;
      expected_pcie_bme = candidate.binding.pcie.bme;
    end
    expected_binding_uid = candidate.binding.function_uid;
    expected_binding_global_id = candidate.binding.global_function_id;
    expected_binding_generation = candidate.binding.generation;
    expected_binding_state = candidate.binding.state;
    expected_owner_present = candidate.binding.owner_h != null;
    if (expected_owner_present) begin
      expected_owner_type = candidate.binding.owner_h.get_object_type();
      if (expected_owner_type == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset candidate owner dynamic type is unavailable"
        );
      expected_owner_kind = candidate.binding.owner_h.kind;
      expected_owner_uid = candidate.binding.owner_h.function_uid;
      expected_owner_object_id = candidate.binding.owner_h.object_id;
      expected_owner_generation = candidate.binding.owner_h.generation;
    end
    captured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：在所有 context 的 virtual prepare/validate 返回后，以不经过 factory/virtual
  //       callback 的直接值比较验证 candidate 仍等于 capture() 时的预期图，阻止 epoch
  //       publish 后提交漂移值。
  // 输入/输出及副作用：candidate（输入）；只读比较 candidate 与 fingerprint 保存的
  //   identity、binding route/owner 和 source 哨兵，返回 detached status，不修改任何对象。
  // 失败/边界：seal 未捕获、validation_complete 被清除、任一 identity/source/PCIe/owner
  //   字段漂移或 binding noalloc authority 不再接受 owner 时返回 INVALID_STATE；调用方必须
  //   在 coordinator epoch publication 前恢复 quiesce 并放弃 candidate。
  function rdma_status verify(
    rdma_function_reset_candidate candidate
  );
    if (!captured || expected_identity == null ||
        expected_binding_identity == null || candidate == null ||
        !candidate.validation_complete || candidate.identity == null ||
        candidate.binding == null || candidate.binding_identity_snapshot == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate fingerprint is incomplete"
      );
    if (candidate.source_identity != expected_source_identity ||
        candidate.source_binding != expected_source_binding ||
        candidate.source_state != expected_source_state ||
        candidate.identity != expected_candidate_identity_ref ||
        candidate.binding != expected_candidate_binding_ref ||
        candidate.binding_identity_snapshot !=
          expected_candidate_binding_snapshot_ref ||
        candidate.binding.get_object_type() != expected_binding_type ||
        candidate.binding.pcie != expected_candidate_pcie_ref ||
        candidate.binding.owner_h != expected_candidate_owner_ref ||
        expected_source_identity_value == null ||
        expected_source_binding_value == null ||
        !candidate.source_identity.same_incarnation(
          expected_source_identity_value
        ) ||
        !binding_value_matches(
          expected_source_binding_value,
          candidate.source_binding,
          expected_source_identity_value
        ) ||
        !candidate.identity.same_incarnation(expected_identity) ||
        !candidate.binding_identity_snapshot.same_incarnation(
          expected_binding_identity
        ))
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate changed after validation"
      );
    if ((candidate.binding.pcie == null) != !expected_pcie_present)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate PCIe presence changed after validation"
      );
    if (!expected_pcie_present)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate binding PCIe identity is missing"
      );
    if (!candidate.binding.matches_identity_snapshot(expected_binding_identity) ||
        !binding_value_matches(
          expected_binding_value,
          candidate.binding,
          expected_binding_identity
        ) ||
        candidate.binding.function_uid != expected_binding_uid ||
        candidate.binding.global_function_id != expected_binding_global_id ||
        candidate.binding.generation != expected_binding_generation ||
        candidate.binding.state != expected_binding_state ||
        candidate.binding.pcie.bdf.segment != expected_pcie_bdf.segment ||
        candidate.binding.pcie.bdf.bus != expected_pcie_bdf.bus ||
        candidate.binding.pcie.bdf.device != expected_pcie_bdf.device ||
        candidate.binding.pcie.bdf.function_num !=
          expected_pcie_bdf.function_num ||
        candidate.binding.pcie.parent_pf_bdf.segment !=
          expected_parent_pf_bdf.segment ||
        candidate.binding.pcie.parent_pf_bdf.bus !=
          expected_parent_pf_bdf.bus ||
        candidate.binding.pcie.parent_pf_bdf.device !=
          expected_parent_pf_bdf.device ||
        candidate.binding.pcie.parent_pf_bdf.function_num !=
          expected_parent_pf_bdf.function_num ||
        candidate.binding.pcie.vf_index != expected_vf_index ||
        candidate.binding.pcie.mse != expected_pcie_mse ||
        candidate.binding.pcie.bme != expected_pcie_bme)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate binding changed after validation"
      );
    if ((candidate.binding.owner_h == null) == expected_owner_present)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate owner presence changed after validation"
      );
    if (expected_owner_present &&
        candidate.binding.owner_h.get_object_type() != expected_owner_type)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate owner dynamic type changed after validation"
      );
    if (expected_owner_present &&
        (candidate.binding.owner_h.kind != expected_owner_kind ||
         candidate.binding.owner_h.function_uid != expected_owner_uid ||
         candidate.binding.owner_h.object_id != expected_owner_object_id ||
         candidate.binding.owner_h.generation != expected_owner_generation ||
         !candidate.binding.accepts_noalloc(candidate.binding.owner_h)))
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "reset candidate owner changed after validation"
      );
    return rdma_status::make_direct(RDMA_SC_OK);
  endfunction
endclass

class rdma_device_env extends uvm_object;
  `uvm_object_utils(rdma_device_env)
  dpu_device_snapshot device_snapshot;
  dpu_resource_snapshot resources;
  dpu_resource_manager resource_manager;
  rdma_host_mem_router host_mem;
  rdma_pcie_router pcie;
  rdma_reset_coordinator reset_coordinator;
  // 按 dpu_common 的完整 Function key 保存身份副本，供各 Function
  // context 和 reset coordinator 共享同一份 immutable authority。
  protected rdma_function_identity m_identities[string];
  // Context 索引与 identity ledger 使用同一完整 Function key；value 由 env
  // 创建并持有，外部只通过 find_*() 获取非拥有引用，避免调用方绕过 scope 校验。
  protected rdma_function_context m_contexts[string];
  // reset 请求在 virtual prepare/validate callback 内仍可能被同步重入；该标志只
  // 保护当前 env 的 reset 事务边界，不代表外部 router 或 coordinator 的锁所有权。
  protected bit m_reset_in_progress;
  // device env 成功 build 后持有 coordinator 的唯一 ownership lease；token 是
  // coordinator 生成的 opaque 值，env 不把它写入 Function identity 或 router ledger。
  protected longint unsigned m_reset_lease_token;
  // close() 成功后禁止再次通过 env 发起 reset；context/router 的非拥有引用同时被清理，
  // 使 coordinator lease 与 env 生命周期有明确的终点。
  protected bit m_closed;

  // 功能：env_status_or_error 将 identity/context/reset 边界返回的状态统一为
  //       非空值，避免集成层在错误诊断中再次解引用 null。
  // 输入/输出及副作用：status 和 label 为输入；非空状态原样返回，null 状态
  //       转为 INVALID_STATE；不修改快照、identity、context 或 coordinator。
  // 失败/边界：任何外部适配器返回 null 都被视为契约违例，调用方必须停止当前
  //       构建或复位分支，不能发布半初始化 device env。
  protected static function rdma_status env_status_or_error(
    rdma_status status,
    string label
  );
    if (status == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {label, " returned null status"}
      );
    return status;
  endfunction

  // 功能：构造空的设备环境对象并初始化 UVM 对象名称；实际依赖绑定由 build() 完成。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name="rdma_device_env");
    super.new(name);
    m_reset_in_progress = 1'b0;
    m_reset_lease_token = 0;
    m_closed = 1'b0;
  endfunction

  // 功能：以冻结 dpu_common 快照为权威，原子地组装 device env、identity ledger
  //       和 reset coordinator；失败时返回错误状态且不返回半初始化环境。
  // 输入/输出及副作用：冻结快照和 manager/router 以非拥有引用写入候选 env；每个 Function
  //   由 adapter 投影 identity/binding、由 context 克隆并暂存 identity，全部 Function 成功后
  //   才通过 coordinator 批量提交 Host-router/identity ledger；result_env 仅在最终 commit 成功
  //   后发布，registry/build_timeout 仅为兼容参数。
  // 失败/边界：依赖为空、快照未冻结/不一致或任一 Function 投影/构造失败时返回错误且
  //   result_env 保持 null；候选对象不会对外发布。
  static function rdma_status build(
    dpu_device_snapshot source_device_snapshot,
    dpu_resource_snapshot source_resources,
    dpu_resource_manager source_resource_manager,
    rdma_host_mem_router source_host_mem,
    rdma_pcie_router source_pcie,
    uvm_object registry,
    time build_timeout,
    output rdma_device_env result_env,
    input rdma_reset_coordinator coordinator = null
  );
    dpu_function_key_t keys[$];
    rdma_function_identity identity;
    rdma_function_binding binding;
    rdma_function_context ctx_snapshot;
    rdma_function_identity staged_identities[$];
    rdma_reset_coordinator selected_coordinator;
    rdma_device_env candidate_env;
    string key_name;
    rdma_status status;
    rdma_status lease_status;
    longint unsigned lease_token;

    result_env = null;
    if (source_device_snapshot == null || source_resources == null ||
        source_resource_manager == null || source_host_mem == null ||
        source_pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Device environment dependency is null");
    if (!source_device_snapshot.is_frozen() || !source_resources.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Device snapshots must be frozen");
    if (!source_resources.references_device_snapshot(source_device_snapshot))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Device/resource snapshots are incoherent");

    selected_coordinator = coordinator;
    if (selected_coordinator == null)
      selected_coordinator = rdma_reset_coordinator::type_id::create(
        "device_env_reset_coordinator");
    if (selected_coordinator == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Device environment reset coordinator allocation failed"
      );
    if (selected_coordinator.host_router_bound())
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "Device environment coordinator is still bound to a Host router"
      );
    candidate_env = rdma_device_env::type_id::create("device_env");
    if (candidate_env == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Device environment allocation failed"
      );
    candidate_env.device_snapshot = source_device_snapshot;
    candidate_env.resources = source_resources;
    candidate_env.resource_manager = source_resource_manager;
    candidate_env.host_mem = source_host_mem;
    candidate_env.pcie = source_pcie;
    candidate_env.reset_coordinator = selected_coordinator;
    candidate_env.m_reset_lease_token = 0;
    candidate_env.m_closed = 1'b0;
    candidate_env.m_identities.delete();
    candidate_env.m_contexts.delete();
    staged_identities.delete();

    source_device_snapshot.list_functions(keys);
    foreach (keys[index]) begin
      identity = null;
      binding = null;
      status = rdma_dpu_identity_adapter::from_snapshot(
        source_device_snapshot, source_resources, keys[index], identity, binding);
      status = env_status_or_error(
        status, "Function identity/binding projection"
      );
      if (!status.ok() || identity == null || binding == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
          {"Function identity/binding projection failed: ", status.message});
      // dpu_common key 名称含 PF ID，而 RDMA identity 用 BDF 作为 PF 身份；
      // 两套字符串不能互相拼接，故分别维护 dpu identity ledger 和 RDMA context index。
      key_name = dpu_function_key_name(keys[index]);
      candidate_env.m_identities[key_name] = identity;
      key_name = identity_key_name(identity.key);
      ctx_snapshot = null;
      status = rdma_function_context::build_shared(
        identity, source_resources, source_host_mem, source_pcie,
        selected_coordinator, binding, registry, build_timeout, ctx_snapshot,
        1'b1);
      status = env_status_or_error(
        status, "Function context build"
      );
      if (!status.ok() || ctx_snapshot == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
          {"Function context build failed: ", status.message});
      // Device env 是 reset coordinator 的共享所有者；context 先持有同一 coordinator，
      // 真正的 attach/register 延迟到整组 Function 候选均成功后，由
      // commit_registration_atomic 一次性发布。
      ctx_snapshot.reset_coordinator = selected_coordinator;
      staged_identities.push_back(identity);
      candidate_env.m_contexts[key_name] = ctx_snapshot;
    end
    // 所有 Function candidate 已经构造完成后才 claim coordinator；这样中途
    // projection/factory 失败不会把一个尚未发布的 env 留在 owner ledger 中。
    lease_token = 0;
    lease_status = selected_coordinator.acquire_lease(
      candidate_env, lease_token
    );
    lease_status = env_status_or_error(
      lease_status, "Device environment coordinator lease acquire"
    );
    if (!lease_status.ok())
      return lease_status;
    candidate_env.m_reset_lease_token = lease_token;
    status = selected_coordinator.commit_registration_atomic(
      source_host_mem, staged_identities, candidate_env, lease_token);
    status = env_status_or_error(status, "Device environment coordinator commit");
    if (!status.ok()) begin
      // commit 失败时 candidate_env 尚未对外发布；显式释放 lease，避免外部 caller
      // 在下一次 build 中永久看到 RESOURCE_BUSY。
      lease_status = selected_coordinator.release_lease(
        candidate_env, lease_token
      );
      lease_status = env_status_or_error(
        lease_status, "Device environment coordinator lease rollback"
      );
      return reset_status_after_rollback(
        status, lease_status, "Device environment coordinator lease rollback"
      );
    end
    // registry/timeout 保留在 API 中用于上层兼容；Device env 只保存已经
    // 校验过的 dpu_common snapshot 和唯一 reset coordinator。
    result_env = candidate_env;
    return rdma_status::success();
  endfunction

  // 功能：按 dpu_common 完整 Function key 查询身份，并返回与内部 ledger 解耦的克隆。
  // 输入/输出及副作用：key（输入）；按 dpu_function_key_name 查找 ledger，并返回 identity 的
  //   clone；读取不修改 ledger，也不转移快照所有权。
  // 失败/边界：key 未枚举或 clone/cast 失败时返回 null；调用方不得把 null 当作有效身份。
  function rdma_function_identity get_identity(dpu_function_key_t key);
    rdma_function_identity copy;
    string key_name;
    key_name = dpu_function_key_name(key);
    if (!m_identities.exists(key_name))
      return null;
    if (!rdma_deep_copy#(rdma_function_identity)::try_of(m_identities[key_name], copy))
      return null;
    return copy;
  endfunction

  // 功能：将 RDMA identity 的完整 Host/root/PF-parent/VF/BDF 路由编码为内部索引键。
  // 输入/输出及副作用：identity_key（输入）；只读编码 Host/root/function-kind/VF/BDF/parent-PF
  //   为稳定字符串键，不包含 generation 或对象句柄。
  // 失败/边界：identity_key 的字段始终是 packed 值；函数不分配资源，缺省字段按 0 编码。
  protected static function string identity_key_name(
    rdma_function_key_t identity_key
  );
    return $sformatf("%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d",
                     identity_key.host_topology_key,
                     identity_key.root_id,
                     identity_key.function_kind,
                     identity_key.vf_index,
                     identity_key.bdf.segment,
                     identity_key.bdf.bus,
                     identity_key.bdf.device,
                     identity_key.bdf.function_num,
                     identity_key.parent_pf_bdf.segment,
                     identity_key.parent_pf_bdf.bus,
                     identity_key.parent_pf_bdf.device,
                     identity_key.parent_pf_bdf.function_num);
  endfunction

  // 功能：按完整 identity 查找已枚举的 Function context，并校验调用方提供的
  //       identity 与 env 保存的 incarnation 一致。
  // 输入/输出及副作用：identity（输入）、result_context（输出）；按完整 identity key 查找并
  //   发布 env 持有的 context 非拥有引用，不克隆 context 或修改 ledger。
  // 失败/边界：identity 为空、key 不存在或 generation/epoch 不一致时返回明确错误状态。
  function rdma_status find_function(
    rdma_function_identity identity,
    output rdma_function_context result_context
  );
    string key_name;
    result_context = null;
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function identity is null");
    key_name = identity_key_name(identity.key);
    if (!m_contexts.exists(key_name) || m_contexts[key_name] == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context is not enumerated");
    if (m_contexts[key_name].identity == null ||
        !m_contexts[key_name].identity.same_incarnation(identity))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "Function identity incarnation is stale");
    result_context = m_contexts[key_name];
    return rdma_status::success();
  endfunction

  // 功能：按 Function handle 反查 context，保证 UID、global ID 和 generation 三元组
  //       与 env 的 immutable identity 完全匹配，避免同一 Host 上本地编号串线。
  // 输入/输出及副作用：function_handle（输入）、result_context（输出）；按 function_uid、global ID
  //   和 generation 三元组扫描 context，发布匹配的非拥有引用。
  // 失败/边界：句柄为空/类型错误返回 INVALID_ARGUMENT；UID 存在但 generation 过期返回 STALE。
  function rdma_status find_handle(
    rdma_handle function_handle,
    output rdma_function_context result_context
  );
    rdma_function_context candidate;
    string key_name;
    result_context = null;

    if (function_handle == null ||
        function_handle.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function handle is invalid");
    foreach (m_contexts[key_name]) begin
      candidate = m_contexts[key_name];
      if (candidate == null || candidate.identity == null)
        continue;
      if (candidate.identity.function_uid == function_handle.function_uid &&
          candidate.identity.global_function_id == function_handle.object_id) begin
        if (candidate.identity.generation != function_handle.generation)
          return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                   "Function handle generation is stale");
        result_context = candidate;
        return rdma_status::success();
      end
    end
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "Function handle is not enumerated");
  endfunction

  // 功能：返回当前 device env 已枚举的 Function context 数量，供上层完成拓扑覆盖检查。
  // 输入/输出及副作用：无参数；只读返回 m_contexts 中已枚举的 context 数量。
  // 失败/边界：尚未枚举任何 Function 时返回 0；函数不创建或删除 context。
  function int unsigned context_count();
    return m_contexts.num();
  endfunction

  // 功能：在任何 reset side effect 前验证目标 scope 的 authority、登记关系和 context 覆盖，建立
  //       quiesce 前的只读屏障。
  // 输入/输出及副作用：scope/identity/host_key（输入）；调用 coordinator 的 registered identity/
  //   Host scope 查询并扫描本 env context，成功只返回状态，不修改 context、router、epoch 或 ledger。
  // 失败/边界：unknown/stale identity、未登记 Host、空 scope、context 缺失或选中 context 已
  //   QUARANTINED 时返回错误；所有拒绝均发生在 quiesce 前，调用方可安全保持旧状态。
  protected function rdma_status validate_reset_scope(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    rdma_status status;
    rdma_function_context target_context;
    string key_name;
    bit found;

    if (reset_coordinator == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "device env reset coordinator is missing"
      );

    case (scope)
      RDMA_ENV_RESET_VF: begin
        if (identity == null ||
            identity.key.function_kind != RDMA_FUNCTION_VF)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "VF FLR preflight requires VF identity"
          );
        status = reset_coordinator.validate_registered_identity(identity);
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "VF FLR identity validation returned null"
          );
        if (!status.ok())
          return status;
        status = find_function(identity, target_context);
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "VF FLR context lookup returned null status"
          );
        if (!status.ok())
          return status;
        if (target_context == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "VF FLR target context is missing"
          );
        if (target_context.state == RDMA_CONTEXT_QUARANTINED)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "VF FLR target context is quarantined"
          );
      end

      RDMA_ENV_RESET_PF: begin
        if (identity == null ||
            identity.key.function_kind != RDMA_FUNCTION_PF)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "PF reset preflight requires PF identity"
          );
        status = reset_coordinator.validate_registered_identity(identity);
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "PF reset identity validation returned null"
          );
        if (!status.ok())
          return status;
        status = find_function(identity, target_context);
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "PF reset context lookup returned null status"
          );
        if (!status.ok())
          return status;
        if (target_context == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "PF reset target context is missing"
          );
        if (target_context.state == RDMA_CONTEXT_QUARANTINED)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "PF reset target context is quarantined"
          );
      end

      RDMA_ENV_RESET_HOST: begin
        status = reset_coordinator.validate_registered_host_scope(host_key);
        if (status == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host reset scope validation returned null"
          );
        if (!status.ok())
          return status;
      end

      RDMA_ENV_RESET_DEVICE: begin
        // Device reset has no external identity argument, but an empty env is
        // still an invalid target: otherwise coordinator epoch would advance
        // without a context capable of consuming the new incarnation.
      end

      default:
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "unknown device reset scope"
        );
    endcase

    found = 1'b0;
    foreach (m_contexts[key_name]) begin
      if (m_contexts[key_name] == null ||
          m_contexts[key_name].identity == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset scope contains an incomplete Function context"
        );
      if (!scope_matches(m_contexts[key_name], scope, identity, host_key))
        continue;
      if (m_contexts[key_name].state == RDMA_CONTEXT_QUARANTINED)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset scope contains a quarantined Function context"
        );
      found = 1'b1;
    end
    if (!found)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset scope has no matching Function context"
      );
    return rdma_status::success();
  endfunction

  // 功能：执行一个已经完成参数/authority 初筛的 env reset scope，并把 preflight、quiesce
  //       和两阶段 rebuild 串成单一可清理的事务边界。
  // 输入/输出及副作用：scope/identity/host_key（输入）选择 reset 范围；函数只调用现有
  //       validate_reset_scope()/quiesce_scope()/rebuild_scope()，成功时发布对应新 incarnation。
  // 失败/边界：任一阶段返回 null 或错误都立即返回；调用方负责在进入本函数前设置 guard，
  //       并在返回后清除 guard，使 virtual callback 重入请求只能观察到 RESOURCE_BUSY。
  protected function rdma_status execute_reset_scope(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    rdma_status status;
    rdma_function_context transitioned_contexts[$];
    string phase;

    case (scope)
      RDMA_ENV_RESET_VF: phase = "VF FLR";
      RDMA_ENV_RESET_PF: phase = "PF reset";
      RDMA_ENV_RESET_HOST: phase = "Host reset";
      RDMA_ENV_RESET_DEVICE: phase = "Device reset";
      default: phase = "unknown reset";
    endcase
    status = validate_reset_scope(scope, identity, host_key);
    status = env_status_or_error(status, {phase, " preflight"});
    if (!status.ok())
      return status;
    status = quiesce_scope(scope, identity, host_key, transitioned_contexts);
    status = env_status_or_error(status, {phase, " quiesce"});
    if (!status.ok())
      return status;
    status = rebuild_scope(scope, identity, host_key, transitioned_contexts);
    return env_status_or_error(status, {phase, " rebuild"});
  endfunction

  // 功能：在 env-local guard 之外，为已 claim coordinator lease 的 device env 开启 reset
  //       transaction；standalone legacy probe 没有 lease 时保留旧的单对象语义。
  // 输入/输出及副作用：无显式输入；读取 reset_coordinator/m_reset_lease_token，成功时由
  //       coordinator 设置 active 标志；无 lease 时返回 OK 且只依赖 m_reset_in_progress。
  // 失败/边界：coordinator 缺失返回 INVALID_STATE；另一个 owner、旧 token 或已有 active
  //       transaction 返回 RESOURCE_BUSY/INVALID_STATE，调用方不得进入 execute_reset_scope。
  protected function rdma_status begin_reset_transaction();
    if (reset_coordinator == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "device env reset coordinator is missing"
      );
    if (!reset_coordinator.lease_held())
      return rdma_status::success();
    return reset_coordinator.begin_reset(this, m_reset_lease_token);
  endfunction

  // 功能：关闭 begin_reset_transaction() 建立的 coordinator active 标志，作为 env reset
  //       成功、预检失败或 rollback 返回后的统一清理出口。
  // 输入/输出及副作用：无显式输入；读取当前 coordinator lease，成功时清除 active 标志；无
  //       lease 的 standalone env 返回 OK，不修改 context/epoch/ledger。
  // 失败/边界：coordinator 缺失或 owner/token 已失效返回对应错误；end 失败表示生命周期契约
  //       破坏，调用方应保留原 reset status 并将环境视为需要隔离。
  protected function rdma_status end_reset_transaction();
    if (reset_coordinator == null || !reset_coordinator.lease_held())
      return rdma_status::success();
    return reset_coordinator.end_reset(this, m_reset_lease_token);
  endfunction

  // 功能：为 reset scope 的所有 context/coordinator seam 统一提供可选 lease owner，避免
  //       standalone/no-lease env 把非零 owner 与零 token 组合传入而被误判为半授权调用。
  // 输入/输出及副作用：无显式输入；当 coordinator 当前由本 env 持有 lease 时返回 this，
  //       否则返回 null；只读 coordinator lease，不修改 context、router 或 reset ledger。
  // 失败/边界：coordinator 缺失或未 claim lease 时返回 null，调用方必须同时使用
  //       reset_operation_token() 的零 token 兼容值，不能只替换 owner 参数。
  protected function uvm_object reset_operation_owner();
    if (reset_coordinator != null && reset_coordinator.lease_held())
      return this;
    return null;
  endfunction

  // 功能：返回与 reset_operation_owner() 成对的 coordinator lease token，供 context 状态
  //       迁移、epoch publication 和 prevalidated commit 共用同一授权边界。
  // 输入/输出及副作用：无显式输入；持有当前 env lease 时返回 m_reset_lease_token，否则
  //       返回零；函数只读 env/coordinator 生命周期字段，不修改任何账本。
  // 失败/边界：coordinator 未 claim lease、token 尚未初始化或 coordinator 缺失时返回零；
  //       调用方不得把零 token 与非 null owner 拼接使用。
  protected function longint unsigned reset_operation_token();
    if (reset_coordinator != null && reset_coordinator.lease_held())
      return m_reset_lease_token;
    return 0;
  endfunction

  // 功能：在 execute_reset_scope() 返回后清除 env guard、结束 coordinator transaction，并
  //       合并 reset 原始结果与 end_reset 清理结果，保持最先可定位的失败诊断不被吞掉。
  // 输入/输出及副作用：reset_status/phase（输入）；清除 m_reset_in_progress，调用 end_reset_transaction()
  //       并返回原始成功/失败或带清理 metadata 的 detached status，不修改已发布 epoch。
  // 失败/边界：end_reset 返回 null/错误时 fail-closed；原始 reset 失败与清理失败同时存在时
  //       返回包含两者消息的 status，调用方不得把 transaction 生命周期破坏当作成功。
  protected function rdma_status finish_reset_transaction(
    rdma_status reset_status,
    string phase
  );
    rdma_status end_status;

    m_reset_in_progress = 1'b0;
    end_status = end_reset_transaction();
    end_status = env_status_or_error(
      end_status, {phase, " transaction end"}
    );
    return reset_status_after_rollback(
      reset_status, end_status, {phase, " transaction end"}
    );
  endfunction

  // 功能：在 device env 改写 Host-router 或 retained context 之前，逐项预检所有 context
  //       是否能够在同一 owner/token 下完成 close quarantine，建立不会产生部分 teardown
  //       的失败屏障。
  // 输入/输出及副作用：owner/lease_token（输入）描述当前 env 的 coordinator ownership；
  //       函数只读取 m_contexts 及每个 context 的 reset authority，返回第一个失败 status，
  //       不清空 identity/binding、router 引用、coordinator ledger 或任何外部资源所有权。
  // 失败/边界：索引中出现 null context、context 的 coordinator/lease 不匹配、owner/token
  //       不成对或 coordinator transaction 已失效时返回错误；全部 context 已处于
  //       QUARANTINED 仍按幂等路径通过，调用方只有在本函数成功后才可进入 teardown 提交。
  protected function rdma_status preflight_close_contexts(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status status;
    string key_name;

    foreach (m_contexts[key_name]) begin
      if (m_contexts[key_name] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          {"Device environment retained context ", key_name, " is null"}
        );
      status = m_contexts[key_name].validate_quarantine_for_close(
        owner, lease_token
      );
      status = env_status_or_error(
        status,
        {"Device environment context ", key_name, " close preflight"}
      );
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：关闭 device env 的 reset ownership 生命周期，先预检所有 retained context，再
  //       双侧解除 Host-router 绑定并 quarantine context，最后释放 coordinator lease 并
  //       清理 env 对所有外部快照、manager、router、context 和 identity 的非拥有引用；
  //       预检保证任一 context authority 拒绝时不会先发生 router 单侧 detach。
  // 输入/输出及副作用：无显式输入；成功时 m_closed 置位、context 进入
  //       RDMA_CONTEXT_QUARANTINED、router 与 coordinator 的反向引用均清除；外部
  //       snapshot/manager/PCIe/Host 资源仍由调用方拥有，close 不调用或释放它们。
  // 失败/边界：reset 正在执行、coordinator lease 属于他人、router 未知/仍有 active mapping 或
  //       detach/release 返回错误时保持 env、lease 和双侧绑定不变；重复 close 幂等成功，调用方
  //       必须先 drain mapping 后再重试 close。
  function rdma_status close();
    rdma_status status;
    string key_name;

    if (m_closed)
      return rdma_status::success();
    if (m_reset_in_progress)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "cannot close device env during reset"
      );
    if (reset_coordinator == null) begin
      // coordinator 已经缺失时，context 仍可能保留旧的非拥有 coordinator 引用；逐项
      // quarantine 后再删除 env 索引，避免外部仍持有 context handle 时观察到已关闭 env
      // 的 stale reset authority。若旧 coordinator 仍被其它 owner 持有，quarantine 会
      // fail-closed，不能用 env 的 null 引用伪造 teardown。
      status = preflight_close_contexts();
      status = env_status_or_error(
        status, "Device environment retained context close preflight"
      );
      if (!status.ok())
        return status;
      foreach (m_contexts[key_name]) begin
        if (m_contexts[key_name] != null) begin
          status = m_contexts[key_name].quarantine_for_close();
          status = env_status_or_error(
            status, "Device environment retained context quarantine"
          );
          if (!status.ok())
            return status;
        end
      end
      m_contexts.delete();
      m_identities.delete();
      device_snapshot = null;
      resources = null;
      resource_manager = null;
      host_mem = null;
      pcie = null;
      m_reset_lease_token = 0;
      m_closed = 1'b1;
      return rdma_status::success();
    end
    if (!reset_coordinator.lease_held()) begin
      // standalone env 没有 coordinator lease；只清理自身的非拥有引用，不伪造
      // 一个不存在的 detach/release 事务；retained context 仍必须进入 quarantine，
      // 不能因为 coordinator 没有 owner 就继续沿用旧 identity/binding。
      if (reset_coordinator.host_router_bound())
        return rdma_status::make(
          RDMA_SC_RESOURCE_BUSY,
          "standalone device env cannot clear a bound Host router without ownership"
        );
      status = preflight_close_contexts();
      status = env_status_or_error(
        status, "Device environment standalone context close preflight"
      );
      if (!status.ok())
        return status;
      foreach (m_contexts[key_name]) begin
        if (m_contexts[key_name] != null) begin
          status = m_contexts[key_name].quarantine_for_close();
          status = env_status_or_error(
            status, "Device environment standalone context quarantine"
          );
          if (!status.ok())
            return status;
        end
      end
      m_contexts.delete();
      m_identities.delete();
      reset_coordinator = null;
      device_snapshot = null;
      resources = null;
      resource_manager = null;
      host_mem = null;
      pcie = null;
      m_reset_lease_token = 0;
      m_closed = 1'b1;
      return rdma_status::success();
    end

    // release_lease() 只接受 transaction 已结束的 owner；先在任何 detach/quarantine
    // side effect 前拒绝 active transaction，避免后续 release 失败后留下不可重试的半关闭 env。
    if (reset_coordinator.reset_transaction_active())
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "cannot close device env during coordinator reset transaction"
      );
    status = preflight_close_contexts(this, m_reset_lease_token);
    status = env_status_or_error(
      status, "Device environment leased context close preflight"
    );
    if (!status.ok())
      return status;

    status = reset_coordinator.detach_host_router_owned(
      host_mem, this, m_reset_lease_token
    );
    status = env_status_or_error(status, "Device environment Host router detach");
    if (!status.ok())
      return status;
    // router 已完成双侧 detach 后，先隔离所有 retained context，再释放 coordinator
    // lease；这样 quarantine 仍可用当前 owner/token 完成一次授权检查，同时 release
    // 下面清空 coordinator ledger 时不会留下可继续提交旧 candidate 的外部句柄。
    foreach (m_contexts[key_name]) begin
      if (m_contexts[key_name] != null) begin
        status = m_contexts[key_name].quarantine_for_close(
          this, m_reset_lease_token
        );
        status = env_status_or_error(
          status, "Device environment context quarantine"
        );
        if (!status.ok())
          return status;
      end
    end
    status = reset_coordinator.release_lease(this, m_reset_lease_token);
    status = env_status_or_error(status, "Device environment coordinator lease release");
    if (!status.ok())
      return status;
    foreach (m_contexts[key_name]) begin
      if (m_contexts[key_name] != null)
        m_contexts[key_name].reset_coordinator = null;
    end
    m_contexts.delete();
    m_identities.delete();
    reset_coordinator = null;
    device_snapshot = null;
    resources = null;
    resource_manager = null;
    host_mem = null;
    pcie = null;
    m_reset_lease_token = 0;
    m_closed = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：请求指定 VF 的 Function-level reset，并以单 context prepare/commit 事务发布新 incarnation。
  // 输入/输出及副作用：identity（输入）；先只读校验 authority，再 quiesce 目标 VF，由 rebuild_scope
  //   预构造 identity/binding/ledger 候选，随后才推进 coordinator epoch 并无分配地提交；其他
  //   Function 不受影响，prepare 失败会恢复本次 quiesce 屏障。
  // 失败/边界：null、非 VF、未知/过时代 identity、缺失目标 context、候选 factory 失败或
  //   coordinator 缺失时返回错误；epoch commit 前失败保持 context/router/epoch/ledger 不变。
  function rdma_status request_vf_flr(rdma_function_identity identity);
    rdma_status status;

    if (m_closed)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "closed device env cannot reset"
      );
    if (identity == null || identity.key.function_kind != RDMA_FUNCTION_VF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF FLR requires a VF identity");
    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    if (m_reset_in_progress)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "device env reset is already in progress");
    status = begin_reset_transaction();
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "VF FLR reset transaction begin returned null"
        ) : status;
    m_reset_in_progress = 1'b1;
    status = execute_reset_scope(RDMA_ENV_RESET_VF, identity, 0);
    return finish_reset_transaction(status, "VF FLR");
  endfunction

  // 功能：请求指定 PF reset，并按同 Host、同 root、同 parent BDF 级联执行跨 context prepare/commit。
  // 输入/输出及副作用：identity（输入）；先只读校验完整 PF scope，再 quiesce 所有选中 context，
  //   为 PF/VF 全集准备 detached candidate 和 identity ledger，全部成功后才推进 PF epoch 并提交。
  // 失败/边界：null、非 PF、未知/过时代 identity、scope 覆盖不完整、任一 candidate/ledger
  //   factory 失败或 coordinator 缺失时返回错误；epoch commit 前失败不留下部分 context 变化。
  function rdma_status request_pf_reset(rdma_function_identity identity);
    rdma_status status;

    if (m_closed)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "closed device env cannot reset"
      );
    if (identity == null || identity.key.function_kind != RDMA_FUNCTION_PF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PF reset requires a PF identity");
    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    if (m_reset_in_progress)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "device env reset is already in progress");
    status = begin_reset_transaction();
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "PF reset transaction begin returned null"
        ) : status;
    m_reset_in_progress = 1'b1;
    status = execute_reset_scope(RDMA_ENV_RESET_PF, identity, 0);
    return finish_reset_transaction(status, "PF reset");
  endfunction

  // 功能：请求 Host reset，级联停止并以跨 context prepare/commit 重建该 Host topology 的全部 Function。
  // 输入/输出及副作用：host_topology_key（输入）；先只读校验 Host scope 和 context 覆盖，再 quiesce
  //   全部选中 context，预构造所有下一代值图，最后一次性推进 Host/Function epoch 并发布候选。
  // 失败/边界：coordinator 缺失、Host 未登记、scope 覆盖不完整、candidate/ledger factory 失败或
  //   quarantined context 时在 epoch commit 前返回，并恢复本次 quiesce 的 context 状态。
  function rdma_status request_host_reset(int unsigned host_topology_key);
    rdma_status status;

    if (m_closed)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "closed device env cannot reset"
      );
    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    if (m_reset_in_progress)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "device env reset is already in progress");
    status = begin_reset_transaction();
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host reset transaction begin returned null"
        ) : status;
    m_reset_in_progress = 1'b1;
    status = execute_reset_scope(RDMA_ENV_RESET_HOST, null, host_topology_key);
    return finish_reset_transaction(status, "Host reset");
  endfunction

  // 功能：请求 Device reset，级联停止并以全 env 的跨 context prepare/commit 重建所有 Function。
  // 输入/输出及副作用：无参数；先只读校验 device scope 覆盖，再 quiesce 全部 context，预构造
  //   下一代 identity/binding/ledger，所有候选成功后才推进全局 Device epoch 并无分配地提交。
  // 失败/边界：coordinator 缺失、env scope 为空/覆盖不完整、candidate factory 失败或 quarantined
  //   context 时在 epoch commit 前拒绝并恢复本次 quiesce；commit 后仅保留无分配 assignment 路径。
  function rdma_status request_device_reset();
    rdma_status status;

    if (m_closed)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "closed device env cannot reset"
      );
    if (reset_coordinator == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "device env reset coordinator is missing");
    if (m_reset_in_progress)
      return rdma_status::make(RDMA_SC_RESOURCE_BUSY,
                               "device env reset is already in progress");
    status = begin_reset_transaction();
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Device reset transaction begin returned null"
        ) : status;
    m_reset_in_progress = 1'b1;
    status = execute_reset_scope(RDMA_ENV_RESET_DEVICE, null, 0);
    return finish_reset_transaction(status, "Device reset");
  endfunction

  // 功能：判断 context 是否属于给定复位范围，集中维护 VF/PF/Host/Device 选择规则。
  // 输入/输出及副作用：context/scope/identity/host_key（输入）；只读判断 context 是否落在 VF、PF、
  //   Host 或 Device 复位选择范围内，不修改任何状态。
  // 失败/边界：null context/identity 永不匹配；PF 只通过完整 Host+root+parent BDF 选择后代 VF，
  //   同 Host、同 BDF 但 root 不同的 malformed topology 必须被隔离。
  protected function bit scope_matches(
    rdma_function_context ctx_snapshot,
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    if (ctx_snapshot == null || ctx_snapshot.identity == null)
      return 1'b0;
    case (scope)
      RDMA_ENV_RESET_VF:
        return identity != null && ctx_snapshot.identity.same_function(identity);
      RDMA_ENV_RESET_PF: begin
        if (identity == null ||
            ctx_snapshot.identity.key.host_topology_key !=
              identity.key.host_topology_key ||
            ctx_snapshot.identity.key.root_id != identity.key.root_id)
          return 1'b0;
        if (ctx_snapshot.identity.key.function_kind == RDMA_FUNCTION_PF)
          return ctx_snapshot.identity.same_function(identity);
        return ctx_snapshot.identity.key.function_kind == RDMA_FUNCTION_VF &&
               rdma_bdf_same(ctx_snapshot.identity.key.parent_pf_bdf,
                             identity.key.bdf);
      end
      RDMA_ENV_RESET_HOST:
        return ctx_snapshot.identity.key.host_topology_key == host_key;
      RDMA_ENV_RESET_DEVICE:
        return 1'b1;
      default:
        return 1'b0;
    endcase
  endfunction

  // 功能：计算给定 reset scope 在 coordinator ledger 中应覆盖的 Function 数量，用于在任何
  //       quiesce/epoch side effect 前后防止 env 只重建部分 context。
  // 输入/输出及副作用：scope/identity/host_key（输入）；只读查询 coordinator 的 Host/PF/Device
  //   ledger 计数，不修改 context、router 或 epoch；返回 0 表示 scope 参数或 coordinator 不可用。
  // 失败/边界：VF 固定要求一个已登记 Function；PF/Host/Device 计数由 coordinator 提供，调用方
  //   必须把 0 视为覆盖失败而非合法空 reset。
  protected function int unsigned expected_scope_count(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    if (reset_coordinator == null)
      return 0;
    case (scope)
      RDMA_ENV_RESET_VF:
        return identity == null ? 0 : 1;
      RDMA_ENV_RESET_PF:
        return reset_coordinator.pf_reset_function_count(identity);
      RDMA_ENV_RESET_HOST:
        return reset_coordinator.host_function_count(host_key);
      RDMA_ENV_RESET_DEVICE:
        return reset_coordinator.function_count();
      default:
        return 0;
    endcase
  endfunction

  // 功能：恢复 quiesce_scope 本次实际从 ACTIVE 转为 QUIESCING 的 context，撤销尚未提交的
  //       reset 屏障而不触碰既有 QUIESCING/其他 scope 状态。
  // 输入/输出及副作用：transitioned_contexts（输入）是本次成功状态迁移的非拥有引用；逐个调用
  //   restore_after_quiesce()，成功时只写回 context state，不分配 owner handle 或修改 epoch。
  // 失败/边界：列表含 null、context owner 已失效或恢复 status 为 null/错误时立即返回错误；调用方
  //   应保留原始 prepare 失败诊断，并将恢复失败视为需要隔离/人工处理的环境契约违例。
  protected function rdma_status restore_quiesced_scope(
    rdma_function_context transitioned_contexts[$]
  );
    rdma_status status;

    foreach (transitioned_contexts[index]) begin
      if (transitioned_contexts[index] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "quiesce rollback contains a null Function context"
        );
      status = transitioned_contexts[index].restore_after_quiesce(
        reset_operation_owner(), reset_operation_token()
      );
      status = env_status_or_error(status, "Function context quiesce rollback");
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：把 reset prepare/epoch 的原始失败与 quiesce rollback 结果合并为一个可观察 status，
  //       确保 rollback 自身失败时不会被原始错误吞掉。
  // 输入/输出及副作用：original_status/rollback_status/phase 为输入；成功恢复时原样返回
  //   original_status，恢复失败时返回携带原始诊断和 rollback metadata 的 detached status，
  //   不修改输入 status、context、epoch 或 ledger。
  // 失败/边界：original_status 为空或 rollback_status 为空均转为 INVALID_STATE；rollback
  //   非 OK 时 fail-closed，调用方必须把环境视为需要隔离/人工处理，而不能继续重试提交。
  protected static function rdma_status reset_status_after_rollback(
    rdma_status original_status,
    rdma_status rollback_status,
    string phase
  );
    rdma_status merged_status;

    if (original_status == null)
      original_status = rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {phase, " original reset failure returned null status"}
      );
    if (rollback_status == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        {phase, " rollback returned null status; original: ",
         original_status.message}
      );
    if (!rollback_status.ok()) begin
      // rollback_status 可能来自外部 context 的共享/缓存 status；不就地改写它，
      // 而是构造独立诊断并保留 rollback 的完整错误上下文。
      merged_status = rdma_status::make_direct(
        rollback_status.code,
        {phase, " rollback failed after original reset failure: ",
         original_status.message, "; rollback: ", rollback_status.message}
      );
      merged_status.category = rollback_status.category;
      merged_status.hardware_code = rollback_status.hardware_code;
      merged_status.hardware_code_valid = rollback_status.hardware_code_valid;
      merged_status.source_engine = rollback_status.source_engine;
      merged_status.function_uid = rollback_status.function_uid;
      merged_status.generation = rollback_status.generation;
      merged_status.resource_id = rollback_status.resource_id;
      merged_status.command_id = rollback_status.command_id;
      merged_status.wr_id = rollback_status.wr_id;
      merged_status.severity = rollback_status.severity;
      merged_status.retryable = rollback_status.retryable;
      return merged_status;
    end
    return original_status;
  endfunction

  // 功能：在 epoch 发布前停止选中 context 接收新事务，并记录本次实际迁移的对象供失败回滚。
  // 输入/输出及副作用：scope/identity/host_key（输入）；transitioned_contexts（输出）保存从 ACTIVE
  //   成功转为 QUIESCING 的 context；函数不推进 coordinator epoch，DISCOVERED/既有 QUIESCING
  //   context 保持原状态。
  // 失败/边界：空/非法 context、QUARANTINED 或 quiesce 返回错误时 fail-closed；已成功 quiesce 的
  //   context 会先尝试恢复，任何 epoch/router/identity ledger 都不会在本函数中改变。
  protected function rdma_status quiesce_scope(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key,
    output rdma_function_context transitioned_contexts[$]
  );
    rdma_status status;
    rdma_status rollback_status;
    string key_name;

    transitioned_contexts.delete();
    foreach (m_contexts[key_name]) begin
      if (!scope_matches(m_contexts[key_name], scope, identity, host_key))
        continue;
      if (m_contexts[key_name] == null ||
          m_contexts[key_name].identity == null)
        begin
          rollback_status = restore_quiesced_scope(transitioned_contexts);
          status = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reset scope contains an incomplete Function context"
          );
          return reset_status_after_rollback(
            status, rollback_status, "quiesce scope incomplete context"
          );
        end
      if (m_contexts[key_name].state == RDMA_CONTEXT_DISCOVERED ||
          m_contexts[key_name].state == RDMA_CONTEXT_QUIESCING)
        continue;
      if (m_contexts[key_name].state != RDMA_CONTEXT_ACTIVE)
        begin
          rollback_status = restore_quiesced_scope(transitioned_contexts);
          status = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reset scope contains a non-quiesceable Function context"
          );
          return reset_status_after_rollback(
            status, rollback_status, "quiesce scope non-quiesceable context"
          );
        end
      status = m_contexts[key_name].quiesce(
        reset_operation_owner(), reset_operation_token()
      );
      status = env_status_or_error(status, "Function context quiesce");
      if (!status.ok()) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        return reset_status_after_rollback(
          status, rollback_status, "quiesce scope transition"
        );
      end
      transitioned_contexts.push_back(m_contexts[key_name]);
    end
    return rdma_status::success();
  endfunction

  // 功能：在所有 context candidate 和 identity ledger 副本准备完成后，才向 coordinator 发布
  //       当前 reset scope 的 Host/Function/Device epoch。
  // 输入/输出及副作用：scope/identity/host_key（输入）；调用对应 coordinator request_*，成功时
  //   一次性更新该 scope 的 epoch；调用前不修改 context identity/binding，调用后不再执行会分配
  //   资源的动作。
  // 失败/边界：coordinator 缺失、scope 参数非法或 request 返回 null/错误时原样拒绝；调用方必须
  //   在该函数前完成所有可能失败的 candidate/ledger prepare，以避免 epoch 后出现部分重建。
  protected function rdma_status publish_reset_epoch(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key
  );
    rdma_status status;

    if (reset_coordinator == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "device env reset coordinator is missing"
      );
    case (scope)
      RDMA_ENV_RESET_VF:
        status = reset_coordinator.request_vf_flr(
          identity, reset_operation_owner(), reset_operation_token()
        );
      RDMA_ENV_RESET_PF:
        status = reset_coordinator.request_pf_reset(
          identity, reset_operation_owner(), reset_operation_token()
        );
      RDMA_ENV_RESET_HOST:
        status = reset_coordinator.request_host_reset(
          host_key, reset_operation_owner(), reset_operation_token()
        );
      RDMA_ENV_RESET_DEVICE:
        status = reset_coordinator.request_device_reset(
          reset_operation_owner(), reset_operation_token()
        );
      default:
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "unknown reset scope for epoch publication"
        );
    endcase
    return env_status_or_error(status, "reset coordinator epoch publication");
  endfunction

  // 功能：为指定旧/new identity 对制作 detached ledger copy，定位 dpu_common identity ledger
  //       的稳定键，但不修改任何 map；该 helper 是跨 context commit 的最后一个可失败阶段。
  // 输入/输出及副作用：previous_identity/next_identity（输入）；ledger_key/staged_copy（输出）分别
  //   返回匹配条目的 key 和 next_identity clone；函数只调用 clone，不改变 context、m_identities
  //   或 coordinator 所有权。
  // 失败/边界：任一 identity 为空、ledger 含不完整条目、clone/cast 失败或找不到 same_function
  //   条目时返回错误，并保持 staged_copy null；调用方不得在失败后推进 epoch。
  protected function rdma_status stage_identity_ledger_copy(
    rdma_function_identity previous_identity,
    rdma_function_identity next_identity,
    output string ledger_key,
    output rdma_function_identity staged_copy
  );
    uvm_object cloned_object;

    ledger_key = "";
    staged_copy = null;
    if (previous_identity == null || next_identity == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "identity ledger prepare received null identity"
      );
    foreach (m_identities[key_name]) begin
      if (m_identities[key_name] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "device env identity ledger contains a null snapshot"
        );
      if (!m_identities[key_name].same_function(previous_identity))
        continue;
      cloned_object = next_identity.clone();
      if (cloned_object == null || !$cast(staged_copy, cloned_object) ||
          staged_copy == next_identity)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "identity ledger clone failed"
        );
      ledger_key = key_name;
      return rdma_status::success();
    end
    return rdma_status::make(
      RDMA_SC_INVALID_STATE,
      "identity ledger entry is missing"
    );
  endfunction

  // 功能：在 quiesce 后执行跨 context reset 的两阶段事务：先准备全部新值和 ledger copy，再发布
  //       coordinator epoch，最后仅以无分配 assignment 提交所有 context/ledger。
  // 输入/输出及副作用：scope/identity/host_key（输入）选择 reset 范围；transitioned_contexts（输入）
  //   仅用于 prepare/epoch 失败时恢复本次 quiesce。成功时所有匹配 context 获得下一 generation/epoch，
  //   m_identities 同步替换，且不再调用可能失败的 factory。
  // 失败/边界：scope 覆盖计数不一致、context authority/ generation/epoch 校验失败、candidate 或
  //   ledger clone 失败、coordinator epoch publication 失败时回滚 quiesce 并保持旧 identity/context；
  //   epoch 已发布后只调用 commit_reset_prevalidated() 和 ledger assignment，所有可失败校验
  //   均已前移，不能在发布后返回部分成功或伪造全局成功。
  protected function rdma_status rebuild_scope(
    rdma_device_reset_scope_e scope,
    rdma_function_identity identity,
    int unsigned host_key,
    rdma_function_context transitioned_contexts[$]
  );
    rdma_function_context selected_contexts[$];
    rdma_function_reset_candidate candidates[$];
    rdma_reset_candidate_fingerprint fingerprints[$];
    rdma_function_identity staged_ledgers[$];
    string ledger_keys[$];
    rdma_function_context selected_context;
    rdma_function_reset_candidate candidate;
    rdma_reset_candidate_fingerprint fingerprint;
    rdma_function_identity previous_identity;
    rdma_function_identity staged_copy;
    rdma_status status;
    rdma_status rollback_status;
    string key_name;
    string ledger_key;
    int unsigned expected_count;
    int unsigned next_generation;
    rdma_reset_epoch_t next_epoch;

    foreach (m_contexts[key_name]) begin
      if (!scope_matches(m_contexts[key_name], scope, identity, host_key))
        continue;
      selected_context = m_contexts[key_name];
      if (selected_context == null || selected_context.identity == null)
        begin
          rollback_status = restore_quiesced_scope(transitioned_contexts);
          status = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "selected Function context is incomplete"
          );
          return reset_status_after_rollback(
            status, rollback_status, "reset scope selected context"
          );
        end
      selected_contexts.push_back(selected_context);
    end
    expected_count = expected_scope_count(scope, identity, host_key);
    if (selected_contexts.size() == 0 ||
        selected_contexts.size() != expected_count)
      begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        status = rdma_status::make(
          RDMA_SC_INVALID_STATE,
          $sformatf("reset scope context coverage mismatch (%0d/%0d)",
                    selected_contexts.size(), expected_count)
        );
        return reset_status_after_rollback(
          status, rollback_status, "reset scope coverage"
        );
      end

    // 下面循环只分配 detached candidate/ledger 值，任一拒绝都可以在 epoch 发布前回滚 quiesce。
    foreach (selected_contexts[index]) begin
      previous_identity = selected_contexts[index].identity;
      status = reset_coordinator.preview_next_function_epoch(
        previous_identity, next_epoch
      );
      status = env_status_or_error(status, "Function epoch preview");
      if (!status.ok()) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        return reset_status_after_rollback(
          status, rollback_status, "Function epoch preview"
        );
      end
      if (previous_identity.generation == 32'hffff_ffff) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        status = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function generation is exhausted"
        );
        return reset_status_after_rollback(
          status, rollback_status, "Function generation exhaustion"
        );
      end
      next_generation = previous_identity.generation + 1;
      candidate = null;
      status = selected_contexts[index].prepare_reset(
        next_generation, next_epoch, candidate
      );
      status = env_status_or_error(status, "Function context reset prepare");
      if (!status.ok() || candidate == null) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        if (!status.ok())
          return reset_status_after_rollback(
            status, rollback_status, "Function context reset prepare"
          );
        status = rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Function context reset prepare returned null candidate"
        );
        return reset_status_after_rollback(
          status, rollback_status, "Function context reset prepare candidate"
        );
      end

      // candidate 刚由 virtual prepare 返回，先按旧 identity 与 coordinator preview
      // 生成 env-owned fingerprint，再进入可被 hostile subclass 替换的 validate seam。
      // 这样后一个 context 即使改写此前 candidate，最终 no-callback verify 仍能在
      // epoch publication 前发现 drift；fingerprint 失败同样不能推进 reset epoch。
      fingerprint = new("reset_candidate_fingerprint");
      if (fingerprint == null) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        status = rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "reset candidate fingerprint allocation failed"
        );
        return reset_status_after_rollback(
          status, rollback_status, "reset candidate fingerprint allocation"
        );
      end
      status = fingerprint.capture(
        candidate, previous_identity, next_generation, next_epoch,
        selected_contexts[index].identity,
        selected_contexts[index].binding,
        selected_contexts[index].state
      );
      status = env_status_or_error(status, "Function reset candidate fingerprint");
      if (!status.ok()) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        return reset_status_after_rollback(
          status, rollback_status, "Function reset candidate fingerprint"
        );
      end
      status = selected_contexts[index].validate_reset_candidate(candidate);
      status = env_status_or_error(status, "Function context reset candidate validation");
      if (!status.ok()) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        return reset_status_after_rollback(
          status, rollback_status, "Function reset candidate validation"
        );
      end
      staged_copy = null;
      ledger_key = "";
      status = stage_identity_ledger_copy(
        previous_identity, fingerprint.expected_identity,
        ledger_key, staged_copy
      );
      status = env_status_or_error(status, "Function identity ledger prepare");
      if (!status.ok()) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        return reset_status_after_rollback(
          status, rollback_status, "Function identity ledger prepare"
        );
      end
      candidates.push_back(candidate);
      fingerprints.push_back(fingerprint);
      staged_ledgers.push_back(staged_copy);
      ledger_keys.push_back(ledger_key);
    end

    // 所有 virtual prepare/validate 已经返回；现在只用 env-owned fingerprint 做
    // 无分配、无 virtual callback 的最终完整性检查。检查必须位于唯一 epoch side
    // effect 之前，否则 hostile callback 改写的 candidate 会形成不可回滚的半提交。
    foreach (selected_contexts[index]) begin
      status = fingerprints[index].verify(candidates[index]);
      status = env_status_or_error(
        status, "Function reset candidate fingerprint verification"
      );
      if (!status.ok()) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        return reset_status_after_rollback(
          status, rollback_status,
          "Function reset candidate fingerprint verification"
        );
      end
      status = selected_contexts[index].seal_prevalidated_candidate(
        candidates[index]
      );
      status = env_status_or_error(
        status, "Function reset candidate prevalidated seal"
      );
      if (!status.ok()) begin
        rollback_status = restore_quiesced_scope(transitioned_contexts);
        return reset_status_after_rollback(
          status, rollback_status,
          "reset scope candidate prevalidated seal"
        );
      end
    end

    // 此处是唯一 epoch side effect；其后所有提交均为已预验证 candidate 的
    // owned prevalidated seam/ledger assignment，不再调用可分配或可重入的 reset API。
    status = publish_reset_epoch(scope, identity, host_key);
    if (!status.ok()) begin
      rollback_status = restore_quiesced_scope(transitioned_contexts);
      return reset_status_after_rollback(
        status, rollback_status, "reset epoch publication"
      );
    end

    foreach (selected_contexts[index]) begin
      // 全量 candidate 已在 epoch publish 前完成 validate；owned seam 只交换字段并
      // 再确认同一 env lease。若此处拒绝，说明 begin/publish 后 owner 生命周期已被
      // 外部破坏，无法安全回滚已发布 epoch，必须以 fatal 隔离而不能继续写部分 ledger。
      status = selected_contexts[index].commit_reset_prevalidated_owned(
        candidates[index], reset_operation_owner(), reset_operation_token()
      );
      if (status == null || !status.ok())
        `uvm_fatal("RDMA_RESET_COMMIT", status == null ?
                   "prevalidated context commit returned null status" :
                   status.message)
      m_identities[ledger_keys[index]] = staged_ledgers[index];
    end
    return rdma_status::success();
  endfunction
endclass
