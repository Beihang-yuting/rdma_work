// 目录：src/integration/，复位控制面与 Host-memory router 的共享状态层。
// 职责：为注册的 PF/VF、Host、Device 维护独立 epoch，实现 VF FLR/PF/Host/Device reset 的影响范围，
//       供 router 拒绝过期 DMA 资源。
// 依赖：rdma_function_identity、rdma_host_mem_router、rdma_status。
// 所有权与生命周期：coordinator 克隆并拥有 identity ledger；Host router 仅持非拥有引用；
//       epoch 自对象创建起累积到 coordinator 生命周期结束。
//
// 设计说明：router 不能把公开 bit 当 authority。legacy attach 与 leased owned attach/detach 各用
//       coordinator 在一次同步调用中创建的一次性 opaque capability；router 不保存它，写入自身
//       coordinator 引用前须向 coordinator 回验目标、方向与 owner/token，避免单侧绑定。
class rdma_reset_router_attach_capability extends uvm_object;
  `rdma_object_utils(rdma_reset_router_attach_capability)

  // 功能：构造 legacy Host-router attach 的一次性 opaque capability。
  // 输入/输出及副作用：name 为 UVM 对象名；无业务字段。
  // 失败/边界：不得缓存或跨 attach 重放；构造成功不代表授权。
  function new(string name = "rdma_reset_router_attach_capability");
    super.new(name);
  endfunction
endclass

// 设计说明：leased Host-router attach/detach 的一次性 opaque 授权句柄，不携带业务字段、不分配
// 资源；身份由 coordinator 暂存并回验。仅可在创建它的 coordinator 同步调用中使用一次，复制、
// 伪造、跨 router/跨操作重放均在回验处被拒绝。
class rdma_reset_router_owned_capability extends uvm_object;
  `rdma_object_utils(rdma_reset_router_owned_capability)

  // 功能：构造 leased Host-router attach/detach 的一次性 opaque capability。
  // 输入/输出及副作用：name 为 UVM 对象名；无业务字段。
  // 失败/边界：仅在创建它的 coordinator 同步调用内使用一次；构造成功不代表授权。
  function new(string name = "rdma_reset_router_owned_capability");
    super.new(name);
  endfunction
endclass

// 设计说明：Host epoch publication 的一次性 capability，仅表示“当前同步调用由 coordinator 驱动”。
// 对象不分配资源，不暴露 Host key/router/owner/token；目标与方向暂存于 coordinator 并由回验
// 函数比对。仅可在 request_host_reset() 的单次同步调用中使用，复制、伪造或跨 Host/router 重放
// 均被回验拒绝。
class rdma_reset_router_epoch_capability extends uvm_object;
  `rdma_object_utils(rdma_reset_router_epoch_capability)

  // 功能：构造 Host epoch capacity/advance publication 的一次性 opaque capability。
  // 输入/输出及副作用：name 为 UVM 对象名；无业务字段。
  // 失败/边界：仅在 request_host_reset() 的同步调用内使用一次；伪造或重放由 coordinator 回验拒绝。
  function new(string name = "rdma_reset_router_epoch_capability");
    super.new(name);
  endfunction
endclass

// 设计说明：tokenless Host-router 数据面须在访问外部 manager 前完成同一份 reset admission 判定，
// 且不读写 coordinator 的 owner/epoch/ledger。把 active 标志与 cleanup 意图冻结为 detached policy，
// 使各数据面入口共用同步边界，也便于测试覆盖全部组合。
class rdma_reset_tokenless_admission_policy;

  // 功能：按 publication guard、reset transaction 与 cleanup 意图判定 tokenless dataplane 是否放行。
  // 输入/输出及副作用：纯函数，只读三个 bit 与 operation_name。
  // 失败/边界：任一 reset 标志 active 且 allow_cleanup=0 返回 RESOURCE_BUSY；否则成功。
  static function rdma_status evaluate(
    bit publication_active,
    bit transaction_active,
    bit allow_cleanup,
    string operation_name
  );
    if (!allow_cleanup && (publication_active || transaction_active))
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {"Host router dataplane blocked during reset: ", operation_name}
      );
    return rdma_status::success();
  endfunction
endclass

class rdma_reset_coordinator extends uvm_object;
  `rdma_object_utils(rdma_reset_coordinator)
  protected rdma_reset_epoch_t m_function_epochs[string];
  protected rdma_reset_epoch_t m_host_epochs[int unsigned];
  protected rdma_reset_epoch_t m_device_epoch;
  protected rdma_host_mem_router m_host_router;
  // 用稳定 route key 的关联数组，避免 VCS 跨 package/static function 调用时 class queue 的
  // copy-on-write 导致登记条目丢失。
  protected rdma_function_identity m_functions[string];
  // 登记快照发布时已消耗的 Function epoch；相对 generation = 当前绝对 epoch - 此值，
  // 使同一 coordinator 重新登记新 incarnation 时不重复累加旧历史。
  protected rdma_reset_epoch_t m_function_registration_epochs[string];

  // 一对一 ownership lease：device env 在发布事务前取得唯一 token；coordinator 只存非拥有句柄，
  // 并在每个可变入口校验 owner/token。lease 不是线程锁，只用于拒绝其他 env、旧 token 或无 token
  // 的直接回调绕过当前事务边界。
  protected uvm_object m_lease_owner;
  protected longint unsigned m_lease_token;
  protected longint unsigned m_next_lease_token;
  protected bit m_reset_transaction_active;
  // 同步 publication guard：防止 validator/router/context 回调在同一调用栈内再次进入 reset_*。
  // 仅在一个 request_* wrapper 的同步窗口内置位以拒绝嵌套 publication；不是抢占式锁。
  protected bit m_reset_operation_active;
  // legacy attach 的一次性 capability：coordinator 在同步调用期间暂存 capability/target，
  // router 经 authorize 函数核验后才可写入 m_reset。
  protected uvm_object m_router_attach_capability;
  protected rdma_host_mem_router m_router_attach_target;
  // leased owned attach/detach 的一次性 capability：仅在同步 seam 期间暂存，router 回验后立即
  // 消费；失败路径由外层 facade 清空，避免旧句柄重放。
  protected uvm_object m_router_owned_capability;
  protected rdma_host_mem_router m_router_owned_target;
  protected bit m_router_owned_attach;
  // Host reset 的 router-local epoch 预检与提交各用一个一次性 capability，不共用公开
  // allow_active bit，防止 legacy 回调伪装成 coordinator 内部 publication。
  protected uvm_object m_router_epoch_capability;
  protected rdma_host_mem_router m_router_epoch_target;
  protected int unsigned m_router_epoch_host;
  protected bit m_router_epoch_advance;

  // 功能：在同步 publication 窗口内拒绝可变操作。
  // 输入/输出及副作用：只读 m_reset_operation_active；allow_active 可豁免。
  // 失败/边界：guard active 且未豁免时返回 RESOURCE_BUSY。
  protected function rdma_status reject_mutation_during_reset_operation(
    string operation_name,
    bit allow_active = 1'b0
  );
    if (m_reset_operation_active && !allow_active)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        {"coordinator reset publication blocks ", operation_name}
      );
    return rdma_status::success();
  endfunction

  // 功能：校验 coordinator 可变操作的 lease owner/token，并处理 legacy 无 lease 调用。
  // 输入/输出及副作用：只读 lease 与 guard 状态；require_active 要求 transaction 已 begin，allow_active 允许其已 active。
  // 失败/边界：无 lease 时仅接受 owner=null/token=0；owner/token 不符或 transaction 冲突返回 BUSY；缺 begin 返回
  //   INVALID_STATE。
  protected function rdma_status validate_operation_lease(
    uvm_object owner,
    longint unsigned token,
    bit require_active = 1'b0,
    bit allow_active = 1'b0
  );
    rdma_status publication_status;

    if (m_lease_owner == null) begin
      if (owner != null || token != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "coordinator operation supplied an owner without an active lease"
        );
      publication_status = reject_mutation_during_reset_operation(
        "direct operation", allow_active
      );
      if (publication_status == null || !publication_status.ok())
        return publication_status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "coordinator publication guard validation returned null"
          ) : publication_status;
      if (m_reset_transaction_active)
        return rdma_status::make(
          RDMA_SC_RESOURCE_BUSY,
          "coordinator reset transaction is already active"
        );
      return rdma_status::success();
    end
    if (owner == null || owner !== m_lease_owner ||
        token == 0 || token != m_lease_token)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator lease is owned by another caller"
      );
    publication_status = reject_mutation_during_reset_operation(
      "leased operation", allow_active
    );
    if (publication_status == null || !publication_status.ok())
      return publication_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator publication guard validation returned null"
        ) : publication_status;
    if (m_reset_transaction_active && !allow_active)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator reset transaction is already active"
      );
    if (require_active && !m_reset_transaction_active)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "coordinator reset transaction has not begun"
      );
    return rdma_status::success();
  endfunction

  // 功能：占用 reset publication 的同步执行槽，阻止嵌套 reset_*。
  // 输入/输出及副作用：成功时置 m_reset_operation_active。
  // 失败/边界：已被占用返回 RESOURCE_BUSY；该 guard 不是线程锁。
  protected function rdma_status enter_reset_operation();
    if (m_reset_operation_active)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator reset publication is already active"
      );
    m_reset_operation_active = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：释放 publication 同步执行槽。
  // 输入/输出及副作用：清除 m_reset_operation_active，不回滚已提交 epoch。
  // 失败/边界：重复调用幂等。
  protected function void leave_reset_operation();
    m_reset_operation_active = 1'b0;
  endfunction

  // 功能：reset_* 实现返回后释放 guard，并把 null status 转为 INVALID_STATE。
  // 输入/输出及副作用：status、label 为输入；先 leave_reset_operation 再返回状态。
  // 失败/边界：status 为 null 视为内部契约违例，返回 INVALID_STATE。
  protected function rdma_status finish_reset_operation(
    rdma_status status,
    string label
  );
    leave_reset_operation();
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        {label, " returned null status"}
      );
    return status;
  endfunction

  // 功能：解析已登记 Function 的当前 incarnation（已应用 reset 数、generation、reset_epoch）。
  // 输入/输出及副作用：只读 registration 快照与 epoch ledger；各 output 在失败时为 0/null。
  // 失败/边界：条目缺失、校验失败、baseline 大于绝对 epoch 返回 INVALID_STATE；加法溢出返回 RESOURCE_EXHAUSTED。
  protected function rdma_status resolve_registered_incarnation(
    string name,
    output rdma_function_identity registered,
    output rdma_reset_epoch_t registration_epoch,
    output rdma_reset_epoch_t applied_resets,
    output longint unsigned current_generation,
    output rdma_reset_epoch_t current_epoch
  );
    rdma_reset_epoch_t absolute_epoch;
    rdma_status identity_status;

    registered = null;
    registration_epoch = 0;
    applied_resets = 0;
    current_generation = 0;
    current_epoch = 0;
    if (!m_functions.exists(name) || m_functions[name] == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "Function registration snapshot is missing"
      );

    registered = m_functions[name];
    identity_status = registered.validate();
    if (identity_status == null)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "Function registration snapshot validation returned null"
      );
    if (!identity_status.ok())
      return identity_status;

    registration_epoch = m_function_registration_epochs.exists(name) ?
                         m_function_registration_epochs[name] : 0;
    absolute_epoch = m_function_epochs.exists(name) ?
                     m_function_epochs[name] : 0;
    if (absolute_epoch < registration_epoch)
      return rdma_status::make_direct(
        RDMA_SC_INVALID_STATE,
        "Function registration epoch ledger is inconsistent"
      );
    applied_resets = absolute_epoch - registration_epoch;
    if (applied_resets >
        (64'hffff_ffff_ffff_ffff - registered.reset_epoch))
      return rdma_status::make_direct(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function reset epoch would overflow"
      );
    if (applied_resets >
        (64'h0000_0000_ffff_ffff - registered.generation))
      return rdma_status::make_direct(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function generation would overflow"
      );
    current_epoch = registered.reset_epoch + applied_resets;
    current_generation = registered.generation + applied_resets;
    return rdma_status::make_direct(RDMA_SC_OK);
  endfunction

  // 功能：在产生任何副作用前检查 Function 是否还能发布下一代 epoch。
  // 输入/输出及副作用：只读 ledger，不修改状态。
  // 失败/边界：条目缺失或不一致透传错误；epoch/generation 已到上限返回 RESOURCE_EXHAUSTED。
  protected function rdma_status validate_function_bump_capacity(string name);
    rdma_function_identity registered;
    rdma_reset_epoch_t registration_epoch;
    rdma_reset_epoch_t applied_resets;
    rdma_reset_epoch_t current_epoch;
    longint unsigned current_generation;
    rdma_reset_epoch_t absolute_epoch;
    rdma_status status;

    status = resolve_registered_incarnation(
      name, registered, registration_epoch, applied_resets,
      current_generation, current_epoch
    );
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Function bump capacity lookup returned null"
        ) : status;
    absolute_epoch = m_function_epochs.exists(name) ?
                     m_function_epochs[name] : 0;
    if (absolute_epoch == 64'hffff_ffff_ffff_ffff ||
        current_epoch == 64'hffff_ffff_ffff_ffff ||
        current_generation >= 32'hffff_ffff)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function reset generation or epoch is exhausted"
      );
    return rdma_status::success();
  endfunction

  // 功能：为 scope 内的 Function 名单构造 detached epoch candidate（各 epoch 加一）。
  // 输入/输出及副作用：function_names 为输入；candidate 输出快照，不修改 m_function_epochs。
  // 失败/边界：名称重复返回 INVALID_ARGUMENT；容量预检、计数溢出或校验失败时返回错误。
  protected function rdma_status prepare_function_epoch_commit(
    string function_names[$],
    output rdma_reset_epoch_candidate candidate
  );
    string name;
    bit seen[string];
    rdma_status status;
    rdma_reset_epoch_t current_epoch;

    candidate = rdma_reset_epoch_candidate::type_id::create(
      "function_epoch_candidate"
    );
    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function epoch candidate allocation failed"
      );
    status = candidate.capture_function_epochs(m_function_epochs);
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function epoch candidate capture returned null"
      ) : status;
    foreach (function_names[index]) begin
      name = function_names[index];
      if (seen.exists(name))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reset scope contains duplicate Function key"
        );
      seen[name] = 1'b1;
      status = validate_function_bump_capacity(name);
      if (status == null || !status.ok())
        return status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Function epoch staging capacity validation returned null"
          ) : status;
      current_epoch = candidate.function_epochs.exists(name) ?
                       candidate.function_epochs[name] : 0;
      if (current_epoch == 64'hffff_ffff_ffff_ffff)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function epoch staging counter is exhausted"
        );
      candidate.function_epochs[name] = current_epoch + 1;
    end
    status = candidate.validate();
    if (status == null || !status.ok())
      return status == null ? rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function epoch candidate validation returned null"
      ) : status;
    return rdma_status::success();
  endfunction

  // 功能：初始化设备 epoch 为 0，并清空 lease、guard 与 capability 暂存。
  // 输入/输出及副作用：name 为 UVM 对象名。
  // 失败/边界：不分配 Host-memory 或 manager 资源。
  function new(string name="rdma_reset_coordinator");
    super.new(name);
    m_device_epoch = 0;
    m_lease_owner = null;
    m_lease_token = 0;
    m_next_lease_token = 0;
    m_reset_transaction_active = 1'b0;
    m_reset_operation_active = 1'b0;
    m_router_attach_capability = null;
    m_router_attach_target = null;
    m_router_owned_capability = null;
    m_router_owned_target = null;
    m_router_owned_attach = 1'b0;
    m_router_epoch_capability = null;
    m_router_epoch_target = null;
    m_router_epoch_host = 0;
    m_router_epoch_advance = 1'b0;
  endfunction

  // 功能：为 device env 建立 coordinator 的唯一 ownership lease。
  // 输入/输出及副作用：owner 为非拥有句柄；token 输出新 token；成功时记录 m_lease_owner/m_lease_token。
  // 失败/边界：owner 为 null 返回 INVALID_ARGUMENT；已有 lease、transaction、legacy router 绑定返回 BUSY；token
  //   耗尽返回 RESOURCE_EXHAUSTED。
  function rdma_status acquire_lease(
    uvm_object owner,
    output longint unsigned token
  );
    rdma_status publication_status;

    token = 0;
    publication_status = reject_mutation_during_reset_operation(
      "lease acquisition"
    );
    if (publication_status == null || !publication_status.ok())
      return publication_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator publication guard validation returned null"
        ) : publication_status;
    if (owner == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "coordinator lease owner is null"
      );
    if (m_lease_owner != null || m_reset_transaction_active ||
        m_host_router != null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        m_host_router != null && m_lease_owner == null ?
          "coordinator has a legacy Host router binding; explicit handoff is required" :
          "coordinator already has an ownership lease"
      );
    if (m_next_lease_token == 64'hffff_ffff_ffff_ffff)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "coordinator lease token is exhausted"
      );
    m_next_lease_token++;
    m_lease_owner = owner;
    m_lease_token = m_next_lease_token;
    token = m_lease_token;
    return rdma_status::success();
  endfunction

  // 功能：结束 env 对 coordinator 的 lease，并清空 registration 与 epoch 账本。
  // 输入/输出及副作用：owner/token 须为当前 pair；成功时清空 ledger、capability 暂存与 lease。
  // 失败/边界：owner/token 不符、无 lease、transaction active 或 router 仍绑定时失败。
  function rdma_status release_lease(
    uvm_object owner,
    longint unsigned token
  );
    rdma_status status;

    status = validate_operation_lease(owner, token, 1'b0);
    if (status == null || !status.ok())
      return (status == null) ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator lease validation returned null"
        ) : status;
    if (m_lease_owner == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "coordinator has no ownership lease"
      );
    if (m_reset_transaction_active)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "cannot release coordinator lease during reset transaction"
      );
    if (m_host_router != null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "cannot release coordinator lease while Host router is attached"
      );
    // lease 结束即结束本次 env 的 registration scope；context 侧已在 release 前完成 quarantine，
    // 清掉 snapshot 与相对 epoch ledger 不影响仍在服务的 context，并允许 coordinator 复用于新拓扑。
    m_functions.delete();
    m_function_epochs.delete();
    m_function_registration_epochs.delete();
    m_host_epochs.delete();
    m_device_epoch = 0;
    m_router_attach_capability = null;
    m_router_attach_target = null;
    m_router_owned_capability = null;
    m_router_owned_target = null;
    m_router_owned_attach = 1'b0;
    m_router_epoch_capability = null;
    m_router_epoch_target = null;
    m_router_epoch_host = 0;
    m_router_epoch_advance = 1'b0;
    m_reset_operation_active = 1'b0;
    m_lease_owner = null;
    m_lease_token = 0;
    return rdma_status::success();
  endfunction

  // 功能：在 lease 内置位 reset transaction active 标志。
  // 输入/输出及副作用：owner/token 为当前 pair；成功时置 m_reset_transaction_active。
  // 失败/边界：无 lease 或 pair 过期、guard active、transaction 已 active 时返回错误。
  function rdma_status begin_reset(
    uvm_object owner,
    longint unsigned token
  );
    rdma_status status;
    rdma_status publication_status;

    publication_status = reject_mutation_during_reset_operation(
      "reset transaction begin"
    );
    if (publication_status == null || !publication_status.ok())
      return publication_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator publication guard validation returned null"
        ) : publication_status;

    if (m_lease_owner == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator reset transaction requires an ownership lease"
      );
    status = validate_operation_lease(owner, token, 1'b0);
    if (status == null || !status.ok())
      return (status == null) ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator reset lease validation returned null"
        ) : status;
    if (m_reset_transaction_active)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator reset transaction is already active"
      );
    m_reset_transaction_active = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：清除 begin_reset 置位的 transaction 标志。
  // 输入/输出及副作用：owner/token 须匹配当前 lease；成功时清标志，不回滚 epoch。
  // 失败/边界：owner/token 不符或 guard active 返回 BUSY；无 active transaction 返回 INVALID_STATE。
  function rdma_status end_reset(
    uvm_object owner,
    longint unsigned token
  );
    rdma_status status;
    rdma_status publication_status;

    // end_reset() 通常在 request_* 返回后调用，此时 guard 已释放；不允许在 wrapper 内的嵌套回调中
    // 调用，否则清除 transaction 标志会让回调发布第二个 scope。
    publication_status = reject_mutation_during_reset_operation(
      "reset transaction end"
    );
    if (publication_status == null || !publication_status.ok())
      return publication_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator publication guard validation returned null"
        ) : publication_status;

    status = validate_operation_lease(owner, token, 1'b0, 1'b1);
    if (status == null || !status.ok())
      return (status == null) ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator reset lease validation returned null"
        ) : status;
    if (!m_reset_transaction_active)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "coordinator reset transaction is not active"
      );
    m_reset_transaction_active = 1'b0;
    return rdma_status::success();
  endfunction

  // 功能：向 router/context 等非拥有组件公开只读的 lease 授权检查。
  // 输入/输出及副作用：转调 validate_operation_lease，不改状态。
  // 失败/边界：无 lease 仅接受 null/0；有 lease 时 owner/token 不符或 transaction 状态不符则失败。
  function rdma_status authorize_owned_operation(
    uvm_object owner,
    longint unsigned token,
    bit require_active = 1'b0,
    bit allow_active = 1'b0
  );
    return validate_operation_lease(
      owner, token, require_active, allow_active
    );
  endfunction

  // 功能：报告 coordinator 是否已被某个 env 独占。
  // 输入/输出及副作用：只读 m_lease_owner。
  // 失败/边界：无。
  function bit lease_held();
    return m_lease_owner != null;
  endfunction

  // 功能：报告 coordinator 是否已保存 Host-router 引用。
  // 输入/输出及副作用：只读 m_host_router。
  // 失败/边界：1 仅表示存在绑定，不代表 router 无 active mapping。
  function bit host_router_bound();
    return m_host_router != null;
  endfunction

  // 功能：报告 reset transaction 是否处于 begin/end 之间。
  // 输入/输出及副作用：只读 active 标志。
  // 失败/边界：无。
  function bit reset_transaction_active();
    return m_reset_transaction_active;
  endfunction

  // 功能：为无 owner/token 的 Host-router dataplane 入口提供 reset admission 判定。
  // 输入/输出及副作用：转调 evaluate，不读写 ledger。
  // 失败/边界：publication 或 transaction active 且 allow_cleanup=0 时返回 RESOURCE_BUSY。
  function rdma_status authorize_tokenless_dataplane(
    string operation_name,
    bit allow_cleanup = 1'b0
  );
    return rdma_reset_tokenless_admission_policy::evaluate(
      m_reset_operation_active,
      m_reset_transaction_active,
      allow_cleanup,
      operation_name
    );
  endfunction

  // 功能：回验并一次性消费 legacy attach capability。
  // 输入/输出及副作用：router、capability 须与暂存值一致；成功时清空暂存。
  // 失败/边界：为空、不匹配或已消费时返回 RESOURCE_BUSY。
  function rdma_status authorize_router_attach_capability(
    rdma_host_mem_router router,
    uvm_object capability
  );
    if (router == null || capability == null ||
        m_router_attach_target !== router ||
        m_router_attach_capability == null ||
        capability !== m_router_attach_capability)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "Host router attach capability is missing or stale"
      );
    m_router_attach_capability = null;
    m_router_attach_target = null;
    return rdma_status::success();
  endfunction

  // 功能：回验并一次性消费 leased attach/detach capability。
  // 输入/输出及副作用：先校验 lease，再比对 router、capability 与操作方向；成功时清空暂存。
  // 失败/边界：lease 校验失败透传；capability 缺失、过期、目标或方向不符返回 RESOURCE_BUSY。
  function rdma_status authorize_router_owned_capability(
    rdma_host_mem_router router,
    uvm_object capability,
    bit attach_operation,
    uvm_object owner,
    longint unsigned token
  );
    rdma_status lease_status;

    lease_status = validate_operation_lease(owner, token, 1'b0);
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "router owned capability lease validation returned null"
        ) : lease_status;
    if (router == null || capability == null ||
        m_router_owned_target !== router ||
        m_router_owned_capability == null ||
        capability !== m_router_owned_capability ||
        attach_operation != m_router_owned_attach)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "Host router owned capability is missing or stale"
      );
    m_router_owned_capability = null;
    m_router_owned_target = null;
    m_router_owned_attach = 1'b0;
    return rdma_status::success();
  endfunction

  // 功能：回验并一次性消费 Host router epoch capability，区分 capacity 与 advance。
  // 输入/输出及副作用：先校验 lease（须已 begin），再比对 router、host key、操作方向与 capability；成功时清空暂存。
  // 失败/边界：lease 失败透传；capability 缺失、过期或目标/方向不符返回 RESOURCE_BUSY。
  function rdma_status authorize_router_epoch_capability(
    rdma_host_mem_router router,
    int unsigned host_topology_key,
    bit advance_operation,
    uvm_object capability,
    uvm_object owner,
    longint unsigned token
  );
    rdma_status lease_status;

    lease_status = validate_operation_lease(owner, token, 1'b1, 1'b1);
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "router epoch capability lease validation returned null"
        ) : lease_status;
    if (router == null || capability == null ||
        m_router_epoch_target !== router ||
        m_router_epoch_capability == null ||
        capability !== m_router_epoch_capability ||
        host_topology_key != m_router_epoch_host ||
        advance_operation != m_router_epoch_advance)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "Host router epoch publication capability is missing or stale"
      );
    m_router_epoch_capability = null;
    m_router_epoch_target = null;
    m_router_epoch_host = 0;
    m_router_epoch_advance = 1'b0;
    return rdma_status::success();
  endfunction

  // 功能：暂存一次性 epoch capability，并委托 Host router 做 capacity 预检或 advance。
  // 输入/输出及副作用：host_topology_key/owner/token 透传；advance 选择操作；调用后无论成败都清空暂存。
  // 失败/边界：未绑定 router 返回 OK；capability 分配失败返回 RESOURCE_EXHAUSTED；router 返回 null 转为失败。
  protected function rdma_status call_host_router_epoch(
    int unsigned host_topology_key,
    uvm_object owner,
    longint unsigned token,
    bit advance
  );
    uvm_object capability;
    rdma_status status;
    string op;

    if (m_host_router == null)
      return rdma_status::success();
    op = advance ? "advance" : "capacity";
    capability = rdma_reset_router_epoch_capability::type_id::create(
      {"rdma_host_router_epoch_", op, "_capability"}
    );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        {"Host router epoch ", op, " capability allocation failed"}
      );
    m_router_epoch_capability = capability;
    m_router_epoch_target = m_host_router;
    m_router_epoch_host = host_topology_key;
    m_router_epoch_advance = advance;
    if (advance)
      status = m_host_router.advance_host_epoch(
        host_topology_key, owner, token, capability
      );
    else
      status = m_host_router.validate_host_epoch_capacity(
        host_topology_key, owner, token, capability
      );
    m_router_epoch_capability = null;
    m_router_epoch_target = null;
    m_router_epoch_host = 0;
    m_router_epoch_advance = 1'b0;
    return rdma_status::nonnull(
      status, {"Host router epoch ", op, " returned null"}
    );
  endfunction

  // 功能：经一次性 capability 把 Host router 绑定到本 coordinator（legacy 无 lease 路径）。
  // 输入/输出及副作用：成功后保存 router 非拥有引用；暂存的 capability 调用后一律清空。
  // 失败/边界：router 为 null 返回 INVALID_ARGUMENT；已有 lease/transaction 或绑定了其他 router 返回 BUSY；router
  //   拒绝则透传。
  function rdma_status attach_host_router_status(rdma_host_mem_router router);
    uvm_object capability;
    rdma_status status;
    rdma_status publication_status;

    publication_status = reject_mutation_during_reset_operation(
      "legacy Host router attach"
    );
    if (publication_status == null || !publication_status.ok())
      return publication_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "coordinator publication guard validation returned null"
        ) : publication_status;

    if (router == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "Host router is null"
      );
    if (m_lease_owner != null || m_reset_transaction_active)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator ownership prevents legacy Host router attach"
      );
    if (m_host_router != null && m_host_router !== router)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator is already bound to another Host router"
      );
    capability = rdma_reset_router_attach_capability::type_id::create(
      "rdma_host_router_attach_capability"
    );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host router attach capability allocation failed"
      );
    m_router_attach_capability = capability;
    m_router_attach_target = router;
    status = router.attach_reset_coordinator_status(this, 1'b1, capability);
    // router 在发布 m_reset 前消费有效 capability；拒绝时清空未消费的暂存，防止重放。
    m_router_attach_capability = null;
    m_router_attach_target = null;
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host router status attach returned null"
      );
    if (!status.ok())
      return status;
    m_host_router = router;
    return rdma_status::success();
  endfunction

  // 功能：保留旧 void attach 入口，转发到 attach_host_router_status 并忽略返回值。
  // 输入/输出及副作用：成功时建立双侧绑定，失败时保持原状。
  // 失败/边界：失败无诊断返回，需要状态请用 attach_host_router_status。
  function void attach_host_router(rdma_host_mem_router router);
    void'(attach_host_router_status(router));
  endfunction

  // 功能：在 lease 下通过 owned capability 绑定 Host router。
  // 输入/输出及副作用：成功时保存 router 引用；暂存的 capability 调用后一律清空。
  // 失败/边界：router 为 null 返回 INVALID_ARGUMENT；lease 校验失败、无 lease 或已绑定其他 router 返回错误。
  function rdma_status attach_host_router_owned(
    rdma_host_mem_router router,
    uvm_object owner,
    longint unsigned token
  );
    uvm_object capability;
    rdma_status status;

    if (router == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "Host router is null"
      );
    status = validate_operation_lease(owner, token, 1'b0);
    if (status == null || !status.ok())
      return (status == null) ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router lease validation returned null"
        ) : status;
    if (!lease_held())
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "owned Host router attach requires an active coordinator lease"
      );
    if (m_host_router != null && m_host_router !== router)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator is already bound to another Host router"
      );
    capability = rdma_reset_router_owned_capability::type_id::create(
      "rdma_host_router_owned_attach_capability"
    );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host router owned attach capability allocation failed"
      );
    m_router_owned_capability = capability;
    m_router_owned_target = router;
    m_router_owned_attach = 1'b1;
    status = router.attach_reset_coordinator_owned(
      this, owner, token, capability
    );
    // router 在发布 m_reset 前消费有效 capability；拒绝时清空未消费的暂存，防止重放。
    m_router_owned_capability = null;
    m_router_owned_target = null;
    m_router_owned_attach = 1'b0;
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router coordinator attach returned null"
        ) : status;
    m_host_router = router;
    return rdma_status::success();
  endfunction

  // 功能：在 lease 下通过 owned capability 与 Host router 完成双侧 detach。
  // 输入/输出及副作用：router 先清除自身绑定，coordinator 再清空 m_host_router。
  // 失败/边界：router 为 null 返回 INVALID_ARGUMENT；lease 失败透传；router 非本 coordinator 绑定对象返回
  //   INVALID_STATE。
  function rdma_status detach_host_router_owned(
    rdma_host_mem_router router,
    uvm_object owner,
    longint unsigned token
  );
    uvm_object capability;
    rdma_status status;

    if (router == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "Host router is null"
      );
    status = validate_operation_lease(owner, token, 1'b0);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router detach lease validation returned null"
        ) : status;
    if (!lease_held())
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "owned Host router detach requires an active coordinator lease"
      );
    // m_host_router 须与参数是同一对象：否则 foreign coordinator 可对仍绑定本 coordinator 的
    // router 伪造双侧 teardown 并释放自己的 lease，真实反向引用却仍存活。反向引用的清除还需
    // router 自身的 capability 回验。
    if (m_host_router !== router)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host router is not bound to this coordinator"
      );
    capability = rdma_reset_router_owned_capability::type_id::create(
      "rdma_host_router_owned_detach_capability"
    );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host router owned detach capability allocation failed"
      );
    m_router_owned_capability = capability;
    m_router_owned_target = router;
    m_router_owned_attach = 1'b0;
    status = router.detach_reset_coordinator_owned(
      this, owner, token, capability
    );
    // router 在清除 m_reset 前消费有效 capability；拒绝时清空未消费的暂存，防止重放。
    m_router_owned_capability = null;
    m_router_owned_target = null;
    m_router_owned_attach = 1'b0;
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host router detach returned null status"
        ) : status;
    m_host_router = null;
    return rdma_status::success();
  endfunction

  // 功能：原子登记一批 Function identity，并按需绑定 Host router。
  // 输入/输出及副作用：先在 staged 副本上校验并克隆；成功后才替换 m_functions 与 registration epoch 账本。
  // 失败/边界：identity 为空/重复、UID 或 global ID 被另一 route 占用、incarnation 非当前、clone 或 router attach
  //   失败时不改账本。
  function rdma_status commit_registration_atomic(
    rdma_host_mem_router router,
    rdma_function_identity identities[$],
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_function_identity staged_functions[string];
    rdma_reset_epoch_t staged_registration_epochs[string];
    rdma_function_identity snapshot;
    string name;
    bit input_seen[string];
    string input_uid_owner[string];
    string input_global_id_owner[string];
    string uid_key;
    string global_id_key;
    string existing_name;
    rdma_function_identity existing;
    rdma_function_identity current_registered;
    rdma_reset_epoch_t registration_epoch;
    rdma_reset_epoch_t applied_resets;
    rdma_reset_epoch_t current_epoch;
    longint unsigned current_generation;
    rdma_status identity_status;
    rdma_status incarnation_status;
    rdma_status lease_status;

    lease_status = validate_operation_lease(owner, lease_token, 1'b0);
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function registration lease validation returned null"
        ) : lease_status;

    // 先复制旧引用（已由 coordinator 拥有）；新 incarnation 只追加 detached clone，失败时无需回滚。
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
      identity_status = rdma_status::nonnull(
        identities[index].validate(),
        "reset coordinator registration identity validation returned null"
      );
      if (!identity_status.ok())
        return identity_status;
      name = identity_name(identities[index]);
      if (input_seen.exists(name)) begin
        // 同批次重复 stable key 一律拒绝，避免输入顺序决定最终 incarnation。
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reset coordinator registration contains duplicate Function key"
        );
      end

      uid_key = $sformatf("%0d", identities[index].function_uid);
      global_id_key = $sformatf("%0d", identities[index].global_function_id);
      if (input_uid_owner.exists(uid_key) &&
          input_uid_owner[uid_key] != name)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reset coordinator registration reuses Function UID"
        );
      if (input_global_id_owner.exists(global_id_key) &&
          input_global_id_owner[global_id_key] != name)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "reset coordinator registration reuses global Function ID"
        );

      // UID/global-ID 是全局 Function authority：同一 route 的 incarnation 可沿用，其他 route 不得借用。
      foreach (staged_functions[existing_name]) begin
        if (existing_name == name || staged_functions[existing_name] == null)
          continue;
        if (staged_functions[existing_name].function_uid ==
              identities[index].function_uid)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reset coordinator registration UID belongs to another route"
          );
        if (staged_functions[existing_name].global_function_id ==
              identities[index].global_function_id)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reset coordinator registration global ID belongs to another route"
          );
      end

      input_uid_owner[uid_key] = name;
      input_global_id_owner[global_id_key] = name;

      if (staged_functions.exists(name) && staged_functions[name] != null) begin
        existing = staged_functions[name];
        if (!existing.same_function(identities[index]) ||
            existing.function_uid != identities[index].function_uid)
          return rdma_status::make(
            RDMA_SC_INVALID_ARGUMENT,
            "reset coordinator registration changes Function authority"
          );
        incarnation_status = resolve_registered_incarnation(
          name, current_registered, registration_epoch, applied_resets,
          current_generation, current_epoch
        );
        if (incarnation_status == null || !incarnation_status.ok())
          return incarnation_status == null ?
            rdma_status::make_direct(
              RDMA_SC_INVALID_STATE,
              "Function registration incarnation lookup returned null"
            ) : incarnation_status;
        // 仅接受与 coordinator 推导值完全一致的当前 incarnation 作为新 baseline；向前跳跃会掩盖漏掉的
        // reset publication。reset 后即使输入等于旧 snapshot 也须经 current-incarnation 比较，以免
        // stale registration 被静默接受；未 reset 过且完全相同时走旧 API 的幂等快路径。
        if (identities[index].generation != current_generation ||
            identities[index].reset_epoch != current_epoch)
          return rdma_status::make(
            RDMA_SC_STALE_GENERATION,
            "reset coordinator registration incarnation is not current"
          );
        if (applied_resets == 0 && existing.same_incarnation(identities[index])) begin
          input_seen[name] = 1'b1;
          continue;
        end
      end

      if (!rdma_deep_copy#(rdma_function_identity)::try_of(identities[index], snapshot))
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "reset coordinator Function identity clone failed"
        );
      staged_functions[name] = snapshot;
      staged_registration_epochs[name] = m_function_epochs.exists(name) ?
                                          m_function_epochs[name] : 0;
      input_seen[name] = 1'b1;
    end

    // 此处 identity 校验已全部完成；router attach 仍可能被 active mapping 或 foreign lease 拒绝，
    // 故 attach 成功后才替换 router 引用，避免 registration ledger 与 router authority 分叉。
    if (router != null) begin
      if (m_lease_owner != null)
        lease_status = attach_host_router_owned(
          router, owner, lease_token
        );
      else
        // legacy 登记也须经 coordinator facade 取得一次性 capability，避免单侧 split-brain。
        lease_status = attach_host_router_status(router);
      if (lease_status == null || !lease_status.ok())
        return lease_status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host router lease attach returned null"
          ) : lease_status;
    end
    m_functions = staged_functions;
    m_function_registration_epochs = staged_registration_epochs;
    return rdma_status::success();
  endfunction

  // 功能：登记单个 Function 的 identity 快照（兼容旧 void API）。
  // 输入/输出及副作用：转调 commit_registration_atomic，使用当前 m_host_router。
  // 失败/边界：identity 为 null 忽略；提交被拒绝时 uvm_fatal。
  function void register_function(rdma_function_identity identity);
    rdma_function_identity identities[$];
    rdma_status status;

    if (identity == null)
      return;
    // 兼容旧 void API；device-env build 使用带 status 的批量入口，本 wrapper 保留 clone 失败即 fatal。
    identities.push_back(identity);
    status = commit_registration_atomic(m_host_router, identities);
    if (status == null || !status.ok())
      `uvm_fatal("RDMA_RESET", status == null ?
                "Function identity registration returned null status" :
                status.message)
  endfunction
  // 功能：按 Function UID 查询当前有效 reset epoch（registration baseline 加已发布 reset 数）。
  // 输入/输出及副作用：uid 为输入；只读扫描已登记 identity，不创建条目。
  // 失败/边界：uid 为 0、UID 重复、未知条目或 baseline 不一致时返回 0。
  function rdma_reset_epoch_t function_epoch_uid(longint unsigned uid);
    string name;
    rdma_function_identity registered;
    rdma_reset_epoch_t registration_epoch;
    rdma_reset_epoch_t applied_resets;
    rdma_reset_epoch_t current_epoch;
    longint unsigned current_generation;
    rdma_status status;
    bit found;
    rdma_reset_epoch_t resolved_epoch;

    if (uid == 0)
      return 0;
    found = 1'b0;
    resolved_epoch = 0;
    foreach (m_functions[name]) begin
      if (m_functions[name] == null ||
          m_functions[name].function_uid != uid)
        continue;
      if (found)
        return 0;
      status = resolve_registered_incarnation(
        name, registered, registration_epoch, applied_resets,
        current_generation, current_epoch
      );
      if (status == null || !status.ok())
        return 0;
      found = 1'b1;
      resolved_epoch = current_epoch;
    end
    return found ? resolved_epoch : 0;
  endfunction

  // 功能：校验 Function handle 与完整 route 对应当前登记 incarnation，并输出当前 epoch。
  // 输入/输出及副作用：只读 ledger；allow_stale_generation 为 1 时不比较 generation；current_epoch 输出。
  // 失败/边界：handle/UID 非法返回 INVALID_ARGUMENT；route 或 global ID 不符返回 DMA_TRANSLATION；generation
  //   过期返回 STALE_GENERATION；未登记/重复/损坏返回 INVALID_STATE。
  protected function rdma_status validate_registered_function_handle_internal(
    rdma_function_handle function_h,
    rdma_route_key_t route,
    bit allow_stale_generation,
    output rdma_reset_epoch_t current_epoch
  );
    string name;
    rdma_function_identity registered;
    rdma_reset_epoch_t registration_epoch;
    rdma_reset_epoch_t applied_resets;
    rdma_reset_epoch_t resolved_epoch;
    longint unsigned expected_generation;
    rdma_status status;
    rdma_status identity_status;
    bit uid_found;

    current_epoch = 0;
    if (function_h == null || function_h.kind != RDMA_RESOURCE_FUNCTION)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "registered Function handle is invalid"
      );
    if (!rdma_route_key_valid(route))
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "registered Function route is invalid"
      );
    if (function_h.function_uid == 0)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "registered Function UID is zero"
      );

    uid_found = 1'b0;
    foreach (m_functions[name]) begin
      registered = m_functions[name];
      if (registered == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset coordinator contains a null Function registration"
        );
      identity_status = registered.validate();
      if (identity_status == null || !identity_status.ok())
        return identity_status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Function registration validation returned null"
          ) : identity_status;
      if (registered.function_uid != function_h.function_uid)
        continue;
      if (uid_found)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function UID is duplicated in reset coordinator"
        );
      uid_found = 1'b1;
      status = resolve_registered_incarnation(
        name, registered, registration_epoch, applied_resets,
        expected_generation, resolved_epoch
      );
      if (status == null || !status.ok())
        return status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Function registration incarnation lookup returned null"
          ) : status;
      if (registered.global_function_id != function_h.object_id)
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "Function handle global ID is not registered"
        );
      if (!rdma_bdf_same(registered.key.bdf, route.bdf) ||
          registered.key.host_topology_key != route.host_topology_key ||
          registered.key.root_id != route.root_id ||
          registered.key.bdf.segment != route.segment)
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "Function handle route is not registered"
        );
      if (!allow_stale_generation &&
          function_h.generation != expected_generation)
        return rdma_status::make(
          RDMA_SC_STALE_GENERATION,
          "Function handle generation is stale"
        );
      current_epoch = resolved_epoch;
    end
    if (!uid_found)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function UID is not registered"
      );
    return rdma_status::success();
  endfunction

  // 功能：严格校验 Function handle 与 route 属于当前 incarnation。
  // 输入/输出及副作用：function_h、route 为输入；current_epoch 输出。
  // 失败/边界：generation 过期等同 internal 的拒绝条件。
  function rdma_status validate_registered_function_handle(
    rdma_function_handle function_h,
    rdma_route_key_t route,
    output rdma_reset_epoch_t current_epoch
  );
    return validate_registered_function_handle_internal(
      function_h, route, 1'b0, current_epoch
    );
  endfunction

  // 功能：reset drain 释放旧 mapping 时校验 handle，允许 generation 已过期。
  // 输入/输出及副作用：function_h、route 为输入；current_epoch 输出。
  // 失败/边界：UID、global ID、route 被篡改或登记损坏仍失败。
  function rdma_status validate_registered_function_handle_for_drain(
    rdma_function_handle function_h,
    rdma_route_key_t route,
    output rdma_reset_epoch_t current_epoch
  );
    return validate_registered_function_handle_internal(
      function_h, route, 1'b1, current_epoch
    );
  endfunction

  // 功能：执行 VF FLR，仅为目标 VF 整体提交新的 Function epoch。
  // 输入/输出及副作用：先校验 lease 与登记，再 staged 构造 candidate，成功后才替换 m_function_epochs。
  // 失败/边界：identity 为 null 或非 VF 返回 INVALID_ARGUMENT；lease、登记或容量校验失败则不改 epoch。
  protected function rdma_status request_vf_flr_impl(
    rdma_function_identity identity,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_candidate candidate;
    string function_names[$];
    rdma_status status;

    status = validate_operation_lease(owner, lease_token, 1'b1, 1'b1);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "VF FLR lease validation returned null"
        ) : status;

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
    function_names.push_back(identity_name(identity));
    status = prepare_function_epoch_commit(function_names, candidate);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Function epoch staging returned null"
        ) : status;
    m_function_epochs = candidate.function_epochs;
    candidate.clear();
    return rdma_status::success();
  endfunction
  // 功能：执行 PF reset，对目标 PF 及其同 Host/root/parent BDF 的 VF 整体 bump epoch。
  // 输入/输出及副作用：先校验 lease 与登记，收集整个 scope 再 staged 提交 m_function_epochs。
  // 失败/边界：identity 为 null 或非 PF 返回 INVALID_ARGUMENT；任一 Function 校验或容量失败则整体不提交。
  protected function rdma_status request_pf_reset_impl(
    rdma_function_identity identity,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_candidate candidate;
    string function_names[$];
    rdma_status status;
    string name;

    status = validate_operation_lease(owner, lease_token, 1'b1, 1'b1);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "PF reset lease validation returned null"
        ) : status;

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
    // 先收集并检查整个 PF/VF scope，避免在后一个 Function 溢出时留下部分 bump。
    foreach (m_functions[name]) begin
      if (m_functions[name] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset coordinator contains a null Function snapshot"
        );
      if (m_functions[name].key.host_topology_key ==
            identity.key.host_topology_key &&
          m_functions[name].key.root_id == identity.key.root_id &&
          ((m_functions[name].key.function_kind == RDMA_FUNCTION_PF &&
            rdma_bdf_same(m_functions[name].key.bdf, identity.key.bdf)) ||
           (m_functions[name].key.function_kind == RDMA_FUNCTION_VF &&
            rdma_bdf_same(m_functions[name].key.parent_pf_bdf,
                          identity.key.bdf)))) begin
        function_names.push_back(name);
      end
    end
    status = prepare_function_epoch_commit(function_names, candidate);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "PF reset scope epoch staging returned null"
        ) : status;
    m_function_epochs = candidate.function_epochs;
    candidate.clear();
    return rdma_status::success();
  endfunction
  // 功能：推进指定 Host epoch，并对该 Host 上全部 Function 级联 bump。
  // 输入/输出及副作用：先校验 scope 与 router 容量，再 staged 准备；router advance 是唯一外部副作用，成功后才提交本地 epoch。
  // 失败/边界：Host 未登记、epoch 耗尽、router 预检/advance 失败或 scope 内 Function 耗尽时不改 coordinator epoch。
  protected function rdma_status request_host_reset_impl(
    int unsigned host_topology_key,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_candidate candidate;
    string function_names[$];
    rdma_status router_status;
    rdma_status status;
    string name;

    status = validate_operation_lease(owner, lease_token, 1'b1, 1'b1);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host reset lease validation returned null"
        ) : status;

    status = validate_registered_host_scope(host_topology_key);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(RDMA_SC_INVALID_STATE,
                          "registered Host scope validation returned null") :
        status;
    if (m_host_epochs.exists(host_topology_key) &&
        m_host_epochs[host_topology_key] == 64'hffff_ffff_ffff_ffff)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host reset epoch is exhausted"
      );
    if (m_host_router != null) begin
      status = call_host_router_epoch(
        host_topology_key, owner, lease_token, 1'b0);
      if (status == null || !status.ok())
        return status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host router epoch capacity validation returned null"
          ) : status;
    end
    foreach (m_functions[name]) begin
      if (m_functions[name].key.host_topology_key == host_topology_key) begin
        function_names.push_back(name);
      end
    end
    status = prepare_function_epoch_commit(function_names, candidate);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Host reset scope epoch staging returned null"
        ) : status;

    // router-local advance 是本 scope 唯一的外部副作用；本地 map 均已 staged，router 拒绝时
    // coordinator 的 Host/Function epoch 保持不变。
    if (m_host_router != null) begin
      router_status = call_host_router_epoch(
        host_topology_key, owner, lease_token, 1'b1);
      if (router_status == null || !router_status.ok())
        return router_status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host router epoch advance returned null"
          ) : router_status;
    end
    m_host_epochs[host_topology_key] = m_host_epochs.exists(host_topology_key) ?
                                       m_host_epochs[host_topology_key] + 1 : 1;
    m_function_epochs = candidate.function_epochs;
    candidate.clear();
    return rdma_status::success();
  endfunction
  // 功能：推进全局 Device epoch，并对全部已登记 Function 整体 bump epoch。
  // 输入/输出及副作用：先 staged 构造 candidate，成功后递增 m_device_epoch 并替换 m_function_epochs。
  // 失败/边界：Device epoch 耗尽、ledger 含 null snapshot 或 Function 容量失败时不提交。
  protected function rdma_status request_device_reset_impl(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_candidate candidate;
    string function_names[$];
    string name;
    rdma_status status;

    status = validate_operation_lease(owner, lease_token, 1'b1, 1'b1);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Device reset lease validation returned null"
        ) : status;

    if (m_device_epoch == 64'hffff_ffff_ffff_ffff)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Device reset epoch is exhausted"
      );
    foreach (m_functions[name]) begin
      if (m_functions[name] == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "reset coordinator contains a null Function snapshot"
        );
      function_names.push_back(name);
    end
    status = prepare_function_epoch_commit(function_names, candidate);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Device reset scope epoch staging returned null"
        ) : status;
    m_device_epoch++;
    m_function_epochs = candidate.function_epochs;
    candidate.clear();
    return rdma_status::success();
  endfunction

  // 功能：VF FLR 的公开入口，在同步 publication 窗口内安装重入屏障。
  // 输入/输出及副作用：转发参数给 impl；返回前经 finish_reset_operation 释放屏障。
  // 失败/边界：嵌套调用返回 RESOURCE_BUSY；其余沿用 impl 的结果。
  function rdma_status request_vf_flr(
    rdma_function_identity identity,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status guard_status;
    rdma_status result_status;

    guard_status = enter_reset_operation();
    if (guard_status == null || !guard_status.ok())
      return guard_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "VF FLR reset publication guard returned null"
        ) : guard_status;
    result_status = request_vf_flr_impl(identity, owner, lease_token);
    return finish_reset_operation(result_status, "VF FLR reset");
  endfunction

  // 功能：PF reset 的公开入口，在同步 publication 窗口内安装重入屏障。
  // 输入/输出及副作用：转发参数给 impl；返回前经 finish_reset_operation 释放屏障。
  // 失败/边界：嵌套调用返回 RESOURCE_BUSY；其余沿用 impl 的结果。
  function rdma_status request_pf_reset(
    rdma_function_identity identity,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status guard_status;
    rdma_status result_status;

    guard_status = enter_reset_operation();
    if (guard_status == null || !guard_status.ok())
      return guard_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "PF reset publication guard returned null"
        ) : guard_status;
    result_status = request_pf_reset_impl(identity, owner, lease_token);
    return finish_reset_operation(result_status, "PF reset");
  endfunction

  // 功能：Host reset 的公开入口，在同步 publication 窗口内安装重入屏障。
  // 输入/输出及副作用：转发参数给 impl；返回前经 finish_reset_operation 释放屏障。
  // 失败/边界：嵌套调用返回 RESOURCE_BUSY；其余沿用 impl 的结果。
  function rdma_status request_host_reset(
    int unsigned host_topology_key,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status guard_status;
    rdma_status result_status;

    guard_status = enter_reset_operation();
    if (guard_status == null || !guard_status.ok())
      return guard_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Host reset publication guard returned null"
        ) : guard_status;
    result_status = request_host_reset_impl(
      host_topology_key, owner, lease_token
    );
    return finish_reset_operation(result_status, "Host reset");
  endfunction

  // 功能：Device reset 的公开入口，在同步 publication 窗口内安装重入屏障。
  // 输入/输出及副作用：转发 owner/lease_token 给 impl；返回前释放屏障。
  // 失败/边界：嵌套调用返回 RESOURCE_BUSY；其余沿用 impl 的结果。
  function rdma_status request_device_reset(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status guard_status;
    rdma_status result_status;

    guard_status = enter_reset_operation();
    if (guard_status == null || !guard_status.ok())
      return guard_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Device reset publication guard returned null"
        ) : guard_status;
    result_status = request_device_reset_impl(owner, lease_token);
    return finish_reset_operation(result_status, "Device reset");
  endfunction

  // 功能：按完整 identity key 查询当前有效 reset epoch。
  // 输入/输出及副作用：只读；registration baseline 加其后已发布 reset 数。
  // 失败/边界：identity 为 null 或解析失败返回 0；需区分合法 0 时先调用 validate_registered_identity。
  function rdma_reset_epoch_t function_epoch(rdma_function_identity identity);
    string name;
    rdma_function_identity registered;
    rdma_reset_epoch_t registration_epoch;
    rdma_reset_epoch_t applied_resets;
    rdma_reset_epoch_t current_epoch;
    longint unsigned current_generation;
    rdma_status status;

    if (identity == null)
      return 0;
    name = identity_name(identity);
    status = resolve_registered_incarnation(
      name, registered, registration_epoch, applied_resets,
      current_generation, current_epoch
    );
    return (status != null && status.ok()) ? current_epoch : 0;
  endfunction
  // 功能：查询指定 Host 的 reset epoch。
  // 输入/输出及副作用：只读 m_host_epochs，不创建条目。
  // 失败/边界：Host 未登记或从未 reset 返回 0。
  function rdma_reset_epoch_t host_epoch(int unsigned host_topology_key);
    return m_host_epochs.exists(host_topology_key) ?
           m_host_epochs[host_topology_key] : 0;
  endfunction
  // 功能：返回当前全局 Device reset epoch。
  // 输入/输出及副作用：只读。
  // 失败/边界：未发生 device reset 时为 0。
  function rdma_reset_epoch_t device_epoch();
    return m_device_epoch;
  endfunction

  // 功能：只读确认 identity 对应 coordinator 当前登记的 incarnation。
  // 输入/输出及副作用：按完整 key 查找并与推导的 generation/reset_epoch 比对，不修改 ledger。
  // 失败/边界：null 或 validate 失败、key 未登记返回错误；authority、incarnation 或 epoch 过期返回 STALE_GENERATION。
  function rdma_status validate_registered_identity(
    rdma_function_identity identity
  );
    rdma_status identity_status;
    rdma_function_identity registered;
    rdma_reset_epoch_t registration_epoch;
    rdma_reset_epoch_t applied_resets;
    rdma_reset_epoch_t expected_epoch;
    longint unsigned expected_generation;
    rdma_status incarnation_status;
    string name;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function identity is null");
    identity_status = rdma_status::nonnull(
      identity.validate(),
      "Function identity validation returned null"
    );
    if (!identity_status.ok())
      return identity_status;

    name = identity_name(identity);
    incarnation_status = resolve_registered_incarnation(
      name, registered, registration_epoch, applied_resets,
      expected_generation, expected_epoch
    );
    if (incarnation_status == null || !incarnation_status.ok())
      return incarnation_status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "registered Function incarnation lookup returned null"
        ) : incarnation_status;
    // 登记快照发布后尚未 reset 时直接 same_incarnation，保留旧 API 的幂等语义；reset 后由 immutable
    // snapshot 加其后已发布的 Function epoch 推导当前 incarnation，避免为校验而复制或提前替换
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

    if (identity.generation != expected_generation ||
        identity.reset_epoch != expected_epoch)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function identity generation/reset epoch is stale"
      );
    return rdma_status::success();
  endfunction

  // 功能：确认 Host topology scope 至少含一个已登记 Function。
  // 输入/输出及副作用：只读扫描 ledger。
  // 失败/边界：无登记 Function 或含 null snapshot 返回 INVALID_STATE。
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

  // 功能：返回已登记 Function 数量。
  // 输入/输出及副作用：只读。
  // 失败/边界：ledger 为空返回 0。
  function int unsigned function_count();
    return m_functions.num();
  endfunction

  // 功能：预览已登记 Function 下一次将发布的 reset epoch。
  // 输入/输出及副作用：identity 为输入；next_epoch 输出当前 epoch 加一，不修改 ledger。
  // 失败/边界：登记校验失败透传（next_epoch 为 0）；epoch 已满返回 RESOURCE_EXHAUSTED。
  function rdma_status preview_next_function_epoch(
    rdma_function_identity identity,
    output rdma_reset_epoch_t next_epoch
  );
    rdma_status status;
    rdma_reset_epoch_t current_epoch;

    next_epoch = 0;
    status = rdma_status::nonnull(
      validate_registered_identity(identity),
      "Function epoch preview returned null validation"
    );
    if (!status.ok())
      return status;
    current_epoch = function_epoch(identity);
    if (current_epoch == 64'hffff_ffff_ffff_ffff)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function reset epoch is exhausted"
      );
    next_epoch = current_epoch + 1;
    return rdma_status::success();
  endfunction

  // 功能：统计指定 Host 下参与 Host reset 的已登记 Function 数。
  // 输入/输出及副作用：只读扫描 ledger。
  // 失败/边界：null snapshot 被跳过，可能导致计数不完整。
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

  // 功能：统计指定 PF reset 会级联的 PF/VF 数量（同 Host、root，PF 自身及其 VF）。
  // 输入/输出及副作用：只读扫描 ledger。
  // 失败/边界：identity 为 null 或非 PF 返回 0；null snapshot 被跳过。
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

  // 功能：把 identity 的完整 Host/root/kind/VF/BDF/parent PF key 编码为 ledger 字符串键。
  // 输入/输出及副作用：只读 i，返回字符串。
  // 失败/边界：i 为 null 会触发仿真错误，仅限已登记 identity 调用。
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
