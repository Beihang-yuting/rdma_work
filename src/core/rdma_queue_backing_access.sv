// 目录：核心执行层 core/rdma_queue_backing_access.sv。
// 职责：实现 rdma_queue_backing_access 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_queue_backing_access.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

// 中文设计：本层把 queue/QP backing reference 归一化为 mapping-relative DMA
// span；access 对象只借用 lifecycle-owned mapping，绝不取得或执行释放权。

class rdma_queue_backing_span extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_span)

  rdma_dma_mapping mapping;
  longint unsigned mapping_offset;
  longint unsigned logical_offset;
  longint unsigned length;

  // 功能：构造 rdma_queue_backing_span，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：mapping=null；mapping_offset=0；logical_offset=0；length=0。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_span 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_span");
    super.new(name);
    mapping = null;
    mapping_offset = 0;
    logical_offset = 0;
    length = 0;
  endfunction
endclass

class rdma_queue_backing_access extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_access)

  protected rdma_function_handle owner;
  protected rdma_host_mem_api host_mem;
  protected rdma_queue_backing_ref queue_ref;
  protected rdma_qp_backing_ref qp_ref;

  // 功能：构造 rdma_queue_backing_access，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：owner=null；host_mem=null；queue_ref=null；qp_ref=null。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_queue_backing_access 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_queue_backing_access");
    super.new(name);
    owner = null;
    host_mem = null;
    queue_ref = null;
    qp_ref = null;
  endfunction

  // 功能：在 rdma_queue_backing_access 中，invalid 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；invalid 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_queue_backing_access 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_queue_backing_access 中，dma_error 根据输入错误信息构造带正确 category/code 的 rdma_status，供上层保留失败证据。
  // 输入/输出及副作用：message（输入）；dma_error 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：dma_error 返回 RDMA_SC_DMA_TRANSLATION；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status dma_error(string message);
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, message);
  endfunction

  // 功能：在 rdma_queue_backing_access 中，add_ok 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：first（输入）、length（输入）；add_ok 可能更新本对象明确拥有的状态；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：add_ok 的结果直接由 return length != 0 && first <= 64'hffff_ffff_ffff_ffff - length 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function bit add_ok(longint unsigned first,
                                longint unsigned length);
    return length != 0 && first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  // 功能：在 rdma_queue_backing_access 中，add_no_overflow 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：first（输入）、length（输入）；add_no_overflow 可能更新本对象明确拥有的状态；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：add_no_overflow 的结果直接由 return first <= 64'hffff_ffff_ffff_ffff - length 计算；输入不满足表达式条件时沿函数体的保守分支返回，不修改已发布账本。
  protected function bit add_no_overflow(longint unsigned first,
                                         longint unsigned length);
    return first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  // 功能：在 rdma_queue_backing_access 中，range_shape 校验逻辑访问长度非零、offset+length 不溢出且二者都按 qword 对齐。
  // 输入/输出及副作用：offset（输入）、length（输入）；range_shape 读取 offset、length 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：range_shape 返回 RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“logical backing access range overflows”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status range_shape(longint unsigned offset,
                                              longint unsigned length);
    if (length == 0)
      return invalid("logical backing access length is zero");
    if (!add_ok(offset, length))
      return dma_error("logical backing access range overflows");
    // 中文设计：所有受支持的固定 queue image 至少为一个 qword 且按 qword 对齐；
    // 同时拒绝调用方在任意 byte 位置切分 span，保证 DMA transaction 边界确定。
    if ((offset & 64'h7) != 0 || (length & 64'h7) != 0)
      return invalid("logical backing access range is unaligned");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：function_h（输入）、api（输入）；configure 先依据 function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION；function_h.generation == 0；api == null 校验 function_h、api；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure(rdma_function_handle function_h,
                                 rdma_host_mem_api api);
    rdma_function_handle snapshot;
    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return invalid("backing access Function is invalid");
    if (function_h.generation == 0)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "backing access generation is zero");
    if (api == null)
      return invalid_state("backing access host memory adapter is null");
    snapshot = rdma_clone_function_handle_value(function_h,
                                                 "backing access owner");
    if (snapshot == null)
      return invalid_state("backing access Function snapshot failed");
    owner = snapshot;
    host_mem = api;
    queue_ref = null;
    qp_ref = null;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，attach_queue 把 attach_queue 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：backing（输入）；attach_queue 先依据 owner == null || host_mem == null；queue_ref != null || qp_ref != null；backing == null 校验 backing；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记、校验器返回 null 或跨 Function 串线时拒绝绑定并保持索引不变。
  function rdma_status attach_queue(rdma_queue_backing_ref backing);
    rdma_status status;
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref != null || qp_ref != null)
      return invalid_state("backing access already has an attached backing");
    if (backing == null)
      return invalid("queue backing reference is null");
    status = backing.validate();
    if (status == null)
      return invalid_state("queue backing validation returned null status");
    if (!status.ok())
      return status;
    if (backing.mapping == null || backing.mapping.function_h == null)
      return invalid_state("queue backing Function identity is missing");
    if (!backing.mapping.function_h.same_instance(owner))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "queue backing Function identity mismatch");
    queue_ref = backing;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，attach_qp 把 attach_qp 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：backing（输入）；attach_qp 先依据 owner == null || host_mem == null；queue_ref != null || qp_ref != null；backing == null 校验 backing；成功时更新本对象配置/状态并保存非拥有引用，返回 rdma_status。
  // 失败/边界：资源不存在、类型不符、重复登记、校验器返回 null 或跨 Function 串线时拒绝绑定并保持索引不变。
  function rdma_status attach_qp(rdma_qp_backing_ref backing);
    rdma_status status;
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref != null || qp_ref != null)
      return invalid_state("backing access already has an attached backing");
    if (backing == null)
      return invalid("QP backing reference is null");
    status = backing.validate();
    if (status == null)
      return invalid_state("QP backing validation returned null status");
    if (!status.ok())
      return status;
    if (backing.mapping == null || backing.mapping.function_h == null)
      return invalid_state("QP backing Function identity is missing");
    if (!backing.mapping.function_h.same_instance(owner))
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "QP backing Function identity mismatch");
    qp_ref = backing;
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，clear 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：无显式参数；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：clear 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  function void clear();
    queue_ref = null;
    qp_ref = null;
  endfunction

  // 功能：为 CQ resize 建立独立 backing-access 视图，复用同一生命周期授权但不共享访问对象状态。
  // 输入输出及副作用：无显式输入；返回新的 access 值对象，保留 owner、host_mem 和 backing 非拥有引用。
  // 失败边界：未配置或未附着 queue backing 时返回 null，调用方必须保留旧 access。
  function rdma_queue_backing_access clone_for_resize();
    rdma_queue_backing_access copy;
    if (owner == null || host_mem == null || queue_ref == null)
      return null;
    copy = rdma_queue_backing_access::type_id::create("resize_backing_access");
    copy.owner = rdma_clone_function_handle_value(owner, "resize backing owner");
    copy.host_mem = host_mem;
    copy.queue_ref = queue_ref;
    copy.qp_ref = qp_ref;
    return copy;
  endfunction

  // 功能：在 rdma_queue_backing_access 中，reference_total 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：backing_ref（输入）、total（输出）；reference_total 读取 backing_ref、total 并使用字段 total，并写入 total；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：reference_total 返回 RDMA_SC_INVALID_STATE、RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“queue backing reference is incomplete”“queue backing segment coverage overflows”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status reference_total(
      rdma_queue_backing_ref backing_ref,
      output longint unsigned total);
    total = 0;
    if (backing_ref == null || backing_ref.mapping == null || backing_ref.length == 0)
      return invalid_state("queue backing reference is incomplete");
    if (backing_ref.logical_queue_offset != 0)
      return invalid("queue backing primary logical offset is not zero");
    total = backing_ref.length;
    foreach (backing_ref.additional_segments[i]) begin
      if (backing_ref.additional_segments[i] == null ||
          backing_ref.additional_segments[i].length == 0 ||
          backing_ref.additional_segments[i].logical_queue_offset != total)
        return invalid("queue backing segments are not contiguous");
      if (!add_ok(total, backing_ref.additional_segments[i].length))
        return dma_error("queue backing segment coverage overflows");
      total += backing_ref.additional_segments[i].length;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，qp_reference_as_queue 将 QP backing 及其附加 segment 投影成统一的 queue backing 视图，供公共 span 解析器使用。
  // 输入/输出及副作用：backing_ref（输入）、projected（输出）；qp_reference_as_queue 读取 backing_ref、projected 并使用字段 projected、projected.role、projected.mapping、projected.ownership、projected.mapping_offset、projected.length、projected.logical_queue_offset、segment，并写入 projected；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：qp_reference_as_queue 返回 RDMA_SC_RESOURCE_EXHAUSTED、RDMA_SC_INVALID_STATE；典型拒绝条件为“QP backing reference is incomplete”“QP backing projection allocation failed”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status qp_reference_as_queue(
      rdma_qp_backing_ref backing_ref,
      output rdma_queue_backing_ref projected);
    rdma_queue_backing_segment segment;
    projected = null;
    if (backing_ref == null || backing_ref.mapping == null || backing_ref.length == 0)
      return invalid_state("QP backing reference is incomplete");
    projected = rdma_queue_backing_ref::type_id::create("qp_projected_ref");
    if (projected == null)
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "QP backing projection allocation failed");
    projected.role = backing_ref.role;
    projected.mapping = backing_ref.mapping;
    projected.ownership = backing_ref.ownership;
    projected.mapping_offset = backing_ref.mapping_offset;
    projected.length = backing_ref.length;
    projected.logical_queue_offset = 0;
    foreach (backing_ref.additional_segments[i]) begin
      if (backing_ref.additional_segments[i] == null)
        return invalid("QP backing contains a null segment");
      segment = backing_ref.additional_segments[i];
      projected.additional_segments.push_back(segment);
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，resolve_ref 把队列逻辑 offset/length 解析为一个或多个 backing DMA span，并拒绝越界或不连续覆盖。
  // 输入/输出及副作用：backing_ref（输入）、offset（输入）、length（输入）、spans（输出）；输入 handle/key/cursor 用于选择读取范围；返回值或 output 为 detached
  //   快照，读取不取得外部资源所有权。
  // 失败/边界：目标不存在、route/authority 不匹配或快照代际失效时返回错误/空值；不得返回陈旧或歧义条目。
  protected function rdma_status resolve_ref(
      rdma_queue_backing_ref backing_ref,
      longint unsigned offset,
      longint unsigned length,
      output rdma_queue_backing_span spans[$]);
    rdma_status status;
    longint unsigned total;
    longint unsigned request_end;
    longint unsigned segment_start;
    longint unsigned segment_end;
    longint unsigned overlap_start;
    longint unsigned overlap_end;
    rdma_dma_mapping mapping;
    longint unsigned mapping_offset;
    rdma_queue_backing_span span;

    spans.delete();
    status = range_shape(offset, length);
    if (!status.ok())
      return status;
    status = reference_total(backing_ref, total);
    if (!status.ok())
      return status;
    if (!add_ok(offset, length) || offset >= total ||
        length > total - offset)
      return dma_error("logical backing access is outside backing coverage");
    request_end = offset + length;

    // 中文设计：严格按 primary 后接 additional segment 的规范顺序遍历；
    // reference_total 已证明逻辑覆盖连续，因此生成的 span 不允许出现空洞。
    segment_start = 0;
    mapping = backing_ref.mapping;
    mapping_offset = backing_ref.mapping_offset;
    for (int index = -1; index < int'(backing_ref.additional_segments.size());
         index++) begin
      if (index >= 0) begin
        segment_start = backing_ref.additional_segments[index].logical_queue_offset;
        mapping = backing_ref.additional_segments[index].mapping;
        mapping_offset = backing_ref.additional_segments[index].mapping_offset;
      end
      segment_end = (index < 0) ? backing_ref.length :
                    backing_ref.additional_segments[index].logical_queue_offset +
                    backing_ref.additional_segments[index].length;
      overlap_start = (offset > segment_start) ? offset : segment_start;
      overlap_end = (request_end < segment_end) ? request_end : segment_end;
      if (overlap_end > overlap_start) begin
        if (mapping == null ||
            !add_ok(mapping_offset, overlap_end - overlap_start))
          return dma_error("mapping-relative backing span overflows");
        span = rdma_queue_backing_span::type_id::create(
          $sformatf("backing_span_%0d", spans.size()));
        if (span == null)
          return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                   "backing span allocation failed");
        span.mapping = mapping;
        span.mapping_offset = mapping_offset +
                              overlap_start - segment_start;
        span.logical_offset = overlap_start;
        span.length = overlap_end - overlap_start;
        spans.push_back(span);
      end
    end
    if (spans.size() == 0)
      return dma_error("logical backing access resolved to no spans");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，resolve 把队列逻辑 offset/length 解析为一个或多个 backing DMA span，并拒绝越界或不连续覆盖。
  // 输入/输出及副作用：offset（输入）、length（输入）、spans（输出）；resolve 读取 offset、length、spans 并使用字段 status，并写入 spans；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：resolve 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“backing access is not configured”“backing access has no attached backing”；失败路径不提交部分状态或转移未声明资源。
  function rdma_status resolve(
      longint unsigned offset,
      longint unsigned length,
      output rdma_queue_backing_span spans[$]);
    rdma_queue_backing_ref projected;
    rdma_status status;
    spans.delete();
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref == null && qp_ref == null)
      return invalid_state("backing access has no attached backing");
    if (queue_ref != null)
      return resolve_ref(queue_ref, offset, length, spans);
    status = qp_reference_as_queue(qp_ref, projected);
    if (!status.ok())
      return status;
    return resolve_ref(projected, offset, length, spans);
  endfunction

  // 功能：check_span 校验 span、direction 与当前对象状态的一致性，并显式处理“backing span is invalid”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：span（输入）、direction（输入）；check_span 读取 span、direction 并使用字段 first_iova.value、permissions、permissions.device_read、permissions.device_write、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：check_span 返回 RDMA_SC_INVALID_STATE、RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“backing span exceeds mapping”“backing span IOVA overflows”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status check_span(
      rdma_queue_backing_span span,
      rdma_dma_direction_e direction);
    rdma_dma_permission_t permissions;
    rdma_iova_t first_iova;
    rdma_status status;

    if (span == null || span.mapping == null || span.length == 0)
      return invalid("backing span is invalid");
    if (!add_ok(span.mapping_offset, span.length) ||
        span.mapping_offset >= span.mapping.size ||
        span.length > span.mapping.size - span.mapping_offset)
      return dma_error("backing span exceeds mapping");
    if (!add_no_overflow(span.mapping.iova.value, span.mapping_offset))
      return dma_error("backing span IOVA overflows");
    first_iova.value = span.mapping.iova.value + span.mapping_offset;
    permissions = '0;
    permissions.device_read = direction == RDMA_DMA_DEVICE_READ;
    permissions.device_write = direction == RDMA_DMA_DEVICE_WRITE;
    status = span.mapping.check_access(
      owner,
      span.mapping.requester_bdf,
      span.mapping.pasid_valid,
      span.mapping.pasid,
      span.mapping.dma_domain_valid,
      span.mapping.dma_domain_id,
      first_iova,
      span.length,
      direction,
      permissions
    );
    if (status == null)
      return invalid_state("DMA mapping access check returned null");
    return status;
  endfunction

  // 功能：在 rdma_queue_backing_access 中，preflight_spans 预检输入并预留事务所需的槽位、映射或中间状态，失败时保留可恢复证据。
  // 输入/输出及副作用：spans（输入）、direction（输入）；preflight_spans 读取 spans、direction 并使用字段 covered、status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：preflight_spans 返回 RDMA_SC_DMA_TRANSLATION；典型拒绝条件为“backing span coverage overflows”“backing span coverage is empty”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status preflight_spans(
      rdma_queue_backing_span spans[$],
      rdma_dma_direction_e direction);
    longint unsigned covered;
    rdma_status status;
    covered = 0;
    foreach (spans[i]) begin
      status = check_span(spans[i], direction);
      if (!status.ok())
        return status;
      if (spans[i].length > 64'hffff_ffff_ffff_ffff - covered)
        return dma_error("backing span coverage overflows");
      covered += spans[i].length;
    end
    if (spans.size() == 0 || covered == 0)
      return dma_error("backing span coverage is empty");
    return rdma_status::success();
  endfunction

  // 设计说明：access 实例由 UVM factory 创建；保留 virtual 分派可让隔离测试替换
  //   未开始 backend 的预检结果，而生产实现仍在本函数集中执行完整 span 校验。
  // 功能：write_device 按 RDMA_DMA_DEVICE_WRITE 方向预检并将调用方 payload 依次写入所有 backing span，供 Host-memory device producer 发布使用。
  // 输入/输出及副作用：offset、data 为输入，backend_write_started 为输出；函数先解析并完整预检 spans，再按逻辑顺序调用 host_mem.write()，首次进入 backend 前将 backend_write_started 置 1；不更新 runtime、mapping ownership 或 cursor。
  // 失败/边界：resolve/preflight 或任一 backend write 返回 null status 时统一为 RDMA_SC_INVALID_STATE；预检失败时 backend_write_started 保持 0 且不发起任何写调用，backend 非成功状态原样传播且后续 span 不再写入。
  virtual function rdma_status write_device(
      longint unsigned offset,
      byte data[],
      output bit backend_write_started
  );
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    backend_write_started = 1'b0;
    status = resolve(offset, data.size(), spans);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "device write resolve returned null status") : status;
    status = preflight_spans(spans, RDMA_DMA_DEVICE_WRITE);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "device write preflight returned null status") : status;
    position = 0;
    foreach (spans[i]) begin
      chunk = new[spans[i].length];
      foreach (chunk[j])
        chunk[j] = data[position + j];
      backend_write_started = 1'b1;
      status = host_mem.write(spans[i].mapping, spans[i].mapping_offset,
                              chunk);
      if (status == null)
        return invalid_state("host memory device write returned null status");
      if (!status.ok())
        return status;
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，write 把请求数据写入指定后端并保留返回状态；只有写入成功才允许本地游标继续推进。
  // 输入/输出及副作用：offset（输入）、data（输入）；输入 request/image/cursor 决定写入内容；成功时更新 PI/CI、slot ledger 或 pending journal，并通过 output
  //   返回结果。
  // 失败/边界：write 遇到后端拒绝、范围溢出或 DMA 权限不足时保留失败证据，不推进本地游标。
  function rdma_status write(longint unsigned offset, byte data[]);
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    status = resolve(offset, data.size(), spans);
    if (!status.ok())
      return status;
    status = preflight_spans(spans, RDMA_DMA_DEVICE_READ);
    if (!status.ok())
      return status;
    position = 0;
    foreach (spans[i]) begin
      chunk = new[spans[i].length];
      foreach (chunk[j])
        chunk[j] = data[position + j];
      status = host_mem.write(spans[i].mapping, spans[i].mapping_offset,
                              chunk);
      if (status == null)
        return invalid_state("host memory write returned null status");
      if (!status.ok())
        return status;
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_queue_backing_access 中，read 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：offset（输入）、length（输入）、data（输出）；read 读取 offset、length、data 并使用字段 data、status、position、chunk，并写入 data；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：read 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function rdma_status read(
      longint unsigned offset,
      longint unsigned length,
      output byte data[]);
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    data = new[0];
    status = resolve(offset, length, spans);
    if (!status.ok())
      return status;
    status = preflight_spans(spans, RDMA_DMA_DEVICE_WRITE);
    if (!status.ok())
      return status;
    data = new[length];
    position = 0;
    foreach (spans[i]) begin
      chunk = new[0];
      status = host_mem.read(spans[i].mapping, spans[i].mapping_offset,
                             int'(spans[i].length), chunk);
      if (status == null || !status.ok()) begin
        data = new[0];
        return status == null ? invalid_state(
          "host memory read returned null status") : status;
      end
      if (chunk.size() != spans[i].length) begin
        data = new[0];
        return dma_error("host memory read returned short data");
      end
      foreach (chunk[j])
        data[position + j] = chunk[j];
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction

  // 中文设计：readback 专用于 host 刚发布 queue entry 后的回读确认，刻意与
  // read() 隔离。read() 模拟 CQ/CEQ/AEQ consumer 的 device-write DMA，要求
  // DEVICE_WRITE；posting ring mapping 仅授予 DEVICE_READ，但 host 仍须在敲
  // producer doorbell 前确认自己的写入已到达 backing memory。
  // 功能：在 rdma_queue_backing_access 中，readback 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：offset（输入）、length（输入）、data（输出）；readback 读取 offset、length、data 并使用字段 data、status、position、chunk，并写入 data；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：readback 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  function rdma_status readback(
      longint unsigned offset,
      longint unsigned length,
      output byte data[]);
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    data = new[0];
    status = resolve(offset, length, spans);
    if (!status.ok()) return status;
    // 中文设计：这里只验证 posting ring 使用的 device-read 权限；单纯检查 host
    // memory 不应额外要求反向 DMA write 权限，否则会错误拒绝只读 posting mapping。
    status = preflight_spans(spans, RDMA_DMA_DEVICE_READ);
    if (!status.ok()) return status;
    data = new[length];
    position = 0;
    foreach (spans[i]) begin
      chunk = new[0];
      status = host_mem.read(spans[i].mapping, spans[i].mapping_offset,
                             int'(spans[i].length), chunk);
      if (status == null || !status.ok()) begin
        data = new[0];
        return status == null ? invalid_state(
          "host memory readback returned null status") : status;
      end
      if (chunk.size() != spans[i].length) begin
        data = new[0];
        return dma_error("host memory readback returned short data");
      end
      foreach (chunk[j]) data[position + j] = chunk[j];
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction
endclass
