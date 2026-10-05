// 目录：src/integration/，位于 RDMA 控制面和外部 PCIe endpoint 之间的路由层。
// 职责：以 Host/root/segment/BDF 完整键选择 endpoint，并以 identity authority
//       保护 handle、配置空间、MMIO、BAR decode 和顺序屏障访问。
// 依赖：rdma_pcie_api、rdma_function_identity，以及外部 PCIe endpoint 实现。
  // 所有权与生命周期：endpoint 由外部 PCIe 环境拥有；本 router 只保存非拥有引用和
  //       route entry 值，entry/authority 随 router 配置生命周期存在。
class rdma_pcie_route_entry extends uvm_object;
  `uvm_object_utils(rdma_pcie_route_entry)
  rdma_route_key_t route;
  rdma_pcie_api endpoint;
  // 中文：handle 路由所需的 Function authority；由 identity adapter 填充。
  longint unsigned function_uid;
  int unsigned global_function_id;
  int unsigned generation;
  protected bit m_identity_verified;
  protected rdma_route_key_t m_verified_route;
  protected longint unsigned m_verified_uid;
  protected int unsigned m_verified_global_id;
  protected int unsigned m_verified_generation;
  // 功能：构造空 route entry，清零 route/authority 并标记 provenance 未验证。
  // 输入/输出及副作用：name 为 UVM 对象名；只写默认字段。
  // 失败/边界：无。
  function new(string name="rdma_pcie_route_entry");
    super.new(name);
    route='0; endpoint=null; function_uid=0; global_function_id=0;
    generation=0; m_identity_verified=0; m_verified_route='0;
    m_verified_uid=0; m_verified_global_id=0; m_verified_generation=0;
  endfunction
  // 功能：从已校验的 identity 一次性投影 route 与完整 authority 三元组，并记录 provenance。
  // 输入/输出及副作用：identity 输入（调用方须先校验空值/authority/generation）；成功时更新本对象，后续 configure() 据此拒绝手写或篡改的字段。
  // 失败/边界：identity 为空或 validate() 失败时返回错误，不改已验证状态。
  function rdma_status set_identity(rdma_function_identity identity);
    rdma_status s;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid Function identity");

    s = identity.validate();
    if (!s.ok())
      return s;

    route = identity.route_key();
    function_uid = identity.function_uid;
    global_function_id = identity.global_function_id;
    generation = identity.generation;
    m_verified_route = route;
    m_verified_uid = function_uid;
    m_verified_global_id = global_function_id;
    m_verified_generation = generation;
    m_identity_verified = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：验证当前公开 route/authority 仍与 set_identity() 保存的快照一致。
  // 输入/输出及副作用：无参数；只读，返回 bit。
  // 失败/边界：尚未 set_identity、route 非法或 uid/global id/generation 任一不符返回 0。
  function bit identity_authority_valid();
    return m_identity_verified &&
           rdma_route_key_valid(route) &&
           same_route_value(route, m_verified_route) &&
           function_uid == m_verified_uid &&
           global_function_id == m_verified_global_id &&
           generation == m_verified_generation;
  endfunction

  // 功能：比较两个 route key 的 Host/root/segment/BDF 值（不比较句柄或 authority）。
  // 输入/输出及副作用：lhs/rhs 只读；返回 bit。
  // 失败/边界：任一路由字段不等返回 0。
  protected function bit same_route_value(rdma_route_key_t lhs,
                                           rdma_route_key_t rhs);
    return lhs.host_topology_key == rhs.host_topology_key &&
           lhs.root_id == rhs.root_id && lhs.segment == rhs.segment &&
           rdma_bdf_same(lhs.bdf, rhs.bdf);
  endfunction
endclass

class rdma_pcie_router extends rdma_pcie_api;
  `uvm_object_utils(rdma_pcie_router)
  protected rdma_pcie_route_entry m_entries[$];
  // 功能：构造空 PCIe router；endpoint 表由 configure() 事务性发布。
  // 输入/输出及副作用：name 为 UVM 对象名；只写默认字段。
  // 失败/边界：无。
  function new(string name="rdma_pcie_router");
    super.new(name);
  endfunction

  // 功能：校验并原子替换 route entry 表，保证 route、authority 与 endpoint BDF 一一对应。
  // 输入/输出及副作用：entries 输入；成功时以非拥有 endpoint 引用替换 m_entries，失败保持旧表；不改 entry/endpoint。
  // 失败/边界：空 entry/endpoint、route 非法、provenance/authority 缺失、route/authority 重复或 endpoint BDF
  //   不符返回错误并保留旧配置。
  function rdma_status configure(rdma_pcie_route_entry entries[$]);
    rdma_pcie_route_entry new_entries[$];

    foreach (entries[i]) begin
      if (entries[i] == null || entries[i].endpoint == null ||
          !rdma_route_key_valid(entries[i].route))
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, "invalid PCIe route entry");
      if (!entries[i].identity_authority_valid() ||
          entries[i].function_uid == 0 || entries[i].generation == 0)
        return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
          "PCIe route authority must come from set_identity()");
      foreach (new_entries[j]) begin
        if (same_route(new_entries[j].route, entries[i].route))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "duplicate PCIe route");
        if (new_entries[j].function_uid == entries[i].function_uid &&
            new_entries[j].global_function_id == entries[i].global_function_id &&
            new_entries[j].generation == entries[i].generation)
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                   "duplicate Function authority tuple");
      end
      begin
        rdma_pcie_function_info info;
        rdma_status info_status;

        info = null;
        info_status = entries[i].endpoint.get_function_info(
          entries[i].route.bdf, info);
        if (!info_status.ok() || info == null ||
            !rdma_bdf_same(info.bdf, entries[i].route.bdf))
          return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
            "endpoint Function identity does not match route BDF");
      end
      new_entries.push_back(entries[i]);
    end
    m_entries = new_entries;
    return rdma_status::success();
  endfunction
  // 功能：按 BDF 解析唯一 endpoint 并转发 32 位配置读。
  // 输入/输出及副作用：target/offset 输入；data/status 输出；入口先清零 data；不改 route 表。
  // 失败/边界：BDF 不存在或多 Host 歧义时返回错误，data 保持 0。
  task cfg_read32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    output bit [31:0] data,
    output rdma_status status
  );
    rdma_pcie_api ep;

    data = '0;
    ep = endpoint_for_bdf(target, status);
    if (ep == null)
      return;
    ep.cfg_read32(target, offset, data, status);
  endtask
  // 功能：按 BDF 解析 endpoint 并转发带 byte-enable 的配置写。
  // 输入/输出及副作用：target/offset/data/byte_enable 输入；status 输出。
  // 失败/边界：BDF 不存在或多 Host 歧义时不调用 endpoint，返回错误。
  task cfg_write32(
    rdma_bdf_t target,
    rdma_cfg_offset_t offset,
    bit [31:0] data,
    bit [3:0] byte_enable,
    output rdma_status status
  );
    rdma_pcie_api ep;

    ep = endpoint_for_bdf(target, status);
    if (ep == null)
      return;
    ep.cfg_write32(target, offset, data, byte_enable, status);
  endtask
  // 功能：用完整 Function handle authority 选择 endpoint 并转发 MMIO 写。
  // 输入/输出及副作用：function_h/address/data 输入；status 输出；router 不拥有 data 缓冲区。
  // 失败/边界：不完整/过期/歧义的 handle 在 endpoint_for_handle() 被拒绝。
  task mmio_write(
    rdma_function_handle function_h,
    rdma_bar_addr_t address,
    byte data[],
    output rdma_status status
  );
    rdma_pcie_api ep;

    ep = endpoint_for_handle(function_h, status);
    if (ep == null)
      return;
    ep.mmio_write(function_h, address, data, status);
  endtask
  // 功能：按 Function handle 转发 DMA 可见性屏障。
  // 输入/输出及副作用：function_h 输入；status 输出；router 不改 handle。
  // 失败/边界：handle 为空/非 Function、authority 未命中或多命中时返回错误，不调用 endpoint。
  task dma_visibility_barrier(rdma_function_handle function_h, output rdma_status status);
    rdma_pcie_api ep;

    ep = endpoint_for_handle(function_h, status);
    if (ep == null)
      return;
    ep.dma_visibility_barrier(function_h, status);
  endtask
  // 功能：按 Function handle 转发 MMIO 顺序屏障。
  // 输入/输出及副作用：function_h 输入；status 输出；router 不改 handle。
  // 失败/边界：handle 为空/非 Function、authority 未命中或多命中时返回错误，不调用 endpoint。
  task mmio_ordering_barrier(rdma_function_handle function_h, output rdma_status status);
    rdma_pcie_api ep;

    ep = endpoint_for_handle(function_h, status);
    if (ep == null)
      return;
    ep.mmio_ordering_barrier(function_h, status);
  endtask
  // 功能：按 BDF 查询 endpoint 的 Function capability/info。
  // 输入/输出及副作用：bdf 输入；info 输出，入口先置 null；不取得 endpoint 所有权。
  // 失败/边界：BDF 不存在或歧义时返回错误，info 保持 null，不静默选择。
  function rdma_status get_function_info(
    rdma_bdf_t bdf,
    output rdma_pcie_function_info info
  );
    rdma_status status;
    rdma_pcie_api ep;

    info = null;
    ep = endpoint_for_bdf(bdf, status);
    if (ep == null)
      return status;
    return ep.get_function_info(bdf, info);
  endfunction
  // 功能：在所有 endpoint 中解码 BAR 地址，仅唯一命中才返回结果。
  // 输入/输出及副作用：address 输入；result 输出；不改 route 表。
  // 失败/边界：无命中返回 DMA_TRANSLATION；多命中清空 result 并返回 INVALID_ARGUMENT（缺少 route authority）。
  function rdma_status decode_bar(
    rdma_bar_addr_t address,
    output rdma_bar_decode result
  );
    rdma_bar_decode candidate;
    rdma_status s;
    int hits;

    result = null;
    hits = 0;
    foreach (m_entries[i]) begin
      candidate = null;
      s = m_entries[i].endpoint.decode_bar(address, candidate);
      if (s.ok() && candidate != null) begin
        hits++;
        result = candidate;
      end
    end
    if (hits == 1)
      return rdma_status::success();
    if (hits > 1) begin
      result = null;
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "ambiguous BAR address; route required");
    end
    return rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                             "BAR address route not found");
  endfunction
  // 功能：按完整 route key 查找 endpoint。
  // 输入/输出及副作用：route 输入；endpoint 输出非拥有引用；不改 route 表。
  // 失败/边界：未命中返回 0 且 endpoint 为 null。
  function bit resolve_route(rdma_route_key_t route, output rdma_pcie_api endpoint);
    endpoint = null;
    foreach (m_entries[i]) begin
      if (same_route(m_entries[i].route, route)) begin
        endpoint = m_entries[i].endpoint;
        return 1;
      end
    end
    return 0;
  endfunction
  // 功能：比较 router 内部 route key 的 Host/root/segment/BDF 完整值。
  // 输入/输出及副作用：a/b 只读；返回 bit。
  // 失败/边界：任一字段不等返回 0。
  protected function bit same_route(rdma_route_key_t a, rdma_route_key_t b);
    return a.host_topology_key == b.host_topology_key &&
           a.root_id == b.root_id && a.segment == b.segment &&
           rdma_bdf_same(a.bdf, b.bdf);
  endfunction
  // 功能：把裸 BDF 解析为唯一 endpoint；多 Host 同 BDF 时报歧义，迫使调用方改用完整 route。
  // 输入/输出及副作用：bdf 输入；扫描 route 表，返回唯一 endpoint 的非拥有引用；status 输出。
  // 失败/边界：BDF 不存在返回 DMA_TRANSLATION；多命中返回 INVALID_ARGUMENT；均不调用 endpoint。
  protected function rdma_pcie_api endpoint_for_bdf(
    rdma_bdf_t bdf,
    output rdma_status status
  );
    rdma_pcie_api ep;
    bit found;

    ep = null;
    found = 0;
    foreach (m_entries[i]) begin
      if (rdma_bdf_same(m_entries[i].route.bdf, bdf)) begin
        if (found) begin
          status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                     "ambiguous PCIe BDF; route required");
          return null;
        end
        found = 1;
        ep = m_entries[i].endpoint;
      end
    end
    if (!found)
      status = rdma_status::make(RDMA_SC_DMA_TRANSLATION,
                                 "PCIe BDF route not found");
    else
      status = rdma_status::success();
    return ep;
  endfunction
  // 功能：用 {function_uid, global_function_id, generation} 完整 authority 查找唯一 endpoint，防止仅凭
  //   object_id 串路由。
  // 输入/输出及副作用：h 输入；返回唯一 endpoint 的非拥有引用；status 输出。
  // 失败/边界：空/非 Function handle 或零/多命中返回 INVALID_ARGUMENT，不调用 endpoint。
  protected function rdma_pcie_api endpoint_for_handle(
    rdma_function_handle h,
    output rdma_status status
  );
    rdma_pcie_api ep;
    int match_count;

    ep = null;
    match_count = 0;
    if (h == null || h.kind != RDMA_RESOURCE_FUNCTION) begin
      status = rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                                 "invalid Function handle");
      return null;
    end
    foreach (m_entries[i]) begin
      if (m_entries[i].function_uid != 0 &&
          h.function_uid == m_entries[i].function_uid &&
          h.object_id == m_entries[i].global_function_id &&
          h.generation == m_entries[i].generation) begin
        match_count++;
        ep = m_entries[i].endpoint;
      end
    end
    if (match_count != 1) begin
      status = rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "ambiguous Function route; full identity required");
      return null;
    end
    status = rdma_status::success();
    return ep;
  endfunction
endclass
