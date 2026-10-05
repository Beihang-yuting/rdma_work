// 目录：核心执行层 core/rdma_cmq_port.sv。
// 职责：实现 rdma_cmq_port 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

virtual class rdma_cmq_port extends uvm_object;

  // 功能：构造 rdma_cmq_port。
  // 输入/输出及副作用：name 为 UVM 对象名；仅调用 super.new。
  // 失败/边界：无。
  function new(string name = "rdma_cmq_port");
    super.new(name);
  endfunction

  // 功能：提交一条 CMQ 命令并返回 ticket、completion 与 status（子类实现）。
  // 输入/输出及副作用：command 输入；ticket/completion/status 输出；驱动下游事务。
  // 失败/边界：锁、超时、generation 变化或提交证据不全时保持原状态，不推进游标。
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
  //   调用一次 execute。legacy override 可改写 command 指向的图，但发布的
  //   command_identity/recovery_owner 是 dispatch 前捕获的 detached 快照。
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
  // 输入/输出及副作用：source 为非拥有输入，snapshot/failure_reason 为输出；基类清空输出，不调用 factory/clone。
  // 失败/边界：null source 视为成功的 null payload；非空 source 一律以非致命原因拒绝。
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

  // 功能：按 ticket 对账一次已提交命令的终态（子类实现）。
  // 输入/输出及副作用：ticket 输入；terminal_known/completion/status 输出；成功时更新状态或恢复证据。
  // 失败/边界：锁、超时、generation 变化或提交证据不全时保持原状态，不推进游标。
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
  // 功能：查询最近一次 execute 是否确定未提交。
  // 输入/输出及副作用：无参数；基类不读任何状态，直接返回 0。
  // 失败/边界：默认 fail-closed 返回 0；缺失 ticket/completion 不能证明未提交。
  virtual function bit last_execute_definitive_no_submit();
    return 1'b0;
  endfunction
endclass
