// 目录：核心执行层 src/core/rdma_responder_registry.sv。
// 职责：登记 PCIe 配置、MMIO、Host-memory 和网络 responder 的地址区间，并维护租约账本。
// 依赖：rdma_types_pkg 的 route/address/status 类型与 UVM；不依赖外部 PCIe、Host-memory、网络环境。
// 所有权与生命周期：registry 拥有内部 region 对象和 lease_id；调用方只获得登记句柄，release 成功后该句柄变为 inactive。

// 设计说明：responder 地址空间按 domain 与完整 Host/root/segment 路由隔离；同作用域内
// 仅非 MONITOR_ONLY responder 互斥，监视器可观察同一区间而不抢占所有权。
typedef enum bit [1:0] {
  RDMA_RESPONDER_CONFIG      = 2'd0,
  RDMA_RESPONDER_MMIO        = 2'd1,
  RDMA_RESPONDER_HOST_MEMORY = 2'd2,
  RDMA_RESPONDER_NETWORK     = 2'd3
} rdma_responder_domain_e;

class rdma_responder_region extends uvm_object;
  `uvm_object_utils(rdma_responder_region)

  rdma_responder_domain_e domain;
  rdma_responder_mode_e mode;
  rdma_route_key_t route;
  rdma_bar_addr_t base;
  longint unsigned size;
  string owner;
  longint unsigned lease_id;
  bit active;

  // 功能：构造未登记的 region，字段取默认值（active=0）。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：不校验字段；未经 claim 登记的对象不是有效 release 句柄。
  function new(string name = "rdma_responder_region");
    super.new(name);
    domain = RDMA_RESPONDER_CONFIG;
    mode = RDMA_RESPONDER_DUT;
    route = '0;
    base = '0;
    size = 0;
    owner = "";
    lease_id = 0;
    active = 1'b0;
  endfunction
endclass

class rdma_responder_registry extends uvm_object;
  `uvm_object_utils(rdma_responder_registry)

  protected rdma_responder_region m_regions[$];
  // m_region_lease_ids 与 m_regions 同步，记录句柄首次登记时的不可变 lease 绑定。
  protected longint unsigned m_region_lease_ids[$];
  // 账本按 lease_id 独立保存，防止调用方经返回句柄篡改冲突与释放校验依据。
  protected string m_owner_ledger[string];
  protected rdma_responder_domain_e m_domain_ledger[string];
  protected rdma_responder_mode_e m_mode_ledger[string];
  protected rdma_route_key_t m_route_ledger[string];
  protected rdma_bar_addr_t m_base_ledger[string];
  protected longint unsigned m_size_ledger[string];
  protected bit m_active_ledger[string];
  protected longint unsigned m_next_lease_id;
  protected bit m_sealed;

  // 功能：构造空 registry，lease 计数从 1 开始，未 seal。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：无。
  function new(string name = "rdma_responder_registry");
    super.new(name);
    m_next_lease_id = 1;
    m_sealed = 1'b0;
  endfunction

  // 功能：创建 source_engine 为 RDMA_ENGINE_RESOURCE 的错误状态。
  // 输入/输出及副作用：code/message 为输入，返回新 rdma_status；不改账本。
  // 失败/边界：不校验 code。
  protected function rdma_status make_status(rdma_status_code_e code, string message);
    rdma_status status;
    status = rdma_status::make(code, message);
    status.source_engine = RDMA_ENGINE_RESOURCE;
    return status;
  endfunction

  // 功能：判断 domain 是否为四个受支持的地址域之一。
  // 输入/输出及副作用：只读枚举。
  // 失败/边界：未知编码返回 0，不修正 domain。
  protected function bit valid_domain(rdma_responder_domain_e domain);
    case (domain)
      RDMA_RESPONDER_CONFIG,
      RDMA_RESPONDER_MMIO,
      RDMA_RESPONDER_HOST_MEMORY,
      RDMA_RESPONDER_NETWORK: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // 功能：判断 mode 是否为 DUT、VIP 或 MONITOR_ONLY。
  // 输入/输出及副作用：只读枚举。
  // 失败/边界：未知编码返回 0；MONITOR_ONLY 的冲突例外由 claim 处理。
  protected function bit valid_mode(rdma_responder_mode_e mode);
    case (mode)
      RDMA_RESPONDER_DUT,
      RDMA_RESPONDER_VIP,
      RDMA_RESPONDER_MONITOR_ONLY: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // 功能：判断两个 route 是否在同一冲突作用域，只比较 host_topology_key、root_id、segment。
  // 输入/输出及副作用：只读。
  // 失败/边界：BDF 差异不扩大作用域；route 合法性由 claim 校验。
  protected function bit same_scope(rdma_route_key_t lhs, rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment;
  endfunction

  // 功能：逐字段比较 route（含 BDF），避免工具对 packed struct 直接比较不一致。
  // 输入/输出及副作用：只读。
  // 失败/边界：任一字段不同返回 0；不验证 route 合法性。
  protected function bit same_route(rdma_route_key_t lhs, rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           lhs.bdf.segment == rhs.bdf.segment && lhs.bdf.bus == rhs.bdf.bus &&
           lhs.bdf.device == rhs.bdf.device &&
           lhs.bdf.function_num == rhs.bdf.function_num;
  endfunction

  // 功能：比较两个 BAR 地址的 value。
  // 输入/输出及副作用：只读。
  // 失败/边界：不检查对齐、长度或溢出。
  protected function bit same_base(rdma_bar_addr_t lhs, rdma_bar_addr_t rhs);
    return lhs.value == rhs.value;
  endfunction

  // 功能：用 65 位中间值计算闭区间末地址 base+size-1 并检测溢出。
  // 输入/输出及副作用：last_ext 输出 65 位末地址；只做加法。
  // 失败/边界：size=0 或末地址超出 64 位返回 0，调用方须拒绝。
  protected function bit compute_last(
    rdma_bar_addr_t base,
    longint unsigned size,
    output bit [64:0] last_ext
  );
    bit [64:0] size_ext;
    last_ext = '0;
    if (size == 0)
      return 1'b0;
    size_ext = {1'b0, size};
    last_ext = {1'b0, base.value} + size_ext - 65'd1;
    return !last_ext[64];
  endfunction

  // 功能：判断两段闭区间 [base, base+size-1] 是否相交。
  // 输入/输出及副作用：只读。
  // 失败/边界：调用方须先保证 size 非零且末地址不溢出，否则结果不得用于提交 claim。
  protected function bit intervals_overlap_values(
    rdma_bar_addr_t lhs_base,
    longint unsigned lhs_size,
    rdma_bar_addr_t rhs_base,
    longint unsigned rhs_size
  );
    bit [64:0] lhs_last;
    bit [64:0] rhs_last;
    void'(compute_last(lhs_base, lhs_size, lhs_last));
    void'(compute_last(rhs_base, rhs_size, rhs_last));
    return ({1'b0, lhs_base.value} <= rhs_last) &&
           ({1'b0, rhs_base.value} <= lhs_last);
  endfunction

  // 功能：登记 responder 地址区间，分配单调 lease_id 并写入 ledger 快照。
  // 输入/输出及副作用：region 输出 registry 拥有的句柄；成功时更新 m_regions 与各 ledger。
  // 失败/边界：已 sealed、domain/mode/route 非法、size=0、末地址溢出、owner 为空，或与同作用域
  //   同 domain 的非 MONITOR_ONLY active 区间重叠时返回错误，region=null 且账本不变。
  function rdma_status claim(
    rdma_responder_domain_e domain,
    rdma_responder_mode_e mode,
    rdma_route_key_t route,
    rdma_bar_addr_t base,
    longint unsigned size,
    string owner,
    output rdma_responder_region region
  );
    bit [64:0] last_ext;
    rdma_responder_region existing;
    rdma_responder_region candidate;
    string existing_key;
    string lease_key;

    region = null;
    if (m_sealed)
      return make_status(RDMA_SC_INVALID_STATE, "responder registry is sealed");
    if (!valid_domain(domain))
      return make_status(RDMA_SC_INVALID_ARGUMENT, "responder domain is invalid");
    if (!valid_mode(mode))
      return make_status(RDMA_SC_INVALID_ARGUMENT, "responder mode is invalid");
    if (!rdma_route_key_valid(route))
      return make_status(RDMA_SC_INVALID_ARGUMENT, "responder route is invalid");
    if (size == 0)
      return make_status(RDMA_SC_INVALID_ARGUMENT, "responder region size is zero");
    if (!compute_last(base, size, last_ext))
      return make_status(RDMA_SC_INVALID_ARGUMENT, "responder region end overflows 64 bits");
    if (owner.len() == 0)
      return make_status(RDMA_SC_INVALID_ARGUMENT, "responder owner is empty");

    candidate = rdma_responder_region::type_id::create("claim_candidate");
    candidate.domain = domain;
    candidate.mode = mode;
    candidate.route = route;
    candidate.base = base;
    candidate.size = size;
    candidate.owner = owner;
    candidate.active = 1'b1;

    foreach (m_regions[index]) begin
      existing = m_regions[index];
      existing_key = $sformatf("%0d", m_region_lease_ids[index]);
      if (!m_active_ledger.exists(existing_key) || !m_active_ledger[existing_key] ||
          m_domain_ledger[existing_key] != domain ||
          m_mode_ledger[existing_key] == RDMA_RESPONDER_MONITOR_ONLY ||
          mode == RDMA_RESPONDER_MONITOR_ONLY ||
          !same_scope(m_route_ledger[existing_key], route))
        continue;
      if (intervals_overlap_values(m_base_ledger[existing_key], m_size_ledger[existing_key],
                                   base, size))
        return make_status(RDMA_SC_INVALID_STATE, "responder region overlaps an active lease");
    end

    region = rdma_responder_region::type_id::create($sformatf("region_%0d", m_next_lease_id));
    region.domain = domain;
    region.mode = mode;
    region.route = route;
    region.base = base;
    region.size = size;
    region.owner = owner;
    region.lease_id = m_next_lease_id;
    region.active = 1'b1;
    m_next_lease_id++;
    m_regions.push_back(region);
    m_region_lease_ids.push_back(region.lease_id);
    lease_key = $sformatf("%0d", region.lease_id);
    m_owner_ledger[lease_key] = owner;
    m_domain_ledger[lease_key] = domain;
    m_mode_ledger[lease_key] = mode;
    m_route_ledger[lease_key] = route;
    m_base_ledger[lease_key] = base;
    m_size_ledger[lease_key] = size;
    m_active_ledger[lease_key] = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：释放 claim 返回的 region 租约，校验身份后删除内部账本项。
  // 输入/输出及副作用：成功时 region.active 清零，并从 m_regions 与各 ledger 删除；
  //   不释放外部 responder 资源。
  // 失败/边界：region 为空、未知、已 inactive 或 lease/owner/domain/mode/route/base/size 与
  //   账本不符返回 INVALID_ARGUMENT 且账本不变；sealed 不阻止 release。
  function rdma_status \release (rdma_responder_region region);
    rdma_responder_region current;
    string lease_key;
    if (region == null)
      return make_status(RDMA_SC_INVALID_ARGUMENT, "responder release handle is null");
    foreach (m_regions[index]) begin
      current = m_regions[index];
      if (current != region)
        continue;
      lease_key = $sformatf("%0d", m_region_lease_ids[index]);
      if (!m_active_ledger.exists(lease_key) || !m_active_ledger[lease_key] ||
          region.lease_id != m_region_lease_ids[index] ||
          region.owner != m_owner_ledger[lease_key] ||
          region.domain != m_domain_ledger[lease_key] ||
          region.mode != m_mode_ledger[lease_key] ||
          !same_route(region.route, m_route_ledger[lease_key]) ||
          !same_base(region.base, m_base_ledger[lease_key]) ||
          region.size != m_size_ledger[lease_key])
        return make_status(RDMA_SC_INVALID_ARGUMENT, "responder lease identity does not match");
      current.active = 1'b0;
      m_active_ledger[lease_key] = 1'b0;
      m_regions.delete(index);
      m_region_lease_ids.delete(index);
      m_owner_ledger.delete(lease_key);
      m_domain_ledger.delete(lease_key);
      m_mode_ledger.delete(lease_key);
      m_route_ledger.delete(lease_key);
      m_base_ledger.delete(lease_key);
      m_size_ledger.delete(lease_key);
      m_active_ledger.delete(lease_key);
      return rdma_status::success();
    end
    return make_status(RDMA_SC_INVALID_ARGUMENT, "responder lease is unknown");
  endfunction

  // 功能：冻结 registry，使后续 claim 失败，release 仍可清理已有租约。
  // 输入/输出及副作用：置位 m_sealed，不改动现有 region 或 ledger。
  // 失败/边界：幂等，始终返回 success。
  function rdma_status seal();
    m_sealed = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：查询 registry 是否已 seal。
  // 输入/输出及副作用：只读 m_sealed。
  // 失败/边界：无。
  function bit is_sealed();
    return m_sealed;
  endfunction

  // 功能：统计账本中仍 active 的 region 数量。
  // 输入/输出及副作用：只读，扫描 lease-id 与 active ledger。
  // 失败/边界：空 registry 返回 0；ledger 缺失的 lease 按非 active 处理。
  function int unsigned active_count();
    int unsigned count;
    count = 0;
    foreach (m_region_lease_ids[index])
      if (m_active_ledger.exists($sformatf("%0d", m_region_lease_ids[index])) &&
          m_active_ledger[$sformatf("%0d", m_region_lease_ids[index])])
        count++;
    return count;
  endfunction

  // 功能：按零基索引返回内部 region 句柄，供诊断和释放。
  // 输入/输出及副作用：返回非拥有引用，不复制。
  // 失败/边界：index 越界返回 null；release 后索引可能重排；调用方不得修改返回对象。
  function rdma_responder_region region_at(int unsigned index);
    if (index >= m_regions.size())
      return null;
    return m_regions[index];
  endfunction
endclass
