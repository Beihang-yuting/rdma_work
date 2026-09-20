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
  // 记录每个 registration snapshot 发布时已经消耗的 Function epoch；reset
  // preflight 以“当前绝对 epoch - registration epoch”推导相对 generation，
  // 这样同一 coordinator 重新登记新 incarnation 时不会重复累加旧历史。
  protected rdma_reset_epoch_t m_function_registration_epochs[string];
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

  // 功能：在不触碰现有 Host router 或 Function ledger 的前提下，预检并一次性提交
  //       一组 Function identity 注册，使 device env 可以把多 Function 构建作为单一事务发布。
  // 输入/输出及副作用：router（输入，非 null 时替换待绑定的非拥有 Host router）和 identities
  //   （输入）描述待登记的 identity 集合；函数先在局部 ledger 中复制已有条目并 clone 全部
  //   新 incarnation，全部成功后才绑定 router、替换 m_host_router/m_functions，并返回状态。
  //   router 为 null 且已有 Host router 为空时表示“只提交 Function ledger”，供兼容的
  //   register_function() 使用；已有 router 非空时 null router 保持该引用不变。
  // 失败/边界：identity 为 null、同一稳定 key 的输入 incarnation 冲突、已有 ledger 条目损坏或
  //   任一 clone/cast 失败时返回明确错误；失败路径不修改本 coordinator 的 router、Function
  //   ledger 或 epoch 账本，也不会回滚/接管外部 router 所有权。
  function rdma_status commit_registration_atomic(
    rdma_host_mem_router router,
    rdma_function_identity identities[$]
  );
    rdma_function_identity staged_functions[string];
    rdma_reset_epoch_t staged_registration_epochs[string];
    rdma_function_identity snapshot;
    uvm_object cloned_object;
    string name;
    bit input_seen[string];
    rdma_status identity_status;

    // 先复制旧引用；旧 snapshot 已由 coordinator 拥有，事务只会在下面为新
    // incarnation 追加 detached clone，因而失败时无需改写原 ledger。
    foreach (m_functions[name]) begin
      if (m_functions[name] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset coordinator contains a null Function snapshot"
        );
      staged_functions[name] = m_functions[name];
      staged_registration_epochs[name] =
        m_function_registration_epochs.exists(name) ?
        m_function_registration_epochs[name] : 0;
    end

    foreach (identities[index]) begin
      if (identities[index] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reset coordinator registration identity is null"
        );
      identity_status = identities[index].validate();
      if (identity_status == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset coordinator registration identity validation returned null"
        );
      if (!identity_status.ok())
        return identity_status;
      name = identity_name(identities[index]);
      if (input_seen.exists(name)) begin
        if (staged_functions[name] == null)
          return rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "reset coordinator staged Function snapshot is null"
          );
        if (!staged_functions[name].same_incarnation(identities[index])) begin
          // 同一个完整 Function key 不能在一次构建中静默覆盖不同代际；否则
          // reset epoch 账本会指向不确定的 incarnation。
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reset coordinator registration contains duplicate incarnation"
          );
        end
        continue;
      end

      // 已有相同 incarnation 时沿用 coordinator 已拥有的 snapshot，保持旧
      // register_function() 的幂等语义；不同 incarnation 则在局部 map 中以
      // 新 clone 替换，提交仍然等到整个输入集合通过后才发生。
      if (staged_functions.exists(name) &&
          staged_functions[name] != null &&
          staged_functions[name].same_incarnation(identities[index])) begin
        input_seen[name] = 1'b1;
        continue;
      end

      cloned_object = identities[index].clone();
      if (cloned_object == null || !$cast(snapshot, cloned_object))
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "reset coordinator Function identity clone failed"
        );
      staged_functions[name] = snapshot;
      staged_registration_epochs[name] = m_function_epochs.exists(name) ?
                                          m_function_epochs[name] : 0;
      input_seen[name] = 1'b1;
    end

    // 到这里所有可能失败的 clone/cast/冲突校验均已完成；attach 本身没有失败
    // 返回路径，随后两个 handle 赋值也不会再暴露半成品 registration。
    if (router != null) begin
      m_host_router = router;
      router.attach_reset_coordinator(this);
    end
    m_functions = staged_functions;
    m_function_registration_epochs = staged_registration_epochs;
    return rdma_status::success();
  endfunction

  // 功能：登记一个 Function 的不可变身份快照；重复 incarnation 不重复登记，调用方
  //       后续修改原 identity 不会影响 reset 级联范围。
  // 输入/输出及副作用：identity（输入）；按完整 key 克隆并保存不可变快照，供后续 reset 范围和
  //   epoch 查询；相同 incarnation 重复登记时不新增条目。
  // 失败/边界：传入 null 直接忽略；克隆失败视为致命测试/环境错误。
  function void register_function(rdma_function_identity identity);
    rdma_function_identity identities[$];
    rdma_status status;

    if (identity == null)
      return;
    // 兼容旧的 void API；新的 device-env build 使用带 status 的批量提交入口，
    // 该 wrapper 保留原来 clone 失败即 fatal 的单 Function 诊断语义。
    identities.push_back(identity);
    status = commit_registration_atomic(m_host_router, identities);
    if (status == null || !status.ok())
      `uvm_fatal("RDMA_RESET", status == null ?
                "Function identity registration returned null status" :
                status.message)
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
  // 输入/输出及副作用：identity（输入）；先只读校验完整 Function key、UID、generation 和
  //   reset_epoch 是否对应当前登记 incarnation，再递增目标 VF 的局部 epoch；PF、其他 VF、Host
  //   epoch 均不变。
  // 失败/边界：null/非 VF 返回 INVALID_ARGUMENT；未知 Function 或 generation/reset_epoch 过期返回
  //   INVALID_STATE/STALE_GENERATION，任何拒绝均不创建 Function epoch 或修改 Host router。
  function rdma_status request_vf_flr(rdma_function_identity identity);
    rdma_status status;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "null Function identity");
    if (identity.key.function_kind != RDMA_FUNCTION_VF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "VF FLR requires VF identity");

    status = validate_registered_identity(identity);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "registered Function validation returned null") :
        status;
    bump_function(m_functions[identity_name(identity)]);
    return rdma_status::success();
  endfunction
  // 功能：执行 PF reset，推进目标 PF 及其同 Host、同 root、同 parent BDF 的所有 VF epoch。
  // 输入/输出及副作用：identity（输入）；先只读校验目标 PF 的完整登记 incarnation，再扫描同
  //   Host/root 的 PF/后代 VF 并递增其局部 epoch；所有递增均使用 coordinator 已拥有的 snapshot。
  // 失败/边界：null/非 PF 返回 INVALID_ARGUMENT；未知 PF 或 generation/reset_epoch 过期返回错误，
  //   失败时不为 phantom PF 建立 Function epoch，也不触碰任何既有 epoch/router。
  function rdma_status request_pf_reset(rdma_function_identity identity);
    rdma_status status;
    string name;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "null Function identity");
    if (identity.key.function_kind != RDMA_FUNCTION_PF)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "PF reset requires PF identity");

    status = validate_registered_identity(identity);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "registered PF validation returned null") :
        status;
    foreach (m_functions[name]) begin
      if (m_functions[name].key.host_topology_key ==
            identity.key.host_topology_key &&
          m_functions[name].key.root_id == identity.key.root_id &&
          ((m_functions[name].key.function_kind == RDMA_FUNCTION_PF &&
            rdma_bdf_same(m_functions[name].key.bdf, identity.key.bdf)) ||
           (m_functions[name].key.function_kind == RDMA_FUNCTION_VF &&
            rdma_bdf_same(m_functions[name].key.parent_pf_bdf,
                          identity.key.bdf)))) begin
        bump_function(m_functions[name]);
      end
    end
    return rdma_status::success();
  endfunction
  // 功能：推进指定 Host epoch，并对该 Host 上登记的全部 Function 级联 bump。
  // 输入/输出及副作用：host_topology_key（输入）；先只读确认该 Host 至少拥有一个完整登记的
  //   Function，再递增 Host epoch、通知已绑定 router，并对该 Host 已登记 Function 逐个 bump。
  // 失败/边界：未登记 Host 返回 INVALID_STATE，且不创建 phantom Host epoch、不调用 router；合法
  //   Host reset 保留原有级联和 router-local epoch 语义。
  function rdma_status request_host_reset(int unsigned host_topology_key);
    rdma_status status;
    string name;

    status = validate_registered_host_scope(host_topology_key);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "registered Host scope validation returned null") :
        status;
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

  // 功能：只读确认输入 identity 对应 coordinator 当前登记的 Function incarnation，供 reset
  //       caller 在 quiesce 前建立 authority 屏障。
  // 输入/输出及副作用：identity（输入）；按完整 route key 查找 coordinator-owned snapshot，并
  //   将 registration snapshot 的 generation/reset_epoch 与该 snapshot 发布后已消耗的 Function
  //   epoch 相加，返回当前 incarnation 是否与输入的 same_function/UID/generation/reset_epoch 一致；
  //   不修改任何 ledger、router 或 epoch。
  // 失败/边界：null/identity.validate 失败返回对应错误；未知完整 key 返回 INVALID_STATE；UID、
  //   global ID、generation 或 reset_epoch 与当前 incarnation 不一致返回 STALE_GENERATION。
  function rdma_status validate_registered_identity(
    rdma_function_identity identity
  );
    rdma_status identity_status;
    rdma_function_identity registered;
    rdma_reset_epoch_t registration_epoch;
    rdma_reset_epoch_t applied_resets;
    rdma_reset_epoch_t expected_epoch;
    longint unsigned expected_generation;
    string name;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function identity is null");
    identity_status = identity.validate();
    if (identity_status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function identity validation returned null"
      );
    if (!identity_status.ok())
      return identity_status;

    name = identity_name(identity);
    if (!m_functions.exists(name) || m_functions[name] == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function identity is not registered"
      );
    registered = m_functions[name];
    registration_epoch = m_function_registration_epochs.exists(name) ?
                         m_function_registration_epochs[name] : 0;
    if (m_function_epochs.exists(name) &&
        m_function_epochs[name] < registration_epoch)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function registration epoch ledger is inconsistent"
      );
    applied_resets = m_function_epochs.exists(name) ?
                     m_function_epochs[name] - registration_epoch : 0;
    // registration snapshot 发布后尚未发生 reset 时直接使用 same_incarnation，
    // 保留旧 API 对同一初始 incarnation 的幂等语义；发生 reset 后，当前
    // incarnation 由 immutable registration snapshot 加上该 snapshot 之后已
    // 发布的 Function epoch 推导，避免 coordinator 为了校验而复制或提前替换
    // 外部 context identity。
    if (applied_resets == 0 && !registered.same_incarnation(identity))
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function identity incarnation is stale"
      );
    if (!registered.same_function(identity) ||
        registered.function_uid != identity.function_uid)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function identity authority is stale"
      );

    expected_generation = registered.generation;
    expected_generation += applied_resets;
    expected_epoch = registered.reset_epoch + applied_resets;
    if (identity.generation != expected_generation ||
        identity.reset_epoch != expected_epoch)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function identity generation/reset epoch is stale"
      );
    return rdma_status::success();
  endfunction

  // 功能：只读确认 Host topology scope 至少包含一个 coordinator 登记的 Function，阻止未知 Host
  //       在 request_host_reset 中隐式创建 epoch。
  // 输入/输出及副作用：host_topology_key（输入）；扫描完整 Function ledger，成功返回 Host scope
  //   已登记；该函数不修改 Host epoch、Function epoch、router 或任何 identity snapshot。
  // 失败/边界：Host 没有任何登记 Function 或 ledger 含 null snapshot 时返回 INVALID_STATE；未知
  //   Host 不会触发 router advance 或建立 phantom epoch。
  function rdma_status validate_registered_host_scope(
    int unsigned host_topology_key
  );
    string name;
    bit found;

    found = 1'b0;
    foreach (m_functions[name]) begin
      if (m_functions[name] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset coordinator contains a null Function snapshot"
        );
      if (m_functions[name].key.host_topology_key == host_topology_key)
        found = 1'b1;
    end
    if (!found)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host topology scope is not registered"
      );
    return rdma_status::success();
  endfunction

  // 功能：返回 reset ledger 中已登记的 Function 数量，供 device env 构建后
  //       的拓扑覆盖检查和调试诊断使用；函数只读，不改变任何 epoch。
  // 输入/输出及副作用：无参数；只读返回 identity ledger 中的登记数量，不修改 epoch。
  // 失败/边界：ledger 为空时返回 0；函数不触发 context 构造或 reset 操作。
  function int unsigned function_count();
    return m_functions.num();
  endfunction

  // 功能：为 device env 的 reset prepare 阶段预览一个已登记 Function 下一次将发布的
  //       epoch，而不提前修改 coordinator ledger。
  // 输入/输出及副作用：identity（输入）必须是当前 context 的 immutable incarnation；
  //   next_epoch（输出）返回当前 Function epoch 加一；函数只读验证 registration ledger，
  //   不触碰 Host router、任何 epoch map 或 identity snapshot。
  // 失败/边界：identity 为空、validator 返回 null、完整 route 未登记、generation/reset_epoch
  //   过期或 registration ledger 不一致时返回对应错误，并将 next_epoch 保持为 0；成功后
  //   调用方必须在 coordinator epoch commit 前完成所有 context candidate 准备。
  function rdma_status preview_next_function_epoch(
    rdma_function_identity identity,
    output rdma_reset_epoch_t next_epoch
  );
    rdma_status status;

    next_epoch = 0;
    status = validate_registered_identity(identity);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function epoch preview returned null validation"
      );
    if (!status.ok())
      return status;
    next_epoch = function_epoch(identity) + 1;
    return rdma_status::success();
  endfunction

  // 功能：统计指定 Host topology 下 coordinator ledger 中应参与 Host reset 的 Function 数量，
  //       供 device env 在 quiesce 后的跨 context 覆盖检查使用。
  // 输入/输出及副作用：host_topology_key（输入）；只读扫描完整 Function snapshot，返回匹配
  //   条目数，不创建 Host epoch 或修改任何 identity/router 状态。
  // 失败/边界：ledger 含 null snapshot 时返回 0 作为不可用计数；调用方应先通过
  //   validate_registered_host_scope() 确认 Host scope 合法，不能把 0 当作空 scope 成功。
  function int unsigned host_function_count(int unsigned host_topology_key);
    string name;
    int unsigned count;

    count = 0;
    foreach (m_functions[name]) begin
      if (m_functions[name] != null &&
          m_functions[name].key.host_topology_key == host_topology_key)
        count++;
    end
    return count;
  endfunction

  // 功能：统计指定 PF reset 会级联的 PF/VF Function 数量，复用 coordinator 的完整 Host/root/BDF
  //       路由规则，防止 env 只重建部分 context 却推进完整 PF epoch。
  // 输入/输出及副作用：identity（输入）提供已登记 PF 的 Host topology 和 BDF；只读扫描
  //   Function ledger，返回同 Host/root 的 PF 本身及 parent_pf_bdf 匹配的 VF 数量，不修改 epoch。
  // 失败/边界：identity 为空、非 PF 或 ledger 含 null snapshot 时返回 0；调用方必须先完成
  //   validate_registered_identity()，0 只表示 scope 不可用于原子 reset。
  function int unsigned pf_reset_function_count(
    rdma_function_identity identity
  );
    string name;
    int unsigned count;

    count = 0;
    if (identity == null || identity.key.function_kind != RDMA_FUNCTION_PF)
      return 0;
    foreach (m_functions[name]) begin
      if (m_functions[name] == null ||
          m_functions[name].key.host_topology_key !=
            identity.key.host_topology_key ||
          m_functions[name].key.root_id != identity.key.root_id)
        continue;
      if (m_functions[name].key.function_kind == RDMA_FUNCTION_PF &&
          rdma_bdf_same(m_functions[name].key.bdf, identity.key.bdf))
        count++;
      else if (m_functions[name].key.function_kind == RDMA_FUNCTION_VF &&
               rdma_bdf_same(m_functions[name].key.parent_pf_bdf,
                             identity.key.bdf))
        count++;
    end
    return count;
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
  // 功能：把 identity 的完整 Host/root/PF-parent/VF/BDF key 编码为 ledger 查找键，避免不同
  //       parent PF 或 Host 上相同 BDF 发生碰撞；该键不包含可变对象句柄。
  // 输入/输出及副作用：i（输入）；只读编码 Host/root/function-kind/VF/BDF/parent-PF 字段为稳定
  //   字符串键，不包含对象句柄或 generation；调用方须保证 i 非 null。
  // 失败/边界：i 为 null 时解引用会触发仿真错误，因此仅允许由已登记 identity 调用。
  protected function string identity_name(rdma_function_identity i);
    return $sformatf("%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d:%0d",
                     i.key.host_topology_key,
                     i.key.root_id,
                     i.key.function_kind,
                     i.key.vf_index,
                     i.key.bdf.segment,
                     i.key.bdf.bus,
                     i.key.bdf.device,
                     i.key.bdf.function_num,
                     i.key.parent_pf_bdf.segment,
                     i.key.parent_pf_bdf.bus,
                     i.key.parent_pf_bdf.device,
                     i.key.parent_pf_bdf.function_num);
  endfunction
endclass
