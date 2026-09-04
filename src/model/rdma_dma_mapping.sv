// 目录：协议与资源模型层 model/rdma_dma_mapping.sv。
// 职责：实现 rdma_dma_mapping 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_dma_mapping.sv 属于模型层，描述语义请求、资源快照、DMA 映射及生命周期数据。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_dma_mapping extends uvm_object;
  `uvm_object_utils(rdma_dma_mapping)

  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
  // 中文：映射保留完整路由与 reset epoch；epoch 变化后映射不可再访问。
  rdma_route_key_t route;
  rdma_reset_epoch_t reset_epoch;
  bit route_valid;
  bit epoch_valid;
  rdma_backing_addr_t backing_addr;
  rdma_iova_t iova;
  longint unsigned size;
  rdma_dma_direction_e direction;
  rdma_dma_permission_t permissions;
  rdma_mapping_state_e state;
  rdma_handle owner_h;

  // 功能：构造 rdma_dma_mapping，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：function_h=null；requester_bdf='0；pasid_valid=1'b0；pasid='0；dma_domain_valid=1'b0；dma_domain_id='0；route='0；reset_epoch=0；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_dma_mapping 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_dma_mapping");
    super.new(name);
    function_h = null;
    requester_bdf = '0;
    pasid_valid = 1'b0;
    pasid = '0;
    dma_domain_valid = 1'b0;
    dma_domain_id = '0;
    route = '0;
    reset_epoch = 0;
    route_valid = 1'b0;
    epoch_valid = 1'b0;
    backing_addr = '0;
    iova = '0;
    size = '0;
    direction = RDMA_DMA_DEVICE_READ;
    permissions = '0;
    state = RDMA_MAPPING_INVALID;
    owner_h = null;
  endfunction

  // Owned mappings are release capabilities.  Concrete allocation adapters
  // must provide an opaque authority snapshot and prove equivalence without
  // exposing their private identity representation.
  // 功能：在 rdma_dma_mapping 中，snapshot_release_authority 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：snapshot（输出）；snapshot_release_authority 读取 snapshot 并使用字段 snapshot，并写入 snapshot；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：snapshot_release_authority 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    snapshot = null;
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release authority snapshots"
    );
  endfunction

  // 功能：在 rdma_dma_mapping 中，release_authority_status 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：snapshot（输入）；release_authority_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：release_authority_status 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release authority equivalence"
    );
  endfunction

  // Concrete adapters keep the completion fact opaque and shared by all
  // authority-preserving mapping copies.  Public mapping state is not proof
  // that the backing allocation was actually released.
  // 功能：在 rdma_dma_mapping 中，release_completion_status 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：release_complete（输出）；release_completion_status 可能更新本对象明确拥有的状态，并写入 release_complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：release_completion_status 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  virtual function rdma_status release_completion_status(
    output bit release_complete
  );
    release_complete = 1'b0;
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release completion queries"
    );
  endfunction

  // 功能：将 rhs 中 rdma_dma_mapping 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：rhs（输入）；rhs 是源对象；当前对象字段会被覆盖，嵌套句柄按实现执行 clone 或保持非拥有引用，源对象不被修改。
  // 失败/边界：do_copy 在源对象为空、clone/cast 失败或类型不匹配时触发 UVM fatal（rdma_dma_mapping copy type mismatch），不保留部分有效快照。
  virtual function void do_copy(uvm_object rhs);
    rdma_dma_mapping rhs_mapping;
    uvm_object cloned_object;

    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_dma_mapping copy type mismatch")
    if (rhs_mapping.function_h == null) begin
      function_h = null;
    end
    else begin
      cloned_object = rhs_mapping.function_h.clone();
      if (cloned_object == null || !$cast(function_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "rdma_function_handle clone type mismatch")
    end
    requester_bdf = rhs_mapping.requester_bdf;
    pasid_valid = rhs_mapping.pasid_valid;
    pasid = rhs_mapping.pasid;
    dma_domain_valid = rhs_mapping.dma_domain_valid;
    dma_domain_id = rhs_mapping.dma_domain_id;
    route = rhs_mapping.route;
    reset_epoch = rhs_mapping.reset_epoch;
    route_valid = rhs_mapping.route_valid;
    epoch_valid = rhs_mapping.epoch_valid;
    backing_addr = rhs_mapping.backing_addr;
    iova = rhs_mapping.iova;
    size = rhs_mapping.size;
    direction = rhs_mapping.direction;
    permissions = rhs_mapping.permissions;
    state = rhs_mapping.state;
    if (rhs_mapping.owner_h == null) begin
      owner_h = null;
    end
    else begin
      cloned_object = rhs_mapping.owner_h.clone();
      if (cloned_object == null || !$cast(owner_h, cloned_object))
        `uvm_fatal("RDMA_COPY_TYPE", "rdma_handle clone type mismatch")
    end
  endfunction

  // 功能：check_access 校验 requested_function、requested_requester_bdf、requested_pasid_valid、requested_pasid、requested_dma_domain_valid 等参数 与当前对象状态的一致性，并显式处理“DMA mapping is not ACTIVE”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：requested_function（输入）、requested_requester_bdf（输入）、requested_pasid_valid（输入）、requested_pasid（输入）、requested_dma_domain_valid（输入）、requested_dma_domain_id（输入）、first_iova（输入）、length（输入）、requested_direction（输入）、requested_permissions（输入）；check_access 读取 requested_function、requested_requester_bdf、requested_pasid_valid、requested_pasid、requested_dma_domain_valid、requested_dma_domain_id、first_iova、length、requested_direction、requested_permissions 并使用字段 mapping_last、request_last；函数返回 rdma_status，不取得调用方资源所有权。

  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  function rdma_status check_access(
    rdma_function_handle requested_function,
    rdma_bdf_t requested_requester_bdf,
    bit requested_pasid_valid,
    bit [19:0] requested_pasid,
    bit requested_dma_domain_valid,
    int unsigned requested_dma_domain_id,
    rdma_iova_t first_iova,
    longint unsigned length,
    rdma_dma_direction_e requested_direction,
    rdma_dma_permission_t requested_permissions
  );
    longint unsigned mapping_last;
    longint unsigned request_last;

    if (state != RDMA_MAPPING_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "DMA mapping is not ACTIVE");
    if (route_valid && !rdma_route_key_valid(route))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping route is invalid");
    if (requested_function == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "requested function handle is null");
    if (function_h == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mapping function handle is null");
    if (function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mapping handle kind is not FUNCTION");
    if (requested_function.kind != RDMA_RESOURCE_FUNCTION ||
        requested_function.function_uid != function_h.function_uid ||
        requested_function.object_id != function_h.object_id)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "requested function does not own mapping");
    if (requested_function.generation != function_h.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "requested function generation is stale");
    if (requested_requester_bdf != requester_bdf)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "requester BDF does not match mapping");
    if (requested_pasid_valid != pasid_valid ||
        (requested_pasid_valid ? requested_pasid : '0) !=
          (pasid_valid ? pasid : '0))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "requester PASID does not match mapping");
    if (requested_dma_domain_valid != dma_domain_valid ||
        requested_dma_domain_id != dma_domain_id)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA domain does not match mapping");
    if (length == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "DMA access length is zero");
    if (size == 0)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "ACTIVE DMA mapping has zero size");

    if (iova.value > (64'hffff_ffff_ffff_ffff - (size - 1'b1)))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA mapping range end overflows 64 bits");
    if (first_iova.value >
        (64'hffff_ffff_ffff_ffff - (length - 1'b1)))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA request range end overflows 64 bits");

    mapping_last = iova.value + size - 1'b1;
    request_last = first_iova.value + length - 1'b1;
    if (first_iova.value < iova.value || request_last > mapping_last)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "DMA request is outside mapping range");

    if (!(requested_direction inside {RDMA_DMA_DEVICE_READ,
                                      RDMA_DMA_DEVICE_WRITE,
                                      RDMA_DMA_BIDIRECTIONAL}))
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "requested DMA direction is invalid");
    if (!(direction inside {RDMA_DMA_DEVICE_READ,
                            RDMA_DMA_DEVICE_WRITE,
                            RDMA_DMA_BIDIRECTIONAL}))
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "mapping DMA direction is invalid");
    case (requested_direction)
      RDMA_DMA_DEVICE_READ: begin
        if (!requested_permissions.device_read)
          return rdma_status::make(
            RDMA_SC_DMA_PERMISSION,
            "device-read DMA request omitted read permission"
          );
      end
      RDMA_DMA_DEVICE_WRITE: begin
        if (!requested_permissions.device_write)
          return rdma_status::make(
            RDMA_SC_DMA_PERMISSION,
            "device-write DMA request omitted write permission"
          );
      end
      RDMA_DMA_BIDIRECTIONAL: begin
        if (!requested_permissions.device_read ||
            !requested_permissions.device_write)
          return rdma_status::make(
            RDMA_SC_DMA_PERMISSION,
            "bidirectional DMA request omitted read or write permission"
          );
      end
    endcase
    if (direction != RDMA_DMA_BIDIRECTIONAL &&
        requested_direction != direction)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "DMA direction is not permitted");
    if ((requested_permissions & ~permissions) != '0)
      return rdma_status::make(RDMA_SC_DMA_PERMISSION,
                               "DMA permissions are not a mapping subset");

    return rdma_status::success();
  endfunction
endclass
