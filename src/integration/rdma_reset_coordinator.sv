// 目录：src/integration/，位于复位控制面与 Host-memory router 的共享状态层。
// 职责：为注册的 PF/VF、Host 和 Device 维护独立 epoch，并实现 VF FLR、PF reset、
//       Host reset、Device reset 的精确影响范围，供 router 拒绝过期 DMA 资源。
// 依赖：rdma_function_identity、rdma_host_mem_router 和 rdma_status。
// 所有权与生命周期：coordinator 克隆并拥有 identity ledger；Host router 仅保存
//       非拥有引用；epoch 从对象创建起累积到 coordinator 生命周期结束。
//
// 设计说明：legacy Host-router attach 仍保留兼容 facade，但 router 不能把一个公开 bit 当作
//       authority。legacy attach 与 leased owned attach/detach 各自使用 coordinator 在一次
//       同步调用中创建并传递的一次性 opaque capability；router 不保存 capability，也不取得
//       router/manager 所有权，而是在写入自身非拥有 coordinator 引用前向 coordinator 回验
//       目标、操作方向和当前 owner/token，避免任何公开 router seam 形成单侧绑定。
class rdma_reset_router_attach_capability extends uvm_object;
  `uvm_object_utils(rdma_reset_router_attach_capability)

  // 功能：构造不含可变业务字段的一次性 Host-router attach capability。
  // 输入/输出及副作用：name（输入）；初始化 UVM 对象名称，不分配 Host-memory、router 或
  //   coordinator 资源；对象身份本身由 coordinator 作为短生命周期授权凭证使用。
  // 失败/边界：capability 不应被调用方缓存、复制或跨 attach 重放；构造成功不代表任何
  //   router 已绑定，只有 coordinator 的当前 target 校验通过后才有效。
  function new(string name = "rdma_reset_router_attach_capability");
    super.new(name);
  endfunction
endclass

// 功能：承载 coordinator 为一次 leased Host-router attach 或 detach 生成的 opaque 授权句柄。
// 输入/输出及副作用：name（输入）只初始化 UVM 对象名称；对象不携带可供调用方篡改的业务
//       字段，不分配 router、Host-memory 或 coordinator 资源，身份由 coordinator 暂存并回验。
// 失败/边界：句柄只能在创建它的 coordinator 当前同步调用中使用一次；调用方复制、伪造、跨
//       router/跨操作重放都必须在 coordinator 回验处被拒绝，构造成功本身不代表任何授权。
class rdma_reset_router_owned_capability extends uvm_object;
  `uvm_object_utils(rdma_reset_router_owned_capability)

  // 功能：构造一个不含业务字段的 leased Host-router owned capability 对象。
  // 输入/输出及副作用：name（输入）用于初始化 UVM 对象名；函数返回新对象本身，不创建
  //       router、manager 或 coordinator 资源，也不改变任何绑定状态。
  // 失败/边界：空 name 仍应得到可用 opaque 对象；对象只有在 coordinator 当前暂存并回验
  //       的同步调用中才有意义，调用方单独构造的实例不能通过授权检查。
  function new(string name = "rdma_reset_router_owned_capability");
    super.new(name);
  endfunction
endclass

// 功能：承载 coordinator 为一次 Host epoch capacity/advance publication 生成的 opaque
//       capability；该对象只表达“当前同步调用由 coordinator 驱动”，不暴露 Host key、router
//       或 owner/token 字段给调用方。
// 输入/输出及副作用：name（输入）只初始化 UVM 对象名称；对象不分配 router、Host-memory 或
//       epoch 资源，实际目标和操作方向暂存于 coordinator 并由回验函数比对。
// 失败/边界：句柄只能在 coordinator 当前 request_host_reset() 的单次同步调用中使用一次；
//       调用方复制、伪造、跨 Host/跨 router 重放都必须被 coordinator 回验拒绝。
class rdma_reset_router_epoch_capability extends uvm_object;
  `uvm_object_utils(rdma_reset_router_epoch_capability)

  // 功能：构造一个不含业务字段的 Host epoch publication capability 对象。
  // 输入/输出及副作用：name（输入）用于初始化 UVM 对象名；函数返回新对象本身，不创建
  //       router、manager、epoch ledger 或 owner 资源。
  // 失败/边界：空 name 仍得到可用 opaque 对象；单独构造的实例没有 coordinator 暂存配对，
  //       不能通过 authorize_router_epoch_capability() 的目标、方向和身份检查。
  function new(string name = "rdma_reset_router_epoch_capability");
    super.new(name);
  endfunction
endclass

// 设计说明：tokenless Host-router 数据面需要在调用外部 manager 前做一个可重复的
// reset-admission 判定，但该判定不应读取或改变 coordinator 的 owner、epoch 或 router
// ledger。将三态输入冻结为 detached policy，既能让 allocate/write/read 共用同一契约，
// 也能让测试直接覆盖 publication、transaction 和 cleanup 的组合，而不伪造并发锁。
class rdma_reset_tokenless_admission_policy;

  // 功能：根据同步 publication guard、leased reset transaction 和 cleanup 意图，决定
  //       tokenless Host-router 数据面操作是否可以继续访问外部 manager。
  // 输入/输出及副作用：publication_active、transaction_active（输入）分别表示同步
  //       publication 窗口和 reset transaction 是否 active；allow_cleanup（输入）表示
  //       调用方是否明确执行 stale-drain/rollback；operation_name（输入）用于错误诊断；
  //       返回 detached rdma_status，不读取或修改任何 coordinator、router 或 epoch 状态。
  // 失败/边界：任一 reset 标志 active 且 allow_cleanup=0 时返回 RESOURCE_BUSY；cleanup
  //       意图或两个标志均 inactive 时返回 OK。该 policy 只描述同步 admission，不提供
  //       跨线程、跨进程或仿真调度级互斥，调用方仍须执行自身的 authority/retry 校验。
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

  // 一对一 ownership lease：device env 在发布 coordinator/Host-router 事务前取得
  // 唯一 token；coordinator 不拥有 owner 对象，只保存非拥有句柄并在每个可变入口
  // 校验 owner/token。lease 不是跨线程锁，不能替代仿真调度同步，但能拒绝另一
  // env、旧 token 或无 token 的 direct callback 绕过当前事务边界。
  protected uvm_object m_lease_owner;
  protected longint unsigned m_lease_token;
  protected longint unsigned m_next_lease_token;
  protected bit m_reset_transaction_active;
  // 同步 publication guard：lease 只证明调用者身份，不能阻止 identity validator、router
  // 或 context callback 在同一 SystemVerilog function 调用栈中再次进入 reset_*。该标志只在
  // 一个 request_* wrapper 的同步执行窗口内置位，拒绝嵌套 publication；它不是抢占式线程锁。
  protected bit m_reset_operation_active;
  // legacy attach facade 的一次性 capability。router 只保存非拥有引用，不能凭一个
  // 可伪造的 coordinator_initiated bit 自行绑定；coordinator 在同步调用期间暂存
  // capability/target，router 通过下方授权函数核验后才允许写入 m_reset。
  protected uvm_object m_router_attach_capability;
  protected rdma_host_mem_router m_router_attach_target;
  // leased owned attach/detach 的一次性 capability 只在 coordinator 调用 router 的同步
  // seam 期间暂存；router 通过 authorize_router_owned_capability() 回验后立即消费，任何
  // 失败路径都会由外层 facade 清空，避免旧句柄跨生命周期重放。
  protected uvm_object m_router_owned_capability;
  protected rdma_host_mem_router m_router_owned_target;
  protected bit m_router_owned_attach;
  // Host reset 的 router-local epoch 预检和提交各使用一个一次性 capability；两次调用
  // 不能共用公开 allow_active bit，否则 legacy callback 可以伪装成 coordinator 内部 publication。
  protected uvm_object m_router_epoch_capability;
  protected rdma_host_mem_router m_router_epoch_target;
  protected int unsigned m_router_epoch_host;
  protected bit m_router_epoch_advance;

  // 功能：统一拒绝在 request_* 已经进入同步 publication 窗口后、仍试图改变
  //       coordinator owner/transaction/router/Function ledger 的 direct mutation。
  // 输入/输出及副作用：operation_name（输入）用于构造可定位诊断；allow_active（输入）仅
  //       允许 coordinator 已完成 owner/token 校验的内部 publication seam 继续执行；函数只读
  //       m_reset_operation_active，不修改 lease、transaction、router 或 epoch 账本。
  // 失败/边界：guard active 且未声明 allow_active 时返回 RESOURCE_BUSY；guard 未 active 或
  //       合法内部 publication 明确 allow_active 时返回 OK。该检查只覆盖同步 function call
  //       stack，不提供跨线程、跨进程或仿真调度级互斥。
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

  // 功能：校验 coordinator 可变操作的 lease owner/token，并统一处理 legacy 无 owner
  //       调用与已被 env 独占的 coordinator。
  // 输入/输出及副作用：owner/token（输入）描述调用方 lease；require_active（输入）要求
  //       当前 reset transaction 已由同一 owner 开启；allow_active（输入）仅供 reset epoch
  //       publication/end seam 在 active transaction 内继续执行；函数只读 lease 字段，不修改 ledger。
  // 失败/边界：未持有 lease 时仅接受 owner=null/token=0 的兼容调用；已持有 lease 时
  //       owner/token 不匹配返回 RESOURCE_BUSY，要求 active 但尚未 begin 返回 INVALID_STATE；
  //       reset active 下的无 token 调用一律拒绝，防止 callback 直接重入 coordinator。
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

  // 功能：取得 coordinator reset publication 的同步执行槽，阻止同一调用栈通过 callback
  //       重新进入另一个 request_* reset scope，避免 staged epoch 在外层 scope 尚未提交时
  //       被嵌套修改。
  // 输入/输出及副作用：无输入；成功时只设置 m_reset_operation_active 并返回 OK，失败时
  //   保持标志不变并返回 RESOURCE_BUSY；不读取或修改 Function/Host/Device ledger。
  // 失败/边界：已有 request_* wrapper 尚未退出时再次进入返回 RESOURCE_BUSY；该 guard 只覆盖
  //   同步 function call stack，不提供跨线程、跨进程或仿真调度级互斥，lease 仍是 owner authority。
  protected function rdma_status enter_reset_operation();
    if (m_reset_operation_active)
      return rdma_status::make(
        RDMA_SC_RESOURCE_BUSY,
        "coordinator reset publication is already active"
      );
    m_reset_operation_active = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：结束当前 request_* wrapper 的同步 publication 窗口，释放嵌套 reset guard。
  // 输入/输出及副作用：无输入；只清除 m_reset_operation_active，不回滚已经提交的 epoch、
  //   registration 或 router 状态；调用方必须在 impl 返回后无条件调用本函数。
  // 失败/边界：重复清除是幂等的；若 impl 通过 fatal 终止仿真，无法观察清理结果，正常
  //   status/null 返回路径均由 public wrapper 负责执行该清理。
  protected function void leave_reset_operation();
    m_reset_operation_active = 1'b0;
  endfunction

  // 功能：在 reset_* implementation 返回后统一释放同步 guard，并把 null status 规范化为
  //       可定位的 INVALID_STATE，供四个 public reset wrapper 共享。
  // 输入/输出及副作用：status、label（输入）；无论 status 成功、失败或为 null 都先清除
  //   m_reset_operation_active，再返回原 status 或新建错误；不修改任何 reset ledger。
  // 失败/边界：implementation 返回 null 表示内部契约违例，调用方只能观察失败状态；清理
  //   本身无失败返回，避免 null/异常路径把 coordinator 永久锁在 active 状态。
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

  // 功能：集中解析一个已登记 Function 的当前有效 incarnation，统一处理 registration
  // baseline、绝对 reset counter 与 generation/reset_epoch 的加法边界。
  // 输入/输出及副作用：name（输入）选择 coordinator-owned ledger 条目；registered（输出）
  //   返回非拥有 registration snapshot，registration_epoch/applied_resets 返回 baseline 和
  //   已应用 reset 数，current_generation/current_epoch 返回推导后的当前值；函数只读所有
  //   ledger，不修改 router、identity 或 epoch。
  // 失败/边界：条目缺失/null、baseline 大于绝对 counter、identity 校验失败或加法会超过
  //   generation/epoch 表示范围时返回非空错误，所有输出保持安全零值；调用方不得把失败
  //   当成“当前 incarnation 为零”继续提交。
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

  // 功能：在 reset scope 尚未产生任何副作用前，检查一个 Function 是否还能安全发布下一代
  //   incarnation，并确认 absolute epoch counter 自身不会回绕。
  // 输入/输出及副作用：name（输入）选择已登记 Function；函数只读 registration baseline、
  //   Function epoch 和 generation，返回 OK 或 RESOURCE_EXHAUSTED/账本错误，不修改任何
  //   context、router 或 epoch。
  // 失败/边界：条目缺失、baseline 不一致、当前 generation/reset_epoch 已达最大值，或内部
  //   absolute counter 已达最大值时拒绝；调用方必须对整个 scope 逐项完成该检查后才能调用
  //   prepare_function_epoch_commit()，以避免先 bump 部分 Function 再在后续条目溢出。
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

  // 功能：为一个已经完成 scope 选择的 Function 名称队列构造 detached epoch map，先验证
  //       每个条目的登记/容量，再把所有下一值写入局部 map，供 reset 事务在最后一步整体替换。
  // 输入/输出及副作用：function_names（输入）列出本次要 bump 的 stable key；staged_epochs（输出）
  //   获得 m_function_epochs 的独立 staged 值图；函数只读当前 ledger，不修改 coordinator、
  //   Host router 或外部 identity。
  // 失败/边界：名称重复、条目缺失/null、容量预检失败、当前 counter 已达最大值或内部校验返回
  //   null 时返回错误且 staged map 不得被调用方提交；成功后调用方只能在其它 scope 预检均通过时
  //   一次性赋值 m_function_epochs，避免逐条 bump 造成部分提交。
  protected function rdma_status prepare_function_epoch_commit(
    string function_names[$],
    output rdma_reset_epoch_t staged_epochs[string]
  );
    string name;
    bit seen[string];
    rdma_status status;
    rdma_reset_epoch_t current_epoch;

    staged_epochs = m_function_epochs;
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
      current_epoch = staged_epochs.exists(name) ? staged_epochs[name] : 0;
      if (current_epoch == 64'hffff_ffff_ffff_ffff)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function epoch staging counter is exhausted"
        );
      staged_epochs[name] = current_epoch + 1;
    end
    return rdma_status::success();
  endfunction

  // 功能：初始化设备级 epoch 为零并建立空的 Function/Host ledger。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
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

  // 功能：为一个 device env 建立 coordinator 的唯一 ownership lease，返回本次生命周期
  //       使用的不可复用 token。
  // 输入/输出及副作用：owner（输入）为持有 env 的非拥有 UVM 对象；token（输出）获得新
  //       token；成功时 coordinator 记录 owner/token，但不修改 Function/Host/Device epoch。
  // 失败/边界：owner=null、已有 owner lease、legacy router 仍绑定、token counter 耗尽或
  //       reset transaction 活跃时返回 INVALID_ARGUMENT、RESOURCE_BUSY 或
  //       RESOURCE_EXHAUSTED；拒绝路径保持旧 lease、router 和 ledger 不变。legacy attach
  //       没有 owner handoff capability，因此不能被新 lease 静默接管。
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

  // 功能：结束一个已经完成的 reset transaction，并释放 env 对 coordinator 的 ownership
  //       lease，使后续 build/attach 方可以重新取得控制权。
  // 输入/输出及副作用：owner/token（输入）必须是 acquire_lease() 返回的当前 pair；成功时
  //       清除 owner/token 和 active 标志，不回退任何已发布 epoch。
  // 失败/边界：owner/token 不匹配返回 RESOURCE_BUSY；transaction 仍 active 或仍绑定 Host
  //       router 时拒绝释放，防止 callback/close 路径留下单侧 authority；未持有 lease 时返回
  //       INVALID_STATE，调用方必须先完成双侧 detach。成功释放同时清空该 leased env 的
  //       Function/Host/Device registration ledger，使 coordinator 不会把旧拓扑历史带入下一
  //       owner；lease token counter 保留单调性，防止旧 token 重放。
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
    // lease 生命周期结束即结束本次 env 的 registration scope。context 侧在调用 release
    // 前已完成 quarantine；因此清掉 coordinator-owned snapshot 和相对 epoch ledger 不会
    // 使仍在服务的 context 失去可见 authority，同时允许同一 coordinator 以不同拓扑复用。
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

  // 功能：为 env reset 入口取得 transaction lease 内的 active 标记，使 coordinator 只接受
  //       同一 owner/token 的 epoch publication，并拒绝同步 direct callback 重入。
  // 输入/输出及副作用：owner/token（输入）为当前 lease pair；成功时只设置 active 标志，不
  //       修改 epoch、identity 或 router；调用方必须在所有路径调用 end_reset()。
  // 失败/边界：未取得 lease、owner/token 过期或已有 active transaction 时返回 RESOURCE_BUSY；
  //       无 lease 的 legacy caller 不能伪造 begin，保持旧 request_* 兼容但没有跨 env ownership。
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

  // 功能：清除 begin_reset() 建立的 active transaction 标记，允许 release/build 路径在 reset
  //       完整提交或回滚后继续使用当前 lease。
  // 输入/输出及副作用：owner/token（输入）必须匹配当前 lease；成功时只清除 active 标志，不
  //       回滚 epoch/context/ledger；函数返回 status 供 env 保留原始 reset 诊断。
  // 失败/边界：owner/token 不匹配返回 RESOURCE_BUSY；没有 active transaction 时返回 INVALID_STATE，
  //       调用方不得把重复 end 当作成功释放。
  function rdma_status end_reset(
    uvm_object owner,
    longint unsigned token
  );
    rdma_status status;
    rdma_status publication_status;

    // end_reset() normally runs immediately after request_* returns, when the
    // wrapper has already released m_reset_operation_active.  It must not be
    // callable from a callback nested inside that wrapper: clearing the
    // transaction flag there would let the callback publish a second scope.
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

  // 功能：向 router/context 等非拥有组件公开只读 lease 授权检查，统一阻止无 token 的
  //       direct operation 绕过当前 env reset transaction；允许 coordinator 内部已授权的
  //       epoch publication seam 在 active transaction 中继续调用 router。
  // 输入/输出及副作用：owner/token（输入）和 require_active（输入）描述调用者授权；
  //       allow_active（输入）仅由已通过 coordinator 主入口的 publication seam 使用，返回
  //       status，不修改任何 coordinator ledger；仅用于边界检查，不返回 owner/token 内容。
  // 失败/边界：当前无 lease 时只接受 legacy null/0；当前有 lease 时错误 owner/token 返回
  //       RESOURCE_BUSY，要求 active 但 transaction 未开始返回 INVALID_STATE；active 期间
  //       未声明 allow_active 的 direct callback 仍返回 RESOURCE_BUSY。
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

  // 功能：报告 coordinator 当前是否已经被某个 device env 独占，供 router/configure 和
  //       生命周期诊断决定是否拒绝 detach/rebind。
  // 输入/输出及副作用：无参数；只读返回 lease owner 是否存在，不修改任何状态。
  // 失败/边界：尚未 acquire_lease() 时返回 0；owner 对象被释放的外部生命周期不由 coordinator
  //       自动检测，调用方必须显式 release_lease()。
  function bit lease_held();
    return m_lease_owner != null;
  endfunction

  // 功能：报告 coordinator 是否已经保存 Host-router 非拥有引用，供 device env build 在
  //       acquire lease 前拒绝复用仍绑定旧 router 的 coordinator。
  // 输入/输出及副作用：无参数；只读返回 m_host_router 是否存在，不修改 router、lease 或
  //   Function/epoch ledger。
  // 失败/边界：返回 1 只表示存在绑定，不代表 router 当前没有 active mapping；调用方仍须用
  //   detach_host_router_owned() 完成双侧 teardown，不能仅凭该查询强制替换旧 router。
  function bit host_router_bound();
    return m_host_router != null;
  endfunction

  // 功能：报告 coordinator reset transaction 是否处于 begin/end 之间，供同步 callback 和
  //       router 入口进行 fail-closed 拒绝。
  // 输入/输出及副作用：无参数；只读返回 active 标志，不修改 epoch、owner 或 context。
  // 失败/边界：active 标志只由 begin_reset()/end_reset() 维护；owner 丢失不会自动清理，需由
  //       生命周期错误处理路径显式恢复或隔离 coordinator。
  function bit reset_transaction_active();
    return m_reset_transaction_active;
  endfunction

  // 功能：为不携带 owner/token 的 Host-router dataplane 入口提供统一的 reset-admission
  //       查询；allocate/write/read 只能在 reset publication 与 transaction 均未 active
  //       时继续访问外部 manager，release/release_opaque 可声明 cleanup 语义以保留旧
  //       mapping 的 drain/rollback 路径。
  // 输入/输出及副作用：operation_name（输入）用于构造可定位的拒绝诊断；allow_cleanup
  //       （输入）仅表示调用方已经选择 stale-drain/rollback 清理语义；函数只读同步 guard
  //       与 transaction 标志，返回 rdma_status，不修改任何 coordinator ledger。
  // 失败/边界：publication guard 或 reset transaction active 且 allow_cleanup=0 时返回
  //       RESOURCE_BUSY；cleanup 调用在 active 窗口内返回 OK 以保持释放/回滚兼容；未绑定
  //       coordinator 或非 active 状态返回 OK。该 seam 只提供同步 reset-admission，不是
  //       跨线程、跨进程或仿真调度级锁，调用方仍须依赖 mapping authority 校验。
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

  // 功能：以一次性 capability 授权 router 完成 legacy coordinator facade 的同步 attach，
  //       把公开的 coordinator_initiated 标志变成不可猜测的双侧握手。
  // 输入/输出及副作用：router、capability（输入）必须是本 coordinator 在
  //       attach_host_router_status() 当前调用中暂存的对象；成功时消费 capability 和目标
  //       记录，但不修改 m_host_router、Function ledger 或 epoch。
  // 失败/边界：router/capability 为空、对象身份不匹配或 capability 已被消费时返回
  //       RESOURCE_BUSY；调用方不能重放旧句柄或把任意新 uvm_object 当作授权。
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

  // 功能：回验并一次性消费 leased Host-router attach/detach capability，确保 router 的
  //       owned seam 只能由本 coordinator 在当前 owner/token 事务中驱动。
  // 输入/输出及副作用：router、capability、attach_operation、owner、token（输入）；函数
  //       只读校验 lease、目标 router 与操作方向，成功时清空 coordinator 暂存 capability/
  //       target，不修改 m_host_router、router 或任何 epoch ledger。
  // 失败/边界：owner/token 不匹配、capability 为空或 stale、目标 router 不同、操作方向不符、
  //       capability 已消费或 coordinator 未持有 lease 时返回明确错误；失败不消费句柄，外层
  //       facade 必须在本次调用结束时清除暂存状态，调用方不得重放旧对象。
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

  // 功能：回验并一次性消费 Host router epoch publication capability，区分 coordinator
  //       request_host_reset() 的内部 capacity/advance seam 与 legacy callback 的同名公开入口。
  // 输入/输出及副作用：router、host_topology_key、advance_operation、capability、owner、token
  //      （输入）描述目标对象、操作方向和当前 lease；成功时只清空 coordinator 暂存 capability
  //       配对，不直接修改 router/local epoch 或 Function ledger。
  // 失败/边界：leased owner/token 不匹配或其 transaction 未 begin、目标 router/Host/方向不符、
  //       句柄为空或已消费时返回 RESOURCE_BUSY/INVALID_STATE；legacy 无 lease 的
  //       request_host_reset() 不建立 begin/end transaction，仍可在当前同步 capability 配对
  //       下成功。失败不消费句柄，外层 helper 必须在本次调用返回前清除暂存状态，调用方不得
  //       把 capability 当作可复用锁。
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

  // 功能：为 Host reset 的 router-local epoch capacity preflight 建立并消费一次性内部
  //       capability，确保 legacy 无 lease publication 也能与 direct callback 区分。
  // 输入/输出及副作用：host_topology_key、owner、token（输入）选择当前 router/lease；函数
  //       在同步调用中暂存 capability，调用 router 只读检查 local epoch capacity，返回 status；
  //       无论成功或失败都会清除暂存配对，不修改 coordinator Host/Function epoch。
  // 失败/边界：未绑定 router 时返回 OK 且不产生 router-local side effect（由调用方决定是否
  //       继续 coordinator-only reset）；capability 分配失败、router 返回 null/错误或 callback
  //       提前消费句柄时返回明确错误，拒绝路径不递增 local epoch，外层 reset scope 必须停止提交。
  protected function rdma_status validate_host_router_epoch_capacity(
    int unsigned host_topology_key,
    uvm_object owner,
    longint unsigned token
  );
    uvm_object capability;
    rdma_status status;

    if (m_host_router == null)
      return rdma_status::success();
    capability = rdma_reset_router_epoch_capability::type_id::create(
      "rdma_host_router_epoch_capacity_capability"
    );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host router epoch capacity capability allocation failed"
      );
    m_router_epoch_capability = capability;
    m_router_epoch_target = m_host_router;
    m_router_epoch_host = host_topology_key;
    m_router_epoch_advance = 1'b0;
    status = m_host_router.validate_host_epoch_capacity(
      host_topology_key, owner, token, capability
    );
    m_router_epoch_capability = null;
    m_router_epoch_target = null;
    m_router_epoch_host = 0;
    m_router_epoch_advance = 1'b0;
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host router epoch capacity validation returned null"
      );
    return status;
  endfunction

  // 功能：为 Host reset 的 router-local epoch commit 建立并消费 advance capability，在
  //       capacity 已预检后递增目标 router 的 local epoch。
  // 输入/输出及副作用：host_topology_key、owner、token（输入）选择当前 router/lease；函数
  //       暂存一次性 capability 并调用 router advance seam，成功时只改变 router-local epoch；
  //       coordinator Host/Function map 仍由 request_host_reset_impl() 随后整体提交。
  // 失败/边界：router 缺失时返回 OK 且不改变 coordinator 或 router ledger；capability 分配
  //       失败、目标/方向/lease 校验失败或 router 返回 null/错误时保持 coordinator ledger
  //       不变；暂存 capability 在所有返回路径清除。
  protected function rdma_status advance_host_router_epoch(
    int unsigned host_topology_key,
    uvm_object owner,
    longint unsigned token
  );
    uvm_object capability;
    rdma_status status;

    if (m_host_router == null)
      return rdma_status::success();
    capability = rdma_reset_router_epoch_capability::type_id::create(
      "rdma_host_router_epoch_advance_capability"
    );
    if (capability == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Host router epoch advance capability allocation failed"
      );
    m_router_epoch_capability = capability;
    m_router_epoch_target = m_host_router;
    m_router_epoch_host = host_topology_key;
    m_router_epoch_advance = 1'b1;
    status = m_host_router.advance_host_epoch(
      host_topology_key, owner, token, capability
    );
    m_router_epoch_capability = null;
    m_router_epoch_target = null;
    m_router_epoch_host = 0;
    m_router_epoch_advance = 1'b0;
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Host router epoch advance returned null"
      );
    return status;
  endfunction

  // 功能：通过 coordinator 自有的一次性 capability 把 Host router 连接到本 coordinator，
  //       使 Host reset 同时推进 router 的本地 epoch。
  // 输入/输出及副作用：router（输入）；status seam 成功后保存 router 非拥有引用并返回
  //   可观察结果；不修改 Function/Host/Device epoch，也不接管 router 所有权。
  // 失败/边界：router 为空、已有 lease/active transaction、旧 router 不同或 router 状态拒绝
  //   时返回错误且双侧绑定保持不变；capability 只在本次同步调用内有效。
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
    // Router consumes a valid capability before publishing m_reset.  Clear any
    // unconsumed pair on a rejection so a later caller cannot replay it.
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

  // 功能：保留旧 void attach 入口并转发到 capability-protected status facade，避免兼容
  //       caller 静默改写 coordinator/router 任一侧的绑定。
  // 输入/输出及副作用：router（输入）；成功时建立双侧 legacy attach，失败时保持旧引用，
  //   void wrapper 不吞掉任何副作用。
  // 失败/边界：router=null、coordinator 已 leased/active、跨 router replacement 或 router
  //   active mapping 均由 status facade 拒绝；需要错误码的调用方应直接使用 status 入口。
  function void attach_host_router(rdma_host_mem_router router);
    void'(attach_host_router_status(router));
  endfunction

  // 功能：在指定 owner lease 下绑定 Host router，供 device env 在 registration commit 前发布
  //       唯一 router/coordinator 关系。
  // 输入/输出及副作用：router、owner、token（输入）；成功时保存 router 非拥有引用并调用
  //       router 的 coordinator attach；不修改 Function/epoch ledger。
  // 失败/边界：router=null、owner/token 不匹配、reset transaction active 或 router attach 失败
  //       返回明确错误；失败路径保持旧 router 引用不变。
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
    // Router consumes a valid capability before publishing m_reset.  Clear any
    // unconsumed pair on rejection so a later caller cannot replay it.
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

  // 功能：在当前 ownership lease 下与 Host router 完成双侧 detach，结束 coordinator 与
  //       router 的一对一生命周期绑定，供 device env close/teardown 使用。
  // 输入/输出及副作用：router、owner、token（输入）；成功时先由 router 清除自身绑定，再
  //   清除 m_host_router 非拥有引用，不修改 Function/Host/Device epoch 或 mapping 数据。
  // 失败/边界：router 为空、owner/token 不匹配、transaction active、router 不是当前绑定或
  //   仍有 active mapping 时返回错误；任一失败路径保留 coordinator/router 双侧旧绑定。
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
    // m_host_router 为空时不能把任意 router 当作已经完成 detach。
    // 若这里直接返回 success，foreign coordinator 可以对仍绑定本 coordinator
    // 的 router 伪造双侧 teardown，随后释放自己的 lease，而真实反向引用仍存活。
    // 先要求 coordinator 侧记录与调用参数同一对象；未绑定或绑定到其它
    // coordinator 的 router 不能取得 detach capability，随后仍需通过 router
    // 自身的 capability 回验才能清除反向引用。
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
    // Router consumes a valid capability before clearing m_reset.  Clear any
    // unconsumed pair on rejection so a later caller cannot replay it.
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

  // 功能：在不触碰现有 Host router 或 Function ledger 的前提下，预检并一次性提交
  //       一组 Function identity 注册，使 device env 可以把多 Function 构建作为单一事务发布。
  // 输入/输出及副作用：router（输入，非 null 时替换待绑定的非拥有 Host router）和 identities
  //   （输入）描述待登记的 identity 集合；函数先在局部 ledger 中复制已有条目并 clone 全部
  //   新 incarnation，全部成功后才绑定 router、替换 m_host_router/m_functions，并返回状态。
  //   router 为 null 且已有 Host router 为空时表示“只提交 Function ledger”，供兼容的
  //   register_function() 使用；已有 router 非空时 null router 保持该引用不变。
  // 失败/边界：identity 为 null、同一批次出现重复稳定 key、不同 route 复用 UID/global-ID、
  //   已有 incarnation 回退或任一 clone/cast 失败时返回明确错误；失败路径不修改本
  //   coordinator 的 router、Function ledger 或 epoch 账本，也不会回滚/接管外部 router 所有权。
  function rdma_status commit_registration_atomic(
    rdma_host_mem_router router,
    rdma_function_identity identities[$],
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_function_identity staged_functions[string];
    rdma_reset_epoch_t staged_registration_epochs[string];
    rdma_function_identity snapshot;
    uvm_object cloned_object;
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
        // 单个 register_function() 的重复调用仍在下方保留幂等语义；同一批次
        // 的重复 stable key 则一律拒绝，避免输入顺序决定最终 incarnation。
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

      // UID/global-ID 是 dpu_common 的全局 Function authority；同一 route 的
      // incarnation 可沿用它们，但另一个 route 不得借用旧 Function 的编号。
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
        // 允许把 context 已发布的当前 incarnation 重新登记为新的 baseline；
        // 只有与 coordinator 推导值完全相同才接受。向前跳跃会掩盖漏掉的 reset
        // publication，不能把外部输入直接当成已提交的历史。只有在该 snapshot
        // 发布后尚未应用任何 reset 时，完全相同的值才走旧 API 的幂等快路径；
        // reset 后即使输入仍等于旧 snapshot，也必须先经过 current-incarnation
        // 比较，避免 stale registration 被静默接受。
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

    // 到这里所有 identity clone/cast/冲突校验均已完成；router attach 仍可能因 active
    // mapping 或 foreign lease 拒绝，因此必须先观察 status，只有 attach 成功后才替换
    // coordinator 的非拥有 router 引用，避免 registration ledger 与 router authority 分叉。
    if (router != null) begin
      if (m_lease_owner != null)
        lease_status = attach_host_router_owned(
          router, owner, lease_token
        );
      else
        // legacy registration 也必须经 coordinator facade 取得一次性 capability；
        // 直接把 coordinator_initiated bit 传给 router 会留下单侧 split-brain。
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

  // 功能：登记一个 Function 的不可变身份快照；重复 incarnation 不重复登记，调用方
  //       后续修改原 identity 不会影响 reset 级联范围。
  // 输入/输出及副作用：identity（输入）；按完整 key 克隆并保存不可变快照，供后续 reset 范围和
  //   epoch 查询；相同 incarnation 重复登记时不新增条目。
  // 失败/边界：传入 null 直接忽略；commit_registration_atomic() 返回的任一拒绝（包括
  //       lease/publication guard、身份校验、重复 key 或 clone 失败）均由兼容 void wrapper
  //       转为 uvm_fatal，调用方若需可恢复 status 必须直接调用 status API。
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
  // 功能：按稳定 Function UID 查询当前有效 reset epoch；结果把 registration snapshot
  // 的非零 reset_epoch baseline 与其后的已发布 reset 数相加，而不是泄露 coordinator
  // 内部的绝对 counter。
  // 输入/输出及副作用：uid（输入）；只读扫描已登记 identity 并解析其 baseline，返回当前
  //   Function incarnation 的 reset_epoch；未登记、ledger 损坏或加法溢出时返回 0。
  // 失败/边界：uid 为 0、重复 UID、未知条目或 baseline 不一致均不创建条目；返回 0 是
  //   未登记/损坏哨兵，调用方若需诊断必须使用 validate_registered_identity()。
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

  // 功能：按 Function handle 与完整 Host/root/segment/BDF route 校验请求是否对应
  //       coordinator 当前登记的唯一 Function incarnation，并返回该 incarnation 的
  //       canonical reset epoch；该 seam 让 Host router 不再把未知 UID 的零值哨兵误认为
  //       合法的初始 epoch=0。
  // 输入/输出及副作用：function_h、route、allow_stale_generation（输入）描述调用方携带的
  //       Function authority、fabric route 及是否处于 reset drain；current_epoch（输出）在成功
  //       时获得 registration baseline 加已发布 Function reset 的当前值；函数只读
  //       m_functions/epoch ledger，不修改 identity、router 或任何 reset 状态。
  // 失败/边界：null/错误 kind/非法 route 返回 INVALID_ARGUMENT 或 DMA_TRANSLATION；未知 UID、
  //       重复 UID、缺失/损坏 registration 返回 INVALID_STATE；UID 已知但 global ID、route
  //       不一致返回 DMA_TRANSLATION；generation 不一致仅在 allow_stale_generation=0 时返回
  //       STALE_GENERATION。所有拒绝路径将 current_epoch 保持为零，调用方不得继续分配或把
  //       零解释为合法 authority；drain 允许旧 generation 通过，但仍严格检查 UID、对象 ID 和 route。
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

  // 功能：校验一个 Function handle 与 route 是否对应当前登记 incarnation，并返回
  //       canonical reset epoch；这是普通 allocation/read/write 入口使用的严格 authority seam。
  // 输入/输出及副作用：function_h、route（输入）描述完整 Function 与 fabric route；current_epoch
  //   （输出）获得当前 Function epoch；只读 coordinator ledger，不修改任何状态。
  // 失败/边界：未知 UID、global ID/route/generation 漂移、重复或损坏 registration 均返回明确
  //   错误；成功返回 epoch=0 仍表示已登记的初始 incarnation，不等同于未知 UID。
  function rdma_status validate_registered_function_handle(
    rdma_function_handle function_h,
    rdma_route_key_t route,
    output rdma_reset_epoch_t current_epoch
  );
    return validate_registered_function_handle_internal(
      function_h, route, 1'b0, current_epoch
    );
  endfunction

  // 功能：在 reset drain 释放旧 mapping 时校验其 UID、global ID 和完整 route，并返回当前
  //       Function epoch；允许旧 generation 通过，以保留失效资源的可控清理出口。
  // 输入/输出及副作用：function_h、route（输入）和 current_epoch（输出）同严格 seam；函数只读
  //   registration/epoch ledger，不释放 mapping 或修改 coordinator 状态。
  // 失败/边界：未知/重复 UID、global ID 或 route 被篡改、registration 损坏仍 fail-closed；仅
  //   generation 可在旧 incarnation drain 中落后，调用方不得把该 seam 用于新 allocation。
  function rdma_status validate_registered_function_handle_for_drain(
    rdma_function_handle function_h,
    rdma_route_key_t route,
    output rdma_reset_epoch_t current_epoch
  );
    return validate_registered_function_handle_internal(
      function_h, route, 1'b1, current_epoch
    );
  endfunction

  // 功能：执行 VF FLR，仅为目标 VF 构造并整体提交一个新的 Function epoch，不影响 PF、其他
  //       VF 或 Host。
  // 输入/输出及副作用：identity（输入）；先只读校验完整 Function key、UID、generation 和
  //   reset_epoch 是否对应当前登记 incarnation，再在 detached map 中递增目标 VF 的局部 epoch；
  //   成功后一次性替换 Function ledger，PF、其他 VF、Host epoch 均不变。
  // 失败/边界：null/非 VF 返回 INVALID_ARGUMENT；未知 Function、generation/reset_epoch 过期或
  //   当前 generation/epoch 已耗尽返回对应错误，任何拒绝均不创建 Function epoch 或修改 Host router。
  protected function rdma_status request_vf_flr_impl(
    rdma_function_identity identity,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_t staged_epochs[string];
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
    status = prepare_function_epoch_commit(function_names, staged_epochs);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Function epoch staging returned null"
        ) : status;
    m_function_epochs = staged_epochs;
    return rdma_status::success();
  endfunction
  // 功能：执行 PF reset，收集目标 PF 及其同 Host、同 root、同 parent BDF 的所有 VF，并整体
  //       提交它们的下一代 Function epoch。
  // 输入/输出及副作用：identity（输入）；先只读校验目标 PF 的完整登记 incarnation，再扫描同
  //   Host/root 的 PF/后代 VF，在 detached map 中构造递增结果；成功后一次性替换 Function
  //   ledger，所有值均使用 coordinator 已拥有的 snapshot。
  // 失败/边界：null/非 PF 返回 INVALID_ARGUMENT；未知 PF、generation/reset_epoch 过期、scope
  //   中任一 Function 耗尽或账本损坏返回错误；所有目标 capacity 预检完成前不触碰任何 epoch。
  protected function rdma_status request_pf_reset_impl(
    rdma_function_identity identity,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_t staged_epochs[string];
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
    status = prepare_function_epoch_commit(function_names, staged_epochs);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "PF reset scope epoch staging returned null"
        ) : status;
    m_function_epochs = staged_epochs;
    return rdma_status::success();
  endfunction
  // 功能：推进指定 Host epoch，并对该 Host 上登记的全部 Function 构造一次性级联 bump。
  // 输入/输出及副作用：host_topology_key（输入）；先只读确认该 Host 至少拥有一个完整登记的
  //   Function，预检 coordinator/router capacity，再 staged Function map；router-local epoch
  //   成功推进后才同时发布 coordinator Host epoch 与 Function map。
  // 失败/边界：未登记 Host、Host epoch 已耗尽、scope 中任一 Function 耗尽或账本损坏返回
  //   INVALID_STATE/RESOURCE_EXHAUSTED，且在所有 capacity 预检完成前不创建 Host epoch、不调用
  //   router；router advance 拒绝时 coordinator 的 Host/Function map 保持旧值。
  protected function rdma_status request_host_reset_impl(
    int unsigned host_topology_key,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_t staged_epochs[string];
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
      status = validate_host_router_epoch_capacity(
        host_topology_key, owner, lease_token
      );
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
    status = prepare_function_epoch_commit(function_names, staged_epochs);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Host reset scope epoch staging returned null"
        ) : status;

    // Router-local advance is the only external side effect in this scope.  All local
    // maps are staged first; a rejected router advance therefore leaves coordinator
    // Host/Function epochs untouched.
    if (m_host_router != null) begin
      router_status = advance_host_router_epoch(
        host_topology_key, owner, lease_token
      );
      if (router_status == null || !router_status.ok())
        return router_status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Host router epoch advance returned null"
          ) : router_status;
    end
    m_host_epochs[host_topology_key] = m_host_epochs.exists(host_topology_key) ?
                                       m_host_epochs[host_topology_key] + 1 : 1;
    m_function_epochs = staged_epochs;
    return rdma_status::success();
  endfunction
  // 功能：推进全局 Device epoch，并使所有已登记 Function 的 DMA 身份通过同一 staged map 同时失效。
  // 输入/输出及副作用：无参数；先构造所有 Function 的下一 epoch，成功后递增全局 Device epoch
  //   并整体替换 Function map。
  // 失败/边界：Device epoch 已耗尽、ledger 含 null snapshot 或任一 Function generation/epoch
  //   已耗尽时返回错误；所有 Function capacity 预检完成前不递增 Device/Function epoch。
  protected function rdma_status request_device_reset_impl(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_reset_epoch_t staged_epochs[string];
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
    status = prepare_function_epoch_commit(function_names, staged_epochs);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Device reset scope epoch staging returned null"
        ) : status;
    m_device_epoch++;
    m_function_epochs = staged_epochs;
    return rdma_status::success();
  endfunction

  // 功能：执行 VF FLR 的公开 reset 入口，并在整个同步 publication 窗口内安装重入屏障。
  // 输入/输出及副作用：identity、owner、lease_token（输入）转发给 VF implementation；成功
  //   时只推进目标 Function epoch，返回 status；wrapper 退出前必定释放同步 guard。
  // 失败/边界：同一调用栈已有 reset publication 时返回 RESOURCE_BUSY；implementation 返回
  //   null 时转为 INVALID_STATE；owner/token、identity 或容量校验失败均保持原 ledger 不变。
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

  // 功能：执行 PF reset 的公开入口，并把同 Host/root 的 Function scope 扫描和 staged epoch
  //       commit 包在不可嵌套的同步 publication 窗口内。
  // 输入/输出及副作用：identity、owner、lease_token（输入）转发给 PF implementation；成功
  //   时整体推进目标 PF 及后代 VF，返回 status；不拥有调用方 identity 或 router。
  // 失败/边界：嵌套 reset publication 返回 RESOURCE_BUSY；implementation 的 null/错误 status
  //   由 wrapper 规范化，任何 scope 预检失败都不得留下部分 Function epoch bump。
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

  // 功能：执行 Host reset 的公开入口，并在 router-local epoch publication 与 coordinator
  //       Function map commit 期间拒绝 callback 重新进入另一 reset scope。
  // 输入/输出及副作用：host_topology_key、owner、lease_token（输入）转发给 Host implementation；
  //   成功时推进该 Host 的独立 epoch及其 Function incarnation，返回 status。
  // 失败/边界：同步嵌套调用返回 RESOURCE_BUSY；router capacity、scope、lease 或 staged map
  //   失败保持旧 ledger；任何 implementation null status 均转为 INVALID_STATE 并释放 guard。
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

  // 功能：执行 Device reset 的公开入口，并把全 Function staged epoch 与 Device epoch 的
  //       发布包在单一同步 publication 窗口内，阻止 callback 嵌套改变全局 scope。
  // 输入/输出及副作用：owner、lease_token（输入）转发给 Device implementation；成功时递增
  //   Device epoch 并整体替换 Function epoch map，返回 status；不接管外部 context 资源。
  // 失败/边界：已有同步 publication 时返回 RESOURCE_BUSY；Device/Function capacity 或 lease
  //   预检失败保持旧值；implementation 返回 null 时清理 guard 后报告 INVALID_STATE。
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

  // 功能：按完整 identity key 查询该 Function 的当前有效 reset epoch；把 registration
  // snapshot 的 baseline 与之后的 reset 数合成为对外 incarnation 值。
  // 输入/输出及副作用：identity（输入）；按完整 key 读取登记条目并解析 baseline，返回当前
  //   reset_epoch；null、未登记或 ledger 加法失败时返回 0，不修改任何 epoch 计数。
  // 失败/边界：调用方需要区分合法 epoch=0 与损坏哨兵时，应先调用
  //   validate_registered_identity() 获得详细 status。
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
  // 失败/边界：null/identity.validate 失败、未知完整 key、registration baseline 不一致或
  //   generation/reset_epoch 加法溢出返回对应错误；UID、global ID 或当前 incarnation 不一致
  //   返回 STALE_GENERATION，调用方不得继续 reset。
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
    identity_status = identity.validate();
    if (identity_status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
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
  //       epoch，而不提前修改 coordinator ledger；预览值基于 registration snapshot 的
  //       有效 reset_epoch，而不是内部绝对 counter。
  // 输入/输出及副作用：identity（输入）必须是当前 context 的 immutable incarnation；
  //   next_epoch（输出）返回当前有效 Function epoch 加一；函数只读验证 registration ledger，
  //   不触碰 Host router、任何 epoch map 或 identity snapshot。
  // 失败/边界：identity 为空、validator 返回 null、完整 route 未登记、generation/reset_epoch
  //   过期、registration ledger 不一致或当前 epoch 已达最大值时返回对应错误，并将 next_epoch
  //   保持为 0；成功后调用方必须在 coordinator epoch commit 前完成所有 context candidate 准备。
  function rdma_status preview_next_function_epoch(
    rdma_function_identity identity,
    output rdma_reset_epoch_t next_epoch
  );
    rdma_status status;
    rdma_reset_epoch_t current_epoch;

    next_epoch = 0;
    status = validate_registered_identity(identity);
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
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

  // 功能：统计指定 Host topology 下 coordinator ledger 中应参与 Host reset 的 Function 数量，
  //       供 device env 在 quiesce 后的跨 context 覆盖检查使用。
  // 输入/输出及副作用：host_topology_key（输入）；只读扫描完整 Function snapshot，返回匹配
  //   条目数，不创建 Host epoch 或修改任何 identity/router 状态。
  // 失败/边界：ledger 含 null snapshot 时跳过该条目并可能返回不完整计数；调用方应先通过
  //   validate_registered_host_scope() 确认 Host scope 合法，不能把部分结果当作空 scope 成功。
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
  // 失败/边界：identity 为空或非 PF 时返回 0；ledger 含 null snapshot 时跳过该条目并可能
  //   返回不完整计数。调用方必须先完成 validate_registered_identity() 与 scope 校验，0 只
  //   表示 scope 不可用于原子 reset。
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
