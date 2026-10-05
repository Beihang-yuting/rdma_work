// 目录：适配器接口层 adapter/rdma_abi_v5_api.sv。
// 职责：实现用户态 RDMA ABI v5 的版本协商、context/region 映射和生命周期管理。
// 依赖：依赖 rdma_types_pkg、rdma_model_pkg、rdma_context_backing_api 和 rdma_host_mem_api。
// 所有权与生命周期：ABI 只拥有自身创建的描述符；owned backing 经后端释放，borrowed backing 永不释放。

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

// ABI v5 协商/映射请求的值快照：调用方填写 version、region_kind、length、owner 与 borrowed backing，
// 对象不接管外部 backing。空 owner、零长度、非法 region 或 backing 不匹配由 rdma_abi_v5_api 在提交前拒绝。
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

  // 功能：构造请求，默认未绑定、零长度。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：默认请求不可直接提交，须由调用方填写版本、Function authority 与区域长度。
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

  // 功能：复制ABI v5 请求并克隆句柄快照的值字段。
  // 输入/输出及副作用：rhs 为源对象；覆盖当前对象字段，backing 保持非拥有引用。
  // 失败/边界：rhs 类型不符或 Function clone 失败触发 UVM fatal，不发布半成品。
  virtual function void do_copy(uvm_object rhs);
    rdma_abi_v5_request source;

    super.do_copy(rhs);
    if (!$cast(source, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "ABI v5 request copy mismatch")
    version = source.version;
    region_kind = source.region_kind;
    length = source.length;
    user_va = source.user_va;
    ownership = source.ownership;
    function_h = rdma_deep_copy#(rdma_function_handle)::of(
      source.function_h, "ABI v5 request Function clone mismatch");
    borrowed_mapping = source.borrowed_mapping;
    borrowed_context = source.borrowed_context;
  endfunction
endclass

// ABI v5 协商/映射响应，保留 Function authority 证据。失败响应保持 mapping_id=0、mapped=0；
// 成功映射必须同时返回 UID、generation 与 reset epoch。
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

  // 功能：构造空响应，避免失败路径暴露旧 mapping 或 authority。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：空响应只表示失败/未提交，使用地址前须检查 mapped 与 mapping_id。
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

  // 功能：复制ABI v5 响应并克隆 authority/backing 快照的值字段。
  // 输入/输出及副作用：rhs 为源对象；覆盖当前对象字段，backing 保持非拥有引用。
  // 失败/边界：类型不符或嵌套 clone 失败触发 UVM fatal。
  virtual function void do_copy(uvm_object rhs);
    rdma_abi_v5_response source;

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
    context_ref = rdma_deep_copy#(rdma_context_backing_ref)::of(
      source.context_ref, "ABI v5 context clone mismatch");
    dma_mapping = rdma_deep_copy#(rdma_dma_mapping)::of(
      source.dma_mapping, "ABI v5 DMA mapping clone mismatch");
  endfunction
endclass

// 单个 ABI v5 mapping 的内部记录：保存释放权威与资源引用，context_ref/dma_mapping 为后端返回的
// 非拥有快照。released 只能 0 到 1 一次，重复 unmap 不再触碰后端。
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

  // 功能：构造空 mapping 记录，引用计数为 0。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：未填充 mapping_id 与 authority 的记录不可发布。
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

// ABI v5 API：管理固定版本协商、映射表与 exactly-once release。configure 注入 Function snapshot 与可选后端；
// 版本、authority、长度、对齐或代际不匹配时拒绝事务，不推进 mapping ID 与引用计数。
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

  // 功能：把后端返回的状态转为可安全消费的对象。
  // 输入/输出及副作用：candidate、operation 为输入；非空原样返回，不修改账本。
  // 失败/边界：null 转为带 ABI 边界诊断的 INVALID_STATE；调用方须停止并保留 mapping 记录供重试。
  protected function automatic rdma_status normalize_status(
    rdma_status candidate,
    string operation
  );
    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {"ABI ", operation, " returned null status"}
      );
    return candidate;
  endfunction

  // 功能：构造ABI v5 API 并建立空 mapping 账本。
  // 输入/输出及副作用：name 为 UVM 对象名；只初始化本地字段。
  // 失败/边界：configure 与 negotiate 之前所有 alloc/map 入口返回 INVALID_STATE。
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
  // 输入/输出及副作用：source、label 为输入；返回独立 handle，不修改 source。
  // 失败/边界：source 为空返回 null；clone/cast 失败触发 UVM fatal。
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

  // 功能：绑定 Function snapshot，并可选注入 context/host-mem 后端。
  // 输入/输出及副作用：成功时保存 source 克隆与后端非拥有引用，并重置协商状态。
  // 失败/边界：source 为空、无法生成合法 Function handle 或 reset epoch 缺失时返回
  //   INVALID_ARGUMENT/INVALID_STATE；失败不替换旧 authority。
  function rdma_status configure(
    rdma_function_binding source,
    rdma_context_backing_api context_api = null,
    rdma_host_mem_api host_mem_api = null
  );
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
    if (!rdma_deep_copy#(rdma_function_binding)::try_of(source, configured))
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

  // 功能：协商 ABI 版本，仅接受版本 5。
  // 输入/输出及副作用：requested_version 为输入；response 输出 negotiated_version 快照，不创建 mapping。
  // 失败/边界：未配置 Function 返回 INVALID_STATE，版本不为 5 返回 UNSUPPORTED_OPCODE；response 保持失败默认值。
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

  // 功能：校验候选 handle 是否仍属于已保存的 UID/object/generation/reset epoch authority。
  // 输入/输出及副作用：candidate、candidate_epoch 只读；只返回状态。
  // 失败/边界：空句柄、类型错误、UID/object 不匹配返回 INVALID_ARGUMENT；generation/epoch 过期返回
  //   STALE_GENERATION；未配置返回 INVALID_STATE。
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

  // 功能：分配 ABI v5 context backing 并返回带 authority 证据的 descriptor。
  // 输入/输出及副作用：response 输出；有 context_backing 时调用 acquire 并保存返回引用，否则生成仅供仿真的合成地址。
  // 失败/边界：未协商、acquire 失败或 authority 失效时不登记 mapping，不泄漏部分资源。
  function rdma_status alloc_context(output rdma_abi_v5_response response);
    rdma_context_backing_ref context_ref;
    rdma_status status;

    response = rdma_abi_v5_response::type_id::create("abi_context_response");
    status = ready_status();
    status = normalize_status(status, "ready_status");
    if (!status.ok())
      return status;
    if (context_backing != null) begin
      context_ref = null;
      status = context_backing.acquire(binding, RDMA_RESOURCE_QP,
                                       context_id, context_ref);
      status = normalize_status(status, "context backing acquire");
      if (!status.ok()) begin
        context_ref = null;
        return status;
      end
      if (context_ref == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "context backing returned success with null reference"
        );
    end
    status = publish_mapping(RDMA_ABI_REGION_CONTEXT, 512,
                             RDMA_ABI_MAPPING_OWNED, context_ref, null,
                             response);
    status = normalize_status(status, "context mapping publish");
    if (status.ok())
      context_id++;
    return status;
  endfunction

  // 功能：以 owned backing 映射 doorbell/QP/CQ/SRQ/shadow/FWQE-SGB 区域。
  // 输入/输出及副作用：region_kind、length 为输入；response 输出 mapping descriptor，成功时推进 mapping ID。
  // 失败/边界：校验失败或 authority 过期时在调用后端前拒绝（见 validate_region、map_region_with_backing）。
  function rdma_status map_region(
    rdma_abi_v5_region_kind_e region_kind,
    longint unsigned length,
    output rdma_abi_v5_response response
  );
    return map_region_with_backing(region_kind, length,
                                   RDMA_ABI_MAPPING_OWNED, null, null,
                                   response);
  endfunction

  // 功能：映射带显式 owned/borrowed backing 的 region，供已有 host-mem/context 映射接入。
  // 输入/输出及副作用：ownership 与 borrowed_mapping/borrowed_context 为输入；成功时登记非拥有引用。
  // 失败/边界：borrowed backing 缺失或 authority 过期时在修改 mapping 表前返回错误；外部对象归调用方。
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
    status = normalize_status(status, "ready_status");
    if (!status.ok())
      return status;
    status = validate_region(region_kind, length);
    status = normalize_status(status, "region validation");
    if (!status.ok())
      return status;
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
      status = normalize_status(status, "host memory allocation");
      if (!status.ok()) begin
        mapped_dma = null;
        return status;
      end
      if (mapped_dma == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "host memory returned success with null mapping"
        );
    end
    else begin
      base.value = SYNTHETIC_BASE + next_mapping_id * 64'h10000;
    end
    status = publish_mapping(region_kind, length, ownership, null,
                             mapped_dma, response);
    return normalize_status(status, "region mapping publish");
  endfunction

  // 功能：按 mapping ID 释放 region，重复 unmap 幂等且不重复调用后端。
  // 输入/输出及副作用：成功时更新 released/refcount，并对 owned context/DMA 调用一次 release。
  // 失败/边界：未知 ID 返回 INVALID_ARGUMENT；stale 或后端释放失败保留未释放状态，可安全重试。
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
      status = normalize_status(status, "context backing release");
      if (!status.ok())
        return status;
    end
    if (record.dma_mapping != null && host_mem != null) begin
      status = host_mem.\release (record.dma_mapping);
      status = normalize_status(status, "host memory release");
      if (!status.ok())
        return status;
    end
    record.released = 1'b1;
    record.refcount = 0;
    mappings[mapping_id] = record;
    release_count++;
    return rdma_status::success();
  endfunction

  // 功能：查询 mapping ID 的当前 response 快照。
  // 输入/输出及副作用：只读内部账本，不改变引用计数或后端状态。
  // 失败/边界：未知 ID 返回 INVALID_ARGUMENT，response 保持默认值。
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

  // 功能：检查是否已完成 Function 配置与 ABI v5 协商。
  // 输入/输出及副作用：只读本地 authority/版本状态。
  // 失败/边界：缺少任一前置条件返回 INVALID_STATE；其余结果取自 validate_function。
  function automatic rdma_status ready_status();
    if (binding == null || authority_h == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ABI Function authority is not configured");
    if (negotiated_version != ABI_VERSION)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ABI v5 has not been negotiated");
    return validate_function(authority_h, authority_reset_epoch);
  endfunction

  // 功能：校验 region 类型与几何约束，避免非法 mmap 请求到达后端。
  // 输入/输出及副作用：region_kind、length 只读；返回状态，不推进 mapping ID。
  // 失败/边界：doorbell 必须恰为 8192 字节；其余区域长度非零并按 region_alignment 对齐。
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

  // 功能：返回各 ABI region 的最小对齐粒度。
  // 输入/输出及副作用：region_kind 为输入；纯值计算。
  // 失败/边界：未知枚举返回 64 字节；调用方已先经 validate_region 拒绝未知类型。
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

  // 功能：创建 mapping record、填充 response 并推进 next_mapping_id。
  // 输入/输出及副作用：区域与后端引用为输入；成功时登记新记录，失败时账本不变。
  // 失败/边界：authority 缺失返回 INVALID_STATE；mapping ID 溢出返回 RESOURCE_EXHAUSTED。
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

  // 功能：把内部 mapping record 转为 detached response 快照。
  // 输入/输出及副作用：只复制值字段并克隆后端引用，不更新账本；response 为空时先创建。
  // 失败/边界：record 为空时直接返回，不填充 response。
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

  // 功能：克隆 context backing 引用，使 response 成为 detached 快照。
  // 输入/输出及副作用：source、label 为输入；返回独立引用，不调用 release。
  // 失败/边界：source 为空返回 null；clone/cast 失败触发 UVM fatal。
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

  // 功能：克隆 host-mem mapping 引用，使读取 response 不影响内部 release authority。
  // 输入/输出及副作用：source、label 为输入；返回独立快照，不接管或释放 backing。
  // 失败/边界：source 为空返回 null；clone/cast 失败触发 UVM fatal。
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
