// 目录：协议与资源模型层 model/rdma_dma_mapping.sv。
// 职责：描述 DMA 映射（Function、BDF、PASID、domain、route/epoch、IOVA/backing、权限）及访问校验。
// 依赖：本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源仅保存非拥有引用，生命周期由调用方管理。

// // 阅读提示：先看公开类型与接口，再看实现；失败路径须保持状态与资源所有权可追踪。

// // 前置声明：UMEM/PBL/MW 在 context_models.sv 定义；mapping 仅保存非拥有引用，不隐式转移 page pin 或窗口释放责任。
typedef class rdma_umem;
typedef class rdma_pbl;
typedef class rdma_mw_binding;

class rdma_dma_mapping extends uvm_object;
  `uvm_object_utils(rdma_dma_mapping)

  rdma_function_handle function_h;
  rdma_bdf_t requester_bdf;
  bit pasid_valid;
  bit [19:0] pasid;
  bit dma_domain_valid;
  int unsigned dma_domain_id;
  // // 映射保留完整路由与 reset epoch；epoch 变化后映射不可再访问。
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
  // // 用户 buffer 关联对象均为非拥有引用，生命周期由 host-mem/MW 管理。
  rdma_umem umem_ref;
  rdma_pbl pbl_ref;
  rdma_mw_binding mw_ref;
  bit umem_backed;
  int unsigned umem_page_count;

  // 功能：构造 DMA mapping，所有句柄置 null、有效位清零。
  // 输入/输出及副作用：name 传给 super.new。
  // 失败/边界：无；业务入口使用前须由 adapter 填充。
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
    umem_ref = null;
    pbl_ref = null;
    mw_ref = null;
    umem_backed = 1'b0;
    umem_page_count = 0;
  endfunction

  // // owned mapping 是 release capability：具体分配 adapter 须提供 opaque authority 快照并证明等价性，
  // // 不暴露私有 identity 表示。
  // 功能：派生 adapter 提供的 release authority 快照。
  // 输入/输出及副作用：snapshot 输出，入口置 null。
  // 失败/边界：基类返回 UNSUPPORTED_OPCODE。
  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    snapshot = null;
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release authority snapshots"
    );
  endfunction

  // 功能：比较 release authority 快照与本 mapping 是否等价。
  // 输入/输出及副作用：snapshot 为输入；只读。
  // 失败/边界：基类返回 UNSUPPORTED_OPCODE。
  virtual function rdma_status release_authority_status(
    rdma_dma_mapping snapshot
  );
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release authority equivalence"
    );
  endfunction

  // // 具体 adapter 把 completion 事实保持为 opaque，并由保留 authority 的各拷贝共享；public mapping 状态
  // // 不是 backing 已释放的证明。
  // 功能：查询 backing 是否已实际释放。
  // 输入/输出及副作用：release_complete 输出，入口置 0。
  // 失败/边界：基类返回 UNSUPPORTED_OPCODE。
  virtual function rdma_status release_completion_status(
    output bit release_complete
  );
    release_complete = 1'b0;
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release completion queries"
    );
  endfunction

  // 功能：复制 mapping 的全部值字段，嵌套句柄深拷贝，UMEM/PBL/MW 保持非拥有引用。
  // 输入/输出及副作用：rhs 为源；当前对象被覆盖。
  // 失败/边界：rhs 类型不符或 clone 失败触发 UVM fatal（rdma_dma_mapping copy type mismatch）。
  virtual function void do_copy(uvm_object rhs);
    rdma_dma_mapping rhs_mapping;

    super.do_copy(rhs);
    if (!$cast(rhs_mapping, rhs))
      `uvm_fatal("RDMA_COPY_TYPE", "rdma_dma_mapping copy type mismatch")
    function_h = rdma_deep_copy#(rdma_function_handle)::of(
      rhs_mapping.function_h, "rdma_function_handle clone type mismatch");
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
    umem_ref = rhs_mapping.umem_ref;
    pbl_ref = rhs_mapping.pbl_ref;
    mw_ref = rhs_mapping.mw_ref;
    umem_backed = rhs_mapping.umem_backed;
    umem_page_count = rhs_mapping.umem_page_count;
    owner_h = rdma_deep_copy#(rdma_handle)::of(
      rhs_mapping.owner_h, "rdma_handle clone type mismatch");
  endfunction

  // 功能：校验一次 DMA 访问是否落在本 mapping 的 owner、范围、方向与权限内。
  // 输入/输出及副作用：requested_* 与 first_iova/length/direction/permissions 为请求；只读，返回状态。
  // 失败/边界：非 ACTIVE、route/handle 非法、Function/BDF/PASID/domain 不符、长度为零、范围溢出或越界、方向/权限不符时拒绝；
  //   generation 不符返回 STALE_GENERATION。
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
