// 目录：核心执行层 core/rdma_queue_backing_access.sv。
// 职责：把 queue/QP 逻辑范围解析为 mapping-relative spans，完整预检后按顺序搬运字节。
// 依赖：DMA handle/mapping、queue/QP backing reference、Host-memory adapter 与 UVM factory。
// 所有权与生命周期：access 拥有 detached Function owner，借用 adapter/backing/mapping；
//   clear 只解除 backing 引用，不释放资源。span 是调用局部视图，不是第二份内存账本。
// 设计：公开入口决定 DMA 方向与诊断；公共循环只搬运 bytes，不推进 PI/CI、不安装 recovery。

// span 保留逻辑与物理偏移以跨 mapping 拼接数据；mapping 生命周期始终由外部 owner 管理。
class rdma_queue_backing_span extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_span)

  rdma_dma_mapping mapping;
  longint unsigned mapping_offset;
  longint unsigned logical_offset;
  longint unsigned length;

  // 功能：构造尚未解析的 span，mapping=null，两个 offset 和 length 均为零。
  // 输入/输出及副作用：name 传给 UVM；不创建、复制或接管 mapping。
  // 失败/边界：初始空 span 不能执行 I/O，必须由 resolve_ref 填充后再经 check_span 校验。
  function new(string name = "rdma_queue_backing_span");
    super.new(name);
    mapping = null;
    mapping_offset = 0;
    logical_offset = 0;
    length = 0;
  endfunction
endclass

// access 只提供地址与 DMA 权限边界；预检不能保证后端原子写入，调用方负责部分失败恢复。
class rdma_queue_backing_access extends uvm_object;
  `uvm_object_utils(rdma_queue_backing_access)

  protected rdma_function_handle owner;
  protected rdma_host_mem_api host_mem;
  protected rdma_queue_backing_ref queue_ref;
  protected rdma_qp_backing_ref qp_ref;

  // 功能：构造未配置/未挂接的 access，清空 owner、host_mem、queue_ref 与 qp_ref。
  // 输入/输出及副作用：name 传给 UVM；不分配 mapping，也不拥有外部 adapter。
  // 失败/边界：须先 configure 再 attach 才能 resolve；构造不验证任何外部 authority。
  function new(string name = "rdma_queue_backing_access");
    super.new(name);
    owner = null;
    host_mem = null;
    queue_ref = null;
    qp_ref = null;
  endfunction

  // 功能：构造 INVALID_ARGUMENT status。
  // 输入/输出及副作用：message 为诊断文本；返回新 status，无其他副作用。
  // 失败/边界：无；任意 message（含空）都返回 INVALID_ARGUMENT。
  protected function rdma_status invalid(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：构造 INVALID_STATE status（未配置、后端返回 null 等）。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无；不判断状态原因。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：构造 DMA_TRANSLATION status（span/mapping/IOVA 无法转换）。
  // 输入/输出及副作用：message 为诊断文本；返回新 status。
  // 失败/边界：无；溢出和对齐由调用方先检查。
  protected function rdma_status dma_error(string message);
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION, message);
  endfunction

  // 功能：检查半开范围 [first, first+length) 非空且不超过 64-bit exclusive-end 上限。
  // 输入/输出及副作用：纯算术，返回 bit。
  // 失败/边界：length 为 0 或 first 大于 `64'hffff_ffff_ffff_ffff-length` 返回 0；不检查对齐。
  protected function bit add_ok(longint unsigned first,
                                longint unsigned length);
    return length != 0 && first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  // 功能：检查 first+length 不超过 64-bit exclusive-end 上限，用于 IOVA 起点和 span 溢出门禁。
  // 输入/输出及副作用：纯算术，返回 bit。
  // 失败/边界：仅 first 大于 `64'hffff_ffff_ffff_ffff-length` 返回 0；length=0 通过，是否允许由调用方定。
  protected function bit add_no_overflow(longint unsigned first,
                                         longint unsigned length);
    return first <= 64'hffff_ffff_ffff_ffff - length;
  endfunction

  // 功能：校验一次 logical backing access 的长度、exclusive-end 和 qword 对齐。
  // 输入/输出及副作用：offset、length 输入，返回 status，无副作用。
  // 失败/边界：length=0 返回 INVALID_ARGUMENT；offset+length 超界返回 DMA_TRANSLATION；
  //   offset 或 length 非 8-byte 对齐返回 INVALID_ARGUMENT。
  protected function rdma_status range_shape(longint unsigned offset,
                                              longint unsigned length);
    if (length == 0)
      return invalid("logical backing access length is zero");
    if (!add_ok(offset, length))
      return dma_error("logical backing access range overflows");
    // 固定 queue image 至少一个 qword 且按 qword 对齐；拒绝在任意 byte 处切分 span，
    // 保证 DMA transaction 边界确定。
    if ((offset & 64'h7) != 0 || (length & 64'h7) != 0)
      return invalid("logical backing access range is unaligned");
    return rdma_status::success();
  endfunction

  // 功能：验证 Function owner 与 Host-memory adapter，建立运行边界并保存 owner 的 detached 快照。
  // 输入/输出及副作用：function_h、api 输入；成功时更新 owner/host_mem 并清空旧 queue_ref/qp_ref，
  //   host_mem 为非拥有引用。
  // 失败/边界：Function 为空/非 FUNCTION、generation 为 0、api 为空或快照失败时返回
  //   INVALID_ARGUMENT/STALE_GENERATION/INVALID_STATE，旧配置不变。
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

  // 功能：校验 queue backing reference 与 Function incarnation，挂接为 logical span 的非拥有来源。
  // 输入/输出及副作用：backing 输入；成功时只写 queue_ref，不复制或释放 mapping。
  // 失败/边界：未 configure、已有 queue/QP attachment、backing 为空、validate 失败/null、
  //   mapping/Function 缺失或 Function instance 不一致时拒绝，旧引用不变。
  function rdma_status attach_queue(rdma_queue_backing_ref backing);
    rdma_status status;
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref != null || qp_ref != null)
      return invalid_state("backing access already has an attached backing");
    if (backing == null)
      return invalid("queue backing reference is null");
    status = rdma_status::nonnull(
      backing.validate(),
      "queue backing validation returned null status"
    );
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

  // 功能：校验 QP backing reference 与 Function incarnation，挂接为 queue-view 解析的非拥有来源。
  // 输入/输出及副作用：backing 输入；成功时只写 qp_ref，不复制或释放 mapping。
  // 失败/边界：同 attach_queue：未 configure、已有 attachment、backing 无效或 Function 不一致时
  //   拒绝，旧引用不变。
  function rdma_status attach_qp(rdma_qp_backing_ref backing);
    rdma_status status;
    if (owner == null || host_mem == null)
      return invalid_state("backing access is not configured");
    if (queue_ref != null || qp_ref != null)
      return invalid_state("backing access already has an attached backing");
    if (backing == null)
      return invalid("QP backing reference is null");
    status = rdma_status::nonnull(backing.validate(), "QP backing validation returned null status");
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

  // 功能：清除 queue/QP backing 借用引用，之后 resolve 在重新 attach 前 fail-closed。
  // 输入/输出及副作用：queue_ref、qp_ref 置 null；不改 owner、host_mem、mapping。
  // 失败/边界：无条件幂等；clear 后 resolve 报告未附着 backing。
  function void clear();
    queue_ref = null;
    qp_ref = null;
  endfunction

  // 功能：计算 queue backing primary 与 additional segments 的连续 logical coverage 总长度。
  // 输入/输出及副作用：backing_ref 输入，total 输出；只读 segment 元数据。
  // 失败/边界：backing/mapping 缺失、primary logical offset 非零、segment 为空/长度零/不连续或
  //   溢出时返回 INVALID_STATE、INVALID_ARGUMENT 或 DMA_TRANSLATION。
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

  // 功能：把 QP backing 及 additional segments 包装成 queue backing 视图，供 resolve_ref 统一解析。
  // 输入/输出及副作用：backing_ref 输入，projected 输出；新建 ref，mapping/segment 仍为非拥有引用。
  // 失败/边界：backing/mapping 缺失或长度为零返回 INVALID_STATE；factory 失败返回
  //   RESOURCE_EXHAUSTED；additional segment 为空返回 INVALID_ARGUMENT；连续性由 reference_total 查。
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

  // 功能：按 primary→additional 顺序把 logical offset/length 切成 mapping-relative DMA span。
  // 输入/输出及副作用：backing_ref、offset、length 输入，spans 输出（先清空）；只读 backing 元数据。
  // 失败/边界：range shape、coverage、边界、mapping-relative 加法或 span factory 失败时返回错误，
  //   spans 为空/不完整；不重排 segment，不接受空洞。
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

    // 严格按 primary 后接 additional 遍历；reference_total 已证明覆盖连续，span 不应有空洞。
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

  // 功能：按已附着的 queue 或 QP backing 解析 logical offset/length，返回 DMA spans。
  // 输入/输出及副作用：offset、length 输入，spans 输出（先清空）；QP 时创建临时 projection。
  // 失败/边界：owner/host_mem 缺失或无 attachment 返回 INVALID_STATE；其余解析失败原样返回，
  //   不回退到另一种 backing。
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

  // 功能：检查单个 span 的 mapping-relative 范围、IOVA 加法和方向权限，再调 mapping.check_access。
  // 输入/输出及副作用：span、direction 输入；读取 owner 和 mapping authority，无写副作用。
  // 失败/边界：span/mapping 为空或长度为零返回 INVALID_ARGUMENT；超 mapping 或 IOVA 溢出返回
  //   DMA_TRANSLATION；check_access 返回 null 为 INVALID_STATE，其余状态原样传播。
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

  // 功能：逐个检查 spans 的 DMA 权限并累计 logical coverage，作为读写前的无副作用预检。
  // 输入/输出及副作用：spans、direction 输入；只调用 check_span。
  // 失败/边界：任一 span 失败、coverage 溢出、spans 为空或总长为零时返回错误；不回滚后端副作用。
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

  // 设计说明：两种写入口的预检/空状态策略不同，留在入口；此处只共用 payload 切片和 backend 循环，
  //   span 字段在调用时读取，不跨 adapter 回调缓存。
  // 功能：按 spans 顺序切片 data 并写入 Host-memory。
  // 输入/输出及副作用：spans/data/null_message 输入；backend_write_started 先置 0，首次 host_mem.write
  //   前置 1；可能留下成功写入的前缀。
  // 失败/边界：caller 须已预检；后端 null 以 null_message 返回 INVALID_STATE，非成功状态原样返回
  //   且不继续后续 span；不回滚、不建恢复记录。
  protected function rdma_status write_spans(
    rdma_queue_backing_span spans[$], byte data[], string null_message,
    output bit backend_write_started
  );
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    backend_write_started = 1'b0;
    position = 0;
    foreach (spans[i]) begin
      chunk = new[spans[i].length];
      foreach (chunk[j])
        chunk[j] = data[position + j];
      backend_write_started = 1'b1;
      status = host_mem.write(spans[i].mapping, spans[i].mapping_offset, chunk);
      if (status == null)
        return invalid_state(null_message);
      if (!status.ok())
        return status;
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction

  // 设计说明：access 由 UVM factory 创建；保留 virtual 使隔离测试可替换未开始 backend 的预检结果。
  // 功能：write_device 按 RDMA_DMA_DEVICE_WRITE 预检并把 payload 依次写入所有 backing span，
  //   供 Host-memory device producer 发布使用。
  // 输入/输出及副作用：offset、data 输入，backend_write_started 输出；先解析并完整预检，再顺序
  //   host_mem.write，首次进入 backend 前置 1；不更新 runtime、ownership 或 cursor。
  // 失败/边界：resolve/preflight 或后端返回 null status 时为 INVALID_STATE；预检失败时
  //   backend_write_started 保持 0 且不写；后端非成功状态原样传播，后续 span 不再写。
  virtual function rdma_status write_device(
      longint unsigned offset,
      byte data[],
      output bit backend_write_started
  );
    rdma_queue_backing_span spans[$];
    rdma_status status;

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
    return write_spans(spans, data, "host memory device write returned null status",
                       backend_write_started);
  endfunction

  // 功能：host 发布 SQ/RQ 等条目，按 DEVICE_READ 权限预检后写入所有 spans。
  // 输入/输出及副作用：offset/data 输入；只写 backing bytes，不推进 PI/CI。
  // 失败/边界：resolve/preflight 失败零写入；后端 null 为 INVALID_STATE，其他错误原样返回；
  //   中途失败可留下前缀，恢复由调用方处理。
  function rdma_status write(longint unsigned offset, byte data[]);
    rdma_queue_backing_span spans[$];
    rdma_status status;
    bit backend_write_started;

    status = resolve(offset, data.size(), spans);
    if (!status.ok())
      return status;
    status = preflight_spans(spans, RDMA_DMA_DEVICE_READ);
    if (!status.ok())
      return status;
    return write_spans(spans, data, "host memory write returned null status",
                       backend_write_started);
  endfunction

  // 设计说明：consumer read 与 host readback 搬运相同，仅 caller 指定的 DMA 权限和诊断不同；
  //   先预检全部 spans 再读取，禁止交付失败的部分 payload。
  // 功能：read_with_permission 解析 offset/length，以 direction 完整预检后拼接各段 bytes。
  // 输入/输出及副作用：offset/length/direction/operation_name 输入，data 先清空；成功输出
  //   独立字节数组，只调用 Host-memory read，不修改 mapping/cursor/ledger。
  // 失败/边界：resolve/preflight 沿用非空 status 契约；后端 null 返回 INVALID_STATE，
  //   非成功 status 原样传播，短/长读均返回 DMA_TRANSLATION；所有失败保持 data 为空。
  protected function rdma_status read_with_permission(
    longint unsigned offset, longint unsigned length,
    rdma_dma_direction_e direction, string operation_name, output byte data[]
  );
    rdma_queue_backing_span spans[$];
    rdma_status status;
    longint unsigned position;
    byte chunk[];

    data = new[0];
    status = resolve(offset, length, spans);
    if (!status.ok())
      return status;
    status = preflight_spans(spans, direction);
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
          {"host memory ", operation_name, " returned null status"}) : status;
      end
      if (chunk.size() != spans[i].length) begin
        data = new[0];
        return dma_error({"host memory ", operation_name, " returned short data"});
      end
      foreach (chunk[j])
        data[position + j] = chunk[j];
      position += spans[i].length;
    end
    return rdma_status::success();
  endfunction

  // 功能：read 读取设备发布的 CQ/CEQ/AEQ 等 backing bytes，要求 DEVICE_WRITE 权限。
  // 输入/输出及副作用：offset/length 输入，data 输出；只读 Host-memory，不确认或消费事件。
  // 失败/边界：范围/权限/后端/null/短长读失败均清空 data，按 read 诊断返回；不自动重试。
  function rdma_status read(
      longint unsigned offset,
      longint unsigned length,
      output byte data[]);
    return read_with_permission(offset, length, RDMA_DMA_DEVICE_WRITE, "read", data);
  endfunction

  // 设计：host 发布后的回读只要求 posting ring 的 DEVICE_READ，不额外要求反向写权限。
  // 功能：readback 确认 host 刚写入的 queue bytes，读取循环与 read 共用但权限策略独立。
  // 输入/输出及副作用：offset/length 输入，data 输出；不发送 doorbell，不改变 cursor。
  // 失败/边界：范围/权限/后端/null/短长读失败均清空 data，保留原 readback 诊断；不回滚写入。
  function rdma_status readback(
      longint unsigned offset,
      longint unsigned length,
      output byte data[]);
    return read_with_permission(offset, length, RDMA_DMA_DEVICE_READ, "readback", data);
  endfunction
endclass
