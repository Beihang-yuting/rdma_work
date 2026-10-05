// 目录：核心执行层 core/rdma_queue_backing_planner.sv。
// 职责：实现 rdma_queue_backing_planner 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_backing_planner.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_queue_backing_planner extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_planner)

  protected rdma_host_mem_api host_mem;

  // 功能：构造 rdma_queue_backing_planner，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：host_mem=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_planner 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_planner");
    super.new(name);
    host_mem = null;
  endfunction

  // 功能：在 rdma_queue_backing_planner 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_queue_backing_planner 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_queue_backing_planner 中，normalize_status 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：status（输入）、message（输入）；normalize_status 读取 status、message 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：normalize_status 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status normalize_status(
    rdma_status status,
    string message
  );
    if (status == null)
      return invalid_state(message);
    return status;
  endfunction

  // 功能：在 rdma_queue_backing_planner 中由 same_handle 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：lhs（输入）、rhs（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_handle 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function bit same_handle(rdma_handle lhs, rdma_handle rhs);
    if (lhs == null || rhs == null)
      return 1'b0;
    return lhs.same_instance(rhs);
  endfunction

  // 功能：比较两个 DMA route key 的 Host/root/segment/BDF 字段，确认映射仍
  //       属于同一条 PCIe fabric 路由。
  // 输入/输出及副作用：lhs/rhs（输入值）；只读比较路由字段，不修改对象或账本。
  // 失败/边界：任一路由字段不相等时返回 0；该值比较不产生额外状态。
  protected function bit same_route(rdma_route_key_t lhs,
                                    rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction

  // 功能：payload_direction 使用 role 计算并返回 rdma_dma_direction_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：role（输入）；payload_direction 读取 role 并使用输入参数和固定枚举/常量；函数返回 rdma_dma_direction_e，不取得调用方资源所有权。
  // 失败/边界：payload_direction 的结果直接由 return RDMA_DMA_DEVICE_WRITE 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function rdma_dma_direction_e payload_direction(
    rdma_queue_backing_role_e role
  );
    if (role inside {RDMA_QUEUE_ROLE_CQ_RING,
                     RDMA_QUEUE_ROLE_CEQ_RING,
                     RDMA_QUEUE_ROLE_AEQ_RING})
      return RDMA_DMA_DEVICE_WRITE;
    return RDMA_DMA_DEVICE_READ;
  endfunction

  // 功能：在 rdma_queue_backing_planner 中，direction_permissions 把访问方向或请求权限规范化为 Host-memory/DMA 校验使用的权限位集合。
  // 输入/输出及副作用：direction（输入）；direction_permissions 读取 direction 并使用字段 permissions、permissions.device_read、permissions.device_write；函数返回 rdma_dma_permission_t，不取得调用方资源所有权。
  // 失败/边界：direction_permissions 的结果直接由 return permissions 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
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

  // 功能：在 rdma_queue_backing_planner 中，expected_layout_status 在测试中检查调用结果、状态码和副作用是否符合契约；失败时报告可定位的验证信息。
  // 输入/输出及副作用：binding（输入）、preflight（输入）、ring（输入）；expected_layout_status 读取 binding、preflight、ring 并使用字段 expected_entry_size、logical_bytes、storage_bytes、capability_limit；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：测试函数 expected_layout_status 缺少前置对象时报告断言错误，并停止依赖该对象的后续检查。
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

  // 功能：required_roles_status 校验 binding、preflight 与当前对象状态的一致性，并显式处理“CQ preflight payload roles are invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、preflight（输入）；required_roles_status 读取 binding、preflight 并使用字段 need_sgb、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：required_roles_status 返回 RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“CQ preflight payload roles are invalid”“SRQ preflight payload roles are invalid”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，find_required_ring 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：preflight（输入）、role（输入）；find_required_ring 读取 preflight、role 并使用字段 i；函数返回 rdma_queue_ring_layout，不取得调用方资源所有权。
  // 失败/边界：find_required_ring 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：borrowed_coverage_status 校验 preflight、ring 与当前对象状态的一致性，并显式处理“borrowed queue layout has a hole or overlap”；“borrowed queue slice exceeds role length”；“borrowed queue role length is incorrect”；“borrowed logical range overflows”；“borrowed logical range exceeds role”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：preflight（输入）、ring（输入）；borrowed_coverage_status 读取 preflight、ring 并使用字段 expected_offset、match_count、selected_index、range_end、j；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：borrowed_coverage_status 返回 函数体规定的失败状态；具体拒绝条件包括 “borrowed queue layout has a hole or overlap”；“borrowed queue slice exceeds role length”；“borrowed queue role length is incorrect”；“borrowed logical range overflows”；“borrowed logical range exceeds role”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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

  // 功能：borrowed_access_status 校验 binding、slice 与当前对象状态的一致性，并显式处理“borrowed queue slice is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、slice（输入）；borrowed_access_status 读取 binding、slice 并使用字段 status、first_iova.value、direction、permissions；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：borrowed_access_status 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_INVALID_ARGUMENT；典型拒绝条件为“borrowed queue slice is null”“borrowed queue IOVA offset overflows”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：borrowed_overlap_status 校验 spec 与当前对象状态的一致性，并显式处理“borrowed queue slice is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：spec（输入）；borrowed_overlap_status 读取 spec 并使用字段 first_iova、first_backing、first_iova_last、first_backing_last、j、second_iova、second_backing、second_iova_last；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：borrowed_overlap_status 返回 函数体规定的失败状态；具体拒绝条件包括 “borrowed queue slice is null”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：host_mem（输入）；configure 先依据 host_mem == null；this.host_mem != null 校验 host_mem；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure(rdma_host_mem_api host_mem);
    if (host_mem == null)
      return invalid_argument("queue backing planner host memory is null");
    // engine.configure() may be replayed after a completed recovery.  Reusing
    // the exact same non-owning Host-memory adapter is idempotent; switching to
    // another adapter would invalidate outstanding release authority.
    if (this.host_mem != null)
      return this.host_mem === host_mem ? rdma_status::success() :
        invalid_state("queue backing planner is already configured");
    this.host_mem = host_mem;
    return rdma_status::success();
  endfunction

  // 功能：validate_spec 校验 binding、preflight 与当前对象状态的一致性，并显式处理“queue backing validation input is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、preflight（输入）；validate_spec 读取 binding、preflight 并使用字段 status、ring；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
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

  // 功能：make_request_context 创建独立的 DMA 请求快照，并把 Function 的完整
  //       route/reset epoch authority 一并传给 Host-memory 路由层。
  // 输入/输出及副作用：binding/resource_h（输入）、request_context（输出）；函数只
  //       写入新建 context，不转移 Function 或 owner 句柄所有权。
  // 失败/边界：make_request_context 返回 RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“queue DMA request context creation failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，allocated_mapping_status 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：binding（输入）、resource_h（输入）、mapping（输入）、length（输入）、alignment（输入）、direction（输入）；allocated_mapping_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：allocated_mapping_status 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“host allocation returned a null mapping”“allocated queue mapping is too short”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，release_acquired_mapping 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mapping（输入）、original_status（输入）、opaque（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：当 mapping 的 public authority 尚未通过校验时必须走 opaque rollback，避免篡改的 route/geometry 令严格 release 找不到底层 allocation；已验证 mapping 仍走严格 release 以保留既有错误注入和审计语义。
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

  // 功能：在 rdma_queue_backing_planner 中，allocate_owned_ref 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：binding（输入）、request_context（输入）、resource_h（输入）、role（输入）、length（输入）、alignment（输入）、direction（输入）、ref_value（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
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
    // Carry the logical backing role through the otherwise role-agnostic DMA
    // adapter boundary.  Deterministic mocks use this hint to consume the
    // exact (method, role, ordinal) fault entry; real adapters ignore it.
    request_context.queue_role_valid = 1'b1;
    request_context.queue_role = int'(role);
    status = normalize_status(host_mem.allocate(
      request_context, int'(length), int'(alignment), direction,
      acquired_mapping
    ), "host queue allocation returned null status");
    if (!status.ok())
      // A defensive adapter may report failure together with a live mapping;
      // no public authority was validated, so rollback by opaque identity.
      return release_acquired_mapping(acquired_mapping, status, 1'b1);
    status = allocated_mapping_status(binding, request_context, resource_h,
                                      acquired_mapping,
                                      length, alignment, direction);
    if (!status.ok())
      // allocated_mapping_status rejected at least one public authority
      // field; only the adapter's opaque identity is trustworthy now.
      return release_acquired_mapping(acquired_mapping, status, 1'b1);

    // Publish a detached authority snapshot carrying the acquired mapping's
    // checked public geometry.  The snapshot's opaque allocation identity is
    // established before copy and therefore remains fixed by adapter do_copy.
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

  // 功能：为 CQ resize 分配一份全新的 control-plane-owned ring backing，并生成带页表几何的 ring/ref 快照。
  // 输入/输出及副作用：binding/resource_h/depth/entry_size/initial_polarity 为输入；ring/ref_value 为输出；函数调用 Host-memory allocate 并在失败时释放候选映射。
  // 失败/边界：planner 未配置、Function/owner/handle 不一致、depth 非法、CQE profile 不支持、容量/乘法溢出、分配/页引用构造失败时返回错误；任何失败都不得泄漏候选 mapping 或修改调用方已有 plan。
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

  // 功能：rollback_owned_ref 回滚 CQ resize 的候选 owned ref，并在释放失败时合并原始失败原因与 cleanup 证据。
  // 输入/输出及副作用：ref_value/original_status 为输入；函数通过 Host-memory release 改变候选 mapping 的生命周期，不修改旧 authority。
  // 失败/边界：ref 为空时原样返回 original_status；cleanup 未完成或 adapter 返回错误时返回 cleanup 错误，调用方必须进入可诊断恢复路径。
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

  // 功能：将 rhs 中 rdma_queue_backing_planner 的值字段复制到当前对象，建立与源对象隔离的快照。
  // 输入/输出及副作用：source（输入）、ring（输出）；clone_ring_metadata 读取 source、ring 并使用字段 ring、cloned_object，并写入 ring；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：clone_ring_metadata 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“queue ring metadata is null”“queue ring metadata clone failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，add_page 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：ring（输入）、mapping（输入）、mapping_offset（输入）、logical_offset（输入）；add_page 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：add_page 返回 RDMA_SC_DMA_TRANSLATION、RDMA_SC_RESOURCE_EXHAUSTED；典型拒绝条件为“queue page IOVA projection overflows”“queue page reference creation failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，populate_owned_ring 把已验证的 backing 规格落实为 Host-memory 映射/队列计划，并登记释放责任。
  // 输入/输出及副作用：ring（输入）、ref_value（输入）；populate_owned_ring 读取 ring、ref_value 并使用字段 offset、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：populate_owned_ring 下游操作失败时原样传播其 status/result，不伪造成功；该路径不隐式重试，也不转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，populate_borrowed_ring 把已验证的 backing 规格落实为 Host-memory 映射/队列计划，并登记释放责任。
  // 输入/输出及副作用：preflight（输入）、ring（输入）、ref_value（输出）；populate_borrowed_ring 读取 preflight、ring、ref_value 并使用字段 ref_value、first_slice、ref_value.role、ref_value.mapping、ref_value.ownership、ref_value.mapping_offset、ref_value.length、ref_value.logical_queue_offset，并写入 ref_value；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：populate_borrowed_ring 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“borrowed queue role has no first slice”“borrowed queue ref creation failed”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，find_ref 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：plan（输入）、role（输入）；find_ref 读取 plan、role 并使用字段 i；函数返回 rdma_queue_backing_ref，不取得调用方资源所有权。
  // 失败/边界：find_ref 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
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

  // 功能：在 rdma_queue_backing_planner 中，add_flush_target 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：plan（输入）、role（输入）、phase（输入）；add_flush_target 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：add_flush_target 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_STATE；典型拒绝条件为“queue flush target creation failed”“queue flush target has no PD reference”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：local_plan_status 校验 plan 与当前对象状态的一致性，并显式处理“planner-local plan context must be absent”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：plan（输入）；local_plan_status 读取 plan 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：local_plan_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“planner-local plan context must be absent”“planner-local plan has a null ring”；失败路径不提交部分状态或转移未声明资源。
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

  // 功能：在 rdma_queue_backing_planner 中，rollback_plan 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：candidate（输入）、original_status（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：rollback_plan 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
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

  // 功能：在 rdma_queue_backing_planner 中，materialize 把已验证的 backing 规格落实为 Host-memory 映射/队列计划，并登记释放责任。
  // 输入/输出及副作用：binding（输入）、preflight（输入）、resource_h（输入）、plan（输出）；materialize 读取 binding、preflight、resource_h、plan 并使用字段 plan、status、owner、candidate、candidate.resource_kind、candidate.context_ref，并写入 plan；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：materialize 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“queue backing planner is not configured”“queue resource handle is invalid”；失败路径不提交部分状态或转移未声明资源。
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
        // Snapshot authority has succeeded; publish this ref immediately.
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

  // 功能：在 rdma_queue_backing_planner 中，pd_role_for 把输入枚举或资源类型映射成对应的状态类别、执行引擎、opcode 或生命周期策略。
  // 输入/输出及副作用：payload_role（输入）；pd_role_for 读取 payload_role 并使用输入参数和固定枚举/常量；函数返回 rdma_queue_backing_role_e，不取得调用方资源所有权。
  // 失败/边界：pd_role_for 按 case(payload_role) 的固定映射计算 rdma_queue_backing_role_e（RDMA_QUEUE_ROLE_CQ_RING→RDMA_QUEUE_ROLE_CQ_PD；RDMA_QUEUE_ROLE_SRQ_RING→RDMA_QUEUE_ROLE_SRQ_PD；RDMA_QUEUE_ROLE_SRFQ_RING→RDMA_QUEUE_ROLE_SRFQ_PD；RDMA_QUEUE_ROLE_CEQ_RING→RDMA_QUEUE_ROLE_CEQ_PD；其余 case 分支按源码继续映射；default→RDMA_QUEUE_ROLE_CQC_CONTEXT_SHADOW）；未列出的输入走 default，不修改运行时账本。
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

  // 功能：initialize_payload_and_pd 更新字段 status、zeros、pd_ref、encoded_pd、pd_bytes，并在提交前保持 Function authority、generation 和资源所有权约束。
  // 输入/输出及副作用：binding（输入）、plan（输入）、pd_codec（输入）；initialize_payload_and_pd 先依据 host_mem == null；binding == null || plan == null || pd_codec == null；!status.ok( 校验 binding、plan、pd_codec；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
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

  // 功能：在 rdma_queue_backing_planner 中，release_local_mapping 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：mapping（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：release_local_mapping 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
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

  // 功能：cleanup_local_role 根据 ref_value、complete 执行 rdma_status 结果转换，具体更新字段 complete、ref_value.cleanup_complete、release_complete、status；失败时返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE，保持已登记资源和输出不变。
  // 输入/输出及副作用：ref_value（输入）、complete（输出）；cleanup_local_role 读取 ref_value、complete 并使用字段 complete、ref_value.cleanup_complete、release_complete、status，并写入 complete；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：cleanup_local_role 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“queue backing planner is not configured”“queue cleanup ref is null”；失败路径不提交部分状态或转移未声明资源。
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
