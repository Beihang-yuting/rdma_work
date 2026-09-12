// 目录：核心执行层 core/rdma_cmq_port.sv。
// 职责：实现 rdma_cmq_port 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_cmq_port.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

virtual class rdma_cmq_port extends uvm_object;

  // 功能：构造 rdma_cmq_port，调用 super.new 建立 UVM 层级对象；外部依赖字段保持未绑定，后续由 configure/build/activate 明确注入。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_cmq_port 构造只建立本地初始状态，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_cmq_port");
    super.new(name);
  endfunction

  // 功能：在 rdma_cmq_port 中，execute 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：command（输入）、ticket（输出）、completion（输出）、status（输出）；execute 驱动下游事务，并写入 ticket、completion、status；函数返回 无直接返回值，不取得调用方资源所有权。

  // 失败/边界：execute 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  pure virtual task execute(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );

  // 设计说明：legacy execute() 只返回结果对象，不能证明任何 submission 或
  // completion lifecycle。此单向 wrapper 在 dispatch 前冻结 command/owner，
  // 再把 legacy 返回值做 nonfatal detached snapshot，绝不反向调用自身。
  // 功能：执行一次 legacy execute，并发布保守的 observed execution result。
  // 输入/输出及副作用：command 为非拥有输入，result 为新建的 detached 输出；
  //   调用一次 execute，且不修改调用方持有的 command、ticket 或 completion。
  // 失败/边界：任一快照失败仅把 observation_status 置 INVALID_STATE；独立成功
  //   字段仍保留。所有 legacy 返回都标记 UNOBSERVED，禁止自动恢复或重试。
  virtual task execute_observed(
    input rdma_cmq_command_desc command,
    output rdma_cmq_execution_result result
  );
    rdma_cmq_nonfatal_snapshot_context snapshot_context;
    rdma_cmq_command_identity identity_snapshot;
    rdma_cmq_recovery_owner owner_snapshot;
    rdma_cmq_recovery_owner owner_source;
    rdma_cmq_ticket legacy_ticket;
    rdma_cmq_ticket ticket_snapshot;
    rdma_cmq_completion legacy_completion;
    rdma_cmq_completion completion_snapshot;
    rdma_status legacy_status;
    rdma_status status_snapshot;
    uvm_object payload_snapshot;
    string failure_reason;
    bit observation_failed;
    bit payload_captured;

    result = new("rdma_cmq_legacy_execution_result");
    result.status = rdma_cmq_direct_status(
      RDMA_SC_INVALID_STATE, "legacy CMQ execute did not return a status"
    );
    result.observation_status = rdma_cmq_direct_status(
      RDMA_SC_OK, "legacy CMQ execution snapshot completed"
    );
    result.command_identity = null;
    result.recovery_owner = null;
    result.ticket = null;
    result.completion = null;
    result.submission_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    result.attempt_effect = RDMA_SUBMIT_EFFECT_UNOBSERVED;
    result.completion_phase = RDMA_CMQ_COMPLETION_UNOBSERVED;
    result.batch_key = "";
    result.batch_id = 0;
    result.attempt_id = 0;
    result.recovery_required = 1'b1;
    result.dma_context = null;
    snapshot_context = new();
    observation_failed = 1'b0;

    identity_snapshot = new("rdma_cmq_legacy_command_identity");
    if (identity_snapshot.capture_from(command, failure_reason)) begin
      result.command_identity = identity_snapshot;
    end
    else begin
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, failure_reason
      );
      observation_failed = 1'b1;
    end

    owner_source = (command == null) ? null : command.recovery_owner;
    if (snapshot_context.try_snapshot_recovery_owner(
          owner_source, owner_snapshot, failure_reason
        )) begin
      result.recovery_owner = owner_snapshot;
    end
    else if (!observation_failed) begin
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, failure_reason
      );
      observation_failed = 1'b1;
    end

    legacy_ticket = null;
    legacy_completion = null;
    legacy_status = null;
    execute(command, legacy_ticket, legacy_completion, legacy_status);

    if (snapshot_context.try_snapshot_required_status(
          legacy_status, status_snapshot, failure_reason
        )) begin
      result.status = status_snapshot;
    end
    else begin
      result.status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, failure_reason
      );
      if (!observation_failed) begin
        result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, failure_reason
        );
        observation_failed = 1'b1;
      end
    end

    if (snapshot_context.try_snapshot_optional_ticket(
          legacy_ticket, ticket_snapshot, failure_reason
        )) begin
      result.ticket = ticket_snapshot;
    end
    else if (!observation_failed) begin
      result.observation_status = rdma_cmq_direct_status(
        RDMA_SC_INVALID_STATE, failure_reason
      );
      observation_failed = 1'b1;
    end

    payload_snapshot = null;
    payload_captured = 1'b1;
    if (legacy_completion != null && legacy_completion.decoded_response != null)
      payload_captured = try_snapshot_legacy_decoded_response(
        legacy_completion.decoded_response, payload_snapshot, failure_reason
      );
    if (!payload_captured) begin
      if (!observation_failed) begin
        result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, failure_reason
        );
        observation_failed = 1'b1;
      end
    end
    else if (!snapshot_context.try_snapshot_completion_shell(
               legacy_completion, payload_snapshot, completion_snapshot,
               failure_reason
             )) begin
      if (!observation_failed) begin
        result.observation_status = rdma_cmq_direct_status(
          RDMA_SC_INVALID_STATE, failure_reason
        );
        observation_failed = 1'b1;
      end
    end
    else begin
      result.completion = completion_snapshot;
    end
  endtask

  // 设计说明：base port 不认识 legacy decoded payload 的 concrete 生命周期，
  // 因此默认拒绝所有非空对象；能直接按字段复制的 adapter 才可覆盖此窄 hook。
  // 功能：尝试把 legacy decoded response 转为 detached payload snapshot。
  // 输入/输出及副作用：source 为非拥有输入，snapshot/failure_reason 为输出；
  //   基类清空输出且不调用 factory、clone、engine 或 profile。
  // 失败/边界：null source 是成功的 null payload；每个非空 source 都以稳定
  //   非致命原因拒绝，调用方仍可保留已独立捕获的 ticket 和 operation status。
  protected virtual function bit try_snapshot_legacy_decoded_response(
    input uvm_object source,
    output uvm_object snapshot,
    output string failure_reason
  );
    snapshot = null;
    failure_reason = "";
    if (source == null)
      return 1'b1;
    failure_reason = "legacy CMQ decoded response snapshot is unsupported";
    return 1'b0;
  endfunction

  // 功能：在 rdma_cmq_port 中，reconcile 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：ticket（输入）、terminal_known（输出）、completion（输出）、status（输出）；输入 action/epoch/handle
  //   决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：reconcile 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  pure virtual task reconcile(
    rdma_cmq_ticket ticket,
    output bit terminal_known,
    output rdma_cmq_completion completion,
    output rdma_status status
  );

  // A missing ticket/completion is not proof that a command was rejected
  // before submission.  An adapter may override this observation when it can
  // prove that the most recent execute() failed in its own pre-submit
  // validation path.  The conservative default is fail-closed.
  // 功能：在 rdma_cmq_port 中，last_execute_definitive_no_submit 只读查询当前运行时/测试账本，返回槽位、对象或恢复记录的快照而不推进事务。
  // 输入/输出及副作用：无显式参数；last_execute_definitive_no_submit 读取 last_execute 的 submitted、completed 和 definitive_no_submit 标志，返回是否明确未提交；函数返回 bit，不取得调用方资源所有权。
  // 失败/边界：last_execute_definitive_no_submit 比较或前置条件不满足时返回 0/false；该路径不隐式重试，也不转移未声明资源。
  virtual function bit last_execute_definitive_no_submit();
    return 1'b0;
  endfunction
endclass
