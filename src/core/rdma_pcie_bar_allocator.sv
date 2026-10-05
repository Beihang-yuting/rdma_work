// 目录：核心执行层 src/core/。
// 职责：提供 PCIe 端独立的 64-bit MMIO 区间分配与可回滚 lease，供 SR-IOV 枚举为多个
//   PF/VF 分配不重叠、按 BAR 大小对齐的窗口。
// 依赖：rdma_types_pkg 的地址/BDF 类型与 rdma_status；不依赖外部 PCIe 组件、host_mem 或
//   dpu_common，避免 PCIe 配置状态与 HMC 生命周期混淆。
// 所有权与生命周期：allocator 拥有 active lease；调用方只持引用，release_lease() 成功后
//   lease 置 inactive，区间可复用。

class rdma_pcie_bar_lease extends uvm_object;
  `rdma_object_utils(rdma_pcie_bar_lease)

  longint unsigned lease_id;
  rdma_bdf_t owner_pf_bdf;
  rdma_bar_addr_t base;
  longint unsigned size;
  longint unsigned alignment;
  bit active;

  // 功能：构造未激活的空 BAR lease。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：仅 allocate() 发布的 active lease 才能传给 release_lease()。
  function new(string name = "rdma_pcie_bar_lease");
    super.new(name);
    lease_id = 0;
    owner_pf_bdf = '0;
    base = '0;
    size = 0;
    alignment = 0;
    active = 1'b0;
  endfunction
endclass

class rdma_pcie_bar_allocator extends uvm_object;
  `rdma_object_utils(rdma_pcie_bar_allocator)

  protected bit configured;
  protected rdma_bar_addr_t aperture_base;
  protected rdma_bar_addr_t aperture_last;
  protected longint unsigned aperture_size;
  protected longint unsigned next_lease_id;
  protected rdma_pcie_bar_lease m_leases[$];

  // 功能：构造未配置的空 allocator，不预设 aperture。
  // 输入/输出及副作用：name 为对象名；清空 lease 表，configured=0。
  // 失败/边界：configure() 成功前 allocate()/release_lease() 返回 INVALID_STATE。
  function new(string name = "rdma_pcie_bar_allocator");
    super.new(name);
    configured = 1'b0;
    aperture_base = '0;
    aperture_last = '0;
    aperture_size = 0;
    next_lease_id = 1;
    m_leases.delete();
  endfunction

  // 功能：判断 value 是否为非零 2 的幂。
  // 输入/输出及副作用：返回 bit，无副作用。
  // 失败/边界：0 返回 0。
  protected function automatic bit power_of_two(longint unsigned value);
    return value != 0 && (value & (value - 1'b1)) == 0;
  endfunction

  // 功能：构造带 PCIe 来源的 allocator status。
  // 输入/输出及副作用：code/message 输入；返回新 status；factory 失败时用本地 fallback。
  // 失败/边界：不改写错误码；severity 仅 RDMA_SC_OK 为 INFO。
  protected function automatic rdma_status make_status(
    rdma_status_code_e code,
    string message
  );
    rdma_status result;
    uvm_object raw_result;

    // 不经 typed registry::create()，避免 allocator 已拒绝请求后被 factory 的 null/错误 override
    // 升级成 FCTTYP fatal。
    raw_result = factory_create_object_nonfatal(rdma_status::get_type(),
                                                "pcie_allocator_status");
    if (raw_result == null || !$cast(result, raw_result))
      result = new("pcie_allocator_status_fallback");
    result.category = rdma_status::category_for(code);
    result.code = code;
    result.hardware_code = '0;
    result.hardware_code_valid = 1'b0;
    result.source_engine = RDMA_ENGINE_PCIE;
    result.function_uid = '0;
    result.generation = '0;
    result.resource_id = '0;
    result.command_id = '0;
    result.wr_id = '0;
    result.severity = (code == RDMA_SC_OK) ? RDMA_SEVERITY_INFO
                                           : RDMA_SEVERITY_ERROR;
    result.retryable = 1'b0;
    result.message = message;
    return result;
  endfunction

  // 功能：经 raw factory 创建对象，避免 typed create 在 null/错误类型时触发 FCTTYP fatal。
  // 输入/输出及副作用：requested_type、name 输入；返回 uvm_object，不改 allocator 状态。
  // 失败/边界：requested_type 或 factory 为空时返回 null；类型转换由调用方负责。
  protected function uvm_object factory_create_object_nonfatal(
    uvm_object_wrapper requested_type,
    string name
  );
    uvm_factory factory;

    if (requested_type == null)
      return null;
    factory = uvm_factory::get();
    if (factory == null)
      return null;
    return factory.create_object_by_type(requested_type, "", name);
  endfunction

  // 功能：配置 64-bit MMIO aperture，清空旧 lease 并重置 lease ID。
  // 输入/输出及副作用：base、size 输入；成功时保存边界并置 configured。
  // 失败/边界：已配置且有 lease、size 为 0 或末端超出 64-bit 时拒绝，旧配置不变。
  function rdma_status configure(
    rdma_bar_addr_t base,
    longint unsigned size
  );
    bit [64:0] end_wide;

    if (configured && m_leases.size() != 0)
      return make_status(RDMA_SC_INVALID_STATE,
                         "PCIe BAR aperture has active leases");
    if (size == 0)
      return make_status(RDMA_SC_INVALID_ARGUMENT,
                         "PCIe BAR aperture size is zero");
    end_wide = {1'b0, base.value} + {1'b0, size} - 65'd1;
    if (end_wide[64])
      return make_status(RDMA_SC_INVALID_ARGUMENT,
                         "PCIe BAR aperture end overflows 64 bits");
    aperture_base = base;
    aperture_last.value = end_wide[63:0];
    aperture_size = size;
    configured = 1'b1;
    next_lease_id = 1;
    m_leases.delete();
    return make_status(RDMA_SC_OK, "PCIe BAR aperture configured");
  endfunction

  // 功能：把 candidate 向上对齐到 alignment。
  // 输入/输出及副作用：aligned 输出；只计算局部值。
  // 失败/边界：alignment 非 2 的幂、加法溢出 64-bit 时返回 0。
  protected function automatic bit align_up(
    longint unsigned candidate,
    longint unsigned alignment,
    output longint unsigned aligned
  );
    bit [64:0] sum_wide;
    longint unsigned mask;

    aligned = 0;
    if (!power_of_two(alignment))
      return 1'b0;
    mask = alignment - 1'b1;
    sum_wide = {1'b0, candidate} + {1'b0, mask};
    if (sum_wide[64])
      return 1'b0;
    aligned = sum_wide[63:0] & ~mask;
    return 1'b1;
  endfunction

  // 功能：查找与 [base, base+size-1] 相交的 active lease。
  // 输入/输出及副作用：hit 输出首个冲突 lease；不修改 lease。
  // 失败/边界：size 为 0 或末端溢出返回 0；溢出的异常 lease 视为冲突。
  protected function automatic bit find_overlap(
    longint unsigned base,
    longint unsigned size,
    output rdma_pcie_bar_lease hit
  );
    bit [64:0] end_wide;
    bit [64:0] lease_end_wide;
    longint unsigned last;

    hit = null;
    if (size == 0)
      return 1'b0;
    end_wide = {1'b0, base} + {1'b0, size} - 65'd1;
    if (end_wide[64])
      return 1'b0;
    last = end_wide[63:0];
    foreach (m_leases[i]) begin
      if (!m_leases[i].active)
        continue;
      lease_end_wide = {1'b0, m_leases[i].base.value} +
                       {1'b0, m_leases[i].size} - 65'd1;
      // active lease 创建前已校验范围；若遇到溢出的损坏 lease，按冲突处理，避免新分配与之重叠。
      if (lease_end_wide[64]) begin
        hit = m_leases[i];
        return 1'b1;
      end
      if (!(last < m_leases[i].base.value ||
            base > lease_end_wide[63:0])) begin
        hit = m_leases[i];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：在 aperture 内 first-fit 分配对齐的 BAR lease。
  // 输入/输出及副作用：owner_pf_bdf、size、alignment 输入，lease 输出；成功时加入 m_leases，
  //   调用方获得非拥有引用。
  // 失败/边界：未配置、BDF 为零、size<4 KiB、alignment 非法、对齐/末端溢出、空间或 ID 耗尽、
  //   factory 返回 null/错误类型/子类型均返回错误，不留半 lease。
  function rdma_status allocate(
    rdma_bdf_t owner_pf_bdf,
    longint unsigned size,
    longint unsigned alignment,
    output rdma_pcie_bar_lease lease
  );
    longint unsigned candidate;
    longint unsigned aligned;
    longint unsigned next_candidate;
    bit [64:0] end_wide;
    bit [64:0] aperture_span_wide;
    rdma_pcie_bar_lease conflict;
    rdma_pcie_bar_lease created;
    uvm_object raw_created;
    longint unsigned candidate_lease_id;

    lease = null;
    if (!configured)
      return make_status(RDMA_SC_INVALID_STATE,
                         "PCIe BAR allocator is not configured");
    if (rdma_bdf_is_zero(owner_pf_bdf))
      return make_status(RDMA_SC_INVALID_ARGUMENT,
                         "PCIe BAR lease owner PF BDF is zero");
    if (size == 0 || size < 64'd4096)
      return make_status(RDMA_SC_INVALID_ARGUMENT,
                         "PCIe BAR allocation size is below 4 KiB");
    // 聚合 VF 窗口按单个 VF aperture 对齐，因此 alignment 可小于请求 size。
    if (alignment == 0 || !power_of_two(alignment))
      return make_status(RDMA_SC_INVALID_ARGUMENT,
                         $sformatf("PCIe BAR alignment is invalid size=0x%016h alignment=0x%016h",
                                   size, alignment));
    aperture_span_wide = {1'b0, aperture_last.value} -
                         {1'b0, aperture_base.value} + 65'd1;
    if ({1'b0, size} > aperture_span_wide)
      return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                         "PCIe BAR size exceeds aperture");
    if (next_lease_id == 0)
      return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                         "PCIe BAR lease ID space is exhausted");

    candidate = aperture_base.value;
    for (int unsigned attempt = 0; attempt <= m_leases.size() + 1; attempt++) begin
      if (!align_up(candidate, alignment, aligned))
        return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                           "PCIe BAR alignment overflows 64 bits");
      if (aligned < aperture_base.value || aligned > aperture_last.value)
        return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                           "PCIe BAR aperture is exhausted");
      end_wide = {1'b0, aligned} + {1'b0, size} - 65'd1;
      if (end_wide[64] || end_wide[63:0] > aperture_last.value)
        return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                           "PCIe BAR lease exceeds aperture");
      if (!find_overlap(aligned, size, conflict)) begin
        // 先在局部 candidate 中完成 factory/类型检查和填充，全部通过后才写入 m_leases、推进
        // next_lease_id 并发布 output lease。
        candidate_lease_id = next_lease_id;
        raw_created = factory_create_object_nonfatal(
          rdma_pcie_bar_lease::get_type(),
          $sformatf("bar_lease_%0d", candidate_lease_id)
        );
        if (raw_created == null || !$cast(created, raw_created))
          return make_status(
            RDMA_SC_RESOURCE_EXHAUSTED,
            "PCIe BAR lease factory returned null or wrong type"
          );
        // Lease 是内部值对象，不允许派生子类型；即使可 cast 也拒绝，避免未知字段进入账本。
        if (created.get_object_type() != rdma_pcie_bar_lease::get_type())
          return make_status(
            RDMA_SC_INVALID_STATE,
            "PCIe BAR lease factory returned unsupported subtype"
          );
        created.lease_id = candidate_lease_id;
        created.owner_pf_bdf = owner_pf_bdf;
        created.base.value = aligned;
        created.size = size;
        created.alignment = alignment;
        created.active = 1'b1;
        m_leases.push_back(created);
        next_lease_id = candidate_lease_id + 1'b1;
        lease = created;
        return make_status(RDMA_SC_OK, "PCIe BAR lease allocated");
      end
      end_wide = {1'b0, conflict.base.value} +
                 {1'b0, conflict.size};
      if (end_wide[64])
        return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                           "PCIe BAR conflict end overflows 64 bits");
      next_candidate = end_wide[63:0];
      if (next_candidate <= candidate)
        return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                           "PCIe BAR first-fit cursor did not advance");
      candidate = next_candidate;
    end
    return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                       "PCIe BAR allocator could not find a free range");
  endfunction

  // 功能：释放 active lease，使其区间可再分配。
  // 输入/输出及副作用：lease 输入；成功时 active 清零并移出 lease 表。
  // 失败/边界：未配置、null/inactive、ID/地址/大小不匹配或不属于本 allocator 时拒绝，账本不变。
  function rdma_status release_lease(rdma_pcie_bar_lease lease);
    if (!configured)
      return make_status(RDMA_SC_INVALID_STATE,
                         "PCIe BAR allocator is not configured");
    if (lease == null || !lease.active || lease.lease_id == 0)
      return make_status(RDMA_SC_INVALID_ARGUMENT,
                         "PCIe BAR lease is null or inactive");
    foreach (m_leases[i]) begin
      if (m_leases[i] == lease &&
          m_leases[i].lease_id == lease.lease_id &&
          m_leases[i].base.value == lease.base.value &&
          m_leases[i].size == lease.size) begin
        m_leases[i].active = 1'b0;
        m_leases.delete(i);
        lease.active = 1'b0;
        return make_status(RDMA_SC_OK, "PCIe BAR lease released");
      end
    end
    return make_status(RDMA_SC_INVALID_ARGUMENT,
                       "PCIe BAR lease does not belong to allocator");
  endfunction

  // 功能：返回 active lease 数量。
  // 输入/输出及副作用：只读。
  // 失败/边界：无。
  function int unsigned active_lease_count();
    return m_leases.size();
  endfunction

  // 功能：按索引返回 lease 的非拥有引用，供调试/验证。
  // 输入/输出及副作用：index 输入；不转移所有权。
  // 失败/边界：index 越界返回 null。
  function rdma_pcie_bar_lease lease_at(int unsigned index);
    if (index >= m_leases.size())
      return null;
    return m_leases[index];
  endfunction
endclass
