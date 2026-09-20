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

  // 功能：把调用方提供的参数拒绝原因封装为 INVALID_ARGUMENT status，供 backing
  //   access 的公开入口保持一致错误类别。
  // 输入/输出及副作用：message 为输入；函数只创建并返回包含该文本的 rdma_status，
  //   不修改 access、mapping、账本或外部 adapter。
  // 失败/边界：status 工厂本身不在此处追加校验；任意 message（包括空文本）都会被
  //   作为 INVALID_ARGUMENT 返回，调用方负责决定具体拒绝条件。
  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：把当前 access 尚未配置、后端返回 null 等生命周期/内部状态拒绝封装为
  //   INVALID_STATE status，保留调用方的诊断文本。
  // 输入/输出及副作用：message 为输入；函数只创建并返回 rdma_status，不修改 access、
  //   mapping、账本或外部 adapter。
  // 失败/边界：无论 message 内容如何都返回 INVALID_STATE；本 helper 不判断状态原因，
  //   具体拒绝条件仍由调用方负责说明。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：把 logical span、mapping 或 IOVA 范围无法转换的原因封装为
  //   DMA_TRANSLATION status，供访问路径统一报告地址错误。
  // 输入/输出及副作用：message 为输入；函数只创建并返回 rdma_status，不修改 access、
  //   mapping、账本或外部 adapter。
  // 失败/边界：任意 message 都按 DMA_TRANSLATION 返回；本 helper 不自行判断溢出或对齐，
  //   调用方必须在调用前完成对应检查。
  protected function rdma_status dma_error(string message);
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, message);
  endfunction

  // 功能：检查从 first 开始、长度为 length 的半开地址范围是否为非空且满足本层
  //   的 64-bit exclusive-end 上限，用于 backing coverage 和 mapping-relative span。
  // 输入/输出及副作用：first、length 为输入；函数返回 bit，只做算术比较，不修改
  //   access、账本、mapping 或外部资源。
  // 失败/边界：length 为 0 或 first 大于 `64'hffff_ffff_ffff_ffff-length` 时返回 0；
  //   该 helper 不检查 qword 对齐，也不把调用方的单位转换为 bytes。
  protected function bit add_ok(longint unsigned first,
                                longint unsigned length);
    return length != 0 && first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  // 功能：检查 first 加 length 的地址计算不会超过本层允许的 64-bit exclusive-end
  //   上限，供 IOVA 起点和 span coverage 的溢出门禁复用。
  // 输入/输出及副作用：first、length 为输入；函数返回 bit，不修改 access、账本、
  //   mapping 或外部资源。
  // 失败/边界：仅当 first 大于 `64'hffff_ffff_ffff_ffff-length` 时返回 0；length=0
  //   可通过此纯算术检查，是否允许空范围由调用方另行决定。
  protected function bit add_no_overflow(longint unsigned first,
                                         longint unsigned length);
    return first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  // 功能：校验一次 logical backing access 的长度、exclusive-end 和 qword 对齐，使后续
  //   span 解析可以按固定 DMA transaction 边界工作。
  // 输入/输出及副作用：offset、length 为输入；函数返回 rdma_status，只读本地算术，不
  //   修改 backing、cursor、账本或外部 adapter。
  // 失败/边界：length=0 返回 INVALID_ARGUMENT；offset+length 超界返回 DMA_TRANSLATION；
  //   offset 或 length 非 8-byte 对齐返回 INVALID_ARGUMENT；通过时返回 success。
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

  // 功能：验证 Function owner 与 Host-memory adapter，建立 backing access 的运行边界，
  //   并把 owner 保存为 detached handle snapshot。
  // 输入/输出及副作用：function_h、api 为输入；成功时更新 owner、host_mem 并清空旧
  //   queue_ref/qp_ref，host_mem 仍为调用方拥有的非拥有引用，返回 success status。
  // 失败/边界：Function 为空/类型非 FUNCTION、generation 为 0、api 为空或 owner
  //   snapshot 失败时返回对应 INVALID_ARGUMENT/STALE_GENERATION/INVALID_STATE，旧配置保持不变。
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

  // 功能：校验 queue backing reference 的完整性和 Function incarnation，并把它挂接到
  //   access 作为后续 logical span 的非拥有来源。
  // 输入/输出及副作用：backing 为输入；成功时只写 queue_ref，不复制或释放 backing
  //   mapping，返回 success status。
  // 失败/边界：access 未 configure、已有 queue/QP attachment、backing 为空、validate
  //   返回 null/失败、mapping/Function 缺失或 Function instance 不一致时拒绝，旧引用保持不变。
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

  // 功能：校验 QP backing reference 的完整性和 Function incarnation，并把它挂接到
  //   access 作为统一 queue-view 解析的非拥有来源。
  // 输入/输出及副作用：backing 为输入；成功时只写 qp_ref，不复制或释放 backing
  //   mapping，返回 success status。
  // 失败/边界：access 未 configure、已有 queue/QP attachment、backing 为空、validate
  //   返回 null/失败、mapping/Function 缺失或 Function instance 不一致时拒绝，旧引用保持不变。
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

  // 功能：清除当前 access 对 queue/QP backing 的借用引用，使后续 resolve 在重新
  //   attach 前 fail-closed。
  // 输入/输出及副作用：无输入；函数把 queue_ref、qp_ref 置 null，不修改 owner、
  //   host_mem、mapping 内容或外部生命周期账本。
  // 失败/边界：clear 是无条件幂等操作，没有 owner/generation 错误分支；调用方若在
  //   clear 后继续访问，resolve 会报告未附着 backing。
  function void clear();
    queue_ref = null;
    qp_ref = null;
  endfunction

  // 功能：为 CQ resize 建立独立的 backing-access 视图，复制 owner snapshot 并复用
  //   当前 host_mem 与 backing 引用，但不共享本 access 的 queue/QP 指针状态容器。
  // 输入/输出及副作用：无显式输入；成功返回新 access 对象，host_mem、queue_ref、
  //   qp_ref 仍是非拥有引用，不释放或复制外部 backing。
  // 失败/边界：owner/host_mem/queue_ref 任一缺失时返回 null；factory 或 owner clone
  //   失败没有 status 通道，调用方必须检查返回对象并保留旧 access。
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

  // 功能：计算 queue backing primary segment 与 additional segments 的连续 logical
  //   coverage 总长度，供 resolve_ref 判断请求是否落在完整 backing 内。
  // 输入/输出及副作用：backing_ref 为输入，total 为输出；函数只读 segment 元数据，
  //   不推进 cursor、不改 backing 或外部资源所有权。
  // 失败/边界：backing/mapping 缺失、primary logical offset 非零、segment 为空/长度为零/
  //   不连续或 coverage 溢出时返回 INVALID_STATE、INVALID_ARGUMENT 或 DMA_TRANSLATION；
  //   成功时 total 包含 primary 与所有 additional segment 长度。
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

  // 功能：把 QP backing 及其 additional segments 包装成 queue backing 视图，使公共
  //   resolve_ref 能按统一 logical offset 解析 SQ/RQ/URC span。
  // 输入/输出及副作用：backing_ref 为输入，projected 为输出；函数创建新的 projected
  //   ref，但其中 mapping/segment 仍为非拥有引用，不取得或释放 QP backing 所有权。
  // 失败/边界：backing/mapping 缺失或长度为零返回 INVALID_STATE，projection factory
  //   失败返回 RESOURCE_EXHAUSTED，任一 additional segment 为空返回 INVALID_ARGUMENT；
  //   函数不在此处验证 segment 连续性，后续 reference_total 负责该门禁。
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

  // 功能：按 primary→additional 的规范顺序，把 logical offset/length 切分为一个或
  //   多个 mapping-relative DMA span，并将每个 span 的 logical 与 mapping 偏移写入输出数组。
  // 输入/输出及副作用：backing_ref、offset、length 为输入，spans 为输出；函数先清空
  //   spans，只读 backing 元数据并返回 status，不取得 mapping 或 Host-memory 所有权。
  // 失败/边界：range shape、coverage、请求边界、mapping-relative 加法或 span factory
  //   失败时返回错误并保持 spans 为空/不完整；没有重排 segment，也不接受空洞覆盖。
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

  // 功能：根据当前 access 已附着的 queue 或 QP backing，解析一次 logical offset/length
  //   请求并返回可供 Host-memory 访问的 DMA spans。
  // 输入/输出及副作用：offset、length 为输入，spans 为输出；函数先清空 spans，必要时
  //   创建临时 QP projection，不修改 backing、cursor 或外部资源所有权。
  // 失败/边界：owner/host_mem 缺失或没有 attachment 时返回 INVALID_STATE；range、
  //   projection、coverage 或 span 解析失败时原样返回错误，不能回退到另一种 backing。
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

  // 功能：检查单个 span 的 mapping-relative 范围、IOVA 加法和 direction 对应权限，
  //   再调用 mapping.check_access 证明 owner 可执行该 DMA 操作。
  // 输入/输出及副作用：span、direction 为输入；函数读取 owner 和 mapping authority，
  //   返回 rdma_status，不修改 span、mapping、cursor 或外部资源。
  // 失败/边界：span/mapping 为空或长度为零返回 INVALID_ARGUMENT；超出 mapping、IOVA
  //   溢出返回 DMA_TRANSLATION；check_access 返回 null 时返回 INVALID_STATE，其余状态原样传播。
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

  // 功能：逐个检查 spans 的 DMA 权限并累计其 logical coverage，作为真正 Host-memory
  //   读写前的无副作用预检。
  // 输入/输出及副作用：spans、direction 为输入；函数只调用 check_span 并返回 status，
  //   不预留 slot、不修改 mapping、cursor 或外部账本。
  // 失败/边界：任一 span 校验失败、累计 coverage 溢出、spans 为空或总长度为零时返回
  //   对应错误；全部通过才返回 success，且不会替后续 backend 操作回滚副作用。
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
