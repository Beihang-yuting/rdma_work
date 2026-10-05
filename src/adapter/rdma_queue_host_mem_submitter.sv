// 目录：适配器接口层 adapter/rdma_queue_host_mem_submitter.sv。
// 职责：实现 rdma_queue_host_mem_submitter 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_host_mem_submitter.sv 属于适配器接口层，定义主机内存、PCIe、网络及上下文后端接口。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// Transactional host-memory access for XTR v1 queue entries.  Queue engines
// own slot selection and doorbells; this adapter deliberately accepts only an
// opaque allocation capability and a mapping-relative byte offset.

// 功能：在 rdma_queue_host_mem_submitter 中，rdma_hw_host_mem_release 按 owner、generation 和幂等规则释放或清理已验证资源，同时删除相关账本记录。
// 输入/输出及副作用：api（输入）、mapping（输入）；rdma_hw_host_mem_release 读取 api、mapping 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
// 失败/边界：rdma_hw_host_mem_release 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“host memory adapter is null”；调用方必须先完成 release-authority 校验，失败路径不提交部分状态或转移未声明资源。
function automatic rdma_status rdma_hw_host_mem_release(
    rdma_host_mem_api api,
    rdma_dma_mapping mapping
  );
    if (api == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "host memory adapter is null");
    return api.\release (mapping);
  endfunction

// 功能：在 allocate_target 的 immediate-failure 路径中，使用 adapter 内部 opaque allocation identity 回滚尚未登记到 submitter ledger 的 mapping。
// 输入/输出及副作用：api（输入）、mapping（输入）；rdma_hw_host_mem_rollback 只释放本次 allocate 产生的候选 backing，不修改 submitter ledger。
// 失败/边界：mapping 的 public route/geometry/owner 可能正是校验失败原因，因此不能依赖严格 release()；api 为空或 opaque token 无效时返回明确错误，由调用方保留原始失败证据。
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

  // 功能：status_or 将 host-memory/codec helper 返回的可空 status 规范化为可诊断结果，
  //   非空 status 原样透传，空值时按 fallback_code 和 fallback_message 构造替代错误。
  // 输入/输出及副作用：status、fallback_code、fallback_message（输入）；返回一个非空
  //   rdma_status，不修改 submitter、ledger、mapping 或外部资源。
  // 失败/边界：status 为 null 时永远采用 fallback；fallback_code/message 由调用方保证能
  //   描述真实拒绝原因，函数不把 null 当作成功，也不执行重试。
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

  // 功能：mapping_identity_status 在登记 queue target 前核对 mapping 与 request_ctx 的
  //   Function、BDF、PASID、DMA domain、route、reset epoch、尺寸、对齐和方向权限。
  // 输入/输出及副作用：mapping、request_ctx、requested_size、requested_alignment、
  //   requested_direction（输入）；只读检查并返回 rdma_status，不写 mapping、request_ctx、
  //   ledger 或外部 Host-memory 资源。
  // 失败/边界：空/非 ACTIVE mapping、缺少 Function、身份或 route/epoch 不一致、尺寸/对齐/
  //   方向/权限不符、零长度及 IOVA 溢出或回绕分别返回 INVALID/STATE、DMA_TRANSLATION、
  //   DMA_PERMISSION 或 STALE_GENERATION；失败不发布 target。
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
    // Legacy direct Host-memory callers may omit route/epoch metadata.  Once
    // either side supplies an authority, however, both copies must be valid
    // and identical; production planner/router paths always supply both.
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

  // 功能：ledger_entry_authority_status 校验一条 target ledger 记录的完整
  //       mapping、release authority、request context、Function、route、epoch
  //       和生命周期 authority。
  // 输入/输出及副作用：entry（输入）；函数只读取 entry 及其嵌套字段，返回
  //       规范化 rdma_status，不调用 host_mem、不修改 ledger 或 mapping。
  // 失败/边界：entry、mapping、release_authority、request_context 或 Function
  //       缺失，mapping 非 ACTIVE、身份/路由/epoch/owner 不一致、几何或权限
  //       非法时返回对应错误；release authority 只通过 mapping 提供的
  //       opaque equivalence hook 校验，不读取或重建其内部 token。
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

    // Direct unit callers may omit route/epoch metadata.  Once either side
    // carries an authority, both copies must be present, valid and identical.
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

  // 功能：lookup_target 按 opaque capability 查找唯一 ledger 记录，并在返回
  //       前执行完整 authority 校验，阻止 malformed entry 进入任何 I/O 路径。
  // 输入/输出及副作用：target（输入）、entry（输出）；函数只读取 target 和
  //       private ledger，返回经过验证的内部 entry 引用，不取得外部资源所有权。
  // 失败/边界：target/key 未登记、entry 或其 mapping/context/authority 缺失、
  //       身份/route/epoch/lifecycle 校验失败时返回非成功 status 且 entry=null。
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

  // 功能：validate_range 把 target ledger entry 与 offset/length/方向/权限组合成一次
  //   Host-memory access，并在调用 mapping.check_access 前验证 IOVA 几何和生命周期。
  // 输入/输出及副作用：entry、offset、length、requested_direction、requested_permissions
  //   （输入）；只读 entry/mapping/context，返回检查 status，不修改 ledger、mapping 或游标。
  // 失败/边界：entry 缺失、已 release、length 为零、offset 或 IOVA 计算溢出时拒绝；
  //   mapping.check_access 的 null status 规范化为 DMA_TRANSLATION，其余失败原样传播，
  //   任何失败都不启动 I/O。
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

  // 功能：complete_read_image 读取一个已登记的 host-memory entry，建立 detached
  //   image，并在 CQE 路径上执行与 entry-size/variant 对应的 codec 校验。
  // 输入/输出及副作用：entry、offset、image_length、image_kind、codec 和可选
  //   cqe_variant 为输入；image 为输出。函数只读取 backing，成功后发布独立 image，
  //   不推进队列游标，也不取得调用方资源所有权。
  // 失败/边界：host-memory 读出长度不符、image 分配失败、variant codec 类型不符、
  //   codec 返回 null/非成功 status 时返回相应错误；所有失败路径保持 image=null，
  //   不提交部分状态、不隐式重试，也不转移未声明资源。
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

    // CQE size is a transaction property.  The registry intentionally shares
    // one codec object, so validate through its explicit profile API instead
    // of reading the mutable 64B/32B/128B active profile.
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
      // A defensive adapter may return a live mapping together with a
      // failure status.  Treat that as a post-allocation failure and make the
      // single cleanup attempt before returning the allocation error.
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
      // An adapter may have returned a mapping with malformed identity.  It
      // is still released exactly once before the failed allocation exits.
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

  // 功能：在 rdma_queue_host_mem_submitter 中，write_queue_entry 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：target（输入）、offset（输入）、model（输入）、image_kind（输入）、variant（输入）、expected_length（输入）、image（输出）；输入
  //   request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output 返回结果。
  // 失败/边界：target authority、Host-memory adapter、codec 或 model 缺失，
  //   codec 返回 null status/image、后端拒绝、范围溢出、DMA 权限不足或
  //   readback 校验失败时返回错误，不发布 image，也不推进本地游标。
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
    // Validate the readback image too.  This catches an adapter that returns
    // bytes with malformed metadata or a codec image that was not detached.
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

  // 功能：按运行时 CQE entry 大小读取并以兼容的 RC variant 解码 CQE，供旧的
  //       32/64/128B CQ ring 调用方继续使用。
  // 输入/输出及副作用：target、offset、entry_size 为输入，model/image 为输出；委托
  //       显式 variant 入口仅读取 host-memory ledger，不修改共享 codec 状态。
  // 失败/边界：entry_size 不是 32/64/128、映像长度不匹配、RC overlay 不适用或
  //       codec 解码失败时不发布 model/image；UD/RQ/SRFQ 调用方必须选新入口。
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

  // 功能：按运行时 CQE entry 大小和调用方明确给出的 variant 读取并解码
  //       CQE；variant 决定 qword2/qword3 中 RC、UD 或 RQ/SRFQ overlay 的
  //       保留位与字段解释，避免共享 registry codec 隐式沿用 RC 默认值。
  // 输入/输出及副作用：target、offset、entry_size、variant 为输入；model、image
  //       为输出；函数仅读取 target 对应 host-memory ledger，发布 detached
  //       CQE model/image，不修改共享 codec 的 active profile 或 variant。
  // 失败/边界：target 不存在、entry_size 不是 32/64/128、variant 非法、映像
  //       metadata/长度不匹配、codec 解码失败或类型转换失败时返回明确错误，且
  //       model/image 保持 null；调用方不得从 raw qword2/qword3 非零值猜 variant。
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

    // CQE profile and variant are properties of this read transaction, not
    // mutable state on the shared registry codec.  Decode through the
    // explicit variant API so interleaved reads cannot observe one another's
    // overlay authority.
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
    model = null;
    image = null;

    status = lookup_target(target, entry);
    if (!status.ok())
      return status;

    status = lookup_queue_codec(RDMA_IMAGE_CEQE, "ceqe", "default", codec);
    if (!status.ok())
      return status;

    if (codec == null)
      return codec_error("CEQE registry returned a null codec");

    status = complete_read_image(entry, offset, RDMA_CEQE_BYTES,
                                 RDMA_IMAGE_CEQE, codec,
                                 candidate_image);
    if (!status.ok())
      return status;

    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "CEQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null;
      image = null;
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
    model = null;
    image = null;

    status = lookup_target(target, entry);
    if (!status.ok())
      return status;

    status = lookup_queue_codec(RDMA_IMAGE_AEQE, "aeqe", "default", codec);
    if (!status.ok())
      return status;

    if (codec == null)
      return codec_error("AEQE registry returned a null codec");

    status = complete_read_image(entry, offset, RDMA_AEQE_BYTES,
                                 RDMA_IMAGE_AEQE, codec,
                                 candidate_image);
    if (!status.ok())
      return status;

    status = codec.decode(candidate_image, decoded);
    status = status_or(status, RDMA_SC_CODEC_ERROR,
                       "AEQE decode returned null status");
    if (!status.ok() || decoded == null || !$cast(model, decoded)) begin
      model = null;
      image = null;
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
