// 目录：适配器接口层 adapter/rdma_abi_v5_api.sv。
// 职责：实现用户态 RDMA ABI v5 的版本协商、context/region 映射和生命周期管理。
// 依赖：依赖 rdma_types_pkg、rdma_model_pkg、rdma_context_backing_api 和 rdma_host_mem_api。
// 所有权与生命周期：ABI 只拥有自身创建的描述符；owned backing 通过后端释放，borrowed backing 永不释放。

typedef enum bit [3:0] {
  RDMA_ABI_REGION_CONTEXT    = 4'd0,
  RDMA_ABI_REGION_DOORBELL   = 4'd1,
  RDMA_ABI_REGION_QP          = 4'd2,
  RDMA_ABI_REGION_CQ          = 4'd3,
  RDMA_ABI_REGION_SRQ         = 4'd4,
  RDMA_ABI_REGION_SHADOW      = 4'd5,
  RDMA_ABI_REGION_FWQE_SGB    = 4'd6
} rdma_abi_v5_region_kind_e;

typedef enum bit {
  RDMA_ABI_MAPPING_OWNED   = 1'b0,
  RDMA_ABI_MAPPING_BORROWED = 1'b1
} rdma_abi_mapping_ownership_e;

// 功能：rdma_abi_v5_request 携带一项 ABI v5 协商或映射请求的值快照。
// 输入/输出及副作用：调用方填写 version、region_kind、length、owner 和 borrowed backing；对象不接管外部 backing 所有权。
// 失败/边界：空 owner、零长度、非法 region 或不匹配的 borrowed backing 由 rdma_abi_v5_api 在提交前拒绝。
class rdma_abi_v5_request extends uvm_object;
  `uvm_object_utils(rdma_abi_v5_request)

  int unsigned version;
  rdma_abi_v5_region_kind_e region_kind;
  longint unsigned length;
  longint unsigned user_va;
  rdma_abi_mapping_ownership_e ownership;
  rdma_function_handle function_h;
  rdma_dma_mapping borrowed_mapping;
  rdma_context_backing_ref borrowed_context;

  // 功能：构造 ABI v5 请求并初始化为未绑定、零长度的安全默认值。
  // 输入/输出及副作用：name 为 UVM 对象名；仅初始化本地字段，不访问外部资源。
  // 失败/边界：默认请求不能直接提交，必须由调用方填写 ABI 版本、Function authority 和区域长度。
  function new(string name = "rdma_abi_v5_request");
    super.new(name);
    version = 0;
    region_kind = RDMA_ABI_REGION_CONTEXT;
    length = 0;
    user_va = 0;
    ownership = RDMA_ABI_MAPPING_OWNED;
    function_h = null;
    borrowed_mapping = null;
    borrowed_context = null;
  endfunction

  // 功能：复制 ABI v5 请求的值字段并克隆句柄快照，避免测试修改源请求影响已提交事务。
  // 输入/输出及副作用：rhs 为输入源对象；当前对象字段被覆盖，borrowed backing 保持非拥有引用。
  // 失败/边界：rhs 类型不符或 Function clone 失败时触发 UVM fatal，不发布半成品请求。
  virtual function void do_copy(uvm_object rhs);
    rdma_abi_v5_request source;
    uvm_object cloned;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "ABI v5 request copy mismatch")
    version = source.version;
    region_kind = source.region_kind;
    length = source.length;
    user_va = source.user_va;
    ownership = source.ownership;
    if (source.function_h == null)
      function_h = null;
    else begin
      cloned = source.function_h.clone();
      if (cloned == null || !$cast(function_h, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "ABI v5 request Function clone mismatch")
    end
    borrowed_mapping = source.borrowed_mapping;
    borrowed_context = source.borrowed_context;
  endfunction
endclass

// 功能：rdma_abi_v5_response 暴露协商结果或映射结果，并保留 Function authority 证据。
// 输入/输出及副作用：API 填写 negotiated_version、mapping_id、地址、长度、authority 和 backing 快照；调用方只读取返回值。
// 失败/边界：失败响应保持 mapping_id=0、mapped=0；任何成功映射都必须同时返回 UID、generation 和 reset epoch。
class rdma_abi_v5_response extends uvm_object;
  `uvm_object_utils(rdma_abi_v5_response)

  int unsigned negotiated_version;
  rdma_abi_v5_region_kind_e region_kind;
  longint unsigned mapping_id;
  longint unsigned length;
  longint unsigned user_va;
  longint unsigned iova;
  longint unsigned function_uid;
  int unsigned generation;
  rdma_reset_epoch_t reset_epoch;
  rdma_abi_mapping_ownership_e ownership;
  int unsigned refcount;
  bit mapped;
  bit released;
  rdma_context_backing_ref context_ref;
  rdma_dma_mapping dma_mapping;

  // 功能：构造空 ABI v5 响应，保证失败路径不会暴露旧 mapping 或 authority。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段，不访问后端资源。
  // 失败/边界：空响应只能表示失败或未提交状态，调用方必须检查 mapped 和 mapping_id 后再使用地址。
  function new(string name = "rdma_abi_v5_response");
    super.new(name);
    negotiated_version = 0;
    region_kind = RDMA_ABI_REGION_CONTEXT;
    mapping_id = 0;
    length = 0;
    user_va = 0;
    iova = 0;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
    ownership = RDMA_ABI_MAPPING_OWNED;
    refcount = 0;
    mapped = 1'b0;
    released = 1'b0;
    context_ref = null;
    dma_mapping = null;
  endfunction

  // 功能：复制 ABI v5 响应的值字段，返回与源响应隔离的 authority/backing 快照。
  // 输入/输出及副作用：rhs 为输入源对象；当前对象被覆盖，不释放或转移源响应的后端资源。
  // 失败/边界：类型不符或嵌套对象 clone 失败时触发 UVM fatal，避免返回不完整响应。
  virtual function void do_copy(uvm_object rhs);
    rdma_abi_v5_response source;
    uvm_object cloned;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "ABI v5 response copy mismatch")
    negotiated_version = source.negotiated_version;
    region_kind = source.region_kind;
    mapping_id = source.mapping_id;
    length = source.length;
    user_va = source.user_va;
    iova = source.iova;
    function_uid = source.function_uid;
    generation = source.generation;
    reset_epoch = source.reset_epoch;
    ownership = source.ownership;
    refcount = source.refcount;
    mapped = source.mapped;
    released = source.released;
    if (source.context_ref == null)
      context_ref = null;
    else begin
      cloned = source.context_ref.clone();
      if (cloned == null || !$cast(context_ref, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "ABI v5 context clone mismatch")
    end
    if (source.dma_mapping == null)
      dma_mapping = null;
    else begin
      cloned = source.dma_mapping.clone();
      if (cloned == null || !$cast(dma_mapping, cloned))
        `uvm_fatal("RDMA_COPY_TYPE", "ABI v5 DMA mapping clone mismatch")
    end
  endfunction
endclass

// 功能：保存 ABI v5 单个 mapping 的内部释放权威和资源引用。
// 输入/输出及副作用：API 创建并更新本记录；context_ref/dma_mapping 只保存后端返回的非拥有句柄快照。
// 失败/边界：released 只能从 0 转为 1 一次；释放后重复 unmap 不再次触碰后端。
class rdma_abi_v5_mapping_record extends uvm_object;
  `uvm_object_utils(rdma_abi_v5_mapping_record)

  longint unsigned mapping_id;
  rdma_abi_v5_region_kind_e region_kind;
  longint unsigned length;
  longint unsigned user_va;
  longint unsigned iova;
  longint unsigned function_uid;
  int unsigned generation;
  rdma_reset_epoch_t reset_epoch;
  rdma_abi_mapping_ownership_e ownership;
  int unsigned refcount;
  bit released;
  rdma_context_backing_ref context_ref;
  rdma_dma_mapping dma_mapping;

  // 功能：构造空 mapping 记录并把引用计数初始化为零。
  // 输入/输出及副作用：name 为 UVM 对象名；仅初始化本地账本字段。
  // 失败/边界：未填充 mapping_id 和 authority 的记录不可发布给调用方。
  function new(string name = "rdma_abi_v5_mapping_record");
    super.new(name);
    mapping_id = 0;
    region_kind = RDMA_ABI_REGION_CONTEXT;
    length = 0;
    user_va = 0;
    iova = 0;
    function_uid = 0;
    generation = 0;
    reset_epoch = 0;
    ownership = RDMA_ABI_MAPPING_OWNED;
    refcount = 0;
    released = 1'b0;
    context_ref = null;
    dma_mapping = null;
  endfunction
endclass

// 功能：rdma_abi_v5_api 管理固定 ABI v5 的协商、映射表和 exactly-once release。
// 输入/输出及副作用：configure 注入 Function snapshot 与可选后端；方法只在本地记录映射并按契约调用后端。
// 失败/边界：版本、authority、长度、对齐或代际不匹配时拒绝事务，不推进 mapping ID 或引用计数。
class rdma_abi_v5_api extends uvm_object;
  `uvm_object_utils(rdma_abi_v5_api)

  localparam int unsigned ABI_VERSION = 5;
  localparam longint unsigned DOORBELL_BYTES = 8192;
  localparam longint unsigned SYNTHETIC_BASE = 64'h0000_7000_0000_0000;

  rdma_function_binding binding;
  rdma_function_handle authority_h;
  rdma_reset_epoch_t authority_reset_epoch;
  rdma_context_backing_api context_backing;
  rdma_host_mem_api host_mem;
  int unsigned negotiated_version;
  longint unsigned next_mapping_id;
  int unsigned release_count;
  int unsigned context_id;
  rdma_abi_v5_mapping_record mappings[longint unsigned];

  // 功能：构造 ABI v5 API 对象并建立空 mapping 账本。
  // 输入/输出及副作用：name 为 UVM 对象名；不会自动绑定 Function 或外部 host-mem/context backing。
  // 失败/边界：未 configure 和 negotiate 前，所有 alloc/map 入口返回 INVALID_STATE。
  function new(string name = "rdma_abi_v5_api");
    super.new(name);
    binding = null;
    authority_h = null;
    authority_reset_epoch = 0;
    context_backing = null;
    host_mem = null;
    negotiated_version = 0;
    next_mapping_id = 1;
    release_count = 0;
    context_id = 1;
    mappings.delete();
  endfunction

  // 功能：克隆 rdma_function_handle 的具体派生类型，供需要强类型 Function 输入的 host-mem 请求使用。
  // 输入/输出及副作用：source、label 为输入；返回独立 Function handle，不修改 source 或 API authority。
  // 失败/边界：source 为空、clone 失败或类型不符时触发 UVM fatal，调用方不会得到可疑的基类句柄。
  function automatic rdma_function_handle clone_function_handle(
    rdma_function_handle source,
    string label
  );
    uvm_object cloned;
    rdma_function_handle result;

    if (source == null)
      return null;
    cloned = source.clone();
    if (cloned == null || !$cast(result, cloned))
      `uvm_fatal("RDMA_COPY_TYPE", {label, " Function clone mismatch"})
    return result;
  endfunction

  // 功能：绑定 dpu_common 派生的 Function snapshot，并可选注入 context/host-mem 后端。
  // 输入/输出及副作用：source、context_api、host_mem_api 为输入；成功时只保存 source 的克隆和后端非拥有引用，并重置协商状态。
  // 失败/边界：source 为空、identity 无法生成合法 Function handle 或 reset epoch 缺失时返回 INVALID_ARGUMENT/INVALID_STATE；失败不替换旧 authority。
  function rdma_status configure(
    rdma_function_binding source,
    rdma_context_backing_api context_api = null,
    rdma_host_mem_api host_mem_api = null
  );
    uvm_object cloned;
    rdma_function_binding configured;
    rdma_function_handle configured_handle;
    rdma_reset_epoch_t configured_epoch;

    if (source == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ABI source binding is null");
    configured_handle = source.make_handle();
    if (configured_handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ABI source Function authority is invalid");
    configured_epoch = source.function_reset_epoch();
    cloned = source.clone();
    if (cloned == null || !$cast(configured, cloned))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "ABI source binding clone failed");
    binding = configured;
    authority_h = configured_handle;
    authority_reset_epoch = configured_epoch;
    context_backing = context_api;
    host_mem = host_mem_api;
    negotiated_version = 0;
    return rdma_status::success();
  endfunction

  // 功能：协商用户态请求的 ABI 版本，当前只接受固定版本 5。
  // 输入/输出及副作用：requested_version 输入；response 输出 negotiated_version=5 的值快照，不创建 mapping。
  // 失败/边界：未配置 Function 或版本不是 5 时返回明确错误，response 仍保持失败默认值。
  function rdma_status negotiate(
    int unsigned requested_version,
    output rdma_abi_v5_response response
  );
    response = rdma_abi_v5_response::type_id::create("abi_negotiate_response");
    if (authority_h == null || binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ABI Function authority is not configured");
    if (requested_version != ABI_VERSION)
      return rdma_status::make(RDMA_SC_UNSUPPORTED_OPCODE,
                               "ABI version is unsupported");
    negotiated_version = ABI_VERSION;
    response.negotiated_version = ABI_VERSION;
    response.function_uid = authority_h.function_uid;
    response.generation = authority_h.generation;
    response.reset_epoch = authority_reset_epoch;
    return rdma_status::success();
  endfunction

  // 功能：校验候选 Function handle 是否仍属于 API 保存的 UID/object/generation/reset epoch authority。
  // 输入/输出及副作用：candidate、candidate_epoch 为只读输入；函数只返回状态，不修改 mapping 账本。
  // 失败/边界：空句柄、类型错误、UID/object 不匹配返回 INVALID_ARGUMENT；generation 或 epoch 过期返回 STALE_GENERATION。
  function rdma_status validate_function(
    rdma_function_handle candidate,
    rdma_reset_epoch_t candidate_epoch = 0
  );
    if (authority_h == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ABI Function authority is not configured");
    return rdma_function_incarnation_status(
      candidate, authority_h.function_uid, authority_h.object_id,
      authority_h.generation, authority_reset_epoch, candidate_epoch);
  endfunction

  // 功能：分配一个 ABI v5 context backing，并返回带 authority 证据的 context descriptor。
  // 输入/输出及副作用：response 输出；若注入 context_backing，则调用 acquire 并保存其返回引用，否则生成仅用于仿真的合成地址。
  // 失败/边界：未协商、后端 acquire 失败或 authority 失效时不登记 mapping，不泄漏部分资源。
  function rdma_status alloc_context(output rdma_abi_v5_response response);
    rdma_context_backing_ref context_ref;
    rdma_status status;

    response = rdma_abi_v5_response::type_id::create("abi_context_response");
    status = ready_status();
    if (!status.ok()) return status;
    if (context_backing != null) begin
      context_ref = null;
      status = context_backing.acquire(binding, RDMA_RESOURCE_QP,
                                       context_id, context_ref);
      if (!status.ok() || context_ref == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE, "context backing returned null") : status;
    end
    status = publish_mapping(RDMA_ABI_REGION_CONTEXT, 512,
                             RDMA_ABI_MAPPING_OWNED, context_ref, null,
                             response);
    if (status.ok()) context_id++;
    return status;
  endfunction

  // 功能：映射 doorbell、QP、CQ、SRQ、shadow 或 FWQE-SGB 区域，并登记 owned/borrowed 生命周期。
  // 输入/输出及副作用：region_kind、length、ownership 和可选 backing 为输入；response 输出新 mapping descriptor，成功时推进 mapping ID。
  // 失败/边界：零长度、非对齐长度、doorbell 非 8KiB、非法 borrowed 引用或 stale authority 均在后端调用前拒绝。
  function rdma_status map_region(
    rdma_abi_v5_region_kind_e region_kind,
    longint unsigned length,
    output rdma_abi_v5_response response
  );
    return map_region_with_backing(region_kind, length,
                                   RDMA_ABI_MAPPING_OWNED, null, null,
                                   response);
  endfunction

  // 功能：映射带有显式 owned/borrowed backing 的 ABI region，供已存在的 host-mem/context 映射接入。
  // 输入/输出及副作用：region_kind、length、ownership、borrowed_mapping、borrowed_context 为输入，response 为输出；成功时登记非拥有引用。
  // 失败/边界：borrowed backing 缺失或 authority 过期时在修改 mapping 表前返回错误；外部对象始终由调用方拥有。
  function rdma_status map_region_with_backing(
    rdma_abi_v5_region_kind_e region_kind,
    longint unsigned length,
    rdma_abi_mapping_ownership_e ownership,
    rdma_dma_mapping borrowed_mapping,
    rdma_context_backing_ref borrowed_context,
    output rdma_abi_v5_response response
  );
    rdma_status status;
    rdma_dma_request_context request_context;
    rdma_dma_mapping mapped_dma;
    rdma_function_identity identity;
    rdma_backing_addr_t base;

    response = rdma_abi_v5_response::type_id::create("abi_region_response");
    status = ready_status();
    if (!status.ok()) return status;
    status = validate_region(region_kind, length);
    if (!status.ok()) return status;
    if (ownership == RDMA_ABI_MAPPING_BORROWED &&
        borrowed_mapping == null && borrowed_context == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "borrowed mapping has no backing reference");
    if (ownership == RDMA_ABI_MAPPING_BORROWED) begin
      if (borrowed_mapping != null) begin
        if (borrowed_mapping.function_h == null ||
            borrowed_mapping.function_h.function_uid != authority_h.function_uid ||
            borrowed_mapping.function_h.generation != authority_h.generation)
          return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                   "borrowed DMA mapping authority is stale");
      end
      status = publish_mapping(region_kind, length, ownership,
                               borrowed_context, borrowed_mapping, response);
      return status;
    end

    mapped_dma = null;
    if (host_mem != null) begin
      request_context = rdma_dma_request_context::type_id::create(
        "abi_dma_request_context");
      request_context.function_h = clone_function_handle(
        authority_h, "ABI DMA Function");
      identity = binding.function_identity_snapshot();
      request_context.requester_bdf = identity.key.bdf;
      request_context.route = identity.route_key();
      request_context.route_valid = 1'b1;
      request_context.reset_epoch = authority_reset_epoch;
      request_context.epoch_valid = 1'b1;
      request_context.owner_h = rdma_clone_handle_value(
        authority_h, "ABI DMA owner");
      status = host_mem.allocate(request_context, int'(length),
                                 int'(region_alignment(region_kind)),
                                 RDMA_DMA_BIDIRECTIONAL, mapped_dma);
      if (!status.ok() || mapped_dma == null)
        return status.ok() ? rdma_status::make(
          RDMA_SC_INVALID_STATE, "host memory returned null mapping") : status;
    end
    else begin
      base.value = SYNTHETIC_BASE + next_mapping_id * 64'h10000;
    end
    status = publish_mapping(region_kind, length, ownership, null,
                             mapped_dma, response);
    return status;
  endfunction

  // 功能：按 mapping ID 释放一个 ABI region，并保证同一 ID 的重复 unmap 幂等且不重复调用后端。
  // 输入/输出及副作用：mapping_id 输入；成功时更新记录 released/refcount，并对 owned context/DMA 调用一次 release。
  // 失败/边界：未知 ID 返回 INVALID_ARGUMENT；stale/后端释放失败保留未释放状态，调用方可以安全重试。
  function rdma_status unmap_region(longint unsigned mapping_id);
    rdma_abi_v5_mapping_record record;
    rdma_status status;

    if (!mappings.exists(mapping_id))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ABI mapping ID is unknown");
    record = mappings[mapping_id];
    if (record.released)
      return rdma_status::success("ABI mapping was already unmapped");
    if (record.ownership == RDMA_ABI_MAPPING_BORROWED) begin
      record.released = 1'b1;
      record.refcount = 0;
      mappings[mapping_id] = record;
      return rdma_status::success("borrowed mapping detached without release");
    end
    if (record.context_ref != null && context_backing != null) begin
      status = context_backing.\release (record.context_ref);
      if (!status.ok()) return status;
    end
    if (record.dma_mapping != null && host_mem != null) begin
      status = host_mem.\release (record.dma_mapping);
      if (!status.ok()) return status;
    end
    record.released = 1'b1;
    record.refcount = 0;
    mappings[mapping_id] = record;
    release_count++;
    return rdma_status::success();
  endfunction

  // 功能：查询 mapping ID 的当前 response 快照，供用户态读取生命周期和 authority 证据。
  // 输入/输出及副作用：mapping_id 输入、response 输出；只读内部账本，不改变引用计数或后端状态。
  // 失败/边界：未知 ID 返回 INVALID_ARGUMENT，response 保持空默认值。
  function rdma_status query_mapping(
    longint unsigned mapping_id,
    output rdma_abi_v5_response response
  );
    rdma_abi_v5_mapping_record record;

    response = rdma_abi_v5_response::type_id::create("abi_query_response");
    if (!mappings.exists(mapping_id))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ABI mapping ID is unknown");
    record = mappings[mapping_id];
    fill_response(record, response);
    return rdma_status::success();
  endfunction

  // 功能：检查 API 是否完成 Function 配置和 ABI v5 协商。
  // 输入/输出及副作用：无显式输入；只读本地 authority/版本状态并返回状态码。
  // 失败/边界：缺少任一前置条件返回 INVALID_STATE，不改变任何账本。
  function automatic rdma_status ready_status();
    if (binding == null || authority_h == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ABI Function authority is not configured");
    if (negotiated_version != ABI_VERSION)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ABI v5 has not been negotiated");
    return validate_function(authority_h, authority_reset_epoch);
  endfunction

  // 功能：校验 region 类型和固定几何约束，避免把非法 mmap 请求交给外部后端。
  // 输入/输出及副作用：region_kind、length 为只读输入；返回状态，不推进 mapping ID。
  // 失败/边界：doorbell 必须精确 8192 字节；其余区域必须非零且按区域粒度对齐。
  function automatic rdma_status validate_region(
    rdma_abi_v5_region_kind_e region_kind,
    longint unsigned length
  );
    longint unsigned alignment;

    if (!(region_kind inside {RDMA_ABI_REGION_DOORBELL,
                              RDMA_ABI_REGION_QP,
                              RDMA_ABI_REGION_CQ,
                              RDMA_ABI_REGION_SRQ,
                              RDMA_ABI_REGION_SHADOW,
                              RDMA_ABI_REGION_FWQE_SGB}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ABI region kind is invalid");
    if (length == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ABI region length is zero");
    if (region_kind == RDMA_ABI_REGION_DOORBELL &&
        length != DOORBELL_BYTES)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "doorbell mapping must be 8192 bytes");
    alignment = region_alignment(region_kind);
    if ((length % alignment) != 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ABI region length is not aligned");
    return rdma_status::success();
  endfunction

  // 功能：返回每种 ABI region 的最小对齐粒度。
  // 输入/输出及副作用：region_kind 输入；返回纯值对齐结果，不修改 API 状态。
  // 失败/边界：未知枚举返回 64 字节保守值，调用方仍会先经过 validate_region 拒绝未知类型。
  function automatic longint unsigned region_alignment(
    rdma_abi_v5_region_kind_e region_kind
  );
    case (region_kind)
      RDMA_ABI_REGION_DOORBELL: return DOORBELL_BYTES;
      RDMA_ABI_REGION_QP:       return 512;
      RDMA_ABI_REGION_FWQE_SGB: return 512;
      default:                  return 64;
    endcase
  endfunction

  // 功能：创建 mapping record、填充 response 并原子推进 next_mapping_id。
  // 输入/输出及副作用：输入为区域与后端值引用，response 输出；成功时登记新记录，失败时不改变账本。
  // 失败/边界：mapping ID 溢出或 authority 缺失时返回 RESOURCE_EXHAUSTED/INVALID_STATE。
  function rdma_status publish_mapping(
    rdma_abi_v5_region_kind_e region_kind,
    longint unsigned length,
    rdma_abi_mapping_ownership_e ownership,
    rdma_context_backing_ref context_ref,
    rdma_dma_mapping dma_mapping,
    output rdma_abi_v5_response response
  );
    rdma_abi_v5_mapping_record record;
    longint unsigned id;

    if (authority_h == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ABI authority is missing while publishing");
    id = next_mapping_id;
    if (id == 0)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "ABI mapping ID exhausted");
    record = rdma_abi_v5_mapping_record::type_id::create(
      $sformatf("abi_mapping_%0d", id));
    record.mapping_id = id;
    record.region_kind = region_kind;
    record.length = length;
    record.user_va = SYNTHETIC_BASE + id * 64'h20000;
    if (dma_mapping != null)
      record.iova = dma_mapping.iova.value;
    else if (context_ref != null && context_ref.shadow_pointer_base.value != 0)
      record.iova = context_ref.shadow_pointer_base.value;
    else if (region_kind == RDMA_ABI_REGION_DOORBELL &&
             binding.notify_base.value != 0)
      record.iova = binding.notify_base.value;
    else
      record.iova = SYNTHETIC_BASE + id * 64'h20000;
    record.function_uid = authority_h.function_uid;
    record.generation = authority_h.generation;
    record.reset_epoch = authority_reset_epoch;
    record.ownership = ownership;
    record.refcount = 1;
    record.released = 1'b0;
    record.context_ref = context_ref;
    record.dma_mapping = dma_mapping;
    mappings[id] = record;
    next_mapping_id++;
    response = rdma_abi_v5_response::type_id::create(
      $sformatf("abi_mapping_response_%0d", id));
    fill_response(record, response);
    return rdma_status::success();
  endfunction

  // 功能：把内部 mapping record 转换为 detached response 值快照。
  // 输入/输出及副作用：record 输入、response 输出；只复制值字段和非拥有后端引用，不更新内部账本。
  // 失败/边界：record 或 response 为空时直接返回，调用方必须在发布前保证两者已创建。
  function automatic void fill_response(
    rdma_abi_v5_mapping_record record,
    output rdma_abi_v5_response response
  );
    if (response == null)
      response = rdma_abi_v5_response::type_id::create("abi_response");
    if (record == null) return;
    response.negotiated_version = ABI_VERSION;
    response.region_kind = record.region_kind;
    response.mapping_id = record.mapping_id;
    response.length = record.length;
    response.user_va = record.user_va;
    response.iova = record.iova;
    response.function_uid = record.function_uid;
    response.generation = record.generation;
    response.reset_epoch = record.reset_epoch;
    response.ownership = record.ownership;
    response.refcount = record.refcount;
    response.mapped = !record.released;
    response.released = record.released;
    response.context_ref = clone_context_ref(record.context_ref,
                                             "ABI response context");
    response.dma_mapping = clone_dma_mapping(record.dma_mapping,
                                              "ABI response DMA");
  endfunction

  // 功能：克隆 context backing 引用，使 response 成为 detached 值快照。
  // 输入/输出及副作用：source、label 为输入；返回独立 context 引用，不调用 release 或改变源账本。
  // 失败/边界：source 为空返回 null；clone/cast 失败触发 UVM fatal，避免传播半可信句柄。
  function automatic rdma_context_backing_ref clone_context_ref(
    rdma_context_backing_ref source,
    string label
  );
    uvm_object cloned;
    rdma_context_backing_ref result;

    if (source == null) return null;
    cloned = source.clone();
    if (cloned == null || !$cast(result, cloned))
      `uvm_fatal("RDMA_COPY_TYPE", {label, " clone mismatch"})
    return result;
  endfunction

  // 功能：克隆 host-mem mapping 引用，使 response 读取不会修改内部 release authority。
  // 输入/输出及副作用：source、label 为输入；返回独立 mapping 快照，不接管或释放 source backing。
  // 失败/边界：source 为空返回 null；clone/cast 失败触发 UVM fatal，调用方不得继续使用不完整响应。
  function automatic rdma_dma_mapping clone_dma_mapping(
    rdma_dma_mapping source,
    string label
  );
    uvm_object cloned;
    rdma_dma_mapping result;

    if (source == null) return null;
    cloned = source.clone();
    if (cloned == null || !$cast(result, cloned))
      `uvm_fatal("RDMA_COPY_TYPE", {label, " clone mismatch"})
    return result;
  endfunction
endclass
