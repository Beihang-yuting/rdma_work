// 目录：核心执行层 core/rdma_control_plane.sv。
// 职责：实现 rdma_control_plane 在本层的职责和对外接口。
// 依赖：依赖本层公共 types/model/adapter 契约及其上游快照。
// 所有权与生命周期：对象只拥有显式创建的值快照；外部资源保存非拥有引用，生命周期由调用方管理。

// 中文说明：rdma_control_plane.sv 属于核心执行层，负责队列、控制面、资源和恢复流程。
// 阅读提示：先看公开类型和接口，再看实现细节；失败路径应保持状态与资源所有权可追踪。

class rdma_control_plane extends uvm_object;
  `uvm_object_utils(rdma_control_plane)

  protected rdma_resource_manager manager;
  protected rdma_cmq_port cmq;
  protected rdma_stag_key_policy key_policy;
  protected rdma_host_mem_api host_mem;
  protected rdma_hmc_allocator hmc_allocator;
  protected rdma_context_backing_api context_backing;
  protected rdma_queue_lifecycle_executor queue_executor;
  protected rdma_qp_lifecycle_executor qp_executor;
  protected time default_timeout;
  protected bit configured;

  protected longint unsigned next_transaction_id;
  protected bit transaction_ids_exhausted;
  protected semaphore lock_table_guard;
  protected semaphore function_locks[string];

  // 功能：构造 rdma_control_plane，调用 super.new 建立 UVM 对象，并把构造体直接写入的默认值设为：manager=null；cmq=null；key_policy=null；host_mem=null；hmc_allocator=null；context_backing=null；queue_executor=null；qp_executor=null；其余字段按实现默认值初始化。
  // 输入/输出及副作用：name（输入）；new 只写入构造体列出的默认字段并返回 void，外部依赖与资源所有权仍由上层管理。
  // 失败/边界：rdma_control_plane 构造只建立本地初始状态；本地 semaphore/ledger 等按构造体显式分配，不接管外部 Host-memory、PCIe 或 manager；未完成后续 configure/build/activate 时，业务入口必须返回 INVALID_STATE。
  function new(string name = "rdma_control_plane");
    super.new(name);
    manager = null;
    cmq = null;
    key_policy = null;
    host_mem = null;
    hmc_allocator = null;
    context_backing = null;
    queue_executor = null;
    qp_executor = null;
    default_timeout = 0;
    configured = 1'b0;
    next_transaction_id = 1;
    transaction_ids_exhausted = 1'b0;
    lock_table_guard = new(1);
    function_locks.delete();
  endfunction

  // 功能：在 rdma_control_plane 中，invalid_argument 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_argument 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_argument 返回 RDMA_SC_INVALID_ARGUMENT；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_argument(string message);
    return rdma_status::make(RDMA_SC_INVALID_ARGUMENT, message);
  endfunction

  // 功能：在 rdma_control_plane 中，invalid_state 把错误消息、硬件码或注入故障封装为统一 rdma_status，保留原事务的诊断证据。
  // 输入/输出及副作用：message（输入）；invalid_state 读取 message 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：invalid_state 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status invalid_state(string message);
    return rdma_status::make(RDMA_SC_INVALID_STATE, message);
  endfunction

  // 功能：在 rdma_control_plane 中，snapshot_handle 按完整 key/handle 查找唯一权威记录并返回 detached 快照，避免把内部可变引用泄露给调用方。
  // 输入/输出及副作用：source（输入）；snapshot_handle 读取 source 并使用字段 snapshot、snapshot.kind、snapshot.function_uid、snapshot.object_id、snapshot.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：snapshot_handle 在 key/handle 缺失、记录不唯一或 generation/reset epoch 过期时返回明确错误，不回退到默认 authority。
  protected function rdma_handle snapshot_handle(rdma_handle source);
    rdma_handle snapshot;

    if (source == null)
      return null;
    snapshot = new("control_handle_snapshot");
    snapshot.kind = source.kind;
    snapshot.function_uid = source.function_uid;
    snapshot.object_id = source.object_id;
    snapshot.generation = source.generation;
    return snapshot;
  endfunction

  // 功能：checked_status 校验 source、null_message 与当前对象状态的一致性，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：source（输入）、null_message（输入）；checked_status 读取 source、null_message 并使用输入参数和固定枚举/常量；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：checked_status 返回 RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status checked_status(
    rdma_status source,
    string null_message
  );
    if (source == null)
      return invalid_state(null_message);
    return rdma_cmq_clone_status_value(source);
  endfunction

  // 功能：为 MR 的硬件阶段构造 CMQ 命令：OCC_FLUSHED→OCC_FLUSH（按 mr_serial 冲刷
  //   PBLE）、MR_DEREGISTERED→MR_DEREGISTER（失效 MRT）、DRAINED→TQ_FLUSH。
  // 输入/输出及副作用：owner 被深拷贝进命令，mr 只读；返回新命令，使用 default_timeout。
  // 失败/边界：其它 step 返回 null，由调用方报告 UNSUPPORTED_OPCODE。
  protected function rdma_cmq_command_desc make_mr_hw_command(
    rdma_function_handle owner,
    rdma_mr mr,
    rdma_control_step_e step,
    string name
  );
    rdma_hw_occ_flush_body occ_body;
    rdma_hw_mr_deregister_body deregister_body;

    if (step == RDMA_CTRL_STEP_HW_OCC_FLUSHED) begin
      occ_body = rdma_hw_occ_flush_body::type_id::create({name, "_body"});
      occ_body.mr_serial_flush = 1'b1;
      occ_body.pble = 1'b1;
      occ_body.mr_serial = mr.mr_serial[11:0];
      return rdma_make_cmq_command(owner, RDMA_OP_OCC_FLUSH, "occ_flush",
                                   occ_body, default_timeout, name);
    end
    if (step == RDMA_CTRL_STEP_HW_MR_DEREGISTERED) begin
      deregister_body =
        rdma_hw_mr_deregister_body::type_id::create({name, "_body"});
      deregister_body.mr_h = project_handle(mr.handle, mr.local_mr_id,
                                            RDMA_RESOURCE_MR);
      deregister_body.stag_key = mr.lkey[7:0];
      deregister_body.next_state = RDMA_CONTEXT_INVALID;
      return rdma_make_cmq_command(owner, RDMA_OP_MR_DEREGISTER,
                                   "deregister", deregister_body,
                                   default_timeout, name);
    end
    if (step == RDMA_CTRL_STEP_HW_DRAINED)
      return rdma_make_cmq_command(
        owner, RDMA_OP_TQ_FLUSH, "tq_flush",
        rdma_hw_cmq_empty_body::type_id::create({name, "_body"}),
        default_timeout, name
      );
    return null;
  endfunction

  // 功能：在 rdma_control_plane 中，execute_control_command_raw_status 收束一次
  //   legacy CMQ 原始 dispatch，明确保留 backend status identity，供仍依赖原始
  //   status 引用的特殊控制面阶段调用。
  // 输入/输出及副作用：command（输入）；ticket、completion、status（输出）。任务
  //   清空本次事务的 ticket/completion，检查 CMQ/command 后恰好调用 cmq.execute 一次，
  //   将 backend 原始 status 写入 status；不取得 command 或外部 CMQ 资源所有权。
  // 失败/边界：cmq 为空时返回 RDMA_SC_INVALID_STATE，command 为空时返回
  //   RDMA_SC_INVALID_ARGUMENT；backend 返回 null status 时保留 null，由调用方按其
  //   原有诊断和 recovery 优先级归一化。任务不重试、不推断 timeout 或 ambiguity，
  //   也不推进 generation/资源状态。
  protected task execute_control_command_raw_status(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_cmq_dispatch_legacy_raw(
      cmq,
      command,
      ticket,
      completion,
      status,
      "control-plane CMQ is unavailable",
      "control-plane CMQ command is null"
    );
  endtask

  // 功能：在 rdma_control_plane 中，execute_control_command 在原始 CMQ dispatch
  // 之后生成 detached status，供 MR 回滚、注销和恢复阶段安全读取稳定诊断值。
  // 输入/输出及副作用：command（输入）；ticket、completion、status（输出）；
  //   null_status_message（输入）。任务复用 raw-status seam 且只调用一次
  //   cmq.execute；成功或 backend status 均复制为独立 status，不取得 command 或
  //   外部 CMQ 资源所有权。
  // 失败/边界：cmq/command guard 的错误沿用 raw seam；backend null status 按
  //   null_status_message 归一化为 RDMA_SC_INVALID_STATE。任务不重试、不推断
  //   timeout/ambiguity，也不推进 generation、资源状态或 recovery journal。
  protected task execute_control_command(
    rdma_cmq_command_desc command,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status,
    input string null_status_message
  );
    execute_control_command_raw_status(
      command, ticket, completion, status
    );
    status = checked_status(status, null_status_message);
  endtask

  // 功能：make_result 通过 control 域 lifecycle result seed 建立 detached 的未完成
  //   rdma_control_result，供 PD/MR/CQ/QP 等控制面入口在同一结果契约上追加业务阶段。
  // 输入/输出及副作用：无显式参数；返回写入 status、primary_status、初始资源状态
  //   和 recovery 标志的 result，只访问本地 seed，不取得 manager、CMQ 或外部 adapter
  //   所有权。
  // 失败/边界：seed 分配或初始化失败时返回带 INVALID_STATE 的结果；transaction_id
  //   仍由调用入口在原有分配窗口写入，函数不提前改变 exhaustion、错误优先级或提交顺序。
  protected function rdma_control_result make_result();
    rdma_control_result result;
    rdma_lifecycle_result_seed seed;
    rdma_status seed_status;

    result = new("control_result");
    seed = rdma_lifecycle_result_seed::type_id::create(
      "control_result_seed"
    );
    if (seed == null) begin
      result.status = invalid_state(
        "control-plane result seed allocation failed"
      );
      result.primary_status = rdma_cmq_clone_status_value(result.status);
      return result;
    end
    seed.domain = RDMA_LIFECYCLE_DOMAIN_CONTROL;
    seed.pending_message = "control-plane operation did not complete";
    seed_status = seed.initialize_result(result);
    if (seed_status == null || !seed_status.ok()) begin
      result.status = invalid_state(
        "control-plane result seed initialization failed"
      );
      result.primary_status = rdma_cmq_clone_status_value(result.status);
      result.final_resource_state = RDMA_RESOURCE_NEW;
      result.final_resource_state_known = 1'b0;
      result.recovery_required = 1'b0;
    end
    return result;
  endfunction

  // 功能：在 rdma_control_plane 中，cleanup_activated_pd 按 owner、generation 和幂等规则释放或清理资源，同时删除相关账本记录。
  // 输入/输出及副作用：pd_h（输入）、result（输入）；cleanup_activated_pd 读取 pd_h、result 并使用字段 cleanup_status、result.final_resource_state、result.final_resource_state_known；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：cleanup_activated_pd 无返回值，仅执行 cleanup_status=manager.begin_quiesce(pd_h)、cleanup_status=checked_status(、result.final_resource_state=RDMA_RESOURCE_QUIESCING、result.final_resource_state_known=1'b1；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function void cleanup_activated_pd(
    rdma_handle pd_h,
    rdma_control_result result
  );
    rdma_status cleanup_status;

    cleanup_status = manager.begin_quiesce(pd_h);
    cleanup_status = checked_status(
      cleanup_status, "active PD cleanup quiesce returned null"
    );
    if (!cleanup_status.ok()) begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(cleanup_status)
      );
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_QUIESCING;
    result.final_resource_state_known = 1'b1;

    cleanup_status = manager.finalize_release(pd_h);
    cleanup_status = checked_status(
      cleanup_status, "active PD cleanup release returned null"
    );
    if (!cleanup_status.ok()) begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(cleanup_status)
      );
      return;
    end
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
  endfunction

  // 功能：在 rdma_control_plane 中，finalize_mr_recovery 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：reserved_mr（输入）、recovery（输入）、primary_status（输入）、result（输入）、mr（输出）、result_finalized（输出）、b0（输入）；finalize_mr_recovery 读取 reserved_mr、recovery、primary_status、result、mr、result_finalized、reserved_error 并使用字段 mr、result_finalized、normalized_primary、recovery_status、result.final_resource_state、result.final_resource_state_known、result.recovery_required、result.primary_status，并写入 mr、result_finalized；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：finalize_mr_recovery 返回 RDMA_SC_RECOVERY_REQUIRED；典型拒绝条件为“MR state requires recovery”；失败路径不提交部分状态或转移未声明资源。
  protected function void finalize_mr_recovery(
    rdma_mr reserved_mr,
    rdma_recovery_record recovery,
    rdma_status primary_status,
    rdma_control_result result,
    output rdma_mr mr,
    output bit result_finalized,
    input bit reserved_error = 1'b0
  );
    rdma_resource authoritative_resource;
    rdma_status normalized_primary;
    rdma_status recovery_status;

    mr = null;
    result_finalized = 1'b1;
    normalized_primary = checked_status(
      primary_status, "MR recovery primary status is null"
    );
    if (reserved_error)
      recovery_status = manager.mark_reserved_error(
        reserved_mr.handle, recovery
      );
    else
      recovery_status = manager.mark_error(reserved_mr.handle, recovery);
    recovery_status = checked_status(
      recovery_status, "MR recovery freeze returned null"
    );
    if (recovery_status.ok()) begin
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b1;
      recovery_status = manager.lookup(
        reserved_mr.handle, authoritative_resource
      );
      recovery_status = checked_status(
        recovery_status, "resource manager ERROR MR lookup returned null"
      );
      if (recovery_status.ok()) begin
        if (!$cast(mr, authoritative_resource) || mr == null ||
            mr.handle == null || mr.state != RDMA_RESOURCE_ERROR)
          mr = null;
      end
    end
    else begin
      result.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(recovery_status)
      );
      recovery_status = manager.lookup(
        reserved_mr.handle, authoritative_resource
      );
      recovery_status = checked_status(
        recovery_status, "authoritative MR fallback lookup returned null"
      );
      if (recovery_status.ok() && authoritative_resource != null) begin
        result.final_resource_state = authoritative_resource.state;
        result.final_resource_state_known = 1'b1;
      end
      else begin
        if (recovery_status.ok())
          recovery_status = invalid_state(
            "authoritative MR fallback snapshot is null"
          );
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(recovery_status)
        );
        result.final_resource_state = RDMA_RESOURCE_NEW;
        result.final_resource_state_known = 1'b0;
      end
      result.recovery_required = 1'b0;
    end
    result.primary_status = rdma_cmq_clone_status_value(normalized_primary);
    result.status = rdma_status::make(
      RDMA_SC_RECOVERY_REQUIRED,
      "MR state requires recovery"
    );
  endfunction

  // 功能：执行 retain_mr_rollback_error 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：reserved_mr（输入）、primary_status（输入）、result（输入）、hardware_presence（输入）、has_pending_step（输入）、pending_step（输入）、ambiguous_ticket（输入）、mr（输出）、result_finalized（输出）；retain_mr_rollback_error 读取 reserved_mr、primary_status、result、hardware_presence、has_pending_step、pending_step、ambiguous_ticket、mr、result_finalized 并使用字段 recovery、recovery.resource_h、recovery.hardware_presence、recovery.completed_steps、recovery.backing_refs、recovery.hmc_refs、recovery.ambiguous_ticket、recovery.primary_status，并写入 mr、result_finalized；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：retain_mr_rollback_error 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void retain_mr_rollback_error(
    rdma_mr reserved_mr,
    rdma_status primary_status,
    rdma_control_result result,
    rdma_hw_presence_e hardware_presence,
    bit has_pending_step,
    rdma_control_step_e pending_step,
    rdma_cmq_ticket ambiguous_ticket,
    output rdma_mr mr,
    output bit result_finalized
  );
    rdma_recovery_record recovery;

    recovery = rdma_recovery_record::type_id::create(
      "register_mr_rollback_recovery"
    );
    recovery.resource_h = snapshot_handle(reserved_mr.handle);
    recovery.hardware_presence = hardware_presence;
    recovery.completed_steps = result.completed_steps;
    if (has_pending_step)
      recovery.pending_steps.push_back(pending_step);
    recovery.backing_refs = reserved_mr.backing_refs;
    recovery.hmc_refs = reserved_mr.hmc_refs;
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ambiguous_ticket, "register MR rollback recovery"
    );
    recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
    recovery.rollback_statuses = result.rollback_statuses;
    finalize_mr_recovery(reserved_mr, recovery, primary_status, result, mr,
                         result_finalized);
  endfunction

  // 功能：在 rdma_control_plane 中，rollback_mr_creation 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：reserved_mr（输入）、owner（输入）、primary_status（输入）、result（输入）、hardware_key_allocated（输入）、registry_programmed（输入）、mr（输出）、result_finalized（输出）；输入
  //   handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：rollback_mr_creation 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected task rollback_mr_creation(
    rdma_mr reserved_mr,
    rdma_function_handle owner,
    rdma_status primary_status,
    rdma_control_result result,
    bit hardware_key_allocated,
    bit registry_programmed,
    output rdma_mr mr,
    output bit result_finalized
  );
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_recovery_record recovery;
    rdma_status rollback_status;
    rdma_hw_presence_e failure_presence;
    bit released_owned_backing;

    mr = null;
    result_finalized = 1'b0;
    ticket = null;
    released_owned_backing = 1'b0;

    if (hardware_key_allocated) begin
      command = make_mr_hw_command(owner, reserved_mr,
                                   RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
                                   "register_mr_rollback_deregister");
      execute_control_command(
        command, ticket, completion, rollback_status,
        "MR_DEREGISTER rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        failure_presence = (rollback_status.code == RDMA_SC_TIMEOUT) ?
          RDMA_HW_PRESENCE_UNKNOWN : RDMA_HW_PRESENCE_PRESENT;
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, failure_presence, 1'b1,
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
          (rollback_status.code == RDMA_SC_TIMEOUT) ? ticket : null, mr,
          result_finalized
        );
        return;
      end
      result.completed_steps.push_back(
        RDMA_CTRL_STEP_HW_MR_DEREGISTERED
      );
    end

    for (int i = int'(reserved_mr.hmc_refs.size()) - 1; i >= 0; i--) begin
      if (reserved_mr.hmc_refs[i] == null ||
          reserved_mr.hmc_refs[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          reserved_mr.hmc_refs[i].release_complete)
        continue;
      if (hmc_allocator == null)
        rollback_status = invalid_state(
          "owned MR HMC rollback allocator is unavailable"
        );
      else
        rollback_status = hmc_allocator.\release (
          reserved_mr.hmc_refs[i].owner,
          reserved_mr.hmc_refs[i].object_kind,
          reserved_mr.hmc_refs[i].address
        );
      rollback_status = checked_status(
        rollback_status, "owned MR HMC rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
      reserved_mr.hmc_refs[i].release_complete = 1'b1;
      released_owned_backing = 1'b1;
    end

    for (int i = int'(reserved_mr.backing_refs.size()) - 1; i >= 0; i--) begin
      if (reserved_mr.backing_refs[i] == null ||
          reserved_mr.backing_refs[i].ownership !=
            RDMA_OWNERSHIP_CONTROL_PLANE ||
          reserved_mr.backing_refs[i].release_complete)
        continue;
      if (host_mem == null)
        rollback_status = invalid_state(
          "owned MR backing rollback host memory is unavailable"
        );
      else
        rollback_status = host_mem.\release (
          reserved_mr.backing_refs[i].mapping
        );
      rollback_status = checked_status(
        rollback_status, "owned MR backing rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        if (hardware_key_allocated || registry_programmed) begin
          retain_mr_rollback_error(
            reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
            1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, mr,
            result_finalized
          );
          return;
        end
        recovery = rdma_recovery_record::type_id::create(
          "register_mr_reserved_backing_rollback"
        );
        recovery.resource_h = snapshot_handle(reserved_mr.handle);
        recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
        recovery.completed_steps = result.completed_steps;
        recovery.pending_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);
        recovery.backing_refs = reserved_mr.backing_refs;
        recovery.hmc_refs = reserved_mr.hmc_refs;
        recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
        recovery.rollback_statuses = result.rollback_statuses;
        finalize_mr_recovery(
          reserved_mr, recovery, primary_status, result, mr,
          result_finalized, 1'b1
        );
        return;
      end
      reserved_mr.backing_refs[i].release_complete = 1'b1;
      released_owned_backing = 1'b1;
    end
    if (released_owned_backing)
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);

    if (!registry_programmed) begin
      rollback_status = manager.release_reserved(reserved_mr.handle);
      rollback_status = checked_status(
        rollback_status, "MR reservation rollback returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        if (reserved_mr.hmc_refs.size() == 0 &&
            reserved_mr.backing_refs.size() == 1 &&
            reserved_mr.backing_refs[0] != null &&
            reserved_mr.backing_refs[0].ownership ==
              RDMA_OWNERSHIP_CONTROL_PLANE) begin
          recovery = rdma_recovery_record::type_id::create(
            "register_mr_reserved_resource_rollback"
          );
          recovery.resource_h = snapshot_handle(reserved_mr.handle);
          recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
          recovery.completed_steps = result.completed_steps;
          recovery.pending_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
          recovery.backing_refs = reserved_mr.backing_refs;
          recovery.hmc_refs = reserved_mr.hmc_refs;
          recovery.primary_status =
            rdma_cmq_clone_status_value(primary_status);
          recovery.rollback_statuses = result.rollback_statuses;
          finalize_mr_recovery(
            reserved_mr, recovery, primary_status, result, mr,
            result_finalized, 1'b1
          );
        end
        else begin
          retain_mr_rollback_error(
            reserved_mr, primary_status, result,
            RDMA_HW_PRESENCE_ABSENT, 1'b1,
            RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
            result_finalized
          );
        end
        return;
      end
    end
    else begin
      recovery = rdma_recovery_record::type_id::create(
        "register_mr_programmed_rollback"
      );
      recovery.resource_h = snapshot_handle(reserved_mr.handle);
      recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
      recovery.completed_steps = result.completed_steps;
      recovery.backing_refs = reserved_mr.backing_refs;
      recovery.hmc_refs = reserved_mr.hmc_refs;
      recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
      recovery.rollback_statuses = result.rollback_statuses;
      rollback_status = manager.mark_error(reserved_mr.handle, recovery);
      rollback_status = checked_status(
        rollback_status, "programmed MR rollback mark ERROR returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
      result.final_resource_state = RDMA_RESOURCE_ERROR;
      result.final_resource_state_known = 1'b1;
      rollback_status = manager.finalize_release(reserved_mr.handle);
      rollback_status = checked_status(
        rollback_status, "programmed MR rollback release returned null"
      );
      if (!rollback_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(rollback_status)
        );
        retain_mr_rollback_error(
          reserved_mr, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, mr,
          result_finalized
        );
        return;
      end
    end
    result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
  endtask

  // 功能：执行 retain_mr_destroy_error 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：mr_snapshot（输入）、primary_status（输入）、result（输入）、hardware_presence（输入）、has_pending_step（输入）、pending_step（输入）、ambiguous_ticket（输入）、result_finalized（输出）；retain_mr_destroy_error 读取 mr_snapshot、primary_status、result、hardware_presence、has_pending_step、pending_step、ambiguous_ticket、result_finalized 并使用字段 recovery、recovery.resource_h、recovery.hardware_presence、recovery.completed_steps、recovery.backing_refs、recovery.hmc_refs、recovery.ambiguous_ticket、recovery.primary_status，并写入 result_finalized；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：retain_mr_destroy_error 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void retain_mr_destroy_error(
    rdma_mr mr_snapshot,
    rdma_status primary_status,
    rdma_control_result result,
    rdma_hw_presence_e hardware_presence,
    bit has_pending_step,
    rdma_control_step_e pending_step,
    rdma_cmq_ticket ambiguous_ticket,
    output bit result_finalized
  );
    rdma_mr ignored_mr;
    rdma_recovery_record recovery;

    recovery = rdma_recovery_record::type_id::create(
      "deregister_mr_recovery"
    );
    recovery.resource_h = snapshot_handle(mr_snapshot.handle);
    recovery.hardware_presence = hardware_presence;
    recovery.completed_steps = result.completed_steps;
    if (has_pending_step)
      recovery.pending_steps.push_back(pending_step);
    recovery.backing_refs = mr_snapshot.backing_refs;
    recovery.hmc_refs = mr_snapshot.hmc_refs;
    recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
      ambiguous_ticket, "deregister MR recovery"
    );
    recovery.primary_status = rdma_cmq_clone_status_value(primary_status);
    recovery.rollback_statuses = result.rollback_statuses;
    finalize_mr_recovery(
      mr_snapshot, recovery, primary_status, result, ignored_mr,
      result_finalized
    );
  endfunction

  // 功能：在 rdma_control_plane 中，finish_result 提交当前事务阶段并发布 detached 结果，只有成功路径才推进游标或状态。
  // 输入/输出及副作用：result（输入）、operation_status（输入）；finish_result 读取 result、operation_status 并使用字段 normalized、result.status、result.primary_status；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：finish_result 无返回值，仅执行 normalized=checked_status(、result.status=rdma_cmq_clone_status_value(normalized)、result.primary_status=rdma_cmq_clone_status_value(normalized)；调用方须保证前置依赖已经绑定，函数不自动重试或接管外部资源。
  protected function void finish_result(
    rdma_control_result result,
    rdma_status operation_status
  );
    rdma_status normalized;

    if (result == null)
      return;
    normalized = checked_status(
      operation_status, "control-plane operation returned null status"
    );
    result.status = rdma_cmq_clone_status_value(normalized);
    result.primary_status = rdma_cmq_clone_status_value(normalized);
  endfunction

  // 功能：configured_status 校验 当前对象字段 与当前对象状态的一致性，并显式处理“control plane is not configured”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：无显式参数；configured_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：configured_status 返回 RDMA_SC_INVALID_STATE；典型拒绝条件为“control plane is not configured”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status configured_status();
    if (!configured || manager == null || cmq == null ||
        key_policy == null || default_timeout == 0)
      return invalid_state("control plane is not configured");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_control_plane 中，binding_owner_status 把 binding_owner_status 指定的资源或后端能力绑定到当前对象索引，并校验 Function、generation 和队列类型一致。
  // 输入/输出及副作用：binding（输入）、owner（输出）；binding_owner_status 读取 binding、owner 并使用字段 owner、status，并写入 owner；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：资源不存在、类型不符、重复登记或跨 Function 串线时拒绝绑定并保持索引不变。
  protected function rdma_status binding_owner_status(
    rdma_function_binding binding,
    output rdma_function_handle owner
  );
    rdma_status status;

    owner = null;
    if (binding == null)
      return invalid_argument("control-plane Function binding is null");
    status = binding.validate();
    if (status == null)
      return invalid_state("Function binding validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    if (binding.state != RDMA_BIND_ACTIVE)
      return invalid_state("control-plane Function binding is not ACTIVE");
    owner = binding.make_handle();
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("Function binding owner construction failed");
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_control_plane 中，generation_fence 读取并校验 Function generation/reset epoch，拒绝旧 binding 或跨 Function 请求。
  // 输入/输出及副作用：binding（输入）、expected_owner（输入）；generation_fence 读取 binding、expected_owner 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：generation_fence 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_STALE_GENERATION；典型拒绝条件为“generation fence authority is null”“generation fence Function differs”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status generation_fence(
    rdma_function_binding binding,
    rdma_function_handle expected_owner
  );
    if (binding == null || expected_owner == null)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "generation fence authority is null"
      );
    if (binding.function_uid != expected_owner.function_uid ||
        binding.global_function_id != expected_owner.object_id)
      return rdma_status::make(
        RDMA_SC_INVALID_ARGUMENT, "generation fence Function differs"
      );
    if (binding.generation != expected_owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "Function generation changed during transaction"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_control_plane 中由 same_owner_status 逐字段比较输入值，返回结构、身份或序列化内容是否一致。
  // 输入/输出及副作用：candidate（输入）、expected（输入）、label（输入）；比较对象/数组只读；返回 bit 或状态结果，不更新 runtime、账本或外部 adapter。
  // 失败/边界：same_owner_status 的任一比较对象为空或类型不符时返回确定的 false/不等结果，不抛出未处理异常。
  protected function rdma_status same_owner_status(
    rdma_function_handle candidate,
    rdma_function_handle expected,
    string label
  );
    if (candidate == null || candidate.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_argument({label, " owner is not a Function handle"});
    if (expected == null || expected.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state({label, " expected Function owner is invalid"});
    if (candidate.function_uid != expected.function_uid ||
        candidate.object_id != expected.object_id)
      return invalid_argument({label, " Function identity does not match"});
    if (candidate.generation != expected.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        {label, " Function generation is stale"}
      );
    return rdma_status::success();
  endfunction

  // 功能：request_status 校验 request、owner 与当前对象状态的一致性，并显式处理“create PD request is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：request（输入）、owner（输入）；request_status 读取 request、owner 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：request_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“create PD request is null”“create PD request validation returned null”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status request_status(
    rdma_create_pd_req request,
    rdma_function_handle owner
  );
    rdma_status status;

    if (request == null)
      return invalid_argument("create PD request is null");
    status = request.validate();
    if (status == null)
      return invalid_state("create PD request validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, "create PD request");
  endfunction

  // 功能：register_mr_request_status 校验 request、owner 与当前对象状态的一致性，并显式处理“register MR request is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：request（输入）、owner（输入）；register_mr_request_status 可能更新本对象明确拥有的状态；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：register_mr_request_status 返回 函数体规定的失败状态；具体拒绝条件包括 “register MR request is null”；“register MR request validation returned null”；“register MR request”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  protected function rdma_status register_mr_request_status(
    rdma_register_mr_req request,
    rdma_function_handle owner
  );
    rdma_status status;

    if (request == null)
      return invalid_argument("register MR request is null");
    status = request.validate();
    if (status == null)
      return invalid_state("register MR request validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, "register MR request");
  endfunction

  // 功能：MR 注册的入口校验：可选 generation fence、request 合法且属于 owner、backing
  //   描述与 request/ownership 一致；锁前、锁后、快照三处共用同一顺序。
  // 输入/输出及副作用：fence_owner 为 null 时跳过 fence；stage 作为 null 归一化诊断的
  //   前缀；只读全部输入，返回独立 status。
  // 失败/边界：fence 失败返回 INVALID_ARGUMENT/STALE_GENERATION，其余沿用
  //   register_mr_request_status 与 validate_backing 的错误码；子校验返回 null 时为 INVALID_STATE。
  protected function rdma_status register_mr_input_status(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_function_handle fence_owner,
    rdma_function_handle owner,
    rdma_resource_ownership_e required_ownership,
    string stage
  );
    rdma_status status;

    if (fence_owner != null) begin
      status = checked_status(
        generation_fence(binding, fence_owner),
        {stage, "register MR generation fence returned null"}
      );
      if (!status.ok())
        return status;
    end
    status = checked_status(
      register_mr_request_status(request, owner),
      {stage, "register MR request check returned null"}
    );
    if (!status.ok())
      return status;
    return checked_status(
      validate_backing(binding, request, backing, owner, required_ownership),
      {stage, "register MR backing check returned null"}
    );
  endfunction

  // 功能：owned MR 的入口校验：request 合法且属于 owner、长度不超过 32 位 host 分配上限、
  //   不请求 atomic；DMA context 合法、属于 owner、与 binding.queue_dma 授权一致且无 owner_h。
  // 输入/输出及副作用：stage 作为诊断前缀区分锁前/锁后/快照；只读输入，返回独立 status。
  // 失败/边界：超长/context 为空/owner_h 非空返回 INVALID_ARGUMENT，atomic 返回
  //   UNSUPPORTED_OPCODE，DMA 授权不符返回 DMA_TRANSLATION，子校验 null 为 INVALID_STATE。
  protected function rdma_status owned_mr_input_status(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_dma_request_context dma_context,
    rdma_function_handle owner,
    string stage
  );
    rdma_status status;

    status = checked_status(
      register_mr_request_status(request, owner),
      {stage, "owned register MR request check returned null"}
    );
    if (!status.ok())
      return status;
    if (request.length > 64'h0000_0000_ffff_ffff)
      return invalid_argument(
        {stage, "owned MR length exceeds host allocation size"}
      );
    if (request.access.remote_atomic)
      return rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        {stage, "owned MR helper cannot allocate atomic DMA authority"}
      );
    if (dma_context == null)
      return invalid_argument({stage, "owned MR DMA request context is null"});
    status = checked_status(
      dma_context.validate(),
      {stage, "owned MR DMA context validation returned null"}
    );
    if (!status.ok())
      return status;
    status = checked_status(
      same_owner_status(dma_context.function_h, owner,
                        {stage, "owned MR DMA context"}),
      {stage, "owned MR DMA Function check returned null"}
    );
    if (!status.ok())
      return status;
    if (dma_context.requester_bdf != binding.queue_dma.requester_bdf ||
        dma_context.pasid_valid != binding.queue_dma.pasid_valid ||
        dma_context.pasid != binding.queue_dma.pasid ||
        dma_context.dma_domain_valid != binding.queue_dma.dma_domain_valid ||
        dma_context.dma_domain_id != binding.queue_dma.dma_domain_id)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "owned MR DMA authority does not match Function"
      );
    if (dma_context.owner_h != null)
      return invalid_argument("owned MR DMA request owner must be null");
    return rdma_status::success();
  endfunction

  // 功能：深拷贝 register MR request，并确认副本与原对象及其 owner/PD 句柄不共享引用。
  // 输入/输出及副作用：request 只读；frozen 输出新副本，失败时为 null。
  // 失败/边界：clone 失败、类型不符或任一引用未分离时返回 INVALID_STATE。
  protected function rdma_status detach_mr_request(
    rdma_register_mr_req request,
    output rdma_register_mr_req frozen
  );
    uvm_object cloned_object;

    frozen = null;
    cloned_object = request.clone();
    if (cloned_object == null || !$cast(frozen, cloned_object) ||
        frozen == request || frozen.owner == request.owner ||
        frozen.pd_h == request.pd_h) begin
      frozen = null;
      return invalid_state("register MR request snapshot is not deeply detached");
    end
    return rdma_status::success();
  endfunction

  // 功能：深拷贝 MR backing 描述，并确认副本及其 Function 句柄、page layout、每个
  //   backing/HMC 引用（含 mapping 与 owner 句柄）都不与原对象共享。
  // 输入/输出及副作用：backing 只读；frozen 输出新副本，失败时为 null。
  // 失败/边界：clone 失败、类型不符、数组长度不同或任一引用未分离时返回 INVALID_STATE。
  protected function rdma_status detach_mr_backing(
    rdma_mr_backing_desc backing,
    output rdma_mr_backing_desc frozen
  );
    uvm_object cloned_object;

    frozen = null;
    cloned_object = backing.clone();
    if (cloned_object == null || !$cast(frozen, cloned_object) ||
        frozen == backing || frozen.function_h == backing.function_h ||
        frozen.page_layout == backing.page_layout ||
        frozen.backing_refs.size() != backing.backing_refs.size() ||
        frozen.hmc_refs.size() != backing.hmc_refs.size()) begin
      frozen = null;
      return invalid_state("register MR backing snapshot is not deeply detached");
    end
    foreach (frozen.backing_refs[i]) begin
      rdma_backing_ref copy_ref = frozen.backing_refs[i];
      rdma_backing_ref orig_ref = backing.backing_refs[i];

      if (copy_ref == null || orig_ref == null || copy_ref == orig_ref ||
          copy_ref.mapping == null || orig_ref.mapping == null ||
          copy_ref.mapping == orig_ref.mapping ||
          copy_ref.mapping.function_h == orig_ref.mapping.function_h ||
          (orig_ref.mapping.owner_h == null && copy_ref.mapping.owner_h != null) ||
          (orig_ref.mapping.owner_h != null &&
           (copy_ref.mapping.owner_h == null ||
            copy_ref.mapping.owner_h == orig_ref.mapping.owner_h))) begin
        frozen = null;
        return invalid_state(
          "register MR backing reference snapshot is not deeply detached"
        );
      end
    end
    foreach (frozen.hmc_refs[i]) begin
      if (frozen.hmc_refs[i] == null || backing.hmc_refs[i] == null ||
          frozen.hmc_refs[i] == backing.hmc_refs[i] ||
          frozen.hmc_refs[i].owner == backing.hmc_refs[i].owner) begin
        frozen = null;
        return invalid_state(
          "register MR HMC reference snapshot is not deeply detached"
        );
      end
    end
    return rdma_status::success();
  endfunction

  // 功能：深拷贝 owned MR 的 DMA request context，并确认 Function/owner 句柄均已分离。
  // 输入/输出及副作用：dma_context 只读；frozen 输出新副本，失败时为 null。
  // 失败/边界：clone 失败、类型不符或任一句柄仍共享时返回 INVALID_STATE。
  protected function rdma_status detach_dma_context(
    rdma_dma_request_context dma_context,
    output rdma_dma_request_context frozen
  );
    uvm_object cloned_object;

    frozen = null;
    cloned_object = dma_context.clone();
    if (cloned_object == null || !$cast(frozen, cloned_object) ||
        frozen == dma_context ||
        frozen.function_h == dma_context.function_h ||
        (dma_context.owner_h == null && frozen.owner_h != null) ||
        (dma_context.owner_h != null &&
         (frozen.owner_h == null || frozen.owner_h == dma_context.owner_h))) begin
      frozen = null;
      return invalid_state("owned MR DMA context snapshot is not deeply detached");
    end
    return rdma_status::success();
  endfunction

  // 功能：required_dma_direction 使用 access 计算并返回 rdma_dma_direction_e 结果；不修改对象字段或外部资源。
  // 输入/输出及副作用：access（输入）；required_dma_direction 读取 access 并使用输入参数和固定枚举/常量；函数返回 rdma_dma_direction_e，不取得调用方资源所有权。
  // 失败/边界：required_dma_direction 是只读访问器，按对象字段返回固定值；未覆盖枚举沿 default/类型默认分支返回，不改变对象和外部资源。
  protected function rdma_dma_direction_e required_dma_direction(
    rdma_rdma_access_t access
  );
    return (access.local_write || access.remote_write ||
            access.remote_atomic) ?
           RDMA_DMA_BIDIRECTIONAL : RDMA_DMA_DEVICE_READ;
  endfunction

  // 功能：validate_backing 校验 binding、request、backing、owner、required_ownership 与当前对象状态的一致性，并显式处理“register MR backing authority is incomplete”；“register MR backing descriptor is null”；“register MR backing validation returned null”；“register MR first PBL index exceeds 28 bits”；“register MR backing reference is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：binding（输入）、request（输入）、backing（输入）、owner（输入）、required_ownership（输入）；validate_backing 读取 binding、request、backing、owner、required_ownership 并使用字段 status、required_permissions、required_permissions.device_read、required_permissions.device_write、required_permissions.atomic、required_direction；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：必需对象/句柄/快照为空，或身份、范围、generation 和生命周期检查失败时返回非成功状态。
  protected function rdma_status validate_backing(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_function_handle owner,
    rdma_resource_ownership_e required_ownership
  );
    rdma_dma_permission_t required_permissions;
    rdma_dma_direction_e required_direction;
    rdma_status status;
    longint unsigned lease_size;

    if (binding == null || request == null || owner == null)
      return invalid_state("register MR backing authority is incomplete");
    if (backing == null)
      return invalid_argument("register MR backing descriptor is null");
    status = backing.validate();
    if (status == null)
      return invalid_state("register MR backing validation returned null");
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    if (backing.page_layout.pbl_mode == RDMA_MR_PBL2 &&
        backing.page_layout.first_pbl_index > 28'hfff_ffff)
      return invalid_argument("register MR first PBL index exceeds 28 bits");
    status = same_owner_status(backing.function_h, owner,
                               "register MR backing");
    if (status == null || !status.ok())
      return checked_status(status,
                            "register MR backing owner check returned null");
    if (backing.requester_bdf != binding.queue_dma.requester_bdf)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "register MR backing requester BDF does not match Function"
      );
    if (backing.pasid_valid != binding.queue_dma.pasid_valid ||
        backing.pasid != binding.queue_dma.pasid)
      return rdma_status::make(
        RDMA_SC_DMA_TRANSLATION,
        "register MR backing PASID does not match Function"
      );
    required_permissions = '0;
    required_permissions.device_read = 1'b1;
    required_permissions.device_write = request.access.local_write ||
                                        request.access.remote_write ||
                                        request.access.remote_atomic;
    required_permissions.atomic = request.access.remote_atomic;
    required_direction = required_dma_direction(request.access);
    foreach (backing.backing_refs[i]) begin
      if (backing.backing_refs[i] == null ||
          backing.backing_refs[i].mapping == null)
        return invalid_argument("register MR backing reference is null");
      if (backing.backing_refs[i].ownership != required_ownership)
        return invalid_argument("register MR backing ownership is invalid");
      if (backing.backing_refs[i].mapping.pasid_valid !=
            backing.pasid_valid ||
          (backing.pasid_valid &&
           backing.backing_refs[i].mapping.pasid != backing.pasid))
        return rdma_status::make(
          RDMA_SC_DMA_TRANSLATION,
          "register MR backing PASID does not match mapping"
        );
      status = backing.backing_refs[i].mapping.check_access(
        owner, backing.requester_bdf, backing.pasid_valid, backing.pasid,
        binding.queue_dma.dma_domain_valid,
        binding.queue_dma.dma_domain_id, request.iova, request.length,
        required_direction, required_permissions
      );
      if (status == null)
        return invalid_state("register MR mapping access returned null");
      if (!status.ok())
        return rdma_cmq_clone_status_value(status);
    end
    foreach (backing.hmc_refs[i]) begin
      if (backing.hmc_refs[i] == null)
        return invalid_argument("register MR HMC reference is null");
      if (backing.hmc_refs[i].ownership != required_ownership)
        return invalid_argument("register MR HMC ownership is invalid");
      status = same_owner_status(backing.hmc_refs[i].owner, owner,
                                 "register MR HMC backing");
      if (status == null || !status.ok())
        return checked_status(
          status, "register MR HMC owner check returned null"
        );
      if (hmc_allocator == null)
        return invalid_state("register MR HMC allocator is unavailable");
      status = hmc_allocator.lookup(
        owner, backing.hmc_refs[i].object_kind,
        backing.hmc_refs[i].address, lease_size
      );
      if (status == null)
        return invalid_state("register MR HMC lookup returned null");
      if (!status.ok())
        return rdma_cmq_clone_status_value(status);
      if (lease_size != backing.hmc_refs[i].size)
        return invalid_argument("register MR HMC lease size does not match");
    end
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_control_plane 中，project_handle 从输入对象提取受控字段并返回 detached 投影，阻断调用方通过别名修改 authority。
  // 输入/输出及副作用：software_h（输入）、local_id（输入）、expected_kind（输入）；project_handle 读取 software_h、local_id、expected_kind 并使用字段 projected、projected.kind、projected.function_uid、projected.object_id、projected.generation；函数返回 rdma_handle，不取得调用方资源所有权。
  // 失败/边界：project_handle 输入对象为空或查找未命中时返回 null；该路径不隐式重试，也不转移未声明资源。
  protected function rdma_handle project_handle(
    rdma_handle software_h,
    int unsigned local_id,
    rdma_resource_kind_e expected_kind
  );
    rdma_handle projected;

    if (software_h == null || software_h.kind != expected_kind)
      return null;
    projected = new("control_plane_hw_projection");
    projected.kind = expected_kind;
    projected.function_uid = software_h.function_uid;
    projected.object_id = local_id;
    projected.generation = software_h.generation;
    return projected;
  endfunction

  // 功能：pd_handle_owner_status 校验 pd_h、owner 与当前对象状态的一致性，并显式处理“destroy PD handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：pd_h（输入）、owner（输入）；pd_handle_owner_status 读取 pd_h、owner 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：pd_handle_owner_status 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“destroy PD handle is null”“destroy PD handle kind is not PD”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status pd_handle_owner_status(
    rdma_handle pd_h,
    rdma_function_handle owner
  );
    if (pd_h == null)
      return invalid_argument("destroy PD handle is null");
    if (pd_h.kind != RDMA_RESOURCE_PD)
      return invalid_argument("destroy PD handle kind is not PD");
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("destroy PD Function owner is invalid");
    if (pd_h.function_uid != owner.function_uid)
      return invalid_argument("destroy PD belongs to another Function");
    if (pd_h.generation != owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "destroy PD Function generation is stale"
      );
    return rdma_status::success();
  endfunction

  // 功能：mr_handle_owner_status 校验 mr_h、owner 与当前对象状态的一致性，并显式处理“deregister MR handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：mr_h（输入）、owner（输入）；mr_handle_owner_status 读取 mr_h、owner 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：mr_handle_owner_status 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；典型拒绝条件为“deregister MR handle is null”“deregister MR handle kind is not MR”；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status mr_handle_owner_status(
    rdma_handle mr_h,
    rdma_function_handle owner
  );
    if (mr_h == null)
      return invalid_argument("deregister MR handle is null");
    if (mr_h.kind != RDMA_RESOURCE_MR)
      return invalid_argument("deregister MR handle kind is not MR");
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state("deregister MR Function owner is invalid");
    if (mr_h.function_uid != owner.function_uid)
      return invalid_argument("deregister MR belongs to another Function");
    if (mr_h.generation != owner.generation)
      return rdma_status::make(
        RDMA_SC_STALE_GENERATION,
        "deregister MR Function generation is stale"
      );
    return rdma_status::success();
  endfunction

  // 功能：在 rdma_control_plane 中，function_key 把 Function/对象身份、代际和游标字段拼成稳定的查找键，供登记表去重和恢复路由使用。
  // 输入/输出及副作用：owner（输入）；function_key 读取 owner 并使用输入参数和固定枚举/常量；函数返回 string，不取得调用方资源所有权。
// 失败/边界：function_key 只按函数体列出的身份、generation、kind、object_id 或 cursor 字段拼接键；调用方须先完成空句柄校验，函数本身不分配资源、不自动回退到 root0。
  protected function string function_key(rdma_function_handle owner);
    return $sformatf("%016h:%08h", owner.function_uid, owner.object_id);
  endfunction

  // 功能：在 rdma_control_plane 中，reserve_transaction_id 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：transaction_id（输出）、status（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  protected task reserve_transaction_id(
    output longint unsigned transaction_id,
    output rdma_status status
  );
    transaction_id = 0;
    status = invalid_state("transaction ID allocation did not complete");
    // Keep the uncontended guard off the blocking scheduler; a failed fast
    // path still uses get() and preserves real contention semantics.
    if (!lock_table_guard.try_get(1))
      lock_table_guard.get(1);
    if (transaction_ids_exhausted) begin
      status = rdma_status::make(
        RDMA_SC_RESOURCE_EXHAUSTED,
        "control-plane transaction ID space is exhausted"
      );
    end
    else begin
      transaction_id = next_transaction_id;
      if (next_transaction_id == 64'hffff_ffff_ffff_ffff)
        transaction_ids_exhausted = 1'b1;
      else
        next_transaction_id++;
      status = rdma_status::success();
    end
    lock_table_guard.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，acquire_function_lock 检查容量后预留资源并返回带 owner 证据的句柄/计划；失败时回滚已登记的局部状态。
  // 输入/输出及副作用：owner（输入）、function_lock（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：容量不足、范围非法、重复占用或身份过期时返回错误；失败不得泄漏半分配资源。
  protected task acquire_function_lock(
    rdma_function_handle owner,
    output semaphore function_lock
  );
    string key;

    function_lock = null;
    key = function_key(owner);
    // Keep the uncontended guard off the blocking scheduler; a failed fast
    // path still uses get() and preserves real contention semantics.
    if (!lock_table_guard.try_get(1))
      lock_table_guard.get(1);
    if (!function_locks.exists(key))
      function_locks[key] = new(1);
    function_lock = function_locks[key];
    lock_table_guard.put(1);
    function_lock.get(1);
  endtask

  // 功能：在 rdma_control_plane 中，configure 校验依赖和 binding 后建立运行边界，只保存非拥有引用并拒绝重复配置。
  // 输入/输出及副作用：resource_manager（输入）、cmq_port（输入）、key_policy（输入）、host_mem（输入）、hmc_allocator（输入）、context_backing（输入）、command_timeout（输入）；configure 先依据 configured；resource_manager == null；cmq_port == null 校验 resource_manager、cmq_port、key_policy、host_mem、hmc_allocator、context_backing、command_timeout；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   rdma_status。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  function rdma_status configure(
    rdma_resource_manager resource_manager,
    rdma_cmq_port cmq_port,
    rdma_stag_key_policy key_policy,
    rdma_host_mem_api host_mem = null,
    rdma_hmc_allocator hmc_allocator = null,
    rdma_context_backing_api context_backing = null,
    time command_timeout = 1us
  );
    rdma_status status;

    if (configured)
      return invalid_state("control plane is already configured");
    if (resource_manager == null)
      return invalid_argument("resource manager is null");
    if (cmq_port == null)
      return invalid_argument("CMQ port is null");
    if (key_policy == null)
      return invalid_argument("STAG key policy is null");
    if (command_timeout == 0)
      return invalid_argument("default control-plane timeout is zero");

    this.manager = resource_manager;
    this.cmq = cmq_port;
    this.key_policy = key_policy;
    this.host_mem = host_mem;
    this.hmc_allocator = hmc_allocator;
    this.context_backing = context_backing;
    default_timeout = command_timeout;
    queue_executor = rdma_queue_lifecycle_executor::type_id::create(
      "control_plane_queue_executor"
    );
    if (queue_executor == null)
      return invalid_state("queue lifecycle executor construction failed");
    status = queue_executor.configure(
      resource_manager, cmq_port, host_mem, context_backing, command_timeout
    );
    status = checked_status(status, "queue executor configure returned null");
    if (!status.ok()) begin
      queue_executor = null;
      return status;
    end
    qp_executor = rdma_qp_lifecycle_executor::type_id::create(
      "control_plane_qp_executor"
    );
    if (qp_executor == null)
      return invalid_state("QP lifecycle executor construction failed");
    if (host_mem != null && context_backing != null) begin
      status = qp_executor.configure(
        resource_manager, cmq_port, host_mem, context_backing, command_timeout
      );
      status = checked_status(status, "QP executor configure returned null");
      if (!status.ok()) begin
        qp_executor = null;
        return status;
      end
    end
    configured = 1'b1;
    return rdma_status::success();
  endfunction

  // 功能：queue_request_status 校验 request、owner、label 与当前对象状态的一致性，并显式处理“request is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：request（输入）、owner（输入）、label（输入）；queue_request_status 读取 request、owner、label 并使用字段 status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：queue_request_status 返回 RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status queue_request_status(
    rdma_semantic_request request,
    rdma_function_handle owner,
    string label
  );
    rdma_status status;

    if (request == null)
      return invalid_argument({label, " request is null"});
    status = request.validate();
    if (status == null)
      return invalid_state({label, " request validation returned null"});
    if (!status.ok())
      return rdma_cmq_clone_status_value(status);
    return same_owner_status(request.owner, owner, label);
  endfunction

  // 功能：queue_target_owner_status 校验 target、owner、label 与当前对象状态的一致性，并显式处理“target handle is null”等拒绝条件，返回 rdma_status 供上层决定是否提交。
  // 输入/输出及副作用：target（输入）、owner（输入）、label（输入）；queue_target_owner_status 读取 target、owner、label 并使用字段 rdma_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：queue_target_owner_status 返回 RDMA_SC_STALE_GENERATION、RDMA_SC_INVALID_ARGUMENT、RDMA_SC_INVALID_STATE；失败路径不提交部分状态或转移未声明资源。
  protected function rdma_status queue_target_owner_status(
    rdma_handle target,
    rdma_function_handle owner,
    string label
  );
    if (target == null)
      return invalid_argument({label, " target handle is null"});
    if (owner == null || owner.kind != RDMA_RESOURCE_FUNCTION)
      return invalid_state({label, " Function owner is invalid"});
    if (target.function_uid != owner.function_uid)
      return invalid_argument({label, " target belongs to another Function"});
    if (target.generation != owner.generation)
      return rdma_status::make(RDMA_SC_STALE_GENERATION,
                               {label, " target generation is stale"});
    return rdma_status::success();
  endfunction

  // 功能：create_queue_facade 创建独立的 无直接返回值；根据 binding、request、requires_context、expected_kind、queue、result 设置字段 queue、result、function_lock、result.transaction_id、status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、request（输入）、requires_context（输入）、expected_kind（输入）、queue（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或
  //   output 发布新句柄/映射。
  // 失败/边界：create_queue_facade 失败或超时通过 queue、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  protected task create_queue_facade(
    rdma_function_binding binding,
    rdma_semantic_request request,
    bit requires_context,
    rdma_resource_kind_e expected_kind,
    output rdma_queue_resource queue,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    queue = null;
    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue transaction ID allocation returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue control-plane configuration check returned null");
        break;
      end
      if (queue_executor == null) begin
        status = invalid_state("queue lifecycle executor is unavailable");
        break;
      end
      if (host_mem == null) begin
        status = invalid_state("queue create requires a host-memory adapter");
        break;
      end
      if (requires_context && context_backing == null) begin
        status = invalid_state(
          "CQ/SRQ queue create requires a context-backing adapter"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue Function binding check returned null");
        break;
      end
      status = queue_request_status(request, owner, "queue create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue create request check returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue Function check returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock queue Function");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue Function identity returned null");
        break;
      end
      status = queue_request_status(request, locked_owner,
                                    "post-lock queue create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue request check returned null");
        break;
      end
      queue_executor.create_locked(binding, owner, request, transaction_id,
                                   queue, result);
      if (result != null && result.ok() &&
          (queue == null || queue.resource_kind() != expected_kind)) begin
        queue = null;
        status = invalid_state("queue executor returned the wrong resource kind");
        finish_result(result, status);
        break;
      end
      status = (result == null) ?
        invalid_state("queue executor returned a null result") :
        rdma_cmq_clone_status_value(result.status);
      if (status == null)
        status = invalid_state("queue executor result status is null");
      break;
    end while (1'b0);
    if (result == null)
      result = make_result();
    if (status == null || !status.ok()) begin
      queue = null;
      finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，destroy_queue_facade 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、expected_kind（输入）、result（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按
  //   adapter 契约释放。
  // 失败/边界：destroy_queue_facade 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected task destroy_queue_facade(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    rdma_resource_kind_e expected_kind,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy transaction ID returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy configuration check returned null");
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy Function check returned null");
        break;
      end
      status = queue_request_status(request, owner, "queue destroy request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "queue destroy request check returned null");
        break;
      end
      if (request.target_h.kind != expected_kind) begin
        status = invalid_argument("queue destroy target kind is invalid");
        break;
      end
      status = queue_target_owner_status(request.target_h, owner,
                                         "queue destroy target");
      if (status == null || !status.ok()) break;

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock queue destroy Function returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock queue destroy Function");
      if (status == null || !status.ok()) break;
      if (request.target_h.kind != expected_kind) begin
        status = invalid_argument("post-lock queue destroy target kind is invalid");
        break;
      end
      status = queue_target_owner_status(request.target_h, locked_owner,
                                         "post-lock queue destroy target");
      if (status == null || !status.ok()) break;
      queue_executor.destroy_locked(binding, owner, request,
                                    transaction_id, result);
      status = (result == null) ?
        invalid_state("queue destroy executor returned null result") :
        rdma_cmq_clone_status_value(result.status);
      break;
    end while (1'b0);
    if (status == null || !status.ok())
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：create_cq 创建独立的 无直接返回值；根据 binding、request、cq、result 设置字段 cq，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、request（输入）、cq（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_cq 失败或超时通过 cq、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task create_cq(
    rdma_function_binding binding,
    rdma_create_cq_req request,
    output rdma_cq cq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    cq = null;
    create_queue_facade(binding, request, 1'b1, RDMA_RESOURCE_CQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(cq, queue) || cq == null || cq.state != RDMA_RESOURCE_ACTIVE) begin
        cq = null;
        finish_result(result, invalid_state("typed CQ projection is invalid"));
      end
    end
  endtask

  // 功能：create_srq 创建独立的 无直接返回值；根据 binding、request、srq、result 设置字段 srq，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、request（输入）、srq（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_srq 失败或超时通过 srq、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task create_srq(
    rdma_function_binding binding,
    rdma_create_srq_req request,
    output rdma_srq srq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    srq = null;
    create_queue_facade(binding, request, 1'b1, RDMA_RESOURCE_SRQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(srq, queue) || srq == null || srq.state != RDMA_RESOURCE_ACTIVE) begin
        srq = null;
        finish_result(result, invalid_state("typed SRQ projection is invalid"));
      end
    end
  endtask

  // 功能：create_ceq 创建独立的 无直接返回值；根据 binding、request、ceq、result 设置字段 ceq，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、request（输入）、ceq（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_ceq 失败或超时通过 ceq、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task create_ceq(
    rdma_function_binding binding,
    rdma_create_ceq_req request,
    output rdma_ceq ceq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    ceq = null;
    create_queue_facade(binding, request, 1'b0, RDMA_RESOURCE_CEQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(ceq, queue) || ceq == null || ceq.state != RDMA_RESOURCE_ACTIVE) begin
        ceq = null;
        finish_result(result, invalid_state("typed CEQ projection is invalid"));
      end
    end
  endtask

  // 功能：create_aeq 创建独立的 无直接返回值；根据 binding、request、aeq、result 设置字段 aeq，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、request（输入）、aeq（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_aeq 失败或超时通过 aeq、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task create_aeq(
    rdma_function_binding binding,
    rdma_create_aeq_req request,
    output rdma_aeq aeq,
    output rdma_control_result result
  );
    rdma_queue_resource queue;
    aeq = null;
    create_queue_facade(binding, request, 1'b0, RDMA_RESOURCE_AEQ, queue, result);
    if (result != null && result.ok()) begin
      if (!$cast(aeq, queue) || aeq == null || aeq.state != RDMA_RESOURCE_ACTIVE) begin
        aeq = null;
        finish_result(result, invalid_state("typed AEQ projection is invalid"));
      end
    end
  endtask

  // 功能：create_qp 创建独立的 无直接返回值；根据 binding、request、qp、result 设置字段 qp、result、function_lock、executor_called、result.transaction_id、status、qp_validation_status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、request（输入）、qp（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_qp 失败或超时通过 qp、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task create_qp(
    rdma_function_binding binding,
    rdma_create_qp_req request,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    rdma_status qp_validation_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit executor_called;

    qp = null;
    result = make_result();
    function_lock = null;
    executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP transaction ID allocation returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP control-plane configuration returned null");
        break;
      end
      if (host_mem == null || context_backing == null) begin
        status = invalid_state(
          "QP create requires host-memory and context-backing adapters"
        );
        break;
      end
      if (qp_executor == null) begin
        status = invalid_state("QP lifecycle executor is unavailable");
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP Function binding returned null");
        break;
      end
      status = queue_request_status(request, owner, "QP create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP create request returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP Function returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock QP Function");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP identity returned null");
        break;
      end
      status = queue_request_status(request, locked_owner,
                                    "post-lock QP create request");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP request returned null");
        break;
      end

      executor_called = 1'b1;
      qp_executor.create_locked(binding, owner, request, transaction_id,
                                qp, result);
      if (result == null) begin
        status = invalid_state("QP executor returned a null result");
        break;
      end
      if (result.transaction_id != transaction_id) begin
        qp = null;
        status = invalid_state("QP executor changed the transaction ID");
        finish_result(result, status);
        break;
      end
      status = checked_status(result.status,
                              "QP executor result status is null");
      if (status.ok()) begin
        qp_validation_status = qp == null ? null : qp.validate();
        if (qp == null || qp.state != RDMA_RESOURCE_ACTIVE ||
            qp.qp_state != RDMA_QPS_RESET || qp_validation_status == null ||
            !qp_validation_status.ok()) begin
          qp = null;
          status = invalid_state("typed QP projection is invalid");
          finish_result(result, status);
        end
      end
      break;
    end while (1'b0);
    if (result == null) begin
      result = make_result();
      result.transaction_id = transaction_id;
    end
    if (status == null || !status.ok()) begin
      qp = null;
      if (!executor_called)
        finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，modify_qp 在代际和状态机保护下修改 QP 上下文，提交硬件命令后才发布新的软件状态。
  // 输入/输出及副作用：binding（输入）、request（输入）、qp（输出）、result（输出）；modify_qp 驱动下游事务，并写入 qp、result；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：modify_qp 失败或超时通过 qp、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task modify_qp(
    rdma_function_binding binding,
    rdma_modify_qp_req request,
    output rdma_qp qp,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_status status;
    rdma_status qp_validation_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit executor_called;

    qp = null;
    result = make_result();
    function_lock = null;
    executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP modify transaction ID allocation returned null");
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "QP modify control-plane configuration returned null");
        break;
      end
      if (host_mem == null || context_backing == null || qp_executor == null) begin
        status = invalid_state("QP modify requires a configured QP executor");
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP modify Function binding returned null");
        break;
      end
      status = queue_request_status(request, owner, "QP modify request");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "QP modify request returned null");
        break;
      end
      status = queue_target_owner_status(request.qp_h, owner,
                                         "QP modify target");
      if (status == null || !status.ok()) break;

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "post-lock QP modify Function returned null");
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock QP modify Function");
      if (status == null || !status.ok()) break;
      status = queue_request_status(request, locked_owner,
                                    "post-lock QP modify request");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "post-lock QP modify request returned null");
        break;
      end
      status = queue_target_owner_status(request.qp_h, locked_owner,
                                         "post-lock QP modify target");
      if (status == null || !status.ok()) break;

      executor_called = 1'b1;
      qp_executor.modify_locked(binding, owner, request, transaction_id,
                                qp, result);
      if (result == null) begin
        status = invalid_state("QP modify executor returned a null result");
        break;
      end
      if (result.transaction_id != transaction_id) begin
        qp = null;
        status = invalid_state("QP modify executor changed the transaction ID");
        finish_result(result, status);
        break;
      end
      status = checked_status(result.status,
                              "QP modify executor result status is null");
      if (status.ok()) begin
        qp_validation_status = qp == null ? null : qp.validate();
        if (qp == null || qp.state != RDMA_RESOURCE_ACTIVE ||
            qp_validation_status == null || !qp_validation_status.ok()) begin
          qp = null;
          status = invalid_state("typed QP modify projection is invalid");
          finish_result(result, status);
        end
      end
      break;
    end while (1'b0);
    if (result == null) begin
      result = make_result();
      result.transaction_id = transaction_id;
    end
    if (status == null || !status.ok()) begin
      qp = null;
      if (!executor_called)
        finish_result(result, status);
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，destroy_qp 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、result（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_qp 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  task destroy_qp(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    rdma_function_handle owner, locked_owner;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit executor_called;
    result = make_result(); function_lock = null; executor_called = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    do begin
      if (status == null || !status.ok()) begin status = checked_status(status,
        "QP destroy transaction ID allocation returned null"); break; end
      status = configured_status(); if (status == null || !status.ok()) begin
        status = checked_status(status, "QP destroy control-plane configuration returned null"); break; end
      status = binding_owner_status(binding, owner); if (status == null || !status.ok()) begin
        status = checked_status(status, "QP destroy Function binding returned null"); break; end
      status = queue_request_status(request, owner, "QP destroy request");
      if (status == null || !status.ok()) begin status = checked_status(status, "QP destroy request returned null"); break; end
      if (request.target_h.kind != RDMA_RESOURCE_QP) begin status = invalid_argument("QP destroy target kind is invalid"); break; end
      status = queue_target_owner_status(request.target_h, owner, "QP destroy target"); if (status == null || !status.ok()) break;
      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner); if (status == null || !status.ok()) break;
      status = same_owner_status(locked_owner, owner, "post-lock QP destroy Function"); if (status == null || !status.ok()) break;
      status = queue_target_owner_status(request.target_h, locked_owner, "post-lock QP destroy target"); if (status == null || !status.ok()) break;
      executor_called = 1'b1;
      qp_executor.destroy_locked(binding, owner, request, transaction_id, result);
      if (result == null) status = invalid_state("QP destroy executor returned null result");
      else if (result.transaction_id != transaction_id) begin status = invalid_state("QP destroy executor changed transaction ID"); finish_result(result, status); end
      else status = checked_status(result.status, "QP destroy executor result status is null");
      break;
    end while (1'b0);
    if (result == null) begin result = make_result(); result.transaction_id = transaction_id; end
    if ((status == null || !status.ok()) && !executor_called) finish_result(result, status);
    if (function_lock != null) function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，destroy_cq 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、result（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_cq 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  task destroy_cq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_CQ, result);
  endtask

  // 功能：在 rdma_control_plane 中，destroy_srq 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、result（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_srq 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  task destroy_srq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_SRQ, result);
  endtask

  // 功能：在 rdma_control_plane 中，destroy_ceq 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、result（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_ceq 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  task destroy_ceq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_CEQ, result);
  endtask

  // 功能：在 rdma_control_plane 中，destroy_aeq 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、result（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_aeq 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  task destroy_aeq(
    rdma_function_binding binding,
    rdma_destroy_resource_req request,
    output rdma_control_result result
  );
    destroy_queue_facade(binding, request, RDMA_RESOURCE_AEQ, result);
  endtask

  // 功能：create_pd 创建独立的 无直接返回值；根据 binding、request、pd、result 设置字段 pd、result、function_lock、result.transaction_id、status、result.resource_h、result.final_resource_state、result.final_resource_state_known、rollback_status，返回对象仅由调用方持有，不转移外部资源所有权。
  // 输入/输出及副作用：binding（输入）、request（输入）、pd（输出）、result（输出）；输入请求/句柄定义资源属性；成功时更新账本并通过返回值或 output 发布新句柄/映射。
  // 失败/边界：create_pd 失败或超时通过 pd、result 明确发布；该路径不隐式重试，也不转移未声明资源。
  task create_pd(
    rdma_function_binding binding,
    rdma_create_pd_req request,
    output rdma_pd pd,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_pd reserved_pd;
    rdma_resource active_resource;
    rdma_status status;
    rdma_status rollback_status;
    semaphore function_lock;
    longint unsigned transaction_id;

    pd = null;
    result = make_result();
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      status = request_status(request, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "create PD request check returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock Function binding check returned null"
        );
        break;
      end
      status = same_owner_status(
        locked_owner, owner, "post-lock create PD binding"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock Function identity check returned null"
        );
        break;
      end
      status = request_status(request, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock create PD request check returned null"
        );
        break;
      end
      status = manager.create_pd(binding, reserved_pd);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager create PD returned null");
        break;
      end
      if (reserved_pd == null || reserved_pd.handle == null ||
          reserved_pd.state != RDMA_RESOURCE_ALLOCATED) begin
        status = invalid_state(
          "resource manager returned an invalid PD reservation"
        );
        if (reserved_pd != null && reserved_pd.handle != null) begin
          result.resource_h = snapshot_handle(reserved_pd.handle);
          result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
          result.final_resource_state_known = 1'b1;
          rollback_status = manager.release_reserved(reserved_pd.handle);
          rollback_status = checked_status(
            rollback_status, "PD reservation rollback returned null"
          );
          if (rollback_status.ok()) begin
            result.final_resource_state = RDMA_RESOURCE_RELEASED;
          end
          else
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(rollback_status)
            );
        end
        break;
      end
      result.resource_h = snapshot_handle(reserved_pd.handle);
      result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);

      status = manager.activate(reserved_pd.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager PD activate returned null");
        rollback_status = manager.release_reserved(reserved_pd.handle);
        rollback_status = checked_status(
          rollback_status, "PD reservation rollback returned null"
        );
        if (rollback_status.ok()) begin
          result.final_resource_state = RDMA_RESOURCE_RELEASED;
        end
        else begin
          result.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(rollback_status)
          );
        end
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);

      status = manager.lookup(reserved_pd.handle, active_resource);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager active PD lookup returned null"
        );
        cleanup_activated_pd(reserved_pd.handle, result);
        break;
      end
      if (!$cast(pd, active_resource) || pd == null || pd.handle == null ||
          pd.state != RDMA_RESOURCE_ACTIVE) begin
        pd = null;
        status = invalid_state(
          "resource manager active PD snapshot is invalid"
        );
        cleanup_activated_pd(reserved_pd.handle, result);
        break;
      end
      result.resource_h = snapshot_handle(pd.handle);
      status = rdma_status::success();
    end while (1'b0);

    finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，destroy_pd 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：binding（输入）、pd_h（输入）、result（输出）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_pd 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  task destroy_pd(
    rdma_function_binding binding,
    rdma_handle pd_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_resource resource;
    rdma_pd pd_snapshot;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;

    result = make_result();
    result.resource_h = snapshot_handle(pd_h);
    function_lock = null;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      status = pd_handle_owner_status(pd_h, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "destroy PD handle check returned null");
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = manager.lookup(pd_h, resource);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager PD lookup returned null");
        break;
      end
      if (!$cast(pd_snapshot, resource) || pd_snapshot == null ||
          pd_snapshot.handle == null || pd_snapshot.owner == null) begin
        status = invalid_state("resource manager PD snapshot is invalid");
        break;
      end
      result.resource_h = snapshot_handle(pd_snapshot.handle);
      result.final_resource_state = pd_snapshot.state;
      result.final_resource_state_known = 1'b1;
      status = same_owner_status(pd_snapshot.owner, owner, "destroy PD");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "destroy PD owner check returned null");
        break;
      end
      if (pd_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("destroy PD requires an ACTIVE PD");
        break;
      end

      status = manager.begin_quiesce(pd_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager PD quiesce returned null"
        );
        result.final_resource_state = RDMA_RESOURCE_ACTIVE;
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_QUIESCING;

      status = manager.finalize_release(pd_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager PD release returned null"
        );
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
      status = rdma_status::success();
    end while (1'b0);

    finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，deregister_mr 按 owner、generation 和幂等规则释放或清理资源，同时删除相关账本记录。
  // 输入/输出及副作用：binding（输入）、mr_h（输入）、result（输出）；deregister_mr 驱动下游事务，并写入 result；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：deregister_mr 返回 RDMA_SC_RESOURCE_BUSY；典型拒绝条件为“deregister MR has outstanding operations”；失败路径不提交部分状态或转移未声明资源。
  task deregister_mr(
    rdma_function_binding binding,
    rdma_handle mr_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_resource resource;
    rdma_mr mr_snapshot;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status primary_status;
    rdma_status cleanup_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit result_finalized;

    result = make_result();
    result.resource_h = snapshot_handle(mr_h);
    function_lock = null;
    result_finalized = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR transaction ID allocation returned null"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR Function check returned null"
        );
        break;
      end
      status = generation_fence(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "initial deregister MR generation fence returned null"
        );
        break;
      end
      status = mr_handle_owner_status(mr_h, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR handle check returned null"
        );
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock deregister MR Function check returned null"
        );
        break;
      end
      status = generation_fence(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock deregister MR generation fence returned null"
        );
        break;
      end
      status = mr_handle_owner_status(mr_h, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock deregister MR handle check returned null"
        );
        break;
      end
      status = manager.lookup(mr_h, resource);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager deregister MR lookup returned null"
        );
        break;
      end
      if (!$cast(mr_snapshot, resource) || mr_snapshot == null ||
          mr_snapshot.handle == null || mr_snapshot.owner == null) begin
        status = invalid_state(
          "resource manager deregister MR snapshot is invalid"
        );
        break;
      end
      result.resource_h = snapshot_handle(mr_snapshot.handle);
      result.final_resource_state = mr_snapshot.state;
      result.final_resource_state_known = 1'b1;
      status = same_owner_status(
        mr_snapshot.owner, locked_owner, "deregister MR"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "deregister MR owner check returned null"
        );
        break;
      end
      if (mr_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("deregister MR requires an ACTIVE MR");
        break;
      end
      if (mr_snapshot.outstanding_ids.size() != 0) begin
        status = rdma_status::make(
          RDMA_SC_RESOURCE_BUSY,
          "deregister MR has outstanding operations"
        );
        break;
      end

      status = manager.begin_quiesce(mr_snapshot.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager MR quiesce returned null"
        );
        result.final_resource_state = RDMA_RESOURCE_ACTIVE;
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_QUIESCING;

      if (mr_snapshot.hmc_refs.size() != 0) begin
        command = make_mr_hw_command(locked_owner, mr_snapshot,
                                     RDMA_CTRL_STEP_HW_OCC_FLUSHED,
                                     "deregister_mr_occ_flush");
        execute_control_command(
          command, ticket, completion, status,
          "OCC_FLUSH execution returned null"
        );
        if (!status.ok()) begin
          primary_status = rdma_cmq_clone_status_value(status);
          if (status.code == RDMA_SC_TIMEOUT) begin
            retain_mr_destroy_error(
              mr_snapshot, primary_status, result,
              RDMA_HW_PRESENCE_UNKNOWN, 1'b1,
              RDMA_CTRL_STEP_HW_OCC_FLUSHED, ticket, result_finalized
            );
          end
          else begin
            cleanup_status = manager.restore_active(mr_snapshot.handle);
            cleanup_status = checked_status(
              cleanup_status, "OCC failure restore ACTIVE returned null"
            );
            if (cleanup_status.ok()) begin
              result.final_resource_state = RDMA_RESOURCE_ACTIVE;
              status = primary_status;
            end
            else begin
              result.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(cleanup_status)
              );
              retain_mr_destroy_error(
                mr_snapshot, primary_status, result,
                RDMA_HW_PRESENCE_PRESENT, 1'b1,
                RDMA_CTRL_STEP_HW_OCC_FLUSHED, null, result_finalized
              );
            end
          end
          break;
        end
        result.completed_steps.push_back(RDMA_CTRL_STEP_HW_OCC_FLUSHED);
        status = generation_fence(binding, locked_owner);
        status = checked_status(
          status, "post-OCC_FLUSH generation fence returned null"
        );
        if (!status.ok()) begin
          primary_status = rdma_cmq_clone_status_value(status);
          retain_mr_destroy_error(
            mr_snapshot, primary_status, result,
            RDMA_HW_PRESENCE_PRESENT, 1'b1,
            RDMA_CTRL_STEP_HW_MR_DEREGISTERED, null, result_finalized
          );
          break;
        end
      end

      command = make_mr_hw_command(locked_owner, mr_snapshot,
                                   RDMA_CTRL_STEP_HW_MR_DEREGISTERED,
                                   "deregister_mr_command");
      execute_control_command(
        command, ticket, completion, status,
        "MR_DEREGISTER execution returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        if (status.code == RDMA_SC_TIMEOUT) begin
          retain_mr_destroy_error(
            mr_snapshot, primary_status, result,
            RDMA_HW_PRESENCE_UNKNOWN, 1'b1,
            RDMA_CTRL_STEP_HW_MR_DEREGISTERED, ticket, result_finalized
          );
        end
        else begin
          cleanup_status = manager.restore_active(mr_snapshot.handle);
          cleanup_status = checked_status(
            cleanup_status,
            "MR_DEREGISTER failure restore ACTIVE returned null"
          );
          if (cleanup_status.ok()) begin
            result.final_resource_state = RDMA_RESOURCE_ACTIVE;
            status = primary_status;
          end
          else begin
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(cleanup_status)
            );
            retain_mr_destroy_error(
              mr_snapshot, primary_status, result,
              RDMA_HW_PRESENCE_PRESENT, 1'b1,
              RDMA_CTRL_STEP_HW_MR_DEREGISTERED, null,
              result_finalized
            );
          end
        end
        break;
      end
      result.completed_steps.push_back(
        RDMA_CTRL_STEP_HW_MR_DEREGISTERED
      );
      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "post-MR_DEREGISTER generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_HW_DRAINED, null, result_finalized
        );
        break;
      end

      command = make_mr_hw_command(locked_owner, mr_snapshot,
                                   RDMA_CTRL_STEP_HW_DRAINED,
                                   "deregister_mr_tq_flush");
      execute_control_command(
        command, ticket, completion, status,
        "TQ_FLUSH execution returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_HW_DRAINED,
          (status.code == RDMA_SC_TIMEOUT) ? ticket : null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_DRAINED);
      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "post-TQ_FLUSH generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null, result_finalized
        );
        break;
      end

      for (int i = int'(mr_snapshot.hmc_refs.size()) - 1;
           i >= 0; i--) begin
        if (mr_snapshot.hmc_refs[i] == null) begin
          status = invalid_state("deregister MR HMC reference is null");
          break;
        end
        if (mr_snapshot.hmc_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            mr_snapshot.hmc_refs[i].release_complete)
          continue;
        if (hmc_allocator == null)
          status = invalid_state(
            "owned deregister MR HMC allocator is unavailable"
          );
        else
          status = hmc_allocator.\release (
            mr_snapshot.hmc_refs[i].owner,
            mr_snapshot.hmc_refs[i].object_kind,
            mr_snapshot.hmc_refs[i].address
          );
        status = checked_status(
          status, "owned deregister MR HMC release returned null"
        );
        if (!status.ok())
          break;
        mr_snapshot.hmc_refs[i].release_complete = 1'b1;
      end
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null,
          result_finalized
        );
        break;
      end

      for (int i = int'(mr_snapshot.backing_refs.size()) - 1;
           i >= 0; i--) begin
        if (mr_snapshot.backing_refs[i] == null ||
            mr_snapshot.backing_refs[i].mapping == null) begin
          status = invalid_state(
            "deregister MR backing reference is null"
          );
          break;
        end
        if (mr_snapshot.backing_refs[i].ownership !=
              RDMA_OWNERSHIP_CONTROL_PLANE ||
            mr_snapshot.backing_refs[i].release_complete)
          continue;
        if (host_mem == null)
          status = invalid_state(
            "owned deregister MR host memory is unavailable"
          );
        else
          status = host_mem.\release (
            mr_snapshot.backing_refs[i].mapping
          );
        status = checked_status(
          status, "owned deregister MR backing release returned null"
        );
        if (!status.ok())
          break;
        mr_snapshot.backing_refs[i].release_complete = 1'b1;
      end
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_BACKING_RELEASED, null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_RELEASED);

      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "pre-finalize MR generation fence returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null, result_finalized
        );
        break;
      end

      status = manager.finalize_release(mr_snapshot.handle);
      status = checked_status(
        status, "resource manager MR release returned null"
      );
      if (!status.ok()) begin
        primary_status = rdma_cmq_clone_status_value(status);
        retain_mr_destroy_error(
          mr_snapshot, primary_status, result, RDMA_HW_PRESENCE_ABSENT,
          1'b1, RDMA_CTRL_STEP_RESOURCE_RELEASED, null,
          result_finalized
        );
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RELEASED);
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized)
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，register_mr_internal 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、backing（输入）、required_ownership（输入）、supplied_transaction_id（输入）、supplied_function_lock（输入）、mr（输出）、result（输出）；register_mr_internal 先依据 transaction_id == 0；status == null || !status.ok(；function_lock == null 校验 binding、request、backing、required_ownership、supplied_transaction_id、supplied_function_lock、mr、result；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   无直接返回值。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  protected task register_mr_internal(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    rdma_resource_ownership_e required_ownership,
    longint unsigned supplied_transaction_id,
    semaphore supplied_function_lock,
    output rdma_mr mr,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_function_handle live_owner;
    rdma_register_mr_req frozen_request;
    rdma_mr_backing_desc frozen_backing;
    rdma_resource pd_resource;
    rdma_pd pd_snapshot;
    rdma_mr reserved_mr;
    rdma_resource active_resource;
    rdma_mrt_model mrt;
    rdma_cmq_command_desc command;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_recovery_record recovery;
    rdma_status status;
    semaphore function_lock;
    longint unsigned transaction_id;
    longint unsigned live_lease_size;
    bit [7:0] stag_key;
    bit has_remote_access;
    bit result_finalized;
    bit function_lock_acquired_here;

    mr = null;
    result = make_result();
    function_lock = supplied_function_lock;
    result_finalized = 1'b0;
    function_lock_acquired_here = 1'b0;
    transaction_id = supplied_transaction_id;
    if (transaction_id == 0)
      reserve_transaction_id(transaction_id, status);
    else
      status = rdma_status::success();
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      status = register_mr_input_status(binding, request, backing, owner,
                                        owner, required_ownership, "");
      if (!status.ok())
        break;

      if (function_lock == null) begin
        acquire_function_lock(owner, function_lock);
        function_lock_acquired_here = 1'b1;
      end
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock Function binding check returned null"
        );
        break;
      end
      status = register_mr_input_status(binding, request, backing, owner,
                                        locked_owner, required_ownership,
                                        "post-lock ");
      if (!status.ok())
        break;

      status = detach_mr_request(request, frozen_request);
      if (!status.ok())
        break;
      status = detach_mr_backing(backing, frozen_backing);
      if (!status.ok())
        break;
      status = register_mr_input_status(binding, frozen_request,
                                        frozen_backing, null, locked_owner,
                                        required_ownership, "snapshot ");
      if (!status.ok())
        break;

      status = manager.lookup(frozen_request.pd_h, pd_resource);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager PD lookup returned null");
        break;
      end
      if (!$cast(pd_snapshot, pd_resource) || pd_snapshot == null ||
          pd_snapshot.handle == null || pd_snapshot.owner == null ||
          pd_snapshot.state != RDMA_RESOURCE_ACTIVE) begin
        status = invalid_state("register MR requires an ACTIVE PD");
        break;
      end
      status = same_owner_status(pd_snapshot.owner, locked_owner,
                                 "register MR PD");
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "register MR PD owner check returned null");
        break;
      end

      status = manager.create_mr(binding, frozen_request.pd_h, reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager create MR returned null");
        break;
      end
      if (reserved_mr == null || reserved_mr.handle == null ||
          reserved_mr.state != RDMA_RESOURCE_ALLOCATED) begin
        status = invalid_state(
          "resource manager returned an invalid MR reservation"
        );
        break;
      end
      result.resource_h = snapshot_handle(reserved_mr.handle);
      result.final_resource_state = RDMA_RESOURCE_ALLOCATED;
      result.final_resource_state_known = 1'b1;
      result.completed_steps.push_back(RDMA_CTRL_STEP_RESOURCE_RESERVED);

      reserved_mr.iova = frozen_request.iova;
      reserved_mr.length = frozen_request.length;
      reserved_mr.access = frozen_request.access;
      reserved_mr.mr_serial = reserved_mr.handle.object_id[11:0];
      reserved_mr.backing_refs = frozen_backing.backing_refs;
      reserved_mr.hmc_refs = frozen_backing.hmc_refs;
      result.completed_steps.push_back(RDMA_CTRL_STEP_BACKING_ATTACHED);
      if (reserved_mr.hmc_refs.size() != 0)
        result.completed_steps.push_back(RDMA_CTRL_STEP_HMC_ATTACHED);
      status = key_policy.derive(reserved_mr, stag_key);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "STAG key policy returned null status");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end
      reserved_mr.lkey = {reserved_mr.local_mr_id[23:0], stag_key};
      has_remote_access = frozen_request.access.remote_read ||
                          frozen_request.access.remote_write ||
                          frozen_request.access.remote_atomic;
      reserved_mr.rkey = has_remote_access ? reserved_mr.lkey : 32'b0;
      status = manager.stage_allocated(reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager stage MR returned null");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end

      mrt = rdma_mrt_model::type_id::create("register_mr_mrt");
      mrt.mr_h = project_handle(reserved_mr.handle,
                                reserved_mr.local_mr_id,
                                RDMA_RESOURCE_MR);
      mrt.pd_h = project_handle(pd_snapshot.handle,
                                pd_snapshot.local_pd_id,
                                RDMA_RESOURCE_PD);
      mrt.state = RDMA_MR_STATE_VALID;
      mrt.iova = reserved_mr.iova;
      mrt.length = reserved_mr.length;
      mrt.lkey = reserved_mr.lkey;
      mrt.rkey = reserved_mr.rkey;
      mrt.access = reserved_mr.access;
      mrt.object_type = 2'b0;
      mrt.page_layout = rdma_clone_mr_page_layout_value(
        frozen_backing.page_layout, "register MR"
      );
      if (mrt.page_layout != null)
        mrt.page_layout.mr_serial = reserved_mr.mr_serial;

      command = rdma_make_cmq_command(
        locked_owner, RDMA_OP_KEY_ALLOC, "key_alloc", mrt, default_timeout,
        "register_mr_key_alloc"
      );

      execute_control_command_raw_status(
        command, ticket, completion, status
      );
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "KEY_ALLOC execution returned null status");
        if (status.code == RDMA_SC_TIMEOUT) begin
          recovery = rdma_recovery_record::type_id::create(
            "register_mr_timeout_recovery"
          );
          recovery.resource_h = snapshot_handle(reserved_mr.handle);
          recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
          recovery.completed_steps = result.completed_steps;
          recovery.pending_steps.push_back(
            RDMA_CTRL_STEP_HW_KEY_ALLOCATED
          );
          recovery.backing_refs = reserved_mr.backing_refs;
          recovery.hmc_refs = reserved_mr.hmc_refs;
          recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
            ticket, "register MR timeout recovery"
          );
          recovery.primary_status = rdma_cmq_clone_status_value(status);
          finalize_mr_recovery(reserved_mr, recovery, status, result, mr,
                               result_finalized);
          break;
        end
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b0, 1'b0, mr, result_finalized);
        break;
      end
      result.completed_steps.push_back(RDMA_CTRL_STEP_HW_KEY_ALLOCATED);

      status = binding_owner_status(binding, live_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-KEY_ALLOC Function binding check returned null"
        );
      end
      else begin
        status = generation_fence(binding, locked_owner);
        status = checked_status(
          status, "post-KEY_ALLOC generation fence returned null"
        );
      end
      if (status.ok()) begin
        foreach (frozen_backing.hmc_refs[i]) begin
          status = hmc_allocator.lookup(
            locked_owner, frozen_backing.hmc_refs[i].object_kind,
            frozen_backing.hmc_refs[i].address, live_lease_size
          );
          status = checked_status(
            status, "post-KEY_ALLOC HMC lookup returned null"
          );
          if (!status.ok())
            break;
          if (live_lease_size != frozen_backing.hmc_refs[i].size) begin
            status = invalid_argument(
              "post-KEY_ALLOC HMC lease size does not match"
            );
            break;
          end
        end
      end
      if (!status.ok()) begin
        recovery = rdma_recovery_record::type_id::create(
          "register_mr_post_cmq_recovery"
        );
        recovery.resource_h = snapshot_handle(reserved_mr.handle);
        recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
        recovery.completed_steps = result.completed_steps;
        recovery.pending_steps.push_back(
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED
        );
        recovery.backing_refs = reserved_mr.backing_refs;
        recovery.hmc_refs = reserved_mr.hmc_refs;
        recovery.primary_status = rdma_cmq_clone_status_value(status);
        finalize_mr_recovery(reserved_mr, recovery, status, result, mr,
                             result_finalized);
        break;
      end

      status = manager.commit_programmed(reserved_mr);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager MR commit returned null"
        );
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b0, mr, result_finalized);
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_PROGRAMMED;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_PROGRAMMED);

      status = generation_fence(binding, locked_owner);
      status = checked_status(
        status, "pre-activate MR generation fence returned null"
      );
      if (!status.ok()) begin
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b1, mr, result_finalized);
        break;
      end

      status = manager.activate(reserved_mr.handle);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "resource manager MR activate returned null");
        rollback_mr_creation(reserved_mr, locked_owner, status, result,
                             1'b1, 1'b1, mr, result_finalized);
        break;
      end
      result.final_resource_state = RDMA_RESOURCE_ACTIVE;
      result.completed_steps.push_back(RDMA_CTRL_STEP_REGISTRY_ACTIVE);

      status = manager.lookup(reserved_mr.handle, active_resource);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "resource manager active MR lookup returned null"
        );
        break;
      end
      if (!$cast(mr, active_resource) || mr == null || mr.handle == null ||
          mr.state != RDMA_RESOURCE_ACTIVE) begin
        mr = null;
        status = invalid_state(
          "resource manager active MR snapshot is invalid"
        );
        break;
      end
      result.resource_h = snapshot_handle(mr.handle);
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized)
      finish_result(result, status);
    if (function_lock_acquired_here && function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：在 rdma_control_plane 中，register_mr 将输入对象登记或挂接到当前集合/依赖图，并同步维护对应账本和生命周期引用。
  // 输入/输出及副作用：binding（输入）、request（输入）、backing（输入）、mr（输出）、result（输出）；register_mr 先依据 依赖存在性、authority 和 generation 条件 校验 binding、request、backing、mr、result；成功时更新本对象配置/状态并保存非拥有引用，返回
  //   无直接返回值。
  // 失败/边界：实现中的空依赖、重复登记、状态或 generation/authority 校验失败时返回错误；失败时保留旧配置。
  task register_mr(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_mr_backing_desc backing,
    output rdma_mr mr,
    output rdma_control_result result
  );
    register_mr_internal(binding, request, backing,
                         RDMA_OWNERSHIP_BORROWED, 0, null, mr, result);
  endtask

  // 功能：在 rdma_control_plane 中，alloc_and_register_mr 按容量、身份和生命周期约束预留或分配资源，并返回带 authority 证据的句柄或计划。
  // 输入/输出及副作用：binding（输入）、request（输入）、dma_context（输入）、alignment（输入）、mapping（输出）、mr（输出）、result（输出）；alloc_and_register_mr 驱动下游事务，并写入 mapping、mr、result；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：alloc_and_register_mr 返回 RDMA_SC_UNSUPPORTED_OPCODE、RDMA_SC_DMA_TRANSLATION、RDMA_SC_RECOVERY_REQUIRED；具体拒绝条件包括 “owned MR helper cannot allocate atomic DMA authority”；“owned MR DMA authority does not match Function”；“owned MR snapshot cannot request atomic DMA authority”；“unattached owned MR mapping requires caller recovery”；失败路径不提交部分状态、不隐式重试，也不转移未声明资源。
  task alloc_and_register_mr(
    rdma_function_binding binding,
    rdma_register_mr_req request,
    rdma_dma_request_context dma_context,
    int unsigned alignment,
    output rdma_dma_mapping mapping,
    output rdma_mr mr,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_register_mr_req frozen_request;
    rdma_dma_request_context frozen_context;
    rdma_dma_mapping allocated_mapping;
    rdma_mr_backing_desc backing;
    rdma_backing_ref backing_ref;
    rdma_status status;
    rdma_status release_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    bit ownership_transferred;
    bit registration_started;

    mapping = null;
    mr = null;
    result = make_result();
    allocated_mapping = null;
    function_lock = null;
    ownership_transferred = 1'b0;
    registration_started = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "transaction ID allocation returned null status"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "control-plane configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "Function binding check returned null");
        break;
      end
      if (alignment < 4096 ||
          (alignment & (alignment - 1'b1)) != 0) begin
        status = invalid_argument(
          "owned MR alignment must be a power of two of at least 4096"
        );
        break;
      end
      status = owned_mr_input_status(binding, request, dma_context, owner, "");
      if (!status.ok())
        break;
      if (host_mem == null) begin
        status = invalid_state(
          "owned MR host memory adapter is unavailable"
        );
        break;
      end

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock owned MR Function binding check returned null"
        );
        break;
      end
      status = same_owner_status(
        locked_owner, owner, "post-lock owned MR Function binding"
      );
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock owned MR Function identity check returned null"
        );
        break;
      end
      status = owned_mr_input_status(binding, request, dma_context,
                                     locked_owner, "post-lock ");
      if (!status.ok())
        break;

      status = detach_mr_request(request, frozen_request);
      if (!status.ok())
        break;
      status = detach_dma_context(dma_context, frozen_context);
      if (!status.ok())
        break;
      status = owned_mr_input_status(binding, frozen_request, frozen_context,
                                     locked_owner, "snapshot ");
      if (!status.ok())
        break;
      // Preserve the caller-selected MR IOVA.  The allocation contract cannot
      // request one, so inner backing validation must prove that the returned
      // mapping covers request.iova rather than silently rewriting it.
      status = host_mem.allocate(
        frozen_context, frozen_request.length, alignment,
        required_dma_direction(frozen_request.access), allocated_mapping
      );
      status = checked_status(
        status, "owned MR host memory allocation returned null"
      );
      if (!status.ok())
        break;
      if (allocated_mapping == null ||
          allocated_mapping.state != RDMA_MAPPING_ACTIVE ||
          allocated_mapping.owner_h != null) begin
        status = invalid_state(
          "owned MR host memory allocation is invalid"
        );
        break;
      end

      backing = rdma_mr_backing_desc::type_id::create(
        "allocated_mr_backing"
      );
      backing.function_h = rdma_clone_function_handle_value(
        frozen_context.function_h, "allocated MR backing"
      );
      backing.requester_bdf = frozen_context.requester_bdf;
      backing.pasid_valid = frozen_context.pasid_valid;
      backing.pasid = frozen_context.pasid;
      backing_ref = rdma_backing_ref::type_id::create(
        "allocated_mr_backing_ref"
      );
      backing_ref.mapping = allocated_mapping;
      backing_ref.ownership = RDMA_OWNERSHIP_CONTROL_PLANE;
      backing_ref.release_complete = 1'b0;
      backing.backing_refs.push_back(backing_ref);
      backing.page_layout.pbl_mode = RDMA_MR_PBL0;
      backing.page_layout.host_page_size = RDMA_MR_PAGE_4K;
      backing.page_layout.pba0 = allocated_mapping.backing_addr;
      backing.page_layout.pba1 = '0;
      backing.page_layout.first_pbl_index = 0;
      backing.page_layout.address_mode = RDMA_MR_ADDRESS_VA_BASED;
      backing.page_layout.odp = 1'b0;

      registration_started = 1'b1;
      register_mr_internal(
        binding, frozen_request, backing, RDMA_OWNERSHIP_CONTROL_PLANE,
        transaction_id, function_lock, mr, result
      );
      foreach (result.completed_steps[i])
        if (result.completed_steps[i] == RDMA_CTRL_STEP_BACKING_ATTACHED)
          ownership_transferred = 1'b1;
      if (result.ok())
        mapping = allocated_mapping;
    end while (1'b0);

    if (!registration_started)
      finish_result(result, status);
    if (allocated_mapping != null && !ownership_transferred) begin
      release_status = host_mem.\release (allocated_mapping);
      release_status = checked_status(
        release_status, "unattached owned MR release returned null"
      );
      if (!release_status.ok()) begin
        result.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(release_status)
        );
        result.status = rdma_status::make(
          RDMA_SC_RECOVERY_REQUIRED,
          "unattached owned MR mapping requires caller recovery"
        );
        result.recovery_required = 1'b0;
        result.final_resource_state = RDMA_RESOURCE_NEW;
        result.final_resource_state_known = 1'b0;
        mapping = allocated_mapping;
      end
    end
    if (function_lock != null)
      function_lock.put(1);
  endtask

  // 功能：first_pending_hardware_step 按 recovery.pending_steps 的持久化顺序选择
  //   本轮应先处理的第一个硬件阶段，供 recover_resource 的硬件恢复循环建立稳定
  //   的执行候选；该 helper 只抽离扫描职责，不改变后续 CMQ 调用或状态迁移。
  // 输入/输出及副作用：recovery（输入）只读 pending_steps；step（输出）先置为
  //   RDMA_CTRL_STEP_RESOURCE_RESERVED，命中时写入首个硬件 step；函数返回 bit 表示
  //   是否找到硬件阶段，不修改 recovery、result、CMQ、锁、资源账本或外部依赖。
  // 失败/边界：recovery 为 null 或 pending_steps 为空/仅含本地阶段时返回 0 并保留
  //   默认 step；helper 不验证 recovery schema、hardware_presence、ticket、owner、
  //   generation 或 pending 阶段的其它 authority，调用方仍须按原顺序执行这些门禁。
  protected function bit first_pending_hardware_step(
    rdma_recovery_record recovery,
    output rdma_control_step_e step
  );
    step = RDMA_CTRL_STEP_RESOURCE_RESERVED;
    if (recovery == null)
      return 1'b0;
    foreach (recovery.pending_steps[i]) begin
      if (rdma_control_step_is_hardware(recovery.pending_steps[i])) begin
        step = recovery.pending_steps[i];
        return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：recovery_has_hardware_step 在恢复账本的 completed_steps 或
  //   pending_steps 中检查是否存在硬件阶段，统一 reserved-only 判定和末尾
  //   硬件缺失校验使用的阶段扫描规则。
  // 输入/输出及副作用：recovery（输入）只读恢复账本；
  //   inspect_completed（输入）
  //   为 1 时扫描 completed_steps，为 0 时扫描 pending_steps；函数返回 bit，
  //   不修改 recovery、result、锁、CMQ 或任何外部资源。
  // 失败/边界：recovery 为 null、所选阶段数组为空或仅含本地阶段时返回 0；
  //   helper 不验证阶段顺序、hardware_presence、ticket、owner 或 generation，
  //   调用方仍须保留原有状态门禁和错误优先级。
  protected function bit recovery_has_hardware_step(
    rdma_recovery_record recovery,
    bit inspect_completed
  );
    if (recovery == null)
      return 1'b0;
    if (inspect_completed) begin
      foreach (recovery.completed_steps[i]) begin
        if (rdma_control_step_is_hardware(recovery.completed_steps[i]))
          return 1'b1;
      end
    end
    else begin
      foreach (recovery.pending_steps[i]) begin
        if (rdma_control_step_is_hardware(recovery.pending_steps[i]))
          return 1'b1;
      end
    end
    return 1'b0;
  endfunction

  // 功能：recovery_is_reserved_only 判断 ERROR MR 的恢复账本是否满足“仅本地预留待释放”
  //   快速路径，并复用 completed_steps 的硬件阶段扫描，集中保留 reserved-only 的 shape 约束。
  // 输入/输出及副作用：recovery（输入）只读 hardware_presence、ambiguous_ticket、HMC/backing/
  //   pending 记录和 completed_steps；函数返回 bit，不修改恢复账本、结果、锁、CMQ 或外部资源。
  // 失败/边界：recovery 为空、硬件存在/未知、有 ambiguous ticket、HMC 引用非空、backing 数量/所有权
  //   不符、pending 阶段不是 BACKING_RELEASED/RESOURCE_RELEASED，或 completed 含硬件阶段时返回 0；
  //   函数不检查 primary_status、owner/generation，调用方须先保留现有 ERROR MR 门禁。
  protected function bit recovery_is_reserved_only(
    rdma_recovery_record recovery
  );
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT ||
        recovery.ambiguous_ticket != null ||
        recovery.hmc_refs.size() != 0 ||
        recovery.backing_refs.size() != 1 ||
        recovery.backing_refs[0] == null ||
        recovery.backing_refs[0].ownership != RDMA_OWNERSHIP_CONTROL_PLANE ||
        recovery.pending_steps.size() != 1 ||
        !(recovery.pending_steps[0] inside {
          RDMA_CTRL_STEP_BACKING_RELEASED,
          RDMA_CTRL_STEP_RESOURCE_RELEASED
        }))
      return 1'b0;
    return !recovery_has_hardware_step(recovery, 1'b1);
  endfunction

  // 功能：在 rdma_control_plane 中，persist_recovery_record 记录或执行队列恢复步骤，依据提交证据选择重试、提交或回滚并保持操作幂等。
  // 输入/输出及副作用：resource_h（输入）、recovery（输入）；persist_recovery_record 读取 resource_h、recovery 并使用字段 first_status、retry_status；函数返回 rdma_status，不取得调用方资源所有权。
  // 失败/边界：persist_recovery_record 先检查 first_status.ok(；!retry_status.ok(，再返回 first_status；拒绝分支不提交部分状态，也不隐式重试。
  protected function rdma_status persist_recovery_record(
    rdma_handle resource_h,
    rdma_recovery_record recovery
  );
    rdma_status first_status;
    rdma_status retry_status;

    first_status = manager.mark_error(resource_h, recovery);
    first_status = checked_status(
      first_status, "recovery progress persistence returned null"
    );
    if (first_status.ok())
      return first_status;

    recovery.rollback_statuses.push_back(
      rdma_cmq_clone_status_value(first_status)
    );
    retry_status = manager.mark_error(resource_h, recovery);
    retry_status = checked_status(
      retry_status, "recovery progress retry returned null"
    );
    if (!retry_status.ok())
      recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(retry_status)
      );
    return first_status;
  endfunction

  // 功能：执行 retain_recovery_failure 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：resource_h（输入）、recovery（输入）、failure（输入）、result（输入）、message（输入）；retain_recovery_failure 读取 resource_h、recovery、failure、result、message 并使用字段 persist_status；函数返回 void，不取得调用方资源所有权。
  // 失败/边界：retain_recovery_failure 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void retain_recovery_failure(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_status failure,
    rdma_control_result result,
    string message
  );
    rdma_status persist_status;

    recovery.rollback_statuses.push_back(
      checked_status(failure, "recovery failure status is null")
    );
    persist_status = persist_recovery_record(resource_h, recovery);
    if (!persist_status.ok() && recovery.rollback_statuses.size() == 0)
      recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(persist_status)
      );
    rdma_recovery_publish_required(recovery, result, message);
  endfunction

  // 功能：在 rdma_control_plane 中，destroy_recovery_restore_ready 按 owner、generation 和幂等规则释放/隔离记录，并同步删除其账本引用。
  // 输入/输出及副作用：recovery（输入）；输入 handle/mapping/token 指定释放目标；成功时更新账本和生命周期，外部资源只按 adapter 契约释放。
  // 失败/边界：destroy_recovery_restore_ready 发现 owner/generation 不匹配、记录未知或重复释放时返回错误或幂等结果，不重新激活旧句柄。
  protected function bit destroy_recovery_restore_ready(
    rdma_recovery_record recovery
  );
    if (recovery == null ||
        recovery.hardware_presence != RDMA_HW_PRESENCE_PRESENT ||
        recovery.ambiguous_ticket != null ||
        recovery.pending_steps.size() != 0)
      return 1'b0;
    return recovery.completed_steps.size() == 0 ||
           (recovery.completed_steps.size() == 1 &&
            recovery.completed_steps[0] == RDMA_CTRL_STEP_HW_OCC_FLUSHED);
  endfunction

  // 功能：执行 restore_destroy_recovery 指定的测试或恢复状态变更，更新受控账本并保留可回滚的故障证据。
  // 输入/输出及副作用：resource_h（输入）、recovery（输入）、result（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：restore_destroy_recovery 仅允许测试/恢复范围内的状态变更；代际或资源不匹配时拒绝并保留原账本。
  protected function void restore_destroy_recovery(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_control_result result
  );
    rdma_status status;

    status = manager.restore_active(resource_h);
    status = checked_status(
      status, "destroy recovery restore ACTIVE returned null"
    );
    if (!status.ok()) begin
      retain_recovery_failure(
        resource_h, recovery, status, result,
        "destroy MR still requires ACTIVE restoration"
      );
      return;
    end
    rdma_recovery_project_history(recovery, result);
    result.status = rdma_status::success();
    result.final_resource_state = RDMA_RESOURCE_ACTIVE;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
  endfunction

  // Reserved-only ERROR MRs use the resource manager's atomic completion
  // transition.  In particular, do not publish a locally RELEASED mapping
  // before complete_reserved_error() succeeds: the adapter's opaque release
  // seal is the durable proof that makes a retry idempotent.
  // 功能：在 rdma_control_plane 中，recover_reserved_error 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：resource_h（输入）、recovery（输入）、result（输入）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover_reserved_error 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  protected function void recover_reserved_error(
    rdma_handle resource_h,
    rdma_recovery_record recovery,
    rdma_control_result result
  );
    rdma_recovery_record durable_recovery;
    rdma_status status;
    rdma_status lookup_status;
    rdma_status persist_status;
    bit backing_release_pending;
    bit release_complete;

    backing_release_pending = recovery.pending_steps[0] ==
      RDMA_CTRL_STEP_BACKING_RELEASED;
    status = rdma_status::success();
    if (backing_release_pending) begin
      if (host_mem == null)
        status = invalid_state(
          "reserved recovery host memory adapter is unavailable"
        );
      else begin
        foreach (recovery.backing_refs[i]) begin
          if (recovery.backing_refs[i] == null ||
              recovery.backing_refs[i].ownership !=
                RDMA_OWNERSHIP_CONTROL_PLANE ||
              recovery.backing_refs[i].mapping == null) begin
            status = invalid_state(
              "reserved recovery backing authority is incomplete"
            );
            break;
          end
          status = manager.query_owned_release_completion(
            recovery.backing_refs[i].mapping, release_complete
          );
          status = checked_status(
            status, "reserved recovery completion query returned null"
          );
          if (!status.ok())
            break;
          if (!release_complete) begin
            status = host_mem.\release (
              recovery.backing_refs[i].mapping
            );
            status = checked_status(
              status, "reserved recovery backing release returned null"
            );
            if (!status.ok())
              break;
            status = manager.query_owned_release_completion(
              recovery.backing_refs[i].mapping, release_complete
            );
            status = checked_status(
              status, "post-release completion query returned null"
            );
            if (!status.ok())
              break;
            if (!release_complete) begin
              status = invalid_state(
                "host memory release did not seal completion"
              );
              break;
            end
          end
        end
      end
    end

    if (status.ok()) begin
      status = manager.complete_reserved_error(resource_h);
      status = checked_status(
        status, "reserved ERROR completion returned null"
      );
    end
    if (!status.ok()) begin
      // A successful host release mutates only this working clone.  Refresh
      // the canonical record before appending the new failure so the retry
      // keeps the reserved-error schema and consumes the opaque release seal.
      durable_recovery = null;
      lookup_status = manager.lookup_recovery(
        resource_h, durable_recovery
      );
      lookup_status = checked_status(
        lookup_status, "reserved recovery refresh returned null"
      );
      if (!lookup_status.ok() || durable_recovery == null) begin
        recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(status)
        );
        if (!lookup_status.ok())
          recovery.rollback_statuses.push_back(
            rdma_cmq_clone_status_value(lookup_status)
          );
        rdma_recovery_publish_required(
          recovery, result, "reserved MR still requires recovery"
        );
        return;
      end
      durable_recovery.rollback_statuses.push_back(
        rdma_cmq_clone_status_value(status)
      );
      persist_status = persist_recovery_record(
        resource_h, durable_recovery
      );
      if (!persist_status.ok() &&
          durable_recovery.rollback_statuses.size() == 0)
        durable_recovery.rollback_statuses.push_back(
          rdma_cmq_clone_status_value(persist_status)
        );
      rdma_recovery_publish_required(
        durable_recovery, result, "reserved MR still requires recovery"
      );
      return;
    end

    if (backing_release_pending)
      rdma_recovery_complete_step(
        recovery, RDMA_CTRL_STEP_BACKING_RELEASED
      );
    rdma_recovery_complete_step(
      recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
    );
    rdma_recovery_project_history(recovery, result);
    result.status = rdma_status::success();
    result.final_resource_state = RDMA_RESOURCE_RELEASED;
    result.final_resource_state_known = 1'b1;
    result.recovery_required = 1'b0;
  endfunction

  // 功能：在 rdma_control_plane 中，execute_recovery_hardware_step 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：error_mr（输入）、owner（输入）、step（输入）、ticket（输出）、completion（输出）、status（输出）；execute_recovery_hardware_step 驱动下游事务，并写入 ticket、completion、status；函数返回 无直接返回值，不取得调用方资源所有权。
  // 失败/边界：execute_recovery_hardware_step 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  protected task execute_recovery_hardware_step(
    rdma_mr error_mr,
    rdma_function_handle owner,
    rdma_control_step_e step,
    output rdma_cmq_ticket ticket,
    output rdma_cmq_completion completion,
    output rdma_status status
  );
    rdma_cmq_command_desc command;

    ticket = null;
    completion = null;
    status = invalid_state("recovery hardware command was not executed");
    if (error_mr == null || owner == null) begin
      status = invalid_state("recovery hardware authority is incomplete");
      return;
    end

    command = make_mr_hw_command(owner, error_mr, step,
                                 "recovery_hardware_command");
    if (command == null) begin
      status = rdma_status::make(
        RDMA_SC_UNSUPPORTED_OPCODE,
        "recovery pending hardware step is unsupported"
      );
      return;
    end
    execute_control_command(
      command, ticket, completion, status,
      "recovery hardware execution returned null"
    );
  endtask

  // 功能：在 rdma_control_plane 中，recover_resource 执行受控事务并按后端提交证据推进状态机，同时保留失败阶段和 generation 证据。
  // 输入/输出及副作用：binding（输入）、resource_h（输入）、result（输出）；输入 action/epoch/handle 决定迁移目标；成功时更新状态或恢复证据，外部资源仍由其拥有者管理。
  // 失败/边界：recover_resource 遇到锁、超时、generation 变化或提交证据不完整时保持原状态，不推进游标。
  task recover_resource(
    rdma_function_binding binding,
    rdma_handle resource_h,
    output rdma_control_result result
  );
    rdma_function_handle owner;
    rdma_function_handle locked_owner;
    rdma_resource resource;
    rdma_mr error_mr;
    rdma_queue_resource error_queue;
    rdma_recovery_record recovery;
    rdma_cmq_ticket ticket;
    rdma_cmq_completion completion;
    rdma_status status;
    rdma_status completion_status;
    rdma_status persist_status;
    rdma_status reconcile_status;
    semaphore function_lock;
    longint unsigned transaction_id;
    longint unsigned lease_size;
    rdma_control_step_e pending_hardware_step;
    bit terminal_known;
    bit release_complete;
    bit creation_origin;
    bit has_hardware_pending;
    bit reserved_only;
    bit result_finalized;
    bit defer_terminal_retry;

    result = make_result();
    function_lock = null;
    result_finalized = 1'b0;
    reserve_transaction_id(transaction_id, status);
    result.transaction_id = transaction_id;
    result.resource_h = snapshot_handle(resource_h);

    do begin
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "recovery transaction ID allocation returned null"
        );
        break;
      end
      status = configured_status();
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "recovery configuration check returned null"
        );
        break;
      end
      status = binding_owner_status(binding, owner);
      if (status == null || !status.ok()) begin
        status = checked_status(status,
                                "recovery Function check returned null");
        break;
      end
      if (resource_h == null ||
          !(resource_h.kind inside {RDMA_RESOURCE_MR, RDMA_RESOURCE_QP,
                                    RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                    RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ})) begin
        status = invalid_argument("recovery handle kind is unsupported");
        break;
      end
      status = queue_target_owner_status(resource_h, owner,
                                         "recovery target");
      if (status == null || !status.ok())
        break;

      acquire_function_lock(owner, function_lock);
      status = binding_owner_status(binding, locked_owner);
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock recovery Function check returned null"
        );
        break;
      end
      status = same_owner_status(locked_owner, owner,
                                 "post-lock recovery Function");
      if (status == null || !status.ok()) begin
        status = checked_status(
          status, "post-lock recovery Function identity returned null"
        );
        break;
      end
      status = manager.lookup(resource_h, resource);
      status = checked_status(status, "recovery lookup returned null");
      if (!status.ok())
        break;

      // QP recovery has its own lifecycle executor because QPC images,
      // query-buffer authority, and ordered backing cleanup differ from the
      // generic queue/MR recovery protocol.  Dispatch while the per-Function
      // lock is held, exactly like create/modify/destroy.
      if (resource_h.kind == RDMA_RESOURCE_QP) begin
        rdma_qp error_qp;
        if (qp_executor == null) begin
          status = invalid_state("QP lifecycle executor is unavailable");
          break;
        end
        if (!$cast(error_qp, resource) || error_qp == null ||
            error_qp.state != RDMA_RESOURCE_ERROR) begin
          status = invalid_state("QP recovery requires an ERROR QP");
          break;
        end
        status = same_owner_status(error_qp.owner, locked_owner,
                                   "recovery QP");
        if (status == null || !status.ok())
          break;
        qp_executor.recover_locked(binding, locked_owner, resource_h,
                                   transaction_id, result);
        if (result == null) begin
          result = make_result();
          result.transaction_id = transaction_id;
          status = invalid_state("QP recovery executor returned null result");
          break;
        end
        result_finalized = 1'b1;
        break;
      end

      // Queue recovery is policy-driven and lives in the queue executor.  Do
      // this dispatch while the same per-Function lock used by create/destroy
      // is held; the executor never allocates IDs or acquires another lock.
      if (resource_h.kind inside {RDMA_RESOURCE_CQ, RDMA_RESOURCE_SRQ,
                                  RDMA_RESOURCE_CEQ, RDMA_RESOURCE_AEQ}) begin
        if (queue_executor == null) begin
          status = invalid_state("queue lifecycle executor is unavailable");
          break;
        end
        if (!$cast(error_queue, resource) || error_queue == null ||
            error_queue.state != RDMA_RESOURCE_ERROR) begin
          status = invalid_state("recovery requires an ERROR queue");
          break;
        end
        status = same_owner_status(error_queue.owner, locked_owner,
                                   "recovery queue");
        if (status == null || !status.ok())
          break;
        queue_executor.recover_locked(
          binding, locked_owner, resource_h, transaction_id, result
        );
        if (result == null) begin
          result = make_result();
          result.transaction_id = transaction_id;
          status = invalid_state("queue recovery executor returned null result");
          break;
        end
        result_finalized = 1'b1;
        break;
      end
      if (!$cast(error_mr, resource) || error_mr == null ||
          error_mr.state != RDMA_RESOURCE_ERROR) begin
        status = invalid_state("recovery requires an ERROR MR");
        break;
      end
      result.resource_h = snapshot_handle(error_mr.handle);
      status = same_owner_status(error_mr.owner, locked_owner, "recovery MR");
      if (status == null || !status.ok()) begin
        status = checked_status(status, "recovery owner check returned null");
        break;
      end
      status = manager.lookup_recovery(resource_h, recovery);
      status = checked_status(
        status, "recovery record lookup returned null"
      );
      if (!status.ok())
        break;
      if (recovery == null || recovery.primary_status == null) begin
        status = invalid_state("ERROR MR recovery record is incomplete");
        break;
      end
      rdma_recovery_project_history(recovery, result);
      creation_origin = rdma_recovery_step_completed(
        recovery, RDMA_CTRL_STEP_RESOURCE_RESERVED
      );
      reserved_only = recovery_is_reserved_only(recovery);
      if (reserved_only) begin
        recover_reserved_error(resource_h, recovery, result);
        result_finalized = 1'b1;
        break;
      end

      if (!creation_origin &&
          destroy_recovery_restore_ready(recovery)) begin
        restore_destroy_recovery(resource_h, recovery, result);
        result_finalized = 1'b1;
        break;
      end

      if (recovery.ambiguous_ticket != null) begin
        ticket = recovery.ambiguous_ticket;
        terminal_known = 1'b0;
        completion = null;
        cmq.reconcile(ticket, terminal_known, completion,
                      reconcile_status);
        reconcile_status = checked_status(
          reconcile_status, "CMQ reconciliation returned null"
        );
        if (!terminal_known) begin
          rdma_recovery_publish_required(
            recovery, result,
            "ambiguous CMQ command has no terminal result"
          );
          if (!reconcile_status.ok())
            result.rollback_statuses.push_back(
              rdma_cmq_clone_status_value(reconcile_status)
            );
          result_finalized = 1'b1;
          break;
        end
        if (completion == null || completion.status == null) begin
          retain_recovery_failure(
            resource_h, recovery,
            invalid_state("CMQ reconciliation completion is incomplete"),
            result, "CMQ reconciliation still requires recovery"
          );
          result_finalized = 1'b1;
          break;
        end
        completion_status = checked_status(
          completion.status, "CMQ reconciliation status returned null"
        );
        if (completion_status.code == RDMA_SC_RESET_CANCELLED) begin
          rdma_recovery_publish_required(
            recovery, result,
            "reset cancellation does not prove hardware absence"
          );
          result_finalized = 1'b1;
          break;
        end

        if (ticket.opcode_key == null) begin
          retain_recovery_failure(
            resource_h, recovery,
            invalid_state("ambiguous CMQ ticket has no opcode"), result,
            "ambiguous CMQ command still requires recovery"
          );
          result_finalized = 1'b1;
          break;
        end
        defer_terminal_retry = 1'b0;
        case (ticket.opcode_key.opcode)
          RDMA_OP_KEY_ALLOC: begin
            if (!rdma_recovery_step_pending(
                  recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED)) begin
              retain_recovery_failure(
                resource_h, recovery,
                invalid_state("KEY_ALLOC ticket has no pending step"),
                result, "ambiguous KEY_ALLOC still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
            recovery.ambiguous_ticket = null;
            if (completion_status.ok()) begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
            end
            else begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
              rdma_recovery_remove_pending(
                recovery, RDMA_CTRL_STEP_HW_KEY_ALLOCATED
              );
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            end
          end
          RDMA_OP_OCC_FLUSH: begin
            recovery.ambiguous_ticket = null;
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            if (completion_status.ok()) begin
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
            end
            else begin
              if (!creation_origin)
                rdma_recovery_remove_pending(
                  recovery, RDMA_CTRL_STEP_HW_OCC_FLUSHED
                );
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
            end
          end
          RDMA_OP_MR_DEREGISTER: begin
            recovery.ambiguous_ticket = null;
            if (completion_status.ok()) begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
              );
              if (creation_origin)
                rdma_recovery_queue_step(
                  recovery, RDMA_CTRL_STEP_BACKING_RELEASED
                );
              else
                rdma_recovery_queue_step(
                  recovery, RDMA_CTRL_STEP_HW_DRAINED
                );
            end
            else begin
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
              if (!creation_origin)
                rdma_recovery_remove_pending(
                  recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
                );
              else
                defer_terminal_retry = 1'b1;
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
            end
          end
          RDMA_OP_TQ_FLUSH: begin
            recovery.ambiguous_ticket = null;
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            if (completion_status.ok()) begin
              rdma_recovery_complete_step(
                recovery, RDMA_CTRL_STEP_HW_DRAINED
              );
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            end
            else begin
              recovery.rollback_statuses.push_back(
                rdma_cmq_clone_status_value(completion_status)
              );
              defer_terminal_retry = 1'b1;
            end
          end
          default: begin
            retain_recovery_failure(
              resource_h, recovery,
              rdma_status::make(
                RDMA_SC_UNSUPPORTED_OPCODE,
                "ambiguous recovery opcode is unsupported"
              ), result, "ambiguous CMQ command still requires recovery"
            );
            result_finalized = 1'b1;
          end
        endcase
        if (result_finalized)
          break;
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "reconciled CMQ progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
        if (defer_terminal_retry) begin
          rdma_recovery_publish_required(
            recovery, result,
            "terminal hardware failure was retained for a later retry"
          );
          result_finalized = 1'b1;
          break;
        end
        if (!creation_origin &&
            destroy_recovery_restore_ready(recovery)) begin
          restore_destroy_recovery(resource_h, recovery, result);
          result_finalized = 1'b1;
          break;
        end
      end

      while (1'b1) begin
        has_hardware_pending = first_pending_hardware_step(
          recovery, pending_hardware_step
        );
        if (!has_hardware_pending)
          break;
        if (recovery.hardware_presence == RDMA_HW_PRESENCE_UNKNOWN) begin
          rdma_recovery_publish_required(
            recovery, result,
            "unknown hardware state lacks terminal reconciliation"
          );
          result_finalized = 1'b1;
          break;
        end
        if (pending_hardware_step == RDMA_CTRL_STEP_HW_KEY_ALLOCATED) begin
          rdma_recovery_publish_required(
            recovery, result,
            "KEY_ALLOC ambiguity requires its original terminal result"
          );
          result_finalized = 1'b1;
          break;
        end

        execute_recovery_hardware_step(
          error_mr, locked_owner, pending_hardware_step,
          ticket, completion, status
        );
        if (!status.ok()) begin
          if (status.code == RDMA_SC_TIMEOUT) begin
            recovery.ambiguous_ticket = rdma_cmq_clone_ticket_value(
              ticket, "recovery timeout ticket"
            );
            if (pending_hardware_step == RDMA_CTRL_STEP_HW_DRAINED)
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            else
              recovery.hardware_presence = RDMA_HW_PRESENCE_UNKNOWN;
          end
          else begin
            recovery.ambiguous_ticket = null;
            if (pending_hardware_step == RDMA_CTRL_STEP_HW_DRAINED)
              recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            else
              recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
          end
          retain_recovery_failure(
            resource_h, recovery, status, result,
            "hardware recovery step failed"
          );
          result_finalized = 1'b1;
          break;
        end

        case (pending_hardware_step)
          RDMA_CTRL_STEP_HW_OCC_FLUSHED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_PRESENT;
            rdma_recovery_complete_step(recovery, pending_hardware_step);
            rdma_recovery_queue_step(
              recovery, RDMA_CTRL_STEP_HW_MR_DEREGISTERED
            );
          end
          RDMA_CTRL_STEP_HW_MR_DEREGISTERED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            rdma_recovery_complete_step(recovery, pending_hardware_step);
            if (creation_origin)
              rdma_recovery_queue_step(
                recovery, RDMA_CTRL_STEP_BACKING_RELEASED
              );
            else
              rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_HW_DRAINED);
          end
          RDMA_CTRL_STEP_HW_DRAINED: begin
            recovery.hardware_presence = RDMA_HW_PRESENCE_ABSENT;
            rdma_recovery_complete_step(recovery, pending_hardware_step);
            rdma_recovery_queue_step(
              recovery, RDMA_CTRL_STEP_BACKING_RELEASED
            );
          end
          default: begin
          end
        endcase
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "hardware recovery progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end
      if (result_finalized)
        break;

      has_hardware_pending = recovery_has_hardware_step(
        recovery, 1'b0
      );
      if (has_hardware_pending ||
          recovery.hardware_presence != RDMA_HW_PRESENCE_ABSENT) begin
        rdma_recovery_publish_required(
          recovery, result,
          "hardware absence is not yet proven"
        );
        result_finalized = 1'b1;
        break;
      end

      if (!rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED) &&
          !rdma_recovery_step_completed(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED) &&
          !rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_BACKING_RELEASED);
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "local recovery plan could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end

      if (rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_BACKING_RELEASED)) begin
        for (int i = int'(recovery.hmc_refs.size()) - 1; i >= 0; i--) begin
          if (recovery.hmc_refs[i] == null) begin
            status = invalid_state("recovery HMC reference is null");
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "HMC cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (recovery.hmc_refs[i].ownership == RDMA_OWNERSHIP_BORROWED ||
              recovery.hmc_refs[i].release_complete)
            continue;
          if (hmc_allocator == null) begin
            status = invalid_state("recovery HMC allocator is unavailable");
          end
          else begin
            status = hmc_allocator.lookup(
              recovery.hmc_refs[i].owner,
              recovery.hmc_refs[i].object_kind,
              recovery.hmc_refs[i].address, lease_size
            );
            status = checked_status(
              status, "recovery HMC lookup returned null"
            );
            if (status.ok() && lease_size != recovery.hmc_refs[i].size)
              status = invalid_state("recovery HMC lease size changed");
            if (status.ok()) begin
              status = hmc_allocator.\release (
                recovery.hmc_refs[i].owner,
                recovery.hmc_refs[i].object_kind,
                recovery.hmc_refs[i].address
              );
              status = checked_status(
                status, "recovery HMC release returned null"
              );
            end
            else if (status.code == RDMA_SC_INVALID_STATE) begin
              status = rdma_status::success(
                "recovery HMC lease was already released"
              );
            end
          end
          if (!status.ok()) begin
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "HMC cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          recovery.hmc_refs[i].release_complete = 1'b1;
          persist_status = persist_recovery_record(resource_h, recovery);
          if (!persist_status.ok()) begin
            rdma_recovery_publish_required(
              recovery, result,
              "HMC cleanup progress could not be persisted"
            );
            result_finalized = 1'b1;
            break;
          end
        end
        if (result_finalized)
          break;

        foreach (recovery.backing_refs[i]) begin
          if (recovery.backing_refs[i] == null ||
              recovery.backing_refs[i].mapping == null) begin
            status = invalid_state("recovery backing reference is null");
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "backing cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (recovery.backing_refs[i].ownership ==
                RDMA_OWNERSHIP_BORROWED ||
              recovery.backing_refs[i].release_complete)
            continue;
          status = manager.query_owned_release_completion(
            recovery.backing_refs[i].mapping, release_complete
          );
          status = checked_status(
            status, "recovery completion query returned null"
          );
          if (!status.ok()) begin
            retain_recovery_failure(
              resource_h, recovery, status, result,
              "backing cleanup still requires recovery"
            );
            result_finalized = 1'b1;
            break;
          end
          if (!release_complete) begin
            if (host_mem == null)
              status = invalid_state(
                "recovery host memory adapter is unavailable"
              );
            else
              status = host_mem.\release (
                recovery.backing_refs[i].mapping
              );
            status = checked_status(
              status, "recovery backing release returned null"
            );
            if (!status.ok()) begin
              retain_recovery_failure(
                resource_h, recovery, status, result,
                "backing cleanup still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
            status = manager.query_owned_release_completion(
              recovery.backing_refs[i].mapping, release_complete
            );
            status = checked_status(
              status, "post-release completion query returned null"
            );
            if (!status.ok() || !release_complete) begin
              if (status.ok())
                status = invalid_state(
                  "host memory release did not seal completion"
                );
              retain_recovery_failure(
                resource_h, recovery, status, result,
                "backing cleanup still requires recovery"
              );
              result_finalized = 1'b1;
              break;
            end
          end
          recovery.backing_refs[i].release_complete = 1'b1;
          persist_status = persist_recovery_record(resource_h, recovery);
          if (!persist_status.ok()) begin
            rdma_recovery_publish_required(
              recovery, result,
              "backing cleanup progress could not be persisted"
            );
            result_finalized = 1'b1;
            break;
          end
        end
        if (result_finalized)
          break;

        rdma_recovery_complete_step(
          recovery, RDMA_CTRL_STEP_BACKING_RELEASED
        );
        rdma_recovery_queue_step(recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED);
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "backing cleanup completion could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end

      if (recovery.pending_steps.size() != 0 &&
          !rdma_recovery_step_pending(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        retain_recovery_failure(
          resource_h, recovery,
          invalid_state("recovery contains an unsupported pending step"),
          result, "resource still requires recovery"
        );
        result_finalized = 1'b1;
        break;
      end

      if (!rdma_recovery_step_completed(
            recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED)) begin
        rdma_recovery_queue_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        rdma_recovery_complete_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        persist_status = persist_recovery_record(resource_h, recovery);
        if (!persist_status.ok()) begin
          rdma_recovery_publish_required(
            recovery, result,
            "resource-release progress could not be persisted"
          );
          result_finalized = 1'b1;
          break;
        end
      end
      if (recovery.pending_steps.size() != 0) begin
        rdma_recovery_publish_required(
          recovery, result,
          "resource still has pending recovery work"
        );
        result_finalized = 1'b1;
        break;
      end
      status = manager.finalize_release(resource_h);
      status = checked_status(
        status, "recovered ERROR final release returned null"
      );
      if (!status.ok()) begin
        rdma_recovery_remove_completed(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        rdma_recovery_queue_step(
          recovery, RDMA_CTRL_STEP_RESOURCE_RELEASED
        );
        retain_recovery_failure(
          resource_h, recovery, status, result,
          "resource finalization still requires recovery"
        );
        result_finalized = 1'b1;
        break;
      end

      rdma_recovery_project_history(recovery, result);
      result.status = rdma_status::success();
      result.final_resource_state = RDMA_RESOURCE_RELEASED;
      result.final_resource_state_known = 1'b1;
      result.recovery_required = 1'b0;
      status = rdma_status::success();
    end while (1'b0);

    if (!result_finalized && (status == null || !status.ok()))
      finish_result(result, status);
    if (function_lock != null)
      function_lock.put(1);
  endtask
endclass
