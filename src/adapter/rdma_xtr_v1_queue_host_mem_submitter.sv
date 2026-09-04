// 目录：适配器接口层 adapter/rdma_xtr_v1_queue_host_mem_submitter.sv。
// 职责：实现 rdma_xtr_v1_queue_host_mem_submitter 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_xtr_v1_queue_host_mem_submitter.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// Transactional host-memory access for XTR v1 queue entries.  Queue engines
// own slot selection and doorbells; this adapter deliberately accepts only an
// opaque allocation capability and a mapping-relative byte offset.

  // 功能：处理 rdma_xtr_v1_host_mem_release：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 api, mapping 用于执行 rdma_xtr_v1_host_mem_release；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：rdma_xtr_v1_host_mem_release 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
function automatic rdma_status rdma_xtr_v1_host_mem_release(
    rdma_host_mem_api api,
    rdma_dma_mapping mapping
  );
    if (api == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "host memory adapter is null");
    return api.\release (mapping);
  endfunction

class rdma_xtr_v1_queue_host_mem_target extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_host_mem_target)

  // The capability is intentionally not an allocation address or a mapping.
  // It is used only by the submitter to find its private ledger entry.
  local string capability;
  local static longint unsigned next_capability;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_queue_host_mem_target");
    super.new(name);
    if (next_capability == 0)
      next_capability = 1;
    capability = $sformatf("queue-target-%0d", next_capability);
    next_capability++;
  endfunction

  // Exposes no mapping or address; callers can only present this opaque token
  // back to a submitter instance.
  // 功能：处理 capability_key：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 capability 用于执行 capability_key；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：capability_key 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  function string capability_key();
    return capability;
  endfunction
endclass

class rdma_xtr_v1_queue_host_mem_ledger_entry extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_host_mem_ledger_entry)

  rdma_dma_mapping mapping;
  rdma_dma_mapping release_authority;
  rdma_dma_request_context request_context;
  rdma_dma_direction_e direction;
  rdma_dma_permission_t permissions;
  bit released;

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_queue_host_mem_ledger_entry");
    super.new(name);
    mapping = null;
    release_authority = null;
    request_context = null;
    direction = RDMA_DMA_DEVICE_READ;
    permissions = '0;
    released = 1'b0;
  endfunction
endclass

class rdma_xtr_v1_queue_host_mem_submitter extends uvm_object;
  `uvm_object_utils(rdma_xtr_v1_queue_host_mem_submitter)

  rdma_host_mem_api host_mem;
  rdma_codec_registry registry;

  // The mapping and all authority snapshots are retained only here.  A
  // target contains no public reference to this ledger or to backing memory.
  protected rdma_xtr_v1_queue_host_mem_ledger_entry ledger[string];

  // 功能：构造当前对象并初始化其字段、集合和 UVM 名称；不接管传入句柄的生命周期。
  // 输入/输出及副作用：name 仅用于 UVM 对象命名；内部字段被初始化为安全默认值，传入句柄不转移所有权。
  //   返回新对象实例；构造失败由 UVM 工厂或调用方处理。
  // 失败/边界：不创建外部资源；name 为空时仍允许构造，但所有字段必须保持可配置的初始值。
  function new(string name = "rdma_xtr_v1_queue_host_mem_submitter");
    super.new(name);
    host_mem = null;
    registry = null;
    ledger.delete();
  endfunction

  // 功能：处理 invalid：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 message 用于执行 invalid；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：invalid 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：处理 state_error：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 message 用于执行 state_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：state_error 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status state_error(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：处理 codec_error：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 message 用于执行 codec_error；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：codec_error 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：将当前对象的类型、状态或关键标识转换为调用方可消费的值，不产生外部副作用。
  // 输入/输出及副作用：输入为当前对象状态；返回字符串、枚举或只读派生值，不修改对象。
  //   对象未配置时返回可识别的 UNKNOWN/UNCONFIGURED 表示。
  // 失败/边界：未配置或字段无效时返回明确的 UNKNOWN 表示，不读取未初始化句柄。
  protected function rdma_status status_or(
    rdma_status status,
    rdma_status_code_e fallback_code,
    string fallback_message
  );
    if (status != null)
      return status;
    return rdma_status::make(fallback_code, fallback_message);
  endfunction

  // 功能：从源对象复制可变字段并生成独立值快照；源对象保持不变，类型不匹配时报告复制错误。
  // 输入/输出及副作用：source/rhs 是源对象；返回或写入独立副本，不修改源对象。
  //   source/rhs 为空或类型不匹配时返回空值或触发既定复制错误。
  // 失败/边界：空源对象不应解引用；类型不匹配必须拒绝复制或按既定 UVM 规则报告 fatal。
  protected function rdma_status clone_context(
    rdma_dma_request_context source,
    output rdma_dma_request_context result
  );
    uvm_object cloned;

    result = null;
    if (source == null)
      return invalid("DMA request context is null");
    cloned = source.clone();
    if (cloned == null || !$cast(result, cloned))
      return state_error("DMA request context clone failed");
    return rdma_status::success();
  endfunction

  // 功能：处理 mapping_identity_status：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 mapping, request_ctx, requested_size, requested_alignment, requested_direction 用于执行 mapping_identity_status；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：mapping_identity_status 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status mapping_identity_status(
    rdma_dma_mapping mapping,
    rdma_dma_request_context request_ctx,
    int unsigned requested_size,
    int unsigned requested_alignment,
    rdma_dma_direction_e requested_direction
  );
    longint unsigned mapping_last;

    if (mapping == null)
      return invalid("host memory adapter returned a null mapping");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return state_error("host memory adapter returned an inactive mapping");
    if (mapping.function_h == null || request_ctx.function_h == null)
      return state_error("DMA mapping or request Function is null");
    if (!mapping.function_h.same_instance(request_ctx.function_h))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping Function identity mismatch");
    if (mapping.requester_bdf != request_ctx.requester_bdf)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping requester BDF mismatch");
    if (mapping.pasid_valid != request_ctx.pasid_valid ||
        mapping.pasid != request_ctx.pasid)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping PASID identity mismatch");
    if (mapping.dma_domain_valid != request_ctx.dma_domain_valid ||
        mapping.dma_domain_id != request_ctx.dma_domain_id)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping domain identity mismatch");
    if (requested_size == 0 || mapping.size != requested_size)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping size does not match allocation");
    if (requested_alignment == 0 ||
        (mapping.iova.value & (requested_alignment - 1'b1)) != 0)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping IOVA does not satisfy alignment");
    if (mapping.direction != requested_direction)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping direction does not match allocation");
    if (requested_direction == RDMA_DMA_DEVICE_READ &&
        !mapping.permissions.device_read)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping lacks device-read permission");
    if (requested_direction == RDMA_DMA_DEVICE_WRITE &&
        !mapping.permissions.device_write)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping lacks device-write permission");
    if (requested_direction == RDMA_DMA_BIDIRECTIONAL &&
        (!mapping.permissions.device_read || !mapping.permissions.device_write))
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                                "DMA mapping lacks bidirectional permissions");
    if (mapping.size == 0)
      return state_error("DMA mapping has zero size");
    if (mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - (mapping.size - 1'b1)))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping range overflows 64 bits");
    mapping_last = mapping.iova.value + mapping.size - 1'b1;
    if (mapping_last < mapping.iova.value)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "DMA mapping range wraps");
    return rdma_status::success();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  protected function rdma_status lookup_target(
    rdma_xtr_v1_queue_host_mem_target target,
    output rdma_xtr_v1_queue_host_mem_ledger_entry entry
  );
    string key;

    entry = null;
    if (target == null)
      return invalid("queue host-memory target is null");
    key = target.capability_key();
    if (key.len() == 0 || !ledger.exists(key) || ledger[key] == null)
      return invalid("queue host-memory target is foreign or unknown");
    entry = ledger[key];
    if (entry.mapping == null || entry.release_authority == null)
      return state_error("queue host-memory target ledger is malformed");
    return rdma_status::success();
  endfunction

  // 功能：检查输入字段、身份和生命周期约束，返回可诊断的校验状态；失败时不提交部分更新。
  // 输入/输出及副作用：输入为待校验字段或快照；返回 rdma_status，校验过程不提交资源和游标。
  //   空依赖、非法范围、身份不一致或非活动状态会返回错误。
  // 失败/边界：任何非法枚举、越界字段、缺失必需依赖或身份/代际不一致都必须返回非成功状态。
  protected function rdma_status validate_range(
    rdma_xtr_v1_queue_host_mem_ledger_entry entry,
    longint unsigned offset,
    int unsigned length,
    rdma_dma_direction_e requested_direction,
    rdma_dma_permission_t requested_permissions
  );
    rdma_iova_t first_iova;
    rdma_status status;

    if (entry == null || entry.mapping == null || entry.request_context == null)
      return state_error("queue host-memory target entry is invalid");
    if (entry.released || entry.mapping.state != RDMA_MAPPING_ACTIVE)
      return state_error("queue host-memory target is released");
    if (length == 0)
      return invalid("queue host-memory access length is zero");
    if (offset > (64'hffff_ffff_ffff_ffff - (longint'(length) - 1'b1)))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "queue host-memory access offset overflows");
    if (offset > (64'hffff_ffff_ffff_ffff - entry.mapping.iova.value))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "queue host-memory IOVA calculation overflows");
    first_iova.value = entry.mapping.iova.value + offset;
    status = entry.mapping.check_access(
      entry.request_context.function_h,
      entry.request_context.requester_bdf,
      entry.request_context.pasid_valid,
      entry.request_context.pasid,
      entry.request_context.dma_domain_valid,
      entry.request_context.dma_domain_id,
      first_iova,
      length,
      requested_direction,
      requested_permissions
    );
    return status_or(status, RDMA_SC_DMA_TRANSLATION,
                     "DMA mapping access check returned null");
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  protected function rdma_status lookup_queue_codec(
    rdma_image_kind_e image_kind,
    string object_type,
    string variant,
    output rdma_codec_base codec
  );
    rdma_codec_key key;
    rdma_status status;

    codec = null;
    if (registry == null)
      return state_error("queue codec registry is not configured");
    key.hw_version = "xtr_v1";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = variant;
    key.opcode = 8'h00;
    status = registry.lookup(key, codec);
    return status_or(status, RDMA_SC_UNSUPPORTED_OPCODE,
                     "queue codec lookup returned null");
  endfunction

  // 功能：处理 image_to_array：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 image, write_data 用于执行 image_to_array；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：image_to_array 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status image_to_array(
    rdma_hw_image image,
    output byte write_data[]
  );
    write_data = new[0];
    if (image == null || image.length != image.bytes.size() ||
        image.length == 0)
      return codec_error("encoded queue image is malformed");
    write_data = new[image.bytes.size()];
    foreach (write_data[i])
      write_data[i] = image.bytes[i];
    return rdma_status::success();
  endfunction

  // 功能：处理 complete_read_image：依据其参数完成所属层的具体协议动作，并保持返回状态、游标和资源所有权一致。
  // 输入/输出及副作用：参数 entry, offset, image_length, image_kind, codec, image 用于执行 complete_read_image；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：complete_read_image 只接受其签名声明的输入；缺少必要字段时返回错误，成功路径不得隐式修改无关资源。
  protected function rdma_status complete_read_image(
    rdma_xtr_v1_queue_host_mem_ledger_entry entry,
    longint unsigned offset,
    int unsigned image_length,
    rdma_image_kind_e image_kind,
    rdma_codec_base codec,
    output rdma_hw_image image
  );
    byte read_data[];
    byte unsigned image_bytes[];
    rdma_status status;
    rdma_hw_image candidate;

    image = null;
    status = validate_range(entry, offset, image_length,
                            RDMA_DMA_DEVICE_WRITE,
                            '{device_read:1'b0, device_write:1'b1,
                              atomic:1'b0});
    if (!status.ok())
      return status;
    read_data = new[0];
    status = host_mem.read(entry.mapping, offset, image_length, read_data);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory read returned null");
    if (!status.ok())
      return status;
    if (read_data.size() != image_length)
      return codec_error("host memory completion read returned a short image");

    candidate = rdma_hw_image::type_id::create("queue_completion_image");
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "completion image allocation failed");
    candidate.bytes.delete();
    foreach (read_data[i])
      candidate.bytes.push_back(read_data[i]);
    candidate.length = image_length;
    candidate.alignment = image_length;
    candidate.endian = RDMA_ENDIAN_BIG;
    candidate.image_kind = image_kind;
    candidate.hardware_version = XTR_V1_HW_VERSION;
    candidate.function_generation =
      entry.request_context.function_h.generation;
    candidate.write_target_kind = RDMA_HW_TARGET_NONE;
    candidate.backing_target = '0;
    candidate.hmc_target = '0;
    candidate.bar_target = '0;
    image_bytes = new[image_length];
    foreach (image_bytes[i])
      image_bytes[i] = candidate.bytes[i];
    status = codec.validate_image(candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue completion image validation returned null");
    if (!status.ok())
      return status;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：检查可用容量并预留所需资源，返回带所有权证据的分配结果；容量不足时不留下部分分配。
  // 输入/输出及副作用：输入请求、容量和依赖用于构造/预留资源；返回独立对象或状态，不暴露内部可变集合。
  //   参数越界、容量不足或构造中途失败时回滚已登记的局部状态。
  // 失败/边界：依赖为空、参数越界、容量不足或构造步骤失败时清理局部结果并返回明确错误。
  function rdma_status allocate_target(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_xtr_v1_queue_host_mem_target target
  );
    rdma_status status;
    rdma_status release_status;
    rdma_dma_mapping mapping;
    rdma_dma_mapping authority;
    rdma_dma_request_context context_snapshot;
    rdma_xtr_v1_queue_host_mem_target candidate;
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;

    target = null;
    if (host_mem == null)
      return state_error("queue host-memory adapter is not configured");
    if (request_context == null)
      return invalid("DMA request context is null");
    status = request_context.validate();
    if (!status.ok())
      return status;
    if (size == 0 || alignment == 0 ||
        (alignment & (alignment - 1'b1)) != 0)
      return invalid("allocation size/alignment is invalid");
    if (!(direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_DEVICE_WRITE,
                            RDMA_DMA_BIDIRECTIONAL}))
      return invalid("allocation DMA direction is invalid");

    mapping = null;
    status = host_mem.allocate(request_context, size, alignment, direction,
                               mapping);
    if (status == null || !status.ok()) begin
      // A defensive adapter may return a live mapping together with a
      // failure status.  Treat that as a post-allocation failure and make the
      // single cleanup attempt before returning the allocation error.
      if (mapping != null)
        release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      return status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory allocation returned null status");
    end
    if (!status.ok())
      return status;
    status = mapping_identity_status(mapping, request_context, size,
                                     alignment, direction);
    if (!status.ok()) begin
      // An adapter may have returned a mapping with malformed identity.  It
      // is still released exactly once before the failed allocation exits.
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      if (release_status == null || !release_status.ok())
        return status;
      return status;
    end
    authority = null;
    status = mapping.snapshot_release_authority(authority);
    status = status_or(status, RDMA_SC_INVALID_STATE,
                       "DMA mapping authority snapshot returned null");
    if (status.ok() && authority == null)
      status = state_error("DMA mapping authority snapshot returned null");
    if (!status.ok()) begin
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      return status;
    end
    status = clone_context(request_context, context_snapshot);
    if (!status.ok()) begin
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      return status;
    end

    candidate = rdma_xtr_v1_queue_host_mem_target::type_id::create(
      "queue_host_mem_target");
    entry = rdma_xtr_v1_queue_host_mem_ledger_entry::type_id::create(
      "queue_host_mem_ledger_entry");
    if (candidate == null || entry == null) begin
      release_status = rdma_xtr_v1_host_mem_release(host_mem, mapping);
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue host-memory target creation failed");
    end
    entry.mapping = mapping;
    entry.release_authority = authority;
    entry.request_context = context_snapshot;
    entry.direction = direction;
    entry.permissions.device_read =
      direction inside {RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL};
    entry.permissions.device_write =
      direction inside {RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL};
    entry.permissions.atomic = 1'b0;
    entry.released = 1'b0;
    ledger[candidate.capability_key()] = entry;
    target = candidate;
    return rdma_status::success();
  endfunction

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 target, offset, model, image_kind, variant, expected_length, image 用于执行 write_queue_entry；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  protected function rdma_status write_queue_entry(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_hw_model model,
    rdma_image_kind_e image_kind,
    string variant,
    int unsigned expected_length,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_image candidate;
    rdma_hw_image readback_image;
    rdma_status status;
    byte write_data[];
    byte read_data[];

    image = null;
    status = lookup_target(target, entry);
    if (!status.ok())
      return status;
    status = lookup_queue_codec(image_kind, "sqe", variant, codec);
    if (image_kind == RDMA_IMAGE_RQE)
      status = lookup_queue_codec(image_kind, "rqe", "default", codec);
    if (!status.ok())
      return status;
    candidate = null;
    status = codec.encode(model, candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue codec encode returned null status");
    if (!status.ok())
      return status;
    if (candidate == null || candidate.length != expected_length ||
        candidate.bytes.size() != expected_length ||
        candidate.alignment != expected_length ||
        candidate.endian != RDMA_ENDIAN_BIG ||
        candidate.image_kind != image_kind ||
        candidate.hardware_version != XTR_V1_HW_VERSION ||
        candidate.write_target_kind != RDMA_HW_TARGET_NONE ||
        candidate.backing_target.value != 0 ||
        candidate.hmc_target.value != 0 || candidate.bar_target.value != 0 ||
        candidate.function_generation !=
          entry.request_context.function_h.generation)
      return codec_error("queue codec returned an image of the wrong size");
    status = codec.validate_image(candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue codec image validation returned null");
    if (!status.ok())
      return status;
    status = validate_range(entry, offset, expected_length,
                            RDMA_DMA_DEVICE_READ,
                            '{device_read:1'b1, device_write:1'b0,
                              atomic:1'b0});
    if (!status.ok())
      return status;
    status = image_to_array(candidate, write_data);
    if (!status.ok())
      return status;
    status = host_mem.write(entry.mapping, offset, write_data);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory write returned null status");
    if (!status.ok())
      return status;
    read_data = new[0];
    status = host_mem.read(entry.mapping, offset, expected_length, read_data);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory readback returned null status");
    if (!status.ok())
      return status;
    if (read_data.size() != expected_length)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                "queue host-memory readback is short");
    foreach (read_data[i]) begin
      if (read_data[i] !== write_data[i])
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                  "queue host-memory readback mismatch");
    end
    // Validate the readback image too.  This catches an adapter that returns
    // bytes with malformed metadata or a codec image that was not detached.
    readback_image = rdma_hw_image::type_id::create("queue_readback_image");
    readback_image.bytes.delete();
    foreach (read_data[i])
      readback_image.bytes.push_back(read_data[i]);
    readback_image.length = expected_length;
    readback_image.alignment = expected_length;
    readback_image.endian = RDMA_ENDIAN_BIG;
    readback_image.image_kind = image_kind;
    readback_image.hardware_version = XTR_V1_HW_VERSION;
    readback_image.function_generation = candidate.function_generation;
    status = codec.validate_image(readback_image);
    if (!status.ok())
      return status;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 target, offset, model, image 用于执行 write_sqe；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  function rdma_status write_sqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_xtr_v1_sqe_model model,
    output rdma_hw_image image
  );
    string variant;
    if (model == null)
      begin image = null; return invalid("SQE model is null"); end
    case (model.transport)
      RDMA_TRANSPORT_RC: variant = "rc";
      RDMA_TRANSPORT_UD: variant = "ud";
      RDMA_TRANSPORT_URC: variant = "urc";
      default: begin image = null; return invalid("SQE transport is unsupported"); end
    endcase
    return write_queue_entry(target, offset, model, RDMA_IMAGE_SQE, variant,
                             XTR_V1_WQE_BYTES, image);
  endfunction

  // 功能：向指定后端写入请求数据并保留返回状态；写入失败时不推进本地提交游标。
  // 输入/输出及副作用：参数 target, offset, model, image 用于执行 write_rqe；返回值或 output/inout 交付处理结果，必要时更新本对象状态。
  //   调用方不获得内部集合或外部依赖的所有权。
  // 失败/边界：后端拒绝或写入范围越界时不推进本地提交游标，也不伪造成功状态。
  function rdma_status write_rqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    rdma_xtr_v1_rqe_model model,
    output rdma_hw_image image
  );
    if (model == null)
      begin image = null; return invalid("RQE model is null"); end
    return write_queue_entry(target, offset, model, RDMA_IMAGE_RQE, "default",
                             XTR_V1_RQE_BYTES, image);
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_status read_cqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_cqe_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_CQE, "cqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, XTR_V1_CQE_BYTES,
                                 RDMA_IMAGE_CQE, codec,
                                 candidate_image);
    if (!status.ok()) return status;
    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "CQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null; image = null;
      return status.ok() ? codec_error("decoded CQE model type mismatch") : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_status read_ceqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_ceqe_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_CEQE, "ceqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, XTR_V1_CEQE_BYTES,
                                 RDMA_IMAGE_CEQE, codec,
                                 candidate_image);
    if (!status.ok()) return status;
    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "CEQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null; image = null;
      return status.ok() ? codec_error("decoded CEQE model type mismatch") : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  // 功能：按输入的完整标识查询当前权威记录并返回独立快照；缺失、歧义或代际过期时返回明确错误。
  // 输入/输出及副作用：输入为完整 key/handle，output 或返回值为记录快照；查询不改变登记表和外部资源。
  //   缺失、歧义、空句柄或旧 generation/reset epoch 返回明确错误。
  // 失败/边界：查询不到唯一记录、输入为空或 authority 已失效时返回错误，不回退到默认 Function/root。
  function rdma_status read_aeqe(
    rdma_xtr_v1_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_xtr_v1_aeqe_model model,
    output rdma_hw_image image
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_AEQE, "aeqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, XTR_V1_AEQE_BYTES,
                                 RDMA_IMAGE_AEQE, codec,
                                 candidate_image);
    if (!status.ok()) return status;
    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "AEQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null; image = null;
      return status.ok() ? codec_error("decoded AEQE model type mismatch") : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  // 功能：按资源所有权和幂等规则释放或清理记录；重复释放不会再次扣减 credit，也不触碰已隔离资源。
  // 输入/输出及副作用：输入为待解除或释放的 handle/key；成功后隔离或删除本对象记录，外部拥有者仍负责真正销毁。
  //   空值、未知记录或重复调用按接口约定返回错误或幂等成功。
  // 失败/边界：不得释放非本对象所有资源；重复解除按幂等约定处理，旧 handle 不得重新激活。
  function rdma_status release_target(
    rdma_xtr_v1_queue_host_mem_target target
  );
    rdma_xtr_v1_queue_host_mem_ledger_entry entry;
    rdma_status status;

    status = lookup_target(target, entry);
    if (!status.ok())
      return status;
    if (entry.released)
      return state_error("queue host-memory target was already released");
    status = entry.mapping.release_authority_status(entry.release_authority);
    status = status_or(status, RDMA_SC_INVALID_STATE,
                       "DMA release authority check returned null");
    if (!status.ok())
      return status;
    status = rdma_xtr_v1_host_mem_release(host_mem, entry.mapping);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory release returned null status");
    if (!status.ok())
      return status;
    entry.released = 1'b1;
    return rdma_status::success();
  endfunction
endclass
