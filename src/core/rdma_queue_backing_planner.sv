// 目录/层次：核心执行层 core/rdma_queue_backing_planner.sv。
// 职责：为 CQ/SRQ/CEQ/AEQ 规划并物化 queue backing（owned 分配或 borrowed 校验），
//   生成 ring/ref/page directory/flush target 计划，并提供失败回滚。
// 依赖：依赖 types/model 层的 binding、preflight、plan、DMA mapping 与 rdma_host_mem_api。
// 所有权与生命周期：host_mem 为非拥有引用；owned ref 归 control plane，借用 backing 永不释放。

class rdma_queue_backing_planner extends uvm_object;
  `rdma_object_utils(rdma_queue_backing_planner)

  protected rdma_host_mem_api host_mem;

  // 功能：构造 planner，host_mem 置空。
  // 输入/输出及副作用：name 为 UVM 实例名。
  // 失败/边界：未 configure 时业务入口返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_planner");
    super.new(name);
    host_mem = null;
  endfunction

  // 功能：构造 INVALID_ARGUMENT 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 INVALID_STATE 状态。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：把后端返回的 null status 归一化为 INVALID_STATE。
  // 输入/输出及副作用：status、message 为输入；非空 status 原样返回。
  // 失败/边界：status 为 null 时返回带 message 的 INVALID_STATE。
  protected function rdma_status normalize_status(
    rdma_status status,
    string message
  );
    if (status == null)
      return invalid_state(message);
    return status;
  endfunction

  // 功能：判断两个 handle 是否为同一实例。
  // 输入/输出及副作用：lhs、rhs 只读；返回 bit。
  // 失败/边界：任一为 null 返回 0。
  protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.same_instance(rhs);
  endfunction

  // 功能：比较两个 DMA route key 的 host/root/segment/BDF 是否一致。
  // 输入/输出及副作用：lhs、rhs 为值输入；返回 bit，无副作用。
  // 失败/边界：任一字段不同返回 0。
  protected function bit same_route(rdma_route_key_t lhs,
                                    rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction

  // 功能：按 role 给出 payload 的 DMA 方向。
  // 输入/输出及副作用：role 为输入；返回 DMA 方向。
  // 失败/边界：CQ/CEQ/AEQ ring 为 DEVICE_WRITE，其余为 DEVICE_READ。
  protected function rdma_dma_direction_e payload_direction(
    rdma_queue_backing_role_e role
  );
    if (role inside {RDMA_QUEUE_ROLE_CQ_RING,
                     RDMA_QUEUE_ROLE_CEQ_RING,
                     RDMA_QUEUE_ROLE_AEQ_RING})
      return RDMA_DMA_DEVICE_WRITE;
    return RDMA_DMA_DEVICE_READ;
  endfunction

  // 功能：把 DMA 方向转为 device_read/device_write 权限位。
  // 输入/输出及副作用：direction 为输入；返回权限结构。
  // 失败/边界：BIDIRECTIONAL 同时置读写位；其余值只置对应位。
  protected function rdma_dma_permission_t direction_permissions(
    rdma_dma_direction_e direction
  );
    rdma_dma_permission_t permissions;

    permissions = '0;
    permissions.device_read = direction inside {
      RDMA_DMA_DEVICE_READ, RDMA_DMA_BIDIRECTIONAL
    };
    permissions.device_write = direction inside {
      RDMA_DMA_DEVICE_WRITE, RDMA_DMA_BIDIRECTIONAL
    };
    return permissions;
  endfunction

  // 功能：校验 preflight ring 的期望布局（entry size、字节数、页数）。
  // 输入/输出及副作用：binding 提供 Function 容量；preflight、ring 只读；返回 status。
  // 失败/边界：role 非 payload、尺寸不符、乘法/对齐溢出、超出容量或单页目录上限、字节/页数非规范值，
  //   均返回 INVALID_ARGUMENT。
  protected function rdma_status expected_layout_status(
    rdma_function_binding binding,
    rdma_queue_preflight preflight,
    rdma_queue_ring_layout ring
  );
    int unsigned expected_entry_size;
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;
    longint unsigned capability_limit;

    if (ring == null || !rdma_queue_role_is_payload(ring.role))
      return invalid_argument("queue preflight ring role is invalid");
    case (ring.role)
      RDMA_QUEUE_ROLE_CQ_RING:
        expected_entry_size = preflight.cqe_size_bytes;
      RDMA_QUEUE_ROLE_SRQ_RING,
      RDMA_QUEUE_ROLE_SRFQ_RING:
        expected_entry_size = 64;
      RDMA_QUEUE_ROLE_SRQ_SGB:
        expected_entry_size = 512;
      RDMA_QUEUE_ROLE_CEQ_RING,
      RDMA_QUEUE_ROLE_AEQ_RING:
        expected_entry_size = 16;
      default:
        return invalid_argument("queue preflight contains a metadata role");
    endcase
    if (ring.depth != preflight.depth || expected_entry_size == 0 ||
        ring.entry_size_bytes != expected_entry_size)
      return invalid_argument("queue preflight ring dimensions disagree");
    if (longint'(ring.depth) >
        64'hffff_ffff_ffff_ffff / ring.entry_size_bytes)
      return invalid_argument("queue ring multiplication overflows");
    logical_bytes = longint'(ring.depth) * ring.entry_size_bytes;
    if (logical_bytes > 64'hffff_ffff_ffff_f000)
      return invalid_argument("queue ring alignment overflows");
    storage_bytes = (logical_bytes + 4095) & 64'hffff_ffff_ffff_f000;
    if (storage_bytes == 0 || storage_bytes > 32'hffff_ffff)
      return invalid_argument("queue ring exceeds host allocation width");
    capability_limit = (ring.role == RDMA_QUEUE_ROLE_SRQ_SGB) ?
      binding.queue_caps.max_sgb_bytes :
      binding.queue_caps.max_queue_ring_bytes;
    if (storage_bytes > capability_limit)
      return invalid_argument("queue ring exceeds Function capability");
    if (ring.role != RDMA_QUEUE_ROLE_SRQ_SGB &&
        storage_bytes > 64'h0020_0000)
      return invalid_argument("queue ring exceeds one page directory");
    if (ring.logical_bytes != logical_bytes ||
        ring.storage_bytes != storage_bytes ||
        ring.page_count != storage_bytes / 4096 ||
        ring.page_count == 0 ||
        (ring.role != RDMA_QUEUE_ROLE_SRQ_SGB && ring.page_count > 512))
      return invalid_argument("queue preflight ring layout is not canonical");
    return rdma_status::success();
  endfunction

  // 功能：按资源类型校验 required rings 的角色集合并逐个校验布局。
  // 输入/输出及副作用：binding、preflight 只读；返回 status。
  // 失败/边界：CQ/CEQ/AEQ 须恰一个对应 ring，SRQ 须 SRQ_RING+SRFQ_RING（max_sge>2 加 SGB）；
  //   其余类型或 ring 布局非法返回 INVALID_ARGUMENT。
  protected function rdma_status required_roles_status(
    rdma_function_binding binding,
    rdma_queue_preflight preflight
  );
    rdma_status status;
    bit need_sgb;

    need_sgb = preflight.max_sge > 2;
    case (preflight.resource_kind)
      RDMA_RESOURCE_CQ: begin
        if (preflight.required_rings.size() != 1 ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_CQ_RING)
          return invalid_argument("CQ preflight payload roles are invalid");
      end
      RDMA_RESOURCE_SRQ: begin
        if (preflight.required_rings.size() != (need_sgb ? 3 : 2) ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[1] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
            preflight.required_rings[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
            (need_sgb && (preflight.required_rings[2] == null ||
             preflight.required_rings[2].role != RDMA_QUEUE_ROLE_SRQ_SGB)))
          return invalid_argument("SRQ preflight payload roles are invalid");
      end
      RDMA_RESOURCE_CEQ: begin
        if (preflight.required_rings.size() != 1 ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_CEQ_RING)
          return invalid_argument("CEQ preflight payload roles are invalid");
      end
      RDMA_RESOURCE_AEQ: begin
        if (preflight.required_rings.size() != 1 ||
            preflight.required_rings[0] == null ||
            preflight.required_rings[0].role != RDMA_QUEUE_ROLE_AEQ_RING)
          return invalid_argument("AEQ preflight payload roles are invalid");
      end
      default:
        return invalid_argument("queue preflight resource kind is invalid");
    endcase
    foreach (preflight.required_rings[i]) begin
      status = expected_layout_status(binding, preflight,
                                      preflight.required_rings[i]);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：按 role 在 preflight 中查找 required ring。
  // 输入/输出及副作用：preflight、role 为输入；返回 ring 引用。
  // 失败/边界：未找到返回 null。
  protected function rdma_queue_ring_layout find_required_ring(
    rdma_queue_preflight preflight,
    rdma_queue_backing_role_e role
  );
    foreach (preflight.required_rings[i]) begin
      if (preflight.required_rings[i] != null &&
          preflight.required_rings[i].role == role)
        return preflight.required_rings[i];
    end
    return null;
  endfunction

  // 功能：校验 borrowed slice 对 ring 逻辑偏移的覆盖：无洞、无重叠、总长等于 storage_bytes。
  // 输入/输出及副作用：preflight、ring 只读；返回 status。
  // 失败/边界：有洞/重叠、slice 越界、总长不符或范围溢出均返回 INVALID_ARGUMENT。
  protected function rdma_status borrowed_coverage_status(
    rdma_queue_preflight preflight,
    rdma_queue_ring_layout ring
  );
    longint unsigned expected_offset;
    longint unsigned range_end;
    int match_count;
    int selected_index;

    expected_offset = 0;
    while (expected_offset < ring.storage_bytes) begin
      match_count = 0;
      selected_index = -1;
      foreach (preflight.backing_spec.slices[i]) begin
        if (preflight.backing_spec.slices[i] != null &&
            preflight.backing_spec.slices[i].role == ring.role &&
            preflight.backing_spec.slices[i].logical_queue_offset ==
              expected_offset) begin
          match_count++;
          selected_index = i;
        end
      end
      if (match_count != 1 || selected_index < 0)
        return invalid_argument("borrowed queue layout has a hole or overlap");
      if (preflight.backing_spec.slices[selected_index].length >
          ring.storage_bytes - expected_offset)
        return invalid_argument("borrowed queue slice exceeds role length");
      expected_offset +=
        preflight.backing_spec.slices[selected_index].length;
    end
    if (expected_offset != ring.storage_bytes)
      return invalid_argument("borrowed queue role length is incorrect");

    foreach (preflight.backing_spec.slices[i]) begin
      if (preflight.backing_spec.slices[i] == null ||
          preflight.backing_spec.slices[i].role != ring.role)
        continue;
      if (!rdma_queue_add_ok(
            preflight.backing_spec.slices[i].logical_queue_offset,
            preflight.backing_spec.slices[i].length))
        return invalid_argument("borrowed logical range overflows");
      range_end =
        preflight.backing_spec.slices[i].logical_queue_offset +
        preflight.backing_spec.slices[i].length;
      if (range_end > ring.storage_bytes)
        return invalid_argument("borrowed logical range exceeds role");
      for (int j = 0; j < i; j++) begin
        if (preflight.backing_spec.slices[j] == null ||
            preflight.backing_spec.slices[j].role != ring.role)
          continue;
        if (preflight.backing_spec.slices[i].logical_queue_offset <
              preflight.backing_spec.slices[j].logical_queue_offset +
                preflight.backing_spec.slices[j].length &&
            preflight.backing_spec.slices[j].logical_queue_offset < range_end)
          return invalid_argument("borrowed logical ranges overlap");
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：校验 borrowed slice 的 mapping 及 DMA 访问权限。
  // 输入/输出及副作用：binding、slice 只读；调用 mapping.check_access，返回 status。
  // 失败/边界：slice/mapping 为空或自校验失败返回其状态；IOVA/backing 范围溢出返回 DMA_TRANSLATION。
  protected function rdma_status borrowed_access_status(
    rdma_function_binding binding,
    rdma_queue_backing_slice slice
  );
    rdma_iova_t first_iova;
    rdma_dma_direction_e direction;
    rdma_dma_permission_t permissions;
    rdma_status status;

    if (slice == null || slice.mapping == null)
      return invalid_argument("borrowed queue slice is null");
    status = normalize_status(slice.validate(),
      "borrowed queue slice validation returned null");
    if (!status.ok())
      return status;
    if (slice.mapping.iova.value >
        64'hffff_ffff_ffff_ffff - slice.mapping_offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "borrowed queue IOVA offset overflows");
    if (slice.mapping.backing_addr.value >
        64'hffff_ffff_ffff_ffff - slice.mapping_offset ||
        slice.mapping.backing_addr.value + slice.mapping_offset >
          64'hffff_ffff_ffff_ffff - (slice.length - 1'b1))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "borrowed host backing range overflows");
    first_iova.value = slice.mapping.iova.value + slice.mapping_offset;
    direction = payload_direction(slice.role);
    permissions = direction_permissions(direction);
    status = normalize_status(slice.mapping.check_access(
      binding.make_handle(), binding.queue_dma.requester_bdf,
      binding.queue_dma.pasid_valid, binding.queue_dma.pasid,
      binding.queue_dma.dma_domain_valid, binding.queue_dma.dma_domain_id,
      first_iova, slice.length, direction, permissions
    ), "borrowed mapping access check returned null");
    return status;
  endfunction

  // 功能：校验 borrowed spec 中各 slice 在 IOVA 与 host backing 上互不重叠。
  // 输入/输出及副作用：spec 只读；返回 status。
  // 失败/边界：slice 或 mapping 为空、任意两 slice 的 IOVA 或 backing 区间相交，返回 INVALID_ARGUMENT。
  protected function rdma_status borrowed_overlap_status(
    rdma_queue_backing_spec spec
  );
    longint unsigned first_iova;
    longint unsigned first_backing;
    longint unsigned first_iova_last;
    longint unsigned first_backing_last;
    longint unsigned second_iova;
    longint unsigned second_backing;
    longint unsigned second_iova_last;
    longint unsigned second_backing_last;

    foreach (spec.slices[i]) begin
      if (spec.slices[i] == null || spec.slices[i].mapping == null)
        return invalid_argument("borrowed queue slice is null");
      first_iova = spec.slices[i].mapping.iova.value +
                   spec.slices[i].mapping_offset;
      first_backing = spec.slices[i].mapping.backing_addr.value +
                      spec.slices[i].mapping_offset;
      first_iova_last = first_iova + spec.slices[i].length - 1'b1;
      first_backing_last = first_backing + spec.slices[i].length - 1'b1;
      for (int j = 0; j < i; j++) begin
        if (spec.slices[j] == null || spec.slices[j].mapping == null)
          continue;
        second_iova = spec.slices[j].mapping.iova.value +
                      spec.slices[j].mapping_offset;
        second_backing = spec.slices[j].mapping.backing_addr.value +
                         spec.slices[j].mapping_offset;
        second_iova_last = second_iova + spec.slices[j].length - 1'b1;
        second_backing_last = second_backing + spec.slices[j].length - 1'b1;
        if ((first_iova <= second_iova_last &&
             second_iova <= first_iova_last) ||
            (first_backing <= second_backing_last &&
             second_backing <= first_backing_last))
          return invalid_argument(
            "borrowed queue roles overlap in IOVA or host backing"
          );
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：绑定 Host-memory 适配器。
  // 输入/输出及副作用：host_mem 为输入；成功时保存非拥有引用。
  // 失败/边界：host_mem 为空返回 INVALID_ARGUMENT；已绑定其他适配器返回 INVALID_STATE；
  //   重复绑定同一适配器视为成功。
  function rdma_status configure(rdma_host_mem_api host_mem);
    if (host_mem == null)
      return invalid_argument("queue backing planner host memory is null");
    // 设计说明：engine.configure() 可能在恢复完成后重放；重复绑定同一非拥有适配器是幂等的，
    // 切换适配器会使未完成的 release authority 失效。
    if (this.host_mem != null)
      return this.host_mem === host_mem ? rdma_status::success() :
        invalid_state("queue backing planner is already configured");
    this.host_mem = host_mem;
    return rdma_status::success();
  endfunction

  // 功能：校验 queue backing 的 preflight/binding；borrowed 模式另校验 slice。
  // 输入/输出及副作用：binding、preflight 只读；返回 status。
  // 失败/边界：输入为空或模式/角色非法返回 INVALID_ARGUMENT；Function 非 ACTIVE 返回 INVALID_STATE；
  //   owned 模式在 required roles 通过后即成功；borrowed 还须通过访问、覆盖、互不重叠检查。
  function rdma_status validate_spec(
    rdma_function_binding binding,
    rdma_queue_preflight preflight
  );
    rdma_status status;
    rdma_queue_ring_layout ring;

    if (binding == null || preflight == null)
      return invalid_argument("queue backing validation input is null");
    status = normalize_status(binding.validate(),
                              "Function binding validation returned null");
    if (!status.ok())
      return status;
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("queue backing requires an ACTIVE Function");
    status = normalize_status(preflight.validate(),
                              "queue preflight validation returned null");
    if (!status.ok())
      return status;
    status = required_roles_status(binding, preflight);
    if (!status.ok())
      return status;
    if (preflight.backing_spec.mode == RDMA_QUEUE_BACKING_OWNED)
      return rdma_status::success();
    if (preflight.backing_spec.mode != RDMA_QUEUE_BACKING_BORROWED)
      return invalid_argument("queue backing mode is invalid");

    foreach (preflight.backing_spec.slices[i]) begin
      ring = find_required_ring(preflight,
        preflight.backing_spec.slices[i] == null ? RDMA_QUEUE_ROLE_CQ_PD :
        preflight.backing_spec.slices[i].role
      );
      if (ring == null)
        return invalid_argument("borrowed queue contains an extra role");
      status = borrowed_access_status(binding,
                                       preflight.backing_spec.slices[i]);
      if (!status.ok())
        return status;
    end
    foreach (preflight.required_rings[i]) begin
      status = borrowed_coverage_status(preflight,
                                        preflight.required_rings[i]);
      if (!status.ok())
        return status;
    end
    return borrowed_overlap_status(preflight.backing_spec);
  endfunction

  // 功能：创建独立的 DMA 请求快照，带上 Function 的 route/reset epoch authority。
  // 输入/输出及副作用：binding、resource_h 为输入；request_context 为输出，只写入新建对象。
  // 失败/边界：输入为空返回 INVALID_ARGUMENT；identity 快照为空返回 INVALID_STATE；
  //   创建失败返回 RESOURCE_EXHAUSTED；失败时 request_context 为 null 或保持未发布。
  protected function rdma_status make_request_context(
    rdma_function_binding binding,
    rdma_handle resource_h,
    output rdma_dma_request_context request_context
  );
    rdma_function_identity identity;
    rdma_status status;

    request_context = null;
    if (binding == null || resource_h == null)
      return invalid_argument("queue DMA request input is null");
    status = normalize_status(binding.validate(),
                              "queue DMA Function validation returned null");
    if (!status.ok())
      return status;
    identity = binding.function_identity_snapshot();
    if (identity == null)
      return invalid_state("queue DMA Function identity snapshot is null");
    request_context = rdma_dma_request_context::type_id::create(
      "queue_backing_request_context"
    );
    if (request_context == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue DMA request context creation failed");
    request_context.function_h = binding.make_handle();
    request_context.requester_bdf = binding.queue_dma.requester_bdf;
    request_context.pasid_valid = binding.queue_dma.pasid_valid;
    request_context.pasid = binding.queue_dma.pasid;
    request_context.dma_domain_valid = binding.queue_dma.dma_domain_valid;
    request_context.dma_domain_id = binding.queue_dma.dma_domain_id;
    request_context.route = identity.route_key();
    request_context.route_valid = 1'b1;
    request_context.reset_epoch = identity.reset_epoch;
    request_context.epoch_valid = 1'b1;
    request_context.owner_h = rdma_clone_handle_value(
      resource_h, "queue DMA resource owner"
    );
    return normalize_status(request_context.validate(),
                            "queue DMA request validation returned null");
  endfunction

  // 功能：校验 host 分配返回的 mapping 与请求一致。
  // 输入/输出及副作用：binding、request_context、resource_h、mapping、length、alignment、direction 为输入；
  //   调用 mapping.check_access，返回 status。
  // 失败/边界：mapping 空或 owner 不符返回 INVALID_STATE；长度不足/范围溢出/route 错误返回
  //   DMA_TRANSLATION；未对齐返回 INVALID_ARGUMENT；reset epoch 不一致返回 STALE_GENERATION。
  protected function rdma_status allocated_mapping_status(
    rdma_function_binding binding,
    rdma_dma_request_context request_context,
    rdma_handle resource_h,
    rdma_dma_mapping mapping,
    longint unsigned length,
    longint unsigned alignment,
    rdma_dma_direction_e direction
  );
    rdma_dma_permission_t permissions;
    rdma_status status;

    if (mapping == null || request_context == null)
      return invalid_state("host allocation returned a null mapping");
    if (mapping.size < length || mapping.size == 0 ||
        mapping.iova.value > 64'hffff_ffff_ffff_ffff - (length - 1'b1) ||
        mapping.backing_addr.value >
          64'hffff_ffff_ffff_ffff - (length - 1'b1))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "allocated queue mapping is too short");
    if (!rdma_queue_aligned(mapping.iova.value, alignment) ||
        !rdma_queue_aligned(mapping.backing_addr.value, alignment))
      return invalid_argument("allocated queue mapping is unaligned");
    if (mapping.owner_h == null || !same_handle(mapping.owner_h, resource_h))
      return invalid_state("allocated queue mapping owner is incorrect");
    if (!request_context.route_valid ||
        !rdma_route_key_valid(request_context.route) ||
        !mapping.route_valid || !rdma_route_key_valid(mapping.route) ||
        !same_route(mapping.route, request_context.route))
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "allocated queue mapping route is incorrect");
    if (!request_context.epoch_valid || !mapping.epoch_valid ||
        mapping.reset_epoch != request_context.reset_epoch)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "allocated queue mapping reset epoch is stale");
    permissions = direction_permissions(direction);
    status = normalize_status(mapping.check_access(
      binding.make_handle(), binding.queue_dma.requester_bdf,
      binding.queue_dma.pasid_valid, binding.queue_dma.pasid,
      binding.queue_dma.dma_domain_valid, binding.queue_dma.dma_domain_id,
      mapping.iova, length, direction, permissions
    ), "allocated mapping access check returned null");
    return status;
  endfunction

  // 功能：回滚已获取的 mapping，并保留原始失败原因。
  // 输入/输出及副作用：mapping、original_status 为输入；opaque=1 时按 opaque identity 释放，
  //   否则按公开 authority 释放。
  // 失败/边界：mapping 为空原样返回 original_status；释放失败时返回合并了释放与原始错误文本的 status；
  //   公开 authority 未通过校验时须用 opaque 回滚。
  protected function rdma_status release_acquired_mapping(
    rdma_dma_mapping mapping,
    rdma_status original_status,
    bit opaque = 1'b0
  );
    rdma_status release_status;

    if (mapping == null)
      return original_status;
    if (opaque)
      release_status = normalize_status(host_mem.release_opaque(mapping),
                                        "opaque host rollback release returned null");
    else
      release_status = normalize_status(host_mem.\release (mapping),
                                        "host rollback release returned null");
    if (release_status.ok())
      return original_status;
    return rdma_status::make(release_status.code,
      {"queue backing rollback release failed: ", release_status.message,
       "; original failure: ", original_status.message});
  endfunction

  // 功能：分配 control-plane 拥有的 ring backing，发布带 release authority 快照的 ref。
  // 输入/输出及副作用：binding、request_context、resource_h、role、length、alignment、direction 为输入；
  //   ref_value 为输出；调用 host_mem.allocate。
  // 失败/边界：length 为 0 或超 32 位返回 INVALID_ARGUMENT；其余步骤失败时回滚已获取 mapping，ref_value 为 null。
  protected function rdma_status allocate_owned_ref(
    rdma_function_binding binding,
    rdma_dma_request_context request_context,
    rdma_handle resource_h,
    rdma_queue_backing_role_e role,
    longint unsigned length,
    longint unsigned alignment,
    rdma_dma_direction_e direction,
    output rdma_queue_backing_ref ref_value
  );
    rdma_dma_mapping acquired_mapping;
    rdma_dma_mapping authority_snapshot;
    rdma_status status;

    ref_value = null;
    if (length == 0 || length > 32'hffff_ffff)
      return invalid_argument("queue allocation length exceeds API width");
    acquired_mapping = null;
    // 把逻辑 backing role 穿过与 role 无关的 DMA 适配器边界；确定性 mock 据此消费
    // (method, role, ordinal) 故障项，真实适配器忽略。
    request_context.queue_role_valid = 1'b1;
    request_context.queue_role = int'(role);
    status = normalize_status(host_mem.allocate(
      request_context, int'(length), int'(alignment), direction,
      acquired_mapping
    ), "host queue allocation returned null status");
    if (!status.ok())
      // 适配器可能在失败时仍返回存活 mapping；此时未验证任何公开 authority，须按 opaque identity 回滚。
      return release_acquired_mapping(acquired_mapping, status, 1'b1);
    status = allocated_mapping_status(binding, request_context, resource_h,
                                      acquired_mapping,
                                      length, alignment, direction);
    if (!status.ok())
      // allocated_mapping_status 已拒绝至少一个公开 authority 字段，此时只有适配器的 opaque identity 可信。
      return release_acquired_mapping(acquired_mapping, status, 1'b1);

    // 发布 detached authority 快照，携带已检查的公开几何；其 opaque allocation identity 在 copy 前已确定，
    // 由适配器 do_copy 保持不变。
    authority_snapshot = null;
    status = normalize_status(acquired_mapping.snapshot_release_authority(
      authority_snapshot), "queue release authority snapshot returned null");
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);
    status = normalize_status(acquired_mapping.release_authority_status(
      authority_snapshot), "queue release authority check returned null");
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);
    authority_snapshot.copy(acquired_mapping);
    status = normalize_status(acquired_mapping.release_authority_status(
      authority_snapshot), "copied queue release authority check returned null");
    if (!status.ok())
      return release_acquired_mapping(acquired_mapping, status);

    ref_value = rdma_queue_backing_ref::type_id::create(
      $sformatf("queue_owned_ref_%0d", role)
    );
    if (ref_value == null)
      return release_acquired_mapping(acquired_mapping,
        rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                          "queue backing ref creation failed"));
    ref_value.role = role;
    ref_value.mapping = authority_snapshot;
    ref_value.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
    ref_value.mapping_offset = 0;
    ref_value.length = length;
    ref_value.logical_queue_offset = 0;
    return rdma_status::success();
  endfunction

  // 功能：为 CQ resize 分配新的 owned ring backing，并生成带页表的 ring 布局。
  // 输入/输出及副作用：binding、resource_h、depth、entry_size、initial_polarity 为输入；ring、ref_value 为输出。
  // 失败/边界：未配置、owner/handle 不一致、depth 或 CQE 大小不支持、容量/页数越界返回错误；
  //   失败时回滚新分配，ring 置 null，清理完成时 ref_value 也置 null。
  function rdma_status allocate_owned_cq_resize_ring(
    rdma_function_binding binding,
    rdma_handle resource_h,
    int unsigned depth,
    int unsigned entry_size,
    output rdma_queue_ring_layout ring,
    output rdma_queue_backing_ref ref_value,
    bit initial_polarity = 1'b0
  );
    rdma_dma_request_context request_context;
    rdma_function_handle owner;
    rdma_status status;
    longint unsigned logical_bytes;
    longint unsigned storage_bytes;
    int unsigned page_count;

    ring = null;
    ref_value = null;
    if (host_mem == null)
      return invalid_state("queue backing planner is not configured");
    if (binding == null || resource_h == null)
      return invalid_argument("CQ resize allocation input is null");
    status = normalize_status(binding.validate(),
                              "CQ resize Function validation returned null");
    if (!status.ok()) return status;
    if (binding.state != RDMA_BIND_ACTIVE || binding.generation == 0)
      return invalid_state("CQ resize requires an ACTIVE Function");
    owner = binding.make_handle();
    if (owner == null || resource_h.kind != RDMA_RESOURCE_CQ ||
        !same_handle(owner, binding.owner_h))
      return invalid_argument("CQ resize resource handle is invalid");
    status = normalize_status(rdma_handle_owner_status(resource_h, owner),
                              "CQ resize resource ownership returned null");
    if (!status.ok()) return status;
    if (!(entry_size inside {32, 64, 128}))
      return invalid_argument("CQ resize CQE size profile is unsupported");
    if (!rdma_is_power_of_two(depth) ||
        depth < binding.queue_caps.min_cq_depth ||
        depth > binding.queue_caps.max_cq_depth)
      return invalid_argument("CQ resize depth is outside Function capability");
    if (depth > 64'hffff_ffff_ffff_ffff / entry_size)
      return invalid_argument("CQ resize ring multiplication overflows");
    logical_bytes = longint'(depth) * entry_size;
    if (logical_bytes > 64'hffff_ffff_ffff_f000)
      return invalid_argument("CQ resize ring alignment overflows");
    storage_bytes = (logical_bytes + 4095) & 64'hffff_ffff_ffff_f000;
    if (storage_bytes == 0 || storage_bytes > 32'hffff_ffff ||
        storage_bytes > binding.queue_caps.max_queue_ring_bytes)
      return invalid_argument("CQ resize ring exceeds Function capability");
    if (storage_bytes > 64'h0020_0000)
      return invalid_argument("CQ resize ring exceeds page-directory ceiling");
    page_count = int'(storage_bytes / 4096);
    if (page_count == 0 || page_count > 512)
      return invalid_argument("CQ resize ring page count is invalid");

    ring = rdma_queue_ring_layout::type_id::create("cq_resize_ring");
    if (ring == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "CQ resize ring creation failed");
    ring.role = RDMA_QUEUE_ROLE_CQ_RING;
    ring.entry_size_bytes = entry_size;
    ring.depth = depth;
    ring.logical_bytes = logical_bytes;
    ring.storage_bytes = storage_bytes;
    ring.page_count = page_count;
    ring.initial_polarity = initial_polarity;
    status = normalize_status(ring.validate_metadata(),
                              "CQ resize ring metadata validation returned null");
    if (status.ok())
      status = make_request_context(binding, resource_h, request_context);
    if (status.ok())
      status = allocate_owned_ref(binding, request_context, resource_h,
                                  RDMA_QUEUE_ROLE_CQ_RING, storage_bytes,
                                  4096, RDMA_DMA_DEVICE_WRITE, ref_value);
    if (!status.ok()) begin
      ring = null;
      return status;
    end
    status = populate_owned_ring(ring, ref_value);
    if (status.ok())
      status = normalize_status(ref_value.validate(),
                                "CQ resize backing reference validation returned null");
    if (status.ok())
      status = normalize_status(ring.validate(),
                                "CQ resize ring validation returned null");
    if (!status.ok()) begin
      status = rollback_owned_ref(ref_value, status);
      if (ref_value.cleanup_complete)
        ref_value = null;
      ring = null;
      return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：回滚 CQ resize 的候选 owned ref，并合并原始失败原因。
  // 输入/输出及副作用：ref_value、original_status 为输入；经 cleanup_local_role 释放 host 资源。
  // 失败/边界：ref 为空原样返回 original_status；清理未完成或出错返回 RECOVERY_REQUIRED 并附原始失败文本。
  protected function rdma_status rollback_owned_ref(
    rdma_queue_backing_ref ref_value,
    rdma_status original_status
  );
    rdma_status cleanup_status;
    bit complete;
    if (ref_value == null)
      return original_status;
    cleanup_status = cleanup_local_role(ref_value, complete);
    if (cleanup_status == null || !cleanup_status.ok() || !complete) begin
      if (cleanup_status == null)
        cleanup_status = invalid_state("CQ resize candidate cleanup returned null");
      return rdma_status::make(RDMA_SC_RECOVERY_REQUIRED,
        {"CQ resize candidate cleanup failed: ", cleanup_status.message,
         "; original failure: ",
         original_status == null ? "" : original_status.message});
    end
    return original_status;
  endfunction

  // 功能：克隆 ring 布局元数据，并清空其页表。
  // 输入/输出及副作用：source 为输入；ring 为输出，是独立的新对象。
  // 失败/边界：source 为空返回 INVALID_ARGUMENT；clone/cast 失败或 clone 返回原对象返回 INVALID_STATE。
  protected function rdma_status clone_ring_metadata(
    rdma_queue_ring_layout source,
    output rdma_queue_ring_layout ring
  );
    uvm_object cloned_object;

    ring = null;
    if (source == null)
      return invalid_argument("queue ring metadata is null");
    cloned_object = source.clone();
    if (cloned_object == null || !$cast(ring, cloned_object) ||
        ring == source)
      return invalid_state("queue ring metadata clone failed");
    ring.pages.delete();
    return rdma_status::success();
  endfunction

  // 功能：向 ring 追加一个 4KB 页引用，页 IOVA 为 mapping.iova + mapping_offset。
  // 输入/输出及副作用：ring、mapping、mapping_offset、logical_offset 为输入；成功时 push 新页并校验。
  // 失败/边界：mapping 为空或 IOVA 投影溢出返回 DMA_TRANSLATION；创建失败返回 RESOURCE_EXHAUSTED。
  protected function rdma_status add_page(
    rdma_queue_ring_layout ring,
    rdma_dma_mapping mapping,
    longint unsigned mapping_offset,
    longint unsigned logical_offset
  );
    rdma_queue_dma_page_ref page;

    if (mapping == null || mapping.iova.value >
        64'hffff_ffff_ffff_ffff - mapping_offset)
      return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                               "queue page IOVA projection overflows");
    page = rdma_queue_dma_page_ref::type_id::create(
      $sformatf("queue_page_%0d_%0d", ring.role, ring.pages.size())
    );
    if (page == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue page reference creation failed");
    page.role = ring.role;
    page.mapping = mapping;
    page.mapping_offset = mapping_offset;
    page.logical_page_offset = logical_offset;
    page.page_iova.value = mapping.iova.value + mapping_offset;
    ring.pages.push_back(page);
    return normalize_status(page.validate(),
                            "queue page validation returned null");
  endfunction

  // 功能：按 4KB 逐页为 owned ring 填充页引用。
  // 输入/输出及副作用：ring、ref_value 为输入；修改 ring.pages。
  // 失败/边界：SRQ_SGB 不建页表，直接成功；add_page 失败时原样返回。
  protected function rdma_status populate_owned_ring(
    rdma_queue_ring_layout ring,
    rdma_queue_backing_ref ref_value
  );
    rdma_status status;

    if (ring.role == RDMA_QUEUE_ROLE_SRQ_SGB)
      return rdma_status::success();
    for (longint unsigned offset = 0; offset < ring.storage_bytes;
         offset += 4096) begin
      status = add_page(ring, ref_value.mapping,
                        ref_value.mapping_offset + offset, offset);
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：把 borrowed slice 组装为 ref（含额外 segment），并为 ring 逐页建立页引用。
  // 输入/输出及副作用：preflight、ring 为输入；ref_value 为输出（BORROWED），segment mapping 深拷贝。
  // 失败/边界：缺首 slice、段不连续、页跨 slice 返回 INVALID_ARGUMENT；创建失败返回 RESOURCE_EXHAUSTED；
  //   segment 克隆失败返回 INVALID_STATE；SRQ_SGB 只组装 ref，不建页表。
  protected function rdma_status populate_borrowed_ring(
    rdma_queue_preflight preflight,
    rdma_queue_ring_layout ring,
    output rdma_queue_backing_ref ref_value
  );
    rdma_queue_backing_slice first_slice;
    rdma_queue_backing_slice next_slice;
    rdma_queue_backing_slice page_slice;
    rdma_queue_backing_segment segment;
    rdma_dma_mapping segment_mapping;
    longint unsigned next_logical_offset;
    longint unsigned slice_relative_offset;
    longint unsigned page_end;
    int match_count;
    rdma_status status;

    ref_value = null;
    first_slice = null;
    foreach (preflight.backing_spec.slices[i]) begin
      if (preflight.backing_spec.slices[i] != null &&
          preflight.backing_spec.slices[i].role == ring.role &&
          preflight.backing_spec.slices[i].logical_queue_offset == 0)
        first_slice = preflight.backing_spec.slices[i];
    end
    if (first_slice == null)
      return invalid_argument("borrowed queue role has no first slice");
    ref_value = rdma_queue_backing_ref::type_id::create(
      $sformatf("queue_borrowed_ref_%0d", ring.role)
    );
    if (ref_value == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "borrowed queue ref creation failed");
    ref_value.role = ring.role;
    ref_value.mapping = first_slice.mapping;
    ref_value.ownership = RDMA_OWNERSHIP_BORROWED;
    ref_value.mapping_offset = first_slice.mapping_offset;
    ref_value.length = first_slice.length;
    ref_value.logical_queue_offset = first_slice.logical_queue_offset;

    next_logical_offset = first_slice.length;
    while (next_logical_offset < ring.storage_bytes) begin
      next_slice = null;
      match_count = 0;
      foreach (preflight.backing_spec.slices[i]) begin
        if (preflight.backing_spec.slices[i] != null &&
            preflight.backing_spec.slices[i].role == ring.role &&
            preflight.backing_spec.slices[i].logical_queue_offset ==
              next_logical_offset) begin
          next_slice = preflight.backing_spec.slices[i];
          match_count++;
        end
      end
      if (match_count != 1 || next_slice == null)
        return invalid_argument("borrowed queue segments are not contiguous");
      if (!rdma_deep_copy#(rdma_dma_mapping)::try_of(next_slice.mapping, segment_mapping))
        return invalid_state("borrowed queue segment mapping clone failed");
      segment = rdma_queue_backing_segment::type_id::create(
        $sformatf("queue_borrowed_segment_%0d_%0d", ring.role,
                  ref_value.additional_segments.size())
      );
      if (segment == null)
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "borrowed queue segment creation failed");
      segment.role = ring.role;
      segment.mapping = segment_mapping;
      segment.ownership = RDMA_OWNERSHIP_BORROWED;
      segment.mapping_offset = next_slice.mapping_offset;
      segment.length = next_slice.length;
      segment.logical_queue_offset = next_slice.logical_queue_offset;
      ref_value.additional_segments.push_back(segment);
      next_logical_offset += next_slice.length;
    end
    if (ring.role == RDMA_QUEUE_ROLE_SRQ_SGB)
      return normalize_status(ref_value.validate(),
                              "borrowed SGB ref validation returned null");

    for (longint unsigned offset = 0; offset < ring.storage_bytes;
         offset += 4096) begin
      page_end = offset + 4096;
      page_slice = null;
      match_count = 0;
      foreach (preflight.backing_spec.slices[i]) begin
        if (preflight.backing_spec.slices[i] == null ||
            preflight.backing_spec.slices[i].role != ring.role)
          continue;
        if (preflight.backing_spec.slices[i].logical_queue_offset <= offset &&
            page_end <=
              preflight.backing_spec.slices[i].logical_queue_offset +
                preflight.backing_spec.slices[i].length) begin
          page_slice = preflight.backing_spec.slices[i];
          match_count++;
        end
      end
      if (match_count != 1 || page_slice == null)
        return invalid_argument("queue page crosses a borrowed slice");
      slice_relative_offset = offset - page_slice.logical_queue_offset;
      status = add_page(ring, page_slice.mapping,
        page_slice.mapping_offset + slice_relative_offset, offset);
      if (!status.ok())
        return status;
    end
    return normalize_status(ref_value.validate(),
                            "borrowed queue ref validation returned null");
  endfunction

  // 功能：按 role 在 plan 中查找 ref。
  // 输入/输出及副作用：plan、role 为输入；返回 ref 引用。
  // 失败/边界：未找到返回 null。
  protected function rdma_queue_backing_ref find_ref(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role
  );
    foreach (plan.refs[i]) begin
      if (plan.refs[i] != null && plan.refs[i].role == role)
        return plan.refs[i];
    end
    return null;
  endfunction

  // 功能：向 plan 追加一个指向 PD ref 的 flush target。
  // 输入/输出及副作用：plan、role、phase 为输入；成功时 push 新 target 并校验。
  // 失败/边界：创建失败返回 RESOURCE_EXHAUSTED；找不到 PD ref 返回 INVALID_STATE。
  protected function rdma_status add_flush_target(
    rdma_queue_backing_plan plan,
    rdma_queue_backing_role_e role,
    rdma_queue_flush_phase_e phase
  );
    rdma_queue_flush_target target;

    target = rdma_queue_flush_target::type_id::create(
      $sformatf("queue_flush_%0d", role)
    );
    if (target == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue flush target creation failed");
    target.role = role;
    target.phase = phase;
    target.pd_ref = find_ref(plan, role);
    if (target.pd_ref == null)
      return invalid_state("queue flush target has no PD reference");
    plan.flush_targets.push_back(target);
    return normalize_status(target.validate(),
                            "queue flush target validation returned null");
  endfunction

  // 功能：校验 planner 本地 plan（无 context）的成员合法性与各资源类型的 role 排布。
  // 输入/输出及副作用：plan 只读；返回 status。
  // 失败/边界：plan 空或带 context_ref、role 排布不符返回 INVALID_STATE；成员为空或类型非法返回 INVALID_ARGUMENT。
  protected function rdma_status local_plan_status(
    rdma_queue_backing_plan plan
  );
    rdma_status status;

    if (plan == null || plan.context_ref != null)
      return invalid_state("planner-local plan context must be absent");
    foreach (plan.rings[i]) begin
      if (plan.rings[i] == null)
        return invalid_argument("planner-local plan has a null ring");
      status = normalize_status(plan.rings[i].validate(),
                                "queue ring validation returned null");
      if (!status.ok())
        return status;
    end
    foreach (plan.refs[i]) begin
      if (plan.refs[i] == null)
        return invalid_argument("planner-local plan has a null ref");
      status = normalize_status(plan.refs[i].validate(),
                                "queue ref validation returned null");
      if (!status.ok())
        return status;
    end
    foreach (plan.flush_targets[i]) begin
      if (plan.flush_targets[i] == null)
        return invalid_argument("planner-local plan has a null flush target");
      status = normalize_status(plan.flush_targets[i].validate(),
        "queue flush target validation returned null");
      if (!status.ok())
        return status;
    end
    case (plan.resource_kind)
      RDMA_RESOURCE_CQ: begin
        if (plan.rings.size() != 1 || plan.refs.size() != 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_CQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_CQ_PD ||
            plan.flush_targets.size() != 1 ||
            plan.flush_targets[0].role != RDMA_QUEUE_ROLE_CQ_PD ||
            plan.flush_targets[0].phase != RDMA_QUEUE_FLUSH_POST_DELETE)
          return invalid_state("planner-local CQ roles are invalid");
      end
      RDMA_RESOURCE_SRQ: begin
        if (plan.rings.size() < 2 || plan.rings.size() > 3 ||
            plan.refs.size() != plan.rings.size() + 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_SRQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_SRFQ_RING ||
            (plan.rings.size() == 3 &&
             plan.refs[2].role != RDMA_QUEUE_ROLE_SRQ_SGB) ||
            plan.refs[plan.refs.size()-2].role != RDMA_QUEUE_ROLE_SRQ_PD ||
            plan.refs[plan.refs.size()-1].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
            plan.flush_targets.size() != 2 ||
            plan.flush_targets[0].role != RDMA_QUEUE_ROLE_SRFQ_PD ||
            plan.flush_targets[1].role != RDMA_QUEUE_ROLE_SRQ_PD)
          return invalid_state("planner-local SRQ roles are invalid");
      end
      RDMA_RESOURCE_CEQ: begin
        if (plan.rings.size() != 1 || plan.refs.size() != 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_CEQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_CEQ_PD ||
            plan.flush_targets.size() != 0)
          return invalid_state("planner-local CEQ roles are invalid");
      end
      RDMA_RESOURCE_AEQ: begin
        if (plan.rings.size() != 1 || plan.refs.size() != 2 ||
            plan.refs[0].role != RDMA_QUEUE_ROLE_AEQ_RING ||
            plan.refs[1].role != RDMA_QUEUE_ROLE_AEQ_PD ||
            plan.flush_targets.size() != 0)
          return invalid_state("planner-local AEQ roles are invalid");
      end
      default:
        return invalid_argument("planner-local plan kind is invalid");
    endcase
    return rdma_status::success();
  endfunction

  // 功能：按逆序回滚 plan 中 control-plane 拥有的 ref，并合并失败原因。
  // 输入/输出及副作用：candidate、original_status 为输入；经 cleanup_local_role 释放 host 资源。
  // 失败/边界：candidate 为空原样返回 original_status；任一清理失败返回首个清理错误并附原始失败文本；
  //   借用 ref 不释放。
  protected function rdma_status rollback_plan(
    rdma_queue_backing_plan candidate,
    rdma_status original_status
  );
    rdma_status cleanup_status;
    rdma_status rollback_failure;
    bit complete;

    if (candidate == null)
      return original_status;
    rollback_failure = null;
    for (int i = candidate.refs.size() - 1; i >= 0; i--) begin
      if (candidate.refs[i] == null ||
          candidate.refs[i].ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
        continue;
      cleanup_status = cleanup_local_role(candidate.refs[i], complete);
      if (cleanup_status == null || !cleanup_status.ok()) begin
        if (cleanup_status == null)
          cleanup_status = invalid_state("queue rollback cleanup returned null");
        if (rollback_failure == null)
          rollback_failure = rdma_status::make(cleanup_status.code,
            {"queue backing rollback failed: ", cleanup_status.message,
             "; original failure: ", original_status.message});
      end
    end
    if (rollback_failure != null)
      return rollback_failure;
    return original_status;
  endfunction

  // 功能：把已校验的 backing 规格物化为 plan（rings、refs、PD、flush targets）。
  // 输入/输出及副作用：binding、preflight、resource_h 为输入；plan 为输出，仅成功时发布；
  //   中途失败经 rollback_plan 回滚。
  // 失败/边界：未配置、规格校验失败、handle 与 owner/kind 不符、创建失败或类型非法返回错误，plan 为 null。
  function rdma_status materialize(
    rdma_function_binding binding,
    rdma_queue_preflight preflight,
    rdma_handle resource_h,
    output rdma_queue_backing_plan plan
  );
    rdma_queue_backing_plan candidate;
    rdma_dma_request_context request_context;
    rdma_queue_ring_layout ring;
    rdma_queue_backing_ref ref_value;
    rdma_queue_backing_role_e pd_roles[$];
    rdma_status status;
    rdma_function_handle owner;

    plan = null;
    if (host_mem == null)
      return invalid_state("queue backing planner is not configured");
    status = validate_spec(binding, preflight);
    if (!status.ok())
      return status;
    owner = binding.make_handle();
    if (resource_h == null || resource_h.kind != preflight.resource_kind ||
        !same_handle(owner, binding.owner_h))
      return invalid_argument("queue resource handle is invalid");
    status = normalize_status(rdma_handle_owner_status(resource_h, owner),
                              "queue resource ownership returned null");
    if (!status.ok())
      return status;
    status = make_request_context(binding, resource_h, request_context);
    if (!status.ok())
      return status;
    candidate = rdma_queue_backing_plan::type_id::create(
      "materialized_queue_backing"
    );
    if (candidate == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "queue backing plan creation failed");
    candidate.resource_kind = preflight.resource_kind;
    candidate.context_ref = null;

    foreach (preflight.required_rings[i]) begin
      status = clone_ring_metadata(preflight.required_rings[i], ring);
      if (!status.ok())
        return rollback_plan(candidate, status);
      if (preflight.backing_spec.mode == RDMA_QUEUE_BACKING_OWNED) begin
        status = allocate_owned_ref(
          binding, request_context, resource_h, ring.role, ring.storage_bytes,
          ring.role == RDMA_QUEUE_ROLE_SRQ_SGB ? 512 : 4096,
          payload_direction(ring.role), ref_value
        );
        if (!status.ok())
          return rollback_plan(candidate, status);
        // 快照 authority 已成功，立即发布该 ref，使后续失败可经 rollback 释放。
        candidate.refs.push_back(ref_value);
        status = populate_owned_ring(ring, ref_value);
      end
      else begin
        status = populate_borrowed_ring(preflight, ring, ref_value);
        if (status.ok())
          candidate.refs.push_back(ref_value);
      end
      if (!status.ok())
        return rollback_plan(candidate, status);
      candidate.rings.push_back(ring);
    end

    case (preflight.resource_kind)
      RDMA_RESOURCE_CQ:
        pd_roles.push_back(RDMA_QUEUE_ROLE_CQ_PD);
      RDMA_RESOURCE_SRQ: begin
        pd_roles.push_back(RDMA_QUEUE_ROLE_SRQ_PD);
        pd_roles.push_back(RDMA_QUEUE_ROLE_SRFQ_PD);
      end
      RDMA_RESOURCE_CEQ:
        pd_roles.push_back(RDMA_QUEUE_ROLE_CEQ_PD);
      RDMA_RESOURCE_AEQ:
        pd_roles.push_back(RDMA_QUEUE_ROLE_AEQ_PD);
      default:
        return rollback_plan(candidate,
                             invalid_argument("queue plan kind is invalid"));
    endcase
    foreach (pd_roles[i]) begin
      status = allocate_owned_ref(
        binding, request_context, resource_h, pd_roles[i], 4096, 4096,
        RDMA_DMA_DEVICE_READ, ref_value
      );
      if (!status.ok())
        return rollback_plan(candidate, status);
      candidate.refs.push_back(ref_value);
    end

    case (preflight.resource_kind)
      RDMA_RESOURCE_CQ: begin
        status = add_flush_target(candidate, RDMA_QUEUE_ROLE_CQ_PD,
                                  RDMA_QUEUE_FLUSH_POST_DELETE);
        if (!status.ok())
          return rollback_plan(candidate, status);
      end
      RDMA_RESOURCE_SRQ: begin
        status = add_flush_target(candidate, RDMA_QUEUE_ROLE_SRFQ_PD,
                                  RDMA_QUEUE_FLUSH_PRE_DELETE);
        if (!status.ok())
          return rollback_plan(candidate, status);
        status = add_flush_target(candidate, RDMA_QUEUE_ROLE_SRQ_PD,
                                  RDMA_QUEUE_FLUSH_PRE_DELETE);
        if (!status.ok())
          return rollback_plan(candidate, status);
      end
      default: begin
      end
    endcase
    status = local_plan_status(candidate);
    if (!status.ok())
      return rollback_plan(candidate, status);
    plan = candidate;
    return rdma_status::success();
  endfunction

  // 功能：把 payload ring role 映射到其页目录（PD）role。
  // 输入/输出及副作用：payload_role 为输入；返回 PD role。
  // 失败/边界：非 CQ/SRQ/SRFQ/CEQ/AEQ ring 的输入返回 CQC_CONTEXT_SHADOW 作为兜底。
  protected function rdma_queue_backing_role_e pd_role_for(
    rdma_queue_backing_role_e payload_role
  );
    case (payload_role)
      RDMA_QUEUE_ROLE_CQ_RING: return RDMA_QUEUE_ROLE_CQ_PD;
      RDMA_QUEUE_ROLE_SRQ_RING: return RDMA_QUEUE_ROLE_SRQ_PD;
      RDMA_QUEUE_ROLE_SRFQ_RING: return RDMA_QUEUE_ROLE_SRFQ_PD;
      RDMA_QUEUE_ROLE_CEQ_RING: return RDMA_QUEUE_ROLE_CEQ_PD;
      RDMA_QUEUE_ROLE_AEQ_RING: return RDMA_QUEUE_ROLE_AEQ_PD;
      default: return RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW;
    endcase
  endfunction

  // 功能：清零 payload ref，并为每个 ring 编码页目录写入其 PD ref。
  // 输入/输出及副作用：binding、plan、pd_codec 为输入；经 host_mem.write 写 payload（含 segment）与 PD。
  // 失败/边界：未配置返回 INVALID_STATE，输入为空返回 INVALID_ARGUMENT；plan 校验失败、无 PD ref、
  //   编码长度非 4096 或写入失败返回错误；SRQ_SGB 不写页目录。
  function rdma_status initialize_payload_and_pd(
    rdma_function_binding binding,
    rdma_queue_backing_plan plan,
    rdma_hw_queue_pd_codec pd_codec
  );
    byte zeros[];
    byte pd_bytes[];
    byte unsigned encoded_pd[];
    rdma_queue_backing_ref pd_ref;
    rdma_status status;

    if (host_mem == null)
      return invalid_state("queue backing planner is not configured");
    if (binding == null || plan == null || pd_codec == null)
      return invalid_argument("queue backing initialization input is null");
    status = normalize_status(binding.validate(),
                              "Function binding validation returned null");
    if (!status.ok())
      return status;
    status = local_plan_status(plan);
    if (!status.ok())
      return status;

    foreach (plan.refs[i]) begin
      if (!rdma_queue_role_is_payload(plan.refs[i].role))
        continue;
      zeros = new[int'(plan.refs[i].length)];
      foreach (zeros[j])
        zeros[j] = 0;
      status = normalize_status(host_mem.write(
        plan.refs[i].mapping, plan.refs[i].mapping_offset, zeros
      ), "queue payload zero-write returned null");
      if (!status.ok())
        return status;
      foreach (plan.refs[i].additional_segments[j]) begin
        zeros = new[int'(plan.refs[i].additional_segments[j].length)];
        foreach (zeros[k])
          zeros[k] = 0;
        status = normalize_status(host_mem.write(
          plan.refs[i].additional_segments[j].mapping,
          plan.refs[i].additional_segments[j].mapping_offset, zeros
        ), "queue payload segment zero-write returned null");
        if (!status.ok())
          return status;
      end
    end

    foreach (plan.rings[i]) begin
      if (plan.rings[i].role == RDMA_QUEUE_ROLE_SRQ_SGB)
        continue;
      pd_ref = find_ref(plan, pd_role_for(plan.rings[i].role));
      if (pd_ref == null)
        return invalid_state("queue ring has no page directory ref");
      encoded_pd = new[0];
      status = normalize_status(pd_codec.encode_table(
        plan.rings[i].pages, binding.rdma_vf_id, encoded_pd
      ), "queue page directory codec returned null");
      if (!status.ok())
        return status;
      if (encoded_pd.size() != 4096)
        return invalid_state("queue page directory length is not 4096");
      pd_bytes = new[encoded_pd.size()];
      foreach (encoded_pd[j])
        pd_bytes[j] = encoded_pd[j];
      status = normalize_status(host_mem.write(
        pd_ref.mapping, pd_ref.mapping_offset, pd_bytes
      ), "queue page directory write returned null");
      if (!status.ok())
        return status;
    end
    return rdma_status::success();
  endfunction

  // 功能：释放 planner 持有的 mapping。
  // 输入/输出及副作用：mapping 为输入；先取 release authority 快照并在 copy 前后各校验一次，再调用 host_mem.release。
  // 失败/边界：mapping 为空返回 INVALID_ARGUMENT；快照为空返回 INVALID_STATE；校验或释放失败返回其 status。
  protected function rdma_status release_local_mapping(
    rdma_dma_mapping mapping
  );
    rdma_dma_mapping release_authority;
    rdma_status status;

    if (mapping == null)
      return invalid_argument("queue cleanup mapping is null");
    status = normalize_status(mapping.snapshot_release_authority(
      release_authority
    ), "queue cleanup authority snapshot returned null");
    if (!status.ok() || release_authority == null)
      return status.ok() ?
        invalid_state("queue cleanup authority snapshot is null") : status;
    status = normalize_status(mapping.release_authority_status(
      release_authority
    ), "queue cleanup authority check returned null");
    if (!status.ok())
      return status;
    release_authority.copy(mapping);
    status = normalize_status(mapping.release_authority_status(
      release_authority
    ), "copied queue cleanup authority check returned null");
    if (!status.ok())
      return status;
    return normalize_status(host_mem.\release (release_authority),
                            "queue host release returned null");
  endfunction

  // 功能：清理单个 ref（含额外 segment）的 host 资源，并标记是否完成。
  // 输入/输出及副作用：ref_value 为输入；complete 为输出；释放后查询 completion，成功置 cleanup_complete。
  // 失败/边界：未配置返回 INVALID_STATE；ref/mapping 为空或所有权非法返回 INVALID_ARGUMENT；
  //   BORROWED 视为完成；释放后仍未完成返回 INVALID_STATE。
  function rdma_status cleanup_local_role(
    rdma_queue_backing_ref ref_value,
    output bit complete
  );
    rdma_status status;
    bit release_complete;

    complete = 1'b0;
    if (host_mem == null)
      return invalid_state("queue backing planner is not configured");
    if (ref_value == null || ref_value.mapping == null)
      return invalid_argument("queue cleanup ref is null");
    if (ref_value.ownership == RDMA_OWNERSHIP_BORROWED) begin
      complete = 1'b1;
      return rdma_status::success();
    end
    if (ref_value.ownership != RDMA_OWNERSHIP_CONTROL_PLANE)
      return invalid_argument("queue cleanup ownership is invalid");
    ref_value.cleanup_complete = 1'b0;
    release_complete = 1'b0;
    status = normalize_status(ref_value.mapping.release_completion_status(
      release_complete), "queue release completion query returned null");
    if (!status.ok())
      return status;
    if (!release_complete) begin
      status = release_local_mapping(ref_value.mapping);
      if (!status.ok())
        return status;
      release_complete = 1'b0;
      status = normalize_status(ref_value.mapping.release_completion_status(
        release_complete), "queue release completion recheck returned null");
      if (!status.ok())
        return status;
      if (!release_complete)
        return invalid_state("queue host release did not complete");
    end

    foreach (ref_value.additional_segments[i]) begin
      if (ref_value.additional_segments[i] == null ||
          ref_value.additional_segments[i].mapping == null)
        return invalid_argument("queue cleanup segment is null");
      if (ref_value.additional_segments[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE)
        return invalid_argument("queue cleanup segment ownership is invalid");
      release_complete = 1'b0;
      status = normalize_status(
        ref_value.additional_segments[i].mapping.release_completion_status(
          release_complete
        ), "queue segment release completion query returned null"
      );
      if (!status.ok())
        return status;
      if (release_complete)
        continue;
      status = release_local_mapping(
        ref_value.additional_segments[i].mapping
      );
      if (!status.ok())
        return status;
      release_complete = 1'b0;
      status = normalize_status(
        ref_value.additional_segments[i].mapping.release_completion_status(
          release_complete
        ), "queue segment release completion recheck returned null"
      );
      if (!status.ok())
        return status;
      if (!release_complete)
        return invalid_state("queue segment host release did not complete");
    end
    ref_value.cleanup_complete = 1'b1;
    complete = 1'b1;
    return rdma_status::success();
  endfunction
endclass
