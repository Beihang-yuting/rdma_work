// 目录：协议与资源模型层 model/rdma_function_binding.sv。
// 职责：实现 rdma_function_binding 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_function_binding.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_bar_info extends uvm_object;
  `uvm_object_utils(rdma_bar_info)

  bit [2:0] bar_id;
  rdma_bar_addr_t base;
  longint unsigned size;
  bit enabled;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_bar_info");
    super.new(name);
    bar_id = '0;
    base = '0;
    size = '0;
    enabled = 1'b0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

class rdma_pcie_identity extends uvm_object;
  `uvm_object_utils(rdma_pcie_identity)

  rdma_bdf_t bdf;
  rdma_bdf_t parent_pf_bdf;
  int unsigned vf_index;
  bit mse;
  bit bme;
  rdma_bar_info bar[6];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_pcie_identity");
    super.new(name);
    bdf = '0;
    parent_pf_bdf = '0;
    vf_index = '0;
    mse = 1'b0;
    bme = 1'b0;
    foreach (bar[i]) begin
      bar[i] = rdma_bar_info::type_id::create($sformatf("bar_%0d", i));
      bar[i].bar_id = i;
    end
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

class rdma_pcie_function_info extends rdma_pcie_identity;
  `uvm_object_utils(rdma_pcie_function_info)

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_pcie_function_info");
    super.new(name);
  endfunction
endclass

class rdma_bar_decode extends uvm_object;
  `uvm_object_utils(rdma_bar_decode)

  rdma_bdf_t target_bdf;
  bit [2:0] bar_id;
  longint unsigned bar_offset;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_bar_decode");
    super.new(name);
    target_bdf = '0;
    bar_id = '0;
    bar_offset = '0;
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
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

class rdma_function_binding extends uvm_object;
  `uvm_object_utils(rdma_function_binding)

  longint unsigned function_uid;
  // 中文：identity 由 binding 创建并拥有；外部只能通过 snapshot accessor
  // 读取 detached 副本，不能替换或就地修改 authority。
  protected rdma_function_identity identity;
  // Function identity is the authority; legacy scalar fields below are mirrors.
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

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_function_binding");
    super.new(name);
    function_uid = '0;
    identity = rdma_function_identity::type_id::create("identity");
    pcie = rdma_pcie_identity::type_id::create("pcie");
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

  // 中文：配置者转移的是值快照，不转移调用方句柄所有权；同时刷新旧标量
  // 镜像，供尚未迁移的调用方读取。identity 配置失败时 binding 保持不变。
  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  function rdma_status configure_identity(rdma_function_identity source);
    uvm_object cloned_object;
    rdma_function_identity configured;
    rdma_status status;

    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function identity is null");
    status = source.validate();
    if (!status.ok())
      return status;
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(configured, cloned_object))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "Function identity clone failed");
    identity = configured;
    function_uid = identity.function_uid;
    global_function_id = identity.global_function_id;
    generation = identity.generation;
    // PCIe identity is a compatibility projection of the same owner route.
    if (pcie == null)
      pcie = rdma_pcie_identity::type_id::create("pcie");
    pcie.bdf = identity.key.bdf;
    pcie.parent_pf_bdf = identity.key.parent_pf_bdf;
    pcie.vf_index = identity.key.vf_index;
    return rdma_status::success();
  endfunction

  // Compatibility-only migration helper.  Legacy callers may continue to
  // populate the public scalar mirrors and PCIe projection, but must
  // explicitly provide the route authority before constructing handles.
  // host_topology_key and the PCIe BDF are required to avoid ambiguous routes.
  // 功能：校验依赖并建立该对象的运行边界，成功后保存必要的非拥有引用；拒绝不完整或重复配置。
  // 输入/输出及副作用：接收 manager、binding、router 或 profile 等依赖；成功后保存非拥有引用并更新配置状态。
  //   任一依赖为空、重复配置或代际不匹配时保持原状态并返回错误。
  // 失败/边界：配置失败不得写入半成品引用；已激活对象不得被无条件降级或重复占用资源。
  function rdma_status configure_identity_from_legacy_mirrors(
    bit [15:0] root_id,
    bit [31:0] host_topology_key,
    rdma_function_kind_e function_kind = RDMA_FUNCTION_PF,
    bit [15:0] vf_index = 16'h0,
    rdma_reset_epoch_t reset_epoch = 0
  );
    rdma_function_identity legacy_identity;
    rdma_function_key_t key;

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
    if (legacy_identity.configure(key, global_function_id, function_uid,
                                  generation, reset_epoch).ok() == 1'b0)
      return legacy_identity.validate();
    return configure_identity(legacy_identity);
  endfunction

  // Explicitly re-project changed legacy mirrors onto the already configured
  // route.  This is useful during migration for tests that model a generation
  // update by writing the legacy generation field before make_handle().
  // 功能：处理 synchronize_identity_from_legacy_mirrors：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 identity 用于执行 synchronize_identity_from_legacy_mirrors；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：synchronize_identity_from_legacy_mirrors 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_status synchronize_identity_from_legacy_mirrors();
    if (identity == null || !identity.validate().ok())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function identity route is not configured");
    return configure_identity_from_legacy_mirrors(
      identity.key.root_id, identity.key.host_topology_key,
      identity.key.function_kind, identity.key.vf_index, identity.reset_epoch
    );
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_function_binding rhs_binding;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_binding, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_function_binding copy type mismatch")
    function_uid = rhs_binding.function_uid;
    if (rhs_binding.identity == null) identity = null;
    else begin
      cloned_object = rhs_binding.identity.clone();
      if (cloned_object == null || !$cast(identity, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "rdma_function_identity clone type mismatch")
    end
    if (rhs_binding.pcie == null) begin
      pcie = null;
    end
    else begin
      cloned_object = rhs_binding.pcie.clone();
      if (cloned_object == null || !$cast(pcie, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "rdma_pcie_identity clone type mismatch")
    end
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
    if (rhs_binding.owner_h == null) begin
      owner_h = null;
    end
    else begin
      cloned_object = rhs_binding.owner_h.clone();
      if (cloned_object == null || !$cast(owner_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "rdma_handle clone type mismatch")
    end
    notify_valid = rhs_binding.notify_valid;
    notify_ready = rhs_binding.notify_ready;
    dmi_valid = rhs_binding.dmi_valid;
    dmi_ready = rhs_binding.dmi_ready;
    vft_valid = rhs_binding.vft_valid;
    vft_ready = rhs_binding.vft_ready;
  endfunction

  // 功能：依据输入请求创建对应的值对象或资源计划，并校验依赖、所有权和生命周期后返回结果。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function rdma_function_handle make_handle();
    rdma_function_handle handle;

    // 中文：identity 缺失或非法时不得退回 legacy scalar（global ID=0 也
    // 是合法值），否则会把未配置 binding 伪装成可用 Function。
    if (identity == null || !identity.validate().ok() ||
        function_uid != identity.function_uid ||
        global_function_id != identity.global_function_id ||
        generation != identity.generation || pcie == null ||
        !rdma_bdf_same(identity.key.bdf, pcie.bdf) ||
        !rdma_bdf_same(identity.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
        identity.key.vf_index != pcie.vf_index)
      return null;
    handle = rdma_function_handle::type_id::create("function_handle");
    handle.kind = RDMA_RESOURCE_FUNCTION;
    handle.function_uid = identity.function_uid;
    handle.object_id = identity.global_function_id;
    handle.generation = identity.generation;
    return handle;
  endfunction

  // 功能：处理 accepts：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 handle 用于执行 accepts；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：accepts 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function bit accepts(rdma_handle handle);
    if (handle == null || identity == null || !identity.validate().ok() ||
        function_uid != identity.function_uid ||
        global_function_id != identity.global_function_id ||
        generation != identity.generation || pcie == null ||
        !rdma_bdf_same(identity.key.bdf, pcie.bdf) ||
        !rdma_bdf_same(identity.key.parent_pf_bdf, pcie.parent_pf_bdf) ||
        identity.key.vf_index != pcie.vf_index)
      return 1'b0;
    return handle.kind == RDMA_RESOURCE_FUNCTION &&
           handle.function_uid == identity.function_uid &&
           handle.object_id == identity.global_function_id &&
           handle.generation == identity.generation;
  endfunction

  // 返回 detached snapshot，调用方修改结果不会改变 binding 的 authority。
  // 功能：处理 function_identity_snapshot：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 cloned_object 用于执行 function_identity_snapshot；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：function_identity_snapshot 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_function_identity function_identity_snapshot();
    uvm_object cloned_object;
    rdma_function_identity snapshot;
    if (identity == null) return null;
    cloned_object = identity.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object))
      `uvm_fatal("RDMA_COPY_TYPE", "Function identity snapshot clone mismatch")
    return snapshot;
  endfunction

  // 中文：别名 accessor，统一强调返回副本而非可变 authority。
  // 功能：处理 identity_snapshot：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 function_identity_snapshot 用于执行 identity_snapshot；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：identity_snapshot 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_function_identity identity_snapshot();
    return function_identity_snapshot();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_function_identity get_identity();
    return function_identity_snapshot();
  endfunction

  // 功能：处理 function_reset_epoch：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 identity 用于执行 function_reset_epoch；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：function_reset_epoch 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function rdma_reset_epoch_t function_reset_epoch();
    return identity == null ? 0 : identity.reset_epoch;
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  function rdma_status validate();
    longint unsigned bar_last;
    longint unsigned notify_last;
    rdma_bar_info selected_bar;

    if (pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "PCIe identity is not instantiated");
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function identity is not configured");
    if (!identity.validate().ok())
      return identity.validate();
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
