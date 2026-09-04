// 目录：src/integration/，位于复位控制面与 Host-memory router 的共享状态层。
// 职责：为注册的 PF/VF、Host 和 Device 维护独立 epoch，并实现 VF FLR、PF reset、
//       Host reset、Device reset 的精确影响范围，供 router 拒绝过期 DMA 资源。
// 依赖：rdma_function_identity、rdma_host_mem_router 和 rdma_status。
// 所有权与生命周期：coordinator 克隆并拥有 identity ledger；Host router 仅保存
//       非拥有引用；epoch 从对象创建起累积到 coordinator 生命周期结束。
class rdma_reset_coordinator extends uvm_object;
  `uvm_object_utils(rdma_reset_coordinator)
  protected rdma_reset_epoch_t m_function_epochs[string];
  protected rdma_reset_epoch_t m_host_epochs[int unsigned];
  protected rdma_reset_epoch_t m_device_epoch;
  protected rdma_host_mem_router m_host_router;
  // 以稳定 route key 建立关联数组，避免 VCS 在跨 package/static function
  // 调用中对 class queue 的 copy-on-write 行为造成登记条目丢失。
  protected rdma_function_identity m_functions[string];
  // 功能：初始化设备级 epoch 为零并建立空的 Function/Host ledger。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name="rdma_reset_coordinator");
    super.new(name);
    m_device_epoch = 0;
  endfunction

  // 功能：把 Host router 连接到本 coordinator，使 Host reset 同时推进 router 的本地 epoch。
  // 输入/输出及副作用：router（输入）；保存非拥有引用，并立即把本 coordinator 绑定到 router，
  //   使 Host reset 同时递增 router-local epoch；该函数无返回状态。
  // 失败/边界：实现未对 null 做保护，调用方必须传入有效 router；coordinator 不接管其所有权。
  function void attach_host_router(rdma_host_mem_router router);
    m_host_router = router;
    router.attach_reset_coordinator(this);
  endfunction

  // 功能：登记一个 Function 的不可变身份快照；重复 incarnation 不重复登记，调用方
  //       后续修改原 identity 不会影响 reset 级联范围。
  // 输入/输出及副作用：identity（输入）；按完整 key 克隆并保存不可变快照，供后续 reset 范围和
  //   epoch 查询；相同 incarnation 重复登记时不新增条目。
  // 失败/边界：传入 null 直接忽略；克隆失败视为致命测试/环境错误。
  function void register_function(rdma_function_identity identity);
    rdma_function_identity snapshot;
    uvm_object cloned_object;
    string name;

    if (identity == null)
      return;
    // coordinator 保存的是注册时的身份快照；调用方后续修改原对象不能
    // 改写 reset 影响范围，否则 PF/VF 级联会出现不可追踪的漂移。
    name = identity_name(identity);
    if (m_functions.exists(name) &&
        m_functions[name].same_incarnation(identity))
      return;
    cloned_object = identity.clone();
    if (cloned_object == null || !$cast(snapshot, cloned_object))
      `uvm_fatal("RDMA_RESET", "Function identity clone failed")
    m_functions[name] = snapshot;
  endfunction
  // 功能：按稳定 Function UID 查询当前 epoch；UID 未登记时返回零，保持查询幂等。
  // 输入/输出及副作用：uid（输入）；只读扫描已登记 identity，返回其局部 Function epoch；未找到返回 0。
  // 失败/边界：uid 为 0 或未登记时返回 0；查询不会创建新的 Function ledger 条目。
  function rdma_reset_epoch_t function_epoch_uid(longint unsigned uid);
    string name;

    foreach (m_functions[name])
      if (m_functions[name].function_uid == uid)
        return function_epoch(m_functions[name]);
    return 0;
  endfunction

  // 功能：执行 VF FLR，仅推进目标 VF 的 Function epoch，不影响 PF、其他 VF 或 Host。
  // 输入/输出及副作用：identity（输入）；校验非 null 且为 VF 后递增目标 VF 的局部 epoch；PF、其他
  //   VF、Host epoch 均不变。
  // 失败/边界：null 或非 VF identity 返回 INVALID_ARGUMENT。
  function rdma_status request_vf_flr(rdma_function_identity identity);
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "null Function identity");
    if (identity.key.function_kind != RDMA_FUNCTION_VF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF FLR requires VF identity");

    bump_function(identity);
    return rdma_status::success();
  endfunction
  // 功能：执行 PF reset，推进目标 PF 及其同 Host、同 parent BDF 的所有 VF epoch。
  // 输入/输出及副作用：identity（输入）；校验非 null 且为 PF 后扫描同 Host 的 PF/后代 VF 并递增其
  //   局部 epoch；若 PF 未登记则为其建立 ledger 条目。
  // 失败/边界：null 或非 PF identity 返回 INVALID_ARGUMENT；PF 尚未登记时仍推进其 ledger。
  function rdma_status request_pf_reset(rdma_function_identity identity);
    bit found_pf;
    string name;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "null Function identity");
    if (identity.key.function_kind != RDMA_FUNCTION_PF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PF reset requires PF identity");

    found_pf = 0;
    foreach (m_functions[name]) begin
      if (m_functions[name].key.host_topology_key ==
            identity.key.host_topology_key &&
          ((m_functions[name].key.function_kind == RDMA_FUNCTION_PF &&
            rdma_bdf_same(m_functions[name].key.bdf, identity.key.bdf)) ||
           (m_functions[name].key.function_kind == RDMA_FUNCTION_VF &&
            rdma_bdf_same(m_functions[name].key.parent_pf_bdf,
                          identity.key.bdf)))) begin
        bump_function(m_functions[name]);
        if (m_functions[name].key.function_kind == RDMA_FUNCTION_PF)
          found_pf = 1;
      end
    end

    if (!found_pf)
      bump_function(identity);
    return rdma_status::success();
  endfunction
  // 功能：推进指定 Host epoch，并对该 Host 上登记的全部 Function 级联 bump。
  // 输入/输出及副作用：host_topology_key（输入）；递增 Host epoch，并对该 Host 已登记 Function
  //   逐个递增局部 epoch，同时通知已绑定 router。
  // 失败/边界：当前实现对任意 Host key 都建立 epoch，未登记 Function 的 Host 也会成功。
  function rdma_status request_host_reset(int unsigned host_topology_key);
    string name;

    m_host_epochs[host_topology_key] = m_host_epochs.exists(host_topology_key) ?
                                       m_host_epochs[host_topology_key] + 1 : 1;
    if (m_host_router != null)
      m_host_router.advance_host_epoch(host_topology_key);
    foreach (m_functions[name]) begin
      if (m_functions[name].key.host_topology_key == host_topology_key)
        bump_function(m_functions[name]);
    end
    return rdma_status::success();
  endfunction
  // 功能：推进全局 Device epoch，并使所有已登记 Function 的 DMA 身份同时失效。
  // 输入/输出及副作用：无参数；递增全局 Device epoch，并对所有已登记 Function 逐个递增局部 epoch。
  // 失败/边界：当前实现无拒绝分支，调用始终返回成功。
  function rdma_status request_device_reset();
    string name;

    m_device_epoch++;
    foreach (m_functions[name])
      bump_function(m_functions[name]);
    return rdma_status::success();
  endfunction

  // 功能：按完整 identity key 查询该 Function 的局部 epoch；未登记或 null 返回零。
  // 输入/输出及副作用：identity（输入）；按完整 key 读取已登记 Function 的局部 epoch；null 或未登记返回 0。
  // 失败/边界：identity 为 null 或 key 未登记时返回 0；函数不修改 epoch 计数。
  function rdma_reset_epoch_t function_epoch(rdma_function_identity identity);
    string name;

    if (identity == null)
      return 0;
    name = identity_name(identity);
    return m_function_epochs.exists(name) ? m_function_epochs[name] : 0;
  endfunction
  // 功能：查询指定 Host 的 reset epoch；从未发生 reset 时返回零。
  // 输入/输出及副作用：host_topology_key（输入）；读取该 Host 的累计 epoch；从未 reset 的 Host 返回 0。
  // 失败/边界：Host key 未登记时返回 0；函数不隐式创建 Host 条目。
  function rdma_reset_epoch_t host_epoch(int unsigned host_topology_key);
    return m_host_epochs.exists(host_topology_key) ?
           m_host_epochs[host_topology_key] : 0;
  endfunction
  // 功能：返回当前全局 Device reset epoch，供 mapping 分解校验使用。
  // 输入/输出及副作用：无参数；只读返回全局 Device epoch，不修改 ledger。
  // 失败/边界：尚未发生 device reset 时返回 0；计数溢出遵循定宽 epoch 算术。
  function rdma_reset_epoch_t device_epoch();
    return m_device_epoch;
  endfunction

  // 功能：返回 reset ledger 中已登记的 Function 数量，供 device env 构建后
  //       的拓扑覆盖检查和调试诊断使用；函数只读，不改变任何 epoch。
  // 输入/输出及副作用：无参数；只读返回 identity ledger 中的登记数量，不修改 epoch。
  // 失败/边界：ledger 为空时返回 0；函数不触发 context 构造或 reset 操作。
  function int unsigned function_count();
    return m_functions.num();
  endfunction

  // 功能：将单个 Function 的局部 epoch 加一；仅由 reset 范围判定函数调用。
  // 输入/输出及副作用：identity（输入）；按 identity_name 递增对应 Function 的局部 epoch；仅供
  //   reset 范围函数调用，不克隆或修改 identity。
  // 失败/边界：调用方必须传入非 null identity；该 helper 本身无状态校验或错误返回。
  protected function void bump_function(rdma_function_identity identity);
    string name;

    name = identity_name(identity);
    m_function_epochs[name] = m_function_epochs.exists(name) ?
                              m_function_epochs[name] + 1 : 1;
  endfunction
  // 功能：把 identity 的 Host/root/VF/BDF 字段编码为 ledger 查找键，避免不同 Host
  //       上相同 BDF 发生碰撞；该键不包含可变对象句柄。
  // 输入/输出及副作用：i（输入）；只读编码 Host/root/function-kind/VF/BDF 字段为稳定字符串键，
  //   不包含对象句柄或 generation；调用方须保证 i 非 null。
  // 失败/边界：i 为 null 时解引用会触发仿真错误，因此仅允许由已登记 identity 调用。
  protected function string identity_name(rdma_function_identity i);
    return $sformatf("%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d",
                     i.key.host_topology_key,
                     i.key.root_id,
                     i.key.function_kind,
                     i.key.vf_index,
                     i.key.bdf.segment,
                     i.key.bdf.bus,
                     i.key.bdf.device,
                     i.key.bdf.function_num);
  endfunction
endclass
