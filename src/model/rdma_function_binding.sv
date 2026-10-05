// 目录/层次：model 层 Function binding 与 PCIe 投影值。
// 职责：绑定 dpu_common 冻结的 Function identity、PCIe/BAR、queue DMA/能力、
// interrupt vector 和 ACTIVE owner，并提供不致命的完整值快照。
// 依赖：rdma_function_identity、rdma_handle/function_handle、BDF/BAR 地址类型、rdma_status。
// 所有权与生命周期：binding 拥有 identity、PCIe 和六个 BAR 值节点；owner_h 仅是身份快照。

// 设计说明：BAR metadata 为独立值节点，支持六个 aperture 的稳定索引与深拷贝，
// 不把 PCIe 组件或 BAR 映射对象引入 model 层。
class rdma_bar_info extends uvm_object;
  `uvm_object_utils(rdma_bar_info)

  bit [2:0] bar_id;
  rdma_bar_addr_t base;
  longint unsigned size;
  bit enabled;

  // 功能：构造 disabled/零窗口的 BAR 值容器。
  // 输入/输出及副作用：name 为 UVM 实例名；所有字段清零。
  // 失败/边界：默认值仅表示未配置，是否可用由 binding.validate() 判定。
  function new(string name = "rdma_bar_info");
    super.new(name);
    bar_id = '0;
    base = '0;
    size = '0;
    enabled = 1'b0;
  endfunction

  // 功能：按值复制 rdma_bar_info 字段。
  // 输入/输出及副作用：rhs 只读；覆盖 bar_id/base/size/enabled。
  // 失败/边界：类型不匹配触发 UVM fatal（rdma_bar_info copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_bar_info rhs_bar;

    super.do_copy(rhs);
    if (!$cast(rhs_bar, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_bar_info copy type mismatch")
    bar_id = rhs_bar.bar_id;
    base = rhs_bar.base;
    size = rhs_bar.size;
    enabled = rhs_bar.enabled;
  endfunction
endclass

// 设计说明：PCIe identity 将 BDF、使能位和六个 BAR 组成 owned 投影，
// 供 binding snapshot 复制，不保存外部 PCIe 组件引用。
class rdma_pcie_identity extends uvm_object;
  `uvm_object_utils(rdma_pcie_identity)

  rdma_bdf_t bdf;
  rdma_bdf_t parent_pf_bdf;
  int unsigned vf_index;
  bit mse;
  bit bme;
  rdma_bar_info bar[6];

  // 功能：构造零 BDF、MSE/BME 关闭且带六个 BAR 值节点的 PCIe 投影。
  // 输入/输出及副作用：name 为 UVM 实例名；直接 new bar[0:5] 并令 bar_id 等于索引。
  // 失败/边界：默认值不代表 Function 已启用；直接 new 避免 factory override 改变 BAR 类型/数量。
  function new(string name = "rdma_pcie_identity");
    super.new(name);
    bdf = '0;
    parent_pf_bdf = '0;
    vf_index = '0;
    mse = 1'b0;
    bme = 1'b0;
    foreach (bar[i]) begin
      bar[i] = new($sformatf("bar_%0d", i));
      bar[i].bar_id = i;
    end
  endfunction

  // 功能：复制 PCIe 投影，六个 BAR 逐个 clone。
  // 输入/输出及副作用：rhs 只读；覆盖 BDF/vf/MSE/BME，rhs 的空 BAR 复制为 null。
  // 失败/边界：类型不匹配或 BAR clone/cast 失败触发 UVM fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_pcie_identity rhs_pcie;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_pcie, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_pcie_identity copy type mismatch")
    bdf = rhs_pcie.bdf;
    parent_pf_bdf = rhs_pcie.parent_pf_bdf;
    vf_index = rhs_pcie.vf_index;
    mse = rhs_pcie.mse;
    bme = rhs_pcie.bme;
    foreach (bar[i]) begin
      if (rhs_pcie.bar[i] == null) begin
        bar[i] = null;
      end
      else begin
        cloned_object = rhs_pcie.bar[i].clone();
        if (cloned_object == null || !$cast(bar[i], cloned_object))
          `uvm_fatal("RDMA_COPY_TYPE", "rdma_bar_info clone type mismatch")
      end
    end
  endfunction
endclass

// 设计说明：兼容子类保留旧调用方的类型名，复用 rdma_pcie_identity 的字段与所有权，
// 不形成第二套 PCIe authority。
class rdma_pcie_function_info extends rdma_pcie_identity;
  `uvm_object_utils(rdma_pcie_function_info)

  // 功能：构造兼容类型，沿用基类默认值。
  // 输入/输出及副作用：name 透传给基类。
  // 失败/边界：无。
  function new(string name = "rdma_pcie_function_info");
    super.new(name);
  endfunction
endclass

// 设计说明：BAR decode 结果对象不带外部引用，携带 target BDF、BAR 和 offset，
// 使 router 区分解码值与 aperture 自身生命周期。
class rdma_bar_decode extends uvm_object;
  `uvm_object_utils(rdma_bar_decode)

  rdma_bdf_t target_bdf;
  bit [2:0] bar_id;
  longint unsigned bar_offset;

  // 功能：构造零值 BAR decode 结果。
  // 输入/输出及副作用：name 为 UVM 实例名；三个结果字段清零。
  // 失败/边界：零值也可能是 BDF0/BAR0/offset0 的合法解码，是否命中须由调用方另记。
  function new(string name = "rdma_bar_decode");
    super.new(name);
    target_bdf = '0;
    bar_id = '0;
    bar_offset = '0;
  endfunction

  // 功能：按值复制 rdma_bar_decode 字段。
  // 输入/输出及副作用：rhs 只读；覆盖 target_bdf/bar_id/bar_offset。
  // 失败/边界：类型不匹配触发 UVM fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_bar_decode rhs_decode;

    super.do_copy(rhs);
    if (!$cast(rhs_decode, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_bar_decode copy type mismatch")
    target_bdf = rhs_decode.target_bdf;
    bar_id = rhs_decode.bar_id;
    bar_offset = rhs_decode.bar_offset;
  endfunction
endclass

typedef struct {
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
} rdma_queue_dma_context;

typedef struct {
  int unsigned min_cq_depth;
  int unsigned max_cq_depth;
  int unsigned min_srq_depth;
  int unsigned max_srq_depth;
  int unsigned max_ceq_depth;
  int unsigned max_aeq_depth;
  int unsigned max_wq_sge;
  longint unsigned max_queue_ring_bytes;
  longint unsigned max_sgb_bytes;
} rdma_queue_capabilities;

typedef struct {
  int unsigned function_local_vector;
  int unsigned hardware_eq_vector;
  int unsigned msix_table_index;
  bit enabled;
} rdma_interrupt_vector_binding;

// 设计说明：binding 是 dpu_common 冻结 topology/PCIe/queue 能力的唯一 RDMA 消费投影；
// nonfatal accessor 发布完整 detached 值，不反向改写外部 authority。
class rdma_function_binding extends uvm_object;
  `uvm_object_utils(rdma_function_binding)

  longint unsigned function_uid;
  // identity 由 binding 创建并拥有；外部只能通过 snapshot accessor 取 detached 副本。
  protected rdma_function_identity identity;
  // identity 是唯一 authority；其后的 legacy scalar 字段仅是兼容镜像。
  rdma_pcie_identity pcie;

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

  rdma_queue_dma_context queue_dma;
  rdma_queue_capabilities queue_caps;
  rdma_interrupt_vector_binding interrupt_vectors[$];
  rdma_binding_state_e state;
  int unsigned generation;
  rdma_handle owner_h;

  bit notify_valid;
  bit notify_ready;
  bit dmi_valid;
  bit dmi_ready;
  bit vft_valid;
  bit vft_ready;

  // 功能：构造 binding 及其 owned identity、PCIe 和六个 BAR 默认值。
  // 输入/输出及副作用：name 传给 uvm_object；owned child 直接 new，state 为 DISCOVERED，其余清零。
  // 失败/边界：默认 binding 无有效 identity/能力/notify/owner，需配置并激活后才能通过 validate。
  function new(string name = "rdma_function_binding");
    super.new(name);
    function_uid = '0;
    identity = new("identity");
    pcie = new("pcie");
    notify_bar_id = '0;
    notify_base = '0;
    notify_size = '0;
    notify_table_sel = '0;
    notify_table_index = '0;
    host_id = '0;
    pfvf_id = '0;
    rdma_vf_id = '0;
    global_function_id = '0;
    vsi_id = '0;
    queue_dma = '{default:'0};
    queue_caps = '{default:'0};
    interrupt_vectors.delete();
    state = RDMA_BIND_DISCOVERED;
    generation = '0;
    owner_h = null;
    notify_valid = 1'b0;
    notify_ready = 1'b0;
    dmi_valid = 1'b0;
    dmi_ready = 1'b0;
    vft_valid = 1'b0;
    vft_ready = 1'b0;
  endfunction

  // 配置者转移的是值快照，不转移调用方句柄所有权；同时刷新旧标量镜像。
  // 功能：验证并克隆 Function identity，再刷新 UID/global-ID/generation 和 PCIe 镜像。
  // 输入/输出及副作用：source 由调用方拥有；成功后 binding 持有 clone 并更新上述镜像。
  // 失败/边界：source 为 null 或校验失败不改 binding；clone 失败返回 RESOURCE_EXHAUSTED；
  //   pcie==null 时经 factory 重建，失败同样不改 binding。
  function rdma_status configure_identity(rdma_function_identity source);
    rdma_function_identity configured;
    rdma_pcie_identity pcie_candidate;
    rdma_status status;

    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function identity is null");
    status = rdma_status::nonnull(
      source.validate(),
      "Function identity validation returned null status"
    );
    if (!status.ok())
      return status;
    if (!rdma_deep_copy#(rdma_function_identity)::try_of(source, configured))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "Function identity clone failed");
    // PCIe identity 是同一 owner route 的兼容投影，不建立第二份 authority。
    // 先完成 candidate factory，再一次性发布 identity/scalar/PCIe 三组字段；
    // factory 失败时保留原 binding，避免“新 identity + 旧 PCIe”半组合。
    pcie_candidate = pcie;
    if (pcie_candidate == null) begin
      pcie_candidate = rdma_pcie_identity::type_id::create("pcie");
      if (pcie_candidate == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "PCIe identity projection allocation failed"
        );
    end
    pcie_candidate.bdf = configured.key.bdf;
    pcie_candidate.parent_pf_bdf = configured.key.parent_pf_bdf;
    pcie_candidate.vf_index = configured.key.vf_index;
    identity = configured;
    function_uid = configured.function_uid;
    global_function_id = configured.global_function_id;
    generation = configured.generation;
    pcie = pcie_candidate;
    return rdma_status::success();
  endfunction

  // 设计说明：仅用于兼容迁移；legacy 调用方可继续填充标量镜像和 PCIe 投影，
  // 但必须显式给出 host_topology_key 与 BDF，以拒绝有歧义的 route。
  // 功能：把 legacy 镜像与显式 Host/root 路由组合成新 Function identity。
  // 输入/输出及副作用：root_id/host_topology_key/function_kind/vf_index/reset_epoch 补足 authority；
  //   读取现有 BDF/UID/global-ID/generation，成功后委托 configure_identity()。
  // 失败/边界：pcie==null 返回 INVALID_STATE；identity configure/validate 错误原样返回。
  function rdma_status configure_identity_from_legacy_mirrors(
    bit [15:0] root_id,
    bit [31:0] host_topology_key,
    rdma_function_kind_e function_kind = RDMA_FUNCTION_PF,
    bit [15:0] vf_index = 16'h0,
    rdma_reset_epoch_t reset_epoch = 0
  );
    rdma_function_identity legacy_identity;
    rdma_function_key_t key;
    rdma_status status;

    if (pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PCIe identity is not instantiated");
    key.root_id = root_id;
    key.host_topology_key = host_topology_key;
    key.function_kind = function_kind;
    key.parent_pf_bdf = pcie.parent_pf_bdf;
    key.vf_index = vf_index;
    key.bdf = pcie.bdf;
    legacy_identity = rdma_function_identity::type_id::create(
      "legacy_identity");
    if (legacy_identity == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "legacy Function identity allocation failed"
      );
    status = rdma_status::nonnull(
      legacy_identity.configure(
          key, global_function_id, function_uid, generation, reset_epoch
        ),
      "legacy Function identity configuration returned null status"
    );
    if (!status.ok())
      return status;
    return configure_identity(legacy_identity);
  endfunction

  // 设计说明：迁移期测试先写 legacy generation 再调用 make_handle()，故须沿已配置 route
  // 重投影变更后的镜像，不能从标量重新猜测 route。
  // 功能：legacy 调用方改写镜像后，沿原 route 重建 authority identity。
  // 输入/输出及副作用：无参数；以原 identity.key/reset_epoch 为根调用
  //   configure_identity_from_legacy_mirrors()，更新 identity 和 PCIe 镜像。
  // 失败/边界：原 identity 为 null 或无效返回 INVALID_STATE；重建失败的 status 原样透传。
  function rdma_status synchronize_identity_from_legacy_mirrors();
    rdma_status identity_status;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function identity route is not configured");
    identity_status = identity.validate();
    if (identity_status == null || !identity_status.ok())
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function identity route is not configured"
      );
    return configure_identity_from_legacy_mirrors(
      identity.key.root_id, identity.key.host_topology_key,
      identity.key.function_kind, identity.key.vf_index, identity.reset_epoch
    );
  endfunction

  // 功能：legacy UVM copy 路径下复制完整 binding。
  // 输入/输出及副作用：rhs 只读；深拷贝 identity/PCIe/owner，按值覆盖其余字段。
  // 失败/边界：类型不匹配或 clone/cast 失败触发 UVM fatal，可能已覆盖前置字段；
  //   需要原子 nonfatal 发布时用 snapshot_complete_nonfatal()。
  virtual function void do_copy(uvm_object rhs);
    rdma_function_binding rhs_binding;

    super.do_copy(rhs);
    if (!$cast(rhs_binding, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_function_binding copy type mismatch")
    function_uid = rhs_binding.function_uid;
    identity = rdma_deep_copy#(rdma_function_identity)::of(
      rhs_binding.identity, "rdma_function_identity clone type mismatch");
    pcie = rdma_deep_copy#(rdma_pcie_identity)::of(
      rhs_binding.pcie, "rdma_pcie_identity clone type mismatch");
    notify_bar_id = rhs_binding.notify_bar_id;
    notify_base = rhs_binding.notify_base;
    notify_size = rhs_binding.notify_size;
    notify_table_sel = rhs_binding.notify_table_sel;
    notify_table_index = rhs_binding.notify_table_index;
    host_id = rhs_binding.host_id;
    pfvf_id = rhs_binding.pfvf_id;
    rdma_vf_id = rhs_binding.rdma_vf_id;
    global_function_id = rhs_binding.global_function_id;
    vsi_id = rhs_binding.vsi_id;
    queue_dma = rhs_binding.queue_dma;
    queue_caps = rhs_binding.queue_caps;
    interrupt_vectors = rhs_binding.interrupt_vectors;
    state = rhs_binding.state;
    generation = rhs_binding.generation;
    owner_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_binding.owner_h, "rdma_handle clone type mismatch");
    notify_valid = rhs_binding.notify_valid;
    notify_ready = rhs_binding.notify_ready;
    dmi_valid = rhs_binding.dmi_valid;
    dmi_ready = rhs_binding.dmi_ready;
    vft_valid = rhs_binding.vft_valid;
    vft_ready = rhs_binding.vft_ready;
  endfunction

  // 功能：由已配置 identity 构造 Function handle 值。
  // 输入/输出及副作用：无参数；核对 identity 与 UID/global-ID/generation/PCIe 镜像，
  //   成功时 factory 创建新 handle，调用方拥有。
  // 失败/边界：identity/pcie 缺失或无效、镜像不一致、factory 返回 null 时返回 null。
  function rdma_function_handle make_handle();
    rdma_function_handle handle;
    rdma_status identity_status;

    // identity 缺失或非法时不得退回 legacy scalar（global ID=0 也合法），
    // 否则未配置 binding 会被伪装成可用 Function。
    if (identity == null || pcie == null)
      return null;
    identity_status = identity.validate();
    if (identity_status == null || !identity_status.ok())
      return null;
    if (function_uid != identity.function_uid ||
        global_function_id != identity.global_function_id ||
        generation != identity.generation ||
        !rdma_bdf_same(identity.key.bdf, pcie.bdf) ||
        !rdma_bdf_same(identity.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
        identity.key.vf_index != pcie.vf_index)
      return null;
    handle = rdma_function_handle::type_id::create("function_handle");
    if (handle == null)
      return null;
    handle.kind = RDMA_RESOURCE_FUNCTION;
    handle.function_uid = identity.function_uid;
    handle.object_id = identity.global_function_id;
    handle.generation = identity.generation;
    return handle;
  endfunction

  // 功能：判断 handle 是否精确指向当前 binding 的 Function incarnation。
  // 输入/输出及副作用：handle 非拥有；只读，比对 kind/UID/global object ID/generation。
  // 失败/边界：任一对象缺失、identity 无效、镜像漂移或 incarnation 不同均返回 0。
  function bit accepts(rdma_handle handle);
    rdma_status identity_status;

    if (handle == null || identity == null || pcie == null)
      return 1'b0;
    identity_status = identity.validate();
    if (identity_status == null || !identity_status.ok())
      return 1'b0;
    if (function_uid != identity.function_uid ||
        global_function_id != identity.global_function_id ||
        generation != identity.generation ||
        !rdma_bdf_same(identity.key.bdf, pcie.bdf) ||
        !rdma_bdf_same(identity.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
        identity.key.vf_index != pcie.vf_index)
      return 1'b0;
    return handle.kind == RDMA_RESOURCE_FUNCTION &&
           handle.function_uid == identity.function_uid &&
           handle.object_id == identity.global_function_id &&
           handle.generation == identity.generation;
  endfunction

  // 功能：reset commit 路径上以纯字段比较确认 owner handle 仍指向当前 incarnation。
  // 输入/输出及副作用：handle 只读；不构造 rdma_status、不进 factory，不修改任何状态。
  // 失败/边界：对象缺失、identity 零值/route 非法、镜像漂移或字段不匹配返回 0；
  //   不发布诊断，需要详细错误时用 accepts()。
  function bit accepts_noalloc(rdma_handle handle);
    if (handle == null || identity == null || pcie == null ||
        identity.function_uid == 0 || identity.generation == 0 ||
        !rdma_function_key_route_valid(identity.key))
      return 1'b0;
    if (function_uid != identity.function_uid ||
        global_function_id != identity.global_function_id ||
        generation != identity.generation ||
        !rdma_bdf_same(identity.key.bdf, pcie.bdf) ||
        !rdma_bdf_same(identity.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
        identity.key.vf_index != pcie.vf_index)
      return 1'b0;
    return handle.kind == RDMA_RESOURCE_FUNCTION &&
           handle.function_uid == identity.function_uid &&
           handle.object_id == identity.global_function_id &&
           handle.generation == identity.generation;
  endfunction

  // 功能：直接构造 nonfatal snapshot 路径使用的 status 值。
  // 输入/输出及副作用：code/message 为输入；返回新 status，不经 factory。
  // 失败/边界：未知 code 沿用 category_for 的保守类别；不发 UVM fatal。
  protected function rdma_status snapshot_status(
    rdma_status_code_e code,
    string message = ""
  );
    rdma_status status;

    status = new("binding_snapshot_status");
    status.category = rdma_status::category_for(code);
    status.code = code;
    status.hardware_code = '0;
    status.hardware_code_valid = 1'b0;
    status.source_engine = RDMA_ENGINE_NONE;
    status.function_uid = '0;
    status.generation = '0;
    status.resource_id = '0;
    status.command_id = '0;
    status.wr_id = '0;
    status.severity = (code == RDMA_SC_OK) ? RDMA_SEVERITY_INFO :
                                             RDMA_SEVERITY_ERROR;
    status.retryable = 1'b0;
    status.message = message;
    return status;
  endfunction

  // 功能：直接复制 protected identity，提供不致命的 status 返回边界。
  // 输入/输出及副作用：snapshot 为输出，入口先置 null；成功发布 detached identity。
  // 失败/边界：identity 为 null、subtype 未知、零 UID/generation 或 route 非法时返回错误
  //   status 且 snapshot 为 null；不进入 factory/clone/copy。
  function rdma_status snapshot_identity_nonfatal(
    output rdma_function_identity snapshot
  );
    rdma_function_identity candidate;

    snapshot = null;
    if (identity == null)
      return snapshot_status(
        RDMA_SC_INVALID_STATE, "Function identity snapshot source is null"
      );
    if (identity.get_object_type() != rdma_function_identity::get_type() ||
        identity.function_uid == 0 || identity.generation == 0 ||
        !rdma_function_key_route_valid(identity.key))
      return snapshot_status(
        RDMA_SC_INVALID_ARGUMENT,
        "Function identity snapshot source is invalid or unsupported"
      );

    candidate = new("function_identity_nonfatal_snapshot");
    candidate.key = identity.key;
    candidate.global_function_id = identity.global_function_id;
    candidate.function_uid = identity.function_uid;
    candidate.generation = identity.generation;
    candidate.reset_epoch = identity.reset_epoch;
    if (candidate == identity || !candidate.same_incarnation(identity))
      return snapshot_status(
        RDMA_SC_INVALID_STATE,
        "Function identity detached candidate verification failed"
      );
    snapshot = candidate;
    return snapshot_status(RDMA_SC_OK);
  endfunction

  // 功能：直接复制完整 binding 值图，保留 exact base/Function owner subtype。
  // 输入/输出及副作用：snapshot 为输出，入口先置 null；成功发布独立的 identity、PCIe、
  //   六 BAR、owner 与 queue/vector 值。
  // 失败/边界：源 validate 失败、嵌套值缺失、owner subtype 未知或候选不等值/未 detached
  //   时返回错误 status；不调用 clone/copy/type_id::create。
  function rdma_status snapshot_complete_nonfatal(
    output rdma_function_binding snapshot
  );
    rdma_function_binding candidate;
    rdma_function_identity identity_candidate;
    rdma_function_handle function_owner_candidate;
    rdma_handle owner_candidate;
    rdma_status status;
    bit values_equal;

    snapshot = null;
    status = snapshot_identity_nonfatal(identity_candidate);
    if (status == null || !status.ok())
      return (status == null) ? snapshot_status(
        RDMA_SC_INVALID_STATE,
        "Function identity nonfatal snapshot returned null status"
      ) : status;
    if (pcie == null ||
        pcie.get_object_type() != rdma_pcie_identity::get_type())
      return snapshot_status(
        RDMA_SC_INVALID_STATE,
        "Function binding PCIe identity is null or unsupported"
      );
    foreach (pcie.bar[i]) begin
      if (pcie.bar[i] == null ||
          pcie.bar[i].get_object_type() != rdma_bar_info::get_type())
        return snapshot_status(
          RDMA_SC_INVALID_STATE,
          $sformatf("Function binding BAR %0d is null or unsupported", i)
        );
    end
    if (owner_h != null &&
        owner_h.get_object_type() != rdma_handle::get_type() &&
        owner_h.get_object_type() != rdma_function_handle::get_type())
      return snapshot_status(
        RDMA_SC_INVALID_ARGUMENT,
        "Function binding owner runtime subtype is unsupported"
      );

    status = validate();
    if (status == null)
      return snapshot_status(
        RDMA_SC_INVALID_STATE, "Function binding validation returned null"
      );
    if (!status.ok())
      return snapshot_status(status.code, status.message);

    candidate = new("function_binding_nonfatal_snapshot");
    candidate.function_uid = function_uid;
    candidate.identity = identity_candidate;
    candidate.pcie.bdf = pcie.bdf;
    candidate.pcie.parent_pf_bdf = pcie.parent_pf_bdf;
    candidate.pcie.vf_index = pcie.vf_index;
    candidate.pcie.mse = pcie.mse;
    candidate.pcie.bme = pcie.bme;
    foreach (pcie.bar[i]) begin
      candidate.pcie.bar[i].bar_id = pcie.bar[i].bar_id;
      candidate.pcie.bar[i].base = pcie.bar[i].base;
      candidate.pcie.bar[i].size = pcie.bar[i].size;
      candidate.pcie.bar[i].enabled = pcie.bar[i].enabled;
    end
    candidate.notify_bar_id = notify_bar_id;
    candidate.notify_base = notify_base;
    candidate.notify_size = notify_size;
    candidate.notify_table_sel = notify_table_sel;
    candidate.notify_table_index = notify_table_index;
    candidate.host_id = host_id;
    candidate.pfvf_id = pfvf_id;
    candidate.rdma_vf_id = rdma_vf_id;
    candidate.global_function_id = global_function_id;
    candidate.vsi_id = vsi_id;
    candidate.queue_dma = queue_dma;
    candidate.queue_caps = queue_caps;
    candidate.interrupt_vectors = interrupt_vectors;
    candidate.state = state;
    candidate.generation = generation;
    if (owner_h == null) begin
      candidate.owner_h = null;
    end
    else if (owner_h.get_object_type() ==
             rdma_function_handle::get_type()) begin
      function_owner_candidate = new("binding_function_owner_snapshot");
      owner_candidate = function_owner_candidate;
      owner_candidate.kind = owner_h.kind;
      owner_candidate.function_uid = owner_h.function_uid;
      owner_candidate.object_id = owner_h.object_id;
      owner_candidate.generation = owner_h.generation;
      candidate.owner_h = owner_candidate;
    end
    else begin
      owner_candidate = new("binding_base_owner_snapshot");
      owner_candidate.kind = owner_h.kind;
      owner_candidate.function_uid = owner_h.function_uid;
      owner_candidate.object_id = owner_h.object_id;
      owner_candidate.generation = owner_h.generation;
      candidate.owner_h = owner_candidate;
    end
    candidate.notify_valid = notify_valid;
    candidate.notify_ready = notify_ready;
    candidate.dmi_valid = dmi_valid;
    candidate.dmi_ready = dmi_ready;
    candidate.vft_valid = vft_valid;
    candidate.vft_ready = vft_ready;

    status = candidate.validate();
    if (status == null || !status.ok())
      return snapshot_status(
        (status == null) ? RDMA_SC_INVALID_STATE : status.code,
        (status == null) ?
          "Function binding detached candidate validation returned null" :
          status.message
      );
    values_equal = candidate.function_uid == function_uid &&
      candidate.identity != identity &&
      candidate.identity.same_incarnation(identity) &&
      candidate.pcie != pcie && candidate.pcie.bdf == pcie.bdf &&
      candidate.pcie.parent_pf_bdf == pcie.parent_pf_bdf &&
      candidate.pcie.vf_index == pcie.vf_index &&
      candidate.pcie.mse == pcie.mse && candidate.pcie.bme == pcie.bme &&
      candidate.notify_bar_id == notify_bar_id &&
      candidate.notify_base == notify_base &&
      candidate.notify_size == notify_size &&
      candidate.notify_table_sel == notify_table_sel &&
      candidate.notify_table_index == notify_table_index &&
      candidate.host_id == host_id && candidate.pfvf_id == pfvf_id &&
      candidate.rdma_vf_id == rdma_vf_id &&
      candidate.global_function_id == global_function_id &&
      candidate.vsi_id == vsi_id && candidate.queue_dma == queue_dma &&
      candidate.queue_caps == queue_caps && candidate.state == state &&
      candidate.generation == generation &&
      candidate.notify_valid == notify_valid &&
      candidate.notify_ready == notify_ready &&
      candidate.dmi_valid == dmi_valid &&
      candidate.dmi_ready == dmi_ready &&
      candidate.vft_valid == vft_valid &&
      candidate.vft_ready == vft_ready &&
      candidate.interrupt_vectors.size() == interrupt_vectors.size();
    foreach (pcie.bar[i]) begin
      values_equal &= candidate.pcie.bar[i] != pcie.bar[i] &&
        candidate.pcie.bar[i].bar_id == pcie.bar[i].bar_id &&
        candidate.pcie.bar[i].base == pcie.bar[i].base &&
        candidate.pcie.bar[i].size == pcie.bar[i].size &&
        candidate.pcie.bar[i].enabled == pcie.bar[i].enabled;
    end
    foreach (interrupt_vectors[i]) begin
      values_equal &= candidate.interrupt_vectors[i].function_local_vector ==
                        interrupt_vectors[i].function_local_vector &&
        candidate.interrupt_vectors[i].hardware_eq_vector ==
          interrupt_vectors[i].hardware_eq_vector &&
        candidate.interrupt_vectors[i].msix_table_index ==
          interrupt_vectors[i].msix_table_index &&
        candidate.interrupt_vectors[i].enabled ==
          interrupt_vectors[i].enabled;
    end
    if (owner_h == null)
      values_equal &= candidate.owner_h == null;
    else
      values_equal &= candidate.owner_h != null &&
        candidate.owner_h != owner_h &&
        candidate.owner_h.get_object_type() == owner_h.get_object_type() &&
        candidate.owner_h.same_instance(owner_h);
    if (!values_equal)
      return snapshot_status(
        RDMA_SC_INVALID_STATE,
        "Function binding detached candidate differs from source"
      );

    snapshot = candidate;
    return snapshot_status(RDMA_SC_OK);
  endfunction

  // 功能：兼容旧调用方，委托 nonfatal seam 返回 detached identity；修改结果不影响 authority。
  // 输入/输出及副作用：无输入；返回新 snapshot 或 null。
  // 失败/边界：identity 缺失/非法返回 null，不发 UVM fatal。
  function rdma_function_identity function_identity_snapshot();
    rdma_function_identity snapshot;
    rdma_status status;

    status = snapshot_identity_nonfatal(snapshot);
    if (status == null || !status.ok())
      return null;
    return snapshot;
  endfunction

  // 功能：function_identity_snapshot() 的别名，强调返回副本。
  // 输入/输出及副作用：无输入；返回新 identity 或 null。
  // 失败/边界：snapshot 失败返回 null。
  function rdma_function_identity identity_snapshot();
    return function_identity_snapshot();
  endfunction

  // 功能：旧 get_identity() API，返回 nonfatal detached identity。
  // 输入/输出及副作用：无输入；返回新 identity 或 null。
  // 失败/边界：identity 无效返回 null，不回退 legacy scalar。
  function rdma_function_identity get_identity();
    return function_identity_snapshot();
  endfunction

  // 功能：不分配 snapshot，验证当前 authority 与 prepare 阶段保存的 identity 仍是同一 incarnation。
  // 输入/输出及副作用：expected 为 prepare 阶段 snapshot；只读 identity、UID/global-ID/generation
  //   和 PCIe BDF 镜像，返回 bit，不调用 factory/clone。
  // 失败/边界：对象缺失、identity 无效、镜像漂移或 BDF/PF/VF 不一致返回 0；
  //   成功不代表 queue/capability/vector 字段已校验。
  function bit matches_identity_snapshot(
    rdma_function_identity expected
  );
    if (expected == null || identity == null || pcie == null)
      return 1'b0;
    if (identity.function_uid == 0 || identity.generation == 0 ||
        !rdma_function_key_route_valid(identity.key))
      return 1'b0;
    if (!identity.same_incarnation(expected) ||
        function_uid != expected.function_uid ||
        global_function_id != expected.global_function_id ||
        generation != expected.generation ||
        !rdma_bdf_same(identity.key.bdf, pcie.bdf) ||
        !rdma_bdf_same(identity.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
        identity.key.vf_index != pcie.vf_index ||
        !rdma_bdf_same(expected.key.bdf, pcie.bdf) ||
        !rdma_bdf_same(expected.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
        expected.key.vf_index != pcie.vf_index)
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：返回 identity 的 reset epoch。
  // 输入/输出及副作用：无参数；只读，不暴露 identity 句柄。
  // 失败/边界：identity==null 返回 0 作为未配置哨兵；不校验其他字段。
  function rdma_reset_epoch_t function_reset_epoch();
    return identity == null ? 0 : identity.reset_epoch;
  endfunction

  // 功能：校验 identity 与镜像、queue DMA/能力、vector、notify BAR 和 ACTIVE 门禁。
  // 输入/输出及副作用：只读 binding，返回首个拒绝 status 或 OK；不修改任何状态。
  // 失败/边界：identity/PCIe 镜像、PASID/BDF/能力/vector、BAR/notify 窗口任一非法即拒绝；
  //   ACTIVE 另需匹配 owner、DMA domain、MSE/BME 和 notify/DMI/VFT valid+ready，
  //   owner generation 过时返回 STALE_GENERATION。
  virtual function rdma_status validate();
    longint unsigned bar_last;
    longint unsigned notify_last;
    rdma_bar_info selected_bar;
    rdma_status identity_status;

    if (pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PCIe identity is not instantiated");
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function identity is not configured");
    identity_status = rdma_status::nonnull(
      identity.validate(),
      "Function identity validation returned null status"
    );
    if (!identity_status.ok())
      return identity_status;
    begin
      if (identity.function_uid != function_uid ||
          identity.global_function_id != global_function_id ||
          identity.generation != generation ||
          !rdma_bdf_same(identity.key.bdf, pcie.bdf) ||
          !rdma_bdf_same(identity.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
          identity.key.vf_index != pcie.vf_index)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "Function identity and compatibility mirrors disagree");
    end
    if (!queue_dma.pasid_valid && queue_dma.pasid != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "invalid queue PASID must be zero");
    if (queue_dma.requester_bdf.segment != pcie.bdf.segment ||
        queue_dma.requester_bdf.bus != pcie.bdf.bus ||
        queue_dma.requester_bdf.device != pcie.bdf.device ||
        queue_dma.requester_bdf.function_num != pcie.bdf.function_num)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue requester BDF does not match PCIe BDF");
    if (queue_caps.min_cq_depth == 0 ||
        queue_caps.max_cq_depth == 0 ||
        queue_caps.min_srq_depth == 0 ||
        queue_caps.max_srq_depth == 0 ||
        queue_caps.max_ceq_depth == 0 ||
        queue_caps.max_aeq_depth == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue depth capability is zero");
    if (queue_caps.min_cq_depth > queue_caps.max_cq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "minimum CQ depth exceeds maximum");
    if (queue_caps.min_srq_depth > queue_caps.max_srq_depth)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "minimum SRQ depth exceeds maximum");
    if (queue_caps.max_wq_sge == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "maximum WQ SGE capability is zero");
    if (queue_caps.max_queue_ring_bytes == 0 ||
        queue_caps.max_sgb_bytes == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue ring or SGB byte capability is zero");
    if (rdma_vf_id > 8'hff)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "RDMA VF ID exceeds 8 bits");
    foreach (interrupt_vectors[i]) begin
      for (int j = 0; j < i; j++) begin
        if (interrupt_vectors[j].function_local_vector ==
            interrupt_vectors[i].function_local_vector)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "interrupt Function-local vector is duplicated"
          );
      end
    end

    foreach (pcie.bar[i]) begin
      if (pcie.bar[i] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          $sformatf("BAR %0d metadata is not instantiated", i)
        );
    end

    if (notify_size == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture size is zero");
    if ((notify_base.value & 64'h0000_0000_0000_1fff) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture base is not 8 KiB aligned");
    if (notify_bar_id >= 6)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify BAR ID is outside BAR[0:5]");

    selected_bar = pcie.bar[notify_bar_id];
    if (selected_bar.bar_id != notify_bar_id)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "notify BAR metadata ID does not match slot");
    if (!selected_bar.enabled)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "notify BAR is disabled");
    if (selected_bar.size == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "notify BAR size is zero");

    if (selected_bar.base.value >
        (64'hffff_ffff_ffff_ffff - (selected_bar.size - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "BAR aperture end overflows 64 bits");
    if (notify_base.value >
        (64'hffff_ffff_ffff_ffff - (notify_size - 1'b1)))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture end overflows 64 bits");

    bar_last = selected_bar.base.value + selected_bar.size - 1'b1;
    notify_last = notify_base.value + notify_size - 1'b1;
    if (notify_base.value < selected_bar.base.value || notify_last > bar_last)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "notify aperture is outside its BAR");

    if (state == RDMA_BIND_ACTIVE) begin
      if (owner_h == null)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding has no owner handle");
      if (owner_h.kind != RDMA_RESOURCE_FUNCTION ||
          owner_h.function_uid != function_uid ||
          owner_h.object_id != global_function_id)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding owner identity does not match");
      if (owner_h.generation != generation)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                 "ACTIVE binding owner generation is stale");
      if (!queue_dma.dma_domain_valid)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding has no DMA domain");
      if (!pcie.mse)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding requires PCIe MSE");
      if (!pcie.bme)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE binding requires PCIe BME");
      if (!notify_valid || !notify_ready)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE notify state is not valid and ready");
      if (!dmi_valid || !dmi_ready)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE DMI state is not valid and ready");
      if (!vft_valid || !vft_ready)
        return rdma_status::make(RDMA_SC_INVALID_STATE,
                                 "ACTIVE VFT state is not valid and ready");
    end

    return rdma_status::success();
  endfunction
endclass
