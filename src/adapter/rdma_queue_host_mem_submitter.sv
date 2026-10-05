// 目录：适配器接口层 adapter/rdma_queue_host_mem_submitter.sv。
// 职责：实现 rdma_queue_host_mem_submitter 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// XTR v1 queue entry 的事务性 host-memory 访问：queue engine 负责槽位选择与 doorbell，
// 本 adapter 只接受 opaque allocation capability 和 mapping 内字节偏移。

// 功能：通过 host-memory adapter 严格释放已验证的 mapping。
// 输入/输出及副作用：api、mapping 输入；调用 api.release，返回其状态。
// 失败/边界：api 为 null 返回 INVALID_STATE；调用方须先完成 release-authority 校验。
function automatic rdma_status rdma_hw_host_mem_release(
    rdma_host_mem_api api,
    rdma_dma_mapping mapping
  );
    if (api == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "host memory adapter is null");
    return api.\release (mapping);
  endfunction

// 功能：allocate_target 失败路径回滚尚未登记到 ledger 的 mapping（用 adapter 内部 opaque identity）。
// 输入/输出及副作用：api、mapping 输入；只释放本次候选 backing，不改 submitter ledger。
// 失败/边界：mapping 的 route/geometry/owner 可能正是失败原因，故不走严格 release()；
//   api 为空或 opaque token 无效时返回错误，调用方保留原始失败证据。
function automatic rdma_status rdma_hw_host_mem_rollback(
    rdma_host_mem_api api,
    rdma_dma_mapping mapping
  );
    if (api == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "host memory adapter is null");
    return api.release_opaque(mapping);
  endfunction

class rdma_queue_host_mem_target extends uvm_object;
  `uvm_object_utils(rdma_queue_host_mem_target)

  // capability 刻意不是地址或 mapping，仅供 submitter 查找私有 ledger 记录。
  local string capability;
  local static longint unsigned next_capability;

  // 功能：构造 target，分配全局递增的 opaque capability 字符串。
  // 输入/输出及副作用：name 输入；next_capability 为 0 时置 1，写 capability 后自增。
  // 失败/边界：无。
  function new(string name = "rdma_queue_host_mem_target");
    super.new(name);
    if (next_capability == 0)
      next_capability = 1;
    capability = $sformatf("queue-target-%0d", next_capability);
    next_capability++;
  endfunction

  // 功能：返回 opaque capability；不暴露 mapping 或地址，只能交回 submitter 查找 ledger。
  // 输入/输出及副作用：无输入；只读 capability。
  // 失败/边界：无。
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

  // 功能：构造 ledger 记录并清空 mapping/authority/context 与 released 标志。
  // 输入/输出及副作用：name 输入；direction 默认 DEVICE_READ。
  // 失败/边界：无。
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

  // mapping 与全部 authority 快照只保存在此；target 不持有 ledger 或 backing 的公开引用。
  protected rdma_queue_host_mem_ledger_entry ledger[string];

  // 功能：构造 submitter，host_mem/registry 置 null 并清空 ledger。
  // 输入/输出及副作用：name 输入；不接管外部资源。
  // 失败/边界：host_mem 未配置时业务入口返回 INVALID_STATE。
  function new(string name = "rdma_queue_host_mem_submitter");
    super.new(name);
    host_mem = null;
    registry = null;
    ledger.delete();
  endfunction

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 INVALID_STATE 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status state_error(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：构造 CODEC_ERROR 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status codec_error(string message);
    return rdma_status::make(RDMA_SC_CODEC_ERROR, message);
  endfunction

  // 功能：把可空 status 规范化：非空原样返回，null 时按 fallback 构造错误。
  // 输入/输出及副作用：status、fallback_code、fallback_message 输入；返回非空 status，无其他副作用。
  // 失败/边界：null 不视为成功，也不重试。
  protected function rdma_status status_or(
    rdma_status status,
    rdma_status_code_e fallback_code,
    string fallback_message
  );
    if (status != null)
      return status;
    return rdma_status::make(fallback_code, fallback_message);
  endfunction

  // 功能：克隆 DMA request context，得到与源隔离的快照。
  // 输入/输出及副作用：source 输入；result 输出（入口先清空）。
  // 失败/边界：source 为 null 返回 INVALID_ARGUMENT；clone 失败或类型不符返回 INVALID_STATE。
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

  // 功能：登记 target 前核对 mapping 与 request_ctx 的 Function/BDF/PASID/domain/route/epoch、尺寸、对齐、方向权限。
  // 输入/输出及副作用：mapping、request_ctx 与 requested_* 输入；只读检查，返回 status。
  // 失败/边界：空/非 ACTIVE mapping 与零长度返回 INVALID_ARGUMENT/INVALID_STATE；身份、尺寸、对齐、
  //   IOVA 溢出或回绕返回 DMA_TRANSLATION；方向/权限不符返回 DMA_PERMISSION；epoch 不符返回 STALE_GENERATION。
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
    // 旧的直接调用方可省略 route/epoch；一旦任一侧提供，两侧必须有效且一致。
    if (request_ctx.route_valid || mapping.route_valid) begin
      if (!request_ctx.route_valid || !rdma_route_key_valid(request_ctx.route) ||
          !mapping.route_valid || !rdma_route_key_valid(mapping.route) ||
          mapping.route.host_topology_key != request_ctx.route.host_topology_key ||
          mapping.route.root_id != request_ctx.route.root_id ||
          mapping.route.segment != request_ctx.route.segment ||
          !rdma_bdf_same(mapping.route.bdf, request_ctx.route.bdf))
        return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                  "DMA mapping route identity mismatch");
    end
    if (request_ctx.epoch_valid || mapping.epoch_valid) begin
      if (!request_ctx.epoch_valid || !mapping.epoch_valid ||
          mapping.reset_epoch != request_ctx.reset_epoch)
        return rdma_status::make(RDMA_SC_STALE_GENERATION,
                                  "DMA mapping reset epoch identity mismatch");
    end
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

  // 功能：校验一条 ledger 记录的 mapping、release authority、request context 及 Function/route/epoch/owner。
  // 输入/输出及副作用：entry 输入；只读，不调用 host_mem、不改 ledger 或 mapping。
  // 失败/边界：记录/mapping/authority/context/Function 缺失、已 released、非 ACTIVE、身份/route/epoch/owner
  //   不一致或方向权限非法时返回对应错误；release authority 只经 mapping 的 opaque hook 校验。
  protected function rdma_status ledger_entry_authority_status(
    rdma_queue_host_mem_ledger_entry entry
  );
    rdma_dma_mapping mapping;
    rdma_dma_request_context request_ctx;
    rdma_status status;

    if (entry == null)
      return state_error("queue host-memory target ledger entry is null");

    mapping = entry.mapping;
    if (mapping == null)
      return state_error("queue host-memory target mapping is null");
    if (entry.release_authority == null)
      return state_error("queue host-memory target release authority is null");
    if (entry.request_context == null)
      return state_error("queue host-memory target request context is null");
    if (entry.released)
      return state_error("queue host-memory target is already released");
    if (mapping.state != RDMA_MAPPING_ACTIVE)
      return state_error("queue host-memory target mapping is not ACTIVE");

    status = mapping.release_authority_status(entry.release_authority);
    status = status_or(
      status,
      RDMA_SC_INVALID_STATE,
      "queue host-memory target release authority validation returned null"
    );
    if (!status.ok())
      return status;

    request_ctx = entry.request_context;
    if (request_ctx.function_h == null)
      return state_error("queue host-memory target request Function is null");
    if (mapping.function_h == null)
      return state_error("queue host-memory target mapping Function is null");
    if (mapping.function_h.kind != RDMA_RESOURCE_FUNCTION ||
        request_ctx.function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target Function kind is invalid"
      );

    status = request_ctx.validate();
    status = status_or(
      status,
      RDMA_SC_INVALID_STATE,
      "queue host-memory target request validation returned null"
    );
    if (!status.ok())
      return status;

    if (mapping.function_h.function_uid != request_ctx.function_h.function_uid ||
        mapping.function_h.object_id != request_ctx.function_h.object_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target Function identity mismatch"
      );
    if (mapping.function_h.generation != request_ctx.function_h.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "queue host-memory target Function generation mismatch"
      );
    if (mapping.requester_bdf != request_ctx.requester_bdf)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target requester BDF mismatch"
      );
    if (mapping.pasid_valid != request_ctx.pasid_valid ||
        mapping.pasid != request_ctx.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target PASID identity mismatch"
      );
    if (mapping.dma_domain_valid != request_ctx.dma_domain_valid ||
        mapping.dma_domain_id != request_ctx.dma_domain_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target DMA domain mismatch"
      );

    // 同上：任一侧携带 route/epoch authority 时，两侧必须存在、有效且一致。
    if (request_ctx.route_valid || mapping.route_valid) begin
      if (!request_ctx.route_valid || !mapping.route_valid ||
          !rdma_route_key_valid(request_ctx.route) ||
          !rdma_route_key_valid(mapping.route) ||
          request_ctx.route.host_topology_key != mapping.route.host_topology_key ||
          request_ctx.route.root_id != mapping.route.root_id ||
          request_ctx.route.segment != mapping.route.segment ||
          !rdma_bdf_same(request_ctx.route.bdf, mapping.route.bdf))
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "queue host-memory target route identity mismatch"
        );
    end
    if (request_ctx.epoch_valid || mapping.epoch_valid) begin
      if (!request_ctx.epoch_valid || !mapping.epoch_valid ||
          request_ctx.reset_epoch != mapping.reset_epoch)
        return rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          "queue host-memory target reset epoch mismatch"
        );
    end

    if ((mapping.owner_h == null) != (request_ctx.owner_h == null))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target owner presence mismatch"
      );
    if (mapping.owner_h != null &&
        !mapping.owner_h.same_instance(request_ctx.owner_h))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target owner identity mismatch"
      );

    if (!(mapping.direction inside {RDMA_DMA_DEVICE_READ,
                                    RDMA_DMA_DEVICE_WRITE,
                                    RDMA_DMA_BIDIRECTIONAL}))
      return state_error("queue host-memory target mapping direction is invalid");
    if (entry.direction != mapping.direction)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "queue host-memory target direction authority mismatch"
      );
    if (entry.permissions.device_read != mapping.permissions.device_read ||
        entry.permissions.device_write != mapping.permissions.device_write ||
        entry.permissions.atomic != mapping.permissions.atomic)
      return rdma_status::make(
        RDMA_SC_DMA_PERMISSION,
        "queue host-memory target permission authority mismatch"
      );
    if (mapping.size == 0)
      return state_error("queue host-memory target mapping has zero size");
    if (mapping.iova.value >
        (64'hffff_ffff_ffff_ffff - (mapping.size - 1'b1)))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "queue host-memory target mapping range overflows"
      );
    return rdma_status::success();
  endfunction

  // 功能：按 opaque capability 查找唯一 ledger 记录，并在返回前做完整 authority 校验。
  // 输入/输出及副作用：target 输入；entry 输出（已验证的内部引用）；只读 ledger。
  // 失败/边界：target/key 未登记或 authority 校验失败时返回非成功 status 且 entry=null。
  protected function rdma_status lookup_target(
    rdma_queue_host_mem_target target,
    output rdma_queue_host_mem_ledger_entry entry
  );
    string key;
    rdma_status status;

    entry = null;
    if (target == null)
      return invalid("queue host-memory target is null");
    key = target.capability_key();
    if (key.len() == 0 || !ledger.exists(key) || ledger[key] == null)
      return invalid("queue host-memory target is foreign or unknown");
    entry = ledger[key];
    status = ledger_entry_authority_status(entry);
    if (status == null || !status.ok()) begin
      entry = null;
      return status_or(
        status,
        RDMA_SC_INVALID_STATE,
        "queue host-memory target ledger validation returned null"
      );
    end
    return status;
  endfunction

  // 功能：把 entry 与 offset/length/方向/权限组成一次 access，在 mapping.check_access 前验证 IOVA 几何与生命周期。
  // 输入/输出及副作用：entry、offset、length、requested_direction/permissions 输入；只读，返回检查 status。
  // 失败/边界：entry 缺失、已 release、length 为零、offset 或 IOVA 溢出时拒绝；check_access 的 null status
  //   规范化为 DMA_TRANSLATION，其余失败原样传播；失败不启动 I/O。
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

  // 功能：按 image_kind/object_type/variant 在 registry 中查找 queue codec。
  // 输入/输出及副作用：image_kind、object_type、variant 输入；codec 输出（入口先置 null）。
  // 失败/边界：registry 未配置返回 INVALID_STATE；lookup 返回 null 时归一化为 UNSUPPORTED_OPCODE。
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

  // 功能：把 image 的字节拷贝为 write_data 数组，供 host-memory 写入。
  // 输入/输出及副作用：image 输入；write_data 输出。
  // 失败/边界：image 非法（malformed）时返回 CODEC_ERROR。
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

  // 功能：读取已登记 entry，建立 detached image；CQE 路径按 entry-size/variant 做 codec 校验。
  // 输入/输出及副作用：entry、offset、image_length、image_kind、codec、可选 cqe_variant 输入；image 输出；
  //   只读 backing，不推进游标。
  // 失败/边界：读出长度不符、image 分配失败、codec 类型不符或 codec 返回 null/失败时返回错误，image=null。
  protected function rdma_status complete_read_image(
    rdma_queue_host_mem_ledger_entry entry,
    longint unsigned offset,
    int unsigned image_length,
    rdma_image_kind_e image_kind,
    rdma_codec_base codec,
    output rdma_hw_image image,
    input bit cqe_variant_valid = 1'b0,
    input rdma_cqe_variant_e cqe_variant = RDMA_CQE_VARIANT_RC
  );
    byte read_data[];
    rdma_status status;
    rdma_hw_image candidate;
    rdma_hw_cqe_codec cqe_codec;

    image = null;
    if (entry == null)
      return state_error("queue completion entry is null");
    if (codec == null)
      return codec_error("queue completion codec is null");
    if (host_mem == null)
      return state_error("queue host-memory adapter is not configured");

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

    // CQE 大小属于事务属性；registry 共享同一 codec，须用显式 profile API 校验，
    // 不读取可变的 active profile。
    if (image_kind == RDMA_IMAGE_CQE) begin
      if (!$cast(cqe_codec, codec))
        return codec_error("CQ registry codec cannot validate a variable profile");
      if (cqe_variant_valid)
        status = cqe_codec.validate_image_with_entry_bytes_variant(
            candidate, image_length, cqe_variant);
      else
        status = cqe_codec.validate_image_with_entry_bytes(candidate,
                                                            image_length);
    end
    else
      status = codec.validate_image(candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue completion image validation returned null");
    if (!status.ok())
      return status;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：校验请求后向 host_mem 分配 mapping，核对身份并登记 ledger，返回 opaque target。
  // 输入/输出及副作用：request_context、size、alignment、direction 输入；target 输出；成功时新增 ledger 记录。
  // 失败/边界：参数非法、adapter 失败、mapping 身份不符、快照/分配失败返回错误；
  //   失败路径对已得到的 mapping 回滚一次，不泄漏资源。
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
    if (status == null)
      return state_error(
          "DMA request context validation returned null status");
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
      // adapter 可能在失败 status 时仍返回活动 mapping：视为分配后失败，仅回滚一次。
      if (mapping != null)
        release_status = rdma_hw_host_mem_rollback(host_mem, mapping);
      return status_or(status, RDMA_SC_DMA_TRANSLATION,
                       "host memory allocation returned null status");
    end
    if (!status.ok())
      return status;
    status = mapping_identity_status(mapping, request_context, size,
                                     alignment, direction);
    if (!status.ok()) begin
      // mapping 身份异常时同样只回滚一次再返回。
      release_status = rdma_hw_host_mem_rollback(host_mem, mapping);
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
    if (status.ok())
      status = clone_context(request_context, context_snapshot);
    if (!status.ok()) begin
      release_status = rdma_hw_host_mem_rollback(host_mem, mapping);
      return status;
    end

    candidate = rdma_queue_host_mem_target::type_id::create(
      "queue_host_mem_target");
    entry = rdma_queue_host_mem_ledger_entry::type_id::create(
      "queue_host_mem_ledger_entry");
    if (candidate == null || entry == null) begin
      release_status = rdma_hw_host_mem_rollback(host_mem, mapping);
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

  // 功能：编码 queue entry，校验 image 与范围后写入 host-memory 并回读校验。
  // 输入/输出及副作用：target、offset、model、image_kind、variant、expected_length 输入；image 输出；写 backing。
  // 失败/边界：target authority、adapter、codec、model 缺失，codec 返回 null/尺寸不符、后端拒绝、
  //   范围溢出、DMA 权限不足或回读校验失败时返回错误，不发布 image。
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
    string object_type;
    string codec_variant;
    byte write_data[];
    byte read_data[];

    image = null;
    status = lookup_target(target, entry);
    status = status_or(status, RDMA_SC_INVALID_STATE,
                       "queue target lookup returned null status");
    if (!status.ok())
      return status;

    if (entry == null || entry.request_context == null ||
        entry.request_context.function_h == null)
      return state_error("queue target authority is incomplete");

    if (host_mem == null)
      return state_error("queue host-memory adapter is not configured");

    object_type = "sqe";
    codec_variant = variant;
    if (image_kind == RDMA_IMAGE_RQE) begin
      object_type = "rqe";
      codec_variant = "default";
    end

    status = lookup_queue_codec(image_kind, object_type, codec_variant, codec);
    status = status_or(status, RDMA_SC_UNSUPPORTED_OPCODE,
                       "queue codec lookup returned null status");
    if (!status.ok())
      return status;
    if (codec == null)
      return codec_error("queue codec lookup returned a null codec");
    if (model == null)
      return invalid("queue entry model is null");

    candidate = null;
    status = codec.encode(model, candidate);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue codec encode returned null status");
    if (!status.ok())
      return status;
    if (candidate == null)
      return codec_error("queue codec returned a null image");
    if (candidate.length != expected_length ||
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
    // 同样校验回读 image，捕获 adapter 返回 metadata 异常或未 detached 的 image。
    readback_image = rdma_hw_image::type_id::create("queue_readback_image");
    if (readback_image == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue readback image allocation failed");
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
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "queue readback image validation returned null");
    if (!status.ok())
      return status;
    image = candidate;
    return rdma_status::success();
  endfunction

  // 功能：按 model.transport 选择 rc/ud/urc variant 写入 SQE。
  // 输入/输出及副作用：target、offset、model 输入；image 输出；委托 write_queue_entry。
  // 失败/边界：model 为 null 或 transport 不支持返回 INVALID_ARGUMENT，image=null。
  function rdma_status write_sqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    rdma_hw_sqe_model model,
    output rdma_hw_image image
  );
    string variant;
    if (model == null) begin
      image = null;
      return invalid("SQE model is null");
    end

    case (model.transport)
      RDMA_TRANSPORT_RC: variant = "rc";
      RDMA_TRANSPORT_UD: variant = "ud";
      RDMA_TRANSPORT_URC: variant = "urc";
      default: begin
        image = null;
        return invalid("SQE transport is unsupported");
      end
    endcase

    return write_queue_entry(
      target,
      offset,
      model,
      RDMA_IMAGE_SQE,
      variant,
      RDMA_WQE_BYTES,
      image
    );
  endfunction

  // 功能：写入 RQE（default variant）。
  // 输入/输出及副作用：target、offset、model 输入；image 输出；委托 write_queue_entry。
  // 失败/边界：model 为 null 返回 INVALID_ARGUMENT，image=null。
  function rdma_status write_rqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    rdma_hw_rqe_model model,
    output rdma_hw_image image
  );
    if (model == null) begin
      image = null;
      return invalid("RQE model is null");
    end

    return write_queue_entry(
      target,
      offset,
      model,
      RDMA_IMAGE_RQE,
      "default",
      RDMA_RQE_BYTES,
      image
    );
  endfunction

  // 功能：以默认 CQE 大小读取并解码 CQE。
  // 输入/输出及副作用：target、offset 输入；model/image 输出；委托 read_cqe_sized。
  // 失败/边界：同 read_cqe_sized。
  function rdma_status read_cqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_hw_cqe_model model,
    output rdma_hw_image image
  );
    return read_cqe_sized(target, offset, RDMA_CQE_BYTES, model, image);
  endfunction

  // 功能：按运行时 CQE entry 大小以 RC variant 解码 CQE，兼容旧 32/64/128B CQ ring 调用方。
  // 输入/输出及副作用：target、offset、entry_size 输入；model/image 输出；委托 variant 入口，只读 ledger。
  // 失败/边界：entry_size 非 32/64/128、长度不匹配、RC overlay 不适用或解码失败时不发布；
  //   UD/RQ/SRFQ 调用方须用 variant 入口。
  function rdma_status read_cqe_sized(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    int unsigned entry_size,
    output rdma_hw_cqe_model model,
    output rdma_hw_image image
  );
    return read_cqe_sized_variant(target, offset, entry_size,
                                  RDMA_CQE_VARIANT_RC, model, image);
  endfunction

  // 功能：按 entry_size 与显式 variant 读取并解码 CQE，variant 决定 qword2/qword3 的 overlay 解释。
  // 输入/输出及副作用：target、offset、entry_size、variant 输入；model/image 输出；只读，发布 detached 值。
  // 失败/边界：target 不存在、entry_size 非法、variant 非法、metadata/长度不符、解码或类型转换失败时
  //   返回错误，model/image 保持 null；调用方不得由 raw qword 猜 variant。
  function rdma_status read_cqe_sized_variant(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    int unsigned entry_size,
    rdma_cqe_variant_e variant,
    output rdma_hw_cqe_model model,
    output rdma_hw_image image
  );
    rdma_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_hw_model decoded;
    rdma_status status;
    rdma_hw_image candidate_image;
    model = null;
    image = null;

    if (!(entry_size inside {32,64,128}))
      return invalid("CQE profile size is invalid");

    status = lookup_target(target, entry);
    if (!status.ok())
      return status;

    status = lookup_queue_codec(RDMA_IMAGE_CQE, "cqe", "default", codec);
    if (!status.ok())
      return status;

    // profile/variant 属于本次读事务而非共享 codec 的可变状态；经显式 variant API 解码，
    // 避免交错读互相影响 overlay。
    status = complete_read_image(entry, offset, entry_size,
                                 RDMA_IMAGE_CQE, codec,
                                 candidate_image, 1'b1, variant);
    if (!status.ok())
      return status;
    begin
      rdma_hw_cqe_codec cqe_codec;
      if (!$cast(cqe_codec, codec)) begin
        model = null;
        image = null;
        return codec_error("CQ registry codec cannot select a variable profile");
      end
      status = cqe_codec.decode_with_entry_bytes_variant(
          candidate_image, entry_size, variant, decoded);
    end
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "CQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null;
      image = null;
      return status.ok() ? codec_error("decoded CQE model type mismatch") : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  // 功能：读取并解码一个事件队列条目（CEQE/AEQE 共用），返回 detached decoded model/image。
  // 输入/输出及副作用：kind/name/bytes 选择 codec 与长度；decoded/image 输出；只读 ledger/backing。
  // 失败/边界：target 或 codec 查找失败、读出/解码失败时返回错误，输出保持 null。
  protected function rdma_status read_event_entry(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    rdma_image_kind_e kind,
    string name,
    int unsigned bytes,
    output rdma_hw_model decoded,
    output rdma_hw_image image
  );
    rdma_queue_host_mem_ledger_entry entry;
    rdma_codec_base codec;
    rdma_status status;
    rdma_hw_image candidate_image;

    decoded = null;
    image = null;
    status = lookup_target(target, entry);
    if (!status.ok())
      return status;
    status = lookup_queue_codec(kind, name.tolower(), "default", codec);
    if (!status.ok())
      return status;
    if (codec == null)
      return codec_error({name, " registry returned a null codec"});
    status = complete_read_image(entry, offset, bytes, kind, codec,
                                 candidate_image);
    if (!status.ok())
      return status;
    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       {name, " decode returned null status"});
    if (!status.ok() || decoded == null) begin
      decoded = null;
      return status.ok() ? codec_error({"decoded ", name, " model type mismatch"})
                         : status;
    end
    image = candidate_image;
    return rdma_status::success();
  endfunction

  // 功能：读取并解码 CEQE。
  // 输入/输出及副作用：model/image 输出；只读 ledger/backing。
  // 失败/边界：读取/解码失败或模型类型不符时返回错误，输出为 null。
  function rdma_status read_ceqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_hw_ceqe_model model,
    output rdma_hw_image image
  );
    rdma_hw_model decoded;
    rdma_status status;

    model = null;
    status = read_event_entry(target, offset, RDMA_IMAGE_CEQE, "CEQE",
                              RDMA_CEQE_BYTES, decoded, image);
    if (status.ok() && !$cast(model, decoded)) begin
      image = null;
      return codec_error("decoded CEQE model type mismatch");
    end
    return status;
  endfunction

  // 功能：读取并解码 AEQE。
  // 输入/输出及副作用：model/image 输出；只读 ledger/backing。
  // 失败/边界：读取/解码失败或模型类型不符时返回错误，输出为 null。
  function rdma_status read_aeqe(
    rdma_queue_host_mem_target target,
    longint unsigned offset,
    output rdma_hw_aeqe_model model,
    output rdma_hw_image image
  );
    rdma_hw_model decoded;
    rdma_status status;

    model = null;
    status = read_event_entry(target, offset, RDMA_IMAGE_AEQE, "AEQE",
                              RDMA_AEQE_BYTES, decoded, image);
    if (status.ok() && !$cast(model, decoded)) begin
      image = null;
      return codec_error("decoded AEQE model type mismatch");
    end
    return status;
  endfunction

  // 功能：校验 release authority 后释放 target 的 mapping，并标记 ledger 记录已释放。
  // 输入/输出及副作用：target 输入；调用 host_mem 释放，成功置 entry.released。
  // 失败/边界：target 未登记、已释放、authority 校验或 adapter 释放失败返回错误，不重新激活旧 target。
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
