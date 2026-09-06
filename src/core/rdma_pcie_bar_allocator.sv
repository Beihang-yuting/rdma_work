// 目录：核心执行层 src/core/。
// 职责：提供 PCIe 端独立的 64-bit MMIO 区间分配和可回滚 lease，供 SR-IOV
//   枚举 sequence 为多个 PF/VF 分配不重叠、按 BAR 大小对齐的地址窗口。
// 依赖：rdma_types_pkg 中的地址/BDF 类型和 rdma_status；不依赖外部 pcie_work、
//   host_mem 或 dpu_common，避免把 PCIe 配置状态和 HMC 生命周期混在一起。
// 所有权与生命周期：allocator 拥有 active lease 对象；调用方只持有 lease 引用，
//   release() 成功后 lease 标记为 inactive，allocator 可以复用其地址区间。

class rdma_pcie_bar_lease extends uvm_object;
  `uvm_object_utils(rdma_pcie_bar_lease)

  longint unsigned lease_id;
  rdma_bdf_t owner_pf_bdf;
  rdma_bar_addr_t base;
  longint unsigned size;
  longint unsigned alignment;
  bit active;

  // 功能：构造空 BAR lease 并建立未激活的默认状态。
  // 输入/输出及副作用：name（输入）；初始化本对象字段，不修改 allocator 或外部资源。
  // 失败/边界：构造成功不代表 lease 有效；只有 allocator.allocate() 发布的 active lease
  //   才能传给 release()。
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
  `uvm_object_utils(rdma_pcie_bar_allocator)

  protected bit configured;
  protected rdma_bar_addr_t aperture_base;
  protected rdma_bar_addr_t aperture_last;
  protected longint unsigned aperture_size;
  protected longint unsigned next_lease_id;
  protected rdma_pcie_bar_lease m_leases[$];

  // 功能：构造空 allocator；不预设地址范围，避免调用方忘记声明可用 MMIO aperture。
  // 输入/输出及副作用：name（输入）；清空 lease 表并将 configured 置零。
  // 失败/边界：configure() 成功前 allocate()/release() 均返回 INVALID_STATE。
  function new(string name = "rdma_pcie_bar_allocator");
    super.new(name);
    configured = 1'b0;
    aperture_base = '0;
    aperture_last = '0;
    aperture_size = 0;
    next_lease_id = 1;
    m_leases.delete();
  endfunction

  // 功能：判断 value 是否为非零 2 的幂，供 BAR size/alignment 校验复用。
  // 输入/输出及副作用：value（输入）；返回 bit，不修改 allocator 或 lease 表。
  // 失败/边界：零返回 0；所有 64-bit 值都在无符号域内判定，不发生隐式有符号转换。
  protected function automatic bit power_of_two(longint unsigned value);
    return value != 0 && (value & (value - 1'b1)) == 0;
  endfunction

  // 功能：构造统一 allocator 状态码并标记 PCIe 来源，供调用方诊断失败阶段。
  // 输入/输出及副作用：code/message（输入）；返回 detached rdma_status，不修改资源账本。
  // 失败/边界：该函数不掩盖原始错误码，也不对 message 做重试或降级处理。
  protected function automatic rdma_status make_status(
    rdma_status_code_e code,
    string message
  );
    rdma_status result;
    result = rdma_status::make(code, message);
    result.source_engine = RDMA_ENGINE_PCIE;
    return result;
  endfunction

  // 功能：配置全局 64-bit MMIO aperture，并清空旧 lease，建立新的分配代际。
  // 输入/输出及副作用：base、size（输入）；成功时保存 aperture 边界并允许后续 allocate。
  // 失败/边界：已配置且仍有 lease、size 为零、base+size-1 超过 64-bit 均拒绝，旧配置保持不变。
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

  // 功能：将 candidate 向上对齐到 alignment，并显式检查 65-bit 加法溢出。
  // 输入/输出及副作用：candidate、alignment（输入）；aligned（输出）；只计算局部值。
  // 失败/边界：alignment 必须是 2 的幂；对齐加法溢出或结果超过 64-bit 时返回失败。
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

  // 功能：判断 [base, base+size-1] 是否与已有 active lease 相交。
  // 输入/输出及副作用：base、size、hit（输入/输出）；hit 返回首个冲突 lease 引用。
  // 失败/边界：size 为零或末端溢出时返回失败；不修改任何 lease 状态。
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
      // Active leases are created only after range validation. Treat a
      // corrupted overflowed lease as a conflict instead of allowing a new
      // allocation to overlap an unrepresentable interval.
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

  // 功能：在 aperture 内按 first-fit 方式分配一个按 alignment 对齐的 BAR lease。
  // 输入/输出及副作用：owner_pf_bdf、size、alignment（输入）、lease（输出）；成功时向
  //   m_leases 原子加入新 lease，调用方获得该对象的非拥有引用。
  // 失败/边界：非法 BDF/size/alignment、对齐或末端溢出、空间不足均返回明确错误且不留半 lease。
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
    // Aggregate VF windows are aligned to one VF aperture even when the
    // aggregate span contains multiple VFs, so alignment may be smaller than
    // the requested allocation size.
    if (alignment == 0 || !power_of_two(alignment))
      return make_status(RDMA_SC_INVALID_ARGUMENT,
                         $sformatf("PCIe BAR alignment is invalid size=0x%016h alignment=0x%016h",
                                   size, alignment));
    aperture_span_wide = {1'b0, aperture_last.value} -
                         {1'b0, aperture_base.value} + 65'd1;
    if ({1'b0, size} > aperture_span_wide)
      return make_status(RDMA_SC_RESOURCE_EXHAUSTED,
                         "PCIe BAR size exceeds aperture");

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
        created = rdma_pcie_bar_lease::type_id::create(
          $sformatf("bar_lease_%0d", next_lease_id));
        created.lease_id = next_lease_id++;
        created.owner_pf_bdf = owner_pf_bdf;
        created.base.value = aligned;
        created.size = size;
        created.alignment = alignment;
        created.active = 1'b1;
        m_leases.push_back(created);
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

  // 功能：释放一个由本 allocator 创建的 active lease，并使其地址区间可再次分配。
  // 输入/输出及副作用：lease（输入）；成功时将 active 清零并从内部 lease 表移除。
  // 失败/边界：null、inactive、ID/地址/大小不匹配或不属于本 allocator 均拒绝；失败不改变账本。
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

  // 功能：返回当前 active lease 数量，供回滚和容量测试断言。
  // 输入/输出及副作用：无显式参数；返回整数，不修改 allocator 状态。
  // 失败/边界：allocator 未配置时返回当前空表数量（通常为零），不伪造资源可用性。
  function int unsigned active_lease_count();
    return m_leases.size();
  endfunction

  // 功能：按索引返回 active lease 的 detached 引用，供调试/验证查看分配结果。
  // 输入/输出及副作用：index（输入）；返回 lease 引用，不转移 allocator 所有权。
  // 失败/边界：index 越界返回 null；调用方不能据此绕过 release() 修改账本。
  function rdma_pcie_bar_lease lease_at(int unsigned index);
    if (index >= m_leases.size())
      return null;
    return m_leases[index];
  endfunction
endclass
