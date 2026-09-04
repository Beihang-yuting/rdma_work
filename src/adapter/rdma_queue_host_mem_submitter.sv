// 目录：适配器接口层 adapter/rdma_queue_host_mem_submitter.sv。
// 职责：实现 rdma_queue_host_mem_submitter 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_host_mem_submitter.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// Transactional host-memory access for XTR v1 queue entries.  Queue engines
// own slot selection and doorbells; this adapter deliberately accepts only an
// opaque allocation capability and a mapping-relative byte offset.

// 功能：在 rdma_queue_host_mem_submitter 中，rdma_hw_host_mem_release 按 owner、generation 和幂等规则释放或清理资源，同时删除相关账本记录。
// 输入/输出及副作用：api（输入）、mapping（输入）；rdma_hw_host_mem_release 读取 api、mapping 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_hw_host_mem_release 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“host memory adapter is null”；失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_hw_host_mem_release(
    rdma_host_mem_api api,
    rdma_dma_mapping mapping
  );
    if (api == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "host memory adapter is null");
    return api.\release (mapping);
  endfunction

class rdma_queue_host_mem_target extends uvm_object;
  `uvm_object_utils(rdma_queue_host_mem_target)

  // The capability is intentionally not an allocation address or a mapping.
  // It is used only by the submitter to find its private ledger entry.
  local string capability;
  local static longint unsigned next_capability;

  // 功能：构造 rdma_queue_host_mem_target，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：next_capability=1；capability=$sformatf("queue-target-%0d", next_capability)。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_host_mem_target 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_host_mem_target");
    super.new(name);
    if (next_capability == 0)
      next_capability = 1;
    capability = $sformatf("queue-target-%0d", next_capability);
    next_capability++;
  endfunction

  // Exposes no mapping or address; callers can only present this opaque token
  // back to a submitter instance.
  // 功能：在 rdma_queue_host_mem_target 中，capability_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：无显式参数；capability_key 读取固定返回值或局部计算结果，不使用对象成员字段；函数返回 string，不取得调用方资源所有权。
// 失败/边界：capability_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  function string capability_key();
    return capability;
  endfunction
endclass

class rdma_queue_host_mem_ledger_entry extends uvm_object;
  `uvm_object_utils(rdma_queue_host_mem_ledger_entry)

  rdma_dma_mapping mapping;
  rdma_dma_mapping release_authority;
  rdma_dma_request_context request_context;
  rdma_dma_direction_e direction;
  rdma_dma_permission_t permissions;
  bit released;

  // 功能：构造 rdma_queue_host_mem_ledger_entry，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：mapping=null；release_authority=null；request_context=null；direction=RDMA_DMA_DEVICE_READ；permissions='0；released=1'b0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_host_mem_ledger_entry 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_host_mem_ledger_entry");
    super.new(name);
    mapping = null;
    release_authority = null;
    request_context = null;
    direction = RDMA_DMA_DEVICE_READ;
    permissions = '0;
    released = 1'b0;
  endfunction
endclass

class rdma_queue_host_mem_submitter extends uvm_object;
  `uvm_object_utils(rdma_queue_host_mem_submitter)

  rdma_host_mem_api host_mem;
  rdma_codec_registry registry;

  // The mapping and all authority snapshots are retained only here.  A
  // target contains no public reference to this ledger or to backing memory.
  protected rdma_queue_host_mem_ledger_entry ledger[string];

  // 功能：构造 rdma_queue_host_mem_submitter，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：host_mem=null；registry=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_host_mem_submitter 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_host_mem_submitter");
    super.new(name);
    host_mem = null;
    registry = null;
    ledger.delete();
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter 中，invalid 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；invalid 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter 中，state_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；state_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：state_error 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status state_error(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter 中，codec_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；codec_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：codec_error 返回 RDMA_SC_CODEC_ERROR；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：status_or 按函数体读取当前字段并生成 rdma_status 结果，供调用方进行诊断或分支决策；不修改外部资源。
  // 输入/输出及副作用：status（输入）、fallback_code（输入）、fallback_message（输入）；status_or 读取 status、fallback_code、fallback_message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：枚举未定义或对象未配置时返回 UNKNOWN/UNCONFIGURED 表示，同时保留数值上下文。
  protected function rdma_status status_or(
    rdma_status status,
    rdma_status_code_e fallback_code,
    string fallback_message
  );
    if (status != null)
      return status;
    return rdma_status::make(fallback_code, fallback_message);
  endfunction

  // 功能：将 rhs 中 rdma_queue_host_mem_submitter 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、result（输出）；clone_context 读取 source、result 并使用字段 result、cloned，并写入 result；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_context 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“DMA request context clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：mapping_identity_status 校验 mapping、request_ctx、requested_size、requested_alignment、requested_direction 与当前对象状态的一致性，并显式处理“host memory adapter returned a null mapping”；“host memory adapter returned an inactive mapping”；“DMA mapping or request Function is null”；“DMA mapping has zero size”；“DMA mapping Function identity mismatch”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：mapping（输入）、request_ctx（输入）、requested_size（输入）、requested_alignment（输入）、requested_direction（输入）；mapping_identity_status 读取 mapping、request_ctx、requested_size、requested_alignment、requested_direction 并使用字段 mapping_last；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：mapping_identity_status 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_DMA_PERMISSION；典型拒绝条件为“DMA mapping Function identity mismatch”“DMA mapping requester BDF mismatch”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_host_mem_submitter 中，lookup_target 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：target（输入）、entry（输出）；lookup_target 读取 target、entry 并使用字段 entry、key，并写入 entry；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：lookup_target 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_status lookup_target(
    rdma_queue_host_mem_target target,
    output rdma_queue_host_mem_ledger_entry entry
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

  // 功能：validate_range 校验 entry、offset、length、requested_direction、requested_permissions 与当前对象状态的一致性，并显式处理“queue host-memory target entry is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：entry（输入）、offset（输入）、length（输入）、requested_direction（输入）、requested_permissions（输入）；validate_range 读取 entry、offset、length、requested_direction、requested_permissions 并使用字段 first_iova.value、status；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：validate_range 返回 RDMA_SC_DMA_TRANSLATION；具体拒绝条件包括 “queue host-memory target entry is invalid”；“queue host-memory target is released”；“queue host-memory access length is zero”；“queue host-memory access offset overflows”；“queue host-memory IOVA calculation overflows”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status validate_range(
    rdma_queue_host_mem_ledger_entry entry,
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

  // 功能：在 rdma_queue_host_mem_submitter 中，lookup_queue_codec 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：image_kind（输入）、object_type（输入）、variant（输入）、codec（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为
  //   detached 快照，读取不取得外部资源所有权。
  // 失败/边界：lookup_queue_codec 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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
    key.hw_version = "rdma";
    key.image_kind = image_kind;
    key.object_type = object_type;
    key.variant = variant;
    key.opcode = 8'h00;
    status = registry.lookup(key, codec);
    return status_or(status, RDMA_SC_UNSUPPORTED_OPCODE,
                     "queue codec lookup returned null");
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter 中，image_to_array 从输入 image/bytes 按固定 offset 提取字段，交付解码所需的值。
  // 输入/输出及副作用：image（输入）、write_data（输出）；image_to_array 读取 image、write_data 并使用字段 write_data，并写入 write_data；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：image_to_array 返回 RDMA_SC_CODEC_ERROR；典型拒绝条件为“encoded queue image is malformed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_host_mem_submitter 中，complete_read_image 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：entry（输入）、offset（输入）、image_length（输入）、image_kind（输入）、codec（输入）、image（输出）；complete_read_image 读取 entry、offset、image_length、image_kind、codec、image 并使用字段 image、status、read_data、candidate、candidate.length、candidate.alignment、candidate.endian、candidate.image_kind，并写入 image；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：complete_read_image 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_CODEC_ERROR；具体拒绝条件包括 “host memory completion read returned a short image”；“completion image allocation failed”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status complete_read_image(
    rdma_queue_host_mem_ledger_entry entry,
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
    candidate.hardware_version = RDMA_HW_VERSION;
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

  // 功能：在 rdma_queue_host_mem_submitter 中，allocate_target 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：request_context（输入）、size（输入）、alignment（输入）、direction（输入）、target（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output
  //   发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  function rdma_status allocate_target(
    rdma_dma_request_context request_context,
    int unsigned size,
    int unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_queue_host_mem_target target
  );
    rdma_status status;
    rdma_status release_status;
    rdma_dma_mapping mapping;
    rdma_dma_mapping authority;
    rdma_dma_request_context context_snapshot;
    rdma_queue_host_mem_target candidate;
    rdma_queue_host_mem_ledger_entry entry;

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
        release_status = rdma_hw_host_mem_release(host_mem, mapping);
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
      release_status = rdma_hw_host_mem_release(host_mem, mapping);
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
      release_status = rdma_hw_host_mem_release(host_mem, mapping);
      return status;
    end
    status = clone_context(request_context, context_snapshot);
    if (!status.ok()) begin
      release_status = rdma_hw_host_mem_release(host_mem, mapping);
      return status;
    end

    candidate = rdma_queue_host_mem_target::type_id::create(
      "queue_host_mem_target");
    entry = rdma_queue_host_mem_ledger_entry::type_id::create(
      "queue_host_mem_ledger_entry");
    if (candidate == null || entry == null) begin
      release_status = rdma_hw_host_mem_release(host_mem, mapping);
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

  // 功能：在 rdma_queue_host_mem_submitter 中，write_queue_entry 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：target（输入）、offset（输入）、model（输入）、image_kind（输入）、variant（输入）、expected_length（输入）、image（输出）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：write_queue_entry 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  protected function rdma_status write_queue_entry(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    rdma_hw_model model,
    rdma_image_kind_e image_kind,
    string variant,
    int unsigned expected_length,
    output rdma_hw_image image
  );
    rdma_queue_host_mem_ledger_entry entry;
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
        candidate.hardware_version != RDMA_HW_VERSION ||
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
    readback_image.hardware_version = RDMA_HW_VERSION;
    readback_image.function_generation = candidate.function_generation;
    status = codec.validate_image(readback_image);
    if (!status.ok())
      return status;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter 中，write_sqe 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：target（输入）、offset（输入）、model（输入）、image（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或
  //   pending journal，并通过 output 返回结果。
  // 失败/边界：write_sqe 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  function rdma_status write_sqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    rdma_hw_sqe_model model,
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
                             RDMA_WQE_BYTES, image);
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter 中，write_rqe 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：target（输入）、offset（输入）、model（输入）、image（输出）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或
  //   pending journal，并通过 output 返回结果。
  // 失败/边界：write_rqe 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  function rdma_status write_rqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    rdma_hw_rqe_model model,
    output rdma_hw_image image
  );
    if (model == null)
      begin image = null; return invalid("RQE model is null"); end
    return write_queue_entry(target, offset, model, RDMA_IMAGE_RQE, "default",
                             RDMA_RQE_BYTES, image);
  endfunction

  // 功能：在 rdma_queue_host_mem_submitter 中，read_cqe 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：target（输入）、offset（输入）、model（输出）、image（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：read_cqe 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function rdma_status read_cqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_hw_cqe_model model,
    output rdma_hw_image image
  );
    return read_cqe_sized(target, offset, RDMA_CQE_BYTES, model, image);
  endfunction

  // 功能：按运行时 CQE entry 大小读取并解码 CQE，供 32/64/128B CQ ring 共用。
  // 输入输出及副作用：target/offset/entry_size 为输入，model/image 为输出；仅读取 host memory ledger。
  // 失败边界：entry_size 不是 32/64/128、映像长度不匹配或 codec 解码失败时不发布 model/image。
  function rdma_status read_cqe_sized(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    int unsigned entry_size,
    output rdma_hw_cqe_model model,
    output rdma_hw_image image
  );
    rdma_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    if (!(entry_size inside {32,64,128}))
      return invalid("CQE profile size is invalid");
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_CQE, "cqe", "default", codec);
    if (!status.ok()) return status;
    begin
      rdma_hw_cqe_codec cqe_codec;
      if ($cast(cqe_codec, codec)) begin
        status = cqe_codec.set_entry_bytes(entry_size);
        if (!status.ok()) return status;
      end
    end
    status = complete_read_image(entry, offset, entry_size,
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

  // 功能：在 rdma_queue_host_mem_submitter 中，read_ceqe 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：target（输入）、offset（输入）、model（输出）、image（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：read_ceqe 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function rdma_status read_ceqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_hw_ceqe_model model,
    output rdma_hw_image image
  );
    rdma_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_CEQE, "ceqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, RDMA_CEQE_BYTES,
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

  // 功能：在 rdma_queue_host_mem_submitter 中，read_aeqe 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：target（输入）、offset（输入）、model（输出）、image（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：read_aeqe 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function rdma_status read_aeqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_hw_aeqe_model model,
    output rdma_hw_image image
  );
    rdma_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null; image = null;
    status = lookup_target(target, entry); if (!status.ok()) return status;
    status = lookup_queue_codec(RDMA_IMAGE_AEQE, "aeqe", "default", codec);
    if (!status.ok()) return status;
    status = complete_read_image(entry, offset, RDMA_AEQE_BYTES,
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

  // 功能：在 rdma_queue_host_mem_submitter 中，release_target 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：target（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_target 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function rdma_status release_target(
    rdma_queue_host_mem_target target
  );
    rdma_queue_host_mem_ledger_entry entry;
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
    status = rdma_hw_host_mem_release(host_mem, entry.mapping);
    status = status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory release returned null status");
    if (!status.ok())
      return status;
    entry.released = 1'b1;
    return rdma_status::success();
  endfunction
endclass
