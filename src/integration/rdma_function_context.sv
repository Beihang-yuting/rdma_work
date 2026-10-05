// 目录：src/integration/，位于设备级环境与单 Function 数据面的连接层。
// 职责：绑定一个 dpu_common 投影 identity、资源快照、Host-memory/PCIe router，
//       并把该 Function 纳入统一 reset coordinator 的 epoch 账本。
// 依赖：rdma_types/adapter 契约、dpu_resource_snapshot 以及两个外部 router。
// 所有权与生命周期：传入快照、router 和可选 registry 由上层拥有；context 保存
//       非拥有引用，identity 保存注册时克隆，context 生命周期由调用方管理。

// Context 状态只描述 Function 级入口是否允许接收新事务；队列 runtime 的细粒度
// 状态仍由 rdma_queue_runtime 独占，避免在集成层复制 PI/CI 或 credit。
typedef enum bit [2:0] {
  RDMA_CONTEXT_DISCOVERED = 3'd0,
  RDMA_CONTEXT_ACTIVE = 3'd1,
  RDMA_CONTEXT_QUIESCING = 3'd2,
  RDMA_CONTEXT_QUARANTINED = 3'd3
} rdma_function_context_state_e;

// 设计说明：reset candidate 只拥有尚未发布的新 identity/binding 值图；它把
// 原 context 的句柄作为来源哨兵保存，供 commit_reset() 在同一 prepare/commit
// 事务内拒绝被外部替换的旧对象。candidate 不拥有 Host-memory、PCIe 或 queue
// 资源，事务失败时由调用方丢弃即可。
class rdma_function_reset_candidate extends uvm_object;
  `uvm_object_utils(rdma_function_reset_candidate)
  rdma_function_identity source_identity;
  rdma_function_binding source_binding;
  rdma_function_identity identity;
  rdma_function_binding binding;
  // prepare 阶段从 candidate.binding 取得的 detached identity；commit 阶段只读该值，
  // 不再调用会分配新对象的 identity_snapshot()。
  rdma_function_identity binding_identity_snapshot;
  rdma_function_context_state_e source_state;
  bit validation_complete;

  // 功能：构造一个尚未发布的 Function reset candidate，清空来源和新值句柄。
  // 输入/输出及副作用：name（输入）；初始化 candidate 的 UVM 名称、source_state、验证
  //   标志和五个 identity/binding 句柄，不修改任何 context 或外部资源所有权。
  // 失败/边界：candidate 仅作为 prepare 阶段暂存容器；identity/binding 为空时不能提交，
  //   调用方必须在 commit_reset() 前完成完整候选构造。
  function new(string name = "rdma_function_reset_candidate");
    super.new(name);
    source_identity = null;
    source_binding = null;
    identity = null;
    binding = null;
    binding_identity_snapshot = null;
    source_state = RDMA_CONTEXT_DISCOVERED;
    validation_complete = 1'b0;
  endfunction
endclass

class rdma_function_context extends uvm_object;
  `uvm_object_utils(rdma_function_context)
  rdma_function_identity identity;
  rdma_function_binding binding;
  dpu_resource_snapshot resources;
  rdma_resource_manager resource_manager;
  rdma_host_mem_router host_mem;
  rdma_pcie_router pcie;
  rdma_reset_coordinator reset_coordinator;
  rdma_function_context_state_e state;
  // 最近一次通过 validate_reset_candidate() 的候选句柄；commit seam 必须按对象身份
  // 复用这份记录，不能只伪造公开 validation_complete bit 跨 context 注入 candidate。
  protected rdma_function_reset_candidate m_validated_candidate;
  // 功能：构造尚未绑定依赖的 Function context；所有校验和引用绑定集中在 build()。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：构造过程不分配 Host-memory、PCIe endpoint 或 manager 资源；空 name 也必须得到可配置对象。
  function new(string name="rdma_function_context");
    super.new(name);
    state = RDMA_CONTEXT_DISCOVERED;
    m_validated_candidate = null;
  endfunction

  // 功能：统一校验 context 状态变更是否位于当前 coordinator 的合法 ownership/transaction
  //       边界内，供 activate、quiesce、rollback 和单 context commit 共用。
  // 输入/输出及副作用：owner/token（输入）描述可选 env lease；require_active（输入）要求
  //   有 token 的调用必须处于 begin_reset()/end_reset() 之间；require_lease（输入）要求
  //   coordinator 已被其它 env claim 时，不能再用无 token 的兼容入口改变 incarnation。
  //   函数只读 coordinator lease/transaction 状态，不修改 context、binding 或 ledger。
  // 失败/边界：无 coordinator 时只接受 null/0 并保留 standalone 兼容语义；部分 owner/token、
  //   错 owner/旧 token、active transaction 下的 tokenless callback，以及 strict lease 入口的
  //   tokenless 调用均返回 INVALID_ARGUMENT/RESOURCE_BUSY；coordinator 返回 null status 时
  //   转换为 INVALID_STATE，调用方不得继续状态或 authority assignment。
  protected function rdma_status authorize_context_mutation(
    uvm_object owner = null,
    longint unsigned token = 0,
    bit require_active = 1'b0,
    bit require_lease = 1'b0
  );
    rdma_status status;

    if ((owner == null) != (token == 0))
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "Function context owner/token pair is incomplete"
      );
    if (reset_coordinator == null) begin
      if (owner != null || token != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "Function context has no coordinator for supplied lease"
        );
      return rdma_status::success();
    end
    if (!reset_coordinator.lease_held()) begin
      if (owner != null || token != 0)
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "Function context coordinator has no active lease"
        );
      return rdma_status::success();
    end

    // activate/quiesce 的无 token 兼容调用仍可在 transaction 外运行（例如设备
    // build 后的初始 lifecycle）；一旦 outer reset 已 begin，任何同步 callback
    // 都必须携带同一 owner/token，避免越过 env 的 scope 选择与 fingerprint。
    if (owner == null && token == 0) begin
      if (require_lease || reset_coordinator.reset_transaction_active())
        return rdma_status::make(
          RDMA_SC_RESOURCE_BUSY,
          require_lease ?
            "Function context mutation requires the coordinator lease" :
            "Function context mutation is blocked during reset transaction"
        );
      return rdma_status::success();
    end
    // quiesce/rollback/owned commit 是 env 已经 begin_reset() 后的受控 seam，
    // 因而显式 allow_active；activate 或其它 transaction 外入口保持默认拒绝，
    // 防止任意 callback 借第四参数伪造 publication 权限。
    status = reset_coordinator.authorize_owned_operation(
      owner, token, require_active, require_active
    );
    if (status == null)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function context lease validation returned null status"
      );
    return status;
  endfunction

  // 功能：在不分配 status/factory 对象的提交边界，复核 candidate 与当前 context 的来源句柄、
  //       incarnation、binding identity 和 owner handle 值图是否仍一致。
  // 输入/输出及副作用：candidate（输入）只读；返回 bit，不修改 candidate、context 或外部账本，
  //   供 virtual validate 之后的 env seal 和 epoch 后 commit 共用同一纯检查。
  // 失败/边界：candidate/context 的 identity 或 binding 缺失、source identity/binding/state
  //   被替换、context 已隔离、candidate generation 未严格前进、reset_epoch 回退，或 identity
  //   snapshot/PCIe 镜像/owner handle 不匹配时返回 0；该 helper 不检查公开
  //   validation_complete 标志，调用方必须另行确认对象身份 marker，避免伪造 bit 绕过验证。
  protected function bit candidate_matches_context_noalloc(
    rdma_function_reset_candidate candidate
  );
    if (identity == null || binding == null ||
        candidate == null || candidate.identity == null ||
        candidate.binding == null || candidate.binding_identity_snapshot == null ||
        candidate.source_identity != identity ||
        candidate.source_binding != binding ||
        candidate.source_state != state ||
        state == RDMA_CONTEXT_QUARANTINED ||
        candidate.identity.generation <= identity.generation ||
        candidate.identity.reset_epoch < identity.reset_epoch ||
        !candidate.binding_identity_snapshot.same_incarnation(candidate.identity) ||
        !candidate.binding.matches_identity_snapshot(
          candidate.binding_identity_snapshot
        ) ||
        candidate.binding.owner_h == null ||
        !candidate.binding.accepts_noalloc(candidate.binding.owner_h))
      return 1'b0;
    return 1'b1;
  endfunction

  // 功能：把 virtual validate 之后仍未登记 marker 的 candidate 以非 virtual、无分配路径封存，
  //       使 device env 在 hostile callback 也能在 epoch publication 前建立唯一提交凭证。
  // 输入/输出及副作用：candidate（输入）；成功时设置 validation_complete 和当前 context 的
  //   m_validated_candidate，失败时保持旧 context/identity/binding 不变并返回 status。
  // 失败/边界：值图或来源句柄任一漂移返回 INVALID_STATE；该函数不调用 factory/clone，调用方
  //   必须在成功后立即完成 fingerprint verify，不能把 marker 当作跨 reset 生命周期的永久授权。
  function rdma_status seal_prevalidated_candidate(
    rdma_function_reset_candidate candidate
  );
    if (!candidate_matches_context_noalloc(candidate))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function reset candidate cannot be sealed"
      );
    candidate.validation_complete = 1'b1;
    m_validated_candidate = candidate;
    return rdma_status::success();
  endfunction

  // 功能：校验 identity/资源快照并构造单 Function context，同时创建或复用 reset
  //       coordinator、连接 Host router、登记 identity。返回错误时 result_context 为 null。
  // 输入/输出及副作用：source_identity/source_binding 被克隆到 result_context；resources、
  //   host_mem、pcie 和 registry 仅保存非拥有引用；coordinator 为空时创建新的 coordinator，
  //   并将 Host router/identity 登记其中。build_timeout 仅为兼容参数，不产生延迟。
  // 失败/边界：依赖为空、identity 无效（包括 validator 返回 null）、资源未冻结或克隆失败时返回错误且 result_context 为 null；
  //   不复制 registry 可变状态，也不取得外部 router/快照所有权。
  static function rdma_status build(
    rdma_function_identity source_identity,
    dpu_resource_snapshot source_resources,
    rdma_host_mem_router source_host_mem,
    rdma_pcie_router source_pcie,
    uvm_object registry,
    time build_timeout,
    output rdma_function_context result_context,
    input rdma_reset_coordinator coordinator = null,
    input rdma_function_binding source_binding = null
  );
    // 兼容入口保留历史参数顺序；实际构造统一走参数顺序稳定的共享实现。
    return build_shared(source_identity, source_resources, source_host_mem,
                        source_pcie, coordinator, source_binding, registry,
                        build_timeout, result_context);
  endfunction

  // 功能：使用显式的 coordinator 参数构造 Function context，供 device env
  //       在多 Function 拓扑中保证所有 context 共享同一 reset ledger。
  // 输入/输出及副作用：source_identity/source_binding 被克隆，resources、router、registry 仅
  //   以非拥有引用写入 result_context；默认会把 coordinator 连接到 Host router 并登记 identity，
  //   defer_coordinator_commit=1 时只把 coordinator 引用写入候选 context，注册副作用交给
  //   device env 的批量 commit。build_timeout 保留在 API 中但不会阻塞或调度事务。
  // 失败/边界：任一依赖校验、factory 分配、克隆、binding identity 不一致或候选
  //   binding 配置失败时返回错误，result_context 保持 null；defer_coordinator_commit=1
  //   时失败不会触碰共享 coordinator，默认模式则只在候选 context 完整后执行既有单 Function
  //   注册语义。
  static function rdma_status build_shared(
    rdma_function_identity source_identity,
    dpu_resource_snapshot source_resources,
    rdma_host_mem_router source_host_mem,
    rdma_pcie_router source_pcie,
    input rdma_reset_coordinator coordinator,
    input rdma_function_binding source_binding,
    input uvm_object registry,
    input time build_timeout,
    output rdma_function_context result_context,
    input bit defer_coordinator_commit = 1'b0
  );
    rdma_function_identity identity_copy;
    rdma_function_binding binding_copy;
    rdma_function_context candidate_context;
    rdma_resource_manager manager;
    rdma_function_identity binding_identity;
    rdma_status status;
    rdma_reset_coordinator selected_coordinator;
    rdma_function_identity identities[$];

    result_context = null;
    if (source_identity == null || source_resources == null ||
        source_host_mem == null || source_pcie == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "Function context dependency is null");
    status = source_identity.validate();
    if (status == null || !status.ok() || !source_resources.is_frozen())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context snapshot invalid");
    if (!rdma_deep_copy#(rdma_function_identity)::try_of(source_identity, identity_copy))
      return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                               "Function identity clone failed");

    if (source_binding != null) begin
      if (!rdma_deep_copy#(rdma_function_binding)::try_of(source_binding, binding_copy))
        return rdma_status::make(RDMA_SC_RESOURCE_EXHAUSTED,
                                 "Function binding clone failed");
      binding_identity = binding_copy.identity_snapshot();
      if (binding_identity == null)
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function binding identity snapshot is invalid"
        );
      status = binding_identity.validate();
      if (status == null || !status.ok())
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function binding identity validation failed"
        );
      if (!binding_identity.same_incarnation(identity_copy))
        return rdma_status::make(
          RDMA_SC_INVALID_ARGUMENT,
          "Function binding identity disagrees with context identity"
        );
    end
    else begin
      binding_copy = rdma_function_binding::type_id::create(
        "context_binding");
      if (binding_copy == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "Function context binding allocation failed"
        );
      status = rdma_status::nonnull(
        binding_copy.configure_identity(identity_copy),
        "Function context binding configuration returned null status"
      );
      if (!status.ok())
        return status;
    end

    candidate_context = rdma_function_context::type_id::create(
      "function_context");
    if (candidate_context == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function context allocation failed"
      );
    candidate_context.identity = identity_copy;
    candidate_context.binding = binding_copy;
    candidate_context.resources = source_resources;
    candidate_context.host_mem = source_host_mem;
    candidate_context.pcie = source_pcie;
    if ($cast(manager, registry))
      candidate_context.resource_manager = manager;
    selected_coordinator = coordinator;
    if (selected_coordinator == null)
      selected_coordinator = rdma_reset_coordinator::type_id::create(
        "function_context_reset_coordinator");
    if (selected_coordinator == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function context reset coordinator allocation failed"
      );

    // 所有候选对象均已分配后才触碰共享 coordinator；device env 的延迟模式把
    // attach/register 再推迟到整组 Function 都成功之后，避免后续 Function 失败
    // 时留下前面条目的半提交 ledger。
    if (!defer_coordinator_commit) begin
      identities.push_back(identity_copy);
      status = rdma_status::nonnull(
        selected_coordinator.commit_registration_atomic(
            source_host_mem, identities
          ),
        "Function context coordinator registration returned null status"
      );
      if (!status.ok())
        return status;
    end
    candidate_context.reset_coordinator = selected_coordinator;
    candidate_context.state = RDMA_CONTEXT_DISCOVERED;
    result_context = candidate_context;
    // build_timeout 保留在兼容签名中；context 构造不引入隐式延迟。
    return rdma_status::success();
  endfunction

  // 功能：允许已构造的 Function context 接收新的控制面/数据面事务，并在 outer reset
  //       transaction 已开始时要求调用者携带同一 coordinator lease。
  // 输入/输出及副作用：owner/token（输入）为可选 env lease；成功时先为当前 binding 创建
  //   新 owner handle，再把 DISCOVERED/QUIESCING context 与 binding 一起标记为 ACTIVE，不
  //   分配队列或 DMA 资源。无 token 的 standalone 或 transaction 外兼容调用只读 coordinator。
  // 失败/边界：QUARANTINED、identity validator 返回 null、binding 缺失、owner-handle factory
  //   返回 null，或 active transaction 中缺少/错误 lease 时拒绝激活且保留原 state/owner；
  //   ACTIVE 仅在已有 handle 仍接受当前 incarnation 时幂等成功。
  function rdma_status activate(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status identity_status;
    rdma_status lease_status;
    rdma_function_handle next_owner_h;

    lease_status = authorize_context_mutation(owner, lease_token, 1'b0, 1'b0);
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function context activation lease validation returned null"
        ) : lease_status;

    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context identity is invalid");
    identity_status = identity.validate();
    if (identity_status == null || !identity_status.ok())
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context identity is invalid");
    if (state == RDMA_CONTEXT_QUARANTINED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "quarantined Function context cannot activate");
    if (binding == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context binding is missing");
    if (state == RDMA_CONTEXT_ACTIVE) begin
      if (binding.owner_h == null || !binding.accepts(binding.owner_h))
        return rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "active Function context owner handle is invalid"
        );
      return rdma_status::success();
    end
    next_owner_h = binding.make_handle();
    if (next_owner_h == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "Function context owner handle allocation failed"
      );
    binding.owner_h = next_owner_h;
    binding.state = RDMA_BIND_ACTIVE;
    state = RDMA_CONTEXT_ACTIVE;
    return rdma_status::success();
  endfunction

  // 功能：停止该 Function 接收新事务，为 reset 或资源回收建立 quiesce 边界，并在 outer
  //       reset transaction 中把状态迁移绑定到同一 coordinator owner。
  // 输入/输出及副作用：owner/token（输入）为可选 env lease；ACTIVE context 转为 QUIESCING，
  //   重复调用幂等；不释放或修改外部资源。transaction 外无 token 的兼容调用只保留状态写入。
  // 失败/边界：active transaction 中的 tokenless/错误 lease、DISCOVERED/QUARANTINED context
  //   返回错误并保持状态；重复 quiesce 在授权通过后幂等成功。
  function rdma_status quiesce(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status lease_status;
    bit require_lease;

    // quiesce 改写入口状态；一旦 coordinator 已被 env claim，不能再把它当作
    // transaction 外的 legacy callback。未 claim 的 standalone/context-build fixture
    // 仍保留旧的 null/0 兼容语义。
    require_lease = reset_coordinator != null &&
                    reset_coordinator.lease_held();
    lease_status = authorize_context_mutation(
      owner, lease_token, 1'b1, require_lease
    );
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function context quiesce lease validation returned null"
        ) : lease_status;
    if (state == RDMA_CONTEXT_QUIESCING)
      return rdma_status::success();
    if (state != RDMA_CONTEXT_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context is not active");
    state = RDMA_CONTEXT_QUIESCING;
    return rdma_status::success();
  endfunction

  // 功能：在任何 context/epoch mutation 前构造一个完整的下一代 identity、binding 和 owner
  //       handle 候选，供 device env 对整个 reset scope 做 prepare。
  // 输入/输出及副作用：new_generation/new_epoch（输入）描述待发布 incarnation；candidate（输出）
  //   获得 detached identity/binding 值图和来源句柄；函数只调用 factory/clone，不改写当前
  //   identity、binding 或 state，也不取得外部资源所有权。
  // 失败/边界：generation 为零、identity/state 缺失、identity factory、binding clone/configure 或
  //   owner-handle factory 失败时返回明确 status、candidate 保持 null；调用方不得在失败后推进
  //   coordinator epoch，候选对象由调用方丢弃即可。
  virtual function rdma_status prepare_reset(
    int unsigned new_generation,
    rdma_reset_epoch_t new_epoch,
    output rdma_function_reset_candidate candidate
  );
    rdma_function_identity next_identity;
    rdma_function_binding next_binding;
    rdma_function_identity next_binding_identity;
    rdma_status status;

    candidate = null;
    if (new_generation == 0)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "new Function generation is zero");
    if (identity == null)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context identity is missing");
    if (state == RDMA_CONTEXT_QUARANTINED)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "quarantined Function context cannot reset");

    next_identity = rdma_function_identity::type_id::create(
      "reset_identity");
    if (next_identity == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "reset identity allocation failed"
      );
    status = rdma_status::nonnull(
      next_identity.configure(
        identity.key, identity.global_function_id, identity.function_uid,
        new_generation, new_epoch),
      "reset identity configuration returned null status"
    );
    if (!status.ok())
      return status;

    // 所有可能失败的 binding/owner factory 操作都落在 detached candidate 上；
    // 只有 prepare 完整成功，commit_reset() 才会交换 context 的两个 authority 句柄。
    if (binding == null) begin
      next_binding = rdma_function_binding::type_id::create("reset_binding");
      if (next_binding == null)
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "reset binding allocation failed"
        );
    end
    else begin
      if (!rdma_deep_copy#(rdma_function_binding)::try_of(binding, next_binding))
        return rdma_status::make(
          RDMA_SC_RESOURCE_EXHAUSTED,
          "reset binding clone failed"
        );
    end
    status = rdma_status::nonnull(
      next_binding.configure_identity(next_identity),
      "reset binding configuration returned null status"
    );
    if (!status.ok())
      return status;

    next_binding.owner_h = next_binding.make_handle();
    if (next_binding.owner_h == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "reset binding owner handle allocation failed"
      );
    next_binding.state = RDMA_BIND_ACTIVE;

    // 这是 prepare 阶段最后一个可能分配的 identity snapshot。commit 阶段必须只
    // 读取该 detached 值，避免 epoch 已发布后再进入 identity_snapshot() factory/分配路径。
    next_binding_identity = next_binding.identity_snapshot();
    if (next_binding_identity == null ||
        !next_binding_identity.same_incarnation(next_identity))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "reset binding identity snapshot is invalid"
      );

    candidate = rdma_function_reset_candidate::type_id::create(
      "reset_candidate");
    if (candidate == null)
      return rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "reset candidate allocation failed"
      );
    candidate.source_identity = identity;
    candidate.source_binding = binding;
    candidate.identity = next_identity;
    candidate.binding = next_binding;
    candidate.binding_identity_snapshot = next_binding_identity;
    candidate.source_state = state;
    candidate.validation_complete = 1'b0;
    return rdma_status::success();
  endfunction

  // 功能：在跨 context epoch commit 前验证 reset candidate 的来源句柄、identity 和 binding
  //       一致性，证明后续 commit_reset() 只会执行无分配字段交换。
  // 输入/输出及副作用：candidate（输入）必须由当前 context 的 prepare_reset() 生成；读取
  //   source_identity/source_binding、候选 validator 和 binding identity snapshot，并在成功时把
  //   validation_complete 置 1；不修改 context、coordinator 或外部资源。
  // 失败/边界：candidate 不完整、来源句柄已被替换、context 已隔离、候选 identity/binding 无效
  //   或 snapshot 不一致时返回错误并清除 validation_complete；调用方必须在任何 epoch bump
  //   前处理该错误，成功后不得再修改 candidate 值图。
  virtual function rdma_status validate_reset_candidate(
    rdma_function_reset_candidate candidate
  );
    rdma_status status;

    m_validated_candidate = null;
    if (candidate != null)
      candidate.validation_complete = 1'b0;

    if (candidate == null || candidate.identity == null ||
        candidate.binding == null ||
        candidate.binding_identity_snapshot == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT,
        "Function reset candidate is incomplete"
      );
    if (candidate.source_identity != identity ||
        candidate.source_binding != binding ||
        candidate.source_state != state)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function reset candidate source no longer matches context"
      );
    if (state == RDMA_CONTEXT_QUARANTINED)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "quarantined Function context cannot commit reset"
      );
    status = rdma_status::nonnull(
      candidate.identity.validate(),
      "Function reset candidate identity validation returned null"
    );
    if (!status.ok())
      return status;
    if (candidate.identity.generation <= identity.generation ||
        candidate.identity.reset_epoch < identity.reset_epoch)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function reset candidate does not advance the current incarnation"
      );
    if (!candidate.binding_identity_snapshot.same_incarnation(candidate.identity) ||
        !candidate.binding.matches_identity_snapshot(
          candidate.binding_identity_snapshot
        ))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function reset candidate binding identity disagrees"
      );

    if (candidate.binding.owner_h == null ||
        !candidate.binding.accepts(candidate.binding.owner_h))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function reset candidate owner handle is invalid"
      );

    candidate.validation_complete = 1'b1;
    m_validated_candidate = candidate;

    return rdma_status::success();
  endfunction

  // 功能：把 prepare_reset() 产生的 detached candidate 一次性发布到当前 context，完成
  //       identity/binding/state 的无分配 commit，并把该 mutation 绑定到 reset coordinator lease。
  // 输入/输出及副作用：candidate（输入）必须已经通过 validate_reset_candidate()；owner/token
  //   （输入）在已 claim coordinator 时必须是当前 active transaction 的 lease。成功时交换
  //   identity/binding，并把原来非 DISCOVERED 状态恢复为 ACTIVE；不调用 factory、不修改外部
  //   router/queue 资源，旧对象仅由 context 放弃引用。
  // 失败/边界：coordinator lease 存在时 tokenless direct commit、错误 owner/旧 token 或未 begin
  //   transaction 均返回 RESOURCE_BUSY/INVALID_STATE 并保持旧组合；candidate 校验失败同样拒绝。
  //   device env 应在 coordinator epoch commit 前验证全部 candidate，随后本函数只执行 assignment，
  //   因而不会留下可预见的跨 context 半提交。
  virtual function rdma_status commit_reset(
    rdma_function_reset_candidate candidate,
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status status;

    status = authorize_context_mutation(owner, lease_token, 1'b1, 1'b1);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function reset commit lease validation returned null status"
        ) : status;

    // device env 在 epoch 发布前已经完成 validate_reset_candidate()；保留一次兼容
    // fallback，让旧的单 context 调用者仍能直接 commit，但成功的批量路径不再重复
    // 任何 identity/binding snapshot 或 factory 操作。
    if (candidate == null || !candidate.validation_complete ||
        candidate !== m_validated_candidate) begin
      status = validate_reset_candidate(candidate);
      if (status == null || !status.ok())
        return status == null ?
          rdma_status::make(
            RDMA_SC_INVALID_STATE,
            "Function reset candidate validation returned null status"
          ) : status;
    end
    if (candidate == null || candidate.identity == null ||
        candidate.binding == null ||
        candidate.binding_identity_snapshot == null ||
        candidate.source_identity != identity ||
        candidate.source_binding != binding ||
        candidate.source_state != state ||
        !candidate_matches_context_noalloc(candidate))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function reset candidate changed before commit"
      );

    status = commit_reset_prevalidated_owned(candidate, owner, lease_token);
    return status == null ?
      rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "prevalidated Function reset commit returned null status"
      ) : status;
  endfunction

  // 功能：在 device env 已完成整组 candidate 验证且 coordinator epoch 已发布后，执行
  //       identity/binding/state 的不可失败字段交换，并确认调用者仍持有同一 reset lease。
  // 输入/输出及副作用：candidate（输入）必须是当前 context 通过
  //   validate_reset_candidate() 的 detached candidate；有 lease 时 owner/token 必须匹配当前
  //   active transaction，无 lease 的 standalone context 仅接受 null/0 兼容调用。授权通过后
  //   函数只写入三个 context 字段，不调用 factory、clone、identity_snapshot 或外部 ledger API。
  // 失败/边界：candidate 来源句柄、source_state、identity snapshot、owner handle 或 no-alloc
  //   镜像任一漂移、owner/token 失效或 active transaction 未开始时返回错误且不写入 context；
  //   调用方必须在 epoch 发布前完成同一授权预检，因为之后拒绝只能暴露不可回滚的生命周期破坏。
  function rdma_status commit_reset_prevalidated_owned(
    rdma_function_reset_candidate candidate,
    uvm_object owner,
    longint unsigned lease_token
  );
    rdma_status lease_status;

    lease_status = authorize_context_mutation(
      owner, lease_token, 1'b1, 1'b1
    );
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "prevalidated Function commit lease validation returned null status"
        ) : lease_status;
    if (candidate == null || candidate.identity == null ||
        candidate.binding == null || candidate.binding_identity_snapshot == null ||
        !candidate.validation_complete ||
        candidate !== m_validated_candidate ||
        candidate.source_identity != identity ||
        candidate.source_binding != binding ||
        candidate.source_state != state ||
        !candidate_matches_context_noalloc(candidate))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "prevalidated Function commit candidate changed before commit"
      );
    identity = candidate.identity;
    binding = candidate.binding;
    if (state != RDMA_CONTEXT_DISCOVERED)
      state = RDMA_CONTEXT_ACTIVE;
    m_validated_candidate = null;
    return rdma_status::success();
  endfunction

  // 功能：保留旧的无返回值 prevalidated commit 兼容入口，同时在 coordinator 已被 claim
  //       时拒绝无 token 的 direct context 绕过，并复核 candidate 的来源/值图后再交换字段。
  // 输入/输出及副作用：candidate（输入）在 standalone/no-lease context 中成功交换
  //   identity/binding/state；leased context 的 tokenless 调用只读授权并在拒绝时保持原值。
  // 失败/边界：candidate 缺失、validation flag/source/value graph/owner handle 任一不一致、
  //   active transaction 或 lease ownership 不匹配都 fail-closed；void API 无法携带 status，
  //   调用方需要详细诊断时必须改用 owned 入口。
  function void commit_reset_prevalidated(
    rdma_function_reset_candidate candidate
  );
    rdma_status lease_status;

    lease_status = authorize_context_mutation(null, 0, 1'b1, 1'b1);
    if (lease_status == null || !lease_status.ok())
      return;
    if (candidate == null || candidate.identity == null ||
        candidate.binding == null || candidate.binding_identity_snapshot == null ||
        !candidate.validation_complete ||
        candidate !== m_validated_candidate ||
        candidate.source_identity != identity ||
        candidate.source_binding != binding ||
        candidate.source_state != state ||
        !candidate_matches_context_noalloc(candidate))
      return;
    identity = candidate.identity;
    binding = candidate.binding;
    if (state != RDMA_CONTEXT_DISCOVERED)
      state = RDMA_CONTEXT_ACTIVE;
    m_validated_candidate = null;
  endfunction

  // 功能：兼容旧的单 context reset API，将 prepare_reset() 和 commit_reset() 串成一次局部事务。
  // 输入/输出及副作用：new_generation/new_epoch（输入）描述新 incarnation；成功时发布新的
  //   identity/binding 并恢复可用状态，失败时不改变旧 context；不推进任何 coordinator ledger。
  // 失败/边界：当 context 绑定的 coordinator 已被 device env claim ownership lease 时，
  //   无 token 的 direct reset 返回 RESOURCE_BUSY，避免 callback 在跨 context transaction 中
  //   绕过 coordinator epoch；没有 coordinator 的 standalone context 继续保留旧语义。其余
  //   prepare/commit 校验失败原样返回，且该 wrapper 不提供跨 context 原子性，批量 reset 必须
  //   由 device env 调用 prepare/commit seam。
  function rdma_status reset(
    int unsigned new_generation,
    rdma_reset_epoch_t new_epoch
  );
    rdma_function_reset_candidate candidate;
    rdma_status status;

    // device env 取得 coordinator ownership lease 后，context.reset() 不能以兼容
    // wrapper 身份直接交换 identity/binding；否则 coordinator 的 scope epoch 与
    // context incarnation 会脱节。传入 null/0 明确表示本调用没有 lease token，
    // coordinator 在无 lease 时仍允许 legacy/standalone context reset。
    if (reset_coordinator != null) begin
      status = reset_coordinator.authorize_owned_operation(null, 0, 1'b0);
      if (status == null)
        return rdma_status::make_direct(
          RDMA_SC_INVALID_STATE,
          "Function context direct reset lease validation returned null"
        );
      if (!status.ok())
        return status;
    end

    status = prepare_reset(new_generation, new_epoch, candidate);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function reset prepare returned null status"
        ) : status;
    status = validate_reset_candidate(candidate);
    if (status == null || !status.ok())
      return status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function reset candidate validation returned null status"
        ) : status;
    status = commit_reset(candidate);
    return status == null ?
      rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function reset commit returned null status"
      ) : status;
  endfunction

  // 功能：撤销本次 reset prepare 之前由 quiesce() 建立的入口屏障，恢复 context 原有 ACTIVE
  //       状态，并在 outer transaction 中验证相同 coordinator lease。
  // 输入/输出及副作用：owner/token（输入）为可选 env lease；仅把 QUIESCING context 的 state
  //   写回 ACTIVE，binding owner 和 identity 保持原句柄，不分配资源也不触碰 router。
  // 失败/边界：active transaction 中 tokenless/错误 lease、QUARANTINED、DISCOVERED 或缺失
  //   binding/owner 的 context 拒绝恢复；ACTIVE 状态在授权通过后幂等成功。
  function rdma_status restore_after_quiesce(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status lease_status;
    bit require_lease;

    // rollback 同样会把 QUIESCING 状态写回 ACTIVE；leased coordinator 下必须由
    // 同一 owner/token 执行，避免 foreign callback 在 scope 失败后私自恢复入口。
    require_lease = reset_coordinator != null &&
                    reset_coordinator.lease_held();
    lease_status = authorize_context_mutation(
      owner, lease_token, 1'b1, require_lease
    );
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function context quiesce restore lease validation returned null"
        ) : lease_status;
    if (state == RDMA_CONTEXT_ACTIVE)
      return rdma_status::success();
    if (state == RDMA_CONTEXT_QUARANTINED)
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "quarantined Function context cannot restore from quiesce"
      );
    if (state != RDMA_CONTEXT_QUIESCING || binding == null ||
        binding.owner_h == null || !binding.accepts(binding.owner_h))
      return rdma_status::make(
        RDMA_SC_INVALID_STATE,
        "Function context quiesce rollback authority is invalid"
      );
    state = RDMA_CONTEXT_ACTIVE;
    return rdma_status::success();
  endfunction

  // 功能：在不改写 context 值图的前提下，预检 close 流程是否拥有把该 Function
  //       隔离到 QUARANTINED 的授权，供 device env 在解除 Host-router 绑定前建立
  //       整体失败屏障。
  // 输入/输出及副作用：owner/lease_token（输入）描述可选 coordinator ownership；函数
  //       只读取当前 reset_coordinator 的 lease/transaction 状态并返回授权 status，不清空
  //       identity、binding、资源引用或 m_validated_candidate，也不取得外部对象所有权。
  // 失败/边界：coordinator 由其它 owner 持有、owner/token 不成对、token 过期，或当前
  //       context 的 coordinator 已缺失而调用者仍携带 lease 时返回错误；未绑定/未 claim
  //       coordinator 的 standalone context 接受 null/0。调用方必须在该检查全部成功后再
  //       调用 quarantine_for_close()，因为本函数本身不提供隔离提交。
  function rdma_status validate_quarantine_for_close(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    bit require_lease;

    // QUARANTINED 是不可复用终态；即使 context 在上一次 close 尝试中已经清空
    // coordinator 引用，重复清理也不能因为旧 token 不再可回验而阻塞剩余字段清除。
    if (state == RDMA_CONTEXT_QUARANTINED)
      return rdma_status::success();
    require_lease = reset_coordinator != null &&
                    reset_coordinator.lease_held();
    return authorize_context_mutation(
      owner, lease_token, 1'b0, require_lease
    );
  endfunction

  // 功能：quarantine_for_close 在 device env 已完成外部 router teardown 后，把 retained
  //       context 变成不可复用的终态，切断旧 identity、binding、资源快照和 reset authority。
  // 输入/输出及副作用：owner/lease_token（输入）描述可选 coordinator ownership；成功时将
  //       state 设为 RDMA_CONTEXT_QUARANTINED，清空 identity、binding、resources、manager、
  //       Host/PCIe/coordinator 非拥有引用及 m_validated_candidate，不释放这些外部对象。
  // 失败/边界：coordinator 仍由其它 owner 持有、owner/token 不匹配或参数成对不完整时返回
  //       RESOURCE_BUSY/INVALID_ARGUMENT 且保留当前值图；已隔离 context 进入终态后不再要求
  //       旧 coordinator lease，可幂等清理残留引用，但调用方仍必须在 release lease 前完成
  //       本函数，避免 retained handle 继续携带旧 authority。
  function rdma_status quarantine_for_close(
    uvm_object owner = null,
    longint unsigned lease_token = 0
  );
    rdma_status lease_status;

    lease_status = validate_quarantine_for_close(owner, lease_token);
    if (lease_status == null || !lease_status.ok())
      return lease_status == null ?
        rdma_status::make(
          RDMA_SC_INVALID_STATE,
          "Function context close quarantine lease validation returned null"
        ) : lease_status;

    state = RDMA_CONTEXT_QUARANTINED;
    identity = null;
    binding = null;
    resources = null;
    resource_manager = null;
    host_mem = null;
    pcie = null;
    reset_coordinator = null;
    m_validated_candidate = null;
    return rdma_status::success();
  endfunction

  // 功能：在当前 Function scope 内查询队列句柄；此阶段仅提供统一 authority 校验。
  // 输入/输出及副作用：queue_handle（输入）；只读校验 context ACTIVE 状态及 Function UID/generation，
  //   当前实现不维护队列表，因此不会发布 queue 对象或取得外部资源所有权。
  // 失败/边界：context 非 ACTIVE、句柄为空、Function UID/generation 不匹配或队列未登记时拒绝。
  function rdma_status lookup_queue(rdma_handle queue_handle);
    if (state != RDMA_CONTEXT_ACTIVE)
      return rdma_status::make(RDMA_SC_INVALID_STATE,
                               "Function context is not active");
    if (queue_handle == null)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue handle is null");
    if (identity == null || queue_handle.function_uid != identity.function_uid)
      return rdma_status::make(RDMA_SC_INVALID_ARGUMENT,
                               "queue handle Function does not match context");
    if (queue_handle.generation != identity.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               "queue handle generation is stale");
    return rdma_status::make(RDMA_SC_INVALID_STATE,
                             "queue is not registered in Function context");
  endfunction
endclass
