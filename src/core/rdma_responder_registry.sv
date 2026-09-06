// 目录：核心执行层 src/core/rdma_responder_registry.sv。
// 职责：登记 PCIe 配置、MMIO、Host-memory 和网络 responder 的地址区间，并维护租约账本。
// 依赖：依赖 rdma_types_pkg 中的 route/address/status 类型以及 UVM object/factory；不依赖外部 PCIe、Host-memory 或网络环境。
// 所有权与生命周期：registry 拥有内部 region 对象和 lease_id；调用方只获得登记句柄，release 成功后该句柄变为 inactive。

// 中文设计说明：responder 的地址空间按 domain 和完整 Host/root/segment 路由隔离。
// 同一作用域内只有两个非 MONITOR_ONLY responder 才互斥；监视器可以观察同一区间而不抢占服务所有权。
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

  // 功能：构造一个尚未登记的 responder region，建立可安全填充的默认快照。
  // 输入输出及副作用：name 为 UVM 对象名输入；初始化 domain/mode、route/base、size、owner、lease_id 和 active，不取得外部资源。
  // 失败边界：构造不会验证 route 或区间；未经过 registry.claim 的对象不能作为 release 的有效租约。
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
  // 账本字段按 lease_id 独立保存，防止调用方通过返回句柄篡改冲突和释放校验依据。
  protected string m_owner_ledger[string];
  protected rdma_responder_domain_e m_domain_ledger[string];
  protected rdma_responder_mode_e m_mode_ledger[string];
  protected rdma_route_key_t m_route_ledger[string];
  protected rdma_bar_addr_t m_base_ledger[string];
  protected longint unsigned m_size_ledger[string];
  protected bit m_active_ledger[string];
  protected longint unsigned m_next_lease_id;
  protected bit m_sealed;

  // 功能：构造空的 responder registry，初始化单调 lease 计数器和 seal 状态。
  // 输入输出及副作用：name 为 UVM 对象名输入；建立本地账本，不绑定外部环境或转移 region 所有权。
  // 失败边界：新对象未 seal 且无 active region；任何输入校验失败均由后续 claim 返回状态，不在构造阶段抛出错误。
  function new(string name = "rdma_responder_registry");
    super.new(name);
    m_next_lease_id = 1;
    m_sealed = 1'b0;
  endfunction

  // 功能：创建统一的 resource-engine 错误状态，保留原始 code/message 并标记错误来源。
  // 输入输出及副作用：code、message 为输入；返回新 rdma_status，其 source_engine 被设置为 RDMA_ENGINE_RESOURCE，不修改 registry 账本。
  // 失败边界：rdma_status::make 只负责 code/category；本函数始终覆盖 source_engine，避免资源错误伪装成 NONE。
  protected function rdma_status make_status(rdma_status_code_e code, string message);
    rdma_status status;
    status = rdma_status::make(code, message);
    status.source_engine = RDMA_ENGINE_RESOURCE;
    return status;
  endfunction

  // 功能：判断 domain 是否为四个受支持的 responder 地址域。
  // 输入输出及副作用：domain 为输入；返回 bit，不写入对象或资源账本。
  // 失败边界：CONFIG/MMIO/HOST_MEMORY/NETWORK 返回 1；未知枚举值返回 0。
  protected function bit valid_domain(rdma_responder_domain_e domain);
    case (domain)
      RDMA_RESPONDER_CONFIG,
      RDMA_RESPONDER_MMIO,
      RDMA_RESPONDER_HOST_MEMORY,
      RDMA_RESPONDER_NETWORK: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // 功能：判断 responder mode 是否为 DUT、VIP 或 MONITOR_ONLY 合法模式。
  // 输入输出及副作用：mode 为输入；返回 bit，不修改 mode 或 registry。
  // 失败边界：未知编码返回 0；MONITOR_ONLY 是合法登记模式但不参与互斥冲突。
  protected function bit valid_mode(rdma_responder_mode_e mode);
    case (mode)
      RDMA_RESPONDER_DUT,
      RDMA_RESPONDER_VIP,
      RDMA_RESPONDER_MONITOR_ONLY: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  // 功能：判断两个路由是否处于同一地址冲突作用域，只比较 Host topology、root 和 segment。
  // 输入输出及副作用：lhs、rhs 为 route 输入；返回 bit，不修改 route 或 registry。
  // 失败边界：BDF 差异不扩大冲突域；route 合法性由 claim 单独校验，未知 bit 比较结果按 SV 等值语义处理。
  protected function bit same_scope(rdma_route_key_t lhs, rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment;
  endfunction

  // 功能：显式比较 route 的每个字段，避免工具对 packed struct 直接比较产生不一致。
  // 输入输出及副作用：lhs、rhs 为 route 输入；返回 bit，不修改路由或账本。
  // 失败边界：任一 host_topology_key、root_id、segment 或 BDF 字段不同即返回 0。
  protected function bit same_route(rdma_route_key_t lhs, rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           lhs.bdf.segment == rhs.bdf.segment && lhs.bdf.bus == rhs.bdf.bus &&
           lhs.bdf.device == rhs.bdf.device &&
           lhs.bdf.function_num == rhs.bdf.function_num;
  endfunction

  // 功能：显式比较两个 BAR 地址值。
  // 输入输出及副作用：lhs、rhs 为地址输入；返回 bit，不修改地址或账本。
  // 失败边界：value 任一 bit 不同时返回 0；该纯函数不处理地址溢出。
  protected function bit same_base(rdma_bar_addr_t lhs, rdma_bar_addr_t rhs);
    return lhs.value == rhs.value;
  endfunction

  // 功能：使用 65 位中间值计算区间末地址并检测 base + size - 1 的溢出。
  // 输入输出及副作用：base、size 为输入；last_ext 为输出 65 位末地址，返回 bit 表示是否溢出，不更新账本。
  // 失败边界：size=0 返回 0；最高位为 1 表示超出 64 位可寻址范围，调用方必须拒绝该区间。
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

  // 功能：判断两个已校验区间是否相交，采用闭区间 [base, base+size-1] 语义。
  // 输入输出及副作用：lhs、rhs 为 region 输入；返回 bit，不修改 region 或 registry。
  // 失败边界：调用方必须保证 size 非零且末地址未溢出；若前置条件不满足，结果仅作保守计算而不应提交 claim。
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

  // 功能：登记一个 responder 地址区间，分配单调 lease_id 并保存完整 route/owner 快照。
  // 输入输出及副作用：domain、mode、route、base、size、owner 为请求输入；region 为成功时返回的 registry-owned 句柄，成功会追加 m_regions。
  // 失败边界：sealed、非法 domain/mode/route、size=0、65 位末地址溢出、owner 为空或同作用域非监视器区间重叠时拒绝且不改变账本。
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

  // 功能：释放 registry 返回的 region 租约，逐项验证句柄和身份后移除内部账本项。
  // 输入输出及副作用：region 为调用方持有的句柄输入；成功时 active 清零并从 m_regions 删除，失败不修改任何条目。
  // 失败边界：空句柄、非本 registry 对象、lease/owner/domain/mode/route/base/size 任一字段不匹配或 inactive 均返回 INVALID_ARGUMENT；sealed 不阻止 release。
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

  // 功能：冻结当前 registry，使后续 claim 失败并允许 release 进行清理。
  // 输入输出及副作用：无显式输入；首次调用置位 m_sealed，重复调用保持置位并返回成功。
  // 失败边界：seal 设计为幂等操作，不因已 seal 或仍有 active region 而失败。
  function rdma_status seal();
    m_sealed = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：查询 registry 是否已进入 seal 状态。
  // 输入输出及副作用：无显式输入；返回 m_sealed，不修改任何资源状态。
  // 失败边界：新建 registry 返回 0；seal 成功后始终返回 1，查询无错误码分支。
  function bit is_sealed();
    return m_sealed;
  endfunction

  // 功能：统计当前账本中仍 active 的 region 数量，供容量和清理断言使用。
  // 输入输出及副作用：无显式输入；返回 active 条目计数，不修改队列或租约。
  // 失败边界：空 registry 返回 0；释放条目已从队列移除，因此不会重复计数。
  function int unsigned active_count();
    int unsigned count;
    count = 0;
    foreach (m_region_lease_ids[index])
      if (m_active_ledger.exists($sformatf("%0d", m_region_lease_ids[index])) &&
          m_active_ledger[$sformatf("%0d", m_region_lease_ids[index])])
        count++;
    return count;
  endfunction

  // 功能：按零基索引返回 registry 中的内部 region 句柄，支持诊断和释放。
  // 输入输出及副作用：index 为输入；返回 registry-owned region handle，不复制或转移所有权。
  // 失败边界：index 超出当前 m_regions.size 或条目为空时返回 null；该函数不因 sealed 改变可见性。
  function rdma_responder_region region_at(int unsigned index);
    if (index >= m_regions.size())
      return null;
    return m_regions[index];
  endfunction
endclass
