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
  virtual function rdma_status snapshot_release_authority(
    output rdma_dma_mapping snapshot
  );
    snapshot = null;
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release authority snapshots"
    );
  endfunction

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
  virtual function rdma_status release_completion_status(
    output bit release_complete
  );
    release_complete = 1'b0;
    return rdma_status::make(
      RDMA_SC_UNSUPPORTED_OPCODE,
      "DMA mapping does not support release completion queries"
    );
  endfunction

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
